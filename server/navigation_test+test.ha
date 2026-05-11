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
