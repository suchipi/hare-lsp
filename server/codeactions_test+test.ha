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

fn ca_test_server() (server, *bufio::scanner, *memio::stream, *memio::stream) = {
	let in_buf = alloc(memio::fixed([]))!;
	let scan = alloc(bufio::newscanner(in_buf))!;
	let out = alloc(memio::dynamic())!;
	let s = new(scan, out);
	return (s, scan, in_buf, out);
};

fn ca_test_cleanup(s: *server, scan: *bufio::scanner, in_buf: *memio::stream, out: *memio::stream) void = {
	finish(s);
	bufio::finish(scan);
	free(scan);
	free(in_buf);
	io::close(out)!;
	free(out);
};

fn ca_open(s: *server, uri: str, text: str) void = {
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

fn ca_skip_to_response(out: *memio::stream, request_id: f64) json::value = {
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

fn organize_imports_new_text(s: *server, uri: str) str = {
	const params = strings::concat(`{"textDocument":{"uri":"`, uri,
		`"},"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"context":{"diagnostics":[]}}`)!;
	defer free(params);
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 60.0,
		method = strings::dup("textDocument/codeAction")!,
		params = pv,
	};
	defer free(r.method);
	handle_code_action(s, r);

	const v = ca_skip_to_response(s.out: *memio::stream, 60.0);
	defer json::finish(v);
	const actions = *(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	assert(len(actions) >= 1);
	// First action should be organize-imports.
	const action = actions[0] as json::object;
	const edit = *(json::get(&action, "edit") as *json::value) as json::object;
	const changes = *(json::get(&edit, "changes") as *json::value) as json::object;
	const edits = *(json::get(&changes, uri) as *json::value) as []json::value;
	const first_edit = edits[0] as json::object;
	return strings::dup(*(json::get(&first_edit, "newText") as *json::value) as str)!;
};

@test fn organize_imports_preserves_alias() void = {
	let (s, scan, in_buf, out) = ca_test_server();
	defer ca_test_cleanup(&s, scan, in_buf, out);
	// Two imports: a plain one and an aliased one.
	ca_open(&s, "file:///alias.ha", "use foo;\\nuse bar = baz::qux;\\n");

	const new_text = organize_imports_new_text(&s, "file:///alias.ha");
	defer free(new_text);
	// Should preserve the alias form.
	assert(strings::contains(new_text, "use bar = baz::qux;"));
	assert(strings::contains(new_text, "use foo;"));
};

@test fn organize_imports_preserves_member_list() void = {
	let (s, scan, in_buf, out) = ca_test_server();
	defer ca_test_cleanup(&s, scan, in_buf, out);
	ca_open(&s, "file:///members.ha", "use foo::{b, a};\\nuse bar;\\n");

	const new_text = organize_imports_new_text(&s, "file:///members.ha");
	defer free(new_text);
	// Member list preserved and sorted internally (a before b).
	assert(strings::contains(new_text, "use foo::{a, b};"));
	assert(strings::contains(new_text, "use bar;"));
};

@test fn organize_imports_preserves_wildcard() void = {
	let (s, scan, in_buf, out) = ca_test_server();
	defer ca_test_cleanup(&s, scan, in_buf, out);
	ca_open(&s, "file:///wc.ha", "use foo::*;\\nuse bar;\\n");

	const new_text = organize_imports_new_text(&s, "file:///wc.ha");
	defer free(new_text);
	assert(strings::contains(new_text, "use foo::*;"));
	assert(strings::contains(new_text, "use bar;"));
};
