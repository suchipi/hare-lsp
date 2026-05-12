// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Document formatting. The Hare standard library exposes hare::unparse,
// which round-trips an AST back to source. We use it directly for full-
// document formatting, and fall back to AST decl-level unparsing for
// range formatting.
//
// On-type formatting is conservative: we only return edits when the user
// just typed '}' or ';' at the start of a line (idiomatic re-indent
// triggers); other on-type events return no edits.

use analysis;
use encoding::json;
use hare::lex;
use lsp;
use memio;
use strings;

// Reported by [[format_source]] when the source can't be reformatted -
// either the recovering parser surfaced a diagnostic, or pretty-printing
// itself failed. `message` is owned by the error value; callers free it
// via [[format_error_finish]] after consuming the error.
export type format_error = !struct {
	location: (lex::location | void),
	message: str,
};

export fn format_error_finish(e: *format_error) void = {
	free(e.message);
};

// Formats `data` end-to-end and returns the reformatted source as a
// freshly-allocated string the caller owns. `path` is an opaque label
// used in parser diagnostics.
//
// Output is always tab-indented at column 0; callers that want a
// space-indent variant should pass the result through
// [[apply_indent_style]]. If parsing produces any diagnostics we refuse
// to format and return the first one - reformatting partially-parsed
// source would rewrite over the user's in-flight edits.
export fn format_source(data: []u8, path: str) (str | format_error) = {
	let pr = analysis::parse_recover(data, path);
	defer analysis::finish_parse_result(&pr);
	if (len(pr.errors) > 0) {
		const e = &pr.errors[0];
		return format_error {
			location = e.location,
			message = strings::dup(e.message)!,
		};
	};

	const cs = collect_comments(data);
	defer finish_comments(cs);
	const bl = collect_blank_lines(data);
	defer free(bl);
	let cursor = comment_cursor { comments = cs, pos = 0 };
	let d = build_subunit_doc(&pr.subunit, &cursor, bl, data);
	defer doc_finish(&d);

	let buf = memio::dynamic();
	defer lsp::safe_close(&buf);
	match (pretty(&buf, &d, 80, 0)) {
	case size => void;
	case =>
		return format_error {
			location = void,
			message = strings::dup("pretty-printer failed")!,
		};
	};
	return strings::dup(memio::string(&buf)!)!;
};

export fn handle_formatting(s: *server, r: lsp::request) void = {
	const uri = match (uri_from_request(r.params)) {
	case let s: str => yield s;
	case void =>
		send_array_fmt(s, r.id, []);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document => yield p;
	case null =>
		send_array_fmt(s, r.id, []);
		return;
	};
	const data = analysis::bytes(&doc.buf);
	const cache = parse_of(doc);
	const pr = &cache.pr;

	// If parse had errors, we don't attempt formatting; better to leave
	// the user's source alone than emit a broken rewrite.
	if (len(pr.errors) > 0) {
		send_array_fmt(s, r.id, []);
		return;
	};

	// Build the doc tree from the AST + comment cursor.
	const cs = collect_comments(data);
	defer finish_comments(cs);
	const bl = collect_blank_lines(data);
	defer free(bl);
	let cursor = comment_cursor { comments = cs, pos = 0 };
	let d = build_subunit_doc(&pr.subunit, &cursor, bl, data);
	defer doc_finish(&d);

	let buf = memio::dynamic();
	defer lsp::safe_close(&buf);
	match (pretty(&buf, &d, 80, 0)) {
	case size => void;
	case =>
		send_array_fmt(s, r.id, []);
		return;
	};
	const formatted_raw = memio::string(&buf)!;
	const formatted_str = apply_indent_style(formatted_raw,
		s.config.format_indent_style, s.config.format_indent_width);
	defer if (formatted_str != formatted_raw) free(formatted_str);
	const formatted = strings::toutf8(formatted_str);

	// If the formatted output equals the input, no edits needed.
	if (bytes_equal(formatted, data)) {
		send_array_fmt(s, r.id, []);
		return;
	};

	// Build a single full-document text edit.
	const enc = position_encoding(s);
	const start_pos = analysis::byte_to_position(data, doc.buf.line_index, enc, 0);
	const end_pos = analysis::byte_to_position(data, doc.buf.line_index, enc, len(data));
	let edit = json::newobject();
	let r_obj = json::newobject();
	let s_obj = json::newobject();
	json::put(&s_obj, "line", start_pos.line: f64)!;
	json::put(&s_obj, "character", start_pos.character: f64)!;
	let e_obj = json::newobject();
	json::put(&e_obj, "line", end_pos.line: f64)!;
	json::put(&e_obj, "character", end_pos.character: f64)!;
	json::put(&r_obj, "start", s_obj)!;
	json::put(&r_obj, "end", e_obj)!;
	json::put(&edit, "range", r_obj)!;
	json::set(&edit, "newText", formatted_str: json::value)!;

	let arr: []json::value = [];
	append(arr, edit: json::value)!;
	send_array_fmt(s, r.id, arr);
};

export fn handle_range_formatting(s: *server, r: lsp::request) void = {
	const obj = match (params_obj_fmt(r.params)) {
	case let o: json::object => yield o;
	case void =>
		send_array_fmt(s, r.id, []);
		return;
	};
	const uri = match (uri_from_request(r.params)) {
	case let s: str => yield s;
	case void =>
		send_array_fmt(s, r.id, []);
		return;
	};
	const range_v = match (json::get(&obj, "range")) {
	case let p: *json::value => yield *p;
	case =>
		send_array_fmt(s, r.id, []);
		return;
	};
	const range = match (lsp::decode_range(range_v)) {
	case let r: lsp::range => yield r;
	case lsp::bad_message =>
		send_array_fmt(s, r.id, []);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document => yield p;
	case null =>
		send_array_fmt(s, r.id, []);
		return;
	};
	const data = analysis::bytes(&doc.buf);
	const cache = parse_of(doc);
	const pr = &cache.pr;
	if (len(pr.errors) > 0) {
		send_array_fmt(s, r.id, []);
		return;
	};

	// Convert range to byte offsets.
	const enc = position_encoding(s);
	const range_start = analysis::position_to_byte(data, doc.buf.line_index, enc,
		analysis::position {
			line = range.start.line, character = range.start.character,
		});
	const range_end = analysis::position_to_byte(data, doc.buf.line_index, enc,
		analysis::position {
			line = range.end.line, character = range.end.character,
		});

	// Empty range — nothing to format.
	if (range_start >= range_end) {
		send_array_fmt(s, r.id, []);
		return;
	};
	// Pick all top-level decls that overlap [range_start, range_end).
	// Two intervals [a,b) and [c,d) overlap iff a < d && c < b.
	let first_idx: int = -1;
	let last_idx: int = -1;
	for (let i = 0z; i < len(pr.subunit.decls); i += 1) {
		const d = &pr.subunit.decls[i];
		const ds = d.loc.start.off: size;
		const de = d.loc.end.off: size;
		if (!(ds < range_end && range_start < de)) continue;
		if (first_idx < 0) first_idx = i: int;
		last_idx = i: int;
	};
	if (first_idx < 0) {
		send_array_fmt(s, r.id, []);
		return;
	};

	// Format the run of selected decls with comment interleaving.
	const decl_range_start = pr.subunit.decls[first_idx: size].loc.start.off: size;
	const decl_range_end = pr.subunit.decls[last_idx: size].loc.end.off: size;
	const cs = collect_comments(data);
	defer finish_comments(cs);
	const bl = collect_blank_lines(data);
	defer free(bl);
	let cursor = comment_cursor { comments = cs, pos = 0 };
	// Skip past any comments before the first selected decl — those
	// don't belong in the range edit.
	const _ = pop_before(&cursor, decl_range_start);

	let d = build_decls_range_doc(&pr.subunit, first_idx: size,
		last_idx: size, &cursor, bl, data);
	defer doc_finish(&d);

	let buf = memio::dynamic();
	defer lsp::safe_close(&buf);
	match (pretty(&buf, &d, 80, 0)) {
	case size => void;
	case =>
		send_array_fmt(s, r.id, []);
		return;
	};
	const formatted_str = memio::string(&buf)!;
	const formatted_str_with_indent = apply_indent_style(formatted_str,
		s.config.format_indent_style, s.config.format_indent_width);
	defer if (formatted_str_with_indent != formatted_str) free(formatted_str_with_indent);
	_ = decl_range_end; // silence unused warning if any

	const replace_start = pr.subunit.decls[first_idx: size].loc.start.off: size;
	const replace_end = pr.subunit.decls[last_idx: size].loc.end.off: size;
	const start_pos = analysis::byte_to_position(data, doc.buf.line_index, enc, replace_start);
	const end_pos = analysis::byte_to_position(data, doc.buf.line_index, enc, replace_end);

	let edit = json::newobject();
	let r_obj = json::newobject();
	let s_obj = json::newobject();
	json::put(&s_obj, "line", start_pos.line: f64)!;
	json::put(&s_obj, "character", start_pos.character: f64)!;
	let e_obj = json::newobject();
	json::put(&e_obj, "line", end_pos.line: f64)!;
	json::put(&e_obj, "character", end_pos.character: f64)!;
	json::put(&r_obj, "start", s_obj)!;
	json::put(&r_obj, "end", e_obj)!;
	json::put(&edit, "range", r_obj)!;
	json::set(&edit, "newText", formatted_str_with_indent: json::value)!;

	let arr: []json::value = [];
	append(arr, edit: json::value)!;
	send_array_fmt(s, r.id, arr);
};

export fn handle_on_type_formatting(s: *server, r: lsp::request) void = {
	const obj = match (params_obj_fmt(r.params)) {
	case let o: json::object => yield o;
	case void =>
		send_array_fmt(s, r.id, []);
		return;
	};
	const uri = match (uri_from_request(r.params)) {
	case let s: str => yield s;
	case void =>
		send_array_fmt(s, r.id, []);
		return;
	};
	const ch = match (json::get(&obj, "ch")) {
	case let p: *json::value =>
		yield match (*p) {
		case let s: str => yield s;
		case =>
			send_array_fmt(s, r.id, []);
			return;
		};
	case =>
		send_array_fmt(s, r.id, []);
		return;
	};
	// Only `}` triggers reindent; `;` doesn't change indent in Hare.
	if (ch != "}") {
		send_array_fmt(s, r.id, []);
		return;
	};
	const pos_v = match (json::get(&obj, "position")) {
	case let p: *json::value => yield *p;
	case =>
		send_array_fmt(s, r.id, []);
		return;
	};
	const pos = match (lsp::decode_position(pos_v)) {
	case let p: lsp::position => yield p;
	case lsp::bad_message =>
		send_array_fmt(s, r.id, []);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document => yield p;
	case null =>
		send_array_fmt(s, r.id, []);
		return;
	};
	const data = analysis::bytes(&doc.buf);
	const enc = position_encoding(s);
	const cursor_off = analysis::position_to_byte(data, doc.buf.line_index, enc,
		analysis::position { line = pos.line, character = pos.character });
	if (cursor_off == 0 || cursor_off > len(data)) {
		send_array_fmt(s, r.id, []);
		return;
	};

	// The character that triggered us is at cursor_off - 1.
	const close_at = cursor_off - 1;
	if (close_at >= len(data) || data[close_at] != '}': u8) {
		send_array_fmt(s, r.id, []);
		return;
	};

	// Find the start of the line containing the `}`.
	let line_start = close_at;
	for (line_start > 0 && data[line_start - 1] != '\n': u8; line_start -= 1) void;

	// Count current leading whitespace on the line.
	let cur_ws_end = line_start;
	for (cur_ws_end < len(data); cur_ws_end += 1) {
		const b = data[cur_ws_end];
		if (b != ' ': u8 && b != '\t': u8) break;
	};

	// The line should be only whitespace + `}` (possibly followed by `;`
	// or other characters; we still reindent the leading whitespace if
	// the `}` is the first non-whitespace character on the line).
	if (cur_ws_end != close_at) {
		send_array_fmt(s, r.id, []);
		return;
	};

	// Compute the expected depth at `close_at` by lexing from the start
	// of the buffer up to that position. Each `{` token increments the
	// depth, each `}` decrements. The expected indent for the closing
	// brace is `depth - 1` (one less than the depth of the contents
	// inside the block).
	const depth = brace_depth_before(data, close_at);
	if (depth == 0) {
		send_array_fmt(s, r.id, []);
		return;
	};
	const expected_depth = depth - 1;

	// Build the new indent string.
	let new_indent: []u8 = [];
	defer free(new_indent);
	switch (s.config.format_indent_style) {
	case indent_style::TAB =>
		for (let i = 0u32; i < expected_depth; i += 1) {
			append(new_indent, '\t': u8)!;
		};
	case indent_style::SPACE =>
		const w = s.config.format_indent_width;
		for (let i = 0u32; i < expected_depth * w; i += 1) {
			append(new_indent, ' ': u8)!;
		};
	};

	// Compare with the current indent; if equal, no edit needed.
	const cur_ws = data[line_start..cur_ws_end];
	if (slices_equal(cur_ws, new_indent)) {
		send_array_fmt(s, r.id, []);
		return;
	};

	// Build a TextEdit replacing the leading whitespace.
	const start_pos = analysis::byte_to_position(data, doc.buf.line_index, enc, line_start);
	const end_pos = analysis::byte_to_position(data, doc.buf.line_index, enc, cur_ws_end);
	const new_text = strings::fromutf8(new_indent)!;

	let edit = json::newobject();
	let r_obj = json::newobject();
	let s_obj = json::newobject();
	json::put(&s_obj, "line", start_pos.line: f64)!;
	json::put(&s_obj, "character", start_pos.character: f64)!;
	let e_obj = json::newobject();
	json::put(&e_obj, "line", end_pos.line: f64)!;
	json::put(&e_obj, "character", end_pos.character: f64)!;
	json::put(&r_obj, "start", s_obj)!;
	json::put(&r_obj, "end", e_obj)!;
	json::put(&edit, "range", r_obj)!;
	json::set(&edit, "newText", new_text: json::value)!;
	let arr: []json::value = [];
	append(arr, edit: json::value)!;
	send_array_fmt(s, r.id, arr);
};

// Returns the brace nesting depth at byte offset `off`. Manual scan that
// skips over strings, runes, raw strings, line comments, and block
// comments so braces inside any of those don't fool us. Avoids hare::lex
// here because the stdlib lexer can hit double-unlex aborts when fed a
// truncated buffer mid-token.
fn brace_depth_before(data: []u8, off: size) u32 = {
	let depth: u32 = 0;
	const limit = if (off > len(data)) len(data) else off;
	let i = 0z;
	for (i < limit) {
		const after = analysis::token_skip_noncode(data, i, limit);
		if (after > i) {
			i = after;
			continue;
		};
		switch (data[i]) {
		case '{': u8 =>
			depth += 1;
		case '}': u8 =>
			if (depth > 0) depth -= 1;
		case => void;
		};
		i += 1;
	};
	return depth;
};

fn slices_equal(a: []u8, b: []u8) bool = {
	if (len(a) != len(b)) return false;
	for (let i = 0z; i < len(a); i += 1) {
		if (a[i] != b[i]) return false;
	};
	return true;
};

fn bytes_equal(a: []u8, b: []u8) bool = {
	if (len(a) != len(b)) return false;
	for (let i = 0z; i < len(a); i += 1) {
		if (a[i] != b[i]) return false;
	};
	return true;
};

fn uri_from_request(p: (json::value | void)) (str | void) = {
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

fn send_array_fmt(s: *server, id: lsp::id, arr: []json::value) void = {
	const v: json::value = arr;
	defer json::finish(v);
	match (lsp::encode_response_result(s.out, id, v)) {
	case size => void;
	case => void;
	};
};

fn params_obj_fmt(p: (json::value | void)) (json::object | void) =
	lsp::params_object(p);

// Post-processes pretty-printer output to honour an indent style.
// `pretty` always emits tabs; when `style == SPACE`, expand the leading
// tabs on each line into `width` spaces.
//
// Returns the input string unchanged when style == TAB, otherwise a
// freshly-allocated string the caller must free if it differs from the
// input.
export fn apply_indent_style(source: str, style: indent_style, width: u32) str = {
	if (style == indent_style::TAB) return source;
	const w = width: size;
	const src = strings::toutf8(source);
	let out: []u8 = alloc([], len(src))!;
	let at_line_start = true;
	for (let i = 0z; i < len(src); i += 1) {
		const b = src[i];
		if (at_line_start && b == '\t': u8) {
			for (let j = 0z; j < w; j += 1) {
				append(out, ' ': u8)!;
			};
			continue;
		};
		if (b != ' ': u8 && b != '\t': u8) {
			at_line_start = false;
		};
		if (b == '\n': u8) {
			at_line_start = true;
		};
		append(out, b)!;
	};
	const result = strings::fromutf8(out)!;
	const dup = strings::dup(result)!;
	free(out);
	return dup;
};
