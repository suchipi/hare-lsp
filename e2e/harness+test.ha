// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// End-to-end test harness: spawns the actual `./hare-lsp` binary with pipes
// on stdin and stdout, exchanges framed JSON-RPC messages, and tears the
// process down at the end of the test.

use ascii;
use encoding::json;
use fmt;
use fs;
use io;
use os;
use os::exec;
use strconv;
use strings;
use time;
use unix::poll;
use unix::signal;

// Default deadlines for per-recv waits and child-exit waits. Tests
// historically used a 5s recv budget and a 2s exit budget. Both proved
// too tight when `make test`'s seven parallel shards spawn
// fresh `./hare-lsp` processes under CPU/IO contention: every shard
// runs an independent test process plus its own server child, so an
// 8-core machine is already at ~1.75x oversubscription before any
// background load. The bumped floors give the harness real headroom
// while still failing reasonably fast on a truly hung server.
//
// Both floors are env-overridable so CI on tiny boxes can dial them
// up further without touching code: set E2E_RECV_TIMEOUT_MS for the
// per-recv budget and E2E_EXIT_TIMEOUT_MS for assert_clean_exit /
// finish_session graceful-exit windows. The Makefile sets these for
// the parallel `test` target only; `test-serial` uses the defaults.
def DEFAULT_RECV_TIMEOUT_MS: i64 = 30000;

def DEFAULT_EXIT_TIMEOUT_MS: i64 = 10000;

// Liveness polling cadence inside recv. While waiting for bytes, we
// also peek the child periodically; if it exited unexpectedly we want
// a clear "server died" diagnostic rather than a "recv timed out"
// after the full budget elapses. 250ms keeps the overhead negligible
// (4 syscalls/s during a wait) while still surfacing a crash quickly.
def LIVENESS_POLL_INTERVAL: time::duration = 250 * time::MILLISECOND;

fn env_duration_ms(name: str, default_ms: i64) time::duration = {
	const ms = match (os::getenv(name)) {
	case let s: str =>
		yield match (strconv::stoi64(s)) {
		case let n: i64 =>
			yield if (n > 0) n else default_ms;
		case =>
			yield default_ms;
		};
	case void =>
		yield default_ms;
	};
	return ms: time::duration * time::MILLISECOND;
};

fn recv_timeout() time::duration = {
	return env_duration_ms("E2E_RECV_TIMEOUT_MS", DEFAULT_RECV_TIMEOUT_MS);
};

fn exit_timeout() time::duration = {
	return env_duration_ms("E2E_EXIT_TIMEOUT_MS", DEFAULT_EXIT_TIMEOUT_MS);
};

let session_counter: size = 0;

fn bin_path() str = {
	return os::tryenv("HARE_LSP_BIN", "./hare-lsp");
};

fn binary_exists(path: str) bool = {
	match (os::access(path, os::amode::F_OK)) {
	case let b: bool =>
		return b;
	case fs::error =>
		return false;
	};
};

// Returns a per-session log directory underneath `base`, creating it on
// demand. The counter is process-local, so parallel shards using the same
// `base` will collide on `session-<n>/` names; opt-in callers should use
// distinct `base` paths per shard (or pin a single shard to that base).
fn auto_log_dir(base: str) str = {
	session_counter += 1;
	const dir = fmt::asprintf("{}/session-{}", base, session_counter)!;
	match (os::mkdirs(dir, 0o755: fs::mode)) {
	case void => void;
	case fs::error => void;
	};
	return dir;
};

export type session = struct {
	proc: exec::process,
	stdin: io::file,
	stdout: io::file,
	read_buf: []u8,
	header_scan_pos: size,
	next_id_counter: f64,
};

fn spawn_session() session = {
	return spawn_session_with_env([]);
};

// Spawns a session that always tees its wire traffic into
// `.tmp/e2e-logs/<label>/` regardless of the `E2E_LOG_DIR` opt-in. A small
// hand-picked set of tests use this so the logging codepath is exercised on
// every `make test` run; the path is keyed on `label` (not a counter) so
// parallel shards don't collide as long as no two opted-in tests reuse the
// same label. Treat `label` like the `.tmp/` per-test naming rule in
// `.claude/rules/test-fixtures-and-tmp-dir.md`.
fn spawn_session_with_logs(label: str) session = {
	const cwd = os::getcwd();
	const dir = fmt::asprintf("{}/.tmp/e2e-logs/{}", cwd, label)!;
	defer free(dir);
	match (os::mkdirs(dir, 0o755: fs::mode)) {
	case void => void;
	case fs::error => void;
	};
	const env: [](str, str) = [
		("HARE_LSP_LOG_DIR", dir),
	];
	return spawn_session_with_env(env);
};

fn spawn_session_with_env(env: [](str, str)) session = {
	const path = bin_path();
	if (!binary_exists(path)) {
		fmt::fatalf(
			"e2e: {} does not exist (cwd={}). Build it with `make`, or set HARE_LSP_BIN to override.",
			path, os::getcwd());
	};

	const (in_r, in_w) = exec::pipe();
	const (out_r, out_w) = exec::pipe();

	let cmd = match (exec::cmd(path)) {
	case let c: exec::command =>
		yield c;
	case let e: exec::error =>
		fmt::fatalf("e2e: cannot prepare {}: {}", path, exec::strerror(e));
	case nomem => abort("e2e: out of memory preparing command");
	};

	// Auto-log to a per-session directory under .tmp/e2e-logs/ only when
	// the developer opts in via `E2E_LOG_DIR=<basedir>` in the test
	// runner's environment. Enabling unconditionally makes parallel
	// shards contend on the same `session-<n>/` directory (the counter
	// is per-process) and the resulting disk pressure can push recv
	// past the 5s budget. Opt-in keeps single-test debugging
	// ergonomic without breaking the full-suite run.
	const log_dir = match (os::getenv("E2E_LOG_DIR")) {
	case let base: str =>
		yield if (len(base) == 0) "" else auto_log_dir(base);
	case void =>
		yield "";
	};
	defer if (len(log_dir) > 0) free(log_dir);
	if (len(log_dir) > 0) {
		match (exec::setenv(&cmd, "HARE_LSP_LOG_DIR", log_dir)) {
		case void => void;
		case =>
			fmt::fatalf("e2e: setenv HARE_LSP_LOG_DIR={} failed", log_dir);
		};
	};

	for (let i = 0z; i < len(env); i += 1) {
		match (exec::setenv(&cmd, env[i].0, env[i].1)) {
		case void => void;
		case =>
			fmt::fatalf("e2e: setenv {}={} failed", env[i].0, env[i].1);
		};
	};

	exec::addfile(&cmd, os::stdin_file, in_r)!;
	exec::addfile(&cmd, os::stdout_file, out_w)!;
	exec::addfile(&cmd, os::stderr_file, exec::nullfd)!;

	const proc = match (exec::start(&cmd)) {
	case let p: exec::process =>
		yield p;
	case let e: exec::error =>
		fmt::fatalf("e2e: cannot start server: {}", exec::strerror(e));
	};

	io::close(in_r)!;
	io::close(out_w)!;

	return session {
		proc = proc,
		stdin = in_w,
		stdout = out_r,
		read_buf = [],
		header_scan_pos = 0,
		next_id_counter = 0.0,
	};
};

fn next_id(s: *session) f64 = {
	s.next_id_counter += 1.0;
	return s.next_id_counter;
};

fn make_request(method: str, id: f64, params_json: str) str = {
	const id_str = f64_to_int_str(id);
	defer free(id_str);
	return strings::concat(`{"jsonrpc":"2.0","id":`, id_str, `,"method":"`,
		method, `","params":`, params_json, `}`)!;
};

fn make_notification(method: str, params_json: str) str = {
	return strings::concat(`{"jsonrpc":"2.0","method":"`, method, `","params":`,
		params_json, `}`)!;
};

// Wait for the child to exit, returning its exit status if it does
// within `deadline`. Returns void on timeout. Polls at ~20ms cadence,
// which keeps the test responsive (no test wastes more than one poll
// interval on an already-dead child) while leaving plenty of CPU for
// other shards.
//
// `exec::peek` returning `exec::error` is treated as not-yet-exited
// rather than fatal: the most plausible cause is a transient signal
// state, and the next poll iteration will see the real exit if the
// process is genuinely gone.
fn wait_for_exit(s: *session, deadline: time::instant) (exec::status | void) = {
	for (true) {
		match (exec::peek(&s.proc)) {
		case let st: exec::status =>
			return st;
		case (void | exec::error) => void;
		};
		if (time::compare(time::now(time::clock::MONOTONIC), deadline) >= 0) {
			return void;
		};
		time::sleep(20 * time::MILLISECOND);
	};
};

// Tear the session down: close pipes, give the child a graceful
// window to exit, then escalate to SIGTERM and finally SIGKILL.
// All deadlines scale with `exit_timeout()` so high-load shards
// don't false-positive on a healthy-but-slow shutdown. The graceful
// window is the larger of the two; SIGTERM gets a fixed slice
// because once we've signaled, anything beyond a second or so is
// effectively a stuck process and SIGKILL is appropriate.
fn finish_session(s: *session) void = {
	defer {
		free(s.read_buf);
		s.read_buf = [];
	};
	const _ = io::close(s.stdin);
	const _ = io::close(s.stdout);

	const budget = exit_timeout();
	const graceful = time::add(time::now(time::clock::MONOTONIC), budget);
	match (wait_for_exit(s, graceful)) {
	case exec::status =>
		return;
	case void => void;
	};
	const _ = exec::sig(s.proc, signal::sig::TERM);
	const after_term = time::add(time::now(time::clock::MONOTONIC),
		1 * time::SECOND);
	match (wait_for_exit(s, after_term)) {
	case exec::status =>
		return;
	case void =>
		const _ = exec::sig(s.proc, signal::sig::KILL);
		const _ = exec::wait(&s.proc);
	};
};

// Polls for the child to exit and fails the test if it doesn't, or if
// it exits with a non-zero status. `total` is the per-test grace
// window for an honest exit; on parallel-shard CI it is dominated by
// the time the LSP needs to flush diagnostics + return from main, not
// by an actual hang. Tests can pass a small `total` here; the harness
// floors it at the configured exit budget so a 2-second caller still
// gets ~10s of headroom under load.
fn assert_clean_exit(s: *session, total: time::duration) void = {
	const floor = exit_timeout();
	// time::duration is an i64 in nanoseconds; compare directly. Don't
	// reach for time::compare here, that one takes time::instant.
	const effective = if (total: i64 < floor: i64) floor else total;
	const deadline = time::add(time::now(time::clock::MONOTONIC), effective);
	match (wait_for_exit(s, deadline)) {
	case let st: exec::status =>
		match (exec::check(&st)) {
		case void =>
			return;
		case !exec::exit_status =>
			const summary = exec::exitstr(exec::exit(&st));
			fmt::fatalf("e2e: server exited uncleanly after `exit`: {}", summary);
		};
	case void =>
		fmt::fatalf("e2e: server did not exit within {} ms of `exit`",
			effective / time::MILLISECOND);
	};
};

fn send(s: *session, body: const []u8) void = {
	let header_buf: [64]u8 = [0...];
	const header =
		fmt::bsprintf(header_buf, "Content-Length: {}\r\n\r\n", len(body))!;
	io::writeall(s.stdin, strings::toutf8(header))!;
	io::writeall(s.stdin, body)!;
};

fn recv(s: *session) []u8 = {
	const budget = recv_timeout();
	match (recv_with_deadline(s, budget)) {
	case let b: []u8 =>
		return b;
	case void =>
		// If the budget elapsed without bytes arriving, do one last
		// liveness check before reporting timeout: a server that died
		// silently (e.g. SIGKILL'd by the OOM killer) deserves a
		// clearer error than "recv timed out".
		match (exec::peek(&s.proc)) {
		case let st: exec::status =>
			const summary = exec::exitstr(exec::exit(&st));
			fmt::fatalf(
				"e2e: server exited during recv (after {} ms, buffered {} bytes): {}",
				budget / time::MILLISECOND, len(s.read_buf), summary);
		case (void | exec::error) => void;
		};
		// The 0-bytes case is almost always parallel-shard load: the
		// server hasn't crashed (peek succeeded above) and yet sent
		// nothing during the window. Mention this in the message so
		// future investigators can tell flake-from-load apart from a
		// real bug without re-running. The fix when this is genuine
		// flake-from-load is to bump E2E_RECV_TIMEOUT_MS, not to
		// rewrite the test.
		const hint = if (len(s.read_buf) == 0)
			" (server alive but silent; usually shard contention - try E2E_RECV_TIMEOUT_MS=60000)"
			else "";
		fmt::fatalf("e2e: recv timed out after {} ms (buffered {} bytes){}",
			budget / time::MILLISECOND, len(s.read_buf), hint);
	};
};

// Reads framed messages with a soft deadline. Returns void on timeout
// rather than fatal-ing, so callers like `expect_no_message` can assert
// silence. Periodically peeks the child during the wait so a crashed
// server triggers a clear "server died" fatal long before the budget
// runs out; otherwise a dead-server probe would idle here for the full
// timeout and then misreport the failure mode.
fn recv_with_deadline(s: *session, budget: time::duration) ([]u8 | void) = {
	const deadline = time::add(time::now(time::clock::MONOTONIC), budget);
	let chunk: [4096]u8 = [0...];

	for (true) {
		match (try_take_frame(s)) {
		case let body: []u8 =>
			return body;
		case void => void;
		};

		const now = time::now(time::clock::MONOTONIC);
		if (time::compare(now, deadline) >= 0) {
			return void;
		};
		const remaining_ns = time::diff(now, deadline);
		// Cap each poll at LIVENESS_POLL_INTERVAL so a server that
		// silently dies mid-wait surfaces quickly, not at the end of
		// the (possibly minutes-long) budget.
		const slice_ns = if (remaining_ns < LIVENESS_POLL_INTERVAL) remaining_ns
			else LIVENESS_POLL_INTERVAL;

		let pfd: [_]poll::pollfd = [
			poll::pollfd {
				fd = s.stdout,
				events = poll::event::POLLIN,
				revents = 0,
			},
		];
		const ready = match (poll::poll(pfd, slice_ns)) {
		case let n: uint =>
			yield n;
		case poll::error => abort("e2e: poll failed");
		};
		if (ready == 0) {
			// No bytes this slice. If the child is gone, fail with
			// a useful diagnostic rather than waiting out the rest
			// of the budget.
			match (exec::peek(&s.proc)) {
			case let st: exec::status =>
				const summary = exec::exitstr(exec::exit(&st));
				fmt::fatalf("e2e: server exited mid-recv (buffered {} bytes): {}",
					len(s.read_buf), summary);
			case (void | exec::error) => void;
			};
			continue;
		};

		const n = match (io::read(s.stdout, chunk[..])) {
		case let n: size =>
			yield n;
		case io::EOF =>
			fmt::fatalf("e2e: server stdout closed after {} bytes (incomplete frame)",
				len(s.read_buf));
		case let e: io::error =>
			fmt::fatalf("e2e: read failed: {}", io::strerror(e));
		};
		if (n == 0) continue;
		append(s.read_buf, chunk[..n]...)!;
	};
};

fn expect_no_message(s: *session, budget: time::duration) void = {
	match (recv_with_deadline(s, budget)) {
	case let body: []u8 =>
		defer free(body);
		const text = strings::fromutf8(body)!;
		fmt::fatalf("e2e: expected no message in {} ms, got: {}",
			budget / time::MILLISECOND, text);
	case void =>
		return;
	};
};

fn try_take_frame(s: *session) ([]u8 | void) = {
	const (body_off, body_len) = match (parse_header(s)) {
	case let p: (size, size) =>
		yield p;
	case void =>
		return void;
	};
	const frame_end = body_off + body_len;
	if (len(s.read_buf) < frame_end) return void;

	let out: []u8 = alloc([0...], body_len)!;
	out[..] = s.read_buf[body_off..frame_end];

	const leftover = len(s.read_buf) - frame_end;
	if (leftover > 0) {
		for (let i = 0z; i < leftover; i += 1) {
			s.read_buf[i] = s.read_buf[frame_end + i];
		};
	};
	s.read_buf = s.read_buf[..leftover];
	s.header_scan_pos = 0;
	return out;
};

fn parse_header(s: *session) ((size, size) | void) = {
	const needle: []u8 = ['\r', '\n', '\r', '\n'];
	if (len(s.read_buf) < len(needle)) return;
	let end: size = 0;
	let found = false;
	let start: size = 0;
	// Resume from `len(needle) - 1` bytes before the previous high
	// water mark so we still catch a needle that straddled the
	// boundary between the bytes we saw last call and the bytes that
	// just arrived. Parens matter: `len(needle) - 1` first, then
	// subtract — otherwise size's unsigned arithmetic underflows to
	// SIZE_MAX when `header_scan_pos == len(needle)` exactly.
	if (s.header_scan_pos > len(needle) - 1) {
		start = s.header_scan_pos - (len(needle) - 1);
	};
	for (let i = start; i + len(needle) <= len(s.read_buf); i += 1) {
		if (s.read_buf[i] == needle[0] && s.read_buf[i + 1] == needle[1]
				&& s.read_buf[i + 2] == needle[2] && s.read_buf[i + 3] == needle[3]) {
			end = i;
			found = true;
			break;
		};
	};
	if (!found) {
		s.header_scan_pos = len(s.read_buf);
		return;
	};

	const headers = match (strings::fromutf8(s.read_buf[..end])) {
	case let s: str =>
		yield s;
	case => abort("e2e: server emitted non-UTF-8 headers");
	};
	const length = match (find_content_length(headers)) {
	case let n: size =>
		yield n;
	case void =>
		fmt::fatalf("e2e: response missing Content-Length: {}", headers);
	};
	return (end + len(needle), length);
};

fn find_content_length(headers: str) (size | void) = {
	const tok = strings::tokenize(headers, "\r\n");
	for (let line => strings::next_token(&tok)) {
		const colon = match (strings::index(line, ':')) {
		case let i: size =>
			yield i;
		case void =>
			continue;
		};
		const name = strings::sub(line, 0, colon);
		// RFC 7230 §3.2 says HTTP-style header field names are
		// case-insensitive; LSP inherits this in its base protocol.
		if (ascii::strcasecmp(name, "Content-Length") != 0) continue;
		const value = strings::trim(strings::sub(line, colon + 1, strings::end));
		match (strconv::stoz(value)) {
		case let n: size =>
			return n;
		case =>
			return;
		};
	};
};

fn do_init(s: *session) void = {
	send(s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(s, 1.0));
	send(s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));
};

fn do_init_with_workspace(s: *session, root: str) void = {
	const msg =
		strings::concat(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":"file://`,
			root, `","workspaceFolders":[{"uri":"file://`, root,
			`","name":"e2e"}],"capabilities":{}}}`)!;
	defer free(msg);
	send(s, strings::toutf8(msg));
	free(wait_for_response(s, 1.0));
	send(s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));
};

// Initializes without a workspace folder (so no background indexing
// fires) but advertising workspace.diagnostics.refreshSupport, the
// capability the server gates server-initiated
// workspace/diagnostic/refresh on. Lets a test observe a save-triggered
// refresh without an indexing-triggered one racing it.
fn do_init_refresh_support(s: *session) void = {
	send(s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{"workspace":{"diagnostics":{"refreshSupport":true}}}}}`
		));
	free(wait_for_response(s, 1.0));
	send(s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));
};

fn open_doc(s: *session, uri: str, body: str) void = {
	const msg = build_did_open(uri, body);
	defer free(msg);
	send(s, strings::toutf8(msg));
};

// Builds a textDocument/didOpen notification body. Caller frees.
//
// `body` is JSON-encoded with `json::dumpstr`, so multi-byte runes and
// any control characters round-trip correctly. The earlier hand-rolled
// ASCII-only quoter would silently corrupt anything outside that subset.
fn build_did_open(uri: str, body: str) str = {
	const text_json = json::dumpstr(body);
	defer free(text_json);
	return strings::concat(
		`{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"`,
		uri, `","languageId":"hare","version":1,"text":`, text_json, `}}}`)!;
};

// Builds a textDocument/didChange notification that replaces the whole
// document (single full-text content change). `body` is JSON-encoded so
// multi-byte runes round-trip. Caller frees.
fn build_did_change_full(uri: str, version: int, body: str) str = {
	const text_json = json::dumpstr(body);
	defer free(text_json);
	const ver = f64_to_int_str(version: f64);
	defer free(ver);
	return strings::concat(
		`{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"`,
		uri, `","version":`, ver, `},"contentChanges":[{"text":`, text_json,
		`}]}}`)!;
};

fn wait_for_response(s: *session, id: f64) []u8 = {
	for (true) {
		const body = recv(s);
		const text = strings::fromutf8(body)!;
		let v = json::loadstr(text)!;
		const matched = match (v) {
		case let obj: json::object =>
			yield match (json::get(&obj, "method")) {
			case *json::value =>
				yield false;
			case void =>
				yield match (json::get(&obj, "id")) {
				case let p: *json::value =>
					yield match (*p) {
					case let n: f64 =>
						yield n == id;
					case =>
						yield false;
					};
				case void =>
					yield false;
				};
			};
		case =>
			yield false;
		};
		json::finish(v);
		if (matched) return body;
		free(body);
	};
};

fn wait_for_publish_diagnostics(s: *session, uri: str) []u8 = {
	for (let i = 0z; i < 50z; i += 1) {
		const body = recv(s);
		const text = strings::fromutf8(body)!;
		if (strings::contains(text, `"method":"textDocument/publishDiagnostics"`)
				&& strings::contains(text, uri)) {
			return body;
		};
		free(body);
	};
	fmt::fatalf("e2e: never received publishDiagnostics for {}", uri);
};

// Drains frames until one carries the given JSON-RPC method (request or
// notification), returning its raw body. Caller frees.
fn wait_for_server_method(s: *session, method: str) []u8 = {
	const needle = strings::concat(`"method":"`, method, `"`)!;
	defer free(needle);
	for (let i = 0z; i < 50z; i += 1) {
		const body = recv(s);
		const text = strings::fromutf8(body)!;
		if (strings::contains(text, needle)) {
			return body;
		};
		free(body);
	};
	fmt::fatalf("e2e: never received a server message with method {}", method);
};

fn parse_publish_diagnostics(body: []u8) (json::value, []json::value) = {
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	const obj = v as json::object;
	const params = *(json::get(&obj, "params") as *json::value) as json::object;
	const diags =
		*(json::get(&params, "diagnostics") as *json::value) as []json::value;
	return (v, diags);
};

fn drain_until_indexed(s: *session) void = {
	for (let i = 0z; i < 20z; i += 1) {
		const body = recv(s);
		defer free(body);
		const text = strings::fromutf8(body)!;
		if (strings::contains(text, "indexed")
				&& strings::contains(text, "file(s)")) return;
	};
	fmt::fatalf("e2e: workspace indexing did not complete within 20 messages");
};

fn drain_until_indexed_ref(s: *session) void = {
	for (let i = 0z; i < 20z; i += 1) {
		const body = recv(s);
		defer free(body);
		const text = strings::fromutf8(body)!;
		if (strings::contains(text, "indexed")
				&& strings::contains(text, "file(s)")) return;
	};
};

fn field(obj: *json::object, key: str) json::value = {
	match (json::get(obj, key)) {
	case let p: *json::value =>
		return *p;
	case void =>
		fmt::fatalf("e2e: missing required field {}", key);
	};
};

fn has_field(obj: *json::object, key: str) bool = {
	match (json::get(obj, key)) {
	case *json::value =>
		return true;
	case void =>
		return false;
	};
};

fn field_object(obj: *json::object, key: str) json::object = {
	match (field(obj, key)) {
	case let o: json::object =>
		return o;
	case =>
		fmt::fatalf("e2e: field `{}` is not an object", key);
	};
};

fn field_array(obj: *json::object, key: str) []json::value = {
	match (field(obj, key)) {
	case let a: []json::value =>
		return a;
	case =>
		fmt::fatalf("e2e: field `{}` is not an array", key);
	};
};

fn field_string(obj: *json::object, key: str) str = {
	match (field(obj, key)) {
	case let s: str =>
		return s;
	case =>
		fmt::fatalf("e2e: field `{}` is not a string", key);
	};
};

fn field_number(obj: *json::object, key: str) f64 = {
	match (field(obj, key)) {
	case let n: f64 =>
		return n;
	case =>
		fmt::fatalf("e2e: field `{}` is not a number", key);
	};
};

fn make_workspace(label: str, files: [](str, str)) str = {
	const cwd = os::getcwd();
	const root = strings::concat(cwd, "/.tmp/e2e-", label)!;
	cleanup_workspace(root);
	match (os::mkdirs(root, 0o755: fs::mode)) {
	case void => void;
	case let e: fs::error =>
		fmt::fatalf("e2e: cannot mkdir {}: {}", root, fs::strerror(e));
	};
	for (let i = 0z; i < len(files); i += 1) {
		const rel = files[i].0;
		const body = files[i].1;
		const full_path = strings::concat(root, "/", rel)!;
		defer free(full_path);
		match (strings::rindex(rel, '/')) {
		case let idx: size =>
			const dir_rel = strings::sub(rel, 0, idx);
			const full_dir = strings::concat(root, "/", dir_rel)!;
			defer free(full_dir);
			match (os::mkdirs(full_dir, 0o755: fs::mode)) {
			case void => void;
			case let e: fs::error =>
				fmt::fatalf("e2e: cannot mkdir {}: {}", full_dir, fs::strerror(e));
			};
		case void => void;
		};
		write_test_file(full_path, body);
	};
	return root;
};

fn cleanup_workspace(root: str) void = {
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

fn f64_to_int_str(v: f64) str = {
	const n = v: i64;
	let buf: [21]u8 = [0...];
	let i = len(buf);
	let val = if (n < 0) -n else n;
	if (val == 0) {
		i -= 1;
		buf[i] = '0': u8;
	};
	for (val > 0; val /= 10) {
		i -= 1;
		buf[i] = '0': u8 + (val % 10): u8;
	};
	if (n < 0) {
		i -= 1;
		buf[i] = '-': u8;
	};
	return strings::dup(strings::fromutf8(buf[i..])!)!;
};
