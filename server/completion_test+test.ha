// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use analysis;
use bufio;
use bytes;
use encoding::json;
use io;
use lsp;
use memio;
use strconv;
use strings;

fn comp_test_server(

) (server, *bufio::scanner, *memio::stream, *memio::stream) = {
	let in_buf = alloc(memio::fixed([]))!;
	let scan = alloc(bufio::newscanner(in_buf))!;
	let out = alloc(memio::dynamic())!;
	let s = new(scan, out);
	return (s, scan, in_buf, out);
};

fn comp_test_cleanup(
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

fn comp_open(s: *server, uri: str, text: str) void = {
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

fn comp_skip_to_response(out: *memio::stream, request_id: f64) json::value = {
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

@test fn completion_includes_keywords() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	comp_open(&s, "file:///x.ha", "fn main() void = {\\n\\t\\n};\\n");

	const params =
		`{"textDocument":{"uri":"file:///x.ha"},"position":{"line":1,"character":1}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 1.0,
		method = strings::dup("textDocument/completion")!,
		params = pv,
	};
	defer free(r.method);
	handle_completion(&s, r);

	const v = comp_skip_to_response(out, 1.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	// Should at least contain the keyword "let".
	let found_let = false;
	for (let i = 0z; i < len(items); i += 1) {
		const item = items[i] as json::object;
		const label = *(json::get(&item, "label") as *json::value) as str;
		if (label == "let") {
			found_let = true;
			break;
		};
	};
	assert(found_let);
};

@test fn completion_filters_by_partial_prefix() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	// Cursor is right after typing "ret".
	comp_open(&s, "file:///x.ha", "fn main() void = ret\\n");

	// Position right after "ret".
	const params =
		`{"textDocument":{"uri":"file:///x.ha"},"position":{"line":0,"character":20}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 2.0,
		method = strings::dup("textDocument/completion")!,
		params = pv,
	};
	defer free(r.method);
	handle_completion(&s, r);

	const v = comp_skip_to_response(out, 2.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	// All labels should start with "ret".
	for (let i = 0z; i < len(items); i += 1) {
		const item = items[i] as json::object;
		const label = *(json::get(&item, "label") as *json::value) as str;
		assert(strings::hasprefix(label, "ret"));
	};
	// And "return" should be in there.
	let found_return = false;
	for (let i = 0z; i < len(items); i += 1) {
		const item = items[i] as json::object;
		const label = *(json::get(&item, "label") as *json::value) as str;
		if (label == "return") found_return = true;
	};
	assert(found_return);
};

@test fn completion_includes_local_decls() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	comp_open(&s, "file:///x.ha",
		"fn helper() void = void;\\nfn main() void = h\\n");

	const params =
		`{"textDocument":{"uri":"file:///x.ha"},"position":{"line":1,"character":18}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 3.0,
		method = strings::dup("textDocument/completion")!,
		params = pv,
	};
	defer free(r.method);
	handle_completion(&s, r);

	const v = comp_skip_to_response(out, 3.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	let found_helper = false;
	for (let i = 0z; i < len(items); i += 1) {
		const item = items[i] as json::object;
		const label = *(json::get(&item, "label") as *json::value) as str;
		if (label == "helper") found_helper = true;
	};
	assert(found_helper);
};

@test fn completion_function_has_snippet_and_sortText() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	comp_open(&s, "file:///snip.ha",
		"fn greet(name: str, age: int) void = void;\\nfn main() void = g\\n");

	const params =
		`{"textDocument":{"uri":"file:///snip.ha"},"position":{"line":1,"character":18}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 4.0,
		method = strings::dup("textDocument/completion")!,
		params = pv,
	};
	defer free(r.method);
	handle_completion(&s, r);

	const v = comp_skip_to_response(out, 4.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	let found = false;
	for (let i = 0z; i < len(items); i += 1) {
		const item = items[i] as json::object;
		const label = *(json::get(&item, "label") as *json::value) as str;
		if (label != "greet") continue;
		found = true;
		// Snippet insertText and Snippet format.
		const insert_text = *(json::get(&item, "insertText") as *json::value) as str;
		assert(insert_text == "greet(${1:name}, ${2:age})$0");
		const fmt_val =
			*(json::get(&item, "insertTextFormat") as *json::value) as f64;
		assert(fmt_val == 2.0);
		// File-local sortText prefix.
		const sort = *(json::get(&item, "sortText") as *json::value) as str;
		assert(strings::hasprefix(sort, "1-"));
	};
	assert(found);
};

@test fn completion_auto_import_attaches_additional_text_edits() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);

	// Seed the workspace index with an exported symbol from a module
	// the open document doesn't import.
	const provider = strings::toutf8("export fn barbar() void = void;\n");
	analysis::index_file(&s.workspace_index, "/repo/mymod/p.ha", provider);

	// The open doc has no `use mymod;`. Cursor sits right after "ba".
	comp_open(&s, "file:///c.ha", "fn main() void = ba\\n");

	const params =
		`{"textDocument":{"uri":"file:///c.ha"},"position":{"line":0,"character":19}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 50.0,
		method = strings::dup("textDocument/completion")!,
		params = pv,
	};
	defer free(r.method);
	handle_completion(&s, r);

	const v = comp_skip_to_response(out, 50.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	let found = false;
	for (let i = 0z; i < len(items); i += 1) {
		const item = items[i] as json::object;
		const label = *(json::get(&item, "label") as *json::value) as str;
		if (label != "barbar") continue;
		found = true;
		const edits =
			*(json::get(&item, "additionalTextEdits") as *json::value) as []json::value;
		assert(len(edits) >= 1);
		const e0 = edits[0] as json::object;
		const new_text = *(json::get(&e0, "newText") as *json::value) as str;
		assert(strings::contains(new_text, "use mymod;"));
		break;
	};
	assert(found);
};

@test fn completion_auto_import_skipped_when_already_imported() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);

	const provider = strings::toutf8("export fn barbar() void = void;\n");
	analysis::index_file(&s.workspace_index, "/repo/mymod/p.ha", provider);

	// The open doc already has `use mymod;`.
	comp_open(&s, "file:///c2.ha", "use mymod;\\nfn main() void = ba\\n");

	const params =
		`{"textDocument":{"uri":"file:///c2.ha"},"position":{"line":1,"character":19}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 51.0,
		method = strings::dup("textDocument/completion")!,
		params = pv,
	};
	defer free(r.method);
	handle_completion(&s, r);

	const v = comp_skip_to_response(out, 51.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	for (let i = 0z; i < len(items); i += 1) {
		const item = items[i] as json::object;
		const label = *(json::get(&item, "label") as *json::value) as str;
		if (label != "barbar") continue;
		// No additionalTextEdits since the module is already imported.
		match (json::get(&item, "additionalTextEdits")) {
		case let p: *json::value => abort(
			"expected no additionalTextEdits for imported module"
		);
		case => void;
		};
		return;
	};
	abort("barbar entry missing");
};

@test fn completion_keyword_has_keyword_sortText() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	comp_open(&s, "file:///k.ha", "fn main() void = l\\n");

	const params =
		`{"textDocument":{"uri":"file:///k.ha"},"position":{"line":0,"character":18}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 5.0,
		method = strings::dup("textDocument/completion")!,
		params = pv,
	};
	defer free(r.method);
	handle_completion(&s, r);

	const v = comp_skip_to_response(out, 5.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	let saw_let = false;
	for (let i = 0z; i < len(items); i += 1) {
		const item = items[i] as json::object;
		const label = *(json::get(&item, "label") as *json::value) as str;
		if (label != "let") continue;
		saw_let = true;
		const sort = *(json::get(&item, "sortText") as *json::value) as str;
		assert(strings::hasprefix(sort, "3-"));
	};
	assert(saw_let);
};
