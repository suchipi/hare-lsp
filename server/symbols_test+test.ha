// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

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

fn sym_test_server(

) (server, *bufio::scanner, *memio::stream, *memio::stream) = {
	let in_buf = alloc(memio::fixed([]))!;
	let scan = alloc(bufio::newscanner(in_buf))!;
	let out = alloc(memio::dynamic())!;
	let s = new(scan, out, void);
	return (s, scan, in_buf, out);
};

fn sym_test_cleanup(
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

fn sym_open(s: *server, uri: str, text: str) void = {
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

// Returns `file://<root>/<module>/` where <root> is the first candidate
// directory containing <module> as a subdir. Candidates are the
// $HAREPATH entries (in order), followed by the same /usr/src/hare ->
// /usr/local/src/hare default the server falls back to. Returned string
// is owned.
fn sym_stdlib_module_prefix(module: str) str = {
	let candidates: []str = [];
	defer free(candidates);
	match (os::getenv("HAREPATH")) {
	case let raw: str =>
		const tok = strings::tokenize(raw, ":");
		for (let item => strings::next_token(&tok)) {
			if (len(item) == 0) continue;
			append(candidates, item)!;
		};
	case void => void;
	};
	append(candidates, default_stdlib_root())!;

	let root = "";
	for (let i = 0z; i < len(candidates); i += 1) {
		const candidate = strings::concat(candidates[i], "/", module)!;
		defer free(candidate);
		const ok = match (os::stat(candidate)) {
		case let st: fs::filestat =>
			yield fs::isdir(st.mode);
		case =>
			yield false;
		};
		if (ok) {
			root = candidates[i];
			break;
		};
	};
	if (len(root) == 0) root = default_stdlib_root();
	return strings::concat("file://", root, "/", module, "/")!;
};

@test fn document_symbol_lists_all_decls() void = {
	let (s, scan, in_buf, out) = sym_test_server();
	defer sym_test_cleanup(&s, scan, in_buf, out);
	sym_open(&s, "file:///x.ha",
		"fn a() void = void;\\nfn b() void = void;\\ntype c = int;\\n");

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
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as []json::value;
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
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	assert(len(result) >= 1);
};

@test fn document_link_returns_imports() void = {
	let (s, scan, in_buf, out) = sym_test_server();
	defer sym_test_cleanup(&s, scan, in_buf, out);
	sym_open(&s, "file:///x.ha",
		"use io;\\nuse strings;\\n\\nexport fn main() void = void;\\n");

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
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	assert(len(result) == 2);
};

@test fn document_link_resolve_fills_target_for_stdlib() void = {
	let (s, scan, in_buf, out) = sym_test_server();
	defer sym_test_cleanup(&s, scan, in_buf, out);
	sym_open(&s, "file:///x.ha", "use io;\\n\\nexport fn main() void = void;\\n");

	// Step 1: get the link list so we can grab its `data`.
	const list_params = `{"textDocument":{"uri":"file:///x.ha"}}`;
	let lpv = json::loadstr(list_params)!;
	defer json::finish(lpv);
	const list_req = lsp::request {
		id = 10.0,
		method = strings::dup("textDocument/documentLink")!,
		params = lpv,
	};
	defer free(list_req.method);
	handle_document_link(&s, list_req);
	const list_v = sym_skip_to_response(out, 10.0);
	defer json::finish(list_v);
	const list_arr =
		*(json::get(&(list_v as json::object),
			"result") as *json::value) as []json::value;
	assert(len(list_arr) >= 1);
	// The first link should have a data field carrying ["io"].
	const first = list_arr[0] as json::object;
	assert(json::get(&first, "data") is *json::value);

	// Step 2: send that link back as the resolve param.
	const resolve_payload = json::dumpstr(list_arr[0]);
	defer free(resolve_payload);
	let rpv = json::loadstr(resolve_payload)!;
	defer json::finish(rpv);
	const resolve_req = lsp::request {
		id = 11.0,
		method = strings::dup("documentLink/resolve")!,
		params = rpv,
	};
	defer free(resolve_req.method);
	handle_document_link_resolve(&s, resolve_req);
	const rv = sym_skip_to_response(out, 11.0);
	defer json::finish(rv);
	const ro =
		*(json::get(&(rv as json::object), "result") as *json::value) as json::object;
	// Should now have a `target` field pointing at a .ha file inside
	// the io stdlib module. Build the expected prefix from $HAREPATH so
	// the assertion is install-layout agnostic.
	const target = *(json::get(&ro, "target") as *json::value) as str;
	const expected_prefix = sym_stdlib_module_prefix("io");
	defer free(expected_prefix);
	assert(strings::hasprefix(target, expected_prefix));
	assert(strings::hassuffix(target, ".ha"));
};

@test fn document_highlight_returns_decl_range() void = {
	let (s, scan, in_buf, out) = sym_test_server();
	defer sym_test_cleanup(&s, scan, in_buf, out);
	sym_open(&s, "file:///x.ha", "fn target() void = void;\\n");

	const params =
		`{"textDocument":{"uri":"file:///x.ha"},"position":{"line":0,"character":4}}`;
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
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	assert(len(result) >= 1);
};

@test fn selection_range_expands_through_levels() void = {
	let (s, scan, in_buf, out) = sym_test_server();
	defer sym_test_cleanup(&s, scan, in_buf, out);
	// A two-line file: a decl on line 0, blank on line 1.
	sym_open(&s, "file:///sel.ha", "fn target() void = void;\\n\\n");

	// Cursor on the 't' of "target".
	const params =
		`{"textDocument":{"uri":"file:///sel.ha"},"positions":[{"line":0,"character":4}]}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 50.0,
		method = strings::dup("textDocument/selectionRange")!,
		params = pv,
	};
	defer free(r.method);
	handle_selection_range(&s, r);
	const v = sym_skip_to_response(out, 50.0);
	defer json::finish(v);
	const arr =
		*(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	assert(len(arr) == 1);
	// Walk the parent chain — should be at least 3 deep (ident → line/decl → file).
	let depth = 0u32;
	let cur = arr[0] as json::object;
	for (true) {
		depth += 1;
		match (json::get(&cur, "parent")) {
		case let p: *json::value =>
			cur = *p as json::object;
		case void =>
			break;
		};
	};
	assert(depth >= 3);
};
