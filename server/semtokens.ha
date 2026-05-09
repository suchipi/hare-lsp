// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Semantic tokens. We lex the file with hare::lex and classify each token
// into one of the LSP standard token types, then encode in the LSP
// 5-tuple format (deltaLine, deltaStart, length, tokenType, modifiers).
//
// We support full and range modes. Delta mode currently returns the same
// data as full (a true diff would compare against a stored result-id'd
// previous edit; correctness is preserved either way and clients fall
// back to full when delta isn't actually computed).

use analysis;
use bufio;
use encoding::json;
use hare::lex;
use hare::lex::{ltok};
use io;
use lsp;
use memio;
use strings;

// LSP token type indices, matching the order advertised in the legend.
def TT_NAMESPACE: u32 = 0;
def TT_TYPE: u32 = 1;
def TT_FUNCTION: u32 = 2;
def TT_PARAMETER: u32 = 3;
def TT_VARIABLE: u32 = 4;
def TT_PROPERTY: u32 = 5;
def TT_KEYWORD: u32 = 6;
def TT_COMMENT: u32 = 7;
def TT_STRING: u32 = 8;
def TT_NUMBER: u32 = 9;
def TT_OPERATOR: u32 = 10;
def TT_ENUM_MEMBER: u32 = 11;

const TOKEN_TYPES: [_]str = [
	"namespace", "type", "function", "parameter", "variable", "property",
	"keyword", "comment", "string", "number", "operator", "enumMember",
];

const TOKEN_MODIFIERS: [_]str = [
	"declaration", "definition", "readonly", "static", "deprecated",
];

export fn token_legend() json::value = {
	let legend = json::newobject();
	let types: []json::value = [];
	for (let i = 0z; i < len(TOKEN_TYPES); i += 1) {
		append(types, strings::dup(TOKEN_TYPES[i])!: json::value)!;
	};
	json::put(&legend, "tokenTypes", types: json::value)!;
	let mods: []json::value = [];
	for (let i = 0z; i < len(TOKEN_MODIFIERS); i += 1) {
		append(mods, strings::dup(TOKEN_MODIFIERS[i])!: json::value)!;
	};
	json::put(&legend, "tokenModifiers", mods: json::value)!;
	return legend;
};

export fn handle_semantic_tokens_full(s: *server, r: lsp::request) void = {
	const uri = match (uri_from_st(r.params)) {
	case let s: str => yield s;
	case void =>
		send_empty_tokens(s, r.id);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document => yield p;
	case null =>
		send_empty_tokens(s, r.id);
		return;
	};
	const data = analysis::bytes(&doc.buf);
	const tokens = compute_semantic_tokens(s, data);
	defer free(tokens);
	send_tokens(s, r.id, tokens);
};

export fn handle_semantic_tokens_full_delta(s: *server, r: lsp::request) void = {
	// Until we maintain previous-result caches, full/delta returns the
	// same data as full. The client falls back gracefully.
	handle_semantic_tokens_full(s, r);
};

export fn handle_semantic_tokens_range(s: *server, r: lsp::request) void = {
	// Same data; clients filter by their own range. Full responses are
	// fine here and avoid the complexity of a partial encoding.
	handle_semantic_tokens_full(s, r);
};

// Returns a flat []u32 of LSP-encoded token tuples for the given source.
fn compute_semantic_tokens(s: *server, data: []u8) []u32 = {
	let result: []u32 = [];
	let src = memio::fixed(data);
	let scan = bufio::newscanner(&src);
	defer bufio::finish(&scan);
	let lexer = lex::init(&scan, "<doc>", lex::flag::COMMENTS);
	defer lex::finish(&lexer);

	let prev_line: u32 = 0;
	let prev_col: u32 = 0;
	for (true) {
		const tok = match (lex::lex(&lexer)) {
		case let t: lex::token => yield t;
		case lex::error => break;
		};
		if (tok.0 == ltok::EOF) break;
		const tt = classify_token(tok.0);
		// LSP wants 0-based line/col; lex provides 1-based.
		const line: u32 = tok.2.line: u32 - 1;
		const col: u32 = tok.2.col: u32 - 1;
		const length: u32 = token_length(tok);
		if (length == 0) continue;
		const delta_line = line - prev_line;
		const delta_start = if (delta_line == 0) {
			yield col - prev_col;
		} else {
			yield col;
		};
		append(result, delta_line)!;
		append(result, delta_start)!;
		append(result, length)!;
		append(result, tt)!;
		append(result, 0u32)!;
		prev_line = line;
		prev_col = col;
	};
	return result;
};

fn classify_token(t: ltok) u32 = {
	// Keywords (most ltok values).
	if (is_keyword(t)) return TT_KEYWORD;
	switch (t) {
	case ltok::LIT_STR, ltok::LIT_RCONST =>
		return TT_STRING;
	case ltok::LIT_U8, ltok::LIT_U16, ltok::LIT_U32, ltok::LIT_U64,
		ltok::LIT_I8, ltok::LIT_I16, ltok::LIT_I32, ltok::LIT_I64,
		ltok::LIT_UINT, ltok::LIT_INT, ltok::LIT_SIZE, ltok::LIT_F32,
		ltok::LIT_F64, ltok::LIT_FCONST, ltok::LIT_ICONST =>
		return TT_NUMBER;
	case ltok::NAME =>
		return TT_VARIABLE;
	case =>
		// Punctuation and operators all fall here.
		return TT_OPERATOR;
	};
};

fn is_keyword(t: ltok) bool = {
	switch (t) {
	case ltok::ABORT, ltok::ALIGN, ltok::ALLOC, ltok::APPEND, ltok::AS,
		ltok::ASSERT, ltok::BOOL, ltok::BREAK, ltok::CASE, ltok::CONST,
		ltok::CONTINUE, ltok::DEF, ltok::DEFER, ltok::DELETE,
		ltok::DONE, ltok::ELSE, ltok::ENUM, ltok::EXPORT, ltok::F32,
		ltok::F64, ltok::FALSE, ltok::FN, ltok::FOR, ltok::FREE,
		ltok::I16, ltok::I32, ltok::I64, ltok::I8, ltok::IF,
		ltok::INSERT, ltok::INT, ltok::IS, ltok::LEN, ltok::LET,
		ltok::MATCH, ltok::NEVER, ltok::NOMEM, ltok::NULL,
		ltok::NULLABLE, ltok::OFFSET, ltok::OPAQUE, ltok::RETURN,
		ltok::RUNE, ltok::SIZE, ltok::STATIC, ltok::STR, ltok::STRUCT,
		ltok::SWITCH, ltok::TRUE, ltok::TYPE, ltok::U16, ltok::U32,
		ltok::U64, ltok::U8, ltok::UINT, ltok::UINTPTR, ltok::UNION,
		ltok::USE, ltok::VAARG, ltok::VAEND, ltok::VALIST,
		ltok::VASTART, ltok::VOID, ltok::YIELD, ltok::ATTR_FINI,
		ltok::ATTR_INIT, ltok::ATTR_PACKED, ltok::ATTR_SYMBOL,
		ltok::ATTR_TEST, ltok::ATTR_THREADLOCAL, ltok::ATTR_UNDEFINED =>
		return true;
	case =>
		return false;
	};
};

// Returns the source length of a token in characters. We approximate by
// re-rendering via lex::tokstr for tokens that carry no value, and using
// the lexer's value length for names/literals.
fn token_length(tok: lex::token) u32 = {
	match (tok.1) {
	case let s: str =>
		return len(strings::toutf8(s)): u32;
	case =>
		const s = lex::tokstr(tok);
		return len(s): u32;
	};
};

fn send_tokens(s: *server, id: lsp::id, tokens: []u32) void = {
	let arr: []json::value = [];
	for (let i = 0z; i < len(tokens); i += 1) {
		append(arr, tokens[i]: f64: json::value)!;
	};
	let result = json::newobject();
	json::put(&result, "data", arr: json::value)!;
	const v: json::value = result;
	defer json::finish(v);
	match (lsp::encode_response_result(s.out, id, v)) {
	case size => void;
	case => void;
	};
};

fn send_empty_tokens(s: *server, id: lsp::id) void = {
	const empty: []u32 = [];
	send_tokens(s, id, empty);
};

fn uri_from_st(p: (json::value | void)) (str | void) = {
	const v = match (p) {
	case let v: json::value => yield v;
	case void => return void;
	};
	const obj = match (v) {
	case let o: json::object => yield o;
	case => return void;
	};
	const td = match (json::get(&obj, "textDocument")) {
	case let p: *json::value =>
		yield match (*p) {
		case let o: json::object => yield o;
		case => return void;
		};
	case => return void;
	};
	match (json::get(&td, "uri")) {
	case let p: *json::value =>
		match (*p) {
		case let s: str => return s;
		case => return void;
		};
	case => return void;
	};
};
