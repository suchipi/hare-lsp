// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// `hare-lsp --doctor` runs dependency checks similar to the ones the
// server itself performs at startup, so users running a prebuilt binary
// can verify their environment without touching make.
//
// Hare's stdlib and third-party libraries can live anywhere on disk;
// users point HAREPATH at the right roots (the Makefile does this with
// `$(THIRDPARTY)` + `/usr/local/src/hare/stdlib`, Alpine ships under
// `/usr/src/hare`, etc.). The doctor mirrors that: it probes whichever
// HAREPATH entries the user has configured for stdlib and hare-json
// marker files, rather than hard-coding a single /usr/local layout.

use fmt;
use fs;
use io;
use os;
use os::exec;
use strings;
use unix;

// File paths that, when any of them is present under a HAREPATH entry,
// identify that entry as a Hare stdlib root. We accept any of several
// stable core modules so a future reshuffle of one module doesn't
// invalidate the check.
const STDLIB_MARKERS: [_]str = [
	"strings/concat.ha",
	"fmt/print.ha",
	"bytes/index.ha",
];

// A file path that, when present under a HAREPATH entry, identifies
// that entry as containing hare-json's `encoding::json` module.
def HARE_JSON_MARKER: str = "encoding/json/load.ha";

// Fallback search roots used only when neither `HAREPATH` nor
// `hare.harepath` is set. Kept in lockstep with `STDLIB_DEFAULTS` in
// `server/stdlib_index.ha` so the doctor and the server agree on what
// "no configuration" means.
const STDLIB_DEFAULTS: [_]str = [
	"/usr/local/src/hare/stdlib",
	"/usr/local/src/hare/third-party",
];

// Runs the doctor checklist. Returns 0 if every check reports OK or
// WARN, 1 if any check is FAIL.
export fn run_doctor() int = {
	let failed = false;

	fmt::println("hare-lsp doctor")!;
	fmt::println("===============")!;
	fmt::println()!;

	// 1. hare on $PATH.
	const hare_bin = find_on_path("hare");
	defer match (hare_bin) {
	case let s: str => free(s);
	case void => void;
	};
	match (hare_bin) {
	case let p: str =>
		fmt::printfln("[OK] hare found at {}", p)!;
		report_hare_version();
	case void =>
		fmt::println("[FAIL] hare not found on $PATH "
			"(install Hare v0.26.0)")!;
		failed = true;
	};

	// 2. hare-lsp on $PATH. Informational; users who launch via an
	// absolute path don't need it, but editor configs typically rely on
	// PATH resolution.
	const lsp_bin = find_on_path("hare-lsp");
	defer match (lsp_bin) {
	case let s: str => free(s);
	case void => void;
	};
	match (lsp_bin) {
	case let p: str =>
		fmt::printfln("[OK] hare-lsp found at {}", p)!;
	case void =>
		fmt::println("[WARN] hare-lsp not on $PATH "
			"(editors usually need this; "
			"run `sudo make install` from the repo)")!;
	};

	// 3. Build the list of search roots. Prefer $HAREPATH; otherwise
	// fall back to the same defaults `server/stdlib_index.ha` uses, so
	// the doctor describes what the server would actually see at
	// runtime.
	const harepath_env = match (os::getenv("HAREPATH")) {
	case let s: str => yield s;
	case void => yield "";
	};
	const from_env = parse_harepath(harepath_env);
	defer free(from_env);

	let entries: []str = [];
	defer free(entries);
	let using_defaults = false;
	if (len(from_env) > 0) {
		fmt::printfln("[..] HAREPATH = {}", harepath_env)!;
		append(entries, from_env...)!;
	} else {
		fmt::println("[WARN] HAREPATH not set; "
			"falling back to compiled-in defaults")!;
		using_defaults = true;
		for (let i = 0z; i < len(STDLIB_DEFAULTS); i += 1) {
			append(entries, STDLIB_DEFAULTS[i])!;
		};
	};

	// Show each entry's existence so users see exactly what the server
	// will probe.
	let stdlib_root: (str | void) = void;
	let hare_json_root: (str | void) = void;
	for (let i = 0z; i < len(entries); i += 1) {
		const entry = entries[i];
		const prefix = if (using_defaults) "    " else "     ";
		if (!is_directory(entry)) {
			fmt::printfln("{}[WARN] {} missing", prefix, entry)!;
			continue;
		};
		fmt::printfln("{}[OK] {} exists", prefix, entry)!;
		if (stdlib_root is void && looks_like_stdlib(entry)) {
			stdlib_root = entry;
		};
		if (hare_json_root is void
				&& has_file(entry, HARE_JSON_MARKER)) {
			hare_json_root = entry;
		};
	};

	// 4. Confirm we found a stdlib root somewhere on the search path.
	match (stdlib_root) {
	case let p: str =>
		fmt::printfln("[OK] stdlib found in {}", p)!;
	case void =>
		fmt::println("[FAIL] no stdlib found on HAREPATH "
			"(no entry contains core stdlib modules); "
			"point HAREPATH at your Hare stdlib root")!;
		failed = true;
	};

	// 5. Confirm hare-json is reachable from one of the search roots.
	// The Makefile fails fast without it so we treat it as a hard
	// requirement.
	match (hare_json_root) {
	case let p: str =>
		fmt::printfln("[OK] hare-json found in {} (contains {})", p,
			HARE_JSON_MARKER)!;
	case void =>
		fmt::printfln("[FAIL] hare-json not reachable from HAREPATH "
			"(no entry contains {})", HARE_JSON_MARKER)!;
		fmt::println("       install with:")!;
		fmt::println("         d=$(mktemp -d) && git clone "
			"https://git.sr.ht/~sircmpwn/hare-json \"$d/hare-json\"")!;
		fmt::println("         sudo make -C \"$d/hare-json\" install")!;
		failed = true;
	};

	// 6. HARE_LSP_LOG_DIR sanity. Only checked when set; the var is
	// optional. vscode-languageclient spawns the server with cwd=/ so
	// a relative path would land in / and silently fail.
	match (os::getenv("HARE_LSP_LOG_DIR")) {
	case let s: str =>
		if (len(s) == 0) {
			fmt::println("[WARN] HARE_LSP_LOG_DIR is set but empty; "
				"wire-protocol logging disabled")!;
		} else if (!path_is_absolute(s)) {
			fmt::printfln("[FAIL] HARE_LSP_LOG_DIR={} is not absolute; "
				"editors run hare-lsp with cwd=/ and relative "
				"paths will fail", s)!;
			failed = true;
		} else if (!is_directory(s)) {
			fmt::printfln("[FAIL] HARE_LSP_LOG_DIR={} is not a "
				"directory", s)!;
			failed = true;
		} else if (!is_writable_dir(s)) {
			fmt::printfln("[FAIL] HARE_LSP_LOG_DIR={} is not "
				"writable", s)!;
			failed = true;
		} else {
			fmt::printfln("[OK] HARE_LSP_LOG_DIR={} is absolute "
				"and writable", s)!;
		};
	case void =>
		fmt::println("[OK] HARE_LSP_LOG_DIR not set "
			"(wire-protocol logging disabled)")!;
	};

	fmt::println()!;
	if (failed) {
		fmt::println("Some checks failed. See messages above.")!;
		return 1;
	};
	fmt::println("All required checks passed.")!;
	return 0;
};

// Splits a HAREPATH-style colon-separated path list into entries with
// empty segments dropped. Returns an owned slice of borrowed substrings.
export fn parse_harepath(s: str) []str = {
	let out: []str = [];
	if (len(s) == 0) return out;
	let tok = strings::tokenize(s, ":");
	for (let item => strings::next_token(&tok)) {
		if (len(item) == 0) continue;
		append(out, item)!;
	};
	return out;
};

// Returns true if `p` starts with '/'.
export fn path_is_absolute(p: str) bool = {
	if (len(p) == 0) return false;
	const b = strings::toutf8(p);
	return b[0] == '/': u8;
};

// True when `<dir>/<relpath>` exists as a regular file.
fn has_file(dir: str, relpath: str) bool = {
	const full = strings::concat(dir, "/", relpath)!;
	defer free(full);
	return os::exists(full);
};

// True when `dir` looks like a Hare stdlib root - i.e. it contains any
// of [[STDLIB_MARKERS]].
fn looks_like_stdlib(dir: str) bool = {
	for (let i = 0z; i < len(STDLIB_MARKERS); i += 1) {
		if (has_file(dir, STDLIB_MARKERS[i])) return true;
	};
	return false;
};

// Walks $PATH and returns the first entry where `<dir>/<name>` is
// executable. Returns void if not found. The result is a freshly
// allocated string; caller frees.
fn find_on_path(name: str) (str | void) = {
	const path_env = match (os::getenv("PATH")) {
	case let s: str => yield s;
	case void => return;
	};
	let tok = strings::tokenize(path_env, ":");
	for (let item => strings::next_token(&tok)) {
		if (len(item) == 0) continue;
		const candidate = strings::concat(item, "/", name)!;
		match (os::access(candidate, os::amode::X_OK)) {
		case let ok: bool =>
			if (ok) return candidate;
		case fs::error => void;
		};
		free(candidate);
	};
};

// True when `p` exists and is a directory.
fn is_directory(p: str) bool = {
	match (os::stat(p)) {
	case let st: fs::filestat =>
		return fs::isdir(st.mode);
	case fs::error =>
		return false;
	};
};

// True when the user has write access to `p`.
fn is_writable_dir(p: str) bool = {
	match (os::access(p, os::amode::W_OK)) {
	case let ok: bool => return ok;
	case fs::error => return false;
	};
};

// Runs `hare version` and pretty-prints the first line of its stdout.
// Best-effort - failures degrade silently so the doctor keeps going.
fn report_hare_version() void = {
	const pipe_pair = match (unix::pipe()) {
	case let p: (io::file, io::file) => yield p;
	case => return;
	};
	const (read_fd, write_fd) = pipe_pair;

	let cmd = match (exec::cmd("hare", "version")) {
	case let c: exec::command => yield c;
	case =>
		safe_close(read_fd);
		safe_close(write_fd);
		return;
	};
	match (exec::addfile(&cmd, os::stdout_file, write_fd)) {
	case void => void;
	case =>
		exec::finish(&cmd);
		safe_close(read_fd);
		safe_close(write_fd);
		return;
	};
	match (exec::addfile(&cmd, os::stderr_file, exec::nullfd)) {
	case void => void;
	case =>
		exec::finish(&cmd);
		safe_close(read_fd);
		safe_close(write_fd);
		return;
	};
	match (exec::addfile(&cmd, os::stdin_file, exec::nullfd)) {
	case void => void;
	case =>
		exec::finish(&cmd);
		safe_close(read_fd);
		safe_close(write_fd);
		return;
	};
	const proc = match (exec::start(&cmd)) {
	case let p: exec::process => yield p;
	case =>
		safe_close(read_fd);
		safe_close(write_fd);
		return;
	};
	safe_close(write_fd);

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
	safe_close(read_fd);
	match (exec::wait(&proc)) {
	case => void;
	};

	const text = match (strings::fromutf8(buf)) {
	case let s: str => yield s;
	case => return;
	};
	const trimmed = strings::trim(text);
	if (len(trimmed) == 0) return;
	fmt::printfln("     {}", first_line(trimmed))!;
};

fn first_line(s: str) str = {
	match (strings::index(s, '\n')) {
	case let i: size => return strings::sub(s, 0, i);
	case void => return s;
	};
};

fn safe_close(f: io::file) void = {
	match (io::close(f)) {
	case => void;
	};
};
