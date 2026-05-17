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

def RECV_TIMEOUT: time::duration = 5 * time::SECOND;

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
	return strings::concat(`{"jsonrpc":"2.0","id":`, id_str, `,"method":"`, method,
		`","params":`, params_json, `}`)!;
};

fn make_notification(method: str, params_json: str) str = {
	return strings::concat(`{"jsonrpc":"2.0","method":"`, method, `","params":`,
		params_json, `}`)!;
};

fn finish_session(s: *session) void = {
	defer {
		free(s.read_buf);
		s.read_buf = [];
	};
	const _ = io::close(s.stdin);
	const _ = io::close(s.stdout);

	const deadline = time::add(time::now(time::clock::MONOTONIC),
		500 * time::MILLISECOND);
	for (true) {
		match (exec::peek(&s.proc)) {
		case let st: exec::status =>
			return;
		case void => void;
		case exec::error =>
			return;
		};
		if (time::compare(time::now(time::clock::MONOTONIC), deadline) >= 0) {
			break;
		};
		time::sleep(10 * time::MILLISECOND);
	};
	const _ = exec::sig(s.proc, signal::sig::TERM);
	time::sleep(100 * time::MILLISECOND);
	match (exec::peek(&s.proc)) {
	case let st: exec::status =>
		return;
	case (void | exec::error) =>
		const _ = exec::sig(s.proc, signal::sig::KILL);
		const _ = exec::wait(&s.proc);
	};
};

fn assert_clean_exit(s: *session, total: time::duration) void = {
	const deadline = time::add(time::now(time::clock::MONOTONIC), total);
	for (true) {
		let st = exec::peek(&s.proc);
		match (st) {
		case let st: exec::status =>
			match (exec::check(&st)) {
			case void =>
				return;
			case !exec::exit_status =>
				const summary = exec::exitstr(exec::exit(&st));
				fmt::fatalf("e2e: server exited uncleanly after `exit`: {}", summary);
			};
		case void => void;
		case exec::error => void;
		};
		if (time::compare(time::now(time::clock::MONOTONIC), deadline) >= 0) {
			fmt::fatalf("e2e: server did not exit within {} ms of `exit`",
				total / time::MILLISECOND);
		};
		time::sleep(20 * time::MILLISECOND);
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
	match (recv_with_deadline(s, RECV_TIMEOUT)) {
	case let b: []u8 =>
		return b;
	case void =>
		fmt::fatalf("e2e: recv timed out after {} ms (buffered {} bytes)",
			RECV_TIMEOUT / time::MILLISECOND, len(s.read_buf));
	};
};

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

		let pfd: [_]poll::pollfd = [
			poll::pollfd {
				fd = s.stdout,
				events = poll::event::POLLIN,
				revents = 0,
			},
		];
		const ready = match (poll::poll(pfd, remaining_ns)) {
		case let n: uint =>
			yield n;
		case poll::error => abort("e2e: poll failed");
		};
		if (ready == 0) {
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
		if (s.read_buf[i] == needle[0] && s.read_buf[i + 1] == needle[1] &&
				s.read_buf[i + 2] == needle[2] &&
				s.read_buf[i + 3] == needle[3]) {
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
		if (strings::contains(text, `"method":"textDocument/publishDiagnostics"`) &&
				strings::contains(text, uri)) {
			return body;
		};
		free(body);
	};
	fmt::fatalf("e2e: never received publishDiagnostics for {}", uri);
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
		if (strings::contains(text, "indexed") &&
				strings::contains(text, "file(s)")) return;
	};
	fmt::fatalf("e2e: workspace indexing did not complete within 20 messages");
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
