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

fn nav_test_server() (server, *bufio::scanner, *memio::stream, *memio::stream) = {
	let in_buf = alloc(memio::fixed([]))!;
	let scan = alloc(bufio::newscanner(in_buf))!;
	let out = alloc(memio::dynamic())!;
	let s = new(scan, out);
	return (s, scan, in_buf, out);
};

fn nav_test_cleanup(s: *server, scan: *bufio::scanner, in_buf: *memio::stream, out: *memio::stream) void = {
	finish(s);
	bufio::finish(scan);
	free(scan);
	free(in_buf);
	io::close(out)!;
	free(out);
};

fn nav_open(s: *server, uri: str, text: str) void = {
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

fn skip_to_response(out: *memio::stream, request_id: f64) json::value = {
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

@test fn hover_returns_signature_for_function() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///x.ha", "export fn target() void = void;\\n");

	// Position is on "target" — line 0, char ~12.
	const params = `{"textDocument":{"uri":"file:///x.ha"},"position":{"line":0,"character":12}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 100.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 100.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value) as json::object;
	const contents = *(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "target"));
	assert(strings::contains(value, "fn"));
};

@test fn hover_on_whitespace_returns_null() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///x.ha", "export fn target() void = void;\\n");

	const params = `{"textDocument":{"uri":"file:///x.ha"},"position":{"line":0,"character":6}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 101.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 101.0);
	defer json::finish(v);
	const o = v as json::object;
	const result = *(json::get(&o, "result") as *json::value);
	assert(result is json::_null);
};

@test fn definition_returns_location_for_local_decl() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///x.ha", "export fn target() void = void;\\n");

	const params = `{"textDocument":{"uri":"file:///x.ha"},"position":{"line":0,"character":12}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 200.0,
		method = strings::dup("textDocument/definition")!,
		params = pv,
	};
	defer free(r.method);
	handle_definition(&s, r);

	const v = skip_to_response(out, 200.0);
	defer json::finish(v);
	const result = *(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const uri = *(json::get(&result, "uri") as *json::value) as str;
	assert(uri == "file:///x.ha");
	const range = *(json::get(&result, "range") as *json::value) as json::object;
	const start = *(json::get(&range, "start") as *json::value) as json::object;
	assert(*(json::get(&start, "line") as *json::value) as f64 == 0.0);
};

@test fn type_definition_returns_location_for_type_only() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///x.ha", "type point = struct { x: int };\\nexport fn f() void = void;\\n");

	// Hover on "point" — line 0, char 5.
	const params = `{"textDocument":{"uri":"file:///x.ha"},"position":{"line":0,"character":6}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 300.0,
		method = strings::dup("textDocument/typeDefinition")!,
		params = pv,
	};
	defer free(r.method);
	handle_type_definition(&s, r);

	const v = skip_to_response(out, 300.0);
	defer json::finish(v);
	const result = *(json::get(&(v as json::object), "result") as *json::value);
	// Should be a Location.
	assert(result is json::object);
};

@test fn type_definition_on_function_returns_null() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///x.ha", "export fn f() void = void;\\n");

	const params = `{"textDocument":{"uri":"file:///x.ha"},"position":{"line":0,"character":11}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 301.0,
		method = strings::dup("textDocument/typeDefinition")!,
		params = pv,
	};
	defer free(r.method);
	handle_type_definition(&s, r);

	const v = skip_to_response(out, 301.0);
	defer json::finish(v);
	const result = *(json::get(&(v as json::object), "result") as *json::value);
	assert(result is json::_null);
};

@test fn definition_falls_back_to_workspace_index_for_cross_file() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// Put a "defines fn target" fixture on disk and index it.
	const def_path = ".tmp/hare-lsp-nav-crossfile.ha";
	const def_text = "export fn target() void = void;\n";
	let _ = match (nav_write(def_path, def_text)) {
	case bool => yield true;
	case => abort("cannot write fixture");
	};
	defer nav_rm(def_path);
	analysis::index_file(&s.workspace_index, def_path,
		strings::toutf8(def_text));

	// Open a separate buffer that calls `target()` — its file-local
	// index doesn't know about `target`.
	nav_open(&s, "file:///caller.ha",
		"fn caller() void = target();\\n");

	// Cursor on `target` in caller.ha.
	const params = `{"textDocument":{"uri":"file:///caller.ha"},"position":{"line":0,"character":22}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 400.0,
		method = strings::dup("textDocument/definition")!,
		params = pv,
	};
	defer free(r.method);
	handle_definition(&s, r);

	const v = skip_to_response(out, 400.0);
	defer json::finish(v);
	const result = *(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const uri = *(json::get(&result, "uri") as *json::value) as str;
	// Should point at the on-disk file, not caller.ha.
	assert(strings::hassuffix(uri, "hare-lsp-nav-crossfile.ha"));
};

@test fn hover_falls_back_to_workspace_index_for_cross_file() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const def_path = ".tmp/hare-lsp-nav-hover-crossfile.ha";
	const def_text = "// the answer\nexport fn answer() int = 42;\n";
	let _ = match (nav_write(def_path, def_text)) {
	case bool => yield true;
	case => abort("cannot write fixture");
	};
	defer nav_rm(def_path);
	analysis::index_file(&s.workspace_index, def_path,
		strings::toutf8(def_text));

	nav_open(&s, "file:///caller.ha",
		"fn caller() void = { let n = answer(); };\\n");

	// Position on `answer` — char index roughly 29.
	const params = `{"textDocument":{"uri":"file:///caller.ha"},"position":{"line":0,"character":31}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 401.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 401.0);
	defer json::finish(v);
	const result = *(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents = *(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	// Hover markdown should contain the cross-file decl signature.
	assert(strings::contains(value, "answer"));
};

@test fn hover_on_let_binding_with_propagate_strips_error_variants() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const def_path = ".tmp/hare-lsp-nav-hover-propagate.ha";
	const def_text = "export type myerr = !void;\nexport fn want() (int | myerr) = 0;\n";
	let _ = match (nav_write(def_path, def_text)) {
	case bool => yield true;
	case => abort("cannot write fixture");
	};
	defer nav_rm(def_path);
	analysis::index_file(&s.workspace_index, def_path,
		strings::toutf8(def_text));

	// `let t = want()?;` — hover on `t` (line 0, char 25).
	nav_open(&s, "file:///caller_prop.ha",
		"fn caller() void = { let t = want()?; };\\n");

	const params = `{"textDocument":{"uri":"file:///caller_prop.ha"},"position":{"line":0,"character":25}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 460.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 460.0);
	defer json::finish(v);
	const result = *(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents = *(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	// After `?`, the result should be just `int` — the alias `myerr`
	// resolves to `!void`, so its variant is stripped from the union.
	assert(strings::contains(value, "let t"));
	assert(strings::contains(value, "int"));
	assert(!strings::contains(value, "myerr"));
	assert(!strings::contains(value, "want()"));
};

@test fn hover_on_let_binding_with_error_assert_strips_error_variants() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const def_path = ".tmp/hare-lsp-nav-hover-bang.ha";
	const def_text = "export type myerr = !void;\nexport fn want() (int | myerr) = 0;\n";
	let _ = match (nav_write(def_path, def_text)) {
	case bool => yield true;
	case => abort("cannot write fixture");
	};
	defer nav_rm(def_path);
	analysis::index_file(&s.workspace_index, def_path,
		strings::toutf8(def_text));

	// `let t = want()!;` — hover on `t` (line 0, char 25).
	nav_open(&s, "file:///caller_bang.ha",
		"fn caller() void = { let t = want()!; };\\n");

	const params = `{"textDocument":{"uri":"file:///caller_bang.ha"},"position":{"line":0,"character":25}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 461.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 461.0);
	defer json::finish(v);
	const result = *(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents = *(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "let t"));
	assert(strings::contains(value, "int"));
	assert(!strings::contains(value, "myerr"));
	assert(!strings::contains(value, "want()"));
};

@test fn definition_disambiguates_by_imported_module() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// Two modules both declare `init`. We want imports of mod_a to win.
	const path_a = ".tmp/lspmoda/init.ha";
	const path_b = ".tmp/lspmodb/init.ha";
	const text = "export fn init() void = void;\n";
	nav_write_dir(".tmp/lspmoda");
	nav_write_dir(".tmp/lspmodb");
	let _ = match (nav_write(path_a, text)) {
	case bool => yield true;
	case => abort("cannot write");
	};
	let _ = match (nav_write(path_b, text)) {
	case bool => yield true;
	case => abort("cannot write");
	};
	defer nav_rm(path_a);
	defer nav_rm(path_b);
	analysis::index_file(&s.workspace_index, path_a, strings::toutf8(text));
	analysis::index_file(&s.workspace_index, path_b, strings::toutf8(text));

	// caller.ha imports lspmoda only.
	nav_open(&s, "file:///caller.ha",
		"use lspmoda;\\n\\nfn caller() void = init();\\n");

	// Position on `init` in caller.ha.
	const params = `{"textDocument":{"uri":"file:///caller.ha"},"position":{"line":2,"character":21}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 450.0,
		method = strings::dup("textDocument/definition")!,
		params = pv,
	};
	defer free(r.method);
	handle_definition(&s, r);

	const v = skip_to_response(out, 450.0);
	defer json::finish(v);
	const result = *(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const uri = *(json::get(&result, "uri") as *json::value) as str;
	// Should resolve to mod-a, not mod-b.
	assert(strings::contains(uri, "lspmoda"));
	assert(!strings::contains(uri, "lspmodb"));
};

@test fn definition_resolves_qualified_reference() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	const path_a = ".tmp/lspmodc/init.ha";
	const path_b = ".tmp/lspmodd/init.ha";
	const text = "export fn init() void = void;\n";
	nav_write_dir(".tmp/lspmodc");
	nav_write_dir(".tmp/lspmodd");
	let _ = match (nav_write(path_a, text)) {
	case bool => yield true;
	case => abort("cannot write");
	};
	let _ = match (nav_write(path_b, text)) {
	case bool => yield true;
	case => abort("cannot write");
	};
	defer nav_rm(path_a);
	defer nav_rm(path_b);
	analysis::index_file(&s.workspace_index, path_a, strings::toutf8(text));
	analysis::index_file(&s.workspace_index, path_b, strings::toutf8(text));

	// caller writes `lspmodd::init()` — a qualified reference.
	// Despite lspmodc also having `init`, the qualifier must win.
	nav_open(&s, "file:///caller2.ha",
		"fn caller() void = lspmodd::init();\\n");

	// Position on `init` in caller2.ha — right after `::`.
	// "fn caller() void = lspmodd::init();" — `init` is cols 28-31.
	const params = `{"textDocument":{"uri":"file:///caller2.ha"},"position":{"line":0,"character":30}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 451.0,
		method = strings::dup("textDocument/definition")!,
		params = pv,
	};
	defer free(r.method);
	handle_definition(&s, r);

	const v = skip_to_response(out, 451.0);
	defer json::finish(v);
	const result = *(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const uri = *(json::get(&result, "uri") as *json::value) as str;
	assert(strings::contains(uri, "lspmodd"));
};

@test fn hover_on_type_reference_shows_doc_comment() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// `build_diagnostic` is declared with a doc comment, then referenced
	// in another decl as `d: build_diagnostic`. Hovering on the reference
	// should show the type's doc comment, not just the signature.
	const src = "// One diagnostic emitted by the compiler.\\nexport type build_diagnostic = struct { x: int };\\nfn f(d: build_diagnostic) void = void;\\n";
	nav_open(&s, "file:///bd.ha", src);

	// Line 2 is `fn f(d: build_diagnostic) void = void;`. The token
	// `build_diagnostic` starts at column 8.
	const params = `{"textDocument":{"uri":"file:///bd.ha"},"position":{"line":2,"character":12}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 470.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 470.0);
	defer json::finish(v);
	const result = *(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents = *(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "build_diagnostic"));
	assert(strings::contains(value, "One diagnostic emitted by the compiler."));
};

@test fn hover_doc_comment_renders_resolved_ref_as_command_link() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// `target` references `[[helper]]` in its doc comment. Both decls
	// live in the same file, so resolution should hit the local index
	// and emit a markdown link with a `command:hare-lsp.openLocation` URI.
	const src = "// See [[helper]] for the implementation.\\nexport fn target() void = void;\\nexport fn helper() void = void;\\n";
	nav_open(&s, "file:///r.ha", src);

	const params = `{"textDocument":{"uri":"file:///r.ha"},"position":{"line":1,"character":12}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 480.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 480.0);
	defer json::finish(v);
	const result = *(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents = *(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "[helper](command:hare-lsp.openLocation?"));
	// The link's URI argument should encode the open document's URI.
	assert(strings::contains(value, "file%3A%2F%2F%2Fr.ha"));
};

@test fn hover_doc_comment_renders_unresolved_ref_as_code() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// `nowhere` is not declared anywhere; the ref should fall back to
	// inline code rather than a broken link.
	const src = "// See [[nowhere]] for details.\\nexport fn target() void = void;\\n";
	nav_open(&s, "file:///u.ha", src);

	const params = `{"textDocument":{"uri":"file:///u.ha"},"position":{"line":1,"character":12}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 481.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 481.0);
	defer json::finish(v);
	const result = *(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents = *(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "`nowhere`"));
	assert(!strings::contains(value, "command:"));
};

@test fn hover_const_match_init_uses_yielded_case_type() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// Mirrors `const c1 = match (...) { case let i: size => yield i;
	// case => return void; };`. Only the size case yields a value; the
	// default diverges, so the inferred type is just `size`.
	const src = "fn caller() void = { const c1 = match (2z: (size | void)) { case let i: size => yield i; case => return; }; };\\n";
	nav_open(&s, "file:///mb.ha", src);

	// Position on `c1` (line 0, column 27 -> just after "const ").
	const params = `{"textDocument":{"uri":"file:///mb.ha"},"position":{"line":0,"character":28}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 490.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 490.0);
	defer json::finish(v);
	const result = *(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents = *(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "const c1"));
	assert(strings::contains(value, ": size"));
	// The diverging default case must not contribute `void` to the type.
	assert(!strings::contains(value, "size | void"));
	// The init source must NOT be echoed when the type was successfully
	// inferred — we want a clean "const c1: size", not "const c1 = match ...".
	assert(!strings::contains(value, "match"));
};

@test fn hover_const_match_init_unions_multiple_yields() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// Two cases each yield a different type. Result should be the union.
	const src = "fn caller() void = { const c2 = match (2z: (size | void)) { case let i: size => yield i; case => yield 0; }; };\\n";
	nav_open(&s, "file:///mu.ha", src);

	const params = `{"textDocument":{"uri":"file:///mu.ha"},"position":{"line":0,"character":28}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 491.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 491.0);
	defer json::finish(v);
	const result = *(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents = *(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "const c2"));
	assert(strings::contains(value, "size"));
	assert(strings::contains(value, "int"));
	// Either order is fine, but it must look like a union.
	assert(strings::contains(value, "|"));
};

@test fn hover_on_use_module_shows_readme() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// `bufio` is a stdlib module with a README at
	// /usr/local/src/hare/stdlib/bufio/README. Hovering on the module
	// name in a `use` statement should show its contents.
	nav_open(&s, "file:///mb1.ha", "use bufio;\\nfn f() void = void;\\n");

	const params = `{"textDocument":{"uri":"file:///mb1.ha"},"position":{"line":0,"character":6}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 500.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 500.0);
	defer json::finish(v);
	const result = *(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents = *(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "module bufio"));
	// The README starts with "bufio: buffered I/O primitives" — assert
	// the descriptive text from the actual file is present.
	assert(strings::contains(value, "buffered I/O primitives"));
};

@test fn hover_on_double_colon_acts_like_first_segment() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// `use unix::poll;` — hovering on the `::` should resolve to
	// `unix` (the first segment), not `unix::poll`.
	nav_open(&s, "file:///mb2.ha",
		"use unix::poll;\\nfn f() void = void;\\n");

	// "use unix::poll;" — `::` is at columns 8-9.
	const params = `{"textDocument":{"uri":"file:///mb2.ha"},"position":{"line":0,"character":8}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 501.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 501.0);
	defer json::finish(v);
	const result = *(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents = *(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	// Header should be `module unix`, NOT `module unix::poll`.
	assert(strings::contains(value, "module unix\n"));
	assert(!strings::contains(value, "module unix::poll"));
};

@test fn hover_on_second_segment_resolves_full_path() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// `use unix::poll;` — hovering on `poll` should resolve to
	// `unix::poll`, not just `unix`.
	nav_open(&s, "file:///mb4.ha",
		"use unix::poll;\\nfn f() void = void;\\n");

	// "use unix::poll;" — `poll` starts at column 10.
	const params = `{"textDocument":{"uri":"file:///mb4.ha"},"position":{"line":0,"character":11}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 503.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 503.0);
	defer json::finish(v);
	const result = *(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents = *(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "module unix::poll"));
};

@test fn hover_on_qualifier_in_code_shows_module_readme() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// In `bufio::newscanner(...)`, hovering on `bufio` should show the
	// bufio README, not fall through to a (missing) decl lookup.
	nav_open(&s, "file:///mb3.ha",
		"use bufio;\\nfn f() void = { bufio::newscanner(0); };\\n");

	// Position on the second `bufio` (in the body, line 1).
	// Source: "fn f() void = { bufio::newscanner(0); };"
	//                          ^ char ~16
	const params = `{"textDocument":{"uri":"file:///mb3.ha"},"position":{"line":1,"character":18}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 502.0,
		method = strings::dup("textDocument/hover")!,
		params = pv,
	};
	defer free(r.method);
	handle_hover(&s, r);

	const v = skip_to_response(out, 502.0);
	defer json::finish(v);
	const result = *(json::get(&(v as json::object), "result") as *json::value) as json::object;
	const contents = *(json::get(&result, "contents") as *json::value) as json::object;
	const value = *(json::get(&contents, "value") as *json::value) as str;
	assert(strings::contains(value, "module bufio"));
	assert(strings::contains(value, "buffered I/O"));
};

// --- fixture helpers ---

fn nav_write(path: str, text: str) (bool | fs::error) = {
	const f = os::create(path, 0o644)?;
	defer io::close(f)!;
	io::writeall(f, strings::toutf8(text))!;
	return true;
};

fn nav_write_dir(path: str) void = {
	match (os::mkdir(path, 0o755)) {
	case => void;
	};
};

fn nav_rm(path: str) void = {
	match (os::remove(path)) {
	case => void;
	};
};
