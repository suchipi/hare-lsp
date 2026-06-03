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
	let s = new(scan, out, void);
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
	const src = "export fn target() void = void;\\n";
	nav_open(&s, "file:///x.ha", src);

	// Position lands on `target`; col is looked up at runtime so
	// edits to `src` don't silently desync the assertion.
	const params = pos_params("file:///x.ha", 0, find_col(src, "target"));
	defer free(params);
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
	const src = `export fn f() void = { let x: size = len(\"hi\"); };`;
	nav_open(&s, "file:///b.ha", src);

	// Position lands on `len`.
	const params = pos_params("file:///b.ha", 0, find_col(src, "len"));
	defer free(params);
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

// Reproduces the reported bug: hovering the loop variable of a by-value
// for-each loop echoed the iterable expression instead of the element
// type (and the loc.end-is-last-rune truncation rendered `cmd.opts` as
// `cmd.opt`). `cmd.opts` is `[](rune, str)`, so `item` is `(rune, str)`.
@test fn hover_on_for_each_value_binding_shows_element_type() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src =
		`export type command = struct { opts: [](rune, str) }; export fn run(cmd: command) void = { for (let item .. cmd.opts) void; };`;
	nav_open(&s, "file:///fe_value.ha", src);
	const value = nav_hover_contents(&s, out, "file:///fe_value.ha", 0,
		find_col(src, "item"), 700.0);
	defer free(value);
	assert(strings::contains(value, "let item"));
	assert(strings::contains(value, "(rune, str)"));
	// Must not echo the iterable expression nor its truncated form.
	assert(!strings::contains(value, "cmd.opt"));
	assert(!strings::contains(value, "= cmd"));
};

// A by-value for-each over a `[]int` binds the loop variable to `int`.
@test fn hover_on_for_each_value_slice_binding_shows_int() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src = `export fn run(xs: []int) void = { for (let item .. xs) void; };`;
	nav_open(&s, "file:///fe_slice.ha", src);
	const value = nav_hover_contents(&s, out, "file:///fe_slice.ha", 0,
		find_col(src, "item"), 701.0);
	defer free(value);
	assert(strings::contains(value, "let item"));
	assert(strings::contains(value, "int"));
	assert(!strings::contains(value, "[]"));
	assert(!strings::contains(value, "= xs"));
};

// A by-pointer for-each (`&..`) binds the loop variable to a pointer to
// the element, so the hover shows `*int`, not `int` or the iterable.
@test fn hover_on_for_each_pointer_binding_shows_pointer_type() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src = `export fn run(xs: []int) void = { for (let item &.. xs) void; };`;
	nav_open(&s, "file:///fe_ptr.ha", src);
	const value = nav_hover_contents(&s, out, "file:///fe_ptr.ha", 0,
		find_col(src, "item"), 702.0);
	defer free(value);
	assert(strings::contains(value, "let item"));
	assert(strings::contains(value, "*int"));
	assert(!strings::contains(value, "= xs"));
};

// An iterator for-each (`=>`) binds the loop variable to the generator's
// value with the `done` sentinel stripped: `gen()` returns `(int | done)`,
// so `item` is `int`.
@test fn hover_on_for_iterator_binding_strips_done() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src =
		`export fn gen() (int | done) = 0; export fn run() void = { for (let item => gen()) void; };`;
	nav_open(&s, "file:///fe_iter.ha", src);
	const value = nav_hover_contents(&s, out, "file:///fe_iter.ha", 0,
		find_col(src, "item"), 703.0);
	defer free(value);
	assert(strings::contains(value, "let item"));
	assert(strings::contains(value, "int"));
	assert(!strings::contains(value, "done"));
	assert(!strings::contains(value, "gen()"));
};

// Hare's `=>` loop strips only the `done` sentinel and keeps every other
// variant, errors included: a generator typed `(int | done | myerr)` binds
// the loop variable as `(int | myerr)`. Since that union can't be rendered
// from a single existing AST node, hover declines to a bare `let item`
// rather than narrowing to the wrong `int` (dropping `myerr`).
@test fn hover_on_for_iterator_binding_keeps_error_variants() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src =
		`export type myerr = !void; export fn gen() (int | done | myerr) = 0; export fn run() void = { for (let item => gen()) void; };`;
	nav_open(&s, "file:///fe_iter_err.ha", src);
	const value = nav_hover_contents(&s, out, "file:///fe_iter_err.ha", 0,
		find_col(src, "item"), 705.0);
	defer free(value);
	assert(strings::contains(value, "let item"));
	// Must not collapse to the bare value type `int` and drop `myerr`.
	assert(!strings::contains(value, "let item: int"));
};

// Member access through a for-each loop variable resolves to the element
// type's field: `pts` is `[]point`, so `p` is `point` and `p.coord` is the
// struct field. This exercises the struct-member type resolver's
// for-each awareness (distinct from the hover-the-binding path above).
@test fn hover_on_field_of_for_each_loop_var_resolves_element() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src =
		`export type point = struct { coord: int }; export fn run(pts: []point) void = { for (let p .. pts) { let _ = p.coord; }; };`;
	nav_open(&s, "file:///fe_member.ha", src);
	// Land on the last rune of `coord` in `p.coord` (loc.end semantics).
	const col = find_col(src, "p.coord") + len("p.coord"): u32 - 1;
	const value = nav_hover_contents(&s, out, "file:///fe_member.ha", 0, col,
		704.0);
	defer free(value);
	assert(strings::contains(value, "(field)"));
	assert(strings::contains(value, "coord"));
	assert(strings::contains(value, "int"));
};

// A single-segment type alias (e.g. `command` in `parse() command`) must
// resolve within the module that *defines* it, not via a name search that
// could match a same-named type in another module. Two modules export a
// type `command`; only the imported one has an `opts` field. The decoy is
// indexed first, so a short-name search would mis-resolve `command` and the
// element type would be lost. This is the bug that surfaced in CI, where
// the stdlib defines both `getopt::command` and `os::exec::command`.
@test fn hover_on_for_each_binding_resolves_alias_in_owning_module() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const real_path = ".tmp/feamb_real/lib.ha";
	const decoy_path = ".tmp/feamb_decoy/lib.ha";
	const real_text =
		"export type command = struct { opts: [](rune, str) };\nexport fn parse() command = command { opts = [] };\n";
	const decoy_text = "export type command = struct { other: int };\n";
	nav_write_dir(".tmp/feamb_real");
	nav_write_dir(".tmp/feamb_decoy");
	let _ = match (nav_write(real_path, real_text)) {
	case bool =>
		yield true;
	case => abort("cannot write");
	};
	let _ = match (nav_write(decoy_path, decoy_text)) {
	case bool =>
		yield true;
	case => abort("cannot write");
	};
	defer nav_rm(real_path);
	defer nav_rm(decoy_path);
	// Index the decoy first: a short-name search would return it.
	analysis::index_file(&s.workspace_index, decoy_path,
		strings::toutf8(decoy_text));
	analysis::index_file(&s.workspace_index, real_path,
		strings::toutf8(real_text));

	const src =
		`use feamb_real; export fn f() void = { const cmd = feamb_real::parse(); for (let opt .. cmd.opts) { let _ = opt; }; };`;
	nav_open(&s, "file:///fe_amb_main.ha", src);
	const value = nav_hover_contents(&s, out, "file:///fe_amb_main.ha", 0,
		find_col(src, "opt"), 706.0);
	defer free(value);
	assert(strings::contains(value, "let opt"));
	assert(strings::contains(value, "(rune, str)"));
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
	const src = "use lspmoda;\\n\\nfn caller() void = init();\\n";
	nav_open(&s, "file:///caller.ha", src);

	// Position on `init` in caller.ha — line/col looked up at runtime.
	const (line, col) = find_pos(src, "init()");
	const params = pos_params("file:///caller.ha", line, col);
	defer free(params);
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

	// Line 2 references `build_diagnostic` after `d: `. Needle is
	// unique to the usage site, so find_pos lands on the right
	// occurrence even when other lines mention the type.
	const (line, col) = find_pos(src, "d: build_diagnostic");
	const params = pos_params("file:///bd.ha", line, col + 3);
	defer free(params);
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

	// Cursor on `target` (the decl whose doc comment we render).
	const (line, col) = find_pos(src, "fn target");
	const params = pos_params("file:///r.ha", line, col + 3);
	defer free(params);
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

	const (line, col) = find_pos(src, "fn target");
	const params = pos_params("file:///u.ha", line, col + 3);
	defer free(params);
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

// Regression: a match case that diverges via a never-returning call
// (here `boom()`, standing in for `fmt::fatal`) must not leak `never`
// into the binding's inferred type. The compiler reduces `(never | str)`
// to `str` (harec type_store_reduce_result drops `never`), so hover must
// show `str`, not `(never | str)`. See navigation.ha infer_match_expr_type.
@test fn hover_const_match_init_drops_never_branch() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const def_path = ".tmp/hare-lsp-nav-hover-match-never.ha";
	const def_text = "export fn boom() never = abort();\n";
	let _ = match (nav_write(def_path, def_text)) {
	case bool =>
		yield true;
	case => abort("cannot write fixture");
	};
	defer nav_rm(def_path);
	analysis::index_file(&s.workspace_index, def_path, strings::toutf8(def_text));

	// Only the `str` case yields a value; the default diverges via a
	// never-returning call, so the inferred type is just `str`.
	const src =
		"fn caller() void = { const input = match (2z: (str | void)) { case let joined: str => yield joined; case => boom(); }; };\\n";
	nav_open(&s, "file:///mn.ha", src);

	// Cursor on `input` (line 0, char 29).
	const params =
		`{"textDocument":{"uri":"file:///mn.ha"},"position":{"line":0,"character":29}}`;
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
	assert(strings::contains(value, "const input"));
	assert(strings::contains(value, ": str"));
	// The diverging never-call case must not contribute `never`, and the
	// init must not be echoed (which would mean inference failed).
	assert(!strings::contains(value, "never"));
	assert(!strings::contains(value, "match"));
};

// Regression: hovering the binding name in a match case header
// (`case let index: size =>`) must resolve to the local match binding,
// not fall through to an unrelated workspace function of the same name.
// The case body (mc.exprs) does not cover the header, so the binding's
// name had to be located separately. See navigation.ha
// match_case_name_range and walk_for_local (match_expr arm).
@test fn hover_on_match_case_binding_decl_resolves_local() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// An unrelated workspace function also named `index` (mirrors
	// strings::index). Hovering the match binding must not resolve to it.
	const def_path = ".tmp/hare-lsp-nav-hover-match-binding-index.ha";
	const def_text = "export fn index() void = void;\n";
	let _ = match (nav_write(def_path, def_text)) {
	case bool =>
		yield true;
	case => abort("cannot write fixture");
	};
	defer nav_rm(def_path);
	analysis::index_file(&s.workspace_index, def_path, strings::toutf8(def_text));

	const src =
		"fn caller(input: str) void = { const output = match (2z: (size | void)) { case let index: size => yield index; case void => yield 0z; }; };\\n";
	nav_open(&s, "file:///mb.ha", src);

	// Cursor on the binding name `index` in `case let index` (char 85).
	const params =
		`{"textDocument":{"uri":"file:///mb.ha"},"position":{"line":0,"character":85}}`;
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
	assert(strings::contains(value, "(match binding) index: size"));
	assert(!strings::contains(value, "fn index"));
};

// Companion to the decl-site test: hovering the binding at its *use*
// site (in the case body) already resolves to the local binding. This
// guards against the fix for the decl site regressing the body path.
@test fn hover_on_match_case_binding_use_resolves_local() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const def_path = ".tmp/hare-lsp-nav-hover-match-binding-use-index.ha";
	const def_text = "export fn index() void = void;\n";
	let _ = match (nav_write(def_path, def_text)) {
	case bool =>
		yield true;
	case => abort("cannot write fixture");
	};
	defer nav_rm(def_path);
	analysis::index_file(&s.workspace_index, def_path, strings::toutf8(def_text));

	const src =
		"fn caller(input: str) void = { const output = match (2z: (size | void)) { case let index: size => yield index; case void => yield 0z; }; };\\n";
	nav_open(&s, "file:///mbu.ha", src);

	// Cursor on the use of `index` in `yield index` (char 106).
	const params =
		`{"textDocument":{"uri":"file:///mbu.ha"},"position":{"line":0,"character":106}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 496.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 496.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "(match binding) index: size"));
	assert(!strings::contains(value, "fn index"));
};

// Multi-byte guard for the decl-site fix: a multi-byte rune literal
// (`'☃'`) before the match makes byte offsets diverge from the UTF-16
// LSP character offsets, so this fails if match_case_name_range works in
// the wrong unit. The `☃` adds two extra bytes, so the decl `index` sits
// at UTF-16 character 98-102 but a higher byte offset.
@test fn hover_on_match_case_binding_decl_multibyte() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const def_path = ".tmp/hare-lsp-nav-hover-match-binding-mb-index.ha";
	const def_text = "export fn index() void = void;\n";
	let _ = match (nav_write(def_path, def_text)) {
	case bool =>
		yield true;
	case => abort("cannot write fixture");
	};
	defer nav_rm(def_path);
	analysis::index_file(&s.workspace_index, def_path, strings::toutf8(def_text));

	const src =
		"fn caller(input: str) void = { const c = '☃'; const output = match (2z: (size | void)) { case let index: size => yield index; case void => yield 0z; }; };\\n";
	nav_open(&s, "file:///mbm.ha", src);

	// Cursor on the binding name `index` (UTF-16 character 100, mid-token).
	const params =
		`{"textDocument":{"uri":"file:///mbm.ha"},"position":{"line":0,"character":100}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 497.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 497.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "(match binding) index: size"));
	assert(!strings::contains(value, "fn index"));
};

// Regression: an `if`/`else` whose true branch diverges via a
// never-returning call must infer the false branch's type, not `never`.
// The compiler reduces `(never | int)` to `int`. See navigation.ha
// infer_type_from_init_at (if_expr) and drop_never.
@test fn hover_if_else_drops_never_true_branch() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const def_path = ".tmp/hare-lsp-nav-hover-if-never.ha";
	const def_text = "export fn boom() never = abort();\n";
	let _ = match (nav_write(def_path, def_text)) {
	case bool =>
		yield true;
	case => abort("cannot write fixture");
	};
	defer nav_rm(def_path);
	analysis::index_file(&s.workspace_index, def_path, strings::toutf8(def_text));

	// The true branch diverges, so the inferred type is the false
	// branch's `int`, not `never`.
	const src =
		"fn caller() void = { const outcome = if (true) boom() else 5; };\\n";
	nav_open(&s, "file:///in.ha", src);

	// Cursor on `outcome` (line 0, char 29).
	const params =
		`{"textDocument":{"uri":"file:///in.ha"},"position":{"line":0,"character":29}}`;
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
	assert(strings::contains(value, "const outcome"));
	assert(strings::contains(value, ": int"));
	// The diverging true branch must not surface as `never`, and the
	// init must not be echoed (which would mean inference failed).
	assert(!strings::contains(value, "never"));
	assert(!strings::contains(value, "if ("));
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

	// Position on `delta` — looked up at runtime.
	const (line, col) = find_pos(src, "delta = ");
	const params = pos_params("file:///cst.ha", line, col);
	defer free(params);
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

// A1: a binding initialized from a struct field access resolves to the
// field's declared type, instead of echoing the (truncated) `= cfg.timeou`
// source. The field name is multi-char so the loc.end rune bug can't hide.
@test fn hover_binding_init_field_access_shows_field_type() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src =
		`export type config = struct { timeout: size }; export fn run(cfg: config) void = { let value = cfg.timeout; };`;
	nav_open(&s, "file:///a1.ha", src);
	const value = nav_hover_contents(&s, out, "file:///a1.ha", 0,
		find_col(src, "value"), 730.0);
	defer free(value);
	assert(strings::contains(value, "let value"));
	assert(strings::contains(value, "size"));
	assert(!strings::contains(value, "cfg.timeou"));
	assert(!strings::contains(value, "= cfg"));
};

// A2: a binding initialized from an index access resolves to the element
// type of the indexed collection.
@test fn hover_binding_init_index_access_shows_element_type() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src = `export fn run(items: []rune) void = { let elem = items[0]; };`;
	nav_open(&s, "file:///a2.ha", src);
	const value = nav_hover_contents(&s, out, "file:///a2.ha", 0,
		find_col(src, "elem"), 731.0);
	defer free(value);
	assert(strings::contains(value, "let elem"));
	assert(strings::contains(value, "rune"));
	assert(!strings::contains(value, "items["));
	assert(!strings::contains(value, "= items"));
};

// A3: a binding initialized from a tuple field access resolves to the type
// of that tuple element.
@test fn hover_binding_init_tuple_access_shows_field_type() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src = `export fn run(pair: (int, str)) void = { let second = pair.1; };`;
	nav_open(&s, "file:///a3.ha", src);
	const value = nav_hover_contents(&s, out, "file:///a3.ha", 0,
		find_col(src, "second"), 732.0);
	defer free(value);
	assert(strings::contains(value, "let second"));
	assert(strings::contains(value, "str"));
	assert(!strings::contains(value, "pair.1"));
	assert(!strings::contains(value, "= pair"));
};

// A4 (single-segment global): a binding aliasing a top-level global resolves
// through the receiver engine to the global's declared type, rather than
// bailing as a non-local identifier. (Qualified `pkg::name` forms are
// covered by the e2e suite, which exercises real stdlib resolution.)
@test fn hover_binding_init_global_ident_shows_type() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src =
		`export let counter: size = 0z; export fn run() void = { let mirror = counter; };`;
	nav_open(&s, "file:///a4.ha", src);
	const value = nav_hover_contents(&s, out, "file:///a4.ha", 0,
		find_col(src, "mirror"), 733.0);
	defer free(value);
	assert(strings::contains(value, "let mirror"));
	assert(strings::contains(value, "size"));
	assert(!strings::contains(value, "= counter"));
};

// A5 (&): address-of yields a pointer to the operand's type.
@test fn hover_binding_init_addr_of_shows_pointer_type() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src =
		`export type point = struct { coord: int }; export fn run(node: point) void = { let ptr = &node; };`;
	nav_open(&s, "file:///a5addr.ha", src);
	const value = nav_hover_contents(&s, out, "file:///a5addr.ha", 0,
		find_col(src, "ptr"), 740.0);
	defer free(value);
	assert(strings::contains(value, "let ptr"));
	assert(strings::contains(value, "*point"));
	assert(!strings::contains(value, "= &node"));
};

// A5 (*): dereference yields the pointer's referent type.
@test fn hover_binding_init_deref_shows_referent_type() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src =
		`export type point = struct { coord: int }; export fn run(handle: *point) void = { let target = *handle; };`;
	nav_open(&s, "file:///a5deref.ha", src);
	const value = nav_hover_contents(&s, out, "file:///a5deref.ha", 0,
		find_col(src, "target"), 741.0);
	defer free(value);
	assert(strings::contains(value, "let target"));
	assert(strings::contains(value, "point"));
	// Must have actually dereferenced, not echoed `*handle` or kept `*point`.
	assert(!strings::contains(value, "*point"));
	assert(!strings::contains(value, "*handle"));
};

// A5 (-): numeric negation keeps the operand's type.
@test fn hover_binding_init_negation_shows_operand_type() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src = `export fn run(count: i32) void = { let negated = -count; };`;
	nav_open(&s, "file:///a5neg.ha", src);
	const value = nav_hover_contents(&s, out, "file:///a5neg.ha", 0,
		find_col(src, "negated"), 742.0);
	defer free(value);
	assert(strings::contains(value, "let negated"));
	assert(strings::contains(value, "i32"));
	assert(!strings::contains(value, "= -count"));
};

// A5 (~): bitwise complement keeps the operand's type.
@test fn hover_binding_init_complement_shows_operand_type() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src = `export fn run(bits: u16) void = { let flipped = ~bits; };`;
	nav_open(&s, "file:///a5cmpl.ha", src);
	const value = nav_hover_contents(&s, out, "file:///a5cmpl.ha", 0,
		find_col(src, "flipped"), 743.0);
	defer free(value);
	assert(strings::contains(value, "let flipped"));
	assert(strings::contains(value, "u16"));
	assert(!strings::contains(value, "= ~bits"));
};

// A5 (!): logical negation always yields bool.
@test fn hover_binding_init_lnot_shows_bool() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src = `export fn run(flag: bool) void = { let toggled = !flag; };`;
	nav_open(&s, "file:///a5lnot.ha", src);
	const value = nav_hover_contents(&s, out, "file:///a5lnot.ha", 0,
		find_col(src, "toggled"), 744.0);
	defer free(value);
	assert(strings::contains(value, "let toggled"));
	assert(strings::contains(value, ": bool"));
	assert(!strings::contains(value, "= !flag"));
};

// A6: slicing a slice yields a slice of the same element type.
@test fn hover_binding_init_slice_expr_shows_slice_type() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src =
		`export fn run(buffer: []u8) void = { let window = buffer[2..8]; };`;
	nav_open(&s, "file:///a6slice.ha", src);
	const value = nav_hover_contents(&s, out, "file:///a6slice.ha", 0,
		find_col(src, "window"), 745.0);
	defer free(value);
	assert(strings::contains(value, "let window"));
	assert(strings::contains(value, "[]u8"));
	assert(!strings::contains(value, "buffer[2..8]"));
};

// A6: slicing an array yields a slice, not the array type.
@test fn hover_binding_init_slice_of_array_shows_slice_type() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src =
		`export fn run(block: [16]rune) void = { let region = block[..]; };`;
	nav_open(&s, "file:///a6arr.ha", src);
	const value = nav_hover_contents(&s, out, "file:///a6arr.ha", 0,
		find_col(src, "region"), 746.0);
	defer free(value);
	assert(strings::contains(value, "let region"));
	assert(strings::contains(value, "[]rune"));
	// The result is a slice, not the original fixed-length array.
	assert(!strings::contains(value, "[16]"));
};

// A9: size(T) yields `size`.
@test fn hover_binding_init_size_expr_shows_size() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src = `export fn run() void = { let amount = size(u64); };`;
	nav_open(&s, "file:///a9size.ha", src);
	const value = nav_hover_contents(&s, out, "file:///a9size.ha", 0,
		find_col(src, "amount"), 747.0);
	defer free(value);
	assert(strings::contains(value, "let amount"));
	assert(strings::contains(value, ": size"));
	assert(!strings::contains(value, "size(u64)"));
};

// A9: align(T) yields `size`.
@test fn hover_binding_init_align_expr_shows_size() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src = `export fn run() void = { let boundary = align(u64); };`;
	nav_open(&s, "file:///a9align.ha", src);
	const value = nav_hover_contents(&s, out, "file:///a9align.ha", 0,
		find_col(src, "boundary"), 748.0);
	defer free(value);
	assert(strings::contains(value, "let boundary"));
	assert(strings::contains(value, ": size"));
	assert(!strings::contains(value, "align(u64)"));
};

// A9: offset(field) yields `size`.
@test fn hover_binding_init_offset_expr_shows_size() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src =
		`export type packet = struct { header: u32, payload: u64 }; export fn run(pkt: packet) void = { let spot = offset(pkt.payload); };`;
	nav_open(&s, "file:///a9offset.ha", src);
	const value = nav_hover_contents(&s, out, "file:///a9offset.ha", 0,
		find_col(src, "spot"), 749.0);
	defer free(value);
	assert(strings::contains(value, "let spot"));
	assert(strings::contains(value, ": size"));
	assert(!strings::contains(value, "offset("));
};

// C1: `x is T` is a type test that yields bool, not T.
@test fn hover_binding_init_is_test_shows_bool() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src =
		`export fn run(value: (int | str)) void = { let matched = value is int; };`;
	nav_open(&s, "file:///c1is.ha", src);
	const value = nav_hover_contents(&s, out, "file:///c1is.ha", 0,
		find_col(src, "matched"), 751.0);
	defer free(value);
	assert(strings::contains(value, "let matched"));
	assert(strings::contains(value, ": bool"));
	// The test must not surface the target type `int`.
	assert(!strings::contains(value, ": int"));
};

// C1 (control): `x as T` is an assertion that keeps the target type T.
@test fn hover_binding_init_as_cast_keeps_target_type() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src =
		`export fn run(value: (int | str)) void = { let widened = value as int; };`;
	nav_open(&s, "file:///c1as.ha", src);
	const value = nav_hover_contents(&s, out, "file:///c1as.ha", 0,
		find_col(src, "widened"), 752.0);
	defer free(value);
	assert(strings::contains(value, "let widened"));
	assert(strings::contains(value, ": int"));
	assert(!strings::contains(value, ": bool"));
};

// A7: a switch expression's type is the union of its cases' yielded values.
@test fn hover_binding_init_switch_expr_unions_case_yields() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src =
		`export fn run(choice: int) void = { let outcome = switch (choice) { case 1 => yield 42i32; case => yield 99u8; }; };`;
	nav_open(&s, "file:///a7union.ha", src);
	const value = nav_hover_contents(&s, out, "file:///a7union.ha", 0,
		find_col(src, "outcome"), 760.0);
	defer free(value);
	assert(strings::contains(value, "let outcome"));
	assert(strings::contains(value, "i32"));
	assert(strings::contains(value, "u8"));
	assert(strings::contains(value, "|"));
	assert(!strings::contains(value, "switch"));
};

// A7: when every case yields the same type, the switch type is just that
// type (deduplicated, no union).
@test fn hover_binding_init_switch_expr_single_type() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src =
		`export fn run(choice: int) void = { let chosen = switch (choice) { case 1 => yield 10i32; case => yield 20i32; }; };`;
	nav_open(&s, "file:///a7single.ha", src);
	const value = nav_hover_contents(&s, out, "file:///a7single.ha", 0,
		find_col(src, "chosen"), 761.0);
	defer free(value);
	assert(strings::contains(value, "let chosen"));
	assert(strings::contains(value, ": i32"));
	assert(!strings::contains(value, "|"));
};

// A8: a compound block's type is its explicitly-yielded value's type.
@test fn hover_binding_init_compound_yields_value_type() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src =
		`export fn run(input: u32) void = { let computed = { let doubled = input * 2; yield doubled; }; };`;
	nav_open(&s, "file:///a8yield.ha", src);
	const value = nav_hover_contents(&s, out, "file:///a8yield.ha", 0,
		find_col(src, "computed"), 762.0);
	defer free(value);
	assert(strings::contains(value, "let computed"));
	assert(strings::contains(value, "u32"));
	// Inference succeeded, so the block source is not echoed, and a block
	// that ends in `yield` does not add the implicit `void`.
	assert(!strings::contains(value, "= {"));
	assert(!strings::contains(value, "void"));
};

// A8: a block with no yield falls through to an implicit `yield void`, so
// its type is `void` rather than the last (discarded) expression's type.
@test fn hover_binding_init_compound_no_yield_is_void() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src = `export fn run() void = { let nothing = { let temp = 5; }; };`;
	nav_open(&s, "file:///a8void.ha", src);
	const value = nav_hover_contents(&s, out, "file:///a8void.ha", 0,
		find_col(src, "nothing"), 763.0);
	defer free(value);
	assert(strings::contains(value, "let nothing"));
	assert(strings::contains(value, ": void"));
};

// C2: a top-level `def` with no written type infers it from the initializer.
@test fn hover_top_level_def_infers_type() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src = `export def PI = 3.14159;`;
	nav_open(&s, "file:///c2def.ha", src);
	const value = nav_hover_contents(&s, out, "file:///c2def.ha", 0,
		find_col(src, "PI"), 770.0);
	defer free(value);
	assert(strings::contains(value, "def PI"));
	assert(strings::contains(value, ": f64"));
};

// C2: a top-level `let` global with no written type infers it too.
@test fn hover_top_level_global_infers_type() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src = `export let threshold = 0z;`;
	nav_open(&s, "file:///c2let.ha", src);
	const value = nav_hover_contents(&s, out, "file:///c2let.ha", 0,
		find_col(src, "threshold"), 771.0);
	defer free(value);
	assert(strings::contains(value, "let threshold"));
	assert(strings::contains(value, ": size"));
};

// C2: a top-level `const` global with no written type infers it as well.
@test fn hover_top_level_const_infers_type() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src = `export const LIMIT = 100;`;
	nav_open(&s, "file:///c2const.ha", src);
	const value = nav_hover_contents(&s, out, "file:///c2const.ha", 0,
		find_col(src, "LIMIT"), 772.0);
	defer free(value);
	assert(strings::contains(value, "const LIMIT"));
	assert(strings::contains(value, ": int"));
};

// A10: object allocation yields `(*T | nomem)`.
@test fn hover_binding_init_alloc_object_shows_pointer_nomem() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src =
		`export type point = struct { coord: int }; export fn run(node: point) void = { let boxed = alloc(node); };`;
	nav_open(&s, "file:///a10obj.ha", src);
	const value = nav_hover_contents(&s, out, "file:///a10obj.ha", 0,
		find_col(src, "boxed"), 780.0);
	defer free(value);
	assert(strings::contains(value, "let boxed"));
	assert(strings::contains(value, "*point"));
	assert(strings::contains(value, "nomem"));
	assert(!strings::contains(value, "= alloc"));
};

// A10: object allocation from a literal infers the literal's type.
@test fn hover_binding_init_alloc_literal_object() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src = `export fn run() void = { let boxed = alloc(42i32); };`;
	nav_open(&s, "file:///a10lit.ha", src);
	const value = nav_hover_contents(&s, out, "file:///a10lit.ha", 0,
		find_col(src, "boxed"), 781.0);
	defer free(value);
	assert(strings::contains(value, "let boxed"));
	assert(strings::contains(value, "*i32"));
	assert(strings::contains(value, "nomem"));
};

// A10: slice-copy allocation (`x...`) yields `([]T | nomem)`.
@test fn hover_binding_init_alloc_copy_shows_slice_nomem() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src =
		`export fn run(items: []u8) void = { let copied = alloc(items...); };`;
	nav_open(&s, "file:///a10copy.ha", src);
	const value = nav_hover_contents(&s, out, "file:///a10copy.ha", 0,
		find_col(src, "copied"), 782.0);
	defer free(value);
	assert(strings::contains(value, "let copied"));
	assert(strings::contains(value, "[]u8"));
	assert(strings::contains(value, "nomem"));
};

// A10: slice allocation with capacity (`x, cap`) also yields `([]T | nomem)`.
@test fn hover_binding_init_alloc_cap_shows_slice_nomem() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src =
		`export fn run(items: []rune) void = { let grown = alloc(items, 64z); };`;
	nav_open(&s, "file:///a10cap.ha", src);
	const value = nav_hover_contents(&s, out, "file:///a10cap.ha", 0,
		find_col(src, "grown"), 783.0);
	defer free(value);
	assert(strings::contains(value, "let grown"));
	assert(strings::contains(value, "[]rune"));
	assert(strings::contains(value, "nomem"));
};

// A11: `vaarg(ap, T)` infers the explicit type `T`.
@test fn hover_binding_init_vaarg_shows_explicit_type() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src =
		`export fn run(ap: valist) void = { let extracted = vaarg(ap, i64); };`;
	nav_open(&s, "file:///a11vaarg.ha", src);
	const value = nav_hover_contents(&s, out, "file:///a11vaarg.ha", 0,
		find_col(src, "extracted"), 784.0);
	defer free(value);
	assert(strings::contains(value, "let extracted"));
	assert(strings::contains(value, ": i64"));
	assert(!strings::contains(value, "vaarg"));
};

// A12: calling a local function pointer infers the function's result type.
@test fn hover_binding_init_indirect_call_via_fn_pointer() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src =
		`export fn target() i32 = 0i32; export fn run() void = { let handler: *fn() i32 = &target; let result = handler(); };`;
	nav_open(&s, "file:///a12fnptr.ha", src);
	const value = nav_hover_contents(&s, out, "file:///a12fnptr.ha", 0,
		find_col(src, "result"), 785.0);
	defer free(value);
	assert(strings::contains(value, "let result"));
	assert(strings::contains(value, "i32"));
	assert(!strings::contains(value, "handler()"));
};

// D1: an array literal renders as `[N]T` with the real element type.
@test fn hover_binding_init_array_literal_shows_sized_type() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src = `export fn run() void = { let nums = [10, 20, 30]; };`;
	nav_open(&s, "file:///d1arr.ha", src);
	const value = nav_hover_contents(&s, out, "file:///d1arr.ha", 0,
		find_col(src, "nums"), 786.0);
	defer free(value);
	assert(strings::contains(value, "let nums"));
	assert(strings::contains(value, "[3]int"));
};

// D2: a named struct literal renders as the type name, not `struct { ... }`.
@test fn hover_binding_init_named_struct_literal_shows_alias() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src =
		`export type point = struct { coord: int }; export fn run() void = { let origin = point { coord = 0 }; };`;
	nav_open(&s, "file:///d2struct.ha", src);
	const value = nav_hover_contents(&s, out, "file:///d2struct.ha", 0,
		find_col(src, "origin"), 787.0);
	defer free(value);
	assert(strings::contains(value, "let origin"));
	assert(strings::contains(value, ": point"));
	assert(!strings::contains(value, "struct {"));
};

// D3: a tuple literal renders as `(T, U, ...)` with real element types.
@test fn hover_binding_init_tuple_literal_shows_element_types() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src = `export fn run() void = { let pair = (1, 2u8); };`;
	nav_open(&s, "file:///d3tuple.ha", src);
	const value = nav_hover_contents(&s, out, "file:///d3tuple.ha", 0,
		find_col(src, "pair"), 788.0);
	defer free(value);
	assert(strings::contains(value, "let pair"));
	assert(strings::contains(value, "(int, u8)"));
};

// Regression: a self-referential binding reached through a compound-block
// yield must not recurse forever. Block-value inference threads the depth so
// the cycle guard in infer_access_expr_type trips instead of overflowing the
// stack (this previously SIGSEGV'd). Hover returns gracefully (echoing the
// unresolved init) rather than crashing.
@test fn hover_self_referential_compound_yield_terminates() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src = `export fn run() void = { let cyclic = { yield cyclic; }; };`;
	nav_open(&s, "file:///cycle1.ha", src);
	const value = nav_hover_contents(&s, out, "file:///cycle1.ha", 0,
		find_col(src, "cyclic"), 796.0);
	defer free(value);
	assert(strings::contains(value, "let cyclic"));
};

// Same cycle reached through a switch yield (the other block form that
// routes through infer_block_value_type).
@test fn hover_self_referential_switch_yield_terminates() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src =
		`export fn run(tag: int) void = { let cyclic = switch (tag) { case => yield cyclic; }; };`;
	nav_open(&s, "file:///cycle2.ha", src);
	const value = nav_hover_contents(&s, out, "file:///cycle2.ha", 0,
		find_col(src, "cyclic"), 797.0);
	defer free(value);
	assert(strings::contains(value, "let cyclic"));
};

// Chain: a -> 1; b -> a; c -> b. The local-identifier follow in
// infer_access_expr_type is bounded by
// `inlay_hints_inferred_types_max_depth`. With depth=1, walking from c
// to b's init (`a`) trips the limit and the hover falls back without
// the resolved type. With depth=3, the chain resolves all the way to
// the literal, so hover renders `let c: int`.
@test fn hover_let_local_chain_bounded_by_inferred_types_max_depth() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src = "fn f() void = { let a = 1; let b = a; let c = b; };\\n";
	nav_open(&s, "file:///chain.ha", src);

	const col = find_col(src, "c = b");
	const params = pos_params("file:///chain.ha", 0, col);
	defer free(params);

	// depth=1: the access_expr at depth=0 enters once (looking up
	// `b`), recurses with depth=1, and the next access_expr (looking
	// up `a`) hits `depth >= max_depth` and returns void. The chain
	// is not resolved, so the hover does not contain ": int".
	s.config.inlay_hints_inferred_types_max_depth = 1;
	let pv1 = json::loadstr(params)!;
	defer json::finish(pv1);
	const r1 = lsp::request {
		id = 6100.0,
		method = strings::dup("textDocument/hover")!,
		params = pv1,
	};
	defer free(r1.method);
	handle_hover(&s, r1);
	const v1 = skip_to_response(out, 6100.0);
	defer json::finish(v1);
	const v1_str = hover_value_str(v1);
	assert(strings::contains(v1_str, "let c"));
	assert(
		!strings::contains(v1_str, ": int"),
		"with depth=1 hover for `c` must not resolve through the chain to int"
	);

	// depth=3: the chain has room to walk c -> b -> a -> literal.
	s.config.inlay_hints_inferred_types_max_depth = 3;
	let pv2 = json::loadstr(params)!;
	defer json::finish(pv2);
	const r2 = lsp::request {
		id = 6101.0,
		method = strings::dup("textDocument/hover")!,
		params = pv2,
	};
	defer free(r2.method);
	handle_hover(&s, r2);
	const v2 = skip_to_response(out, 6101.0);
	defer json::finish(v2);
	const v2_str = hover_value_str(v2);
	assert(strings::contains(v2_str, "let c"));
	assert(
		strings::contains(v2_str, ": int"),
		"with depth=3 hover for `c` must resolve through the chain to int"
	);
};

fn hover_value_str(v: json::value) str = {
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	return *(json::get(&contents, "value") as *json::value) as str;
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
	const src = "use bufio;\\nfn f() void = { bufio::newscanner(0); };\\n";
	nav_open(&s, "file:///mb3.ha", src);

	// Position on the second `bufio` (in the body) — the needle
	// `bufio::` is unique to the call site, so find_pos lands there.
	const (line, col) = find_pos(src, "bufio::");
	const params = pos_params("file:///mb3.ha", line, col);
	defer free(params);
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

// --- runtime position helpers ---
//
// Tests construct LSP-position params from inline source strings.
// Hardcoding `"character":N` couples the test to exact column
// counting and silently breaks on any edit to the source. The
// helpers below let tests look up the cursor column at runtime
// from the source text and a needle substring.

// Decodes the JSON-escape sequences (`\n`, `\t`, `\\`, `\"`, `\r`)
// commonly used in test-source strings so the byte offset of a
// needle matches what the LSP sees after json-decoding the
// request body. Unknown escapes pass through unchanged.
//
// @returns: owned
fn decode_test_src(src: str) []u8 = {
	const bytes = strings::toutf8(src);
	let out: []u8 = [];
	let i = 0z;
	for (i < len(bytes)) {
		if (bytes[i] == '\\' && i + 1 < len(bytes)) {
			switch (bytes[i + 1]) {
			case 'n' =>
				append(out, '\n': u8)!;
				i += 2;
				continue;
			case 't' =>
				append(out, '\t': u8)!;
				i += 2;
				continue;
			case '\\' =>
				append(out, '\\': u8)!;
				i += 2;
				continue;
			case '"' =>
				append(out, '"': u8)!;
				i += 2;
				continue;
			case 'r' =>
				append(out, '\r': u8)!;
				i += 2;
				continue;
			case => void;
			};
		};
		append(out, bytes[i])!;
		i += 1;
	};
	return out;
};

// Returns the LSP (line, character) of the first occurrence of
// `needle` within the JSON-escaped test source string `src`.
// Aborts if not found. Assumes ASCII source within the cursor's
// line (UTF-8 byte == LSP character under UTF-8/UTF-16 for ASCII).
fn find_pos(src: str, needle: str) (u32, u32) = {
	const decoded = decode_test_src(src);
	defer free(decoded);
	const needle_bytes = strings::toutf8(needle);
	const off = match (bytes::index(decoded, needle_bytes)) {
	case let i: size =>
		yield i;
	case void => abort("find_pos: needle not found in src");
	};
	let line = 0u32;
	let line_start = 0z;
	for (let i = 0z; i < off; i += 1) {
		if (decoded[i] == '\n') {
			line += 1;
			line_start = i + 1;
		};
	};
	return (line, (off - line_start): u32);
};

// Returns the LSP character column of the first occurrence of
// `needle` in `src`, asserting the match lives on line 0. Use this
// for single-line tests; reach for [[find_pos]] when the source
// spans multiple lines.
fn find_col(src: str, needle: str) u32 = {
	const (line, col) = find_pos(src, needle);
	assert(line == 0u32, "find_col: needle is not on line 0");
	return col;
};

// Builds a `textDocument/<method>`-shaped position params JSON
// string. The result is owned by the caller; pair with `defer free`.
//
// @returns: owned
fn pos_params(uri: str, line: u32, ch: u32) str = {
	return strings::concat(`{"textDocument":{"uri":"`, uri,
		`"},"position":{"line":`, fmt_u32(line), `,"character":`, fmt_u32(ch), `}}`)!;
};

// Sends a `textDocument/hover` at (line, ch) and returns the response's
// `contents.value` markdown string. Assumes the document is already open.
// Aborts if the response isn't a hover result. Caller frees.
//
// @returns: owned
fn nav_hover_contents(
	s: *server,
	out: *memio::stream,
	uri: str,
	line: u32,
	ch: u32,
	id: f64,
) str = {
	const params = pos_params(uri, line, ch);
	defer free(params);
	let pv = json::loadstr(params)!;
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
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	return strings::dup(value)!;
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
