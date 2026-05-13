// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// e2e: pull-style diagnostics (textDocument/diagnostic and
// workspace/diagnostic). Push-style diagnostics arrive as
// `textDocument/publishDiagnostics` notifications after didOpen/didChange
// and are exercised here as well by waiting for the notification.

use encoding::json;
use fmt;
use fs;
use io;
use os;
use strings;

@test fn e2e_pull_diagnostic_full_report_for_open_doc() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `export fn main() void = void;
`;
	open_doc(&s, "file:///pull_diag_ok.ha", sample);

	const req =
		`{"jsonrpc":"2.0","id":1000,"method":"textDocument/diagnostic","params":{"textDocument":{"uri":"file:///pull_diag_ok.ha"}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1000.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield *p;
	case void =>
		fmt::fatalf("e2e: pull diag missing result: {}", text);
	};
	const result_obj = result as json::object;
	const kind = *(json::get(&result_obj, "kind") as *json::value) as str;
	assert(kind == "full", "diagnostic report kind must be `full`");
	const items =
		*(json::get(&result_obj, "items") as *json::value) as []json::value;
	// Clean file: should be empty.
	assert(
		len(items) == 0,
		"a syntactically valid file should produce no diagnostics"
	);
};

@test fn e2e_pull_diagnostic_reports_parse_error() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	// Missing closing brace -> parser produces an error diagnostic.
	const sample = `export fn main() void = {
	let x = 1;
`;
	open_doc(&s, "file:///pull_diag_bad.ha", sample);

	const req =
		`{"jsonrpc":"2.0","id":1001,"method":"textDocument/diagnostic","params":{"textDocument":{"uri":"file:///pull_diag_bad.ha"}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1001.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result_obj =
		*(json::get(&obj, "result") as *json::value) as json::object;
	const items =
		*(json::get(&result_obj, "items") as *json::value) as []json::value;
	assert(len(items) >= 1, "broken file should produce at least one diagnostic");

	// The fixture's missing-`}` lives on the open brace at line 0 (the
	// `{` after `void = `). The recovering parser reports the error
	// somewhere between that brace and EOF (line 2). Verifying the
	// range lands on the fixture - rather than at (0, 0) or beyond
	// EOF - catches regressions where the error is mislocated.
	const d0 = items[0] as json::object;
	const sev = *(json::get(&d0, "severity") as *json::value) as f64;
	assert(sev == 1.0, "parse error must be severity 1 (Error)");
	const msg = *(json::get(&d0, "message") as *json::value) as str;
	assert(len(msg) > 0, "diagnostic message must be non-empty");
	const range = *(json::get(&d0, "range") as *json::value) as json::object;
	const start = *(json::get(&range, "start") as *json::value) as json::object;
	const start_line = *(json::get(&start, "line") as *json::value) as f64;
	assert(
		start_line >= 0.0 && start_line <= 2.0,
		"diagnostic range must land on the fixture (lines 0-2)"
	);
};

@test fn e2e_workspace_diagnostic_returns_per_doc_reports() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	open_doc(&s, "file:///ws_diag_a.ha", "export fn a() void = void;\n");
	open_doc(&s, "file:///ws_diag_b.ha", "export fn b() void = void;\n");

	const req =
		`{"jsonrpc":"2.0","id":1002,"method":"workspace/diagnostic","params":{"previousResultIds":[]}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1002.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result_obj =
		*(json::get(&obj, "result") as *json::value) as json::object;
	const items =
		*(json::get(&result_obj, "items") as *json::value) as []json::value;
	assert(
		len(items) == 2,
		"workspace diagnostic should report exactly one entry per open doc"
	);
	let saw_a = false;
	let saw_b = false;
	for (let i = 0z; i < len(items); i += 1) {
		const r = items[i] as json::object;
		assert(
			*(json::get(&r, "kind") as *json::value) as str == "full",
			"each per-doc report is a full report"
		);
		const r_uri = *(json::get(&r, "uri") as *json::value) as str;
		if (r_uri == "file:///ws_diag_a.ha") saw_a = true;
		if (r_uri == "file:///ws_diag_b.ha") saw_b = true;
		const r_items = *(json::get(&r, "items") as *json::value) as []json::value;
		assert(
			len(r_items) == 0,
			"clean files should produce no diagnostics in workspace report"
		);
	};
	assert(saw_a, "workspace diagnostic must report ws_diag_a.ha");
	assert(saw_b, "workspace diagnostic must report ws_diag_b.ha");
};

// Reads frames until a publishDiagnostics for `uri` arrives, returning
// the matching frame's body bytes. Caller takes ownership and must
// free the slice. Aborts if no matching frame shows up within the
// harness's recv budget.
fn wait_for_publish_diagnostics(s: *session, uri: str) []u8 = {
	for (let i = 0z; i < 50z; i += 1) {
		const body = recv(s);
		const text = strings::fromutf8(body)!;
		if (strings::contains(text, `"method":"textDocument/publishDiagnostics"`) &&
				strings::contains(text, uri)) {
			return body;
		};
		free(body);
	};
	fmt::fatalf("e2e: never received publishDiagnostics for {}", uri);
};

// Parses a publishDiagnostics notification frame and returns the parsed
// JSON root alongside the params.diagnostics slice borrowed from inside
// it. The caller must `json::finish(root)` when done; the slice becomes
// invalid at that point.
fn parse_publish_diagnostics(body: []u8) (json::value, []json::value) = {
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	const obj = v as json::object;
	const params = *(json::get(&obj, "params") as *json::value) as json::object;
	const diags =
		*(json::get(&params, "diagnostics") as *json::value) as []json::value;
	return (v, diags);
};

fn write_didsave_file(path: str, body: str) void = {
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

// Library modules have no `main` function. `hare build <library-dir>`
// (the default `-t bin`) would fail with "no main function defined";
// the dep-build path uses `-t o` (object build) so library modules
// type-check without that. Verifies the saved file's sibling-symbol
// references resolve too, the same as the multifile-module case.
@test fn e2e_didsave_library_module_no_unknown_object() void = {
	const cwd = os::getcwd();
	const root = strings::concat(cwd, "/.tmp/e2e-didsave-library-mod")!;
	defer free(root);
	cleanup_didsave_root(root);
	defer cleanup_didsave_root(root);

	match (os::mkdirs(root, 0o755: fs::mode)) {
	case void => void;
	case let e: fs::error =>
		fmt::fatalf("e2e: cannot mkdir {}: {}", root, fs::strerror(e));
	};
	const helpers_path = strings::concat(root, "/helpers.ha")!;
	defer free(helpers_path);
	write_didsave_file(helpers_path, "export fn helper() int = 42;\n");
	const lib_path = strings::concat(root, "/lib.ha")!;
	defer free(lib_path);
	// No `main` defined anywhere - this is a library module.
	write_didsave_file(lib_path, "export fn use_helper() int = helper();\n");

	let s = spawn_session();
	defer finish_session(&s);
	init_with_workspace_folder(&s, root);
	drain_until_indexed_ref(&s);

	const lib_uri = strings::concat("file://", lib_path)!;
	defer free(lib_uri);
	open_doc(&s, lib_uri, "export fn use_helper() int = helper();\n");
	free(wait_for_publish_diagnostics(&s, lib_uri));

	const save_msg =
		strings::concat(
			`{"jsonrpc":"2.0","method":"textDocument/didSave","params":{"textDocument":{"uri":"`,
			lib_uri, `"}}}`)!;
	defer free(save_msg);
	send(&s, strings::toutf8(save_msg));

	const body = wait_for_publish_diagnostics(&s, lib_uri);
	defer free(body);
	const (jv, diags) = parse_publish_diagnostics(body);
	defer json::finish(jv);
	assert(
		len(diags) == 0,
		"library-module didSave must publish no diagnostics: sibling-file symbols must resolve and missing-main must not fire"
	);
};

// Two-module workspace: `app/main.ha` does `use lib;` to reach a
// symbol defined in `lib/x.ha`. didSave on app/main.ha must walk into
// lib, build it first (with HAREPATH composed so `use lib` resolves),
// then build app itself - no false "Unknown module" or "Unknown
// object" errors.
@test fn e2e_didsave_module_with_local_dep_builds_dep_first() void = {
	const cwd = os::getcwd();
	const root = strings::concat(cwd, "/.tmp/e2e-didsave-local-dep")!;
	defer free(root);
	cleanup_didsave_root(root);
	defer cleanup_didsave_root(root);

	const app_dir = strings::concat(root, "/app")!;
	defer free(app_dir);
	const lib_dir = strings::concat(root, "/lib")!;
	defer free(lib_dir);
	match (os::mkdirs(app_dir, 0o755: fs::mode)) {
	case void => void;
	case let e: fs::error =>
		fmt::fatalf("e2e: cannot mkdir {}: {}", app_dir, fs::strerror(e));
	};
	match (os::mkdirs(lib_dir, 0o755: fs::mode)) {
	case void => void;
	case let e: fs::error =>
		fmt::fatalf("e2e: cannot mkdir {}: {}", lib_dir, fs::strerror(e));
	};
	const main_path = strings::concat(app_dir, "/main.ha")!;
	defer free(main_path);
	const lib_x_path = strings::concat(lib_dir, "/x.ha")!;
	defer free(lib_x_path);
	write_didsave_file(lib_x_path, "export fn provided() int = 7;\n");
	write_didsave_file(main_path,
		"use lib;\nexport fn main() void = { let _ = lib::provided(); };\n");

	let s = spawn_session();
	defer finish_session(&s);
	init_with_workspace_folder(&s, root);
	drain_until_indexed_ref(&s);

	const main_uri = strings::concat("file://", main_path)!;
	defer free(main_uri);
	open_doc(&s, main_uri,
		"use lib;\nexport fn main() void = { let _ = lib::provided(); };\n");
	free(wait_for_publish_diagnostics(&s, main_uri));

	const save_msg =
		strings::concat(
			`{"jsonrpc":"2.0","method":"textDocument/didSave","params":{"textDocument":{"uri":"`,
			main_uri, `"}}}`)!;
	defer free(save_msg);
	send(&s, strings::toutf8(save_msg));

	const body = wait_for_publish_diagnostics(&s, main_uri);
	defer free(body);
	const (jv, diags) = parse_publish_diagnostics(body);
	defer json::finish(jv);
	assert(
		len(diags) == 0,
		"cross-module didSave must publish no diagnostics: `use lib` resolves against the workspace folder and `lib::provided` is found"
	);
};

// Module that does `use io;` with no local `io/` dir: the resolver
// returns a path outside the workspace, the dep walker skips it as
// external, and the build runs successfully against the stdlib's io
// (resolved via the inherited HAREPATH).
@test fn e2e_didsave_skips_stdlib_uses() void = {
	const cwd = os::getcwd();
	const root = strings::concat(cwd, "/.tmp/e2e-didsave-stdlib-skip")!;
	defer free(root);
	cleanup_didsave_root(root);
	defer cleanup_didsave_root(root);

	match (os::mkdirs(root, 0o755: fs::mode)) {
	case void => void;
	case let e: fs::error =>
		fmt::fatalf("e2e: cannot mkdir {}: {}", root, fs::strerror(e));
	};
	const main_path = strings::concat(root, "/lib.ha")!;
	defer free(main_path);
	// `use strings;` resolves via HAREPATH to the stdlib's strings
	// module. The dep walker must classify that as external (not
	// under the workspace) and skip it; the build itself runs
	// against the saved module with stdlib resolved via the
	// inherited HAREPATH.
	const body = "use strings;\nexport fn upper(s: str) str = strings::dup(s)!;\n";
	write_didsave_file(main_path, body);

	let s = spawn_session();
	defer finish_session(&s);
	init_with_workspace_folder(&s, root);
	drain_until_indexed_ref(&s);

	const main_uri = strings::concat("file://", main_path)!;
	defer free(main_uri);
	open_doc(&s, main_uri, body);
	free(wait_for_publish_diagnostics(&s, main_uri));

	const save_msg =
		strings::concat(
			`{"jsonrpc":"2.0","method":"textDocument/didSave","params":{"textDocument":{"uri":"`,
			main_uri, `"}}}`)!;
	defer free(save_msg);
	send(&s, strings::toutf8(save_msg));

	const published = wait_for_publish_diagnostics(&s, main_uri);
	defer free(published);
	const (jv, diags) = parse_publish_diagnostics(published);
	defer json::finish(jv);
	// Stdlib modules resolve via HAREPATH; the dep walker must not
	// fall over because there's no local `strings/` directory.
	assert(
		len(diags) == 0,
		"stdlib uses must resolve via HAREPATH (dep walker treats them as external and skips); no diagnostics expected"
	);
};

// Regression: once a sibling-file error is fixed and the user saves
// again, the LSP must publish an empty diagnostics list for that
// sibling URI so the editor stops showing the stale entry. The dep
// walker compiles the whole module each save; without the stale-
// clearing pass, the first save would publish errors for sibling.ha,
// the second save would only publish for the saved file, and
// sibling.ha's old errors would linger.
@test fn e2e_didsave_clears_stale_diagnostics_for_sibling() void = {
	const cwd = os::getcwd();
	const root = strings::concat(cwd, "/.tmp/e2e-didsave-stale-clear")!;
	defer free(root);
	cleanup_didsave_root(root);
	defer cleanup_didsave_root(root);

	match (os::mkdirs(root, 0o755: fs::mode)) {
	case void => void;
	case let e: fs::error =>
		fmt::fatalf("e2e: cannot mkdir {}: {}", root, fs::strerror(e));
	};
	const sibling_path = strings::concat(root, "/sibling.ha")!;
	defer free(sibling_path);
	const main_path = strings::concat(root, "/main.ha")!;
	defer free(main_path);
	// Start with sibling.ha broken: references an undefined symbol.
	write_didsave_file(sibling_path, "export fn s() void = undefined_symbol();\n");
	write_didsave_file(main_path, "export fn m() void = void;\n");

	let s = spawn_session();
	defer finish_session(&s);
	init_with_workspace_folder(&s, root);
	drain_until_indexed_ref(&s);

	const main_uri = strings::concat("file://", main_path)!;
	defer free(main_uri);
	const sibling_uri = strings::concat("file://", sibling_path)!;
	defer free(sibling_uri);

	open_doc(&s, main_uri, "export fn m() void = void;\n");
	free(wait_for_publish_diagnostics(&s, main_uri));

	// First save: sibling.ha is broken; the dep build should emit an
	// "Unknown object" diagnostic for sibling.ha, and the LSP must
	// publish to its URI (proves we tracked it for later clearing).
	const save_msg =
		strings::concat(
			`{"jsonrpc":"2.0","method":"textDocument/didSave","params":{"textDocument":{"uri":"`,
			main_uri, `"}}}`)!;
	defer free(save_msg);
	send(&s, strings::toutf8(save_msg));
	const sibling_initial = wait_for_publish_diagnostics(&s, sibling_uri);
	defer free(sibling_initial);
	const (initial_root, initial_diags) = parse_publish_diagnostics(
		sibling_initial);
	defer json::finish(initial_root);
	assert(
		len(initial_diags) >= 1,
		"first didSave must publish at least one diagnostic for the broken sibling.ha"
	);
	let saw_undef = false;
	for (let i = 0z; i < len(initial_diags); i += 1) {
		const d = initial_diags[i] as json::object;
		const dmsg = *(json::get(&d, "message") as *json::value) as str;
		if (strings::contains(dmsg, "undefined_symbol")) {
			saw_undef = true;
			break;
		};
	};
	assert(
		saw_undef,
		"first didSave's sibling.ha diagnostics must mention the undefined symbol"
	);

	// Fix sibling.ha on disk and save main.ha again. The next pass
	// must publish an empty diagnostics list for sibling.ha so the
	// editor drops the now-stale entry. The main.ha publish that
	// also fires this round is fine; the wait helper drains past it
	// looking for the sibling publish specifically.
	write_didsave_file(sibling_path, "export fn s() void = void;\n");
	send(&s, strings::toutf8(save_msg));

	const sibling_cleared = wait_for_publish_diagnostics(&s, sibling_uri);
	defer free(sibling_cleared);
	const (cleared_root, cleared_diags) = parse_publish_diagnostics(
		sibling_cleared);
	defer json::finish(cleared_root);
	assert(
		len(cleared_diags) == 0,
		"second didSave must publish empty diagnostics for the now-fixed sibling.ha"
	);
};

fn cleanup_didsave_root(root: str) void = {
	match (os::rmdirall(root)) {
	case void => void;
	case fs::error => void;
	};
};

// Regression: the didSave dep-build path uses `hare build -t o` to type-
// check modules. Without `-o /dev/null`, hare drops `<module>.o` into the
// child's cwd (the workspace folder), littering the user's repo. Verifies
// that after a save we don't leave any `.o` artifacts behind.
@test fn e2e_didsave_does_not_leave_object_files() void = {
	const cwd = os::getcwd();
	const root = strings::concat(cwd, "/.tmp/e2e-didsave-no-obj-files")!;
	defer free(root);
	cleanup_didsave_root(root);
	defer cleanup_didsave_root(root);

	match (os::mkdirs(root, 0o755: fs::mode)) {
	case void => void;
	case let e: fs::error =>
		fmt::fatalf("e2e: cannot mkdir {}: {}", root, fs::strerror(e));
	};
	const main_path = strings::concat(root, "/main.ha")!;
	defer free(main_path);
	const body = "export fn add(a: int, b: int) int = a + b;\n";
	write_didsave_file(main_path, body);

	let s = spawn_session();
	defer finish_session(&s);
	init_with_workspace_folder(&s, root);
	drain_until_indexed_ref(&s);

	const main_uri = strings::concat("file://", main_path)!;
	defer free(main_uri);
	open_doc(&s, main_uri, body);
	free(wait_for_publish_diagnostics(&s, main_uri));

	const save_msg =
		strings::concat(
			`{"jsonrpc":"2.0","method":"textDocument/didSave","params":{"textDocument":{"uri":"`,
			main_uri, `"}}}`)!;
	defer free(save_msg);
	send(&s, strings::toutf8(save_msg));
	free(wait_for_publish_diagnostics(&s, main_uri));

	const ents = match (os::readdir(root)) {
	case let e: []fs::dirent =>
		yield e;
	case let e: fs::error =>
		fmt::fatalf("e2e: cannot readdir {}: {}", root, fs::strerror(e));
	case =>
		fmt::fatalf("e2e: out of memory reading {}", root);
	};
	defer fs::dirents_free(ents);
	for (let i = 0z; i < len(ents); i += 1) {
		assert(
			!strings::hassuffix(ents[i].name, ".o"),
			"didSave must not leave .o files in the workspace folder"
		);
	};
};

// Push-style: opening a broken doc produces a publishDiagnostics
// notification carrying at least one error-severity entry. Drain frames
// until we see it.
@test fn e2e_push_diagnostic_published_after_didopen() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `export fn main() void = {
	let x = 1;
`;
	open_doc(&s, "file:///push_diag.ha", sample);

	const body = wait_for_publish_diagnostics(&s, "file:///push_diag.ha");
	defer free(body);
	const (jv, diags) = parse_publish_diagnostics(body);
	defer json::finish(jv);
	assert(
		len(diags) >= 1,
		"push-style publishDiagnostics for a broken doc must include at least one diagnostic"
	);
	let saw_error = false;
	for (let i = 0z; i < len(diags); i += 1) {
		const d = diags[i] as json::object;
		const sev = *(json::get(&d, "severity") as *json::value) as f64;
		if (sev == 1.0) {
			saw_error = true;
			break;
		};
	};
	assert(
		saw_error,
		"broken doc must produce at least one severity-1 (Error) diagnostic"
	);
};
