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

fn cl_test_server() (server, *bufio::scanner, *memio::stream, *memio::stream) = {
	let in_buf = alloc(memio::fixed([]))!;
	let scan = alloc(bufio::newscanner(in_buf))!;
	let out = alloc(memio::dynamic())!;
	let s = new(scan, out);
	return (s, scan, in_buf, out);
};

fn cl_test_cleanup(s: *server, scan: *bufio::scanner, in_buf: *memio::stream, out: *memio::stream) void = {
	finish(s);
	bufio::finish(scan);
	free(scan);
	free(in_buf);
	io::close(out)!;
	free(out);
};

fn cl_open(s: *server, uri: str, text: str) void = {
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

fn cl_skip_to_response(out: *memio::stream, request_id: f64) json::value = {
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

@test fn codelens_runtest_carries_function_name() void = {
	let (s, scan, in_buf, out) = cl_test_server();
	defer cl_test_cleanup(&s, scan, in_buf, out);
	cl_open(&s, "file:///t.ha", "@test fn my_test() void = void;\\n");

	const params = `{"textDocument":{"uri":"file:///t.ha"}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 70.0,
		method = strings::dup("textDocument/codeLens")!,
		params = pv,
	};
	defer free(r.method);
	handle_code_lens(&s, r);

	const v = cl_skip_to_response(out, 70.0);
	defer json::finish(v);
	const arr = *(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	// At least one lens — the run-test one.
	let found = false;
	for (let i = 0z; i < len(arr); i += 1) {
		const lens = arr[i] as json::object;
		const cmd_v = match (json::get(&lens, "command")) {
		case let p: *json::value => yield *p;
		case void => continue;
		};
		const cmd = cmd_v as json::object;
		const cmd_str = *(json::get(&cmd, "command") as *json::value) as str;
		if (cmd_str != "hare-lsp.runTest") continue;
		const title = *(json::get(&cmd, "title") as *json::value) as str;
		assert(strings::contains(title, "my_test"));
		const args = *(json::get(&cmd, "arguments") as *json::value) as []json::value;
		// args = [uri, "my_test"].
		assert(len(args) == 2);
		assert(args[1] as str == "my_test");
		found = true;
	};
	assert(found);
};
