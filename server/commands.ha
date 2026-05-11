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
use unix;

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
	run_hare_command(s, "test", dir, []);
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

	// Stream output.
	let buf: []u8 = [];
	defer free(buf);
	let chunk: [4096]u8 = [0...];
	for (true) {
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

	// Send the output to the client.
	const output = strings::fromutf8(buf)!;
	if (len(output) > 0) {
		log_info(s, output);
	};
};

fn first_arg_str(args: []json::value) (str | void) = {
	if (len(args) == 0) return void;
	match (args[0]) {
	case let s: str => return s;
	case => return void;
	};
};

fn uri_to_path_xc(uri: str) str = {
	const prefix = "file://";
	if (strings::hasprefix(uri, prefix)) {
		return strings::dup(strings::sub(uri, len(prefix), strings::end))!;
	};
	return strings::dup(uri)!;
};

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
