// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// e2e check: open a small Hare document and ask for hover on an
// identifier in it. The unit tests cover `handle_hover` directly with a
// synthetic document; this exercises the full sync path (didOpen →
// hover) the way VSCode does, so we catch issues that only manifest
// when the document is sent over the wire.

use encoding::json;
use fmt;
use os;
use strings;

def HOVER_DOC: str =
	`// SPDX-License-Identifier: MPL-2.0
export fn answer() int = 42;

export fn ask() int = answer();
`;

// Hover on `let scan = bufio::newscanner(...)` — no explicit type annotation,
// so the server should infer the type from the callee's return signature.
// Catches the regression where the hover used to read just "let scan", which
// is duplicate of what the user already typed.
@test fn e2e_hover_local_let_infers_call_return_type() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample =
		`use bufio;
use os;
export fn main() void = {
	let scan = bufio::newscanner(os::stdin);
	let _ = scan;
};
`;
	const did_open = build_did_open("file:///infer_call.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Hover on `scan` in `let _ = scan`. Line 4, char 9.
	const hover_req =
		`{"jsonrpc":"2.0","id":500,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///infer_call.ha"},"position":{"line":4,"character":9}}}`;
	send(&s, strings::toutf8(hover_req));

	const body = wait_for_response(&s, 500.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result_obj = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield match (*p) {
		case let o: json::object =>
			yield o;
		case =>
			fmt::fatalf("e2e: hover returned null for inferred-type local. body={}",
				text);
		};
	case void =>
		fmt::fatalf("e2e: hover response missing result: {}", text);
	};
	const contents =
		*(json::get(&result_obj, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;
	// The server should report the inferred type rather than the bare
	// `let scan` form. bufio::newscanner returns `scanner` (unqualified
	// — that's the spelling in the stdlib decl, which is what
	// hare::unparse re-emits).
	assert(
		strings::contains(md, "let scan: scanner"),
		"hover on a `let x = call()` local should render the inferred type"
	);
	// And it should NOT render the source-text fallback when inference
	// succeeded.
	assert(
		!strings::contains(md, "= bufio::newscanner"),
		"inferred type should replace the init-source fallback"
	);
};

// Top-level hover should render the signature only — no `= body`. The
// previous behavior dumped the full unparsed decl including the function
// body, which was useless noise for anything bigger than a one-liner.
@test fn e2e_hover_top_level_strips_body() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample =
		`export fn add(a: int, b: int) int = {
	let result = a + b;
	return result;
};
`;
	const did_open = build_did_open("file:///strip_body.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Hover on `add` in the function declaration. Line 0, char 10.
	const hover_req =
		`{"jsonrpc":"2.0","id":800,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///strip_body.ha"},"position":{"line":0,"character":10}}}`;
	send(&s, strings::toutf8(hover_req));

	const body = wait_for_response(&s, 800.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result_obj =
		*(json::get(&obj, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result_obj, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;

	assert(
		strings::contains(md, "fn add(a: int, b: int) int"),
		"hover must include the function signature"
	);
	assert(
		!strings::contains(md, "return result"),
		"hover must not include the function body"
	);
	assert(
		!strings::contains(md, "let result"),
		"hover must not include the function body"
	);
};

// Same idea for global decls: `let foo: T = init` should hover as `let foo: T`.
@test fn e2e_hover_global_strips_init() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample = `export let buffer_size: size = 12345;
`;
	const did_open = build_did_open("file:///strip_init.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Hover on `buffer_size`. Line 0, char 14.
	const hover_req =
		`{"jsonrpc":"2.0","id":810,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///strip_init.ha"},"position":{"line":0,"character":14}}}`;
	send(&s, strings::toutf8(hover_req));

	const body = wait_for_response(&s, 810.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result_obj =
		*(json::get(&obj, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result_obj, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;

	assert(
		strings::contains(md, "export let buffer_size: size"),
		"hover must render the full decl form (export, name, and type)"
	);
	assert(
		!strings::contains(md, "12345"),
		"hover must not include the initializer value"
	);
};

// Hover on a stdlib symbol that lives under a `+platform` tag directory
// (`os::stdout_file` is in os/+darwin/stdfd.ha on Darwin). The module
// indexer must fold the tag dir into the parent module, otherwise the
// lookup would search under module "+darwin" and miss.
@test fn e2e_hover_on_stdlib_tag_dir_symbol() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample =
		`use os;
export fn main() void = {
	let _ = os::stdout_file;
};
`;
	const did_open = build_did_open("file:///tag_hover.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Hover on `stdout_file` in `os::stdout_file`. Line 2, char 13.
	const hover_req =
		`{"jsonrpc":"2.0","id":600,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///tag_hover.ha"},"position":{"line":2,"character":13}}}`;
	send(&s, strings::toutf8(hover_req));

	const body = wait_for_response(&s, 600.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result_obj = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield match (*p) {
		case let o: json::object =>
			yield o;
		case =>
			fmt::fatalf("e2e: os::stdout_file hover returned null. body={}", text);
		};
	case void =>
		fmt::fatalf("e2e: response missing result: {}", text);
	};
	const contents =
		*(json::get(&result_obj, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;
	// The decl in stdlib is `export let stdout_file: io::file = rt::...;`
	// — the hover renderer strips the initializer, leaving the typed
	// binding. Match that whole form so a regression that returned just
	// `stdout_file` (the bare ident) fails.
	assert(
		strings::contains(md, "export let stdout_file: io::file"),
		"hover should render the typed decl for os::stdout_file"
	);
};

// Goto-definition on the same symbol — exercises the same module lookup
// path via handle_definition, so a fix to module_from_path benefits both.
@test fn e2e_definition_on_stdlib_tag_dir_symbol() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample =
		`use os;
export fn main() void = {
	let _ = os::stdout_file;
};
`;
	const did_open = build_did_open("file:///tag_def.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	const def_req =
		`{"jsonrpc":"2.0","id":700,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///tag_def.ha"},"position":{"line":2,"character":13}}}`;
	send(&s, strings::toutf8(def_req));

	const body = wait_for_response(&s, 700.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield *p;
	case void =>
		fmt::fatalf("e2e: definition response missing result: {}", text);
	};
	// Extract the (first) Location and verify its URI points into the
	// stdlib's os module under a platform tag dir (os/+darwin, os/+linux,
	// etc.) at stdfd.ha. Just asserting non-empty would pass even if the
	// server returned a Location pointing at the use site or a wrong file.
	const loc = match (result) {
	case let o: json::object =>
		yield o;
	case let arr: []json::value =>
		assert(len(arr) > 0, "definition should return at least one location");
		yield arr[0] as json::object;
	case =>
		fmt::fatalf("e2e: definition returned null for os::stdout_file. body={}",
			text);
	};
	const uri_str = *(json::get(&loc, "uri") as *json::value) as str;
	assert(
		strings::contains(uri_str, "/os/+") &&
		strings::hassuffix(uri_str, "/stdfd.ha"),
		"definition should resolve to os/<platform-tag>/stdfd.ha"
	);
};

// Hover on a stdlib-qualified call (`bufio::newscanner`). The server lazily
// indexes the imported module from $HAREPATH / default install paths.
@test fn e2e_hover_on_stdlib_qualified_call() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample =
		`use bufio;
export fn main() void = {
	let _ = bufio::newscanner;
};
`;
	const did_open = build_did_open("file:///stdlib_hover.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Hover on `newscanner` in `bufio::newscanner`. Line 2, char 17.
	const hover_req =
		`{"jsonrpc":"2.0","id":400,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///stdlib_hover.ha"},"position":{"line":2,"character":17}}}`;
	send(&s, strings::toutf8(hover_req));

	const body = wait_for_response(&s, 400.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield *p;
	case void =>
		fmt::fatalf("e2e: stdlib hover missing result: {}", text);
	};
	const result_obj = match (result) {
	case let o: json::object =>
		yield o;
	case =>
		fmt::fatalf(
			"e2e: stdlib hover returned null — bufio::newscanner unresolved. body={}",
			text);
	};
	const contents =
		*(json::get(&result_obj, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;
	// Stdlib indexing should yield the rendered signature, not just the
	// bare identifier. Pin the function prototype with its return type so
	// a regression to "value contains the name" fails.
	assert(
		strings::contains(md, "fn newscanner("),
		"hover should render the function signature opening"
	);
	assert(
		strings::contains(md, ") scanner"),
		"hover should render the return type after the parameter list"
	);
};

// Hover on a local `let` binding inside a function body. Before this was
// supported, the handler only looked at top-level decls and returned null.
// e2e check for struct-member hover. Two things that previously failed:
//  1. Multi-rune field names like `data` — the matching used `loc.end.off`
//     directly (which is the start of the LAST RUNE, not the start of the
//     name), so ASCII single-character fields happened to work and longer
//     names didn't.
//  2. Member access nested inside the `free()` builtin — parsed as an
//     ast::free_expr, not ast::call_expr, which the AST walker silently
//     skipped over.
@test fn e2e_hover_on_struct_member_inside_free_builtin() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample =
		`type buffer = struct {
	data: []u8,
};

export fn finish(b: *buffer) void = {
	free(b.data);
};
`;
	const did_open = build_did_open("file:///sm_free_e2e.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Hover on `data` inside `free(b.data)`. Line 5 (0-indexed):
	// "\tfree(b.data);" — col 8 = 'd', col 9 = 'a', col 11 = 'a' (last rune).
	// Test col 11 specifically to lock in the last-rune behavior.
	const hover_req =
		`{"jsonrpc":"2.0","id":800,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///sm_free_e2e.ha"},"position":{"line":5,"character":11}}}`;
	send(&s, strings::toutf8(hover_req));

	const body = wait_for_response(&s, 800.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield *p;
	case void =>
		fmt::fatalf("e2e: struct-member hover missing result: {}", text);
	};
	const result_obj = match (result) {
	case let o: json::object =>
		yield o;
	case =>
		fmt::fatalf("e2e: struct-member hover returned null inside free(). body={}",
			text);
	};
	const contents =
		*(json::get(&result_obj, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;
	assert(
		strings::contains(md, "(field) data"),
		"hover inside free() should render `(field) data`"
	);
	assert(
		strings::contains(md, "[]u8"),
		"hover inside free() should render the field's type"
	);
};

@test fn e2e_hover_on_local_let_binding() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample =
		`export fn main() void = {
	let scan: int = 42;
	let _ = scan;
};
`;
	const did_open = build_did_open("file:///local_hover.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Hover on `scan` in `let _ = scan`. Line 2 (0-indexed), char 9.
	const hover_req =
		`{"jsonrpc":"2.0","id":200,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///local_hover.ha"},"position":{"line":2,"character":9}}}`;
	send(&s, strings::toutf8(hover_req));

	const body = wait_for_response(&s, 200.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield *p;
	case void =>
		fmt::fatalf("e2e: local hover response missing result: {}", text);
	};
	const result_obj = match (result) {
	case let o: json::object =>
		yield o;
	case =>
		fmt::fatalf("e2e: local hover returned null. body={}", text);
	};
	const contents =
		*(json::get(&result_obj, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;
	assert(
		strings::contains(md, "let scan"),
		"hover on local should render `let scan` binding"
	);
	assert(
		strings::contains(md, "int"),
		"hover on local should render the binding's type"
	);
};

// Hover on a function parameter — same mechanism as local bindings but the
// scope is the function's prototype, not its body.
@test fn e2e_hover_on_function_parameter() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample = `export fn echo(n: int) int = {
	return n;
};
`;
	const did_open = build_did_open("file:///param_hover.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Hover on `n` in `return n`. Line 1, char 8.
	const hover_req =
		`{"jsonrpc":"2.0","id":300,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///param_hover.ha"},"position":{"line":1,"character":8}}}`;
	send(&s, strings::toutf8(hover_req));

	const body = wait_for_response(&s, 300.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = *(json::get(&obj, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;
	assert(
		strings::contains(md, "(parameter) n: int"),
		"hover on a function parameter should render `(parameter) <name>: <type>`"
	);
};

// Reproduces the call-site hover scenario the user reported: hovering on a
// qualified workspace identifier (e.g. `server::new`). The `server` module is
// in this workspace, so the server should resolve it via the workspace
// index. The unit tests only cover unqualified top-level decls in the
// current file, so this fills a gap.
@test fn e2e_hover_on_qualified_workspace_call() void = {
	let s = spawn_session();
	defer finish_session(&s);

	// rootUri matters: workspace indexing scans this folder so qualified
	// lookups resolve.
	const init_msg =
		strings::concat(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":"file://`,
			os_repo_root(), `","workspaceFolders":[{"uri":"file://`, os_repo_root(),
			`","name":"hare-lsp"}],"capabilities":{}}}`)!;
	defer free(init_msg);
	send(&s, strings::toutf8(init_msg));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	// Open a small file that mirrors the user's actual main.ha shape.
	const sample =
		`use server;
export fn main() void = {
	let _ = server::run;
};
`;
	const did_open = build_did_open("file:///probe_main.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Wait for indexing to settle — `initialized` triggers a workspace
	// scan and the server emits a log notification when done. We pull
	// a few messages so the index is populated before we ask for hover.
	drain_until_indexed(&s);

	// Hover on `run` in `server::run`. Line 2 (0-indexed), `server::run`
	// starts at column 9 ("let _ = "), so `run` starts at column 17.
	const hover_req =
		`{"jsonrpc":"2.0","id":100,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///probe_main.ha"},"position":{"line":2,"character":17}}}`;
	send(&s, strings::toutf8(hover_req));

	const body = wait_for_response(&s, 100.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield *p;
	case void =>
		fmt::fatalf("e2e: hover response has no result: {}", text);
	};
	const result_obj = match (result) {
	case let o: json::object =>
		yield o;
	case =>
		fmt::fatalf(
			"e2e: hover on `server::run` returned null — workspace-qualified hover broken. body={}",
			text);
	};
	// Just confirming the result is an object isn't enough — the bug this
	// test reproduces was about the workspace index resolving to *some*
	// symbol; assert that the rendered hover is actually `server::run`'s
	// signature (declared as `export fn run(s: *server) int` in
	// server/server.ha). A regression that returned a wrong symbol or
	// dropped the signature would still pass an object-shape check.
	const contents =
		*(json::get(&result_obj, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;
	assert(
		strings::contains(md, "fn run(s: *server) int"),
		"hover on `server::run` should render the function's signature"
	);
};

// Waits for the "indexed N file(s)" log to arrive so the workspace index
// is populated before the caller queries it. Fails loudly on timeout so
// an indexing regression manifests as a clear error rather than a
// downstream null-hover failure that's hard to attribute.
fn drain_until_indexed(s: *session) void = {
	for (let i = 0z; i < 20z; i += 1) {
		const body = recv(s);
		defer free(body);
		const text = strings::fromutf8(body)!;
		if (strings::contains(text, "indexed") &&
				strings::contains(text, "file(s)")) return;
	};
	fmt::fatalf(
		"e2e: workspace indexing did not complete within 20 messages — `initialized` should trigger a scan and the server should log `indexed N file(s)`"
	);
};

fn os_repo_root() str = {
	// Tests run with cwd at the repo root (driven by the Makefile);
	// take it from the live cwd so the test works on any checkout
	// (CI, contributor machines, etc.) without hardcoding a path.
	return os::getcwd();
};

@test fn e2e_hover_on_identifier() void = {
	let s = spawn_session();
	defer finish_session(&s);

	// Initialize. We need to be ready before opening docs.
	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	// didOpen.
	const did_open = build_did_open("file:///hover_test.ha", HOVER_DOC);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Hover on `answer` in the call `answer()` on line 3 (0-indexed),
	// which is `export fn ask() int = answer();`. The call's `answer`
	// starts at column 23.
	const hover_req =
		`{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///hover_test.ha"},"position":{"line":3,"character":24}}}`;
	send(&s, strings::toutf8(hover_req));

	const body = wait_for_response(&s, 2.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);

	const obj = v as json::object;
	const result = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield *p;
	case void =>
		fmt::fatalf("e2e: hover response has no result field: {}", text);
	};
	// LSP allows null when nothing matches. Surface that as a clear
	// failure so the developer can compare against what VSCode receives.
	const result_obj = match (result) {
	case let o: json::object =>
		yield o;
	case =>
		fmt::fatalf(
			"e2e: hover returned null/non-object — server didn't recognize the identifier. Body: {}",
			text);
	};
	const contents = match (json::get(&result_obj, "contents")) {
	case let p: *json::value =>
		yield *p;
	case void =>
		fmt::fatalf("e2e: hover result missing contents: {}", text);
	};
	const c_obj = contents as json::object;
	match (json::get(&c_obj, "value")) {
	case let p: *json::value =>
		const md = *p as str;
		assert(
			strings::contains(md, "answer"),
			"hover markdown should mention the identifier name"
		);
	case void =>
		fmt::fatalf("e2e: hover contents missing value: {}", text);
	};
};

// Ownership line: annotated function -> Layer 1 wins, source = annotation.
@test fn e2e_hover_ownership_annotation_owned() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample =
		`// Make a fresh widget.
//
// @returns: owned
export fn make_widget() *int = alloc(0);
`;
	const did_open = build_did_open("file:///own_anno.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Hover on `make_widget` (line 3, char 12 -> on 'a' of make_widget).
	const hover_req =
		`{"jsonrpc":"2.0","id":900,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///own_anno.ha"},"position":{"line":3,"character":14}}}`;
	send(&s, strings::toutf8(hover_req));

	const body = wait_for_response(&s, 900.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result_obj = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield match (*p) {
		case let o: json::object =>
			yield o;
		case =>
			fmt::fatalf("e2e: ownership-annotation hover returned null. body={}", text);
		};
	case void =>
		fmt::fatalf("e2e: ownership hover missing result: {}", text);
	};
	const contents =
		*(json::get(&result_obj, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;
	assert(
		strings::contains(md, "Ownership: owned (annotation)"),
		"hover should include the annotation-sourced ownership line"
	);
};

// Ownership line: local bound to alloc(...) -> Layer 3 heuristic.
@test fn e2e_hover_ownership_local_alloc_heuristic() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample = `export fn use_it() void = {
	let x = alloc(0);
	free(x);
};
`;
	const did_open = build_did_open("file:///own_local.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Hover on `x` in `let x = alloc(0);`. Line 1, char 5 (tab + "let " then 'x').
	const hover_req =
		`{"jsonrpc":"2.0","id":910,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///own_local.ha"},"position":{"line":1,"character":5}}}`;
	send(&s, strings::toutf8(hover_req));

	const body = wait_for_response(&s, 910.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result_obj = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield match (*p) {
		case let o: json::object =>
			yield o;
		case =>
			fmt::fatalf("e2e: ownership-local hover returned null. body={}", text);
		};
	case void =>
		fmt::fatalf("e2e: ownership-local hover missing result: {}", text);
	};
	const contents =
		*(json::get(&result_obj, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;
	assert(
		strings::contains(md, "Ownership: owned"),
		"alloc-initialized local should show owned"
	);
	assert(
		strings::contains(md, "heuristic"),
		"the source layer should be the heuristic walker"
	);
};

// The Ownership line goes BELOW the doc comment, not above it: the doc
// comment is generally more relevant than the ownership label, so it
// should read first.
@test fn e2e_hover_ownership_line_below_doc_comment() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample =
		`// Frobnicates the input thoroughly.
//
// @returns: owned
export fn frobnicate() *int = alloc(0);
`;
	const did_open = build_did_open("file:///own_order.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	const hover_req =
		`{"jsonrpc":"2.0","id":930,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///own_order.ha"},"position":{"line":3,"character":14}}}`;
	send(&s, strings::toutf8(hover_req));

	const body = wait_for_response(&s, 930.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result_obj =
		*(json::get(&obj, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result_obj, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;
	const doc_idx = strings::index(md, "Frobnicates");
	const own_idx = strings::index(md, "Ownership:");
	const di = match (doc_idx) {
	case let i: size =>
		yield i;
	case void =>
		fmt::fatalf("e2e: hover missing doc comment text: {}", text);
	};
	const oi = match (own_idx) {
	case let i: size =>
		yield i;
	case void =>
		fmt::fatalf("e2e: hover missing Ownership line: {}", text);
	};
	assert(di < oi, "doc comment must appear before the Ownership line");
};

// When the client sets `hare.hover.useHtml = false`, the Ownership line
// must NOT be wrapped in `<small>` tags. Non-HTML clients (Neovim,
// Helix, Emacs) opt into this to avoid showing literal tags.
@test fn e2e_hover_ownership_html_disabled() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	// Push the setting to the server.
	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","method":"workspace/didChangeConfiguration","params":{"settings":{"hare":{"hover":{"useHtml":false}}}}}`
		));

	const sample = `// @returns: owned
export fn make_widget() *int = alloc(0);
`;
	const did_open = build_did_open("file:///own_nohtml.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	const hover_req =
		`{"jsonrpc":"2.0","id":940,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///own_nohtml.ha"},"position":{"line":1,"character":14}}}`;
	send(&s, strings::toutf8(hover_req));

	const body = wait_for_response(&s, 940.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result_obj =
		*(json::get(&obj, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result_obj, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;
	assert(
		strings::contains(md, "Ownership: owned (annotation)"),
		"plain Ownership line still shows when HTML is disabled"
	);
	assert(
		!strings::contains(md, "<small>"),
		"hover.useHtml = false must suppress the <small> wrapper"
	);
	assert(
		!strings::contains(md, "</small>"),
		"hover.useHtml = false must suppress the </small> wrapper"
	);
};

// Ownership line: stdlib symbol via the committed Layer-2 lookup table.
// Hovering `strings::dup` should pick up the doc-comment-sourced fact.
@test fn e2e_hover_ownership_stdlib_strings_dup() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample =
		`use strings;
export fn main() void = {
	let _ = strings::dup;
};
`;
	const did_open = build_did_open("file:///own_stdlib.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Hover on `dup` in `strings::dup`. Line 2, char 18.
	const hover_req =
		`{"jsonrpc":"2.0","id":920,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///own_stdlib.ha"},"position":{"line":2,"character":18}}}`;
	send(&s, strings::toutf8(hover_req));

	const body = wait_for_response(&s, 920.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result_obj = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield match (*p) {
		case let o: json::object =>
			yield o;
		case =>
			fmt::fatalf("e2e: stdlib ownership hover returned null. body={}", text);
		};
	case void =>
		fmt::fatalf("e2e: stdlib ownership hover missing result: {}", text);
	};
	const contents =
		*(json::get(&result_obj, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;
	assert(
		strings::contains(md, "Ownership: owned"),
		"strings::dup should be flagged owned via the stdlib table"
	);
	assert(
		strings::contains(md, "doc comment"),
		"source for strings::dup should be the doc-comment table"
	);
};

fn build_did_open(uri: str, body: str) str = {
	// JSON-encode the body. We do it the long way rather than json::dumpstr
	// to keep this test light — the body has no embedded quotes or
	// backslashes.
	let result =
		strings::concat(
			`{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"`,
			uri, `","languageId":"hare","version":1,"text":`, json_string_quote(body),
			`}}}`)!;
	return result;
};

fn json_string_quote(s: str) str = {
	// Minimal JSON string encoder for ASCII printable + common whitespace.
	const bytes = strings::toutf8(s);
	let out: []u8 = [];
	append(out, '"': u8)!;
	for (let i = 0z; i < len(bytes); i += 1) {
		const b = bytes[i];
		switch (b) {
		case '"': u8 =>
			append(out, '\\': u8)!;
			append(out, '"': u8)!;
		case '\\': u8 =>
			append(out, '\\': u8)!;
			append(out, '\\': u8)!;
		case '\n': u8 =>
			append(out, '\\': u8)!;
			append(out, 'n': u8)!;
		case '\r': u8 =>
			append(out, '\\': u8)!;
			append(out, 'r': u8)!;
		case '\t': u8 =>
			append(out, '\\': u8)!;
			append(out, 't': u8)!;
		case =>
			append(out, b)!;
		};
	};
	append(out, '"': u8)!;
	return strings::fromutf8(out)!;
};
