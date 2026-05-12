// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// e2e: textDocument/references, prepareRename, and rename.

use encoding::json;
use fmt;
use fs;
use io;
use os;
use strings;

@test fn e2e_references_finds_call_site_and_decl() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `export fn answer() int = 42;

export fn ask() int = answer();
export fn echo() int = answer();
`;
	open_doc(&s, "file:///refs.ha", sample);

	// Cursor on `answer` in the decl (line 0, char 12). includeDeclaration=true.
	const req = `{"jsonrpc":"2.0","id":1500,"method":"textDocument/references","params":{"textDocument":{"uri":"file:///refs.ha"},"position":{"line":0,"character":12},"context":{"includeDeclaration":true}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1500.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value)
		as []json::value;
	// Decl + two call sites = 3.
	assert(len(arr) >= 3,
		"should find at least the decl + two call sites");
	const loc0 = arr[0] as json::object;
	assert(json::get(&loc0, "uri") is *json::value,
		"each reference is a Location with uri");
	assert(json::get(&loc0, "range") is *json::value,
		"each reference is a Location with range");
};

@test fn e2e_prepare_rename_returns_ident_range() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `export fn answer() int = 42;
`;
	open_doc(&s, "file:///pr.ha", sample);

	// Cursor inside `answer` (line 0, char 12).
	const req = `{"jsonrpc":"2.0","id":1501,"method":"textDocument/prepareRename","params":{"textDocument":{"uri":"file:///pr.ha"},"position":{"line":0,"character":12}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1501.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = (*(json::get(&obj, "result") as *json::value))
		as json::object;
	const start = *(json::get(&result, "start") as *json::value)
		as json::object;
	const end = *(json::get(&result, "end") as *json::value)
		as json::object;
	const start_char = *(json::get(&start, "character") as *json::value) as f64;
	const end_char = *(json::get(&end, "character") as *json::value) as f64;
	// `answer` starts at col 10 and ends at col 16.
	assert(start_char == 10.0 && end_char == 16.0,
		"prepareRename should return the ident byte range");
};

@test fn e2e_rename_produces_workspace_edit() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `export fn answer() int = 42;

export fn ask() int = answer();
`;
	open_doc(&s, "file:///rn.ha", sample);

	// Rename `answer` to `result`.
	const req = `{"jsonrpc":"2.0","id":1502,"method":"textDocument/rename","params":{"textDocument":{"uri":"file:///rn.ha"},"position":{"line":0,"character":12},"newName":"result"}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1502.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = (*(json::get(&obj, "result") as *json::value))
		as json::object;
	const changes = (*(json::get(&result, "changes") as *json::value))
		as json::object;
	// The file's URI key should hold a non-empty TextEdit array.
	const edits = (*(json::get(&changes, "file:///rn.ha") as *json::value))
		as []json::value;
	assert(len(edits) >= 2,
		"rename should produce edits for both decl and call site");
	const e0 = edits[0] as json::object;
	const new_text = *(json::get(&e0, "newText") as *json::value) as str;
	assert(new_text == "result",
		"every edit should replace the identifier with the new name");
};

@test fn e2e_rename_respects_local_scope() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `let foo: int = 1;

export fn use_globals() void = {
	foo = 2;
};

export fn shadow() void = {
	let foo: int = 10;
	foo = 11;
};
`;
	open_doc(&s, "file:///shadow.ha", sample);

	// Cursor on the `foo` declared by `let foo: int = 10` (line 7, char 5).
	const req = `{"jsonrpc":"2.0","id":1510,"method":"textDocument/rename","params":{"textDocument":{"uri":"file:///shadow.ha"},"position":{"line":7,"character":5},"newName":"bar"}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1510.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = (*(json::get(&obj, "result") as *json::value))
		as json::object;
	const changes = (*(json::get(&result, "changes") as *json::value))
		as json::object;
	const edits = (*(json::get(&changes, "file:///shadow.ha") as *json::value))
		as []json::value;
	// Exactly two edits expected: line 7 (`let foo`) and line 8 (`foo = 11`).
	assert(len(edits) == 2,
		"local rename should produce exactly two edits");
	for (let i = 0z; i < len(edits); i += 1) {
		const e = edits[i] as json::object;
		const new_text = *(json::get(&e, "newText") as *json::value) as str;
		assert(new_text == "bar",
			"each edit replaces the local identifier");
		const r = *(json::get(&e, "range") as *json::value)
			as json::object;
		const start = *(json::get(&r, "start") as *json::value)
			as json::object;
		const line = *(json::get(&start, "line") as *json::value) as f64;
		// Lines 0-4 hold the global decl and use_globals; the local
		// rename must not touch any of them.
		assert(line >= 7.0,
			"local-rename edit must stay inside the shadowing function");
	};
};

// Two top-level functions named `samename` in different modules must not
// be conflated by the workspace scan: references from the cursor in
// `mod_a` must return hits only from `mod_a`.
@test fn e2e_references_distinguishes_same_name_across_modules() void = {
	const root = setup_crossmod_workspace("refs");
	defer cleanup_crossmod_workspace(root);

	let s = spawn_session();
	defer finish_session(&s);
	init_with_workspace_folder(&s, root);
	drain_until_indexed_ref(&s);

	const uri_a = strings::concat("file://", root, "/mod_a/file.ha")!;
	defer free(uri_a);
	open_doc(&s, uri_a,
		"export fn samename() int = 1;\n");

	// Cursor on `samename` in mod_a (line 0, col 12).
	const tmpl = `{"jsonrpc":"2.0","id":1520,"method":"textDocument/references","params":{"textDocument":{"uri":"`;
	const req = strings::concat(tmpl, uri_a,
		`"},"position":{"line":0,"character":12},"context":{"includeDeclaration":true}}}`)!;
	defer free(req);
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1520.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value)
		as []json::value;
	for (let i = 0z; i < len(arr); i += 1) {
		const loc = arr[i] as json::object;
		const u = *(json::get(&loc, "uri") as *json::value) as str;
		assert(strings::contains(u, "/mod_a/"),
			"references should only return hits in the cursor's module");
		assert(!strings::contains(u, "/mod_b/"),
			"references must not leak into the unrelated same-named module");
	};
};

// Same fixture, but for textDocument/rename: the workspace edit should
// touch only mod_a's file.
@test fn e2e_rename_distinguishes_same_name_across_modules() void = {
	const root = setup_crossmod_workspace("rename");
	defer cleanup_crossmod_workspace(root);

	let s = spawn_session();
	defer finish_session(&s);
	init_with_workspace_folder(&s, root);
	drain_until_indexed_ref(&s);

	const uri_a = strings::concat("file://", root, "/mod_a/file.ha")!;
	defer free(uri_a);
	open_doc(&s, uri_a,
		"export fn samename() int = 1;\n");

	const tmpl = `{"jsonrpc":"2.0","id":1521,"method":"textDocument/rename","params":{"textDocument":{"uri":"`;
	const req = strings::concat(tmpl, uri_a,
		`"},"position":{"line":0,"character":12},"newName":"renamed"}}`)!;
	defer free(req);
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1521.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = (*(json::get(&obj, "result") as *json::value))
		as json::object;
	const changes = (*(json::get(&result, "changes") as *json::value))
		as json::object;
	// mod_a's URI key should exist with a non-empty edit list; mod_b's
	// must not appear at all.
	const uri_b = strings::concat("file://", root, "/mod_b/file.ha")!;
	defer free(uri_b);
	assert(json::get(&changes, uri_a) is *json::value,
		"rename must produce an edit for the cursor's file");
	assert(!(json::get(&changes, uri_b) is *json::value),
		"rename must not touch the unrelated same-named module");
};

// Sets up `.tmp/e2e-crossmod-<label>/{mod_a,mod_b}/file.ha`, returns the
// absolute path to the root. Caller frees and should call
// [[cleanup_crossmod_workspace]].
fn setup_crossmod_workspace(label: str) str = {
	const cwd = os::getcwd();
	const root = strings::concat(cwd, "/.tmp/e2e-crossmod-", label)!;
	// Clean up any leftover state from a previous run before recreating.
	cleanup_crossmod_workspace(root);
	const mod_a = strings::concat(root, "/mod_a")!;
	defer free(mod_a);
	const mod_b = strings::concat(root, "/mod_b")!;
	defer free(mod_b);
	match (os::mkdirs(mod_a, 0o755: fs::mode)) {
	case void => void;
	case let e: fs::error =>
		fmt::fatalf("e2e: cannot mkdir {}: {}", mod_a, fs::strerror(e));
	};
	match (os::mkdirs(mod_b, 0o755: fs::mode)) {
	case void => void;
	case let e: fs::error =>
		fmt::fatalf("e2e: cannot mkdir {}: {}", mod_b, fs::strerror(e));
	};
	const file_a = strings::concat(mod_a, "/file.ha")!;
	defer free(file_a);
	const file_b = strings::concat(mod_b, "/file.ha")!;
	defer free(file_b);
	write_test_file(file_a, "export fn samename() int = 1;\n");
	write_test_file(file_b, "export fn samename() int = 2;\n");
	return root;
};

fn cleanup_crossmod_workspace(root: str) void = {
	match (os::rmdirall(root)) {
	case void => void;
	case fs::error => void;
	};
};

fn write_test_file(path: str, body: str) void = {
	const f = match (os::create(path, 0o644: fs::mode)) {
	case let f: io::file => yield f;
	case let e: fs::error =>
		fmt::fatalf("e2e: cannot create {}: {}", path, fs::strerror(e));
	};
	defer io::close(f)!;
	match (io::writeall(f, strings::toutf8(body))) {
	case size => void;
	case let e: io::error =>
		fmt::fatalf("e2e: cannot write {}: {}", path, io::strerror(e));
	};
};

fn init_with_workspace_folder(s: *session, root: str) void = {
	const msg = strings::concat(
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":"file://`,
		root,
		`","workspaceFolders":[{"uri":"file://`,
		root,
		`","name":"crossmod"}],"capabilities":{}}}`)!;
	defer free(msg);
	send(s, strings::toutf8(msg));
	free(wait_for_response(s, 1.0));
	send(s, strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));
};

fn drain_until_indexed_ref(s: *session) void = {
	for (let i = 0z; i < 20z; i += 1) {
		const body = recv(s);
		defer free(body);
		const text = strings::fromutf8(body)!;
		if (strings::contains(text, "indexed") &&
				strings::contains(text, "file(s)")) return;
	};
};

@test fn e2e_rename_rejects_invalid_identifier() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	open_doc(&s, "file:///rn_bad.ha", "export fn answer() int = 42;\n");

	// `return` is a keyword -> invalid Hare ident.
	const req = `{"jsonrpc":"2.0","id":1503,"method":"textDocument/rename","params":{"textDocument":{"uri":"file:///rn_bad.ha"},"position":{"line":0,"character":12},"newName":"return"}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1503.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	assert(json::get(&obj, "error") is *json::value,
		"renaming to a keyword must produce an error response");
};
