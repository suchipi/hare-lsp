// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// End-to-end tests for the Ownership line that hover responses splice
// into their markdown when the hovered subject's type carries memory
// ownership. The Layer-1 annotation parser and Layer-2 stdlib table
// are unit-tested in analysis/ownership_test+test.ha; the tests here
// exercise the full hover code path through handle_hover.

use bufio;
use encoding::json;
use io;
use lsp;
use memio;
use strings;

fn nav_open_at(s: *server, uri: str, text: str) void = {
	nav_open(s, uri, text);
};

fn hover_value(
	s: *server,
	out: *memio::stream,
	uri: str,
	line: f64,
	ch: f64,
	id: f64,
) str = {
	const params =
		strings::concat(`{"textDocument":{"uri":"`, uri, `"},"position":{"line":`)!;
	defer free(params);
	const line_str = nav_format_int(line: int);
	defer free(line_str);
	const ch_str = nav_format_int(ch: int);
	defer free(ch_str);
	const full = strings::concat(params, line_str, `,"character":`, ch_str, `}}`)!;
	defer free(full);
	let pv = json::loadstr(full)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = id,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(s, r);
	const v = skip_to_response(out, id);
	defer json::finish(v);
	const o = v as json::object;
	const result_v = match (json::get(&o, "result")) {
	case let p: *json::value =>
		yield *p;
	case => abort("missing result");
	};
	const result = match (result_v) {
	case let o2: json::object =>
		yield o2;
	case =>
		return strings::dup("")!;
	};
	const contents = match (json::get(&result, "contents")) {
	case let p: *json::value =>
		yield *p as json::object;
	case => abort("missing contents");
	};
	const val = match (json::get(&contents, "value")) {
	case let p: *json::value =>
		yield *p as str;
	case => abort("missing value");
	};
	return strings::dup(val)!;
};

fn nav_format_int(n: int) str = {
	let buf: [16]u8 = [0...];
	let m = n;
	if (m == 0) return strings::dup("0")!;
	let i = 0z;
	let neg = false;
	if (m < 0) {
		neg = true;
		m = -m;
	};
	for (m > 0) {
		buf[i] = '0': u8 + (m % 10): u8;
		i += 1;
		m /= 10;
	};
	if (neg) {
		buf[i] = '-': u8;
		i += 1;
	};
	// Reverse.
	let out: []u8 = [];
	for (let k = i; k > 0; k -= 1) {
		append(out, buf[k - 1])!;
	};
	const s = strings::fromutf8(out)!;
	const d = strings::dup(s)!;
	free(out);
	return d;
};

@test fn hover_ownership_returns_annotation_owned() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///own.ha",
		"// @returns: owned\\nexport fn make() *int = alloc(0);\\n");
	// Char 12 is on the 'k' of 'make' on line 1.
	const v = hover_value(&s, out, "file:///own.ha", 1.0, 12.0, 200.0);
	defer free(v);
	assert(strings::contains(v, "Ownership: owned (annotation)"));
};

@test fn hover_ownership_returns_annotation_borrowed_from() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///own.ha",
		"// @returns: borrowed from in\\nexport fn pick(in: str) str = in;\\n");
	const v = hover_value(&s, out, "file:///own.ha", 1.0, 12.0, 201.0);
	defer free(v);
	assert(strings::contains(v, "Ownership: borrowed"));
	assert(strings::contains(v, "borrowed from `in`"));
};

@test fn hover_ownership_bare_owned_on_function_ignored() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///own.ha",
		"// @owned\\nexport fn make() *int = alloc(0);\\n");
	const v = hover_value(&s, out, "file:///own.ha", 1.0, 12.0, 202.0);
	defer free(v);
	// Bare @owned ignored on functions; with no other signal, no Ownership
	// line is rendered.
	assert(!strings::contains(v, "Ownership:"));
};

@test fn hover_ownership_no_line_for_int_return() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///own.ha", "export fn count() int = 0;\\n");
	const v = hover_value(&s, out, "file:///own.ha", 0.0, 14.0, 203.0);
	defer free(v);
	assert(!strings::contains(v, "Ownership:"));
};

@test fn hover_ownership_local_alloc_is_owned() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	const src =
		"export fn use_it() void = {\\n\\tlet x = alloc(0);\\n\\tfree(x);\\n};\\n";
	nav_open(&s, "file:///own.ha", src);
	// Cursor on `x` in `let x = alloc(0);` on line 1, char ~5.
	const v = hover_value(&s, out, "file:///own.ha", 1.0, 5.0, 204.0);
	defer free(v);
	assert(strings::contains(v, "Ownership: owned"));
	assert(strings::contains(v, "heuristic"));
};

@test fn hover_ownership_local_string_literal_is_borrowed() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	// The inner `"hi"` is double-escaped: Hare `\\\"` -> JSON `\"` -> `"`.
	const src = "export fn use_it() void = {\\n\\tlet s = \\\"hi\\\";\\n};\\n";
	nav_open(&s, "file:///own.ha", src);
	const v = hover_value(&s, out, "file:///own.ha", 1.0, 5.0, 205.0);
	defer free(v);
	assert(strings::contains(v, "Ownership: borrowed"));
	assert(strings::contains(v, "string literal"));
};

@test fn hover_ownership_param_annotation_borrowed() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	const src =
		"// @param p: borrowed\\nexport fn use_it(p: *int) void = void;\\n";
	nav_open(&s, "file:///own.ha", src);
	// Cursor on `p` in the parameter list, line 1, char ~17.
	const v = hover_value(&s, out, "file:///own.ha", 1.0, 17.0, 206.0);
	defer free(v);
	assert(strings::contains(v, "Ownership: borrowed (annotation)"));
};

@test fn hover_ownership_global_bare_owned() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	const src = "// @owned\\nlet g: *int = null: *int;\\n";
	nav_open(&s, "file:///own.ha", src);
	const v = hover_value(&s, out, "file:///own.ha", 1.0, 4.0, 207.0);
	defer free(v);
	assert(strings::contains(v, "Ownership: owned (annotation)"));
};

@test fn hover_ownership_alloc_builtin_shows_owned() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	const src = "export fn use_it() void = {\\n\\tlet x = alloc(0);\\n};\\n";
	nav_open(&s, "file:///own.ha", src);
	// Cursor on `alloc` itself, line 1, char ~10.
	const v = hover_value(&s, out, "file:///own.ha", 1.0, 10.0, 208.0);
	defer free(v);
	assert(strings::contains(v, "Ownership: owned"));
	assert(strings::contains(v, "alloc returns owned"));
};

@test fn hover_ownership_no_line_on_pointer_with_no_signal() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	const src = "export fn make() *int = alloc(0);\\n";
	nav_open(&s, "file:///own.ha", src);
	const v = hover_value(&s, out, "file:///own.ha", 0.0, 12.0, 209.0);
	defer free(v);
	// No annotation; workspace fn isn't in the stdlib table; no Layer-3
	// match. We stay silent rather than rendering "unknown".
	assert(!strings::contains(v, "Ownership:"));
};
