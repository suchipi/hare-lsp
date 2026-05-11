// SPDX-License-Identifier: MPL-2.0
// (c) Hare authors <https://harelang.org>
//
// Vendored overlay of hare::parse. Mirrors the stdlib module byte-for-byte
// except for the `want` fix below — without that fix, calling `want` with
// multiple alternatives on a non-matching token aborts the whole process
// ("attempted to unlex more than one token"), which trips on intermediate
// editing states and crashes the LSP.

use fmt;
use hare::lex;
use hare::lex::{ltok};
use hare::ast;
use io;
use memio;

// All possible error types.
export type error = !lex::error;

// Convert an error into a human-friendly string. The result may be statically
// allocated.
export fn strerror(err: error) const str = lex::strerror(err: lex::error);

fn syntaxerr(
	loc: lex::location,
	fmt: str,
	args: fmt::field...
) lex::error = {
	static let buf: [4096]u8 = [0...];
	let why = fmt::bsprintf(buf, fmt, args...)!;
	return lex::syntaxerr(loc, why);
};

// Requires the next token to have a matching ltok. Returns that token, or an
// error.
export fn want(lexer: *lex::lexer, want: lex::ltok...) (lex::token | error) = {
	let tok = lex::lex(lexer)?;
	if (len(want) == 0) {
		return tok;
	};
	for (let i = 0z; i < len(want); i += 1) {
		if (tok.0 == want[i]) {
			return tok;
		};
	};

	let buf = memio::dynamic();
	defer io::close(&buf)!;
	// Note: stdlib uses `mkloc(lexer)` here for the per-alternative token
	// location. mkloc does a lex+unlex cycle, which leaves a token in
	// the unlex slot — so the `lex::unlex(lexer, tok)` below would then
	// assert with "attempted to unlex more than one token". We use
	// `tok.2` (the failing token's location) instead, which gives the
	// same render for tokstr (it ignores location for the keyword/symbol
	// tokens used here) and keeps the unlex slot clean.
	for (let i = 0z; i < len(want); i += 1) {
		const tstr = if (want[i] == ltok::NAME) "name"
			else lex::tokstr((want[i], void, tok.2));
		fmt::fprintf(&buf, "'{}'", tstr)!;
		if (i + 1 < len(want)) {
			fmt::fprint(&buf, ", ")!;
		};
	};
	lex::unlex(lexer, tok);
	return syntaxerr(tok.2, "Unexpected '{}', was expecting {}",
		lex::tokstr(tok), memio::string(&buf)!);
};

// Looks for a matching ltok from the lexer, and if not present, unlexes the
// token and returns void. If found, the token is consumed from the lexer and is
// returned.
export fn try(
	lexer: *lex::lexer,
	want: lex::ltok...
) (lex::token | error | void) = {
	let tok = lex::lex(lexer)?;
	assert(len(want) > 0);
	for (let i = 0z; i < len(want); i += 1) {
		if (tok.0 == want[i]) {
			return tok;
		};
	};
	lex::unlex(lexer, tok);
};

// Looks for a matching ltok from the lexer, unlexes the token, and returns
// it; or void if it was not an ltok.
export fn peek(
	lexer: *lex::lexer,
	want: lex::ltok...
) (lex::token | error | void) = {
	let tok = lex::lex(lexer)?;
	lex::unlex(lexer, tok);
	if (len(want) == 0) {
		return tok;
	};
	for (let i = 0z; i < len(want); i += 1) {
		if (tok.0 == want[i]) {
			return tok;
		};
	};
};

// Returns a syntax error if cond is false and void otherwise
export fn synassert(loc: lex::location, cond: bool, msg: str) (void | error) = {
	if (!cond) {
		return syntaxerr(loc, "{}", msg);
	};
};

fn loc_from(lexer: *lex::lexer, start: lex::location) ast::location = {
	return ast::location {
		start = start,
		end = lex::prevloc(lexer),
	};
};

fn mkloc(lexer: *lex::lexer) lex::location = {
	let tok = match (lex::lex(lexer)) {
	case let t: lex::token =>
		yield t;
	case lex::error =>
		return lex::mkloc(lexer);
	};
	lex::unlex(lexer, tok);
	return tok.2;
};
