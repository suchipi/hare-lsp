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

fn th_test_server() (server, *bufio::scanner, *memio::stream, *memio::stream) = {
	let in_buf = alloc(memio::fixed([]))!;
	let scan = alloc(bufio::newscanner(in_buf))!;
	let out = alloc(memio::dynamic())!;
	let s = new(scan, out);
	return (s, scan, in_buf, out);
};

fn th_test_cleanup(s: *server, scan: *bufio::scanner, in_buf: *memio::stream, out: *memio::stream) void = {
	finish(s);
	bufio::finish(scan);
	free(scan);
	free(in_buf);
	io::close(out)!;
	free(out);
};

fn th_open(s: *server, uri: str, text: str) void = {
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

fn th_skip_to_response(out: *memio::stream, request_id: f64) json::value = {
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

// Indexes a fake file directly into the workspace index.
fn th_index(s: *server, path: str, text: str) void = {
	analysis::index_file(&s.workspace_index, path, strings::toutf8(text));
};

@test fn supertypes_of_alias_returns_underlying_type() void = {
	let (s, scan, in_buf, out) = th_test_server();
	defer th_test_cleanup(&s, scan, in_buf, out);

	// Create a workspace where A = B and B = int.
	// Both decls live in /repo/x.ha.
	const text = "type A = B;\\ntype B = int;\\n";
	th_open(&s, "file:///repo/x.ha", text);
	// Also index it so subtypes can find it.
	th_index(&s, "/repo/x.ha", "type A = B;\ntype B = int;\n");

	const params = `{"item":{"name":"A","kind":23,"uri":"file:///repo/x.ha","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":11}},"selectionRange":{"start":{"line":0,"character":0},"end":{"line":0,"character":11}}}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 1.0,
		method = strings::dup("typeHierarchy/supertypes")!,
		params = pv,
	};
	defer free(r.method);
	handle_supertypes(&s, r);
	const v = th_skip_to_response(out, 1.0);
	defer json::finish(v);
	const result = *(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	// Expect at least one item (B).
	assert(len(result) >= 1);
	let found_b = false;
	for (let i = 0z; i < len(result); i += 1) {
		const item = result[i] as json::object;
		const n = *(json::get(&item, "name") as *json::value) as str;
		if (n == "B") found_b = true;
	};
	assert(found_b);
};

@test fn subtypes_of_underlying_returns_alias() void = {
	let (s, scan, in_buf, out) = th_test_server();
	defer th_test_cleanup(&s, scan, in_buf, out);

	// Build a file on disk so the subtypes scan can find it.
	// We use the .tmp dir per project rules.
	const path = ".tmp/hare-lsp-th-subtypes-test.ha";
	const text = "type Wrapper = Inner;\ntype Inner = int;\n";
	let f = match (writefile(path, text)) {
	case bool => yield true;
	case => abort("cannot write fixture");
	};
	defer rmfile(path);

	th_index(&s, path, text);

	// Ask: what are Inner's subtypes? Expect Wrapper.
	const params_str = strings::concat(`{"item":{"name":"Inner","kind":23,"uri":"file://`, path,
		`","range":{"start":{"line":1,"character":0},"end":{"line":1,"character":17}},"selectionRange":{"start":{"line":1,"character":0},"end":{"line":1,"character":17}}}}`)!;
	defer free(params_str);
	let pv = json::loadstr(params_str)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 2.0,
		method = strings::dup("typeHierarchy/subtypes")!,
		params = pv,
	};
	defer free(r.method);
	handle_subtypes(&s, r);
	const v = th_skip_to_response(out, 2.0);
	defer json::finish(v);
	const result = *(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	let found_wrapper = false;
	for (let i = 0z; i < len(result); i += 1) {
		const item = result[i] as json::object;
		const n = *(json::get(&item, "name") as *json::value) as str;
		if (n == "Wrapper") found_wrapper = true;
	};
	assert(found_wrapper);
};

@test fn supertypes_of_tagged_union_lists_variants() void = {
	let (s, scan, in_buf, out) = th_test_server();
	defer th_test_cleanup(&s, scan, in_buf, out);

	// type T = (A | B); type A = int; type B = str;
	const path = ".tmp/hare-lsp-th-tagged-test.ha";
	const text = "type T = (A | B);\ntype A = int;\ntype B = str;\n";
	let _ = match (writefile(path, text)) {
	case bool => yield true;
	case => abort("cannot write fixture");
	};
	defer rmfile(path);

	th_index(&s, path, text);
	th_open(&s, "file://.tmp/hare-lsp-th-tagged-test.ha", "type T = (A | B);\\ntype A = int;\\ntype B = str;\\n");

	const params_str = strings::concat(`{"item":{"name":"T","kind":23,"uri":"file://`, path,
		`","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":17}},"selectionRange":{"start":{"line":0,"character":0},"end":{"line":0,"character":17}}}}`)!;
	defer free(params_str);
	let pv = json::loadstr(params_str)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 3.0,
		method = strings::dup("typeHierarchy/supertypes")!,
		params = pv,
	};
	defer free(r.method);
	handle_supertypes(&s, r);
	const v = th_skip_to_response(out, 3.0);
	defer json::finish(v);
	const result = *(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	let found_a = false, found_b = false;
	for (let i = 0z; i < len(result); i += 1) {
		const item = result[i] as json::object;
		const n = *(json::get(&item, "name") as *json::value) as str;
		if (n == "A") found_a = true;
		if (n == "B") found_b = true;
	};
	assert(found_a);
	assert(found_b);
};

// --- file fixture helpers ---

fn writefile(path: str, text: str) (bool | fs::error) = {
	const f = os::create(path, 0o644)?;
	defer io::close(f)!;
	io::writeall(f, strings::toutf8(text))!;
	return true;
};

fn rmfile(path: str) void = {
	match (os::remove(path)) {
	case => void;
	};
};
