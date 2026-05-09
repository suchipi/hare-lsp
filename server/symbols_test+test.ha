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

fn sym_test_server() (server, *bufio::scanner, *memio::stream, *memio::stream) = {
	let in_buf = alloc(memio::fixed([]))!;
	let scan = alloc(bufio::newscanner(in_buf))!;
	let out = alloc(memio::dynamic())!;
	let s = new(scan, out);
	return (s, scan, in_buf, out);
};

fn sym_test_cleanup(s: *server, scan: *bufio::scanner, in_buf: *memio::stream, out: *memio::stream) void = {
	finish(s);
	bufio::finish(scan);
	free(scan);
	free(in_buf);
	io::close(out)!;
	free(out);
};

fn sym_open(s: *server, uri: str, text: str) void = {
	const open = strings::concat(`{"textDocument":{"uri":"`, uri,
		`","languageId":"hare","version":1,"text":"`, text, `"}}`)!;
	defer free(open);
	let pv = json::loadstr(open)!;
	const n = lsp::notification {
		method = strings::dup("textDocument/didOpen")!,
		params = pv,
	};
	defer { free(n.method); json::finish(pv); };
	handle_did_open(s, n);
};

fn sym_skip_to_response(out: *memio::stream, request_id: f64) json::value = {
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

@test fn document_symbol_lists_all_decls() void = {
	let (s, scan, in_buf, out) = sym_test_server();
	defer sym_test_cleanup(&s, scan, in_buf, out);
	sym_open(&s, "file:///x.ha", "fn a() void = void;\\nfn b() void = void;\\ntype c = int;\\n");

	const params = `{"textDocument":{"uri":"file:///x.ha"}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 1.0,
		method = strings::dup("textDocument/documentSymbol")!,
		params = pv,
	};
	defer free(r.method);
	handle_document_symbol(&s, r);
	const v = sym_skip_to_response(out, 1.0);
	defer json::finish(v);
	const result = *(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	assert(len(result) == 3);
};

@test fn folding_range_returns_decls() void = {
	let (s, scan, in_buf, out) = sym_test_server();
	defer sym_test_cleanup(&s, scan, in_buf, out);
	// Multi-line decl so it folds.
	sym_open(&s, "file:///x.ha", "export fn long() void = {\\n\\treturn;\\n};\\n");

	const params = `{"textDocument":{"uri":"file:///x.ha"}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 2.0,
		method = strings::dup("textDocument/foldingRange")!,
		params = pv,
	};
	defer free(r.method);
	handle_folding_range(&s, r);
	const v = sym_skip_to_response(out, 2.0);
	defer json::finish(v);
	const result = *(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	assert(len(result) >= 1);
};

@test fn document_link_returns_imports() void = {
	let (s, scan, in_buf, out) = sym_test_server();
	defer sym_test_cleanup(&s, scan, in_buf, out);
	sym_open(&s, "file:///x.ha", "use io;\\nuse strings;\\n\\nexport fn main() void = void;\\n");

	const params = `{"textDocument":{"uri":"file:///x.ha"}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 3.0,
		method = strings::dup("textDocument/documentLink")!,
		params = pv,
	};
	defer free(r.method);
	handle_document_link(&s, r);
	const v = sym_skip_to_response(out, 3.0);
	defer json::finish(v);
	const result = *(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	assert(len(result) == 2);
};

@test fn document_highlight_returns_decl_range() void = {
	let (s, scan, in_buf, out) = sym_test_server();
	defer sym_test_cleanup(&s, scan, in_buf, out);
	sym_open(&s, "file:///x.ha", "fn target() void = void;\\n");

	const params = `{"textDocument":{"uri":"file:///x.ha"},"position":{"line":0,"character":4}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 4.0,
		method = strings::dup("textDocument/documentHighlight")!,
		params = pv,
	};
	defer free(r.method);
	handle_document_highlight(&s, r);
	const v = sym_skip_to_response(out, 4.0);
	defer json::finish(v);
	const result = *(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	assert(len(result) >= 1);
};
