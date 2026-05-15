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

@test fn hover_on_struct_member_through_index() void = {
	// Receiver is an indexed slice: `xs[i].name`.
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// Line 0: type entry = struct { name: str };
	// Line 1: fn f(xs: []entry, i: size) void = { let _ = xs[i].name; };
	const src =
		"type entry = struct { name: str };\\nfn f(xs: []entry, i: size) void = { let _ = xs[i].name; };\\n";
	nav_open(&s, "file:///sm_index.ha", src);

	// `name` of `xs[i].name` starts at col 50 of line 1; cursor at 52 (`m`).
	const params =
		`{"textDocument":{"uri":"file:///sm_index.ha"},"position":{"line":1,"character":52}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 625.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 625.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "(field) name"));
	assert(strings::contains(value, "str"));
};

@test fn hover_on_struct_member_through_deref() void = {
	// Receiver is a manual dereference: `(*p).name`.
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src =
		"type entry = struct { name: str };\\nfn f(p: *entry) void = { let _ = (*p).name; };\\n";
	nav_open(&s, "file:///sm_deref.ha", src);

	// `(*p).name` — find `name`. Source layout of line 1 after `let _ = `:
	// fn f(p: *entry) void = { let _ = (*p).name; };
	// 0         1         2         3         4
	// 01234567890123456789012345678901234567890123456789
	// `name` starts at col 38; cursor at 40 (`m`).
	const params =
		`{"textDocument":{"uri":"file:///sm_deref.ha"},"position":{"line":1,"character":40}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 626.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 626.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "(field) name"));
	assert(strings::contains(value, "str"));
};

@test fn hover_on_multi_rune_struct_member_shows_field_type() void = {
	// Regression: `loc.end.off` from `hare::lex::prevloc` is the start of
	// the LAST rune of the last consumed token, not the start of that
	// token. Earlier tests used single-character field names like `x`,
	// where start-of-last-rune == start-of-name, so they masked the bug.
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// Line 0: type buffer = struct { data: []u8 };
	// Line 1: fn f(b: *buffer) void = { free(b.data); };
	// `data` in `b.data` starts at column 33 of line 1; cursor on the
	// trailing 'a' (column 36) is the start of the LAST rune of the
	// field name, which is what hare::lex::prevloc reports as
	// `loc.end.off`. Locking in that exact column is the regression
	// guard.
	const src =
		"type buffer = struct { data: []u8 };\\nfn f(b: *buffer) void = { free(b.data); };\\n";
	nav_open(&s, "file:///sm_multirune.ha", src);

	const params =
		`{"textDocument":{"uri":"file:///sm_multirune.ha"},"position":{"line":1,"character":36}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 620.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 620.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "(field) data"));
	assert(strings::contains(value, "[]u8"));
};

@test fn hover_on_member_inside_free_builtin() void = {
	// Regression: `free(...)` is parsed as ast::free_expr, not call_expr.
	// The pre-fix `scan_expr_for_field` had no case for free_expr and
	// silently returned void for any member access nested inside it.
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const src =
		"type buffer = struct { data: []u8 };\\nfn f(b: *buffer) void = { free(b.data); };\\n";
	nav_open(&s, "file:///sm_free.ha", src);

	// `data` spans columns 33..37 (half-open) on line 1; cursor at 35
	// lands on `t` inside the field name.
	const params =
		`{"textDocument":{"uri":"file:///sm_free.ha"},"position":{"line":1,"character":35}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 621.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 621.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "(field) data"));
};

@test fn hover_on_member_inside_len_builtin() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// `len(b.items)` — len() is parsed as ast::len_expr.
	const src =
		"type list = struct { items: []int };\\nfn f(b: list) size = len(b.items);\\n";
	nav_open(&s, "file:///sm_len.ha", src);

	// `items` spans columns 27..32 (half-open) on line 1; cursor at 30
	// lands on `m` inside the field name.
	const params =
		`{"textDocument":{"uri":"file:///sm_len.ha"},"position":{"line":1,"character":30}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 622.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 622.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "(field) items"));
	assert(strings::contains(value, "[]int"));
};

@test fn hover_on_member_inside_append_builtin() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// `append(b.items, 1)!` — append is parsed as ast::append_expr.
	const src =
		"type list = struct { items: []int };\\nfn f(b: *list) void = { append(b.items, 1)!; };\\n";
	nav_open(&s, "file:///sm_append.ha", src);

	// `items` of `b.items` spans columns 33..38 of line 1; cursor on 'e' (col 35).
	const params =
		`{"textDocument":{"uri":"file:///sm_append.ha"},"position":{"line":1,"character":35}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 623.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 623.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "(field) items"));
};

@test fn hover_on_member_inside_alloc_builtin() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// `alloc(b.value)` — alloc is parsed as ast::alloc_expr.
	const src =
		"type box = struct { value: int };\\nfn f(b: box) *int = alloc(b.value)!;\\n";
	nav_open(&s, "file:///sm_alloc.ha", src);

	// `value` of `b.value` starts at col 28 of line 1.
	const params =
		`{"textDocument":{"uri":"file:///sm_alloc.ha"},"position":{"line":1,"character":30}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 624.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 624.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "(field) value"));
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
	nav_open(&s, "file:///sm_caller.ha",
		"fn f(p: point) void = { let _ = p.x; };\\n");

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
