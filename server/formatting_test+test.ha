// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use bufio;
use bytes;
use encoding::json;
use io;
use lsp;
use memio;
use strconv;
use strings;

fn fmt_test_server(

) (server, *bufio::scanner, *memio::stream, *memio::stream) = {
	let in_buf = alloc(memio::fixed([]))!;
	let scan = alloc(bufio::newscanner(in_buf))!;
	let out = alloc(memio::dynamic())!;
	let s = new(scan, out, void);
	return (s, scan, in_buf, out);
};

fn fmt_test_cleanup(
	s: *server,
	scan: *bufio::scanner,
	in_buf: *memio::stream,
	out: *memio::stream,
) void = {
	finish(s);
	bufio::finish(scan);
	free(scan);
	free(in_buf);
	io::close(out)!;
	free(out);
};

fn fmt_open(s: *server, uri: str, text: str) void = {
	const open =
		strings::concat(`{"textDocument":{"uri":"`, uri,
			`","languageId":"hare","version":1,"text":"`, text, `"}}`)!;
	defer free(open);
	let pv = json::loadstr(open)!;
	const n = lsp::notification {
		method = strings::dup("textDocument/didOpen")!,
		params = pv,
	};
	defer {
		free(n.method);
		json::finish(pv);
	};
	handle_did_open(s, n);
};

fn fmt_skip_to_response(out: *memio::stream, request_id: f64) json::value = {
	const data = memio::buffer(out);
	let off = 0z;
	for (off < len(data)) {
		const sep = bytes::index(data[off..], strings::toutf8("\r\n\r\n")) as size;
		const headers = strings::fromutf8(data[off..off + sep])!;
		let length: size = 0;
		const lines = strings::split(headers, "\r\n")!;
		defer free(lines);
		for (let i = 0z; i < len(lines); i += 1) {
			const idx = strings::index(lines[i], ':') as size;
			const name = strings::sub(lines[i], 0, idx);
			const value = strings::trim(strings::sub(lines[i], idx + 1, strings::end));
			if (name == "Content-Length") {
				length = strconv::stoz(value)!;
			};
		};
		const body_start = off + sep + 4;
		const body = data[body_start..body_start + length];
		const v = json::loadstr(strings::fromutf8(body)!)!;
		const obj = v as json::object;
		match (json::get(&obj, "id")) {
		case let p: *json::value =>
			match (*p) {
			case let f: f64 =>
				if (f == request_id) return v;
			case => void;
			};
		case => void;
		};
		json::finish(v);
		off = body_start + length;
	};
	abort("response not found");
};

// Round-trips a file with leading and inline comments through
// handle_formatting; the resulting newText must contain every comment
// from the input. Regression for the data-loss bug where
// `unparse::subunit` silently dropped non-doc comments.
@test fn formatting_preserves_inline_comments() void = {
	let (s, scan, in_buf, out) = fmt_test_server();
	defer fmt_test_cleanup(&s, scan, in_buf, out);
	// fmt_open splices `src` into a JSON string literal; newlines and
	// tabs must be JSON-escaped (\\n / \\t) so the JSON parser decodes
	// them, not raw characters which would terminate the literal.
	const src =
		"// SPDX-License-Identifier: MPL-2.0\\n// (c) test authors\\n\\nuse io;\\n\\nexport fn main() void = {\\n\\t// note one\\n\\tlet x = 1;\\n\\tlet y = 2;\\n\\t// note two\\n\\tlet z = x + y;\\n};\\n";
	fmt_open(&s, "file:///cmt.ha", src);

	const params =
		`{"textDocument":{"uri":"file:///cmt.ha"},"options":{"tabSize":8,"insertSpaces":false}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 2.0,
		method = strings::dup("textDocument/formatting")!,
		params = pv,
	};
	defer free(r.method);
	handle_formatting(&s, r);
	const v = fmt_skip_to_response(out, 2.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	// No edit = source is already canonical, which trivially preserves
	// every comment. The regression target is an edit that drops a
	// comment, not the absence of an edit.
	if (len(result) == 0) return;
	const edit = result[0] as json::object;
	const new_text = *(json::get(&edit, "newText") as *json::value) as str;

	assert(strings::contains(new_text, "SPDX-License-Identifier"));
	assert(strings::contains(new_text, "(c) test authors"));
	assert(strings::contains(new_text, "note one"));
	assert(strings::contains(new_text, "note two"));
};

@test fn range_formatting_edits_only_selected_decl() void = {
	let (s, scan, in_buf, out) = fmt_test_server();
	defer fmt_test_cleanup(&s, scan, in_buf, out);
	// Three decls: a, b, c. We'll request range formatting on b only.
	fmt_open(&s, "file:///x.ha",
		"fn a() void = void;\\n\\nfn b() void = void;\\n\\nfn c() void = void;\\n");

	// b spans line 2 (0-based) approximately.
	const params =
		`{"textDocument":{"uri":"file:///x.ha"},"range":{"start":{"line":2,"character":0},"end":{"line":2,"character":19}},"options":{"tabSize":8,"insertSpaces":false}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 1.0,
		method = strings::dup("textDocument/rangeFormatting")!,
		params = pv,
	};
	defer free(r.method);
	handle_range_formatting(&s, r);
	const v = fmt_skip_to_response(out, 1.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	if (len(result) > 0) {
		// The edit must start on line 2 (where decl b lives) and must
		// not start on line 0 (decl a) or line 4 (decl c). Hare's
		// loc.end may point into the trailing whitespace before the
		// next decl, so we don't assert on the end line precisely.
		const e0 = result[0] as json::object;
		const range = *(json::get(&e0, "range") as *json::value) as json::object;
		const start = *(json::get(&range, "start") as *json::value) as json::object;
		assert(*(json::get(&start, "line") as *json::value) as f64 == 2.0);
		const end = *(json::get(&range, "end") as *json::value) as json::object;
		const end_line = *(json::get(&end, "line") as *json::value) as f64;
		assert(end_line >= 2.0 && end_line <= 4.0);
	};
};

@test fn range_formatting_no_overlap_returns_empty() void = {
	let (s, scan, in_buf, out) = fmt_test_server();
	defer fmt_test_cleanup(&s, scan, in_buf, out);
	fmt_open(&s, "file:///x.ha", "fn a() void = void;\\n\\n\\n\\n\\n");

	// Range on line 4 (a blank line below the decl).
	const params =
		`{"textDocument":{"uri":"file:///x.ha"},"range":{"start":{"line":4,"character":0},"end":{"line":4,"character":0}},"options":{"tabSize":8,"insertSpaces":false}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 2.0,
		method = strings::dup("textDocument/rangeFormatting")!,
		params = pv,
	};
	defer free(r.method);
	handle_range_formatting(&s, r);
	const v = fmt_skip_to_response(out, 2.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	assert(len(result) == 0);
};

@test fn apply_indent_style_tab_passes_through() void = {
	const input = "fn x() void = {\n\treturn;\n};";
	const r = apply_indent_style(input, indent_style::TAB, 8);
	assert(r == input);
};

@test fn apply_indent_style_space_expands_leading_tabs() void = {
	const input = "fn x() void = {\n\treturn;\n};";
	const r = apply_indent_style(input, indent_style::SPACE, 4);
	defer free(r);
	assert(r == "fn x() void = {\n    return;\n};");
};

@test fn apply_indent_style_handles_multiple_tabs() void = {
	const input = "if (x) {\n\t\tfoo();\n};";
	const r = apply_indent_style(input, indent_style::SPACE, 2);
	defer free(r);
	assert(r == "if (x) {\n    foo();\n};");
};

@test fn apply_indent_style_leaves_tabs_inside_strings_alone() void = {
	// A tab after a non-whitespace byte (e.g. inside a string literal)
	// should not be expanded.
	const input = "let s = \"a\tb\";";
	const r = apply_indent_style(input, indent_style::SPACE, 4);
	defer free(r);
	assert(r == "let s = \"a\tb\";");
};

@test fn on_type_formatting_reindents_close_brace() void = {
	let (s, scan, in_buf, out) = fmt_test_server();
	defer fmt_test_cleanup(&s, scan, in_buf, out);
	// `}` on line 1 with 4 leading spaces; expected indent (depth 0) is empty.
	fmt_open(&s, "file:///x.ha", "fn x() void = {\\n    }\\n");

	const params =
		`{"textDocument":{"uri":"file:///x.ha"},"position":{"line":1,"character":5},"ch":"}","options":{"tabSize":8,"insertSpaces":false}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 50.0,
		method = strings::dup("textDocument/onTypeFormatting")!,
		params = pv,
	};
	defer free(r.method);
	handle_on_type_formatting(&s, r);
	const v = fmt_skip_to_response(out, 50.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	assert(len(result) == 1);
	const e0 = result[0] as json::object;
	const new_text = *(json::get(&e0, "newText") as *json::value) as str;
	assert(new_text == "");
};

@test fn on_type_formatting_semicolon_no_op() void = {
	let (s, scan, in_buf, out) = fmt_test_server();
	defer fmt_test_cleanup(&s, scan, in_buf, out);
	fmt_open(&s, "file:///x.ha", "fn x() void = void;\\n");

	const params =
		`{"textDocument":{"uri":"file:///x.ha"},"position":{"line":0,"character":19},"ch":";","options":{"tabSize":8,"insertSpaces":false}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 51.0,
		method = strings::dup("textDocument/onTypeFormatting")!,
		params = pv,
	};
	defer free(r.method);
	handle_on_type_formatting(&s, r);
	const v = fmt_skip_to_response(out, 51.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	assert(len(result) == 0);
};

@test fn on_type_formatting_correct_indent_no_edit() void = {
	let (s, scan, in_buf, out) = fmt_test_server();
	defer fmt_test_cleanup(&s, scan, in_buf, out);
	// Already correctly indented: `}` at column 0 in depth-0 context.
	fmt_open(&s, "file:///x.ha", "fn x() void = {\\n}\\n");

	const params =
		`{"textDocument":{"uri":"file:///x.ha"},"position":{"line":1,"character":1},"ch":"}","options":{"tabSize":8,"insertSpaces":false}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 52.0,
		method = strings::dup("textDocument/onTypeFormatting")!,
		params = pv,
	};
	defer free(r.method);
	handle_on_type_formatting(&s, r);
	const v = fmt_skip_to_response(out, 52.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	assert(len(result) == 0);
};

@test fn on_type_formatting_with_space_indent_emits_spaces() void = {
	let (s, scan, in_buf, out) = fmt_test_server();
	defer fmt_test_cleanup(&s, scan, in_buf, out);
	s.config.format_indent_style = indent_style::SPACE;
	s.config.format_indent_width = 2;
	// Nested block where the inner `}` should land at depth 1 = 2 spaces.
	// (Hare requires `;` after each compound expression.)
	fmt_open(&s, "file:///x.ha",
		"fn x() void = {\\n\\tif (true) {\\n\\t\\treturn;\\n};\\n};\\n");

	// Cursor is right after the inner `}` on line 3, char position 1.
	const params =
		`{"textDocument":{"uri":"file:///x.ha"},"position":{"line":3,"character":1},"ch":"}","options":{"tabSize":8,"insertSpaces":false}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 53.0,
		method = strings::dup("textDocument/onTypeFormatting")!,
		params = pv,
	};
	defer free(r.method);
	handle_on_type_formatting(&s, r);
	const v = fmt_skip_to_response(out, 53.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	assert(len(result) == 1);
	const e0 = result[0] as json::object;
	const new_text = *(json::get(&e0, "newText") as *json::value) as str;
	assert(new_text == "  ");
};
