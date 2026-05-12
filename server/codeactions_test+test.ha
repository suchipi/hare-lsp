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

// Returns every code action returned for the given URI. The caller owns
// the response and must finish it.
fn ca_get_actions(s: *server, uri: str, request_id: f64) json::value = {
	const params = strings::concat(`{"textDocument":{"uri":"`, uri,
		`"},"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"context":{"diagnostics":[]}}`)!;
	defer free(params);
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = request_id,
		method = strings::dup("textDocument/codeAction")!,
		params = pv,
	};
	defer free(r.method);
	handle_code_action(s, r);
	return ca_skip_to_response(s.out: *memio::stream, request_id);
};

// Counts code actions in a response whose title starts with `prefix`.
fn ca_count_titles_with_prefix(v: json::value, prefix: str) size = {
	const actions = *(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	let n: size = 0;
	for (let i = 0z; i < len(actions); i += 1) {
		const action = actions[i] as json::object;
		const title = *(json::get(&action, "title") as *json::value) as str;
		if (strings::hasprefix(title, prefix)) n += 1;
	};
	return n;
};

@test fn unused_imports_void_binding_flagged() void = {
	let (s, scan, in_buf, out) = ca_test_server();
	defer ca_test_cleanup(&s, scan, in_buf, out);
	// `foo` is imported but never referenced. `bar` is used as `bar::x()`.
	ca_open(&s, "file:///u1.ha",
		"use foo;\\nuse bar;\\nfn x() void = bar::x();\\n");

	const v = ca_get_actions(&s, "file:///u1.ha", 100.0);
	defer json::finish(v);
	// Expect one quickfix for `foo` (range overlaps line 0) plus the
	// source action "Remove all unused imports". The quickfix for
	// `bar` should NOT appear because `bar` is used.
	const removes = ca_count_titles_with_prefix(v, "Remove unused import");
	const all = ca_count_titles_with_prefix(v, "Remove all unused imports");
	assert(removes == 1);
	assert(all == 1);
};

@test fn unused_imports_alias_binding_flagged() void = {
	let (s, scan, in_buf, out) = ca_test_server();
	defer ca_test_cleanup(&s, scan, in_buf, out);
	// `foo` is the alias and never appears in the body.
	ca_open(&s, "file:///u2.ha",
		"use foo = bar::baz;\\nfn x() void = void;\\n");

	const v = ca_get_actions(&s, "file:///u2.ha", 101.0);
	defer json::finish(v);
	const removes = ca_count_titles_with_prefix(v, "Remove unused import");
	assert(removes == 1);
};

@test fn unused_imports_aliased_use_with_namespace_is_used() void = {
	let (s, scan, in_buf, out) = ca_test_server();
	defer ca_test_cleanup(&s, scan, in_buf, out);
	// The alias `foo` is used as `foo::qux()` so the import is live.
	ca_open(&s, "file:///u3.ha",
		"use foo = bar::baz;\\nfn x() void = foo::qux();\\n");

	const v = ca_get_actions(&s, "file:///u3.ha", 102.0);
	defer json::finish(v);
	// No unused imports => no removal actions of any kind.
	const removes = ca_count_titles_with_prefix(v, "Remove unused import");
	const all = ca_count_titles_with_prefix(v, "Remove all unused imports");
	assert(removes == 0);
	assert(all == 0);
};

@test fn unused_imports_member_used_is_not_flagged() void = {
	let (s, scan, in_buf, out) = ca_test_server();
	defer ca_test_cleanup(&s, scan, in_buf, out);
	// Member `a` is called directly; `b` is not. Whole import stays
	// because at least one member is used.
	ca_open(&s, "file:///u4.ha",
		"use foo::{a, b};\\nfn x() void = a();\\n");

	const v = ca_get_actions(&s, "file:///u4.ha", 103.0);
	defer json::finish(v);
	const removes = ca_count_titles_with_prefix(v, "Remove unused import");
	assert(removes == 0);
};

@test fn unused_imports_all_members_unused_is_flagged() void = {
	let (s, scan, in_buf, out) = ca_test_server();
	defer ca_test_cleanup(&s, scan, in_buf, out);
	ca_open(&s, "file:///u5.ha",
		"use foo::{a, b};\\nfn x() void = void;\\n");

	const v = ca_get_actions(&s, "file:///u5.ha", 104.0);
	defer json::finish(v);
	const removes = ca_count_titles_with_prefix(v, "Remove unused import");
	assert(removes == 1);
};

@test fn unused_imports_wildcard_is_not_flagged() void = {
	let (s, scan, in_buf, out) = ca_test_server();
	defer ca_test_cleanup(&s, scan, in_buf, out);
	// Wildcard imports are conservatively never flagged: the names
	// they expose can't be statically enumerated.
	ca_open(&s, "file:///u6.ha",
		"use foo::*;\\nfn x() void = void;\\n");

	const v = ca_get_actions(&s, "file:///u6.ha", 105.0);
	defer json::finish(v);
	const removes = ca_count_titles_with_prefix(v, "Remove unused import");
	assert(removes == 0);
};

@test fn unused_imports_mid_path_segment_does_not_count_as_use() void = {
	let (s, scan, in_buf, out) = ca_test_server();
	defer ca_test_cleanup(&s, scan, in_buf, out);
	// `foo` appears in `bar::foo::baz` but is a path continuation, not
	// a reference to the imported `foo` module. So `use foo;` is
	// unused.
	ca_open(&s, "file:///u7.ha",
		"use foo;\\nfn x() void = bar::foo::baz();\\n");

	const v = ca_get_actions(&s, "file:///u7.ha", 106.0);
	defer json::finish(v);
	const removes = ca_count_titles_with_prefix(v, "Remove unused import");
	assert(removes == 1);
};

@test fn unused_imports_match_inside_comment_does_not_count() void = {
	let (s, scan, in_buf, out) = ca_test_server();
	defer ca_test_cleanup(&s, scan, in_buf, out);
	// `foo::` appears inside a comment and a string literal; neither
	// counts as a real use of the import.
	ca_open(&s, "file:///u8.ha",
		"use foo;\\n// foo::bar\\nfn x() void = {\\n\\tconst s = \\\"foo::baz\\\";\\n};\\n");

	const v = ca_get_actions(&s, "file:///u8.ha", 107.0);
	defer json::finish(v);
	const removes = ca_count_titles_with_prefix(v, "Remove unused import");
	assert(removes == 1);
};

@test fn unused_import_quickfix_edit_clears_the_use_line() void = {
	let (s, scan, in_buf, out) = ca_test_server();
	defer ca_test_cleanup(&s, scan, in_buf, out);
	ca_open(&s, "file:///u9.ha",
		"use foo;\\nfn x() void = void;\\n");

	const v = ca_get_actions(&s, "file:///u9.ha", 108.0);
	defer json::finish(v);
	const actions = *(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	// Find the per-import quickfix (kind == "quickfix").
	let found_quickfix = false;
	for (let i = 0z; i < len(actions); i += 1) {
		const action = actions[i] as json::object;
		const kind = *(json::get(&action, "kind") as *json::value) as str;
		if (kind != "quickfix") continue;
		const edit = *(json::get(&action, "edit") as *json::value) as json::object;
		const changes = *(json::get(&edit, "changes") as *json::value) as json::object;
		const edits = *(json::get(&changes, "file:///u9.ha") as *json::value) as []json::value;
		assert(len(edits) == 1);
		const e0 = edits[0] as json::object;
		const new_text = *(json::get(&e0, "newText") as *json::value) as str;
		assert(new_text == "");
		const range = *(json::get(&e0, "range") as *json::value) as json::object;
		const start = *(json::get(&range, "start") as *json::value) as json::object;
		const start_line = *(json::get(&start, "line") as *json::value) as f64;
		assert(start_line == 0.0);
		found_quickfix = true;
		break;
	};
	assert(found_quickfix);
};

@test fn unused_import_source_batch_removes_all() void = {
	let (s, scan, in_buf, out) = ca_test_server();
	defer ca_test_cleanup(&s, scan, in_buf, out);
	// Three imports, none used. The source action should batch all
	// three into one WorkspaceEdit.
	ca_open(&s, "file:///u10.ha",
		"use a;\\nuse b;\\nuse c;\\nfn x() void = void;\\n");

	const v = ca_get_actions(&s, "file:///u10.ha", 109.0);
	defer json::finish(v);
	const actions = *(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	let found_batch = false;
	for (let i = 0z; i < len(actions); i += 1) {
		const action = actions[i] as json::object;
		const kind = *(json::get(&action, "kind") as *json::value) as str;
		if (kind != "source.removeUnused") continue;
		const edit = *(json::get(&action, "edit") as *json::value) as json::object;
		const changes = *(json::get(&edit, "changes") as *json::value) as json::object;
		const edits = *(json::get(&changes, "file:///u10.ha") as *json::value) as []json::value;
		assert(len(edits) == 3);
		found_batch = true;
		break;
	};
	assert(found_batch);
};

@test fn unused_import_quickfix_range_outside_imports_is_skipped() void = {
	let (s, scan, in_buf, out) = ca_test_server();
	defer ca_test_cleanup(&s, scan, in_buf, out);
	// `foo` is unused, but the request range is on line 2 (the fn
	// decl). Per-import quickfix should be suppressed; the source
	// action should still appear.
	ca_open(&s, "file:///u11.ha",
		"use foo;\\n\\nfn x() void = void;\\n");

	const params = `{"textDocument":{"uri":"file:///u11.ha"},"range":{"start":{"line":2,"character":0},"end":{"line":2,"character":0}},"context":{"diagnostics":[]}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 110.0,
		method = strings::dup("textDocument/codeAction")!,
		params = pv,
	};
	defer free(r.method);
	handle_code_action(&s, r);
	const v = ca_skip_to_response(out, 110.0);
	defer json::finish(v);
	const actions = *(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	let saw_quickfix = false;
	let saw_batch = false;
	for (let i = 0z; i < len(actions); i += 1) {
		const action = actions[i] as json::object;
		const kind = *(json::get(&action, "kind") as *json::value) as str;
		if (kind == "quickfix") saw_quickfix = true;
		if (kind == "source.removeUnused") saw_batch = true;
	};
	assert(!saw_quickfix);
	assert(saw_batch);
};
