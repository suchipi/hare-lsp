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
use strconv;
use strings;
use time;

// Generates `count` Hare source files under `dir`, each declaring a
// unique top-level function. Returns the directory path.
fn gen_index_workspace(label: str, count: size) str = {
	const cwd = os::getcwd();
	const root = strings::concat(cwd, "/.tmp/e2e-indexing-", label)!;
	cleanup_workspace(root);
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

// Drains messages until the `$/progress` `end` notification for the
// workspace-indexing job arrives, then parses the file count out of its
// `message` field. The server formats the message as
// `<prefix> <count> file(s)` (with ` (cancelled)` appended if the job
// was cancelled, see server/workspace_index_job.ha:finish_head_job).
// Returns (count, cancelled). Fails the test if `max` messages drain
// without the end notification.
type index_end = struct {
	count: size,
	cancelled: bool,
};

fn drain_until_index_end(s: *session, max: size) index_end = {
	for (let i = 0z; i < max; i += 1) {
		const body = recv(s);
		defer free(body);
		const text = strings::fromutf8(body)!;
		let v = match (json::loadstr(text)) {
		case let v: json::value =>
			yield v;
		case =>
			continue;
		};
		defer json::finish(v);
		const obj = match (v) {
		case let o: json::object =>
			yield o;
		case =>
			continue;
		};
		const method = match (json::get(&obj, "method")) {
		case let p: *json::value =>
			yield match (*p) {
			case let s: str =>
				yield s;
			case =>
				continue;
			};
		case =>
			continue;
		};
		if (method != "$/progress") continue;
		const params = match (json::get(&obj, "params")) {
		case let p: *json::value =>
			yield match (*p) {
			case let o: json::object =>
				yield o;
			case =>
				continue;
			};
		case =>
			continue;
		};
		const value = match (json::get(&params, "value")) {
		case let p: *json::value =>
			yield match (*p) {
			case let o: json::object =>
				yield o;
			case =>
				continue;
			};
		case =>
			continue;
		};
		const kind = match (json::get(&value, "kind")) {
		case let p: *json::value =>
			yield match (*p) {
			case let s: str =>
				yield s;
			case =>
				continue;
			};
		case =>
			continue;
		};
		if (kind != "end") continue;
		const msg = match (json::get(&value, "message")) {
		case let p: *json::value =>
			yield match (*p) {
			case let s: str =>
				yield s;
			case =>
				continue;
			};
		case =>
			continue;
		};
		return parse_index_end_message(msg);
	};
	fmt::fatalf("e2e: indexing did not emit $/progress end within {} messages",
		max);
};

// Parses "<prefix> <count> file(s)[ (cancelled)]". Fails the test on
// any unrecognised shape so a regression in the server's message
// format surfaces as a test failure rather than a silent miss.
fn parse_index_end_message(msg: str) index_end = {
	const cancelled = strings::hassuffix(msg, " (cancelled)");
	const trimmed = if (cancelled)
		strings::sub(msg, 0, len(msg) - len(" (cancelled)"))
		else msg;
	const suffix = " file(s)";
	if (!strings::hassuffix(trimmed, suffix)) {
		fmt::fatalf("e2e: unexpected index end message: {}", msg);
	};
	const before_suffix = strings::sub(trimmed, 0, len(trimmed) - len(suffix));
	const last_space = match (strings::rindex(before_suffix, ' ')) {
	case let i: size =>
		yield i;
	case void =>
		fmt::fatalf("e2e: index end message has no count token: {}", msg);
	};
	const count_str = strings::sub(before_suffix, last_space + 1, strings::end);
	const count = match (strconv::stoz(count_str)) {
	case let n: size =>
		yield n;
	case =>
		fmt::fatalf("e2e: index end message count is not a number: {}", msg);
	};
	return index_end {
		count = count,
		cancelled = cancelled,
	};
};

// A workspace of ~150 files exercises the chunked path: with batch size
// 50 and 4 inline batches, the inline drain processes 200 files — so we
// pick a count comfortably below the inline limit to stay fast.
@test fn e2e_indexing_chunked_indexes_large_workspace() void = {
	const FILE_COUNT: size = 150z;
	const root = gen_index_workspace("chunked", FILE_COUNT);
	defer cleanup_workspace(root);

	let s = spawn_session();
	defer finish_session(&s);
	do_init_with_workspace(&s, root);

	// Eventually the server emits `$/progress` `end` with the final
	// count. Allow up to 200 messages to drain (begin, intermediate
	// report frames, config pulls, registrations).
	const result = drain_until_index_end(&s, 200z);
	assert(!result.cancelled, "happy-path indexing must not report cancelled");
	assert(
		result.count == FILE_COUNT,
		"indexing must report the exact workspace file count"
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
	const result_v = *(json::get(&obj, "result") as *json::value);
	const items = extract_symbol_items(result_v);
	// Find `f_140` and verify its location points at file_140.ha so a
	// regression that returned the right name but the wrong URI fails.
	let found_uri: str = "";
	for (let i = 0z; i < len(items); i += 1) {
		const it = items[i] as json::object;
		const name = *(json::get(&it, "name") as *json::value) as str;
		if (name != "f_140") continue;
		const loc = *(json::get(&it, "location") as *json::value) as json::object;
		found_uri = *(json::get(&loc, "uri") as *json::value) as str;
		break;
	};
	assert(
		len(found_uri) > 0,
		"deep file symbol must be reachable after indexing completes"
	);
	assert(
		strings::hassuffix(found_uri, "/file_140.ha"),
		"workspace/symbol must point f_140 at its source file"
	);
};

// Cancelling the indexing progress token must stop further work and
// leave the workspace partly indexed. The inline drain plus the one
// post-`initialized` background batch covers ~250 files; with 500
// files in the workspace, at least 250 will still be queued when the
// test sends `cancel`, so the cancel path is actually exercised.
@test fn e2e_indexing_cancel_stops_job() void = {
	const TOTAL: size = 500z;
	const root = gen_index_workspace("cancel", TOTAL);
	defer cleanup_workspace(root);

	let s = spawn_session();
	defer finish_session(&s);
	do_init_with_workspace(&s, root);

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
			token)!;
	defer free(cancel);
	send(&s, strings::toutf8(cancel));

	// The server should publish the end notification with a count
	// strictly below the total and the cancelled flag set. Both are
	// load-bearing: a regression that ignored the cancel would leave
	// `cancelled` false (and `count` equal to TOTAL).
	const result = drain_until_index_end(&s, 200z);
	assert(result.cancelled, "end notification must report the job as cancelled");
	assert(
		result.count < TOTAL,
		"cancelled indexing must report fewer files than the workspace total"
	);
};

// Indexing must continue advancing while the editor is silent. Pre-fix,
// `drain_index_job` only ran after a dispatched message, so a quiet client
// left the workspace permanently under-indexed. The fix polls stdin with
// timeout 0 between batches; this test reproduces the regression by
// staging a workspace larger than the inline-batch budget (4 * 50 = 200
// files), sleeping without sending anything, then querying for a symbol
// that the inline drain alone would not have reached.
//
// Note: we don't assert `isIncomplete: false`, because the workspace/symbol
// handler enqueues a stdlib index job on every cold call, so a job is
// always "in flight" the first time. The meaningful regression signal is
// whether the deep workspace symbol is present at all.
@test fn e2e_indexing_drains_while_client_is_idle() void = {
	// 600 files: the inline drain covers 200, so 8 more background
	// batches must happen during the idle sleep below.
	const root = gen_index_workspace("idle", 600z);
	defer cleanup_workspace(root);

	let s = spawn_session();
	defer finish_session(&s);
	do_init_with_workspace(&s, root);

	// Generous margin: 8 background batches of tiny files complete in
	// well under a second even on slow hardware.
	time::sleep(2 * time::SECOND);

	const req =
		`{"jsonrpc":"2.0","id":1731,"method":"workspace/symbol","params":{"query":"f_550"}}`;
	send(&s, strings::toutf8(req));
	const body = wait_for_response(&s, 1731.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const items = extract_symbol_items(
		*(json::get(&obj, "result") as *json::value));
	let found = false;
	for (let i = 0z; i < len(items); i += 1) {
		const it = items[i] as json::object;
		const name = *(json::get(&it, "name") as *json::value) as str;
		if (name == "f_550") {
			found = true;
			break;
		};
	};
	assert(
		found,
		"deep workspace symbol must be reachable after idle-time indexing"
	);
};

// workspace/symbol's response can be a bare array or a
// WorkspaceSymbolList { items, isIncomplete }. Returns the items array
// in either shape; an empty slice on anything else.
fn extract_symbol_items(result: json::value) []json::value = {
	match (result) {
	case let arr: []json::value =>
		return arr;
	case let obj: json::object =>
		match (json::get(&obj, "items")) {
		case let p: *json::value =>
			match (*p) {
			case let arr: []json::value =>
				return arr;
			case => void;
			};
		case => void;
		};
	case => void;
	};
	return [];
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
