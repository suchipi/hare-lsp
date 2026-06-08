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
	// @owned
	errors: []parse_diagnostic,
	// True when the buffer was non-empty but no top-level form was
	// successfully parsed.
	completely_failed: bool,
};

// A single parse error, suitable for translation to an LSP Diagnostic.
export type parse_diagnostic = struct {
	location: lex::location,
	// @owned
	message: str,
};

// Parses an entire source buffer with recovery. The result owns its strings;
// pass it to [[finish_parse_result]] when done.
//
// `path` is an opaque label used in error messages.
//
// Two-pass body recovery: the stdlib `parse::decl` rejects an entire
// function when ANY statement in its body is malformed, and this parser
// only resyncs at decl boundaries, so a single bad statement otherwise
// discards every binding in the function (breaking hover, go-to-def,
// references, etc. for the whole function). The overwhelmingly common
// such transient error during editing is an incomplete member access -
// `foo.` with no field name yet, e.g. the instant before requesting
// completion. When the first pass reports errors, we retry on an
// offset-preserving copy in which each dangling member-access dot is
// blanked to a space (see [[repair_dangling_member_dots]]); if that pass
// recovers more decls we adopt its AST but keep the ORIGINAL errors, so
// the incomplete access still surfaces as a diagnostic. Blanking (rather
// than inserting a placeholder) keeps every byte/rune offset identical,
// so the recovered AST is consumed against the original source without
// remapping.
//
// @param text: borrowed
// @param path: borrowed
export fn parse_recover(text: []u8, path: str) parse_result = {
	let res = parse_phases(text, path);

	if (len(res.errors) > 0) {
		match (repair_dangling_member_dots(text)) {
		case let repaired: []u8 =>
			defer free(repaired);
			let res2 = parse_phases(repaired, path);
			if (len(res2.subunit.decls) > len(res.subunit.decls)) {
				// Adopt the recovered AST, but keep the original
				// errors for diagnostics. Offsets match because the
				// repair is byte-for-byte length-preserving.
				free_subunit(&res.subunit);
				res.subunit = res2.subunit;
				res2.subunit = ast::subunit {
					imports = [],
					decls = [],
				};
			};
			finish_parse_result(&res2);
		case void => void;
		};
	};

	res.completely_failed =
		len(res.subunit.imports) == 0 && len(res.subunit.decls) == 0
		&& len(res.errors) > 0;
	// hare::lex stores `loc.off` as a rune index, but every
	// downstream consumer (byte_to_position, source slicing,
	// documentLink, etc.) treats it as a byte offset. Translate
	// the entire AST to byte offsets here so callers don't need
	// to know about the underlying rune-vs-byte distinction.
	fixup_parse_result(&res, text);
	return res;
};

// Runs the recovering parse passes (imports, then a decl loop) over `text`
// and returns the best-effort AST plus recorded errors. The result is NOT
// location-fixed-up; [[parse_recover]] owns that final step so it can run
// these passes more than once (see its body-recovery retry).
//
// @param text: borrowed
// @param path: borrowed
fn parse_phases(text: []u8, path: str) parse_result = {
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
		case void =>
			break;
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

	res.completely_failed =
		len(res.subunit.imports) == 0 && len(res.subunit.decls) == 0
		&& len(res.errors) > 0;
	return res;
};

// Releases owned memory in a parse_result, including each ast::decl via
// ast::decl_finish.
//
// @param r: borrowed
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

// Frees the imports and decls owned by a subunit (but not the subunit
// value itself, which is a plain struct). Used by [[parse_recover]]'s
// body-recovery retry when it adopts the repaired AST and must release
// the first pass's discarded one.
//
// @param su: borrowed
fn free_subunit(su: *ast::subunit) void = {
	for (let i = 0z; i < len(su.imports); i += 1) {
		ast::import_finish(su.imports[i]);
	};
	free(su.imports);
	for (let i = 0z; i < len(su.decls); i += 1) {
		ast::decl_finish(su.decls[i]);
	};
	free(su.decls);
};

// Returns an offset-preserving copy of `text` in which every dangling
// member-access dot - a `.` written as the start of a field access but
// with no field name after it yet, e.g. `foo.` right before a `)`, `;`,
// `}`, or end of input - is overwritten with a space, or void when there
// is no such dot. Overwriting in place (rather than deleting the dot or
// inserting a placeholder name) keeps every byte and rune offset identical
// to the original, so an AST parsed from the result maps onto the original
// source without remapping.
//
// Only member-access dots are touched:
//   - dots inside strings, runes, raw strings and comments are skipped via
//     [[token_skip_noncode]];
//   - `..` and `...` (slice ranges, variadic, struct spread) are left alone;
//   - a dot must directly follow a receiver (identifier, `)` or `]`) - a dot
//     after a digit is a float literal (`1.`), never a member access;
//   - a dot followed (after whitespace/comments) by an identifier or digit
//     is a complete `.field` / `.0` access and is left alone.
//
// @param text: borrowed
// @returns: owned
fn repair_dangling_member_dots(text: []u8) ([]u8 | void) = {
	const n = len(text);
	let out: []u8 = [];
	let changed = false;
	let i = 0z;
	for (i < n) {
		const j = token_skip_noncode(text, i, n);
		if (j != i) {
			i = j;
			continue;
		};
		if (text[i] != '.': u8) {
			i += 1;
			continue;
		};
		// `..` / `...`: skip both dots so the second isn't reconsidered.
		if (i + 1 < n && text[i + 1] == '.': u8) {
			i += 2;
			continue;
		};
		if (i > 0 && text[i - 1] == '.': u8) {
			i += 1;
			continue;
		};
		// A member-access dot directly follows its receiver. A leading dot
		// or one after a non-receiver byte (digit -> float literal,
		// whitespace, operator) is not something we can safely blank.
		if (i == 0 || !is_receiver_end_byte(text[i - 1])) {
			i += 1;
			continue;
		};
		// Find the next code byte after the dot, skipping whitespace and
		// comments. An identifier or digit there means the access is
		// already complete (`.field` / `.0`); only a non-name byte (or
		// end of input) is a dangling access.
		let k = i + 1;
		for (k < n) {
			if (is_space_byte(text[k])) {
				k += 1;
				continue;
			};
			const m = token_skip_noncode(text, k, n);
			if (m != k) {
				k = m;
				continue;
			};
			break;
		};
		const dangling = k >= n || !is_ident_byte(text[k]);
		if (!dangling) {
			i += 1;
			continue;
		};
		if (!changed) {
			out = alloc([], n)!;
			append(out, text...)!;
			changed = true;
		};
		out[i] = ' ': u8;
		i += 1;
	};
	if (changed) {
		return out;
	};
	return void;
};

// True for a byte that can be the last byte of a member-access receiver:
// an ASCII letter, `_`, `)` or `]`. Digits are deliberately excluded so a
// trailing dot on a number (`1.`, a float literal) is not mistaken for a
// member access.
fn is_receiver_end_byte(b: u8) bool = {
	if (b >= 'a': u8 && b <= 'z': u8) return true;
	if (b >= 'A': u8 && b <= 'Z': u8) return true;
	return b == '_': u8 || b == ')': u8 || b == ']': u8;
};

fn is_space_byte(b: u8) bool = {
	return b == ' ': u8 || b == '\t': u8 || b == '\n': u8 || b == '\r': u8;
};

// @param r: borrowed
// @param e: borrowed
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
//
// @param lexer: borrowed
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
	case ltok::EXPORT,
	ltok::STATIC,
	ltok::LET,
	ltok::CONST,
	ltok::DEF,
	ltok::TYPE,
	ltok::FN,
	ltok::USE,
	ltok::ATTR_FINI,
	ltok::ATTR_INIT,
	ltok::ATTR_PACKED,
	ltok::ATTR_SYMBOL,
	ltok::ATTR_TEST,
	ltok::ATTR_THREADLOCAL,
	ltok::ATTR_UNDEFINED =>
		return true;
	case =>
		return false;
	};
};
