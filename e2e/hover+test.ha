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

	send(
		&s,
		strings::toutf8(

			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`,
		),
	);
	free(wait_for_response(&s, 1.0));
	send(
		&s, strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`),
	);

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
			fmt::fatalf(
				"e2e: hover returned null for inferred-type local. body={}", text,
			);
		};
	case void =>
		fmt::fatalf("e2e: hover response missing result: {}", text);
	};
	const contents =
		*(json::get(&result_obj, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;
	// The server should report the inferred type rather than the bare
	// `let scan` form. bufio::newscanner returns bufio::scanner.
	assert(
		strings::contains(md, "scanner"),
		"hover on a `let x = call()` local should infer the call's return type"
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

	send(
		&s,
		strings::toutf8(

			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`,
		),
	);
	free(wait_for_response(&s, 1.0));
	send(
		&s, strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`),
	);

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

	send(
		&s,
		strings::toutf8(

			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`,
		),
	);
	free(wait_for_response(&s, 1.0));
	send(
		&s, strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`),
	);

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
		strings::contains(md, "buffer_size") && strings::contains(md, "size"),
		"hover must include the global's name and type"
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

	send(
		&s,
		strings::toutf8(

			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`,
		),
	);
	free(wait_for_response(&s, 1.0));
	send(
		&s, strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`),
	);

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
	assert(
		strings::contains(md, "stdout_file"),
		"hover should mention stdout_file"
	);
};

// Goto-definition on the same symbol — exercises the same module lookup
// path via handle_definition, so a fix to module_from_path benefits both.
@test fn e2e_definition_on_stdlib_tag_dir_symbol() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(
		&s,
		strings::toutf8(

			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`,
		),
	);
	free(wait_for_response(&s, 1.0));
	send(
		&s, strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`),
	);

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
	match (result) {
	case json::object => void;
	case let arr: []json::value =>
		assert(len(arr) > 0, "definition should return at least one location");
	case =>
		fmt::fatalf(
			"e2e: definition returned null for os::stdout_file. body={}", text,
		);
	};
};

// Hover on a stdlib-qualified call (`bufio::newscanner`). The server lazily
// indexes the imported module from $HAREPATH / default install paths.
@test fn e2e_hover_on_stdlib_qualified_call() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(
		&s,
		strings::toutf8(

			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`,
		),
	);
	free(wait_for_response(&s, 1.0));
	send(
		&s, strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`),
	);

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
			text,
		);
	};
	const contents =
		*(json::get(&result_obj, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;
	assert(
		strings::contains(md, "newscanner"),
		"hover should mention the identifier"
	);
};

// Hover on a local `let` binding inside a function body. Before this was
// supported, the handler only looked at top-level decls and returned null.
@test fn e2e_hover_on_local_let_binding() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(
		&s,
		strings::toutf8(

			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`,
		),
	);
	free(wait_for_response(&s, 1.0));
	send(
		&s, strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`),
	);

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

	send(
		&s,
		strings::toutf8(

			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`,
		),
	);
	free(wait_for_response(&s, 1.0));
	send(
		&s, strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`),
	);

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
		strings::contains(md, "(parameter)"),
		"hover on parameter should mark it as a parameter"
	);
	assert(
		strings::contains(md, "int"),
		"hover on parameter should include its type"
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
			`","name":"hare-lsp"}],"capabilities":{}}}`,
		)!;
	defer free(init_msg);
	send(&s, strings::toutf8(init_msg));
	free(wait_for_response(&s, 1.0));
	send(
		&s, strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`),
	);

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
	match (result) {
	case json::object => void;
	case =>
		fmt::fatalf(

			"e2e: hover on `server::run` returned null — workspace-qualified hover broken. body={}",
			text,
		);
	};
};

// Best-effort: wait briefly for the "indexed N file(s)" log to arrive so the
// workspace index is populated. Times out silently — the hover test below
// will surface the real problem.
fn drain_until_indexed(s: *session) void = {
	for (let i = 0z; i < 20z; i += 1) {
		const body = recv(s);
		defer free(body);
		const text = strings::fromutf8(body)!;
		if (strings::contains(text, "indexed") &&
		strings::contains(text, "file(s)")) return;
	};
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
	send(
		&s,
		strings::toutf8(

			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`,
		),
	);
	free(wait_for_response(&s, 1.0));
	send(
		&s, strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`),
	);

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
			text,
		);
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

fn build_did_open(uri: str, body: str) str = {
	// JSON-encode the body. We do it the long way rather than json::dumpstr
	// to keep this test light — the body has no embedded quotes or
	// backslashes.
	let result =
		strings::concat(

			`{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"`,
			uri, `","languageId":"hare","version":1,"text":`, json_string_quote(body),
			`}}}`,
		)!;
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
