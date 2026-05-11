// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use bufio;
use fs;
use io;
use os;
use server;
use strings;

export fn main() void = {
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
	case void => yield "";
	};
	const in_log = open_log_in_dir(log_dir, "hare-lsp-in.log");
	const out_log = open_log_in_dir(log_dir, "hare-lsp-out.log");
	const err_log = open_log_in_dir(log_dir, "hare-lsp-err.log");
	defer match (in_log) {
	case let f: io::file => io::close(f)!;
	case void => void;
	};
	defer match (out_log) {
	case let f: io::file => io::close(f)!;
	case void => void;
	};
	defer match (err_log) {
	case let f: io::file => io::close(f)!;
	case void => void;
	};

	let in_tee = match (in_log) {
	case let f: io::file => yield io::tee(os::stdin, f);
	case void => yield io::tee(os::stdin, io::empty);
	};
	let out_tee = match (out_log) {
	case let f: io::file => yield io::tee(os::stdout_file, f);
	case void => yield io::tee(os::stdout_file, io::empty);
	};
	let err_tee = match (err_log) {
	case let f: io::file => yield io::tee(os::stderr, f);
	case void => yield io::tee(os::stderr, io::empty);
	};
	const in_handle: io::handle = if (in_log is io::file)
		&in_tee: io::handle else os::stdin;
	const out_handle: io::handle = if (out_log is io::file)
		&out_tee: io::handle else os::stdout_file;
	if (err_log is io::file) {
		// Replace the process-wide stderr so the existing
		// `fmt::fprintln(os::stderr, ...)` call sites scattered
		// through the server tee to the log too, without needing
		// to thread the wrapped handle.
		os::stderr = &err_tee;
	};

	let scan = bufio::newscanner(in_handle);
	defer bufio::finish(&scan);

	// Use the unbuffered stdout handle: vscode-languageclient and other
	// clients keep stdin open across requests, so the process never exits
	// to flush a buffered stdout — the response would sit in the 4 KiB
	// buffer indefinitely and the client would time out the handshake.
	// The e2e suite under e2e/ guards against re-introducing this bug.
	let s = server::new(&scan, out_handle);
	defer server::finish(&s);

	const code = server::run(&s);
	if (code != 0) {
		os::exit(code);
	};
};

// Opens (or truncates and creates) a per-session log file at
// `<dir>/<name>`. Returns void if `dir` is empty (logging disabled)
// or on any I/O error, so the LSP still starts even when the log
// directory isn't writable.
fn open_log_in_dir(dir: str, name: str) (io::file | void) = {
	if (len(dir) == 0) return;
	const path = strings::concat(dir, "/", name)!;
	defer free(path);
	match (os::create(path,
			0o644: fs::mode,
			fs::flag::WRONLY | fs::flag::TRUNC)) {
	case let f: io::file =>
		return f;
	case fs::error =>
		return;
	};
};
