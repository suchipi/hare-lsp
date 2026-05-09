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
use fmt;
use hare::ast;
use hare::unparse;
use io;
use lsp;
use memio;
use strings;

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
	let pr = analysis::parse_recover(data, uri);
	defer analysis::finish_parse_result(&pr);

	// If parse had errors, we don't attempt formatting; better to leave
	// the user's source alone than emit a broken rewrite.
	if (len(pr.errors) > 0) {
		send_array_fmt(s, r.id, []);
		return;
	};

	let buf = memio::dynamic();
	defer io::close(&buf)!;
	match (unparse::subunit(&buf, &unparse::syn_wrap, pr.subunit)) {
	case size => void;
	case =>
		send_array_fmt(s, r.id, []);
		return;
	};
	const formatted_raw = memio::string(&buf)!;
	const formatted_str = apply_indent_style(s, formatted_raw);
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
	let pr = analysis::parse_recover(data, uri);
	defer analysis::finish_parse_result(&pr);
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

	// Unparse the run of selected decls.
	let buf = memio::dynamic();
	defer io::close(&buf)!;
	for (let i = first_idx: size; i <= last_idx: size; i += 1) {
		match (unparse::decl(&buf, &unparse::syn_wrap, &pr.subunit.decls[i])) {
		case size => void;
		case =>
			send_array_fmt(s, r.id, []);
			return;
		};
		fmt::fprint(&buf, ";")!;
		if (i < last_idx: size) {
			fmt::fprint(&buf, "\n\n")!;
		} else {
			fmt::fprint(&buf, "\n")!;
		};
	};
	const formatted_str = memio::string(&buf)!;
	const formatted_str_with_indent = apply_indent_style(s, formatted_str);
	defer if (formatted_str_with_indent != formatted_str) free(formatted_str_with_indent);

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
	// Conservative: emit no edits. On-type reformatting that doesn't
	// preserve cursor intent leads to user frustration; we'd rather
	// require an explicit format request than mis-correct the user's
	// in-progress edit.
	send_array_fmt(s, r.id, []);
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

fn params_obj_fmt(p: (json::value | void)) (json::object | void) = {
	const v = match (p) {
	case let v: json::value => yield v;
	case void => return void;
	};
	return match (v) {
	case let o: json::object => yield o;
	case => yield void;
	};
};

// Post-processes unparse output to honour config.format_indent_style.
// hare::unparse always emits tabs; if the user wants spaces, expand the
// leading tabs on each line into config.format_indent_width spaces.
//
// Returns the input string unchanged when style == TAB, otherwise a
// freshly-allocated string the caller must free if it differs from the
// input.
export fn apply_indent_style(s: *server, source: str) str = {
	if (s.config.format_indent_style == indent_style::TAB) return source;
	const width = s.config.format_indent_width: size;
	const src = strings::toutf8(source);
	let out: []u8 = alloc([], len(src))!;
	let at_line_start = true;
	for (let i = 0z; i < len(src); i += 1) {
		const b = src[i];
		if (at_line_start && b == '\t': u8) {
			for (let j = 0z; j < width; j += 1) {
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
