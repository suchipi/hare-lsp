// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// workspace/executeCommand dispatcher. Runs hare commands synchronously
// and streams stdout/stderr back to the client via window/logMessage.

use bufio;
use encoding::json;
use io;
use lsp;
use os;
use os::exec;
use strings;
use time;
use unix;
use unix::poll;
use unix::signal;

export fn handle_execute_command(s: *server, r: lsp::request) void = {
	const obj = match (params_obj_xc(r.params)) {
	case let o: json::object => yield o;
	case void =>
		send_null_xc(s, r.id);
		return;
	};
	const command = match (json::get(&obj, "command")) {
	case let p: *json::value =>
		yield match (*p) {
		case let s: str => yield s;
		case =>
			send_null_xc(s, r.id);
			return;
		};
	case =>
		send_null_xc(s, r.id);
		return;
	};
	const args = match (json::get(&obj, "arguments")) {
	case let p: *json::value =>
		yield match (*p) {
		case let a: []json::value => yield a;
		case => yield ([]: []json::value);
		};
	case => yield ([]: []json::value);
	};

	switch (command) {
	case "hare-lsp.runTest" =>
		execute_run_test(s, r, args);
	case "hare-lsp.runModule" =>
		execute_run_module(s, r, args);
	case "hare-lsp.organizeImports" =>
		send_null_xc(s, r.id);
	case "hare-lsp.applyAutoImport" =>
		send_null_xc(s, r.id);
	case =>
		send_error(s, r.id, lsp::METHOD_NOT_FOUND,
			"unknown command");
	};
};

fn execute_run_test(s: *server, r: lsp::request, args: []json::value) void = {
	const uri = match (first_arg_str(args)) {
	case let s: str => yield s;
	case void =>
		send_null_xc(s, r.id);
		return;
	};
	const path = uri_to_path_xc(uri);
	defer free(path);
	const dir = dirname_xc(path);
	// Optional 2nd argument: the test function name. When present
	// pass it as a `[path] [test]` filter to `hare test` so only the
	// matching @test runs.
	let extra: []str = [];
	defer free(extra);
	if (len(args) >= 2) {
		match (args[1]) {
		case let name: str =>
			// `hare test <path> <test...>` — the directory is the
			// path arg; the test name is the glob. We chdir'd to
			// `dir` already so pass "." as the path.
			append(extra, ".")!;
			append(extra, name)!;
		case => void;
		};
	};
	run_hare_command(s, "test", dir, extra);
	send_null_xc(s, r.id);
};

fn execute_run_module(s: *server, r: lsp::request, args: []json::value) void = {
	const uri = match (first_arg_str(args)) {
	case let s: str => yield s;
	case void =>
		send_null_xc(s, r.id);
		return;
	};
	const path = uri_to_path_xc(uri);
	defer free(path);
	const dir = dirname_xc(path);
	run_hare_command(s, "run", dir, []);
	send_null_xc(s, r.id);
};

// Runs `<config.hare_path> <subcmd> [args...]` in the given directory and
// streams the output through window/logMessage. Synchronous.
fn run_hare_command(s: *server, subcmd: str, dir: str, extra: []str) void = {
	let argv: []str = [];
	defer free(argv);
	append(argv, subcmd)!;
	for (let i = 0z; i < len(extra); i += 1) {
		append(argv, extra[i])!;
	};
	// Grow a pipe for the child's stderr.
	const pipe_pair = match (unix::pipe()) {
	case let p: (io::file, io::file) => yield p;
	case =>
		log_error(s, "failed to create pipe for hare command");
		return;
	};
	const (read_fd, write_fd) = pipe_pair;

	let cmd = match (exec::cmd(s.config.hare_path, argv...)) {
	case let c: exec::command => yield c;
	case =>
		lsp::safe_close(read_fd);
		lsp::safe_close(write_fd);
		log_error(s, "failed to spawn hare command");
		return;
	};
	if (len(dir) > 0) {
		exec::chdir(&cmd, dir);
	};
	exec::addfile(&cmd, os::stderr_file, write_fd)!;
	exec::addfile(&cmd, os::stdout_file, write_fd)!;
	exec::addfile(&cmd, os::stdin_file, exec::nullfd)!;

	const proc = match (exec::start(&cmd)) {
	case let p: exec::process => yield p;
	case =>
		lsp::safe_close(read_fd);
		lsp::safe_close(write_fd);
		log_error(s, "failed to start hare command");
		return;
	};
	lsp::safe_close(write_fd);

	// Stream output via a deadline-bounded poll loop. Same shape as
	// run_build's drain in build.ha — see there for rationale. A hung
	// `hare test` won't freeze the LSP main loop.
	let buf: []u8 = [];
	defer free(buf);
	let chunk: [4096]u8 = [0...];
	const timeout_ms = s.config.build_timeout_ms;
	const deadline_abs = if (timeout_ms > 0) {
		yield time::add(time::now(time::clock::MONOTONIC),
			(timeout_ms: i64) * time::MILLISECOND);
	} else {
		yield time::instant { sec = 0, nsec = 0 };
	};
	let timed_out = false;
	for (true) {
		const remaining: time::duration = if (timeout_ms == 0) {
			yield poll::INDEF;
		} else {
			const now = time::now(time::clock::MONOTONIC);
			yield time::diff(now, deadline_abs);
		};
		if (timeout_ms > 0 && remaining <= 0) {
			timed_out = true;
			break;
		};
		let pfds: [1]poll::pollfd = [poll::pollfd {
			fd = read_fd,
			events = poll::event::POLLIN: i16,
			revents = 0,
		}];
		const n = match (poll::poll(pfds[..], remaining)) {
		case let n: uint => yield n;
		case poll::error => break;
		};
		if (n == 0) {
			timed_out = true;
			break;
		};
		match (io::read(read_fd, chunk[..])) {
		case let n: size =>
			append(buf, chunk[..n]...)!;
		case io::EOF =>
			break;
		case io::error =>
			break;
		};
	};
	lsp::safe_close(read_fd);
	if (timed_out) {
		match (exec::sig(proc, signal::sig::TERM)) {
		case => void;
		};
		log_warning(s, "hare command timed out and was terminated");
	};
	match (exec::wait(&proc)) {
	case => void;
	};

	// Send the output to the client. Tag-prefixed so users searching
	// their "Output" panel can tell what produced the lines.
	const output = strings::fromutf8(buf)!;
	if (len(output) > 0) {
		const tagged = strings::concat("[hare ", subcmd, "] ", output)!;
		defer free(tagged);
		log_info(s, tagged);
	};
};

fn first_arg_str(args: []json::value) (str | void) = {
	if (len(args) == 0) return void;
	match (args[0]) {
	case let s: str => return s;
	case => return void;
	};
};

fn uri_to_path_xc(uri: str) str = lsp::uri_decode_path(uri);

fn dirname_xc(path: str) str = {
	const idx = strings::rindex(path, '/');
	match (idx) {
	case let i: size =>
		return strings::sub(path, 0, i);
	case void =>
		return "";
	};
};

fn params_obj_xc(p: (json::value | void)) (json::object | void) =
	lsp::params_object(p);

fn send_null_xc(s: *server, id: lsp::id) void = {
	const v: json::value = json::_null;
	match (lsp::encode_response_result(s.out, id, v)) {
	case size => void;
	case => void;
	};
};
