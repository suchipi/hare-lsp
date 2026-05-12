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

fn pull_test_server(

) (server, *bufio::scanner, *memio::stream, *memio::stream) = {
	let in_buf = alloc(memio::fixed([]))!;
	let scan = alloc(bufio::newscanner(in_buf))!;
	let out = alloc(memio::dynamic())!;
	let s = new(scan, out);
	return (s, scan, in_buf, out);
};

fn pull_test_cleanup(
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

fn next_pull_msg(data: []u8) (json::value, size) = {
	const sep = bytes::index(data, strings::toutf8("\r\n\r\n")) as size;
	const headers = strings::fromutf8(data[..sep])!;
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
	const body_start = sep + 4;
	const body = data[body_start..body_start + length];
	const v = json::loadstr(strings::fromutf8(body)!)!;
	return (v, body_start + length);
};

@test fn textdocument_diagnostic_returns_full_report() void = {
	let (s, scan, in_buf, out) = pull_test_server();
	defer pull_test_cleanup(&s, scan, in_buf, out);

	// Open a file with a syntax error.
	const open =
		`{"textDocument":{"uri":"file:///x.ha","languageId":"hare","version":1,"text":"export fn bad( = void;\n"}}`;
	let pv = json::loadstr(open)!;
	const open_n = lsp::notification {
		method = strings::dup("textDocument/didOpen")!,
		params = pv,
	};
	defer {
		free(open_n.method);
		json::finish(pv);
	};
	handle_did_open(&s, open_n);

	// Issue a textDocument/diagnostic request.
	const params = `{"textDocument":{"uri":"file:///x.ha"}}`;
	let req_pv = json::loadstr(params)!;
	defer json::finish(req_pv);
	const req = lsp::request {
		id = 1.0,
		method = strings::dup("textDocument/diagnostic")!,
		params = req_pv,
	};
	defer free(req.method);
	handle_textdocument_diagnostic(&s, req);

	// Walk to the response (skip the publishDiagnostics from didOpen).
	const data = memio::buffer(out);
	const (v1, off1) = next_pull_msg(data);
	defer json::finish(v1);
	// v1 is the publishDiagnostics notification.
	const (v2, _) = next_pull_msg(data[off1..]);
	defer json::finish(v2);
	const o = v2 as json::object;
	assert(*(json::get(&o, "id") as *json::value) as f64 == 1.0);
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	assert(*(json::get(&result, "kind") as *json::value) as str == "full");
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	assert(len(items) >= 1);
};

@test fn textdocument_diagnostic_unknown_uri_returns_empty() void = {
	let (s, scan, in_buf, out) = pull_test_server();
	defer pull_test_cleanup(&s, scan, in_buf, out);

	const params = `{"textDocument":{"uri":"file:///nope.ha"}}`;
	let req_pv = json::loadstr(params)!;
	defer json::finish(req_pv);
	const req = lsp::request {
		id = 5.0,
		method = strings::dup("textDocument/diagnostic")!,
		params = req_pv,
	};
	defer free(req.method);
	handle_textdocument_diagnostic(&s, req);

	const data = memio::buffer(out);
	const (v, _) = next_pull_msg(data);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	assert(len(items) == 0);
};

@test fn workspace_diagnostic_returns_per_doc_reports() void = {
	let (s, scan, in_buf, out) = pull_test_server();
	defer pull_test_cleanup(&s, scan, in_buf, out);

	// Open two files.
	for (let i = 0z; i < 2; i += 1) {
		let url = "file:///a.ha";
		if (i == 1) url = "file:///b.ha";
		const open =
			strings::concat(
				`{"textDocument":{"uri":"`, url,
				`","languageId":"hare","version":1,"text":"export fn ok() void = void;\n"}}`,
			)!;
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
		handle_did_open(&s, n);
	};

	// Issue workspace/diagnostic.
	let req_pv = json::loadstr(`{"previousResultIds":[]}`)!;
	defer json::finish(req_pv);
	const req = lsp::request {
		id = 9.0,
		method = strings::dup("workspace/diagnostic")!,
		params = req_pv,
	};
	defer free(req.method);
	handle_workspace_diagnostic(&s, req);

	// Walk past the two publishDiagnostics from didOpen, then read the response.
	const data = memio::buffer(out);
	let off = 0z;
	for (let skipped = 0z; skipped < 2; skipped += 1) {
		const (v, n) = next_pull_msg(data[off..]);
		defer json::finish(v);
		off += n;
	};
	const (v, _) = next_pull_msg(data[off..]);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	assert(len(items) == 2);
	for (let i = 0z; i < len(items); i += 1) {
		const item = items[i] as json::object;
		assert(*(json::get(&item, "kind") as *json::value) as str == "full");
		// "uri" must be present.
		assert(json::get(&item, "uri") is *json::value);
	};
};
