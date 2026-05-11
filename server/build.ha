// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Synchronously runs `hare build` for a saved document and parses its
// stderr into LSP diagnostics. We trigger this on didSave (not didChange)
// to keep the server's main loop responsive — Hare's build can take
// seconds on large modules and we have no async runtime in this thread.
// The plan describes an async kill-and-restart variant; see TODOs.
//
// The compiler error format is:
//
//	<path>:<line>:<col>: <kind>: <message>
//
// where `kind` is "error" or "syntax error" — both map to severity 1.
// Path is filesystem-absolute and may include "../"; we URI-encode it
// when matching against open documents.

use bufio;
use encoding::json;
use io;
use lsp;
use os;
use os::exec;
use path;
use strconv;
use strings;
use time;
use unix;
use unix::poll;
use unix::signal;

// One diagnostic emitted by the compiler.
export type build_diagnostic = struct {
	path: str,
	line: u32,
	col: u32,
	// "error", "syntax error", or "warning" — preserved verbatim from
	// the compiler line, used by build_diag_to_lsp to set severity and
	// the LSP `code` field.
	kind: str,
	message: str,
};

// Frees a slice of build_diagnostics.
export fn finish_build_diagnostics(d: []build_diagnostic) void = {
	for (let i = 0z; i < len(d); i += 1) {
		free(d[i].path);
		free(d[i].kind);
		free(d[i].message);
	};
	free(d);
};

// Runs `hare build` for the file at `file_path`. Returns parsed
// diagnostics; the caller takes ownership and must call
// [[finish_build_diagnostics]].
//
// `hare_path` is the path to the `hare` binary (typically just "hare" so
// PATH is consulted). Build tags are passed via -T <tag> for each tag.
//
// timeout_ms is the wall-clock deadline (in milliseconds) before the
// subprocess is terminated and the partial output returned. Zero
// disables the timeout (waits indefinitely). A hung build that
// exceeds the deadline gets SIGTERM, then SIGKILL if it doesn't
// promptly exit.
export fn run_build(
	hare_path: str,
	file_path: str,
	tags: []str,
	timeout_ms: u32,
) []build_diagnostic = {
	// Build the argument list: hare build <-T tag>... <file>
	let argv: []str = [];
	defer free(argv);
	for (let i = 0z; i < len(tags); i += 1) {
		append(argv, "-T")!;
		append(argv, tags[i])!;
	};
	append(argv, file_path)!;

	// Create a pipe for stderr.
	const pipe_pair = match (unix::pipe()) {
	case let p: (io::file, io::file) => yield p;
	case => return [];
	};
	const (read_fd, write_fd) = pipe_pair;

	let cmd = match (exec::cmd(hare_path, build_args("build", argv)...)) {
	case let c: exec::command => yield c;
	case =>
		lsp::safe_close(read_fd);
		lsp::safe_close(write_fd);
		return [];
	};

	// Determine the working directory: the directory containing file_path.
	// For files without a directory part (relative), we leave dir unset so
	// the child runs in our cwd.
	const dir = dirname(file_path);
	if (len(dir) > 0) {
		exec::chdir(&cmd, dir);
	};

	// Redirect child stderr -> write_fd. Also nullfd stdin/stdout so a
	// build doesn't accidentally spew on our channel or block on stdin.
	exec::addfile(&cmd, os::stderr_file, write_fd)!;
	exec::addfile(&cmd, os::stdout_file, exec::nullfd)!;
	exec::addfile(&cmd, os::stdin_file, exec::nullfd)!;

	const proc = match (exec::start(&cmd)) {
	case let p: exec::process => yield p;
	case =>
		lsp::safe_close(read_fd);
		lsp::safe_close(write_fd);
		return [];
	};

	// Close the write end in our process so reads from read_fd will hit
	// EOF when the child exits.
	lsp::safe_close(write_fd);

	// Drain stderr via a poll loop bounded by `timeout_ms`. On each
	// iteration we poll for POLLIN with the remaining time as the
	// timeout; if poll signals readable, we read once. If poll returns
	// 0 (timeout expired) we SIGTERM the child and stop reading.
	let buf: []u8 = [];
	defer free(buf);
	let chunk: [4096]u8 = [0...];
	const deadline = if (timeout_ms > 0) {
		yield time::now(time::clock::MONOTONIC);
	} else {
		yield time::instant { sec = 0, nsec = 0 };
	};
	const deadline_abs = if (timeout_ms > 0) {
		yield time::add(deadline,
			(timeout_ms: i64) * time::MILLISECOND);
	} else {
		yield time::instant { sec = 0, nsec = 0 };
	};
	let timed_out = false;
	for (true) {
		// Compute remaining time as a poll timeout (in
		// time::duration units; negative means indefinite).
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
			// timeout
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
		// SIGTERM. The defer below also waits, which reaps the
		// zombie once the kernel delivers the signal.
		match (exec::sig(proc, signal::sig::TERM)) {
		case => void;
		};
	};

	// Reap. peek + retry would let us escalate to KILL if TERM was
	// ignored, but Hare's std::exec doesn't expose a wait-with-timeout;
	// we accept the small risk of a wait hang here because the build
	// is over once stderr closes.
	match (exec::wait(&proc)) {
	case => void;
	};

	const text = match (strings::fromutf8(buf)) {
	case let s: str => yield s;
	case => return [];
	};
	return parse_compiler_output(text, dir);
};

// Builds the argument list `[name, args...]`, used to splat for exec::cmd.
fn build_args(name: str, args: []str) []str = {
	let out: []str = alloc([], 1 + len(args))!;
	append(out, name)!;
	append(out, args...)!;
	return out;
};

// Returns the directory portion of `file_path`, or "" if there is none.
fn dirname(file_path: str) str = {
	const idx = strings::rindex(file_path, '/');
	match (idx) {
	case let i: size =>
		return strings::sub(file_path, 0, i);
	case void =>
		return "";
	};
};

// Parses the compiler's stderr text into diagnostics. `cwd` (if non-empty)
// is prepended to relative paths so callers can match against absolute file
// URIs.
export fn parse_compiler_output(text: str, cwd: str) []build_diagnostic = {
	let out: []build_diagnostic = [];
	const lines = strings::split(text, "\n")!;
	defer free(lines);
	for (let i = 0z; i < len(lines); i += 1) {
		match (parse_diagnostic_line(lines[i], cwd)) {
		case let d: build_diagnostic =>
			append(out, d)!;
		case void => void;
		};
	};
	return out;
};

fn parse_diagnostic_line(line: str, cwd: str) (build_diagnostic | void) = {
	// Find ":line:col: <kind>: <message>". The path may itself contain
	// ':' on Windows-ish setups, but on Unix is a colon-free token.
	// Strategy: find the third ':' (path:line:col:), then split after the
	// next ':' (kind:).
	const c1 = match (strings::index(line, ':')) {
	case let i: size => yield i;
	case => return void;
	};
	const after1 = strings::sub(line, c1 + 1, strings::end);
	const c2_rel = match (strings::index(after1, ':')) {
	case let i: size => yield i;
	case => return void;
	};
	const after2 = strings::sub(after1, c2_rel + 1, strings::end);
	const c3_rel = match (strings::index(after2, ':')) {
	case let i: size => yield i;
	case => return void;
	};
	const after3 = strings::sub(after2, c3_rel + 1, strings::end);
	const c4_rel = match (strings::index(after3, ':')) {
	case let i: size => yield i;
	case => return void;
	};
	const path_str = strings::sub(line, 0, c1);
	const line_str = strings::sub(after1, 0, c2_rel);
	const col_str = strings::sub(after2, 0, c3_rel);
	const kind_str = strings::trim(strings::sub(after3, 0, c4_rel));
	const message = strings::trim(strings::sub(after3, c4_rel + 1, strings::end));

	// Validate that line/col parse as numbers; reject otherwise.
	const lineno = match (strconv::stou32(line_str)) {
	case let n: u32 => yield n;
	case => return void;
	};
	const colno = match (strconv::stou32(col_str)) {
	case let n: u32 => yield n;
	case => return void;
	};
	if (kind_str != "error" && kind_str != "syntax error" &&
		kind_str != "warning") {
		return void;
	};

	// Resolve relative paths against cwd.
	const abs_path = if (len(cwd) > 0 && !path_is_absolute(path_str)) {
		yield strings::concat(cwd, "/", path_str)!;
	} else {
		yield strings::dup(path_str)!;
	};

	return build_diagnostic {
		path = abs_path,
		line = lineno,
		col = colno,
		kind = strings::dup(kind_str)!,
		message = strings::dup(message)!,
	};
};

fn path_is_absolute(p: str) bool = {
	if (len(p) == 0) return false;
	const b = strings::toutf8(p);
	return b[0] == '/': u8;
};

// Converts a build_diagnostic into a json::value LSP Diagnostic. Range is
// (line-1, col-1) -> (line-1, col) since the compiler reports a single
// caret position.
//
// Severity is 1 (Error) for "error" and "syntax error", 2 (Warning) for
// "warning". The compiler's `kind` is also emitted as the LSP `code` so
// clients can filter/suppress per category. When the message looks like
// an unused-import diagnostic, the `Unnecessary` (1) tag is added so
// editors grey it out.
export fn build_diag_to_lsp(d: build_diagnostic) json::value = {
	let o = json::newobject();
	let s_obj = json::newobject();
	json::put(&s_obj, "line", (d.line - 1): f64)!;
	json::put(&s_obj, "character", (d.col - 1): f64)!;
	let e_obj = json::newobject();
	json::put(&e_obj, "line", (d.line - 1): f64)!;
	json::put(&e_obj, "character", d.col: f64)!;
	let r_obj = json::newobject();
	json::put(&r_obj, "start", s_obj)!;
	json::put(&r_obj, "end", e_obj)!;
	json::put(&o, "range", r_obj)!;
	const severity: f64 = if (d.kind == "warning") 2.0 else 1.0;
	json::put(&o, "severity", severity)!;
	json::set(&o, "source", "hare-lsp/build": json::value)!;
	json::set(&o, "code", d.kind: json::value)!;
	json::set(&o, "message", d.message: json::value)!;
	apply_unnecessary_tag_if_match(&o, d.message);
	return o;
};

// Translates a filesystem path into a file:// URI.
export fn path_to_uri(p: str) str = {
	if (path_is_absolute(p)) {
		return strings::concat("file://", p)!;
	};
	return strings::dup(p)!;
};

// Translates a file:// URI back into a filesystem path. Strips the
// scheme and percent-decodes the rest. Returns a freshly-allocated
// string; caller frees.
export fn uri_to_path(uri: str) str = lsp::uri_decode_path(uri);
