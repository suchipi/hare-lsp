// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Semantic tokens. We lex the file with hare::lex and classify each token
// into one of the LSP standard token types, then encode in the LSP
// 5-tuple format (deltaLine, deltaStart, length, tokenType, modifiers).
//
// We support full, range, and delta. Delta mode compares the new token
// array against the cached one keyed by previousResultId: the diff is the
// minimal "common prefix / common suffix" splice ([lo..hi_old) replaced by
// [lo..hi_new), encoded as a single semanticTokensEdit). If the client's
// previousResultId no longer matches our cache (e.g. server restart or
// intervening request for a different document), we fall back to /full.
//
// Range mode returns the full document encoded; clients filter locally.
// A true range encoding would only emit the tuples whose absolute line
// falls inside [start, end), but the savings are small for typical files
// and the LSP spec lets the server return the full set.

use analysis;
use bufio;
use encoding::json;
use hare::lex;
use hare::lex::{ltok};
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
	"namespace",
	"type",
	"function",
	"parameter",
	"variable",
	"property",
	"keyword",
	"comment",
	"string",
	"number",
	"operator",
	"enumMember",
];

const TOKEN_MODIFIERS: [_]str = [
	"declaration",
	"definition",
	"readonly",
	"static",
	"deprecated",
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
	case let s: str =>
		yield s;
	case void =>
		send_empty_tokens(s, r.id);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document =>
		yield p;
	case null =>
		send_empty_tokens(s, r.id);
		return;
	};
	const data = analysis::bytes(&doc.buf);
	const tokens = compute_semantic_tokens(s, data);
	// Cache for the next /full/delta call.
	free(doc.prev_tokens);
	let saved: []u32 = alloc([], len(tokens))!;
	append(saved, tokens...)!;
	doc.prev_tokens = saved;
	free(doc.prev_result_id);
	const new_id = next_semantic_id(s);
	doc.prev_result_id = strings::dup(new_id)!;
	defer free(new_id);
	send_tokens_with_id(s, r.id, tokens, new_id);
	free(tokens);
};

// Delta encoding for semantic tokens. If the client's previousResultId
// matches our stored id, we compute a coarse diff and emit a single edit
// covering the differing slice. Otherwise we fall back to /full.
export fn handle_semantic_tokens_full_delta(
	s: *server,
	r: lsp::request,
) void = {
	const obj = match (params_obj_st(r.params)) {
	case let o: json::object =>
		yield o;
	case void =>
		handle_semantic_tokens_full(s, r);
		return;
	};
	const uri = match (uri_from_st(r.params)) {
	case let s: str =>
		yield s;
	case void =>
		send_empty_tokens(s, r.id);
		return;
	};
	const prev_id = match (json::get(&obj, "previousResultId")) {
	case let p: *json::value =>
		yield match (*p) {
		case let s: str =>
			yield s;
		case =>
			handle_semantic_tokens_full(s, r);
			return;
		};
	case =>
		handle_semantic_tokens_full(s, r);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document =>
		yield p;
	case null =>
		send_empty_tokens(s, r.id);
		return;
	};
	if (prev_id != doc.prev_result_id || len(doc.prev_result_id) == 0) {
		handle_semantic_tokens_full(s, r);
		return;
	};

	// Compute the new tokens and diff against prev.
	const data = analysis::bytes(&doc.buf);
	const new_tokens = compute_semantic_tokens(s, data);
	const old_tokens = doc.prev_tokens;
	const (lo, hi_old, hi_new) = diff_bounds(old_tokens, new_tokens);

	// Update the cache.
	free(doc.prev_tokens);
	let saved: []u32 = alloc([], len(new_tokens))!;
	append(saved, new_tokens...)!;
	doc.prev_tokens = saved;
	free(doc.prev_result_id);
	const new_id = next_semantic_id(s);
	doc.prev_result_id = strings::dup(new_id)!;
	defer free(new_id);
	defer free(new_tokens);

	// Build the response.
	let result = json::newobject();
	json::set(&result, "resultId", new_id: json::value)!;
	let edits: []json::value = [];
	if (lo < hi_old || lo < hi_new) {
		let edit = json::newobject();
		json::put(&edit, "start", lo: f64)!;
		json::put(&edit, "deleteCount", (hi_old - lo): f64)!;
		let data_arr: []json::value = [];
		for (let i = lo; i < hi_new; i += 1) {
			append(data_arr, new_tokens[i]: f64: json::value)!;
		};
		json::put(&edit, "data", data_arr: json::value)!;
		append(edits, edit: json::value)!;
	};
	json::put(&result, "edits", edits: json::value)!;
	const v: json::value = result;
	defer json::finish(v);
	match (lsp::encode_response_result(s.out, r.id, v)) {
	case size => void;
	case => void;
	};
};

export fn handle_semantic_tokens_range(s: *server, r: lsp::request) void = {
	// Same data; clients filter by their own range. Full responses are
	// fine here and avoid the complexity of a partial encoding.
	handle_semantic_tokens_full(s, r);
};

// Returns (lo, hi_old, hi_new) such that:
//   - tokens prior to `lo` are identical in both arrays
//   - tokens after `hi_old` (in old) and `hi_new` (in new) are identical
//   - the slice [lo..hi_new) replaces [lo..hi_old) in the old array.
fn diff_bounds(old: []u32, new: []u32) (size, size, size) = {
	const min_len = if (len(old) < len(new)) len(old) else len(new);
	let lo: size = 0;
	for (lo < min_len; lo += 1) {
		if (old[lo] != new[lo]) break;
	};
	// Walk from the back. Stop before lo so we don't overlap.
	let hi_old = len(old);
	let hi_new = len(new);
	for (hi_old > lo && hi_new > lo) {
		if (old[hi_old - 1] != new[hi_new - 1]) break;
		hi_old -= 1;
		hi_new -= 1;
	};
	return (lo, hi_old, hi_new);
};

fn next_semantic_id(s: *server) str = {
	const id = s.next_semantic_result_id;
	s.next_semantic_result_id += 1;
	let buf: [21]u8 = [0...];
	let i = len(buf);
	let v = id;
	if (v == 0) {
		i -= 1;
		buf[i] = '0': u8;
	};
	for (v > 0; v /= 10) {
		i -= 1;
		buf[i] = '0': u8 + (v % 10): u8;
	};
	return strings::dup(strings::fromutf8(buf[i..])!)!;
};

fn params_obj_st(
	p: (json::value | void),
) (json::object | void) = lsp::params_object(p);

// Returns a flat []u32 of LSP-encoded token tuples for the given source.
fn compute_semantic_tokens(s: *server, data: []u8) []u32 = {
	let result: []u32 = [];
	let src = memio::fixed(data);
	let scan = bufio::newscanner(&src);
	defer bufio::finish(&scan);
	let lexer = lex::init(&scan, "<doc>", lex::flag::COMMENTS);
	defer lex::finish(&lexer);

	// hare::lex reports `tok.2.col` as a rune count with tab expansion
	// (each tab advances to the next multiple of 8) and `tok.2.off` as
	// a rune index. LSP wants positions in the negotiated encoding's
	// code units, so translate every token's rune offset into a byte
	// offset and run it through byte_to_position.
	const r2b = analysis::build_rune_to_byte_table(data);
	defer free(r2b);
	const line_index = analysis::build_line_index(data);
	defer free(line_index);
	const enc = position_encoding(s);

	let prev_line: u32 = 0;
	let prev_col: u32 = 0;
	for (true) {
		const tok = match (lex::lex(&lexer)) {
		case let t: lex::token =>
			yield t;
		case lex::error =>
			break;
		};
		if (tok.0 == ltok::EOF) break;
		const tt = classify_token(tok.0);
		const rune_off = tok.2.off: size;
		const byte_off = if (rune_off < len(r2b)) r2b[rune_off] else len(data);
		const pos = analysis::byte_to_position(data, line_index, enc, byte_off);
		const line: u32 = pos.line;
		const col: u32 = pos.character;
		// LSP semantic tokens can't be multiline (per spec), so clip
		// the token's source span at the next newline if one falls
		// inside it (e.g. backtick raw strings with embedded newlines).
		const byte_end_raw = byte_off + token_byte_len(data, byte_off, tok);
		const byte_end = clip_to_line_end(data, byte_off, byte_end_raw);
		const length: u32 = analysis::count_units(data[byte_off..byte_end], enc): u32;
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
	case ltok::LIT_U8,
	ltok::LIT_U16,
	ltok::LIT_U32,
	ltok::LIT_U64,
	ltok::LIT_I8,
	ltok::LIT_I16,
	ltok::LIT_I32,
	ltok::LIT_I64,
	ltok::LIT_UINT,
	ltok::LIT_INT,
	ltok::LIT_SIZE,
	ltok::LIT_F32,
	ltok::LIT_F64,
	ltok::LIT_FCONST,
	ltok::LIT_ICONST =>
		return TT_NUMBER;
	case ltok::NAME =>
		return TT_VARIABLE;
	// Punctuation and operators all fall here.

	case =>
		return TT_OPERATOR;
	};
};

fn is_keyword(t: ltok) bool = {
	switch (t) {
	case ltok::ABORT,
	ltok::ALIGN,
	ltok::ALLOC,
	ltok::APPEND,
	ltok::AS,
	ltok::ASSERT,
	ltok::BOOL,
	ltok::BREAK,
	ltok::CASE,
	ltok::CONST,
	ltok::CONTINUE,
	ltok::DEF,
	ltok::DEFER,
	ltok::DELETE,
	ltok::DONE,
	ltok::ELSE,
	ltok::ENUM,
	ltok::EXPORT,
	ltok::F32,
	ltok::F64,
	ltok::FALSE,
	ltok::FN,
	ltok::FOR,
	ltok::FREE,
	ltok::I16,
	ltok::I32,
	ltok::I64,
	ltok::I8,
	ltok::IF,
	ltok::INSERT,
	ltok::INT,
	ltok::IS,
	ltok::LEN,
	ltok::LET,
	ltok::MATCH,
	ltok::NEVER,
	ltok::NOMEM,
	ltok::NULL,
	ltok::NULLABLE,
	ltok::OFFSET,
	ltok::OPAQUE,
	ltok::RETURN,
	ltok::RUNE,
	ltok::SIZE,
	ltok::STATIC,
	ltok::STR,
	ltok::STRUCT,
	ltok::SWITCH,
	ltok::TRUE,
	ltok::TYPE,
	ltok::U16,
	ltok::U32,
	ltok::U64,
	ltok::U8,
	ltok::UINT,
	ltok::UINTPTR,
	ltok::UNION,
	ltok::USE,
	ltok::VAARG,
	ltok::VAEND,
	ltok::VALIST,
	ltok::VASTART,
	ltok::VOID,
	ltok::YIELD,
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

// Returns the byte length of the source representation of `tok` starting
// at `byte_off` in `data`. Walks source bytes rather than relying on
// `tok.1` (which holds the parsed value — escape-stripped string content
// for LIT_STR, a u64 for integer constants, a rune for LIT_RCONST) or
// `lex::tokstr` (which returns canonical names like "u8" or "iconst" for
// literal tokens, not the source spelling).
fn token_byte_len(data: []u8, byte_off: size, tok: lex::token) size = {
	if (byte_off >= len(data)) return 0;
	const b = data[byte_off];
	// String / rune / raw-string literals are delimited; reuse the
	// shared scanner that already handles escape sequences.
	if (b == '"': u8 || b == '\'': u8 || b == '`': u8) {
		return analysis::token_skip_noncode(data, byte_off, len(data)) - byte_off;
	};
	// Numeric literals: walk forward while the byte plausibly belongs.
	// Covers hex/binary/octal digits, suffix letters (u8, f32, etc.),
	// `.` for floats, and `e±N` / `p±N` exponent signs.
	if (is_numeric_literal_kind(tok.0)) {
		return scan_numeric_literal(data, byte_off);
	};
	// Names, keywords, operators, attributes: `lex::tokstr` returns
	// the canonical spelling, which is byte-identical to source.
	const s = lex::tokstr(tok);
	const slen = len(strings::toutf8(s));
	if (byte_off + slen > len(data)) return len(data) - byte_off;
	return slen;
};

fn is_numeric_literal_kind(t: ltok) bool = {
	switch (t) {
	case ltok::LIT_U8,
	ltok::LIT_U16,
	ltok::LIT_U32,
	ltok::LIT_U64,
	ltok::LIT_I8,
	ltok::LIT_I16,
	ltok::LIT_I32,
	ltok::LIT_I64,
	ltok::LIT_UINT,
	ltok::LIT_INT,
	ltok::LIT_SIZE,
	ltok::LIT_F32,
	ltok::LIT_F64,
	ltok::LIT_ICONST,
	ltok::LIT_FCONST =>
		return true;
	case =>
		return false;
	};
};

fn scan_numeric_literal(data: []u8, byte_off: size) size = {
	let end = byte_off;
	for (end < len(data)) {
		const c = data[end];
		if (c >= '0': u8 && c <= '9': u8 || c >= 'a': u8 && c <= 'z': u8 ||
				c >= 'A': u8 && c <= 'Z': u8 ||
				c == '_': u8) {
			end += 1;
			continue;
		};
		if (c == '.': u8) {
			// Accept `.` only when it's a float separator (next byte
			// is a digit). Without this guard, `0..10` ranges and
			// `1.method` field access get swallowed past the literal.
			if (end + 1 < len(data) && data[end + 1] >= '0': u8 &&
					data[end + 1] <= '9': u8) {
				end += 1;
				continue;
			};
			break;
		};
		if ((c == '+': u8 || c == '-': u8) && end > byte_off) {
			const prev = data[end - 1];
			if (prev == 'e': u8 || prev == 'E': u8 || prev == 'p': u8 ||
					prev == 'P': u8) {
				end += 1;
				continue;
			};
		};
		break;
	};
	if (end == byte_off) return 1;
	return end - byte_off;
};

// LSP semantic tokens can't span newlines. Returns `byte_end` if no
// newline falls inside [byte_off, byte_end); otherwise the offset of
// the newline byte.
fn clip_to_line_end(data: []u8, byte_off: size, byte_end: size) size = {
	const end = if (byte_end > len(data)) len(data) else byte_end;
	for (let i = byte_off; i < end; i += 1) {
		if (data[i] == '\n': u8) return i;
	};
	return end;
};

fn send_tokens(s: *server, id: lsp::id, tokens: []u32) void = {
	send_tokens_with_id(s, id, tokens, "");
};

fn send_tokens_with_id(
	s: *server,
	id: lsp::id,
	tokens: []u32,
	result_id: str,
) void = {
	let arr: []json::value = [];
	for (let i = 0z; i < len(tokens); i += 1) {
		append(arr, tokens[i]: f64: json::value)!;
	};
	let result = json::newobject();
	if (len(result_id) > 0) {
		json::set(&result, "resultId", result_id: json::value)!;
	};
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
	case let v: json::value =>
		yield v;
	case void =>
		return void;
	};
	const obj = match (v) {
	case let o: json::object =>
		yield o;
	case =>
		return void;
	};
	const td = match (json::get(&obj, "textDocument")) {
	case let p: *json::value =>
		yield match (*p) {
		case let o: json::object =>
			yield o;
		case =>
			return void;
		};
	case =>
		return void;
	};
	match (json::get(&td, "uri")) {
	case let p: *json::value =>
		match (*p) {
		case let s: str =>
			return s;
		case =>
			return void;
		};
	case =>
		return void;
	};
};
