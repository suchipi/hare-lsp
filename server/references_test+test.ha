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

fn ref_test_server(

) (server, *bufio::scanner, *memio::stream, *memio::stream) = {
	let in_buf = alloc(memio::fixed([]))!;
	let scan = alloc(bufio::newscanner(in_buf))!;
	let out = alloc(memio::dynamic())!;
	let s = new(scan, out);
	return (s, scan, in_buf, out);
};

fn ref_test_cleanup(
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

fn ref_open(s: *server, uri: str, text: str) void = {
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

fn ref_skip_to_response(out: *memio::stream, request_id: f64) json::value = {
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

@test fn references_returns_all_textual_occurrences() void = {
	let (s, scan, in_buf, out) = ref_test_server();
	defer ref_test_cleanup(&s, scan, in_buf, out);
	ref_open(&s, "file:///x.ha",
		"fn target() void = void;\\nfn caller() void = target();\\n");

	// Position cursor on "target" in the decl.
	const params =
		`{"textDocument":{"uri":"file:///x.ha"},"position":{"line":0,"character":4},"context":{"includeDeclaration":true}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 1.0,
		method = strings::dup("textDocument/references")!,
		params = pv,
	};
	defer free(r.method);
	handle_references(&s, r);
	const v = ref_skip_to_response(out, 1.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	// Two occurrences: the decl and the call site.
	assert(len(result) == 2);
};

@test fn prepare_rename_returns_ident_range() void = {
	let (s, scan, in_buf, out) = ref_test_server();
	defer ref_test_cleanup(&s, scan, in_buf, out);
	ref_open(&s, "file:///x.ha", "fn name() void = void;\\n");

	const params =
		`{"textDocument":{"uri":"file:///x.ha"},"position":{"line":0,"character":4}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 2.0,
		method = strings::dup("textDocument/prepareRename")!,
		params = pv,
	};
	defer free(r.method);
	handle_prepare_rename(&s, r);
	const v = ref_skip_to_response(out, 2.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	// Should be a Range.
	const start = *(json::get(&result, "start") as *json::value) as json::object;
	assert(*(json::get(&start, "character") as *json::value) as f64 == 3.0);
};

@test fn rename_to_keyword_is_rejected() void = {
	let (s, scan, in_buf, out) = ref_test_server();
	defer ref_test_cleanup(&s, scan, in_buf, out);
	ref_open(&s, "file:///x.ha", "fn target() void = void;\\n");

	const params =
		`{"textDocument":{"uri":"file:///x.ha"},"position":{"line":0,"character":4},"newName":"fn"}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 3.0,
		method = strings::dup("textDocument/rename")!,
		params = pv,
	};
	defer free(r.method);
	handle_rename(&s, r);
	const v = ref_skip_to_response(out, 3.0);
	defer json::finish(v);
	const o = v as json::object;
	// Error response, not result.
	assert(json::get(&o, "error") is *json::value);
};

@test fn rename_returns_workspace_edit() void = {
	let (s, scan, in_buf, out) = ref_test_server();
	defer ref_test_cleanup(&s, scan, in_buf, out);
	ref_open(&s, "file:///x.ha", "fn target() void = void;\\n");

	const params =
		`{"textDocument":{"uri":"file:///x.ha"},"position":{"line":0,"character":4},"newName":"renamed"}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 4.0,
		method = strings::dup("textDocument/rename")!,
		params = pv,
	};
	defer free(r.method);
	handle_rename(&s, r);
	const v = ref_skip_to_response(out, 4.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const changes =
		*(json::get(&result, "changes") as *json::value) as json::object;
	const edits =
		*(json::get(&changes, "file:///x.ha") as *json::value) as []json::value;
	assert(len(edits) >= 1);
	const e0 = edits[0] as json::object;
	assert(*(json::get(&e0, "newText") as *json::value) as str == "renamed");
};

@test fn references_skip_matches_inside_comments_and_strings() void = {
	let (s, scan, in_buf, out) = ref_test_server();
	defer ref_test_cleanup(&s, scan, in_buf, out);
	// Buffer has 'target' as a decl name and also inside a //-comment,
	// inside a string literal, and inside a /* */ block comment.
	// Only the decl and the actual call site should match.
	const src =
		"fn target() void = void;\\n// target referenced in a comment\\nfn caller() void = {\\n\\tconst note = \\\"call target with this\\\";\\n\\t/* target in block comment */\\n\\ttarget();\\n};\\n";
	ref_open(&s, "file:///cmt.ha", src);

	const params =
		`{"textDocument":{"uri":"file:///cmt.ha"},"position":{"line":0,"character":4},"context":{"includeDeclaration":true}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 5.0,
		method = strings::dup("textDocument/references")!,
		params = pv,
	};
	defer free(r.method);
	handle_references(&s, r);
	const v = ref_skip_to_response(out, 5.0);
	defer json::finish(v);
	const arr =
		*(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	// Decl + call site = 2 hits exactly. Comments/strings must NOT match.
	assert(len(arr) == 2);
};
