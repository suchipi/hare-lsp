// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use analysis;
use bufio;
use bytes;
use encoding::json;
use fs;
use io;
use lsp;
use memio;
use os;
use strconv;
use strings;

fn nav_test_server(

) (server, *bufio::scanner, *memio::stream, *memio::stream) = {
	let in_buf = alloc(memio::fixed([]))!;
	let scan = alloc(bufio::newscanner(in_buf))!;
	let out = alloc(memio::dynamic())!;
	let s = new(scan, out);
	return (s, scan, in_buf, out);
};

fn nav_test_cleanup(
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

fn nav_open(s: *server, uri: str, text: str) void = {
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

fn skip_to_response(out: *memio::stream, request_id: f64) json::value = {
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

@test fn hover_returns_signature_for_function() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///x.ha", "export fn target() void = void;\\n");

	// Position is on "target" — line 0, char ~12.
	const params =
		`{"textDocument":{"uri":"file:///x.ha"},"position":{"line":0,"character":12}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 100.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 100.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "target"));
	assert(strings::contains(value, "fn"));
};

@test fn hover_on_builtin_returns_docs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///b.ha",
		`export fn f() void = { let x: size = len(\"hi\"); };`);

	// Position is on "len" — character 38.
	const params =
		`{"textDocument":{"uri":"file:///b.ha"},"position":{"line":0,"character":38}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 150.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 150.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "len(value) size"));
	assert(strings::contains(value, "Built-in"));
	assert(strings::contains(value, "slice"));
};

@test fn hover_on_keyword_returns_docs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///k.ha", `export fn f() void = { defer free(null); };`);

	// Position is on "defer" — character 24.
	const params =
		`{"textDocument":{"uri":"file:///k.ha"},"position":{"line":0,"character":24}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 151.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 151.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Keyword"));
	assert(strings::contains(value, "defer"));
	assert(strings::contains(value, "reverse order"));
};

@test fn hover_on_attribute_returns_docs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///a.ha", `@test fn checks() void = void;`);

	// Position is on "test" — character 3.
	const params =
		`{"textDocument":{"uri":"file:///a.ha"},"position":{"line":0,"character":3}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 152.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 152.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Attribute"));
	assert(strings::contains(value, "@test"));
	assert(strings::contains(value, "test harness"));
};

@test fn hover_on_attribute_at_sign_returns_docs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///a2.ha", `@init fn boot() void = void;`);

	// Position is on the "@" — character 0.
	const params =
		`{"textDocument":{"uri":"file:///a2.ha"},"position":{"line":0,"character":0}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 153.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 153.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "@init"));
	assert(strings::contains(value, "before `main`"));
};

@test fn hover_on_operator_logical_or_returns_docs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op1.ha",
		`export fn f() bool = { return true || false; };`);

	// Position is on the first '|' of '||' — character 35.
	const params =
		`{"textDocument":{"uri":"file:///op1.ha"},"position":{"line":0,"character":35}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 160.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 160.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Operator"));
	assert(strings::contains(value, "Logical OR"));
	assert(strings::contains(value, "Precedence: 2"));
	assert(strings::contains(value, "Short-circuits"));
};

@test fn hover_on_operator_logical_and_prefers_two_chars() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op2.ha",
		`export fn f() bool = { return true && false; };`);

	// Position is on the first '&' of '&&' — character 35. The
	// scanner must pick up `&&`, not the single `&`.
	const params =
		`{"textDocument":{"uri":"file:///op2.ha"},"position":{"line":0,"character":35}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 161.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 161.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Logical AND"));
	assert(strings::contains(value, "Precedence: 4"));
	assert(strings::contains(value, "a && b"));
};

@test fn hover_on_operator_bitwise_and_returns_docs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op3.ha", `export fn f() int = { return 1 & 2; };`);

	// Position is on the lone '&' — character 31.
	const params =
		`{"textDocument":{"uri":"file:///op3.ha"},"position":{"line":0,"character":31}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 162.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 162.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Bitwise AND"));
	assert(strings::contains(value, "Precedence: 9"));
	// Disambiguation: binary context must not surface the address-of meaning.
	assert(!strings::contains(value, "Address-of"));
};

@test fn hover_on_operator_equality_returns_docs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op4.ha", `export fn f() bool = { return 1 == 2; };`);

	// Position is on the first '=' of '==' — character 32.
	const params =
		`{"textDocument":{"uri":"file:///op4.ha"},"position":{"line":0,"character":32}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 163.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 163.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Equality"));
	assert(strings::contains(value, "Precedence: 5"));
};

@test fn hover_on_operator_compound_assign_returns_docs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op5.ha",
		`export fn f() void = { let x = 1; x <<= 2; };`);

	// Position is on the first '<' of '<<=' — character 36.
	// The scanner must prefer `<<=` over `<<` or `<`.
	const params =
		`{"textDocument":{"uri":"file:///op5.ha"},"position":{"line":0,"character":36}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 164.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 164.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Compound assignment"));
	assert(strings::contains(value, "left shift"));
	assert(strings::contains(value, "a <<= b"));
	assert(strings::contains(value, "Precedence: 1"));
};

@test fn hover_on_star_binary_shows_only_multiplication() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_starb.ha", `export fn f() int = { return 2 * 3; };`);

	// '*' is at character 31, with '2 ' before it.
	const params =
		`{"textDocument":{"uri":"file:///op_starb.ha"},"position":{"line":0,"character":31}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 165.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 165.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Multiplication"));
	assert(strings::contains(value, "Precedence: 12"));
	assert(!strings::contains(value, "Pointer dereference"));
	assert(!strings::contains(value, "Pointer type modifier"));
};

@test fn hover_on_star_prefix_shows_only_dereference() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_starp.ha",
		`export fn g(p: *int) int = { return *p; };`);

	// '*' at character 36 — the prefix dereference of `p`.
	const params =
		`{"textDocument":{"uri":"file:///op_starp.ha"},"position":{"line":0,"character":36}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 166.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 166.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Pointer dereference"));
	assert(strings::contains(value, "Precedence: 13"));
	assert(!strings::contains(value, "Multiplication"));
};

@test fn hover_on_star_type_shows_only_pointer_type() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_start.ha",
		`export fn g(p: *int) int = { return *p; };`);

	// '*' at character 15 — the pointer-type marker in `*int`.
	const params =
		`{"textDocument":{"uri":"file:///op_start.ha"},"position":{"line":0,"character":15}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 167.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 167.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Pointer type modifier"));
	assert(!strings::contains(value, "Multiplication"));
	assert(!strings::contains(value, "Pointer dereference"));
};

@test fn hover_on_address_of_shows_only_address_of() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_addr.ha",
		`export fn h() void = { let x = 1; let p = &x; };`);

	// '&' at character 42 — address-of x.
	const params =
		`{"textDocument":{"uri":"file:///op_addr.ha"},"position":{"line":0,"character":42}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 168.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 168.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Address-of"));
	assert(strings::contains(value, "Precedence: 13"));
	assert(!strings::contains(value, "Bitwise AND"));
};

@test fn hover_on_logical_not_shows_only_logical_not() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_not.ha",
		`export fn f(b: bool) bool = { return !b; };`);

	// '!' at character 37 — logical NOT prefix on b.
	const params =
		`{"textDocument":{"uri":"file:///op_not.ha"},"position":{"line":0,"character":37}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 169.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 169.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Logical NOT"));
	assert(strings::contains(value, "Precedence: 13"));
	assert(!strings::contains(value, "Error-assert"));
};

@test fn hover_on_error_assert_postfix_shows_only_error_assert() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_eassert.ha",
		`export fn f() int = { let x: (int | void) = 1; return x!; };`);

	// '!' at character 55 — postfix error-assert on x.
	const params =
		`{"textDocument":{"uri":"file:///op_eassert.ha"},"position":{"line":0,"character":55}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 170.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 170.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Error-assert"));
	assert(strings::contains(value, "Precedence: 14"));
	assert(!strings::contains(value, "Logical NOT"));
};

@test fn hover_on_pipe_in_type_position_shows_tagged_union() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_pipetype.ha",
		`export fn f() void = { let x: (int | void) = 1; };`);

	// '|' at character 35 — separates tagged-union members.
	const params =
		`{"textDocument":{"uri":"file:///op_pipetype.ha"},"position":{"line":0,"character":35}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 171.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 171.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Tagged-union"));
	assert(!strings::contains(value, "Bitwise OR"));
};

@test fn hover_on_pipe_in_value_position_shows_bitwise_or() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_pipeval.ha",
		`export fn f() int = { return 1 | 2; };`);

	// '|' at character 31.
	const params =
		`{"textDocument":{"uri":"file:///op_pipeval.ha"},"position":{"line":0,"character":31}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 172.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 172.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Bitwise OR"));
	assert(strings::contains(value, "Precedence: 7"));
	assert(!strings::contains(value, "Tagged-union"));
};

@test fn hover_on_slice_double_dot_returns_docs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_dd.ha",
		`export fn f(s: []int) []int = { return s[1..3]; };`);

	// '..' first dot is at character 42.
	const params =
		`{"textDocument":{"uri":"file:///op_dd.ha"},"position":{"line":0,"character":42}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 173.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 173.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Slice/range separator"));
	// Disambiguation: the slice meaning must not surface the for-header
	// each-value-binding meaning.
	assert(!strings::contains(value, "iterator binding"));
};

@test fn hover_on_variadic_ellipsis_returns_docs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_ell.ha", `export fn f(args: int...) void = void;`);

	// '...' first dot is at character 21.
	const params =
		`{"textDocument":{"uri":"file:///op_ell.ha"},"position":{"line":0,"character":21}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 174.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 174.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Variadic parameter"));
	assert(!strings::contains(value, "Slice/range"));
	// Disambiguation: variadic-decl context must not surface call-site
	// spread, array fill, or struct autofill meanings.
	assert(!strings::contains(value, "Call-site spread"));
	assert(!strings::contains(value, "Array-literal fill"));
	assert(!strings::contains(value, "Struct-literal autofill"));
};

@test fn hover_on_field_access_dot_returns_docs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_dot.ha",
		`type t = struct { x: int }; export fn f(v: t) int = { return v.x; };`);

	// '.' at character 62 between v and x.
	const params =
		`{"textDocument":{"uri":"file:///op_dot.ha"},"position":{"line":0,"character":62}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 175.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 175.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Field access"));
	// Disambiguation: a struct-field `.` must not surface tuple-index docs.
	assert(!strings::contains(value, "Tuple positional"));
};

@test fn hover_on_open_brace_returns_docs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_lbrace.ha", `export fn f() void = { return; };`);

	// '{' at character 21.
	const params =
		`{"textDocument":{"uri":"file:///op_lbrace.ha"},"position":{"line":0,"character":21}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 176.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 176.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Function body opener"));
	// Disambiguation: function-body `{` must not list the other block
	// constructs (struct/union/enum/match/switch/literal/compound).
	assert(!strings::contains(value, "Struct type body"));
	assert(!strings::contains(value, "Match body"));
	assert(!strings::contains(value, "Compound expression"));
};

@test fn hover_on_close_brace_returns_docs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_rbrace.ha", `export fn f() void = { return; };`);

	// '}' at character 31.
	const params =
		`{"textDocument":{"uri":"file:///op_rbrace.ha"},"position":{"line":0,"character":31}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 177.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 177.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Function body closer"));
	assert(!strings::contains(value, "Struct type body"));
	assert(!strings::contains(value, "Match body"));
};

@test fn hover_on_type_annotation_colon_returns_docs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_colon.ha",
		`export fn f() void = { let x: int = 1; };`);

	// ':' at character 28 in 'let x: int'.
	const params =
		`{"textDocument":{"uri":"file:///op_colon.ha"},"position":{"line":0,"character":28}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 178.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 178.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Type annotation"));
	// Disambiguation: the binding-annotation case must NOT surface the
	// cast or label meanings.
	assert(!strings::contains(value, "Cast expression"));
	assert(!strings::contains(value, "Label prefix"));
};

@test fn hover_on_cast_colon_returns_docs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_cast.ha", `export fn f() u8 = { return 5: u8; };`);

	// ':' at character 29 in '5: u8'.
	const params =
		`{"textDocument":{"uri":"file:///op_cast.ha"},"position":{"line":0,"character":29}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 179.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 179.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Cast expression"));
	assert(!strings::contains(value, "Type annotation"));
	assert(!strings::contains(value, "Label prefix"));
};

@test fn hover_on_label_colon_returns_docs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_label.ha",
		`export fn f() void = { for :outer (false) { break :outer; }; };`);

	// First ':' at character 27 — the label declaration ':outer'.
	const params =
		`{"textDocument":{"uri":"file:///op_label.ha"},"position":{"line":0,"character":27}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 180.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 180.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Label prefix"));
	assert(!strings::contains(value, "Type annotation"));
	assert(!strings::contains(value, "Cast expression"));
};

@test fn hover_on_for_header_double_dot_returns_iter_binding() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_forval.ha",
		`export fn f(xs: []int) void = { for (let v .. xs) void; };`);

	// '..' first dot is at character 44 in 'let v .. xs'.
	const params =
		`{"textDocument":{"uri":"file:///op_forval.ha"},"position":{"line":0,"character":44}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 181.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 181.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "By-value iterator binding"));
	// Disambiguation: the for-header case must not mention slice docs.
	assert(!strings::contains(value, "Slice/range separator"));
};

@test fn hover_on_for_iterator_arrow_returns_iter_binding() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_foriter.ha",
		`export fn f(it: int) void = { for (let v => it) void; };`);

	// '=>' first byte at character 42 in 'let v => it'.
	const params =
		`{"textDocument":{"uri":"file:///op_foriter.ha"},"position":{"line":0,"character":42}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 182.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 182.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Iterator-protocol binding"));
	// Disambiguation: the for-iterator case must not mention case-arrow docs.
	assert(!strings::contains(value, "Case arrow"));
};

@test fn hover_on_case_arrow_returns_case_arrow() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_case.ha",
		`export fn f(v: (int | void)) void = { match (v) { case int => void; case => void; }; };`
	);

	// First '=>' first byte at character 59 (the '=' of 'case int => void').
	const params =
		`{"textDocument":{"uri":"file:///op_case.ha"},"position":{"line":0,"character":59}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 183.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 183.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Case arrow"));
	assert(!strings::contains(value, "Iterator-protocol binding"));
};

@test fn hover_on_tuple_index_dot_returns_tuple_docs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_tup.ha",
		`export fn f(t: (int, int)) int = { return t.0; };`);

	// '.' at character 43 in 't.0'.
	const params =
		`{"textDocument":{"uri":"file:///op_tup.ha"},"position":{"line":0,"character":43}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 184.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 184.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Tuple positional"));
	// Disambiguation: tuple `.` must not mention struct-field docs.
	assert(!strings::contains(value, "Field access"));
};

@test fn hover_on_struct_body_brace_returns_struct_docs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_struct.ha", `type t = struct { x: int };`);

	// '{' at character 16.
	const params =
		`{"textDocument":{"uri":"file:///op_struct.ha"},"position":{"line":0,"character":16}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 185.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 185.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Struct type body opener"));
	assert(!strings::contains(value, "Function body"));
	assert(!strings::contains(value, "Match body"));
};

@test fn hover_on_match_body_brace_returns_match_docs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_match.ha",
		`export fn f(v: (int | void)) void = { match (v) { case => void; }; };`);

	// '{' opening the match body at character 48.
	const params =
		`{"textDocument":{"uri":"file:///op_match.ha"},"position":{"line":0,"character":48}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 186.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 186.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Match body opener"));
	assert(!strings::contains(value, "Function body"));
	assert(!strings::contains(value, "Switch body"));
};

@test fn hover_on_index_lbracket_returns_docs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_idx.ha",
		`export fn f(xs: []int) int = { return xs[0]; };`);

	// '[' at character 40 (just after 'xs').
	const params =
		`{"textDocument":{"uri":"file:///op_idx.ha"},"position":{"line":0,"character":40}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 187.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 187.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Index / slice opener"));
	assert(!strings::contains(value, "Array / slice type"));
	assert(!strings::contains(value, "Array literal"));
};

@test fn hover_on_array_type_lbracket_returns_docs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_atype.ha",
		`export fn f() void = { let x: [3]int = [1, 2, 3]; };`);

	// First '[' at character 30 — the array-type bracket in '[3]int'.
	const params =
		`{"textDocument":{"uri":"file:///op_atype.ha"},"position":{"line":0,"character":30}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 188.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 188.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Array type opener"));
	assert(!strings::contains(value, "Index / slice"));
	assert(!strings::contains(value, "Array literal"));
	// Length-bearing array type must not surface the empty-bracket
	// slice-type meaning.
	assert(!strings::contains(value, "Slice type opener"));
};

@test fn hover_on_array_literal_lbracket_returns_docs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_alit.ha",
		`export fn f() void = { let x: [3]int = [1, 2, 3]; };`);

	// Second '[' at character 39 — the array-literal bracket in '[1, 2, 3]'.
	const params =
		`{"textDocument":{"uri":"file:///op_alit.ha"},"position":{"line":0,"character":39}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 189.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 189.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Array literal opener"));
	assert(!strings::contains(value, "Index / slice"));
	assert(!strings::contains(value, "Array / slice type"));
};

@test fn hover_on_index_rbracket_returns_docs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_idxc.ha",
		`export fn f(xs: []int) int = { return xs[0]; };`);

	// ']' at character 42, matching the index '[' at 40.
	const params =
		`{"textDocument":{"uri":"file:///op_idxc.ha"},"position":{"line":0,"character":42}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 190.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 190.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Index / slice closer"));
};

@test fn hover_on_call_lparen_returns_call_docs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_call.ha",
		`export fn f() void = { let x: size = len(\"hi\"); };`);

	// '(' at character 40 — len's argument list opener.
	const params =
		`{"textDocument":{"uri":"file:///op_call.ha"},"position":{"line":0,"character":40}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 191.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 191.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Call argument list opener"));
	assert(!strings::contains(value, "Function parameter list"));
	assert(!strings::contains(value, "if condition"));
};

@test fn hover_on_param_list_lparen_returns_param_docs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_par.ha", `export fn f(x: int) void = void;`);

	// '(' at character 11 — function declaration parameter list.
	const params =
		`{"textDocument":{"uri":"file:///op_par.ha"},"position":{"line":0,"character":11}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 192.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 192.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Function parameter list opener"));
	assert(!strings::contains(value, "Call argument list"));
};

@test fn hover_on_if_lparen_returns_if_docs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_if.ha", `export fn f() void = { if (true) void; };`);

	// '(' at character 26 — if's condition opener.
	const params =
		`{"textDocument":{"uri":"file:///op_if.ha"},"position":{"line":0,"character":26}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 193.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 193.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(
		strings::contains(value, "if condition opener") ||
		strings::contains(value, "`if` condition opener")
	);
	assert(!strings::contains(value, "Call argument list"));
};

@test fn hover_on_type_parens_lparen_returns_type_docs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_tparen.ha",
		`export fn f() void = { let x: (int | void) = 1; };`);

	// '(' at character 30 — opens the tagged-union type.
	const params =
		`{"textDocument":{"uri":"file:///op_tparen.ha"},"position":{"line":0,"character":30}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 194.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 194.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Type-grouping opener"));
	assert(!strings::contains(value, "Expression-grouping"));
};

@test fn hover_on_terminator_semicolon_returns_docs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_semi.ha", `export fn f() void = { let x = 1; };`);

	// ';' at character 32 after `let x = 1`.
	const params =
		`{"textDocument":{"uri":"file:///op_semi.ha"},"position":{"line":0,"character":32}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 195.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 195.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Statement terminator"));
	assert(!strings::contains(value, "for header separator"));
};

@test fn hover_on_for_header_semicolon_returns_separator_docs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_forsemi.ha",
		`export fn f() void = { for (let i = 0; i < 3; i += 1) void; };`);

	// First ';' inside the for header — at character 37.
	const params =
		`{"textDocument":{"uri":"file:///op_forsemi.ha"},"position":{"line":0,"character":37}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 196.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 196.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "header separator"));
	assert(!strings::contains(value, "Statement terminator"));
};

@test fn hover_on_func_body_brace_mentions_return() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_fbret.ha", `export fn f() void = { return; };`);

	// '{' at character 21.
	const params =
		`{"textDocument":{"uri":"file:///op_fbret.ha"},"position":{"line":0,"character":21}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 197.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 197.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Function body opener"));
	assert(strings::contains(value, "return"));
};

@test fn hover_on_comma_after_rbracket_does_not_show_rbracket_docs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	// Mirrors the analysis/buffer.ha case: `[0...], grow`. The cursor
	// on the comma must not back off and surface the array-literal
	// closer's tooltip.
	nav_open(&s, "file:///op_combr.ha",
		`export fn f(b: []u8) void = { append(b, [0...], 3)!; };`);

	// ',' immediately after the ']' of '[0...]'. The bytes '[0...]'
	// sit at characters 40-45, so the comma is at character 46.
	const params =
		`{"textDocument":{"uri":"file:///op_combr.ha"},"position":{"line":0,"character":46}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 198.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 198.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	// The comma sits inside the call to `append(...)`, so its tooltip
	// should be the call-arg separator, not the array-literal closer.
	assert(strings::contains(value, "Argument separator"));
	assert(!strings::contains(value, "Array literal closer"));
};

@test fn hover_on_param_list_comma_returns_param_docs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_compar.ha",
		`export fn f(a: int, b: int) void = void;`);

	// ',' between params at character 18.
	const params =
		`{"textDocument":{"uri":"file:///op_compar.ha"},"position":{"line":0,"character":18}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 199.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 199.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Parameter separator"));
	assert(!strings::contains(value, "Argument separator"));
};

@test fn hover_on_array_literal_comma_returns_element_docs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_comar.ha",
		`export fn f() void = { let x: [3]int = [1, 2, 3]; };`);

	// First ',' inside [1, 2, 3] at character 41.
	const params =
		`{"textDocument":{"uri":"file:///op_comar.ha"},"position":{"line":0,"character":41}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 200.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 200.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Array element separator"));
	assert(!strings::contains(value, "Argument separator"));
	assert(!strings::contains(value, "Parameter separator"));
};

@test fn hover_on_slice_type_lbracket_returns_slice_docs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_slt.ha", `export fn f(b: []u8) void = void;`);

	// '[' at character 15 — opens the slice type '[]u8'.
	const params =
		`{"textDocument":{"uri":"file:///op_slt.ha"},"position":{"line":0,"character":15}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 201.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 201.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Slice type opener"));
	assert(!strings::contains(value, "Array type opener"));
	assert(!strings::contains(value, "Index / slice opener"));
};

@test fn hover_on_slice_type_rbracket_returns_slice_docs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///op_slc.ha", `export fn f(b: []u8) void = void;`);

	// ']' at character 16 — closes the slice type '[]u8'.
	const params =
		`{"textDocument":{"uri":"file:///op_slc.ha"},"position":{"line":0,"character":16}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 202.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 202.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "Slice type closer"));
	assert(!strings::contains(value, "Array type closer"));
	assert(!strings::contains(value, "Index / slice"));
};

@test fn hover_on_whitespace_returns_null() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///x.ha", "export fn target() void = void;\\n");

	const params =
		`{"textDocument":{"uri":"file:///x.ha"},"position":{"line":0,"character":6}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 101.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 101.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value);
	assert(result is json::_null);
};

@test fn definition_returns_location_for_local_decl() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///x.ha", "export fn target() void = void;\\n");

	const params =
		`{"textDocument":{"uri":"file:///x.ha"},"position":{"line":0,"character":12}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 200.0,
		method = strings::dup("textDocument/definition")!,
		params = pv,
	};
	defer free(r.method);
	handle_definition(&s, r);

	const v = skip_to_response(out, 200.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const uri = *(json::get(&result, "uri") as *json::value) as str;
	assert(uri == "file:///x.ha");
	const range = *(json::get(&result, "range") as *json::value) as json::object;
	const start = *(json::get(&range, "start") as *json::value) as json::object;
	assert(*(json::get(&start, "line") as *json::value) as f64 == 0.0);
};

@test fn type_definition_returns_location_for_type_only() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///x.ha",
		"type point = struct { x: int };\\nexport fn f() void = void;\\n");

	// Hover on "point" — line 0, char 5.
	const params =
		`{"textDocument":{"uri":"file:///x.ha"},"position":{"line":0,"character":6}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 300.0,
		method = strings::dup("textDocument/typeDefinition")!,
		params = pv,
	};
	defer free(r.method);
	handle_type_definition(&s, r);

	const v = skip_to_response(out, 300.0);
	defer json::finish(v);
	const result = *(json::get(&(v as json::object), "result") as *json::value);
	// Should be a Location.
	assert(result is json::object);
};

@test fn type_definition_on_function_returns_null() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///x.ha", "export fn f() void = void;\\n");

	const params =
		`{"textDocument":{"uri":"file:///x.ha"},"position":{"line":0,"character":11}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 301.0,
		method = strings::dup("textDocument/typeDefinition")!,
		params = pv,
	};
	defer free(r.method);
	handle_type_definition(&s, r);

	const v = skip_to_response(out, 301.0);
	defer json::finish(v);
	const result = *(json::get(&(v as json::object), "result") as *json::value);
	assert(result is json::_null);
};

@test fn definition_falls_back_to_workspace_index_for_cross_file() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// Put a "defines fn target" fixture on disk and index it.
	const def_path = ".tmp/hare-lsp-nav-crossfile.ha";
	const def_text = "export fn target() void = void;\n";
	let _ = match (nav_write(def_path, def_text)) {
	case bool =>
		yield true;
	case => abort("cannot write fixture");
	};
	defer nav_rm(def_path);
	analysis::index_file(&s.workspace_index, def_path, strings::toutf8(def_text));

	// Open a separate buffer that calls `target()` — its file-local
	// index doesn't know about `target`.
	nav_open(&s, "file:///caller.ha", "fn caller() void = target();\\n");

	// Cursor on `target` in caller.ha.
	const params =
		`{"textDocument":{"uri":"file:///caller.ha"},"position":{"line":0,"character":22}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 400.0,
		method = strings::dup("textDocument/definition")!,
		params = pv,
	};
	defer free(r.method);
	handle_definition(&s, r);

	const v = skip_to_response(out, 400.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const uri = *(json::get(&result, "uri") as *json::value) as str;
	// Should point at the on-disk file, not caller.ha.
	assert(strings::hassuffix(uri, "hare-lsp-nav-crossfile.ha"));
};

@test fn hover_falls_back_to_workspace_index_for_cross_file() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const def_path = ".tmp/hare-lsp-nav-hover-crossfile.ha";
	const def_text = "// the answer\nexport fn answer() int = 42;\n";
	let _ = match (nav_write(def_path, def_text)) {
	case bool =>
		yield true;
	case => abort("cannot write fixture");
	};
	defer nav_rm(def_path);
	analysis::index_file(&s.workspace_index, def_path, strings::toutf8(def_text));

	nav_open(&s, "file:///caller.ha",
		"fn caller() void = { let n = answer(); };\\n");

	// Position on `answer` — char index roughly 29.
	const params =
		`{"textDocument":{"uri":"file:///caller.ha"},"position":{"line":0,"character":31}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 401.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 401.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	// Hover markdown should contain the cross-file decl signature.
	assert(strings::contains(value, "answer"));
};

@test fn hover_on_let_binding_with_propagate_strips_error_variants() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const def_path = ".tmp/hare-lsp-nav-hover-propagate.ha";
	const def_text =
		"export type myerr = !void;\nexport fn want() (int | myerr) = 0;\n";
	let _ = match (nav_write(def_path, def_text)) {
	case bool =>
		yield true;
	case => abort("cannot write fixture");
	};
	defer nav_rm(def_path);
	analysis::index_file(&s.workspace_index, def_path, strings::toutf8(def_text));

	// `let t = want()?;` — hover on `t` (line 0, char 25).
	nav_open(&s, "file:///caller_prop.ha",
		"fn caller() void = { let t = want()?; };\\n");

	const params =
		`{"textDocument":{"uri":"file:///caller_prop.ha"},"position":{"line":0,"character":25}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 460.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 460.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	// After `?`, the result should be just `int` — the alias `myerr`
	// resolves to `!void`, so its variant is stripped from the union.
	assert(strings::contains(value, "let t"));
	assert(strings::contains(value, "int"));
	assert(!strings::contains(value, "myerr"));
	assert(!strings::contains(value, "want()"));
};

@test fn hover_on_let_binding_with_error_assert_strips_error_variants() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const def_path = ".tmp/hare-lsp-nav-hover-bang.ha";
	const def_text =
		"export type myerr = !void;\nexport fn want() (int | myerr) = 0;\n";
	let _ = match (nav_write(def_path, def_text)) {
	case bool =>
		yield true;
	case => abort("cannot write fixture");
	};
	defer nav_rm(def_path);
	analysis::index_file(&s.workspace_index, def_path, strings::toutf8(def_text));

	// `let t = want()!;` — hover on `t` (line 0, char 25).
	nav_open(&s, "file:///caller_bang.ha",
		"fn caller() void = { let t = want()!; };\\n");

	const params =
		`{"textDocument":{"uri":"file:///caller_bang.ha"},"position":{"line":0,"character":25}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 461.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 461.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "let t"));
	assert(strings::contains(value, "int"));
	assert(!strings::contains(value, "myerr"));
	assert(!strings::contains(value, "want()"));
};

@test fn definition_disambiguates_by_imported_module() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// Two modules both declare `init`. We want imports of mod_a to win.
	const path_a = ".tmp/lspmoda/init.ha";
	const path_b = ".tmp/lspmodb/init.ha";
	const text = "export fn init() void = void;\n";
	nav_write_dir(".tmp/lspmoda");
	nav_write_dir(".tmp/lspmodb");
	let _ = match (nav_write(path_a, text)) {
	case bool =>
		yield true;
	case => abort("cannot write");
	};
	let _ = match (nav_write(path_b, text)) {
	case bool =>
		yield true;
	case => abort("cannot write");
	};
	defer nav_rm(path_a);
	defer nav_rm(path_b);
	analysis::index_file(&s.workspace_index, path_a, strings::toutf8(text));
	analysis::index_file(&s.workspace_index, path_b, strings::toutf8(text));

	// caller.ha imports lspmoda only.
	nav_open(&s, "file:///caller.ha",
		"use lspmoda;\\n\\nfn caller() void = init();\\n");

	// Position on `init` in caller.ha.
	const params =
		`{"textDocument":{"uri":"file:///caller.ha"},"position":{"line":2,"character":21}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 450.0,
		method = strings::dup("textDocument/definition")!,
		params = pv,
	};
	defer free(r.method);
	handle_definition(&s, r);

	const v = skip_to_response(out, 450.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const uri = *(json::get(&result, "uri") as *json::value) as str;
	// Should resolve to mod-a, not mod-b.
	assert(strings::contains(uri, "lspmoda"));
	assert(!strings::contains(uri, "lspmodb"));
};

@test fn definition_resolves_qualified_reference() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const path_a = ".tmp/lspmodc/init.ha";
	const path_b = ".tmp/lspmodd/init.ha";
	const text = "export fn init() void = void;\n";
	nav_write_dir(".tmp/lspmodc");
	nav_write_dir(".tmp/lspmodd");
	let _ = match (nav_write(path_a, text)) {
	case bool =>
		yield true;
	case => abort("cannot write");
	};
	let _ = match (nav_write(path_b, text)) {
	case bool =>
		yield true;
	case => abort("cannot write");
	};
	defer nav_rm(path_a);
	defer nav_rm(path_b);
	analysis::index_file(&s.workspace_index, path_a, strings::toutf8(text));
	analysis::index_file(&s.workspace_index, path_b, strings::toutf8(text));

	// caller writes `lspmodd::init()` — a qualified reference.
	// Despite lspmodc also having `init`, the qualifier must win.
	nav_open(&s, "file:///caller2.ha", "fn caller() void = lspmodd::init();\\n");

	// Position on `init` in caller2.ha — right after `::`.
	// "fn caller() void = lspmodd::init();" — `init` is cols 28-31.
	const params =
		`{"textDocument":{"uri":"file:///caller2.ha"},"position":{"line":0,"character":30}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 451.0,
		method = strings::dup("textDocument/definition")!,
		params = pv,
	};
	defer free(r.method);
	handle_definition(&s, r);

	const v = skip_to_response(out, 451.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const uri = *(json::get(&result, "uri") as *json::value) as str;
	assert(strings::contains(uri, "lspmodd"));
};

@test fn hover_on_type_reference_shows_doc_comment() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// `build_diagnostic` is declared with a doc comment, then referenced
	// in another decl as `d: build_diagnostic`. Hovering on the reference
	// should show the type's doc comment, not just the signature.
	const src =
		"// One diagnostic emitted by the compiler.\\nexport type build_diagnostic = struct { x: int };\\nfn f(d: build_diagnostic) void = void;\\n";
	nav_open(&s, "file:///bd.ha", src);

	// Line 2 is `fn f(d: build_diagnostic) void = void;`. The token
	// `build_diagnostic` starts at column 8.
	const params =
		`{"textDocument":{"uri":"file:///bd.ha"},"position":{"line":2,"character":12}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 470.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 470.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "build_diagnostic"));
	assert(strings::contains(value, "One diagnostic emitted by the compiler."));
};

@test fn hover_doc_comment_renders_resolved_ref_as_command_link() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// `target` references `[[helper]]` in its doc comment. Both decls
	// live in the same file, so resolution should hit the local index
	// and emit a markdown link with a `command:hare-lsp.openLocation` URI.
	const src =
		"// See [[helper]] for the implementation.\\nexport fn target() void = void;\\nexport fn helper() void = void;\\n";
	nav_open(&s, "file:///r.ha", src);

	const params =
		`{"textDocument":{"uri":"file:///r.ha"},"position":{"line":1,"character":12}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 480.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 480.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "[helper](command:hare-lsp.openLocation?"));
	// The link's URI argument should encode the open document's URI.
	assert(strings::contains(value, "file%3A%2F%2F%2Fr.ha"));
};

@test fn hover_doc_comment_renders_unresolved_ref_as_code() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// `nowhere` is not declared anywhere; the ref should fall back to
	// inline code rather than a broken link.
	const src =
		"// See [[nowhere]] for details.\\nexport fn target() void = void;\\n";
	nav_open(&s, "file:///u.ha", src);

	const params =
		`{"textDocument":{"uri":"file:///u.ha"},"position":{"line":1,"character":12}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 481.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 481.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "`nowhere`"));
	assert(!strings::contains(value, "command:"));
};

@test fn hover_const_match_init_uses_yielded_case_type() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// Mirrors `const c1 = match (...) { case let i: size => yield i;
	// case => return void; };`. Only the size case yields a value; the
	// default diverges, so the inferred type is just `size`.
	const src =
		"fn caller() void = { const c1 = match (2z: (size | void)) { case let i: size => yield i; case => return; }; };\\n";
	nav_open(&s, "file:///mb.ha", src);

	// Position on `c1` (line 0, column 27 -> just after "const ").
	const params =
		`{"textDocument":{"uri":"file:///mb.ha"},"position":{"line":0,"character":28}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 490.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 490.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "const c1"));
	assert(strings::contains(value, ": size"));
	// The diverging default case must not contribute `void` to the type.
	assert(!strings::contains(value, "size | void"));
	// The init source must NOT be echoed when the type was successfully
	// inferred — we want a clean "const c1: size", not "const c1 = match ...".
	assert(!strings::contains(value, "match"));
};

@test fn hover_const_match_init_unions_multiple_yields() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// Two cases each yield a different type. Result should be the union.
	const src =
		"fn caller() void = { const c2 = match (2z: (size | void)) { case let i: size => yield i; case => yield 0; }; };\\n";
	nav_open(&s, "file:///mu.ha", src);

	const params =
		`{"textDocument":{"uri":"file:///mu.ha"},"position":{"line":0,"character":28}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 491.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 491.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "const c2"));
	assert(strings::contains(value, "size"));
	assert(strings::contains(value, "int"));
	// Either order is fine, but it must look like a union.
	assert(strings::contains(value, "|"));
};

// Mirrors `let s = if (start > len(b)) len(b) else start;` from
// analysis/buffer.ha line 76. Both branches yield `size`, so the binding's
// inferred type is `size` — not an echo of the if-else source.
@test fn hover_let_if_else_with_len_infers_size() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src =
		"fn f(start: size, b: []u8) void = { let s = if (start > len(b)) len(b) else start; };\\n";
	nav_open(&s, "file:///ifb.ha", src);

	// Cursor on `s` (line 0, char 40).
	const params =
		`{"textDocument":{"uri":"file:///ifb.ha"},"position":{"line":0,"character":40}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 492.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 492.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "let s"));
	assert(strings::contains(value, ": size"));
	assert(!strings::contains(value, "if ("));
};

// Mirrors `const old_len = e - s;` from analysis/buffer.ha line 80: a
// subtraction between two locals whose types must be discovered by walking
// back to their declarations.
@test fn hover_const_subtraction_of_locals_infers_size() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src =
		"fn f(b: []u8) void = { let e: size = len(b); let s: size = 0z; const old_len = e - s; };\\n";
	nav_open(&s, "file:///sub.ha", src);

	// Position on `old_len`.
	const params =
		`{"textDocument":{"uri":"file:///sub.ha"},"position":{"line":0,"character":69}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 493.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 493.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "const old_len"));
	assert(strings::contains(value, ": size"));
	assert(!strings::contains(value, " = e - s"));
};

// Mirrors `const delta = len(new_text): ssize - old_len: ssize;` from
// analysis/buffer.ha line 81: a subtraction whose operands are both casts
// to a concrete type. The cast type drives the result.
@test fn hover_const_subtraction_of_casts_infers_cast_type() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src =
		"type ssize = i64;\\nfn f(new_text: []u8, old_len: size) void = { const delta = len(new_text): ssize - old_len: ssize; };\\n";
	nav_open(&s, "file:///cst.ha", src);

	// Position on `delta` (line 1, char 53).
	const params =
		`{"textDocument":{"uri":"file:///cst.ha"},"position":{"line":1,"character":53}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 494.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 494.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "const delta"));
	assert(strings::contains(value, ": ssize"));
	assert(!strings::contains(value, " = len("));
};

// Comparison operators always yield `bool`, regardless of operand type.
@test fn hover_let_comparison_infers_bool() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src = "fn f(a: size, b: size) void = { let cmp = a < b; };\\n";
	nav_open(&s, "file:///cmp.ha", src);

	const params =
		`{"textDocument":{"uri":"file:///cmp.ha"},"position":{"line":0,"character":36}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 495.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 495.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "let cmp"));
	assert(strings::contains(value, ": bool"));
};

@test fn hover_on_use_module_shows_readme() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// `bufio` is a stdlib module with a README at
	// /usr/local/src/hare/stdlib/bufio/README. Hovering on the module
	// name in a `use` statement should show its contents.
	nav_open(&s, "file:///mb1.ha", "use bufio;\\nfn f() void = void;\\n");

	const params =
		`{"textDocument":{"uri":"file:///mb1.ha"},"position":{"line":0,"character":6}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 500.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 500.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "module bufio"));
	// The README starts with "bufio: buffered I/O primitives" — assert
	// the descriptive text from the actual file is present.
	assert(strings::contains(value, "buffered I/O primitives"));
};

@test fn hover_on_double_colon_acts_like_first_segment() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// `use unix::poll;` — hovering on the `::` should resolve to
	// `unix` (the first segment), not `unix::poll`.
	nav_open(&s, "file:///mb2.ha", "use unix::poll;\\nfn f() void = void;\\n");

	// "use unix::poll;" — `::` is at columns 8-9.
	const params =
		`{"textDocument":{"uri":"file:///mb2.ha"},"position":{"line":0,"character":8}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 501.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 501.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	// Header should be `module unix`, NOT `module unix::poll`.
	assert(strings::contains(value, "module unix\n"));
	assert(!strings::contains(value, "module unix::poll"));
};

@test fn hover_on_second_segment_resolves_full_path() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// `use unix::poll;` — hovering on `poll` should resolve to
	// `unix::poll`, not just `unix`.
	nav_open(&s, "file:///mb4.ha", "use unix::poll;\\nfn f() void = void;\\n");

	// "use unix::poll;" — `poll` starts at column 10.
	const params =
		`{"textDocument":{"uri":"file:///mb4.ha"},"position":{"line":0,"character":11}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 503.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 503.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "module unix::poll"));
};

@test fn hover_on_qualifier_in_code_shows_module_readme() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// In `bufio::newscanner(...)`, hovering on `bufio` should show the
	// bufio README, not fall through to a (missing) decl lookup.
	nav_open(&s, "file:///mb3.ha",
		"use bufio;\\nfn f() void = { bufio::newscanner(0); };\\n");

	// Position on the second `bufio` (in the body, line 1).
	// Source: "fn f() void = { bufio::newscanner(0); };"
	//                          ^ char ~16
	const params =
		`{"textDocument":{"uri":"file:///mb3.ha"},"position":{"line":1,"character":18}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 502.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 502.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "module bufio"));
	assert(strings::contains(value, "buffered I/O"));
};

// --- fixture helpers ---
fn nav_write(path: str, text: str) (bool | fs::error) = {
	const f = os::create(path, 0o644)?;
	defer io::close(f)!;
	io::writeall(f, strings::toutf8(text))!;
	return true;
};

fn nav_write_dir(path: str) void = {
	match (os::mkdir(path, 0o755)) {
	case => void;
	};
};

fn nav_rm(path: str) void = {
	match (os::remove(path)) {
	case => void;
	};
};
