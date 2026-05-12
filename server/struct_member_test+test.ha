// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use analysis;
use encoding::json;
use lsp;
use strings;

// Shared test helpers (nav_test_server / nav_open / skip_to_response /
// nav_write etc.) live in navigation_test+test.ha.
@test fn hover_on_struct_member_shows_field_type() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// Line 0: type point = struct { x: int };
	// Line 1: fn f(p: point) void = { let _ = p.x; };
	// `x` in `p.x` is at column 34 of line 1.
	const src =
		"type point = struct { x: int };\\nfn f(p: point) void = { let _ = p.x; };\\n";
	nav_open(&s, "file:///sm_hover.ha", src);

	const params =
		`{"textDocument":{"uri":"file:///sm_hover.ha"},"position":{"line":1,"character":34}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 600.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 600.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "(field)"));
	assert(strings::contains(value, "int"));
};

@test fn hover_on_struct_member_includes_doc_comment() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// Line 0: type point = struct {
	// Line 1: \t// horizontal coordinate
	// Line 2: \tx: int,
	// Line 3: };
	// Line 4: fn f(p: point) void = { let _ = p.x; };
	// `x` at column 34 of line 4.
	const src =
		"type point = struct {\\n\\t// horizontal coordinate\\n\\tx: int,\\n};\\nfn f(p: point) void = { let _ = p.x; };\\n";
	nav_open(&s, "file:///sm_docs.ha", src);

	const params =
		`{"textDocument":{"uri":"file:///sm_docs.ha"},"position":{"line":4,"character":34}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 601.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 601.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "horizontal coordinate"));
};

@test fn definition_on_struct_member_jumps_to_field() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src =
		"type point = struct { x: int };\\nfn f(p: point) void = { let _ = p.x; };\\n";
	nav_open(&s, "file:///sm_def.ha", src);

	const params =
		`{"textDocument":{"uri":"file:///sm_def.ha"},"position":{"line":1,"character":34}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 602.0,
		method = strings::dup("textDocument/definition")!,
		params = pv,
	};
	defer free(r.method);
	handle_definition(&s, r);

	const v = skip_to_response(out, 602.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const uri = *(json::get(&result, "uri") as *json::value) as str;
	assert(uri == "file:///sm_def.ha");
	const range = *(json::get(&result, "range") as *json::value) as json::object;
	const start = *(json::get(&range, "start") as *json::value) as json::object;
	// Field `x` lives on line 0; "type point = struct { x: int };" -> col 22.
	assert(*(json::get(&start, "line") as *json::value) as f64 == 0.0);
	assert(*(json::get(&start, "character") as *json::value) as f64 == 22.0);
};

@test fn hover_on_struct_member_through_pointer() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// Line 1: "fn f(p: *point) void = { let _ = p.x; };"
	// p in (p: *point) param, .x at column 35.
	const src =
		"type point = struct { x: int };\\nfn f(p: *point) void = { let _ = p.x; };\\n";
	nav_open(&s, "file:///sm_ptr.ha", src);

	const params =
		`{"textDocument":{"uri":"file:///sm_ptr.ha"},"position":{"line":1,"character":35}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 603.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 603.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "(field)"));
	assert(strings::contains(value, "int"));
};

@test fn hover_on_struct_member_unknown_field_returns_null() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// `.nope` is not a member; hover should fall through and yield null.
	// Line 1: "fn f(p: point) void = { let _ = p.nope; };"
	// `nope` starts at column 34.
	const src =
		"type point = struct { x: int };\\nfn f(p: point) void = { let _ = p.nope; };\\n";
	nav_open(&s, "file:///sm_unk.ha", src);

	const params =
		`{"textDocument":{"uri":"file:///sm_unk.ha"},"position":{"line":1,"character":34}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 604.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 604.0);
	defer json::finish(v);
	const result = *(json::get(&(v as json::object), "result") as *json::value);
	assert(result is json::_null);
};

@test fn hover_on_chained_struct_member() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// Line 0: type inner = struct { x: int };
	// Line 1: type outer = struct { i: inner };
	// Line 2: fn f(o: outer) void = { let _ = o.i.x; };
	// On line 2 the literal text after `{ let _ = o.i.x` has `x` at column 36.
	const src =
		"type inner = struct { x: int };\\ntype outer = struct { i: inner };\\nfn f(o: outer) void = { let _ = o.i.x; };\\n";
	nav_open(&s, "file:///sm_chain.ha", src);

	const params =
		`{"textDocument":{"uri":"file:///sm_chain.ha"},"position":{"line":2,"character":36}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 605.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 605.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "(field)"));
	assert(strings::contains(value, "int"));
};

@test fn definition_on_struct_member_cross_file() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// Struct lives in a workspace file on disk; caller is the open doc.
	// We can't compare URIs directly (the workspace_index stores the
	// canonical file:// URI for the on-disk path), so just assert it
	// matches the on-disk file.
	const def_path = ".tmp/hare-lsp-sm-crossfile.ha";
	const def_text = "export type point = struct { x: int };\n";
	let _ = match (nav_write(def_path, def_text)) {
	case bool =>
		yield true;
	case => abort("cannot write fixture");
	};
	defer nav_rm(def_path);
	analysis::index_file(&s.workspace_index, def_path, strings::toutf8(def_text));

	// Line 0: "fn f(p: point) void = { let _ = p.x; };"
	// `x` at column 34.
	nav_open(&s,
		"file:///sm_caller.ha", "fn f(p: point) void = { let _ = p.x; };\\n");

	const params =
		`{"textDocument":{"uri":"file:///sm_caller.ha"},"position":{"line":0,"character":34}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 606.0,
		method = strings::dup("textDocument/definition")!,
		params = pv,
	};
	defer free(r.method);
	handle_definition(&s, r);

	const v = skip_to_response(out, 606.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const uri = *(json::get(&result, "uri") as *json::value) as str;
	assert(strings::hassuffix(uri, "hare-lsp-sm-crossfile.ha"));
	const range = *(json::get(&result, "range") as *json::value) as json::object;
	const start = *(json::get(&range, "start") as *json::value) as json::object;
	// The on-disk file's `x` field lives on line 0:
	// "export type point = struct { x: int };" -> col 29.
	assert(*(json::get(&start, "line") as *json::value) as f64 == 0.0);
	assert(*(json::get(&start, "character") as *json::value) as f64 == 29.0);
};
