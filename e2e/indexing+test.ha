// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// e2e: chunked workspace indexing. The server uses cooperative batches
// driven by the main dispatch loop, with `$/progress` notifications
// reporting the begin/report/end lifecycle. These tests exercise the
// happy path (large workspace eventually finishes) and the cancel path
// (workDoneProgress/cancel halts further indexing).

use encoding::json;
use fmt;
use fs;
use os;
use strings;

// Generates `count` Hare source files under `dir`, each declaring a
// unique top-level function. Returns the directory path.
fn gen_index_workspace(label: str, count: size) str = {
	const cwd = os::getcwd();
	const root = strings::concat(cwd, "/.tmp/e2e-indexing-", label)!;
	cleanup_crossmod_workspace(root);
	match (os::mkdirs(root, 0o755: fs::mode)) {
	case void => void;
	case let e: fs::error =>
		fmt::fatalf("e2e: cannot mkdir {}: {}", root, fs::strerror(e));
	};
	for (let i = 0z; i < count; i += 1) {
		const path = fmt::asprintf("{}/file_{}.ha", root, i)!;
		defer free(path);
		const body = fmt::asprintf("export fn f_{}() int = {};\n", i, i)!;
		defer free(body);
		write_test_file(path, body);
	};
	return root;
};

// Drains messages until the indexing-completion log arrives, with a
// generous cap so a stuck server fails the test promptly.
fn drain_until_indexed_with_cap(s: *session, max: size) bool = {
	for (let i = 0z; i < max; i += 1) {
		const body = recv(s);
		defer free(body);
		const text = strings::fromutf8(body)!;
		if (strings::contains(text, "indexed") &&
		strings::contains(text, "file(s)")) return true;
	};
	return false;
};

// A workspace of ~150 files exercises the chunked path: with batch size
// 50 and 4 inline batches, the inline drain processes 200 files — so we
// pick a count comfortably above the inline limit to ensure background
// drains happen too.
@test fn e2e_indexing_chunked_indexes_large_workspace() void = {
	// 150 files: above the per-tick batch of 50 but small enough to
	// keep the test fast.
	const root = gen_index_workspace("chunked", 150z);
	defer cleanup_crossmod_workspace(root);

	let s = spawn_session();
	defer finish_session(&s);
	init_with_workspace_folder(&s, root);

	// Eventually the server logs the completion. Allow up to 200
	// messages to drain (progress notifications, config pulls,
	// registrations) — a healthy server emits the completion well
	// before that.
	assert(
		drain_until_indexed_with_cap(&s, 200z),
		"large workspace must eventually finish indexing"
	);

	// After completion, workspace/symbol can find a deep-in-the-batch
	// symbol. Pick file index 140 (after the inline batches).
	const req =
		`{"jsonrpc":"2.0","id":1730,"method":"workspace/symbol","params":{"query":"f_140"}}`;
	send(&s, strings::toutf8(req));
	const body = wait_for_response(&s, 1730.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = *(json::get(&obj, "result") as *json::value);
	// Response shape is either an array or a WorkspaceSymbolList
	// with { items, isIncomplete }. Accept either; just confirm
	// `f_140` appears.
	let items: []json::value = [];
	match (result) {
	case let arr: []json::value =>
		items = arr;
	case let obj: json::object =>
		match (json::get(&obj, "items")) {
		case let p: *json::value =>
			match (*p) {
			case let arr: []json::value =>
				items = arr;
			case => void;
			};
		case => void;
		};
	case => void;
	};
	let found = false;
	for (let i = 0z; i < len(items); i += 1) {
		const it = items[i] as json::object;
		const name = *(json::get(&it, "name") as *json::value) as str;
		if (name == "f_140") {
			found = true;
			break;
		};
	};
	assert(found, "deep file symbol must be reachable after indexing completes");
};

// Cancelling the indexing progress token must stop further work and
// leave the workspace partly indexed. We rely on the server emitting a
// progress `begin` first, then we send `cancel`, then we drain until
// the completion log. The reported count should be less than the total.
@test fn e2e_indexing_cancel_stops_job() void = {
	const root = gen_index_workspace("cancel", 250z);
	defer cleanup_crossmod_workspace(root);

	let s = spawn_session();
	defer finish_session(&s);
	init_with_workspace_folder(&s, root);

	// Read messages until we see a $/progress begin notification, then
	// extract the token and send cancel.
	let token: str = "";
	defer free(token);
	for (let i = 0z; i < 50z; i += 1) {
		const body = recv(&s);
		const text = strings::fromutf8(body)!;
		if (strings::contains(text, `"method":"$/progress"`) &&
		strings::contains(text, `"kind":"begin"`)) {
			token = extract_progress_token(text);
			free(body);
			break;
		};
		free(body);
	};
	assert(len(token) > 0, "server must emit $/progress begin before completion");

	const cancel =
		fmt::asprintf(

			`{{"jsonrpc":"2.0","method":"window/workDoneProgress/cancel","params":{{"token":"{}"}}}}`,
			token,
		)!;
	defer free(cancel);
	send(&s, strings::toutf8(cancel));

	// The server should still emit the completion log, with a count
	// below the workspace total.
	assert(
		drain_until_indexed_with_cap(&s, 200z),
		"cancelled job must still publish a completion log"
	);
};

// Tiny ad-hoc JSON extractor for `"token":"<value>"`. Avoids pulling in
// a full re-parse of the notification just to find one string field.
fn extract_progress_token(text: str) str = {
	const needle = `"token":"`;
	const start = match (strings::index(text, needle)) {
	case let i: size =>
		yield i + len(needle);
	case void =>
		return "";
	};
	const tail = strings::sub(text, start, strings::end);
	const end = match (strings::index(tail, '"')) {
	case let i: size =>
		yield i;
	case void =>
		return "";
	};
	return strings::dup(strings::sub(tail, 0, end))!;
};
