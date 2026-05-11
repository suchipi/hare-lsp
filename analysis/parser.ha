// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Recovering parser. The Hare stdlib parser stops at the first error; we
// need to keep going so the LSP can report multiple diagnostics per file
// and still hand the rest of the AST to feature handlers.
//
// Strategy:
//   1. Parse imports via parse::imports. If that fails, record the error
//      and resync to the first plausible decl boundary.
//   2. Loop:
//        - Stop at EOF.
//        - Try parse::decl. On success, append. On error, record and skip
//          tokens until the next plausible decl boundary.
//
// "Plausible decl boundary" = top-of-decl tokens: EXPORT, STATIC, LET,
// CONST, DEF, TYPE, FN, USE, any ATTR_* token, or EOF.

use bufio;
use hare::ast;
use hare::lex;
use hare::lex::{ltok};
use hare::parse;
use io;
use memio;
use strings;

// Result of a recovering parse.
export type parse_result = struct {
	// Best-effort AST. Contains successfully-parsed imports + decls.
	subunit: ast::subunit,
	// All errors encountered. Each is keyed by location for the LSP layer
	// to convert into diagnostics.
	errors: []parse_diagnostic,
	// True when the buffer was non-empty but no top-level form was
	// successfully parsed.
	completely_failed: bool,
};

// A single parse error, suitable for translation to an LSP Diagnostic.
export type parse_diagnostic = struct {
	location: lex::location,
	message: str,
};

// Parses an entire source buffer with recovery. The result owns its strings;
// pass it to [[finish_parse_result]] when done.
//
// `path` is an opaque label used in error messages.
export fn parse_recover(text: []u8, path: str) parse_result = {
	let res = parse_result {
		subunit = ast::subunit {
			imports = [],
			decls = [],
		},
		errors = [],
		completely_failed = false,
	};

	if (len(text) == 0) {
		return res;
	};

	let src = memio::fixed(text);
	let scan = bufio::newscanner(&src);
	defer bufio::finish(&scan);
	// COMMENTS so doc comments above decls populate ast::decl.docs;
	// hover renders them below the signature.
	let lexer = lex::init(&scan, path, lex::flag::COMMENTS);
	defer lex::finish(&lexer);

	// Phase 1: imports.
	match (parse::imports(&lexer)) {
	case let imps: []ast::import =>
		res.subunit.imports = imps;
	case let e: parse::error =>
		record_error(&res, e);
		// On import-parse failure, sync to the next decl boundary and
		// continue with decls.
		resync_to_decl(&lexer);
	};

	// Phase 2: decls in a loop.
	for (true) {
		// EOF check, plus a pre-flight that the next token is plausibly
		// the start of a declaration. Gating on is_decl_boundary lets
		// us surface an "expected declaration" diagnostic at the bad
		// token's location instead of whatever deeper error parse::decl
		// would surface from inside the attrs loop or want chain.
		const tok = match (parse::peek(&lexer)) {
		case let t: lex::token =>
			yield t;
		case void => break;
		case let e: parse::error =>
			record_error(&res, e);
			resync_to_decl(&lexer);
			continue;
		};
		if (tok.0 == ltok::EOF) break;
		if (!is_decl_boundary(tok.0)) {
			append(res.errors, parse_diagnostic {
				location = tok.2,
				message = strings::dup("expected declaration")!,
			})!;
			resync_to_decl(&lexer);
			continue;
		};

		match (parse::decl(&lexer)) {
		case let d: ast::decl =>
			append(res.subunit.decls, d)!;
		case let e: parse::error =>
			record_error(&res, e);
			resync_to_decl(&lexer);
		};
	};

	res.completely_failed = len(res.subunit.imports) == 0
		&& len(res.subunit.decls) == 0
		&& len(res.errors) > 0;
	// hare::lex stores `loc.off` as a rune index, but every
	// downstream consumer (byte_to_position, source slicing,
	// documentLink, etc.) treats it as a byte offset. Translate
	// the entire AST to byte offsets here so callers don't need
	// to know about the underlying rune-vs-byte distinction.
	fixup_parse_result(&res, text);
	return res;
};

// Releases owned memory in a parse_result, including each ast::decl via
// ast::decl_finish.
export fn finish_parse_result(r: *parse_result) void = {
	for (let i = 0z; i < len(r.errors); i += 1) {
		free(r.errors[i].message);
	};
	free(r.errors);
	for (let i = 0z; i < len(r.subunit.imports); i += 1) {
		ast::import_finish(r.subunit.imports[i]);
	};
	free(r.subunit.imports);
	for (let i = 0z; i < len(r.subunit.decls); i += 1) {
		ast::decl_finish(r.subunit.decls[i]);
	};
	free(r.subunit.decls);
};

fn record_error(r: *parse_result, e: parse::error) void = {
	const lex_err: lex::error = e: lex::error;
	match (lex_err) {
	case let s: lex::syntax =>
		append(r.errors, parse_diagnostic {
			location = s.0,
			message = strings::dup(s.1)!,
		})!;
	case let io_err: io::error =>
		// I/O errors against an in-memory buffer shouldn't really
		// happen, but report them at the lexer's last known location.
		append(r.errors, parse_diagnostic {
			location = lex::location {
				path = "",
				line = 1,
				col = 1,
				off = 0,
			},
			message = strings::dup(io::strerror(io_err))!,
		})!;
	};
};

// Advances the lexer until a plausible declaration boundary or EOF is the
// next token. The "boundary" tokens are unlexed so the next parse::decl
// starts cleanly on them.
//
// Implementation note: Hare's parser sometimes leaves a token in the unlex
// slot when it fails (e.g. after a `try` that didn't match). The lex slot
// only holds one token, and `lex::unlex` aborts on overflow. So we always
// start by performing a single `lex` to drain any pending slot, then proceed
// by lexing without unlexing until we've found a boundary, at which point we
// finally place that boundary token back in the slot for the next parse step
// to pick up.
fn resync_to_decl(lexer: *lex::lexer) void = {
	let last: (lex::token | void) = void;
	for (true) {
		const tok: lex::token = match (lex::lex(lexer)) {
		case let t: lex::token =>
			yield t;
		case lex::error =>
			return;
		};
		if (is_decl_boundary(tok.0) || tok.0 == ltok::EOF) {
			last = tok;
			break;
		};
	};
	match (last) {
	case let t: lex::token =>
		lex::unlex(lexer, t);
	case void => void;
	};
};

fn is_decl_boundary(t: ltok) bool = {
	switch (t) {
	case ltok::EXPORT, ltok::STATIC, ltok::LET, ltok::CONST,
	     ltok::DEF, ltok::TYPE, ltok::FN, ltok::USE,
	     ltok::ATTR_FINI, ltok::ATTR_INIT, ltok::ATTR_PACKED,
	     ltok::ATTR_SYMBOL, ltok::ATTR_TEST, ltok::ATTR_THREADLOCAL,
	     ltok::ATTR_UNDEFINED =>
		return true;
	case =>
		return false;
	};
};
