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

fn st_test_server() (server, *bufio::scanner, *memio::stream, *memio::stream) = {
	let in_buf = alloc(memio::fixed([]))!;
	let scan = alloc(bufio::newscanner(in_buf))!;
	let out = alloc(memio::dynamic())!;
	let s = new(scan, out);
	return (s, scan, in_buf, out);
};

fn st_test_cleanup(s: *server, scan: *bufio::scanner, in_buf: *memio::stream, out: *memio::stream) void = {
	finish(s);
	bufio::finish(scan);
	free(scan);
	free(in_buf);
	io::close(out)!;
	free(out);
};

fn st_open(s: *server, uri: str, text: str) void = {
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

fn st_skip_to_response(out: *memio::stream, request_id: f64) json::value = {
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

@test fn semantic_tokens_full_includes_result_id() void = {
	let (s, scan, in_buf, out) = st_test_server();
	defer st_test_cleanup(&s, scan, in_buf, out);
	st_open(&s, "file:///x.ha", "fn main() void = void;\\n");

	const params = `{"textDocument":{"uri":"file:///x.ha"}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 1.0,
		method = strings::dup("textDocument/semanticTokens/full")!,
		params = pv,
	};
	defer free(r.method);
	handle_semantic_tokens_full(&s, r);
	const v = st_skip_to_response(out, 1.0);
	defer json::finish(v);
	const result = *(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const result_id = *(json::get(&result, "resultId") as *json::value) as str;
	assert(len(result_id) > 0);
	const data_arr = *(json::get(&result, "data") as *json::value) as []json::value;
	assert(len(data_arr) > 0);
};

@test fn semantic_tokens_delta_with_correct_id_returns_edits() void = {
	let (s, scan, in_buf, out) = st_test_server();
	defer st_test_cleanup(&s, scan, in_buf, out);
	st_open(&s, "file:///x.ha", "fn a() void = void;\\nfn b() void = void;\\n");

	// Step 1: full request, capture resultId.
	const full_params = `{"textDocument":{"uri":"file:///x.ha"}}`;
	let fpv = json::loadstr(full_params)!;
	defer json::finish(fpv);
	const full_req = lsp::request {
		id = 1.0,
		method = strings::dup("textDocument/semanticTokens/full")!,
		params = fpv,
	};
	defer free(full_req.method);
	handle_semantic_tokens_full(&s, full_req);
	const v1 = st_skip_to_response(out, 1.0);
	defer json::finish(v1);
	const r1 = *(json::get(&(v1 as json::object), "result") as *json::value) as json::object;
	const id1 = *(json::get(&r1, "resultId") as *json::value) as str;

	// Step 2: delta request with the same id (no edits made yet, so no
	// changes — should produce empty edits).
	const delta_params = strings::concat(`{"textDocument":{"uri":"file:///x.ha"},"previousResultId":"`,
		id1, `"}`)!;
	defer free(delta_params);
	let dpv = json::loadstr(delta_params)!;
	defer json::finish(dpv);
	const delta_req = lsp::request {
		id = 2.0,
		method = strings::dup("textDocument/semanticTokens/full/delta")!,
		params = dpv,
	};
	defer free(delta_req.method);
	handle_semantic_tokens_full_delta(&s, delta_req);
	const v2 = st_skip_to_response(out, 2.0);
	defer json::finish(v2);
	const r2 = *(json::get(&(v2 as json::object), "result") as *json::value) as json::object;
	// Should have edits (possibly empty array) and a fresh resultId.
	assert(json::get(&r2, "edits") is *json::value);
	const edits = *(json::get(&r2, "edits") as *json::value) as []json::value;
	assert(len(edits) == 0); // No changes => no diff edits
};

@test fn semantic_tokens_delta_with_stale_id_falls_back_to_full() void = {
	let (s, scan, in_buf, out) = st_test_server();
	defer st_test_cleanup(&s, scan, in_buf, out);
	st_open(&s, "file:///x.ha", "fn a() void = void;\\n");

	// Delta request with an id we never issued.
	const delta_params = `{"textDocument":{"uri":"file:///x.ha"},"previousResultId":"bogus-id-9999"}`;
	let pv = json::loadstr(delta_params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 5.0,
		method = strings::dup("textDocument/semanticTokens/full/delta")!,
		params = pv,
	};
	defer free(r.method);
	handle_semantic_tokens_full_delta(&s, r);
	const v = st_skip_to_response(out, 5.0);
	defer json::finish(v);
	const result = *(json::get(&(v as json::object), "result") as *json::value) as json::object;
	// Falls back to full: has `data`, not `edits`.
	assert(json::get(&result, "data") is *json::value);
	assert(json::get(&result, "edits") is void);
};

@test fn diff_bounds_identical_returns_zero_range() void = {
	const a: []u32 = [1, 2, 3, 4];
	const b: []u32 = [1, 2, 3, 4];
	const (lo, ho, hn) = diff_bounds(a, b);
	assert(lo == 4 && ho == 4 && hn == 4);
};

@test fn diff_bounds_finds_middle_change() void = {
	const a: []u32 = [1, 2, 3, 4, 5];
	const b: []u32 = [1, 2, 9, 4, 5];
	const (lo, ho, hn) = diff_bounds(a, b);
	assert(lo == 2);
	assert(ho == 3);
	assert(hn == 3);
};

@test fn diff_bounds_handles_insertion() void = {
	const a: []u32 = [1, 2, 5];
	const b: []u32 = [1, 2, 3, 4, 5];
	const (lo, ho, hn) = diff_bounds(a, b);
	assert(lo == 2);
	assert(ho == 2);
	assert(hn == 4);
};

@test fn diff_bounds_handles_deletion() void = {
	const a: []u32 = [1, 2, 3, 4, 5];
	const b: []u32 = [1, 5];
	const (lo, ho, hn) = diff_bounds(a, b);
	assert(lo == 1);
	assert(ho == 4);
	assert(hn == 1);
};
