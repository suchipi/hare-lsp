// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// End-to-end test harness: spawns the actual `./hare-lsp` binary with pipes
// on stdin and stdout, exchanges framed JSON-RPC messages, and tears the
// process down at the end of the test.
//
// These tests guard against regressions that unit tests can't catch — most
// notably anything tied to the real `os::stdout` (which is a buffered handle
// and historically caused the server to never flush its initialize response
// to a long-lived client). See `cmd/hare-lsp/main.ha` for context.
//
// Tests require ./hare-lsp to exist at the repo root. The Makefile's
// `test-e2e` target builds it first.

use encoding::json;
use fmt;
use io;
use os;
use os::exec;
use strconv;
use strings;
use time;
use unix::poll;
use unix::signal;

// Path to the binary under test, resolved relative to the test's working
// directory (which is the repo root when invoked via `make test-e2e`).
def BIN_PATH: str = "./hare-lsp";

// Default deadline for any single recv. The server should respond within
// milliseconds on a healthy machine; 5 seconds is generous and still much
// faster than vscode-languageclient's own init timeout, so a regression
// will surface here rather than in the editor.
def RECV_TIMEOUT: time::duration = 5 * time::SECOND;

// Handles for an in-flight server process plus the pipes used to talk to it.
export type session = struct {
	proc: exec::process,
	stdin: io::file,
	stdout: io::file,
	// Bytes read from `stdout` that don't belong to the frame the
	// caller asked for yet. Each `recv` call drains as much of this
	// as it needs, then reads more from the pipe to complete the
	// frame; leftover bytes after the frame are kept here for the
	// next call. Without this carry-over, two frames coalescing into
	// a single `read` (which happens at random under OS-scheduling
	// pressure) would silently drop the second frame and the next
	// `recv` would block forever waiting for bytes that already
	// arrived.
	read_buf: []u8,
};

// Spawns the server binary with anonymous pipes on stdin and stdout. The
// child's stderr is inherited from the parent so server-side diagnostics
// show up in `hare test` output.
fn spawn_session() session = {
	const (in_r, in_w) = exec::pipe();
	const (out_r, out_w) = exec::pipe();

	let cmd = match (exec::cmd(BIN_PATH)) {
	case let c: exec::command =>
		yield c;
	case let e: exec::error =>
		fmt::fatalf("e2e: cannot prepare {}: {} (is the binary built? run `make`)",
			BIN_PATH, exec::strerror(e));
	case nomem =>
		abort("e2e: out of memory preparing command");
	};

	exec::addfile(&cmd, os::stdin_file, in_r)!;
	exec::addfile(&cmd, os::stdout_file, out_w)!;

	const proc = match (exec::start(&cmd)) {
	case let p: exec::process =>
		yield p;
	case let e: exec::error =>
		fmt::fatalf("e2e: cannot start server: {}", exec::strerror(e));
	};

	// In the parent, close the ends owned by the child.
	io::close(in_r)!;
	io::close(out_w)!;

	return session {
		proc = proc,
		stdin = in_w,
		stdout = out_r,
		read_buf = [],
	};
};

// Closes the pipes and reaps the child. Sends SIGTERM if it's still running.
// Safe to call multiple times on the same session in a defer chain — second
// call is a no-op because the pipes are already closed.
fn finish_session(s: *session) void = {
	defer {
		free(s.read_buf);
		s.read_buf = [];
	};
	// Closing stdin signals EOF to the server, which causes its read loop
	// to return EXIT_ERROR (per its own semantics). Most tests should do
	// a clean shutdown/exit before reaching this, but we tolerate either.
	const _ = io::close(s.stdin);
	const _ = io::close(s.stdout);

	// Give the process a brief moment to exit on its own. If it's still
	// running, send SIGTERM, then SIGKILL as a last resort.
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
		if (time::compare(time::now(time::clock::MONOTONIC),
				deadline) >= 0) {
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

// Writes a single framed LSP message. The body must already be valid JSON.
fn send(s: *session, body: const []u8) void = {
	let header_buf: [64]u8 = [0...];
	const header = fmt::bsprintf(header_buf,
		"Content-Length: {}\r\n\r\n", len(body))!;
	io::writeall(s.stdin, strings::toutf8(header))!;
	io::writeall(s.stdin, body)!;
};

// Reads a single framed LSP message from the server, failing the test if no
// complete frame is received within RECV_TIMEOUT. The returned slice is owned
// by the caller and must be freed.
//
// Buffering: we operate on the session's persistent `read_buf` rather than
// a fresh slice per call. The server can write more than one frame's worth
// of bytes between our reads (the OS happily coalesces tightly-spaced
// writes into one pipe delivery), and a previous design that discarded
// `buf` on return silently dropped any bytes past the frame boundary.
// The next `recv` then blocked on a pipe that had no more bytes to give,
// because the response had already arrived and been thrown away.
fn recv(s: *session) []u8 = {
	const deadline = time::add(time::now(time::clock::MONOTONIC),
		RECV_TIMEOUT);
	let chunk: [4096]u8 = [0...];

	for (true) {
		// Try to extract a complete frame from whatever we've
		// already buffered before reading more from the pipe.
		match (try_take_frame(&s.read_buf)) {
		case let body: []u8 =>
			return body;
		case void => void;
		};

		const now = time::now(time::clock::MONOTONIC);
		if (time::compare(now, deadline) >= 0) {
			fmt::fatalf("e2e: recv timed out after {} ms (buffered {} bytes)",
				RECV_TIMEOUT / time::MILLISECOND,
				len(s.read_buf));
		};
		const remaining_ns = time::diff(now, deadline);

		let pfd: [_]poll::pollfd = [poll::pollfd {
			fd = s.stdout,
			events = poll::event::POLLIN,
			revents = 0,
		}];
		const ready = match (poll::poll(pfd, remaining_ns)) {
		case let n: uint =>
			yield n;
		case poll::error =>
			abort("e2e: poll failed");
		};
		if (ready == 0) {
			continue; // loop checks deadline at top
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

// Pulls one complete LSP frame off the front of `buf` if one is present,
// shifting the remaining bytes (the next frame's prefix, if any) to the
// start of the slice. Returns void when the buffer doesn't yet contain
// a complete frame. The returned slice is owned by the caller.
fn try_take_frame(buf: *[]u8) ([]u8 | void) = {
	const (body_off, body_len) = match (parse_header(*buf)) {
	case let p: (size, size) => yield p;
	case void => return void;
	};
	const frame_end = body_off + body_len;
	if (len(*buf) < frame_end) return void;

	let out: []u8 = alloc([0...], body_len)!;
	out[..] = (*buf)[body_off..frame_end];

	// Shift any bytes past the frame down to the start of buf.
	const leftover = len(*buf) - frame_end;
	if (leftover > 0) {
		for (let i = 0z; i < leftover; i += 1) {
			(*buf)[i] = (*buf)[frame_end + i];
		};
	};
	*buf = (*buf)[..leftover];
	return out;
};

// Looks for the end of the LSP header block ("\r\n\r\n") in `buf`. If found,
// parses the Content-Length value and returns (body_offset, body_length).
// Returns void when the headers haven't all arrived yet.
fn parse_header(buf: []u8) ((size, size) | void) = {
	const needle: []u8 = ['\r', '\n', '\r', '\n'];
	if (len(buf) < len(needle)) return;
	let end: size = 0;
	let found = false;
	for (let i = 0z; i + len(needle) <= len(buf); i += 1) {
		if (buf[i] == needle[0] && buf[i + 1] == needle[1]
				&& buf[i + 2] == needle[2]
				&& buf[i + 3] == needle[3]) {
			end = i;
			found = true;
			break;
		};
	};
	if (!found) return;

	const headers = match (strings::fromutf8(buf[..end])) {
	case let s: str =>
		yield s;
	case =>
		abort("e2e: server emitted non-UTF-8 headers");
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
		// The server always emits this casing — keep the compare exact
		// so we don't pull in extra string utilities for the test path.
		if (name != "Content-Length") continue;
		const value = strings::trim(strings::sub(line, colon + 1,
			strings::end));
		match (strconv::stoz(value)) {
		case let n: size =>
			return n;
		case =>
			return;
		};
	};
};

// Sends a minimal `initialize` request with id=1 and waits for the
// response, then sends `initialized`. Most e2e tests don't care about
// the response body, so the bytes are discarded.
fn do_init(s: *session) void = {
	send(s, strings::toutf8(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`));
	free(wait_for_response(s, 1.0));
	send(s, strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));
};

// Sends a textDocument/didOpen for the given URI with the given body.
fn open_doc(s: *session, uri: str, body: str) void = {
	const msg = build_did_open(uri, body);
	defer free(msg);
	send(s, strings::toutf8(msg));
};
