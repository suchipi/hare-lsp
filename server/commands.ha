// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// workspace/executeCommand dispatcher. Runs hare commands synchronously
// and streams stdout/stderr back to the client via window/logMessage.

use encoding::json;
use io;
use lsp;
use os;
use os::exec;
use strings;
use unix;
use unix::poll;

// @param s: borrowed
export fn handle_execute_command(s: *server, r: lsp::request) void = {
	const obj = match (params_obj_xc(r.params)) {
	case let o: json::object =>
		yield o;
	case void =>
		send_null_result(s, r.id);
		return;
	};
	const command = match (json::get(&obj, "command")) {
	case let p: *json::value =>
		yield match (*p) {
		case let s: str =>
			yield s;
		case =>
			send_null_result(s, r.id);
			return;
		};
	case =>
		send_null_result(s, r.id);
		return;
	};
	const args = match (json::get(&obj, "arguments")) {
	case let p: *json::value =>
		yield match (*p) {
		case let a: []json::value =>
			yield a;
		case =>
			yield []: []json::value;
		};
	case =>
		yield []: []json::value;
	};

	switch (command) {
	case "hare-lsp.runTest" =>
		execute_run_test(s, r, args);
	case "hare-lsp.runModule" =>
		execute_run_module(s, r, args);
	case "hare-lsp.organizeImports" =>
		send_null_result(s, r.id);
	case "hare-lsp.applyAutoImport" =>
		send_null_result(s, r.id);
	case =>
		send_error(s, r.id, lsp::METHOD_NOT_FOUND, "unknown command");
	};
};

// @param s: borrowed
// @param args: borrowed
fn execute_run_test(s: *server, r: lsp::request, args: []json::value) void = {
	const uri = match (first_arg_str(args)) {
	case let s: str =>
		yield s;
	case void =>
		send_null_result(s, r.id);
		return;
	};
	const path = uri_to_path_xc(uri);
	defer free(path);
	const dir = dirname_xc(path);
	const cwd = spawn_cwd_for_path(s, path);
	defer free(cwd);
	// `hare test <path> [test...]`. Path is always passed (absolute so
	// it works regardless of cwd) so we only test the file's module;
	// without it `hare test` would recursively test everything under
	// the workspace root. An optional 2nd argument is a test-name
	// filter that restricts to a single @test.
	let extra: []str = [];
	defer free(extra);
	append(extra, dir)!;
	if (len(args) >= 2) {
		match (args[1]) {
		case let name: str =>
			append(extra, name)!;
		case => void;
		};
	};
	run_hare_command(s, "test", cwd, extra);
	send_null_result(s, r.id);
};

// @param s: borrowed
// @param args: borrowed
fn execute_run_module(s: *server, r: lsp::request, args: []json::value) void = {
	const uri = match (first_arg_str(args)) {
	case let s: str =>
		yield s;
	case void =>
		send_null_result(s, r.id);
		return;
	};
	const path = uri_to_path_xc(uri);
	defer free(path);
	const dir = dirname_xc(path);
	const cwd = spawn_cwd_for_path(s, path);
	defer free(cwd);
	let extra: []str = [];
	defer free(extra);
	append(extra, dir)!;
	run_hare_command(s, "run", cwd, extra);
	send_null_result(s, r.id);
};

// Runs `<config.hare_path> <subcmd> [args...]` in the given directory and
// streams the output through window/logMessage. The cwd should be a
// workspace root so a relative `HARECACHE` doesn't pollute random
// directories. An empty `dir` leaves the child in our own cwd.
// Synchronous.
//
// @param s: borrowed
// @param subcmd: borrowed
// @param dir: borrowed
// @param extra: borrowed
fn run_hare_command(s: *server, subcmd: str, dir: str, extra: []str) void = {
	let argv: []str = [];
	defer free(argv);
	append(argv, subcmd)!;
	// Forward `hare.tags` as `-T <tag>` pairs so file selection in the
	// spawned `hare test` / `hare run` matches the user's diagnostics
	// build (see run_build_obj in dep_build.ha).
	for (let i = 0z; i < len(s.config.tags); i += 1) {
		append(argv, "-T")!;
		append(argv, s.config.tags[i])!;
	};
	for (let i = 0z; i < len(extra); i += 1) {
		append(argv, extra[i])!;
	};
	// Grow a pipe for the child's stderr.
	const pipe_pair = match (unix::pipe()) {
	case let p: (io::file, io::file) =>
		yield p;
	case =>
		log_error(s, "failed to create pipe for hare command");
		return;
	};
	const (read_fd, write_fd) = pipe_pair;

	let cmd = match (exec::cmd(s.config.hare_path, argv...)) {
	case let c: exec::command =>
		yield c;
	case =>
		lsp::safe_close(read_fd);
		lsp::safe_close(write_fd);
		log_error(s, "failed to spawn hare command");
		return;
	};
	if (len(dir) > 0) {
		exec::chdir(&cmd, dir);
	};
	// Mirror the HAREPATH the server uses for `hare build` diagnostics
	// so "Run test" / "Run program" resolve `use` declarations through
	// the same search path the user configured via `hare.harepath`.
	const harepath = server_harepath_for(s);
	defer free(harepath);
	if (len(harepath) > 0) {
		match (exec::setenv(&cmd, "HAREPATH", harepath)) {
		case => void;
		};
	};
	exec::addfile(&cmd, os::stderr_file, write_fd)!;
	exec::addfile(&cmd, os::stdout_file, write_fd)!;
	exec::addfile(&cmd, os::stdin_file, exec::nullfd)!;

	const proc = match (exec::start(&cmd)) {
	case let p: exec::process =>
		yield p;
	case =>
		lsp::safe_close(read_fd);
		lsp::safe_close(write_fd);
		log_error(s, "failed to start hare command");
		return;
	};
	lsp::safe_close(write_fd);

	// Stream output via an indefinite poll loop. Unlike the build path,
	// runTest / runModule run user code that may legitimately take
	// arbitrarily long; the user invokes them explicitly, so we wait
	// until the process exits naturally.
	let buf: []u8 = [];
	defer free(buf);
	let chunk: [4096]u8 = [0...];
	for (true) {
		let pfds: [1]poll::pollfd = [
			poll::pollfd {
				fd = read_fd,
				events = poll::event::POLLIN: i16,
				revents = 0,
			},
		];
		const n = match (poll::poll(pfds[..], poll::INDEF)) {
		case let n: uint =>
			yield n;
		case poll::error =>
			break;
		};
		if (n == 0) break;
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

// @param args: borrowed
// @returns: borrowed from args
fn first_arg_str(args: []json::value) (str | void) = {
	if (len(args) == 0) return void;
	match (args[0]) {
	case let s: str =>
		return s;
	case =>
		return void;
	};
};

// @param uri: borrowed
// @returns: owned
fn uri_to_path_xc(uri: str) str = lsp::uri_decode_path(uri);

// @param path: borrowed
// @returns: borrowed from path
fn dirname_xc(path: str) str = {
	const idx = strings::rindex(path, '/');
	match (idx) {
	case let i: size =>
		return strings::sub(path, 0, i);
	case void =>
		return "";
	};
};

// @param p: borrowed
fn params_obj_xc(
	p: (json::value | void),
) (json::object | void) = lsp::params_object(p);
