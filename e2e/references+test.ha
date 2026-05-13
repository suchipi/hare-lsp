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

	const sample =
		`export fn answer() int = 42;

export fn ask() int = answer();
export fn echo() int = answer();
`;
	open_doc(&s, "file:///refs.ha", sample);

	// Cursor on `answer` in the decl (line 0, char 12). includeDeclaration=true.
	const req =
		`{"jsonrpc":"2.0","id":1500,"method":"textDocument/references","params":{"textDocument":{"uri":"file:///refs.ha"},"position":{"line":0,"character":12},"context":{"includeDeclaration":true}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1500.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	// The fixture has exactly three `answer` occurrences:
	//   line 0 col 10 (decl), line 2 col 22 (call in ask), line 3 col 23 (call in echo).
	// A `>=3` bound would let the server emit duplicates and pass; require an exact count.
	if (len(arr) != 3) {
		fmt::fatalf("e2e: references returned {} hits; fixture has exactly 3 `answer` occurrences. body={}",
			len(arr), text);
	};
	// Every Location must be in refs.ha. Collect (line, char) pairs and
	// verify the set matches the expected occurrence positions exactly --
	// a regression that returned every range at col 0, or pointed at
	// unrelated symbols, would fail this check.
	let seen_line0 = false;
	let seen_line2 = false;
	let seen_line3 = false;
	for (let i = 0z; i < len(arr); i += 1) {
		const loc = arr[i] as json::object;
		const u = *(json::get(&loc, "uri") as *json::value) as str;
		if (u != "file:///refs.ha") {
			fmt::fatalf("e2e: references[{}].uri = {}, expected file:///refs.ha", i, u);
		};
		const range = *(json::get(&loc, "range") as *json::value) as json::object;
		const start = *(json::get(&range, "start") as *json::value) as json::object;
		const sl = *(json::get(&start, "line") as *json::value) as f64;
		const sc = *(json::get(&start, "character") as *json::value) as f64;
		if (sl == 0.0 && sc == 10.0) {
			seen_line0 = true;
		} else if (sl == 2.0 && sc == 22.0) {
			seen_line2 = true;
		} else if (sl == 3.0 && sc == 23.0) {
			seen_line3 = true;
		} else {
			fmt::fatalf("e2e: unexpected references hit at ({}, {}); expected one of (0,10) (2,22) (3,23). body={}",
				sl, sc, text);
		};
	};
	assert(seen_line0 && seen_line2 && seen_line3,
		"references should cover the decl and both call sites with distinct positions");
};

@test fn e2e_prepare_rename_returns_ident_range() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `export fn answer() int = 42;
`;
	open_doc(&s, "file:///pr.ha", sample);

	// Cursor inside `answer` (line 0, char 12).
	const req =
		`{"jsonrpc":"2.0","id":1501,"method":"textDocument/prepareRename","params":{"textDocument":{"uri":"file:///pr.ha"},"position":{"line":0,"character":12}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1501.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = *(json::get(&obj, "result") as *json::value) as json::object;
	// LSP allows prepareRename to return either a bare Range or
	// `{range, placeholder}`. Pin the current shape (bare Range, identified
	// by top-level `start`/`end` and no `placeholder` field) so a switch
	// to the wrapped form is a deliberate, visible change.
	assert(
		!has_field(&result, "placeholder"),
		"prepareRename currently returns a bare Range, not {range, placeholder}; update this assertion if the server changes shape"
	);
	const start = *(json::get(&result, "start") as *json::value) as json::object;
	const end = *(json::get(&result, "end") as *json::value) as json::object;
	const start_line = *(json::get(&start, "line") as *json::value) as f64;
	const start_char = *(json::get(&start, "character") as *json::value) as f64;
	const end_line = *(json::get(&end, "line") as *json::value) as f64;
	const end_char = *(json::get(&end, "character") as *json::value) as f64;
	// `answer` is on line 0, cols 10..16.
	if (start_line != 0.0 || end_line != 0.0 || start_char != 10.0 ||
			end_char != 16.0) {
		fmt::fatalf("e2e: prepareRename range = ({},{}..{},{}), expected (0,10..0,16). body={}",
			start_line, start_char, end_line, end_char, text);
	};
};

@test fn e2e_rename_produces_workspace_edit() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample =
		`export fn answer() int = 42;

export fn ask() int = answer();
`;
	open_doc(&s, "file:///rn.ha", sample);

	// Rename `answer` to `result`.
	const req =
		`{"jsonrpc":"2.0","id":1502,"method":"textDocument/rename","params":{"textDocument":{"uri":"file:///rn.ha"},"position":{"line":0,"character":12},"newName":"result"}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1502.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = *(json::get(&obj, "result") as *json::value) as json::object;
	const changes =
		*(json::get(&result, "changes") as *json::value) as json::object;
	const edits =
		*(json::get(&changes, "file:///rn.ha") as *json::value) as []json::value;
	// Fixture has exactly two `answer` occurrences (decl line 0 col 10..16,
	// call line 2 col 22..28). Require an exact count; `>= 2` would let a
	// regression that emitted duplicate edits slip past and corrupt the user's file.
	if (len(edits) != 2) {
		fmt::fatalf("e2e: rename produced {} edits; fixture has exactly 2 `answer` occurrences. body={}",
			len(edits), text);
	};
	// Iterate every edit (not just edits[0]) -- a regression that mangled
	// newText on the second site would silently pass otherwise. Also pin
	// the (line, character) of each edit's start so an edit aimed at the
	// wrong byte span is caught.
	let seen_decl = false;
	let seen_call = false;
	for (let i = 0z; i < len(edits); i += 1) {
		const e = edits[i] as json::object;
		const new_text = *(json::get(&e, "newText") as *json::value) as str;
		if (new_text != "result") {
			fmt::fatalf("e2e: rename edit[{}].newText = {}, expected `result`. body={}",
				i, new_text, text);
		};
		const range = *(json::get(&e, "range") as *json::value) as json::object;
		const start = *(json::get(&range, "start") as *json::value) as json::object;
		const end = *(json::get(&range, "end") as *json::value) as json::object;
		const sl = *(json::get(&start, "line") as *json::value) as f64;
		const sc = *(json::get(&start, "character") as *json::value) as f64;
		const el = *(json::get(&end, "line") as *json::value) as f64;
		const ec = *(json::get(&end, "character") as *json::value) as f64;
		// Each edit must span exactly `answer` (6 chars) on one line.
		if (el != sl || ec - sc != 6.0) {
			fmt::fatalf("e2e: rename edit[{}] range = ({},{}..{},{}); expected a single-line 6-char span. body={}",
				i, sl, sc, el, ec, text);
		};
		if (sl == 0.0 && sc == 10.0) {
			seen_decl = true;
		} else if (sl == 2.0 && sc == 22.0) {
			seen_call = true;
		} else {
			fmt::fatalf("e2e: unexpected rename edit at ({}, {}); expected (0,10) decl or (2,22) call. body={}",
				sl, sc, text);
		};
	};
	assert(seen_decl && seen_call,
		"rename should edit both the decl and the call site, at distinct positions");
};

@test fn e2e_rename_respects_local_scope() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample =
		`let foo: int = 1;

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
	const req =
		`{"jsonrpc":"2.0","id":1510,"method":"textDocument/rename","params":{"textDocument":{"uri":"file:///shadow.ha"},"position":{"line":7,"character":5},"newName":"bar"}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1510.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = *(json::get(&obj, "result") as *json::value) as json::object;
	const changes =
		*(json::get(&result, "changes") as *json::value) as json::object;
	const edits =
		*(json::get(&changes, "file:///shadow.ha") as *json::value) as []json::value;
	// Exactly two edits expected: line 7 (`\tlet foo: ...`, foo at col 5)
	// and line 8 (`\tfoo = 11;`, foo at col 1). The previous `line >= 7.0`
	// permitted any line at or below 7 (including off-buffer positions),
	// so collect both lines and assert the exact set {(7, 5), (8, 1)}.
	if (len(edits) != 2) {
		fmt::fatalf("e2e: local rename produced {} edits; expected exactly 2. body={}",
			len(edits), text);
	};
	let seen_decl = false;
	let seen_assign = false;
	for (let i = 0z; i < len(edits); i += 1) {
		const e = edits[i] as json::object;
		const new_text = *(json::get(&e, "newText") as *json::value) as str;
		if (new_text != "bar") {
			fmt::fatalf("e2e: local rename edit[{}].newText = {}, expected `bar`. body={}",
				i, new_text, text);
		};
		const r = *(json::get(&e, "range") as *json::value) as json::object;
		const start = *(json::get(&r, "start") as *json::value) as json::object;
		const end = *(json::get(&r, "end") as *json::value) as json::object;
		const sl = *(json::get(&start, "line") as *json::value) as f64;
		const sc = *(json::get(&start, "character") as *json::value) as f64;
		const el = *(json::get(&end, "line") as *json::value) as f64;
		const ec = *(json::get(&end, "character") as *json::value) as f64;
		if (el != sl || ec - sc != 3.0) {
			fmt::fatalf("e2e: local rename edit[{}] range = ({},{}..{},{}); expected single-line 3-char (`foo`) span. body={}",
				i, sl, sc, el, ec, text);
		};
		if (sl == 7.0 && sc == 5.0) {
			seen_decl = true;
		} else if (sl == 8.0 && sc == 1.0) {
			seen_assign = true;
		} else {
			fmt::fatalf("e2e: unexpected local-rename edit at ({}, {}); the global decl on line 0 and the use_globals body on line 3 must NOT be touched. body={}",
				sl, sc, text);
		};
	};
	assert(seen_decl && seen_assign,
		"local rename should hit both `let foo` (line 7) and `foo = 11` (line 8) at distinct positions");
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
	open_doc(&s, uri_a, "export fn samename() int = 1;\n");

	// Cursor on `samename` in mod_a (line 0, col 12).
	const tmpl =
		`{"jsonrpc":"2.0","id":1520,"method":"textDocument/references","params":{"textDocument":{"uri":"`;
	const req =
		strings::concat(tmpl, uri_a,
			`"},"position":{"line":0,"character":12},"context":{"includeDeclaration":true}}}`
		)!;
	defer free(req);
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1520.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	// Guard against the vacuous-pass shape: with all assertions inside the
	// loop, an empty `arr` (server returned no references at all -- a real
	// regression) would slip past. Require at least the decl.
	if (len(arr) == 0) {
		fmt::fatalf("e2e: cross-module references returned no hits; expected at least the decl in mod_a. body={}",
			text);
	};
	for (let i = 0z; i < len(arr); i += 1) {
		const loc = arr[i] as json::object;
		const u = *(json::get(&loc, "uri") as *json::value) as str;
		// Structural URI check: every hit must live in mod_a/file.ha
		// specifically. Substring matches like `contains(u, "/mod_a/")`
		// would also accept paths nested under unrelated dirs that happen
		// to contain `mod_a` in their name; `hassuffix` pins the exact
		// per-module file.
		if (!strings::hassuffix(u, "/mod_a/file.ha")) {
			fmt::fatalf("e2e: references[{}].uri = {}; expected suffix /mod_a/file.ha", i, u);
		};
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
	open_doc(&s, uri_a, "export fn samename() int = 1;\n");

	const tmpl =
		`{"jsonrpc":"2.0","id":1521,"method":"textDocument/rename","params":{"textDocument":{"uri":"`;
	const req =
		strings::concat(tmpl, uri_a,
			`"},"position":{"line":0,"character":12},"newName":"renamed"}}`)!;
	defer free(req);
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1521.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = *(json::get(&obj, "result") as *json::value) as json::object;
	const changes =
		*(json::get(&result, "changes") as *json::value) as json::object;
	const uri_b = strings::concat("file://", root, "/mod_b/file.ha")!;
	defer free(uri_b);
	// mod_b must not appear at all -- the rename must not leak across modules.
	assert(
		!(json::get(&changes, uri_b) is *json::value),
		"rename must not touch the unrelated same-named module"
	);
	// mod_a must have edits that actually replace `samename` with `renamed`.
	// A presence-only `has_field` check would pass even on `{uri_a: []}`
	// (rename silently does nothing while VSCode reports success);
	// extract the array and verify its contents.
	const edits =
		*(json::get(&changes, uri_a) as *json::value) as []json::value;
	if (len(edits) < 1) {
		fmt::fatalf("e2e: cross-module rename returned 0 edits for mod_a; expected at least the decl edit. body={}",
			text);
	};
	const e0 = edits[0] as json::object;
	const new_text = *(json::get(&e0, "newText") as *json::value) as str;
	if (new_text != "renamed") {
		fmt::fatalf("e2e: cross-module rename edit[0].newText = {}, expected `renamed`. body={}",
			new_text, text);
	};
	const range = *(json::get(&e0, "range") as *json::value) as json::object;
	const start = *(json::get(&range, "start") as *json::value) as json::object;
	const end = *(json::get(&range, "end") as *json::value) as json::object;
	const sl = *(json::get(&start, "line") as *json::value) as f64;
	const sc = *(json::get(&start, "character") as *json::value) as f64;
	const el = *(json::get(&end, "line") as *json::value) as f64;
	const ec = *(json::get(&end, "character") as *json::value) as f64;
	// `samename` in `export fn samename() int = 1;` is at line 0 cols 10..18.
	if (sl != 0.0 || el != 0.0 || sc != 10.0 || ec != 18.0) {
		fmt::fatalf("e2e: cross-module rename edit[0] range = ({},{}..{},{}); expected (0,10..0,18) covering `samename`. body={}",
			sl, sc, el, ec, text);
	};
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
	case let f: io::file =>
		yield f;
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
	const msg =
		strings::concat(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":"file://`,
			root, `","workspaceFolders":[{"uri":"file://`, root,
			`","name":"crossmod"}],"capabilities":{}}}`)!;
	defer free(msg);
	send(s, strings::toutf8(msg));
	free(wait_for_response(s, 1.0));
	send(s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));
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
	const req =
		`{"jsonrpc":"2.0","id":1503,"method":"textDocument/rename","params":{"textDocument":{"uri":"file:///rn_bad.ha"},"position":{"line":0,"character":12},"newName":"return"}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1503.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	// Field-presence alone would accept any error including an unrelated
	// server crash. Pin the specific JSON-RPC error code (InvalidParams =
	// -32602) and the message text so VSCode's user-facing toast remains
	// the actionable "not a valid Hare identifier" string rather than a
	// generic internal-error message.
	const err =
		*(json::get(&obj, "error") as *json::value) as json::object;
	const code = *(json::get(&err, "code") as *json::value) as f64;
	const message = *(json::get(&err, "message") as *json::value) as str;
	if (code != -32602.0) {
		fmt::fatalf("e2e: rename error code = {}, expected -32602 (InvalidParams). body={}",
			code, text);
	};
	if (!strings::contains(message, "valid Hare identifier")) {
		fmt::fatalf("e2e: rename error message = {}, expected to mention `valid Hare identifier`. body={}",
			message, text);
	};
};
