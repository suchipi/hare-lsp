// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use bufio;
use fmt;
use fs;
use io;
use os;
use server;
use strconv;
use strings;

// Version string. Kept in sync with the `serverInfo.version` value
// returned from `initialize` (see server/server.ha).
def VERSION: str = "0.0.1";

export fn main() void = {
	// Handle one-shot CLI subcommands before doing any LSP setup.
	// `os::args[0]` is the binary name; anything from index 1 is a flag.
	if (len(os::args) >= 2) {
		const arg = os::args[1];
		if (arg == "--doctor") {
			os::exit(run_doctor());
		};
		if (arg == "--help" || arg == "-h") {
			print_usage();
			os::exit(0);
		};
		if (arg == "--version" || arg == "-V") {
			fmt::printfln("hare-lsp {}", VERSION)!;
			os::exit(0);
		};
		fmt::fprintfln(os::stderr, "unknown argument: {}", arg)!;
		fmt::fprintln(os::stderr, "run `hare-lsp --help` for usage")!;
		os::exit(2);
	};

	// Optional wire-protocol log. When `HARE_LSP_LOG_DIR` is set in
	// the environment, we tee everything we read from the client
	// into `$HARE_LSP_LOG_DIR/hare-lsp-in.log`, everything we
	// write back into `…-out.log`, and stderr into `…-err.log`.
	// This is the easiest way to see what VS Code is actually
	// exchanging with the server: `tail -f` either file shows
	// messages as they flow.
	//
	// The env-var indirection exists because vscode-languageclient
	// spawns the server with cwd=`/`, so a relative `.tmp/` would
	// land at `/.tmp/` (unwritable). Set the var to an absolute
	// path you can write to. All three logs are truncated at
	// startup so each session begins clean. Without the env var,
	// no logging happens.
	const log_dir = match (os::getenv("HARE_LSP_LOG_DIR")) {
	case let s: str =>
		yield if (len(s) == 0) "" else s;
	case void =>
		yield "";
	};
	const in_log = open_log_in_dir(log_dir, "hare-lsp-in.log");
	const out_log = open_log_in_dir(log_dir, "hare-lsp-out.log");
	const err_log = open_log_in_dir(log_dir, "hare-lsp-err.log");
	defer match (in_log) {
	case let f: io::file =>
		io::close(f)!;
	case void => void;
	};
	defer match (out_log) {
	case let f: io::file =>
		io::close(f)!;
	case void => void;
	};
	defer match (err_log) {
	case let f: io::file =>
		io::close(f)!;
	case void => void;
	};

	let in_tee = match (in_log) {
	case let f: io::file =>
		yield io::tee(os::stdin, f);
	case void =>
		yield io::tee(os::stdin, io::empty);
	};
	let out_tee = match (out_log) {
	case let f: io::file =>
		yield io::tee(os::stdout_file, f);
	case void =>
		yield io::tee(os::stdout_file, io::empty);
	};
	let err_tee = match (err_log) {
	case let f: io::file =>
		yield io::tee(os::stderr, f);
	case void =>
		yield io::tee(os::stderr, io::empty);
	};
	const in_handle: io::handle = if (in_log is io::file) &in_tee: io::handle
		else os::stdin;
	const out_handle: io::handle = if (out_log is io::file) &out_tee: io::handle
		else os::stdout_file;
	if (err_log is io::file) {
		// Replace the process-wide stderr so structured log lines
		// written by `server::slog_*` (and any direct os::stderr
		// callers we haven't migrated) tee into the log file as
		// well, without needing to thread the wrapped handle
		// through every layer.
		os::stderr = &err_tee;
	};

	let scan = bufio::newscanner(in_handle);
	defer bufio::finish(&scan);

	// Use the unbuffered stdout handle: vscode-languageclient and other
	// clients keep stdin open across requests, so the process never exits
	// to flush a buffered stdout — the response would sit in the 4 KiB
	// buffer indefinitely and the client would time out the handshake.
	// The e2e suite under e2e/ guards against re-introducing this bug.
	//
	// Body cap: defaults to 32 MiB; overridable via env var for clients
	// that send very large workspace edits. Must be set here because the
	// reader is constructed before `initialize` arrives.
	// Pass `os::stdin_file` (the unbuffered, pollable fd 0) so the
	// server can peek between background-indexing batches and advance
	// the workspace index while the client is silent. The wrapped tee
	// stream above is not pollable; the raw fd is.
	const max_body = read_max_body_env();
	let s = match (max_body) {
	case let n: size =>
		yield server::new_with_max_body(&scan, out_handle, os::stdin_file, n);
	case void =>
		yield server::new(&scan, out_handle, os::stdin_file);
	};
	defer server::finish(&s);

	const code = server::run(&s);
	if (code != 0) {
		os::exit(code);
	};
};

fn print_usage() void = {
	fmt::println("Usage: hare-lsp [OPTION]")!;
	fmt::println()!;
	fmt::println("With no arguments, runs the LSP server over stdio.")!;
	fmt::println()!;
	fmt::println("Options:")!;
	fmt::println(
		"  --doctor      Check that hare, hare-json, and "
		"HAREPATH look healthy.")!;
	fmt::println("  --version     Print the server version and exit.")!;
	fmt::println("  --help        Show this message and exit.")!;
	fmt::println()!;
	fmt::println("Environment:")!;
	fmt::println(
		"  HARE_LSP_LOG_DIR     Absolute directory to tee "
		"wire-protocol logs into.")!;
	fmt::println(
		"  HARE_LSP_LOG_LEVEL   debug|info|warn|error "
		"(default: info)")!;
};

// Reads HARE_LSP_MAX_BODY_BYTES if set. Returns void when unset or
// invalid; the server then falls back to the default body cap.
fn read_max_body_env() (size | void) = {
	const raw = match (os::getenv("HARE_LSP_MAX_BODY_BYTES")) {
	case let s: str =>
		if (len(s) == 0) return void;
		yield s;
	case void =>
		return void;
	};
	match (strconv::stoz(raw)) {
	case let n: size =>
		return n;
	case =>
		return void;
	};
};

// Opens (or truncates and creates) a per-session log file at
// `<dir>/<name>`. Returns void if `dir` is empty (logging disabled)
// or on any I/O error, so the LSP still starts even when the log
// directory isn't writable.
//
// @param dir: borrowed
// @param name: borrowed
fn open_log_in_dir(dir: str, name: str) (io::file | void) = {
	if (len(dir) == 0) return;
	const path = strings::concat(dir, "/", name)!;
	defer free(path);
	match (os::create(path, 0o644: fs::mode, fs::flag::WRONLY | fs::flag::TRUNC)) {
	case let f: io::file =>
		return f;
	case fs::error =>
		return;
	};
};
