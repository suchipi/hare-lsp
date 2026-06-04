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
	let s = new(scan, out, void);
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
			const value = strings::trim(
				strings::sub(lines[i], idx + 1, strings::end));
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
		*(json::get(&(v as json::object),
			"result") as *json::value) as json::object;
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
		*(json::get(&(v as json::object),
			"result") as *json::value) as json::object;
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
		*(json::get(&(v as json::object),
			"result") as *json::value) as json::object;
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
		*(json::get(&(v as json::object),
			"result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	let found = false;
	for (let i = 0z; i < len(items); i += 1) {
		const item = items[i] as json::object;
		const label = *(json::get(&item, "label") as *json::value) as str;
		if (label != "greet") continue;
		found = true;
		// Snippet insertText and Snippet format.
		const insert_text =
			*(json::get(&item, "insertText") as *json::value) as str;
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
		*(json::get(&(v as json::object),
			"result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	let found = false;
	for (let i = 0z; i < len(items); i += 1) {
		const item = items[i] as json::object;
		const label = *(json::get(&item, "label") as *json::value) as str;
		if (label != "barbar") continue;
		found = true;
		const edits =
			*(json::get(&item,
				"additionalTextEdits") as *json::value) as []json::value;
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
		*(json::get(&(v as json::object),
			"result") as *json::value) as json::object;
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

@test fn completion_auto_import_skipped_for_nested_workspace_import() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);

	// Workspace module — module_from_path stores the leaf "parse"
	// regardless of how deep the file lives in the workspace tree.
	const provider = strings::toutf8("export fn parser_func() void = void;\n");
	analysis::index_file(&s.workspace_index, "/repo/hare/parse/p.ha", provider);

	// Doc imports the qualified form `use hare::parse;`. Hare
	// references this module by its leaf `parse`, so any second `use
	// parse;` would shadow it. Auto-import must therefore NOT attach a
	// `use parse;` edit just because `e.module == "parse"` differs
	// from the literal import ident "hare::parse".
	comp_open(&s, "file:///nested.ha",
		"use hare::parse;\\nfn main() void = parser\\n");

	const params =
		`{"textDocument":{"uri":"file:///nested.ha"},"position":{"line":1,"character":24}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 90.0,
		method = strings::dup("textDocument/completion")!,
		params = pv,
	};
	defer free(r.method);
	handle_completion(&s, r);

	const v = comp_skip_to_response(out, 90.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object),
			"result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	let found = false;
	for (let i = 0z; i < len(items); i += 1) {
		const item = items[i] as json::object;
		const label = *(json::get(&item, "label") as *json::value) as str;
		if (label != "parser_func") continue;
		found = true;
		match (json::get(&item, "additionalTextEdits")) {
		case let p: *json::value => abort(
			"workspace auto-import: nested import (use hare::parse;) must suppress redundant `use parse;` edit"
		);
		case => void;
		};
		break;
	};
	assert(found);
};

@test fn completion_auto_import_for_stdlib_uses_qualified_module() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);

	// Pin HAREPATH so stdlib_qualified_module has a deterministic root
	// to strip; the default probes /usr/src and /usr/local/src which
	// will differ across hosts.
	free(s.config.harepath);
	s.config.harepath = strings::dup("/repo/stdlib")!;
	const seed = strings::toutf8("export fn loadstr(input: str) void = void;\n");
	analysis::index_file(&s.stdlib_index, "/repo/stdlib/encoding/json/loader.ha",
		seed);

	// Doc has no `use encoding::json;`. Cursor sits after "load".
	comp_open(&s, "file:///z.ha", "fn main() void = load\\n");

	const params =
		`{"textDocument":{"uri":"file:///z.ha"},"position":{"line":0,"character":21}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 70.0,
		method = strings::dup("textDocument/completion")!,
		params = pv,
	};
	defer free(r.method);
	handle_completion(&s, r);

	const v = comp_skip_to_response(out, 70.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object),
			"result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	let found = false;
	for (let i = 0z; i < len(items); i += 1) {
		const item = items[i] as json::object;
		const label = *(json::get(&item, "label") as *json::value) as str;
		if (label != "loadstr") continue;
		found = true;
		const edits =
			*(json::get(&item,
				"additionalTextEdits") as *json::value) as []json::value;
		assert(len(edits) >= 1);
		const e0 = edits[0] as json::object;
		const new_text = *(json::get(&e0, "newText") as *json::value) as str;
		assert(
			strings::contains(new_text, "use encoding::json;"),
			"stdlib auto-import must insert the qualified module path"
		);
		break;
	};
	assert(
		found,
		"stdlib loadstr should be offered as an unqualified completion"
	);
};

@test fn completion_auto_import_for_stdlib_skipped_when_qualified_import_present(

) void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);

	free(s.config.harepath);
	s.config.harepath = strings::dup("/repo/stdlib")!;
	const seed = strings::toutf8("export fn loadstr(input: str) void = void;\n");
	analysis::index_file(&s.stdlib_index, "/repo/stdlib/encoding/json/loader.ha",
		seed);

	// Doc already imports the qualified module. The completion should
	// still surface `loadstr` but must NOT attach a redundant edit.
	comp_open(&s, "file:///z2.ha",
		"use encoding::json;\\nfn main() void = load\\n");

	const params =
		`{"textDocument":{"uri":"file:///z2.ha"},"position":{"line":1,"character":21}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 71.0,
		method = strings::dup("textDocument/completion")!,
		params = pv,
	};
	defer free(r.method);
	handle_completion(&s, r);

	const v = comp_skip_to_response(out, 71.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object),
			"result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	let found = false;
	for (let i = 0z; i < len(items); i += 1) {
		const item = items[i] as json::object;
		const label = *(json::get(&item, "label") as *json::value) as str;
		if (label != "loadstr") continue;
		found = true;
		match (json::get(&item, "additionalTextEdits")) {
		case let p: *json::value => abort(
			"expected no additionalTextEdits when encoding::json is already imported"
		);
		case => void;
		};
		break;
	};
	assert(found);
};

@test fn completion_auto_import_inserts_qualified_function_snippet() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);

	// Exported function in a module the open document doesn't import.
	const provider = strings::toutf8("export fn barbar() void = void;\n");
	analysis::index_file(&s.workspace_index, "/repo/mymod/p.ha", provider);

	// Open doc has no `use mymod;`. Cursor after "ba".
	comp_open(&s, "file:///qc.ha", "fn main() void = ba\\n");

	const params =
		`{"textDocument":{"uri":"file:///qc.ha"},"position":{"line":0,"character":19}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 72.0,
		method = strings::dup("textDocument/completion")!,
		params = pv,
	};
	defer free(r.method);
	handle_completion(&s, r);

	const v = comp_skip_to_response(out, 72.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object),
			"result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	let found = false;
	for (let i = 0z; i < len(items); i += 1) {
		const item = items[i] as json::object;
		const label = *(json::get(&item, "label") as *json::value) as str;
		if (label != "barbar") continue;
		found = true;
		// Accepting must insert the module-qualified call, not a bare
		// `barbar()` that wouldn't resolve after the `use mymod;` edit.
		const it_text = *(json::get(&item, "insertText") as *json::value) as str;
		assert(
			strings::hasprefix(it_text, "mymod::barbar("),
			"cross-module function completion must insert a qualified call"
		);
		const fmt_kind =
			*(json::get(&item, "insertTextFormat") as *json::value) as f64;
		assert(fmt_kind == 2.0, "qualified function insert must be a Snippet");
		break;
	};
	assert(found, "barbar should be offered");
};

@test fn completion_stdlib_inserts_qualified_function_snippet() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);

	free(s.config.harepath);
	s.config.harepath = strings::dup("/repo/stdlib")!;
	const seed = strings::toutf8("export fn loadstr(input: str) void = void;\n");
	analysis::index_file(&s.stdlib_index, "/repo/stdlib/encoding/json/loader.ha",
		seed);

	// Doc has no `use encoding::json;`. Cursor after "load".
	comp_open(&s, "file:///qz.ha", "fn main() void = load\\n");

	const params =
		`{"textDocument":{"uri":"file:///qz.ha"},"position":{"line":0,"character":21}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 73.0,
		method = strings::dup("textDocument/completion")!,
		params = pv,
	};
	defer free(r.method);
	handle_completion(&s, r);

	const v = comp_skip_to_response(out, 73.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object),
			"result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	let found = false;
	for (let i = 0z; i < len(items); i += 1) {
		const item = items[i] as json::object;
		const label = *(json::get(&item, "label") as *json::value) as str;
		if (label != "loadstr") continue;
		found = true;
		const it_text = *(json::get(&item, "insertText") as *json::value) as str;
		// The module leaf `json`, not the full `encoding::json::` path:
		// Hare references the module by its last segment.
		assert(
			strings::hasprefix(it_text, "json::loadstr("),
			"stdlib completion must insert the leaf-qualified call"
		);
		break;
	};
	assert(found, "loadstr should be offered");
};

@test fn completion_cross_module_type_inserts_qualified_plain_name() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);

	const provider = strings::toutf8("export type mytype = int;\n");
	analysis::index_file(&s.workspace_index, "/repo/othermod/t.ha", provider);

	comp_open(&s, "file:///qt.ha", "fn main() void = my\\n");

	const params =
		`{"textDocument":{"uri":"file:///qt.ha"},"position":{"line":0,"character":19}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 74.0,
		method = strings::dup("textDocument/completion")!,
		params = pv,
	};
	defer free(r.method);
	handle_completion(&s, r);

	const v = comp_skip_to_response(out, 74.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object),
			"result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	let found = false;
	for (let i = 0z; i < len(items); i += 1) {
		const item = items[i] as json::object;
		const label = *(json::get(&item, "label") as *json::value) as str;
		if (label != "mytype") continue;
		found = true;
		// Non-function: a plain qualified identifier with no snippet
		// placeholders and no Snippet format flag.
		const it_text = *(json::get(&item, "insertText") as *json::value) as str;
		assert(
			it_text == "othermod::mytype",
			"cross-module type completion must insert the qualified name"
		);
		match (json::get(&item, "insertTextFormat")) {
		case *json::value => abort(
			"plain qualified insert must not be marked as a Snippet"
		);
		case => void;
		};
		break;
	};
	assert(found, "mytype should be offered");
};

@test fn completion_same_module_inserts_bare_name() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);

	// Sibling file in the SAME module as the open document.
	const provider = strings::toutf8("export fn sibfunc() void = void;\n");
	analysis::index_file(&s.workspace_index, "/repo/proj/sibling.ha", provider);

	// Open doc lives in /repo/proj too, so `sibfunc` is reachable
	// unqualified - the insert must stay a bare call.
	comp_open(&s, "file:///repo/proj/main.ha", "fn main() void = sib\\n");

	const params =
		`{"textDocument":{"uri":"file:///repo/proj/main.ha"},"position":{"line":0,"character":20}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 75.0,
		method = strings::dup("textDocument/completion")!,
		params = pv,
	};
	defer free(r.method);
	handle_completion(&s, r);

	const v = comp_skip_to_response(out, 75.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object),
			"result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	let found = false;
	for (let i = 0z; i < len(items); i += 1) {
		const item = items[i] as json::object;
		const label = *(json::get(&item, "label") as *json::value) as str;
		if (label != "sibfunc") continue;
		found = true;
		const it_text = *(json::get(&item, "insertText") as *json::value) as str;
		assert(
			strings::hasprefix(it_text, "sibfunc("),
			"same-module function completion must insert a bare call"
		);
		assert(
			!strings::contains(it_text, "::"),
			"same-module completion must not qualify the inserted name"
		);
		// And no `use` edit: importing your own module is an error.
		match (json::get(&item, "additionalTextEdits")) {
		case *json::value => abort(
			"same-module completion must not attach a `use <own-module>;` edit"
		);
		case => void;
		};
		break;
	};
	assert(found, "sibfunc should be offered");
};

@test fn completion_omits_non_exported_cross_module_symbol() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);

	// Two same-prefix decls in another module: one private, one exported.
	// A private decl is unreachable from a different module even with a
	// qualifier + import, so it must not be offered; the exported one
	// must (a positive control proving the filter discriminates on
	// exported-ness rather than dropping all cross-module symbols).
	const provider = strings::toutf8(
		"fn secret_priv() void = void;\nexport fn secret_pub() void = void;\n");
	analysis::index_file(&s.workspace_index, "/repo/othermod/p.ha", provider);

	// Open doc is in a DIFFERENT module (leaf "mymod").
	comp_open(&s, "file:///repo/mymod/main.ha", "fn main() void = secret\\n");

	const params =
		`{"textDocument":{"uri":"file:///repo/mymod/main.ha"},"position":{"line":0,"character":23}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 76.0,
		method = strings::dup("textDocument/completion")!,
		params = pv,
	};
	defer free(r.method);
	handle_completion(&s, r);

	const v = comp_skip_to_response(out, 76.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object),
			"result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	let saw_pub = false;
	for (let i = 0z; i < len(items); i += 1) {
		const item = items[i] as json::object;
		const label = *(json::get(&item, "label") as *json::value) as str;
		assert(
			label != "secret_priv",
			"a private cross-module decl must not be offered as a completion"
		);
		if (label == "secret_pub") saw_pub = true;
	};
	assert(saw_pub, "the exported cross-module decl must still be offered");
};

@test fn completion_auto_import_nested_workspace_module_uses_full_path(

) void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);

	// Pin the module root so the synthetic /ws tree resolves: the file
	// /ws/hare/parse/p.ha then belongs to module `hare::parse`, not the
	// bare leaf `parse`.
	free(s.config.harepath);
	s.config.harepath = strings::dup("/ws")!;
	const provider = strings::toutf8("export fn parser_func() void = void;\n");
	analysis::index_file(&s.workspace_index, "/ws/hare/parse/p.ha", provider);

	// Open doc at the workspace root with no imports yet.
	comp_open(&s, "file:///ws/main.ha", "fn main() void = parser\\n");

	const params =
		`{"textDocument":{"uri":"file:///ws/main.ha"},"position":{"line":0,"character":23}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 77.0,
		method = strings::dup("textDocument/completion")!,
		params = pv,
	};
	defer free(r.method);
	handle_completion(&s, r);

	const v = comp_skip_to_response(out, 77.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object),
			"result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	let found = false;
	for (let i = 0z; i < len(items); i += 1) {
		const item = items[i] as json::object;
		const label = *(json::get(&item, "label") as *json::value) as str;
		if (label != "parser_func") continue;
		found = true;
		// Referenced by the module leaf `parse`...
		const it_text = *(json::get(&item, "insertText") as *json::value) as str;
		assert(
			strings::hasprefix(it_text, "parse::parser_func("),
			"nested-module completion must qualify by the leaf `parse`"
		);
		// ...but imported by the FULL module path `hare::parse`.
		const edits =
			*(json::get(&item,
				"additionalTextEdits") as *json::value) as []json::value;
		assert(len(edits) >= 1, "nested-module completion must carry a use edit");
		const e0 = edits[0] as json::object;
		const new_text = *(json::get(&e0, "newText") as *json::value) as str;
		assert(
			strings::contains(new_text, "use hare::parse;"),
			"nested-module auto-import must insert `use hare::parse;`, not `use parse;`"
		);
		break;
	};
	assert(found, "parser_func should be offered");
};

@test fn completion_module_name_suggests_stdlib_module() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);

	free(s.config.harepath);
	s.config.harepath = strings::dup("/repo/stdlib")!;
	const seed = strings::toutf8("export fn loadstr(input: str) void = void;\n");
	analysis::index_file(&s.stdlib_index, "/repo/stdlib/encoding/json/loader.ha",
		seed);

	// Typing just `js` — the user wants the module name itself, not a
	// symbol inside it. We must offer a MODULE item with the qualified
	// detail so it's distinguishable from any "js"-prefixed symbol.
	comp_open(&s, "file:///mod.ha", "fn main() void = js\\n");

	const params =
		`{"textDocument":{"uri":"file:///mod.ha"},"position":{"line":0,"character":19}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 80.0,
		method = strings::dup("textDocument/completion")!,
		params = pv,
	};
	defer free(r.method);
	handle_completion(&s, r);

	const v = comp_skip_to_response(out, 80.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object),
			"result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	let found = false;
	for (let i = 0z; i < len(items); i += 1) {
		const item = items[i] as json::object;
		const label = *(json::get(&item, "label") as *json::value) as str;
		if (label != "json") continue;
		const kind = *(json::get(&item, "kind") as *json::value) as f64;
		if (kind != 9.0) continue;
		found = true;
		const detail = *(json::get(&item, "detail") as *json::value) as str;
		assert(
			detail == "encoding::json",
			"module-name completion detail must show the qualified path"
		);
		const edits =
			*(json::get(&item,
				"additionalTextEdits") as *json::value) as []json::value;
		assert(len(edits) >= 1);
		const e0 = edits[0] as json::object;
		const new_text = *(json::get(&e0, "newText") as *json::value) as str;
		assert(strings::contains(new_text, "use encoding::json;"));
		break;
	};
	assert(
		found,
		"typing a module-name prefix should offer a MODULE-kind item with auto-import"
	);
};

@test fn completion_module_name_dedupes_repeated_module() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);

	free(s.config.harepath);
	s.config.harepath = strings::dup("/repo/stdlib")!;
	// Two files in the same module — module suggestion must only
	// appear once.
	analysis::index_file(&s.stdlib_index, "/repo/stdlib/bufio/scanner.ha",
		strings::toutf8("export fn newscanner() void = void;\n"));
	analysis::index_file(&s.stdlib_index, "/repo/stdlib/bufio/writer.ha",
		strings::toutf8("export fn newwriter() void = void;\n"));

	comp_open(&s, "file:///dedup.ha", "fn main() void = bu\\n");
	const params =
		`{"textDocument":{"uri":"file:///dedup.ha"},"position":{"line":0,"character":19}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 81.0,
		method = strings::dup("textDocument/completion")!,
		params = pv,
	};
	defer free(r.method);
	handle_completion(&s, r);

	const v = comp_skip_to_response(out, 81.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object),
			"result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	let bufio_count = 0;
	for (let i = 0z; i < len(items); i += 1) {
		const item = items[i] as json::object;
		const label = *(json::get(&item, "label") as *json::value) as str;
		if (label != "bufio") continue;
		const kind = *(json::get(&item, "kind") as *json::value) as f64;
		if (kind != 9.0) continue;
		bufio_count += 1;
	};
	assert(
		bufio_count == 1,
		"module-name completion must dedupe — `bufio` should appear exactly once"
	);
};

@test fn completion_module_name_skipped_when_already_imported() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);

	free(s.config.harepath);
	s.config.harepath = strings::dup("/repo/stdlib")!;
	analysis::index_file(&s.stdlib_index, "/repo/stdlib/encoding/json/loader.ha",
		strings::toutf8("export fn loadstr(s: str) void = void;\n"));

	// Doc already imports `encoding::json`. The module-name suggestion
	// is still useful (user typed `js`), but it must not carry a
	// redundant auto-import edit.
	comp_open(&s, "file:///already.ha",
		"use encoding::json;\\nfn main() void = js\\n");
	const params =
		`{"textDocument":{"uri":"file:///already.ha"},"position":{"line":1,"character":19}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 82.0,
		method = strings::dup("textDocument/completion")!,
		params = pv,
	};
	defer free(r.method);
	handle_completion(&s, r);

	const v = comp_skip_to_response(out, 82.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object),
			"result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	let found = false;
	for (let i = 0z; i < len(items); i += 1) {
		const item = items[i] as json::object;
		const label = *(json::get(&item, "label") as *json::value) as str;
		if (label != "json") continue;
		const kind = *(json::get(&item, "kind") as *json::value) as f64;
		if (kind != 9.0) continue;
		found = true;
		match (json::get(&item, "additionalTextEdits")) {
		case let p: *json::value => abort(
			"module-name completion must NOT attach an auto-import edit when the module is already imported"
		);
		case => void;
		};
		break;
	};
	assert(found);
};

@test fn completion_module_name_workspace_module() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);

	const provider = strings::toutf8("export fn helper() void = void;\n");
	analysis::index_file(&s.workspace_index, "/repo/mymod/p.ha", provider);

	comp_open(&s, "file:///wsmod.ha", "fn main() void = my\\n");
	const params =
		`{"textDocument":{"uri":"file:///wsmod.ha"},"position":{"line":0,"character":19}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 83.0,
		method = strings::dup("textDocument/completion")!,
		params = pv,
	};
	defer free(r.method);
	handle_completion(&s, r);

	const v = comp_skip_to_response(out, 83.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object),
			"result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	let found = false;
	for (let i = 0z; i < len(items); i += 1) {
		const item = items[i] as json::object;
		const label = *(json::get(&item, "label") as *json::value) as str;
		if (label != "mymod") continue;
		const kind = *(json::get(&item, "kind") as *json::value) as f64;
		if (kind != 9.0) continue;
		found = true;
		const edits =
			*(json::get(&item,
				"additionalTextEdits") as *json::value) as []json::value;
		assert(len(edits) >= 1);
		const e0 = edits[0] as json::object;
		const new_text = *(json::get(&e0, "newText") as *json::value) as str;
		assert(strings::contains(new_text, "use mymod;"));
		break;
	};
	assert(
		found,
		"typing `my` should offer the workspace module `mymod` with auto-import"
	);
};

@test fn completion_auto_import_for_stdlib_skips_unexported() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);

	free(s.config.harepath);
	s.config.harepath = strings::dup("/repo/stdlib")!;
	const seed = strings::toutf8("fn internal_helper() void = void;\n");
	analysis::index_file(&s.stdlib_index, "/repo/stdlib/encoding/json/loader.ha",
		seed);

	comp_open(&s, "file:///z3.ha", "fn main() void = inter\\n");

	const params =
		`{"textDocument":{"uri":"file:///z3.ha"},"position":{"line":0,"character":22}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 72.0,
		method = strings::dup("textDocument/completion")!,
		params = pv,
	};
	defer free(r.method);
	handle_completion(&s, r);

	const v = comp_skip_to_response(out, 72.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object),
			"result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	for (let i = 0z; i < len(items); i += 1) {
		const item = items[i] as json::object;
		const label = *(json::get(&item, "label") as *json::value) as str;
		assert(
			label != "internal_helper",
			"private stdlib symbols must not appear in unqualified completion"
		);
	};
};

@test fn completion_qualified_filters_by_module() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);

	// Seed two modules. Only entries whose module matches the prefix
	// before "::" should appear.
	const a = strings::toutf8("export fn mymod_fn() void = void;\n");
	analysis::index_file(&s.workspace_index, "/repo/mymod/a.ha", a);
	const b = strings::toutf8("export fn other_fn() void = void;\n");
	analysis::index_file(&s.workspace_index, "/repo/other/b.ha", b);

	comp_open(&s, "file:///q.ha", "use mymod;\\nfn main() void = mymod::\\n");

	// Cursor sits right after the trailing "::" on line 1.
	// "fn main() void = mymod::" has length 24.
	const params =
		`{"textDocument":{"uri":"file:///q.ha"},"position":{"line":1,"character":24}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 60.0,
		method = strings::dup("textDocument/completion")!,
		params = pv,
	};
	defer free(r.method);
	handle_completion(&s, r);

	const v = comp_skip_to_response(out, 60.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object),
			"result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	let found_mymod = false;
	for (let i = 0z; i < len(items); i += 1) {
		const item = items[i] as json::object;
		const label = *(json::get(&item, "label") as *json::value) as str;
		if (label == "mymod_fn") found_mymod = true;
		assert(label != "other_fn");
		assert(label != "let");
		assert(label != "main");
	};
	assert(found_mymod);
};

@test fn completion_qualified_filters_with_partial() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);

	const a = strings::toutf8(
		"export fn dup() void = void;\nexport fn split() void = void;\n");
	analysis::index_file(&s.workspace_index, "/repo/strings/a.ha", a);

	// "fn main() void = strings::du" — len = 28, cursor right after "du".
	comp_open(&s, "file:///qp.ha", "fn main() void = strings::du\\n");

	const params =
		`{"textDocument":{"uri":"file:///qp.ha"},"position":{"line":0,"character":28}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 61.0,
		method = strings::dup("textDocument/completion")!,
		params = pv,
	};
	defer free(r.method);
	handle_completion(&s, r);

	const v = comp_skip_to_response(out, 61.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object),
			"result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	let found_dup = false;
	for (let i = 0z; i < len(items); i += 1) {
		const item = items[i] as json::object;
		const label = *(json::get(&item, "label") as *json::value) as str;
		if (label == "dup") found_dup = true;
		assert(label != "split");
	};
	assert(found_dup);
};

@test fn completion_qualified_includes_stdlib_module_members() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);

	// Seed `s.stdlib_index` directly (mirrors what
	// ensure_stdlib_module_indexed would build after walking
	// /usr/local/src/hare/stdlib/strings) and mark the module as
	// already indexed so the lookup doesn't try to walk the real
	// filesystem during the test.
	const stdlib_strings = strings::toutf8(
		"export fn concat(parts: str...) str = \"\";\n");
	analysis::index_file(&s.stdlib_index,
		"/usr/local/src/hare/stdlib/strings/concat.ha", stdlib_strings);
	append(s.indexed_stdlib_modules, strings::dup("strings")!)!;

	comp_open(&s, "file:///stdq.ha",
		"use strings;\\nfn main() void = strings::\\n");

	// "fn main() void = strings::" has length 26.
	const params =
		`{"textDocument":{"uri":"file:///stdq.ha"},"position":{"line":1,"character":26}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 63.0,
		method = strings::dup("textDocument/completion")!,
		params = pv,
	};
	defer free(r.method);
	handle_completion(&s, r);

	const v = comp_skip_to_response(out, 63.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object),
			"result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	let found_concat = false;
	for (let i = 0z; i < len(items); i += 1) {
		const item = items[i] as json::object;
		const label = *(json::get(&item, "label") as *json::value) as str;
		if (label == "concat") found_concat = true;
		// Keywords and unrelated symbols must not leak in even when
		// the only match comes from stdlib_index.
		assert(label != "let");
		assert(label != "main");
	};
	assert(
		found_concat,
		"stdlib symbols must surface for `mod::` when only stdlib_index contains them"
	);
};

@test fn completion_qualified_excludes_unexported() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);

	const a = strings::toutf8(
		"export fn shown() void = void;\nfn hidden() void = void;\n");
	analysis::index_file(&s.workspace_index, "/repo/m/a.ha", a);

	// "fn main() void = m::" — len = 20, cursor right after "::".
	comp_open(&s, "file:///qe.ha", "fn main() void = m::\\n");

	const params =
		`{"textDocument":{"uri":"file:///qe.ha"},"position":{"line":0,"character":20}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 62.0,
		method = strings::dup("textDocument/completion")!,
		params = pv,
	};
	defer free(r.method);
	handle_completion(&s, r);

	const v = comp_skip_to_response(out, 62.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object),
			"result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	let found_shown = false;
	for (let i = 0z; i < len(items); i += 1) {
		const item = items[i] as json::object;
		const label = *(json::get(&item, "label") as *json::value) as str;
		if (label == "shown") found_shown = true;
		assert(label != "hidden");
	};
	assert(found_shown);
};

// --- Struct/union member completion -----------------------------------
fn run_completion(
	s: *server,
	out: *memio::stream,
	uri: str,
	line: u32,
	ch: u32,
	req_id: f64,
) []json::value = {
	const params =
		strings::concat(`{"textDocument":{"uri":"`, uri, `"},"position":{"line":`,
			fmt_u32(line), `,"character":`, fmt_u32(ch), `}}`)!;
	defer free(params);
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = req_id,
		method = strings::dup("textDocument/completion")!,
		params = pv,
	};
	defer free(r.method);
	handle_completion(s, r);

	const v = comp_skip_to_response(out, req_id);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object),
			"result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	// Return a duplicated copy so callers can inspect after json::finish.
	let dup_items: []json::value = [];
	for (let i = 0z; i < len(items); i += 1) {
		match (json::dup(items[i])) {
		case let v: json::value =>
			append(dup_items, v)!;
		case nomem => abort();
		};
	};
	return dup_items;
};

fn finish_items(items: []json::value) void = {
	for (let i = 0z; i < len(items); i += 1) {
		json::finish(items[i]);
	};
	free(items);
};

fn fmt_u32(n: u32) str = {
	if (n == 0) return strings::dup("0")!;
	let buf: [11]u8 = [0...];
	let i = len(buf);
	let v = n;
	for (v > 0; v /= 10) {
		i -= 1;
		buf[i] = '0': u8 + (v % 10): u8;
	};
	return strings::dup(strings::fromutf8(buf[i..])!)!;
};

fn item_labels(items: []json::value) []str = {
	let out: []str = [];
	for (let i = 0z; i < len(items); i += 1) {
		const it = items[i] as json::object;
		const label = *(json::get(&it, "label") as *json::value) as str;
		append(out, strings::dup(label)!)!;
	};
	return out;
};

fn labels_contains(labels: []str, name: str) bool = {
	for (let i = 0z; i < len(labels); i += 1) {
		if (labels[i] == name) return true;
	};
	return false;
};

fn free_labels(labels: []str) void = {
	for (let i = 0z; i < len(labels); i += 1) {
		free(labels[i]);
	};
	free(labels);
};

@test fn completion_struct_field_via_function_param() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	// `b` is a function parameter of an inline struct type; typing `b.`
	// should suggest its fields.
	comp_open(&s, "file:///m1.ha",
		`fn main(b: struct { data: int, line_index: int }) void = {\n\tb.\n};\n`);

	const items = run_completion(&s, out, "file:///m1.ha", 1, 3, 1000.0);
	defer finish_items(items);
	const labels = item_labels(items);
	defer free_labels(labels);
	assert(
		labels_contains(labels, "data"),
		"expected `data` in struct member completions"
	);
	assert(
		labels_contains(labels, "line_index"),
		"expected `line_index` in struct member completions"
	);

	// Each item must be Kind=Field and have a `name: type` detail.
	for (let i = 0z; i < len(items); i += 1) {
		const it = items[i] as json::object;
		const kind = *(json::get(&it, "kind") as *json::value) as f64;
		assert(kind == 5.0, "member completion items must have kind=Field(5)");
		const detail = *(json::get(&it, "detail") as *json::value) as str;
		assert(len(detail) > 0, "member completion items must populate detail");
		const sort = *(json::get(&it, "sortText") as *json::value) as str;
		assert(
			strings::hasprefix(sort, "0-"),
			"member completions must sort above all other sources"
		);
	};
};

@test fn completion_tuple_index_via_function_param() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	// `pair` is a function parameter of a tuple type; typing `pair.`
	// should suggest its positional indices with their element types.
	comp_open(&s, "file:///mt.ha",
		`export fn f(pair: (int, uint)) void = {\n\tpair.\n};\n`);

	const items = run_completion(&s, out, "file:///mt.ha", 1, 6, 1100.0);
	defer finish_items(items);
	const labels = item_labels(items);
	defer free_labels(labels);
	assert(
		labels_contains(labels, "0"),
		"expected `0` in tuple index completions"
	);
	assert(
		labels_contains(labels, "1"),
		"expected `1` in tuple index completions"
	);
	// Member completion is exclusive: keywords/locals must NOT appear.
	assert(!labels_contains(labels, "let"));
	assert(!labels_contains(labels, "pair"));

	// Each item is Kind=Field, sorts above other sources, and carries the
	// element type as detail.
	let saw0 = false;
	let saw1 = false;
	for (let i = 0z; i < len(items); i += 1) {
		const it = items[i] as json::object;
		const kind = *(json::get(&it, "kind") as *json::value) as f64;
		assert(kind == 5.0, "tuple index items must have kind=Field(5)");
		const sort = *(json::get(&it, "sortText") as *json::value) as str;
		assert(
			strings::hasprefix(sort, "0-"),
			"tuple index items must sort above other sources"
		);
		const label = *(json::get(&it, "label") as *json::value) as str;
		const detail = *(json::get(&it, "detail") as *json::value) as str;
		if (label == "0") {
			assert(detail == "int", "element 0 detail should be `int`");
			saw0 = true;
		};
		if (label == "1") {
			assert(detail == "uint", "element 1 detail should be `uint`");
			saw1 = true;
		};
	};
	assert(saw0 && saw1, "both tuple indices must be emitted");
};

@test fn completion_tuple_index_via_pointer() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	// `*(int, uint)` should still let you complete indices via auto-deref,
	// mirroring struct-field completion through a pointer.
	comp_open(&s, "file:///mtp.ha",
		`export fn f(pair: *(int, uint)) void = {\n\tpair.\n};\n`);

	const items = run_completion(&s, out, "file:///mtp.ha", 1, 6, 1101.0);
	defer finish_items(items);
	const labels = item_labels(items);
	defer free_labels(labels);
	assert(
		labels_contains(labels, "0"),
		"auto-deref tuple completion should emit `0`"
	);
	assert(
		labels_contains(labels, "1"),
		"auto-deref tuple completion should emit `1`"
	);
};

@test fn completion_struct_field_via_alias_type() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	// Receiver type is a top-level `type buffer = struct {...};`.
	comp_open(&s, "file:///m2.ha",
		`type buffer = struct { data: []u8, line_index: []size };\nfn main(b: buffer) void = {\n\tb.\n};\n`
	);

	const items = run_completion(&s, out, "file:///m2.ha", 2, 3, 1001.0);
	defer finish_items(items);
	const labels = item_labels(items);
	defer free_labels(labels);
	assert(labels_contains(labels, "data"));
	assert(labels_contains(labels, "line_index"));
	// Member completion is exclusive: keywords/locals must NOT appear.
	assert(!labels_contains(labels, "let"));
	assert(!labels_contains(labels, "main"));
	// Each item must be Kind=Field, have a non-empty `name: type`
	// detail, and sort above other completion sources.
	for (let i = 0z; i < len(items); i += 1) {
		const it = items[i] as json::object;
		const kind = *(json::get(&it, "kind") as *json::value) as f64;
		assert(kind == 5.0, "member completion items must have kind=Field(5)");
		const detail = *(json::get(&it, "detail") as *json::value) as str;
		assert(len(detail) > 0, "member completion items must populate detail");
		const sort = *(json::get(&it, "sortText") as *json::value) as str;
		assert(
			strings::hasprefix(sort, "0-"),
			"member completions must sort above all other sources"
		);
	};
};

@test fn completion_struct_field_via_pointer_alias() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	// `*buffer` should still let you complete fields via auto-deref.
	comp_open(&s, "file:///m3.ha",
		`type buffer = struct { data: []u8, line_index: []size };\nfn main(b: *buffer) void = {\n\tb.\n};\n`
	);

	const items = run_completion(&s, out, "file:///m3.ha", 2, 3, 1002.0);
	defer finish_items(items);
	const labels = item_labels(items);
	defer free_labels(labels);
	assert(labels_contains(labels, "data"));
	assert(labels_contains(labels, "line_index"));
	// Auto-deref still emits proper Field-kind items with detail + sort.
	for (let i = 0z; i < len(items); i += 1) {
		const it = items[i] as json::object;
		const kind = *(json::get(&it, "kind") as *json::value) as f64;
		assert(kind == 5.0, "auto-deref member items must have kind=Field(5)");
		const detail = *(json::get(&it, "detail") as *json::value) as str;
		assert(len(detail) > 0, "auto-deref member items must populate detail");
		const sort = *(json::get(&it, "sortText") as *json::value) as str;
		assert(
			strings::hasprefix(sort, "0-"),
			"auto-deref member items must sort above other sources"
		);
	};
};

@test fn completion_struct_field_filters_by_partial() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	// Typing `b.li` should only show fields starting with `li`.
	comp_open(&s, "file:///m4.ha",
		`type buffer = struct { data: []u8, line_index: []size };\nfn main(b: buffer) void = {\n\tb.li\n};\n`
	);

	const items = run_completion(&s, out, "file:///m4.ha", 2, 5, 1003.0);
	defer finish_items(items);
	const labels = item_labels(items);
	defer free_labels(labels);
	assert(labels_contains(labels, "line_index"));
	// Every returned label must satisfy the `li` prefix filter — not
	// just that one matching label is present and one excluded label
	// is absent.
	assert(len(labels) > 0, "filter must still return at least one match");
	for (let i = 0z; i < len(labels); i += 1) {
		assert(
			strings::hasprefix(labels[i], "li"),
			"every item under partial `li` must start with `li`"
		);
	};
};

@test fn completion_struct_field_after_call_return() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	// `make_buf()` returns a buffer; `make_buf().data` is a valid access
	// chain so completion should suggest fields after the `)`.
	comp_open(&s, "file:///m5.ha",
		`type buffer = struct { data: []u8, line_index: []size };\nfn make_buf() buffer = buffer { ... };\nfn main() void = {\n\tmake_buf().\n};\n`
	);

	const items = run_completion(&s, out, "file:///m5.ha", 3, 12, 1004.0);
	defer finish_items(items);
	const labels = item_labels(items);
	defer free_labels(labels);
	assert(labels_contains(labels, "data"));
	assert(labels_contains(labels, "line_index"));
};

@test fn completion_struct_field_after_nested_field() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	// `outer.inner.` should resolve `outer.inner`'s type and emit its
	// fields. Inner field names are multi-rune so any loc.end-style
	// offset bug surfaces here (single-char names mask it).
	comp_open(&s, "file:///m6.ha",
		`type inner = struct { posx: int, posy: int };\ntype outer = struct { inner: inner, name: str };\nfn main(o: outer) void = {\n\to.inner.\n};\n`
	);

	const items = run_completion(&s, out, "file:///m6.ha", 3, 9, 1005.0);
	defer finish_items(items);
	const labels = item_labels(items);
	defer free_labels(labels);
	assert(labels_contains(labels, "posx"));
	assert(labels_contains(labels, "posy"));
	assert(!labels_contains(labels, "inner"), "must not show outer's fields");
	assert(!labels_contains(labels, "name"));
};

@test fn completion_skips_member_mode_for_float_literal() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	// `1.|` is a float literal continuation, not a member access. We
	// should fall back to PLAIN completion (keywords/etc).
	comp_open(&s, "file:///m7.ha", `fn main() void = {\n\t1.\n};\n`);

	const items = run_completion(&s, out, "file:///m7.ha", 1, 3, 1006.0);
	defer finish_items(items);
	const labels = item_labels(items);
	defer free_labels(labels);
	// Should contain keywords (PLAIN-mode fallback).
	assert(
		labels_contains(labels, "let") || labels_contains(labels, "return"),
		"`1.` should not flip into member mode; PLAIN keywords expected"
	);
};

@test fn completion_skips_member_mode_for_range_dotdot() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	// `arr[0..]` — the second dot is part of `..`, never a member access.
	comp_open(&s, "file:///m8.ha",
		`fn main(arr: []int) void = {\n\tlet _ = arr[0..\n};\n`);

	const items = run_completion(&s, out, "file:///m8.ha", 1, 15, 1007.0);
	defer finish_items(items);
	// `..` must not flip into member mode. The fallback is PLAIN
	// completion, so we expect Field-kind items to be absent AND at
	// least one keyword (PLAIN-mode signal) to be present — `[]` would
	// satisfy the kind-check alone but would silently regress to an
	// always-empty completion.
	let saw_keyword = false;
	const labels = item_labels(items);
	defer free_labels(labels);
	for (let i = 0z; i < len(items); i += 1) {
		const it = items[i] as json::object;
		match (json::get(&it, "kind")) {
		case let p: *json::value =>
			const kind = *p as f64;
			assert(kind != 5.0, "`..` must not produce Field-kind completion items");
			if (kind == 14.0) saw_keyword = true;
		case void => void;
		};
	};
	assert(
		saw_keyword || labels_contains(labels, "let")
		|| labels_contains(labels, "return"),
		"`..` must fall back to PLAIN completion (at least one keyword expected)"
	);
};

@test fn completion_struct_field_via_embedded_struct() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	// An embedded `struct { ... }` inlines its fields into the outer
	// struct; completion should surface them transparently. Inner
	// field names are multi-rune so offset-end bugs aren't masked.
	comp_open(&s, "file:///m9.ha",
		`type outer = struct { struct { posx: int, posy: int }, label: str };\nfn main(o: outer) void = {\n\to.\n};\n`
	);

	const items = run_completion(&s, out, "file:///m9.ha", 2, 3, 1008.0);
	defer finish_items(items);
	const labels = item_labels(items);
	defer free_labels(labels);
	assert(labels_contains(labels, "posx"));
	assert(labels_contains(labels, "posy"));
	assert(labels_contains(labels, "label"));
};

@test fn completion_struct_field_via_embedded_alias() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	// `point` is referenced by name (not `struct { ... }`); it's an
	// embedded type alias and its fields should be reachable. Inner
	// field names are multi-rune so offset-end bugs aren't masked.
	comp_open(&s, "file:///m10.ha",
		`type point = struct { posx: int, posy: int };\ntype labeled = struct { point, label: str };\nfn main(p: labeled) void = {\n\tp.\n};\n`
	);

	const items = run_completion(&s, out, "file:///m10.ha", 3, 3, 1009.0);
	defer finish_items(items);
	const labels = item_labels(items);
	defer free_labels(labels);
	assert(labels_contains(labels, "posx"));
	assert(labels_contains(labels, "posy"));
	assert(labels_contains(labels, "label"));
};

@test fn completion_skips_anonymous_underscore_field() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	// `_` is anonymous padding and isn't accessible by name; never emit it.
	comp_open(&s, "file:///m11.ha",
		`type padded = struct { _: int, real: int };\nfn main(p: padded) void = {\n\tp.\n};\n`
	);

	const items = run_completion(&s, out, "file:///m11.ha", 2, 3, 1010.0);
	defer finish_items(items);
	const labels = item_labels(items);
	defer free_labels(labels);
	assert(labels_contains(labels, "real"));
	assert(
		!labels_contains(labels, "_"),
		"anonymous `_` field must not be emitted as a completion item"
	);
};

@test fn completion_struct_field_via_let_binding() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	// Locally bound via `let b: buffer = ...;`.
	comp_open(&s, "file:///m12.ha",
		`type buffer = struct { data: []u8, line_index: []size };\nfn main() void = {\n\tlet b: buffer = buffer { ... };\n\tb.\n};\n`
	);

	const items = run_completion(&s, out, "file:///m12.ha", 3, 3, 1011.0);
	defer finish_items(items);
	const labels = item_labels(items);
	defer free_labels(labels);
	assert(labels_contains(labels, "data"));
	assert(labels_contains(labels, "line_index"));
};

@test fn completion_struct_field_cursor_inside_existing_word() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	// Cursor sits between `li` and `ne_index` while editing in the middle
	// of an identifier. The splice must replace the entire word
	// (`line_index`) with the sentinel so the parse succeeds.
	comp_open(&s, "file:///m13.ha",
		`type buffer = struct { data: []u8, line_index: []size };\nfn main(b: buffer) void = {\n\tb.line_index\n};\n`
	);

	// Position character=5 places cursor after `b.li` (\t=1, b=1, .=1, l=1, i=1 → 5).
	const items = run_completion(&s, out, "file:///m13.ha", 2, 5, 1012.0);
	defer finish_items(items);
	const labels = item_labels(items);
	defer free_labels(labels);
	assert(
		labels_contains(labels, "line_index"),
		"member completion must work when cursor is inside an existing word"
	);
};

@test fn completion_struct_field_on_identifier_ending_in_digit() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	// Identifiers may legitimately end in digits (`buf1`, `hash32`).
	// The dot in `buf1.` is a member access, not a float-literal point.
	comp_open(&s, "file:///mdig.ha",
		`type buffer = struct { data: []u8, line_index: []size };\nfn main(buf1: buffer) void = {\n\tbuf1.\n};\n`
	);

	// Line 2 = `\tbuf1.`; position character=6 sits right after the dot.
	const items = run_completion(&s, out, "file:///mdig.ha", 2, 6, 1013.0);
	defer finish_items(items);
	const labels = item_labels(items);
	defer free_labels(labels);
	assert(
		labels_contains(labels, "data"),
		"identifier ending in digit must still trigger member completion"
	);
	assert(labels_contains(labels, "line_index"));
};

@test fn completion_struct_field_inside_match_value() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	// The receiver is inside a `match (h.|)` head expression; the AST
	// walker must descend into match_expr.value. Include a case clause
	// so the synth parses cleanly (Hare's match requires >= 1 case).
	comp_open(&s, "file:///mmatch.ha",
		`type tagged = (int | str);\ntype holder = struct { val: tagged };\nfn main(h: holder) void = {\n\tmatch (h.) {\n\tcase => void;\n\t};\n};\n`
	);

	// Line 3 = `\tmatch (h.) {`; position char=10 sits right after the dot.
	const items = run_completion(&s, out, "file:///mmatch.ha", 3, 10, 1014.0);
	defer finish_items(items);
	const labels = item_labels(items);
	defer free_labels(labels);
	assert(
		labels_contains(labels, "val"),
		"member completion must work inside match value expressions"
	);
};

@test fn completion_struct_field_after_postfix_error_assert() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	// Postfix `!` (error-assert) before `.` is a valid receiver
	// terminator: `make_buf()!.<field>`. Use a real `!`-tagged error
	// variant so [[strip_errors_located]] can collapse the result type
	// back to `buffer`.
	comp_open(&s, "file:///mexc.ha",
		`type buffer = struct { data: []u8, line_index: []size };\ntype err = !void;\nfn make_buf() (buffer | err) = buffer { ... };\nfn main() void = {\n\tmake_buf()!.\n};\n`
	);

	// Line 4 = `\tmake_buf()!.`; position 13 sits right after the dot.
	const items = run_completion(&s, out, "file:///mexc.ha", 4, 13, 1015.0);
	defer finish_items(items);
	const labels = item_labels(items);
	defer free_labels(labels);
	assert(
		labels_contains(labels, "data"),
		"postfix `!` before `.` must still trigger member completion"
	);
	assert(labels_contains(labels, "line_index"));
};

@test fn completion_struct_field_inside_assert_message() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	// The receiver sits inside an `assert(...)` builtin expression;
	// the AST walker must descend into assert_expr.cond.
	comp_open(&s, "file:///masrt.ha",
		`type holder = struct { ok: bool };\nfn main(h: holder) void = {\n\tassert(h.);\n};\n`
	);

	// Line 2 = `\tassert(h.);`; position 10 sits right after the dot.
	const items = run_completion(&s, out, "file:///masrt.ha", 2, 10, 1016.0);
	defer finish_items(items);
	const labels = item_labels(items);
	defer free_labels(labels);
	assert(
		labels_contains(labels, "ok"),
		"member completion must work inside assert() arguments"
	);
};

@test fn completion_struct_field_inside_struct_literal() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	// The receiver appears as an init expression inside a struct
	// literal; the walker must descend into literal_expr -> struct_literal.
	comp_open(&s, "file:///mlit.ha",
		`type inner = struct { x: int };\ntype outer = struct { v: int };\nfn main(i: inner) void = {\n\tlet _ = outer { v = i. };\n};\n`
	);

	// Line 3 = `\tlet _ = outer { v = i. };`; position 23 sits right
	// after the dot (1 tab + 21 ASCII chars + dot = position 23).
	const items = run_completion(&s, out, "file:///mlit.ha", 3, 23, 1017.0);
	defer finish_items(items);
	const labels = item_labels(items);
	defer free_labels(labels);
	assert(
		labels_contains(labels, "x"),
		"member completion must work inside struct-literal initializers"
	);
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
		*(json::get(&(v as json::object),
			"result") as *json::value) as json::object;
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

// Exercises the resolve enrichment path end-to-end: the initial
// completion call must stash a `data` field on each resolvable item,
// and completionItem/resolve must look that data up to populate
// `detail` (the rendered signature) and `documentation` (the cleaned
// doc-comment markdown). Uses a multi-character identifier so a
// regression that compared only the first byte of `name` would still
// fail. Hare's lexer disallows non-ASCII identifier runes, so the
// CLAUDE.md "multi-byte rune" guidance can't apply to identifiers.
@test fn completion_resolve_enriches_detail_and_documentation() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);

	// Inline doc comment hugs the decl so the parser captures it as
	// the decl's `docs`. The literal `\"` sequences round-trip through
	// JSON to `"` in the document text.
	comp_open(&s, "file:///resv.ha",
		`// Returns an empty label for the widget.\nexport fn frobnicate_widget(arg: int) str = \"\";\nfn main() void = frob\n`
	);

	// Step 1: drive the initial completion and pull the `data` field
	// off the frobnicate_widget item. Cursor sits right after `frob`
	// on line 2; `fn main() void = frob` is 21 characters.
	const params =
		`{"textDocument":{"uri":"file:///resv.ha"},"position":{"line":2,"character":21}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 600.0,
		method = strings::dup("textDocument/completion")!,
		params = pv,
	};
	defer free(r.method);
	handle_completion(&s, r);

	const v = comp_skip_to_response(out, 600.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object),
			"result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;

	let data_dup: json::value = json::_null;
	let owned_data = false;
	defer if (owned_data) json::finish(data_dup);
	for (let i = 0z; i < len(items); i += 1) {
		const it = items[i] as json::object;
		const label = *(json::get(&it, "label") as *json::value) as str;
		if (label != "frobnicate_widget") continue;
		const dp = json::get(&it, "data") as *json::value;
		data_dup = json::dup(*dp)!;
		owned_data = true;
		break;
	};
	assert(
		owned_data,
		"frobnicate_widget completion item must carry a `data` field"
	);

	// Step 2: build a CompletionItem mirroring what the editor would
	// send back (carrying just label/kind/data) and dispatch resolve.
	let resolve_item = json::newobject();
	json::set(&resolve_item, "label", "frobnicate_widget": json::value)!;
	json::put(&resolve_item, "kind", 3.0: f64)!;
	json::put(&resolve_item, "data", data_dup)!;
	owned_data = false;
	const resolve_v: json::value = resolve_item;
	defer json::finish(resolve_v);
	const r2 = lsp::request {
		id = 601.0,
		method = strings::dup("completionItem/resolve")!,
		params = resolve_v,
	};
	defer free(r2.method);
	handle_completion_resolve(&s, r2);

	const v2 = comp_skip_to_response(out, 601.0);
	defer json::finish(v2);
	const result2 =
		*(json::get(&(v2 as json::object),
			"result") as *json::value) as json::object;

	// detail must contain the rendered signature: starts with `fn`
	// and includes the full identifier as written.
	const detail = *(json::get(&result2, "detail") as *json::value) as str;
	assert(
		strings::contains(detail, "frobnicate_widget"),
		"resolve must replace detail with a signature containing the identifier"
	);
	assert(
		strings::contains(detail, "fn"),
		"resolve must replace detail with the function signature, not the full name"
	);

	// documentation must be MarkupContent(kind=markdown) carrying the
	// cleaned doc-comment body (no leading-space-per-line residue).
	const doc_obj =
		*(json::get(&result2, "documentation") as *json::value) as json::object;
	const dkind = *(json::get(&doc_obj, "kind") as *json::value) as str;
	assert(
		dkind == "markdown",
		"resolve must return documentation as MarkupContent(kind=markdown)"
	);
	const dvalue = *(json::get(&doc_obj, "value") as *json::value) as str;
	assert(
		strings::contains(dvalue, "Returns an empty label for the widget"),
		"resolve documentation must include the cleaned doc comment"
	);
};

// Resolve must echo the input verbatim when no `data` field is set:
// editors that don't drive the lazy-resolve path (or any future
// caller that hands us a synthetic item) shouldn't see their popup
// contents disappear. Mirrors the e2e passthrough test at the unit
// level so a regression surfaces before the binary is even built.
@test fn completion_resolve_passthrough_without_data() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);

	const params_str = `{"label":"foo","kind":3}`;
	let pv = json::loadstr(params_str)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 610.0,
		method = strings::dup("completionItem/resolve")!,
		params = pv,
	};
	defer free(r.method);
	handle_completion_resolve(&s, r);

	const v = comp_skip_to_response(out, 610.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object),
			"result") as *json::value) as json::object;
	const label = *(json::get(&result, "label") as *json::value) as str;
	assert(label == "foo");
	const kind = *(json::get(&result, "kind") as *json::value) as f64;
	assert(kind == 3.0);
};

// When the data field references a file we no longer have open, the
// handler must echo the input rather than erroring out.
@test fn completion_resolve_missing_document_echoes_input() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);

	const params_str =
		`{"label":"foo","kind":3,"detail":"orig","data":{"source":"file","uri":"file:///nonexistent.ha","name":"foo"}}`;
	let pv = json::loadstr(params_str)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 611.0,
		method = strings::dup("completionItem/resolve")!,
		params = pv,
	};
	defer free(r.method);
	handle_completion_resolve(&s, r);

	const v = comp_skip_to_response(out, 611.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object),
			"result") as *json::value) as json::object;
	const detail = *(json::get(&result, "detail") as *json::value) as str;
	assert(
		detail == "orig",
		"resolve must echo the original detail when the document is missing"
	);
};

// --- Type vs value position -------------------------------------------
@test fn completion_value_position_suggests_local_let_binding() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	// `let thing = false;` on one line; typing `th` on the next should
	// surface the local binding `thing` as a Variable completion. This is
	// the canonical value-position case the feature targets.
	comp_open(&s, "file:///vpos.ha",
		"fn main() void = {\\n\\tlet thing = false;\\n\\tth\\n};\\n");

	// Line 2 = `\tth`; char 3 sits right after `th`.
	const items = run_completion(&s, out, "file:///vpos.ha", 2, 3, 2000.0);
	defer finish_items(items);
	const labels = item_labels(items);
	defer free_labels(labels);
	assert(
		labels_contains(labels, "thing"),
		"value-position completion must suggest the in-scope local binding"
	);
	// The local must present as a Variable (kind 6) so the editor renders
	// it distinctly from keywords / functions.
	let saw_variable = false;
	for (let i = 0z; i < len(items); i += 1) {
		const it = items[i] as json::object;
		const label = *(json::get(&it, "label") as *json::value) as str;
		if (label != "thing") continue;
		const kind = *(json::get(&it, "kind") as *json::value) as f64;
		assert(kind == 6.0, "local let binding must have kind=Variable(6)");
		saw_variable = true;
	};
	assert(saw_variable, "the `thing` binding item must be present");
};

@test fn completion_type_position_suggests_builtin_type() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	// Typing the type annotation of a binding: `let thing: s`. With no
	// initializer yet (the realistic while-typing state) the binding
	// doesn't parse, but classification is byte-based, so the type
	// keywords must still be offered — and the non-type keywords filtered.
	comp_open(&s, "file:///tpos.ha",
		"fn main() void = {\\n\\tlet thing: s\\n};\\n");

	// Line 1 = `\tlet thing: s`; char 13 sits right after `s`.
	const items = run_completion(&s, out, "file:///tpos.ha", 1, 13, 2001.0);
	defer finish_items(items);
	const labels = item_labels(items);
	defer free_labels(labels);
	assert(
		labels_contains(labels, "str"),
		"type-position completion must suggest the builtin type `str`"
	);
	// Non-type keywords that happen to start with `s` must NOT leak into a
	// type position.
	assert(
		!labels_contains(labels, "static"),
		"type position must exclude the non-type keyword `static`"
	);
	assert(
		!labels_contains(labels, "switch"),
		"type position must exclude the non-type keyword `switch`"
	);
	assert(
		!labels_contains(labels, "let"),
		"type position must exclude the non-type keyword `let`"
	);
};

@test fn completion_type_position_suggests_type_alias() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	// A top-level `type mytype = int;` must be offered when completing a
	// type annotation, while the function `main` (a value symbol) must not.
	comp_open(&s, "file:///talias.ha",
		"type mytype = int;\\nfn main() void = {\\n\\tlet x: my = 0\\n};\\n");

	// Line 2 = `\tlet x: my = 0`; char 10 sits right after `my`.
	const items = run_completion(&s, out, "file:///talias.ha", 2, 10, 2002.0);
	defer finish_items(items);
	const labels = item_labels(items);
	defer free_labels(labels);
	assert(
		labels_contains(labels, "mytype"),
		"type-position completion must suggest the file-local type alias"
	);
	assert(
		!labels_contains(labels, "main"),
		"type position must exclude value symbols like the function `main`"
	);
};

@test fn completion_type_position_excludes_value_binding() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	// A local value binding `thing` is in scope, and a type alias `theme`
	// also matches the `th` prefix. In a type position only the type
	// alias may surface — the value binding must be suppressed.
	comp_open(&s, "file:///texcl.ha",
		"type theme = int;\\nfn main() void = {\\n\\tlet thing = false;\\n\\tlet other: th = thing\\n};\\n"
	);

	// Line 3 = `\tlet other: th = thing`; char 14 sits right after `th`.
	const items = run_completion(&s, out, "file:///texcl.ha", 3, 14, 2003.0);
	defer finish_items(items);
	const labels = item_labels(items);
	defer free_labels(labels);
	assert(
		labels_contains(labels, "theme"),
		"type position must still surface the matching type alias"
	);
	assert(
		!labels_contains(labels, "thing"),
		"type position must exclude the in-scope value binding `thing`"
	);
};

@test fn completion_type_position_offers_done_and_nomem() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	// `done` and `nomem` are builtin types accepted by hare::parse's
	// primitive_type, so they must be offered in a type position even
	// though they read like control-flow / error keywords elsewhere.
	comp_open(&s, "file:///tdone.ha",
		"fn main() void = {\\n\\tlet x: do\\n};\\n");
	const items_d = run_completion(&s, out, "file:///tdone.ha", 1, 10, 2010.0);
	defer finish_items(items_d);
	const labels_d = item_labels(items_d);
	defer free_labels(labels_d);
	assert(
		labels_contains(labels_d, "done"),
		"type position must offer the builtin type `done`"
	);

	comp_open(&s, "file:///tnomem.ha",
		"fn main() void = {\\n\\tlet x: no\\n};\\n");
	const items_n = run_completion(&s, out, "file:///tnomem.ha", 1, 10, 2011.0);
	defer finish_items(items_n);
	const labels_n = item_labels(items_n);
	defer free_labels(labels_n);
	assert(
		labels_contains(labels_n, "nomem"),
		"type position must offer the builtin type `nomem`"
	);
};

@test fn completion_type_position_qualified_filters_to_types() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	// A module exports both a function and a type. After `mymod::` in a
	// type position only the type member is grammatical, so the function
	// must be filtered out.
	const provider = strings::toutf8(
		"export fn myfunc() void = void;\nexport type mytype = int;\n");
	analysis::index_file(&s.workspace_index, "/repo/mymod/p.ha", provider);

	comp_open(&s, "file:///qtype.ha",
		"use mymod;\\nfn main() void = {\\n\\tlet v: mymod::\\n};\\n");

	// Line 2 = `\tlet v: mymod::`; char 15 sits right after the `::`.
	const items = run_completion(&s, out, "file:///qtype.ha", 2, 15, 2004.0);
	defer finish_items(items);
	const labels = item_labels(items);
	defer free_labels(labels);
	assert(
		labels_contains(labels, "mytype"),
		"qualified type position must surface the module's type member"
	);
	assert(
		!labels_contains(labels, "myfunc"),
		"qualified type position must exclude the module's function member"
	);
};
