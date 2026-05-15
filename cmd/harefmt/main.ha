// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// `harefmt` is a thin CLI in front of the same comment-preserving
// formatter that powers hare-lsp's `textDocument/formatting` request.
// Three modes (--write / --check / --stdout), prettier-style ignore
// file handling, and gofmt-style exit codes (0 clean, 1 changes
// needed or parse error, 2 usage error).
//
// Output is always tab-indented at column 0; Hare's style guide
// mandates tabs for indentation, so harefmt doesn't expose
// --indent-* knobs.

use bytes;
use fmt;
use fs;
use hare::lex;
use io;
use os;
use path;
use server;
use strings;
use unix;

def VERSION: str = "0.0.1";

type mode = enum {
	NONE,
	WRITE,
	CHECK,
	STDOUT,
};

type cli = struct {
	mode: mode,
	paths: []str,
	opts: ignore_opts,
};

type state = struct {
	mode: mode,
	any_unformatted: bool,
	any_error: bool,
};

type cli_error = enum {
	HELP,
	VERSION,
	USAGE,
};

export fn main() void = {
	const c = match (parse_args(os::args[1..])) {
	case let c: cli =>
		yield c;
	case let e: cli_error =>
		switch (e) {
		case cli_error::HELP =>
			print_usage(os::stdout);
			os::exit(0);
		case cli_error::VERSION =>
			fmt::printfln("harefmt {}", VERSION)!;
			os::exit(0);
		case cli_error::USAGE =>
			print_usage(os::stderr);
			os::exit(2);
		};
	};
	defer free(c.paths);

	if (c.mode == mode::STDOUT) {
		os::exit(run_stdout(c.paths[0]));
	};

	let st = state {
		mode = c.mode,
		any_unformatted = false,
		any_error = false,
	};
	for (let i = 0z; i < len(c.paths); i += 1) {
		process_path(c.paths[i], c.opts, &st);
	};

	let code = 0;
	if (st.any_error) code = 1;
	if (st.any_unformatted) code = 1;
	os::exit(code);
};

// Parses argv (minus the binary name). Returns either a `cli` value or
// a sentinel error indicating that the program should exit immediately
// (help, version, or usage failure).
//
// @param args: borrowed
fn parse_args(args: []str) (cli | cli_error) = {
	let c = cli {
		mode = mode::NONE,
		paths = [],
		opts = default_opts(),
	};

	for (let i = 0z; i < len(args); i += 1) {
		const a = args[i];
		switch (a) {
		case "--help", "-h" =>
			free(c.paths);
			return cli_error::HELP;
		case "--version", "-V" =>
			free(c.paths);
			return cli_error::VERSION;
		case "--write", "-w" =>
			if (c.mode != mode::NONE) {
				free(c.paths);
				return cli_error::USAGE;
			};
			c.mode = mode::WRITE;
		case "--check", "-c" =>
			if (c.mode != mode::NONE) {
				free(c.paths);
				return cli_error::USAGE;
			};
			c.mode = mode::CHECK;
		case "--stdout" =>
			if (c.mode != mode::NONE) {
				free(c.paths);
				return cli_error::USAGE;
			};
			c.mode = mode::STDOUT;
		case "--no-ignore" =>
			c.opts.use_harefmtignore = false;
		case "--no-gitignore" =>
			c.opts.use_gitignore = false;
		case "--follow-dir-symlinks" =>
			c.opts.follow_dir_symlinks = true;
		case "--no-follow-file-symlinks" =>
			c.opts.follow_file_symlinks = false;
		case =>
			if (strings::hasprefix(a, "--") ||
					len(a) >= 2 && strings::hasprefix(a, "-") && a != "-") {
				fmt::fprintfln(os::stderr, "harefmt: unknown option: {}", a)!;
				free(c.paths);
				return cli_error::USAGE;
			};
			append(c.paths, a)!;
		};
	};

	if (c.mode == mode::NONE) {
		fmt::fprintln(os::stderr,
			"harefmt: missing one of --write, --check, --stdout")!;
		free(c.paths);
		return cli_error::USAGE;
	};
	if (c.mode == mode::STDOUT) {
		if (len(c.paths) != 1) {
			fmt::fprintln(os::stderr,
				"harefmt: --stdout requires exactly one path arg (or `-`)")!;
			free(c.paths);
			return cli_error::USAGE;
		};
	} else {
		if (len(c.paths) == 0) {
			fmt::fprintln(os::stderr, "harefmt: no paths given")!;
			free(c.paths);
			return cli_error::USAGE;
		};
	};
	return c;
};

fn print_usage(out: io::handle) void = {
	fmt::fprintln(out,
		"Usage: harefmt --write|--check|--stdout [OPTIONS] <path>...")!;
	fmt::fprintln(out, "       harefmt --stdout -")!;
	fmt::fprintln(out)!;
	fmt::fprintln(out,
		"Format Hare source files using the same engine as hare-lsp.")!;
	fmt::fprintln(out)!;
	fmt::fprintln(out, "Modes (exactly one required):")!;
	fmt::fprintln(out, "  -w, --write           Format files in place.")!;
	fmt::fprintln(out,
		"  -c, --check           Don't write. Print each unformatted file's")!;
	fmt::fprintln(out,
		"                        path on its own line. Exit 1 if any file")!;
	fmt::fprintln(out, "                        would change.")!;
	fmt::fprintln(out,
		"      --stdout          Read one file (or `-` for stdin), write the")!;
	fmt::fprintln(out,
		"                        formatted output to stdout. Exit 1 on parse")!;
	fmt::fprintln(out, "                        error.")!;
	fmt::fprintln(out)!;
	fmt::fprintln(out, "Options:")!;
	fmt::fprintln(out,
		"      --no-ignore               Don't read .harefmtignore files.")!;
	fmt::fprintln(out,
		"      --no-gitignore            Don't read .gitignore files.")!;
	fmt::fprintln(out,
		"      --follow-dir-symlinks     Follow symlinked directories.")!;
	fmt::fprintln(out,
		"      --no-follow-file-symlinks Skip symlinked regular files.")!;
	fmt::fprintln(out,
		"  -h, --help                    Show this help and exit.")!;
	fmt::fprintln(out, "  -V, --version                 Print version and exit.")!;
};

// Handles --stdout mode for a single path. Returns the process exit
// code.
//
// @param path: borrowed
fn run_stdout(path: str) int = {
	const label = if (path == "-") "<stdin>" else path;
	const data = if (path == "-") {
		yield match (io::drain(os::stdin)) {
		case let d: []u8 =>
			yield d;
		case io::error =>
			fmt::fprintln(os::stderr, "harefmt: failed to read stdin")!;
			return 2;
		};
	} else {
		yield match (read_file(path)) {
		case let d: []u8 =>
			yield d;
		case =>
			fmt::fprintfln(os::stderr, "harefmt: {}: cannot read", path)!;
			return 2;
		};
	};
	defer free(data);

	const result = match (server::format_source(data, label)) {
	case let s: str =>
		yield s;
	case let e: server::format_error =>
		report_format_error(label, &e);
		server::format_error_finish(&e);
		return 1;
	};
	defer free(result);
	io::writeall(os::stdout, strings::toutf8(result))!;
	return 0;
};

// Processes one path arg in --write or --check mode. Files named
// explicitly on the command line are formatted regardless of any
// ignore file - the user pointed at this specific path, and silently
// skipping it would be surprising. Ignore files only narrow what a
// directory walk discovers, matching prettier's behaviour.
//
// @param path: borrowed
// @param st: borrowed
fn process_path(path: str, opts: ignore_opts, st: *state) void = {
	const abs = strings::dup(os::resolve(path))!;
	defer free(abs);
	const cl = classify_arg(abs);
	switch (cl) {
	case arg_class::FILE =>
		process_file(abs, st);
	case arg_class::DIRECTORY =>
		const layers = collect_ancestors(abs, opts);
		defer finish_layers(layers);
		descend(abs, layers, opts, &process_file_cb, st);
	case arg_class::MISSING =>
		fmt::fprintfln(os::stderr, "harefmt: {}: no such file or directory", path)!;
		st.any_error = true;
	};
};

type arg_class = enum {
	FILE,
	DIRECTORY,
	MISSING,
};

// Classifies an explicit CLI path argument. Symlinks are followed (the
// user asked for this path by name; don't second-guess them).
//
// @param abs: borrowed
fn classify_arg(abs: str) arg_class = {
	const real = match (os::realpath(abs)) {
	case let s: str =>
		yield strings::dup(s)!;
	case fs::error =>
		return arg_class::MISSING;
	};
	defer free(real);
	match (os::stat(real)) {
	case let st: fs::filestat =>
		if (fs::isdir(st.mode)) return arg_class::DIRECTORY;
		if (fs::isfile(st.mode)) return arg_class::FILE;
		return arg_class::MISSING;
	case fs::error =>
		return arg_class::MISSING;
	};
};

// @param abs: borrowed
// @param ud: borrowed
fn process_file_cb(abs: str, ud: nullable *opaque) void = {
	const st = ud: *state;
	process_file(abs, st);
};

// @param abs: borrowed
// @param st: borrowed
fn process_file(abs: str, st: *state) void = {
	const data = match (read_file(abs)) {
	case let d: []u8 =>
		yield d;
	case =>
		fmt::fprintfln(os::stderr, "harefmt: {}: cannot read", abs)!;
		st.any_error = true;
		return;
	};
	defer free(data);

	const result = match (server::format_source(data, abs)) {
	case let s: str =>
		yield s;
	case let e: server::format_error =>
		report_format_error(abs, &e);
		server::format_error_finish(&e);
		st.any_error = true;
		return;
	};
	defer free(result);

	const result_bytes = strings::toutf8(result);
	if (bytes::equal(result_bytes, data)) return;

	switch (st.mode) {
	case mode::CHECK =>
		fmt::println(abs)!;
		st.any_unformatted = true;
	case mode::WRITE =>
		match (write_file(abs, result_bytes)) {
		case void => void;
		case =>
			fmt::fprintfln(os::stderr, "harefmt: {}: cannot write", abs)!;
			st.any_error = true;
		};
	case mode::STDOUT,
	mode::NONE => abort("unreachable: stdout/none in process_file");
	};
};

// @param label: borrowed
// @param e: borrowed
fn report_format_error(label: str, e: *server::format_error) void = {
	match (e.location) {
	case let loc: lex::location =>
		fmt::fprintfln(os::stderr, "{}:{}:{}: {}", label, loc.line, loc.col,
			e.message)!;
	case void =>
		fmt::fprintfln(os::stderr, "{}: {}", label, e.message)!;
	};
};

// @param path: borrowed
fn read_file(path: str) ([]u8 | fs::error | io::error) = {
	const f = os::open(path)?;
	defer io::close(f)!;
	return io::drain(f)?;
};

// Writes `data` to `path` atomically: writes to a sibling temp file
// in the same directory, then renames over the destination. Rename
// within a single directory is atomic on every POSIX filesystem we
// care about, so an interrupted run leaves either the old file
// intact or the new one in place - never a partial write.
// Original file's permissions are preserved when known.
//
// @param path: borrowed
// @param data: borrowed
fn write_file(path: str, data: []u8) (void | fs::error | io::error) = {
	const mode = match (os::stat(path)) {
	case let st: fs::filestat =>
		yield fs::mode_perm(st.mode);
	case fs::error =>
		yield 0o644: fs::mode;
	};
	const dir = path::dirname(path);
	const base = path::basename(path);
	// Hidden filename so a stray crash leaves something the user's
	// globs won't pick up; pid disambiguates concurrent harefmt
	// invocations targeting the same file.
	const tmp_name =
		fmt::asprintf(".{}.harefmt.{}.tmp", base, unix::getpid(): u64)!;
	defer free(tmp_name);
	const tmp_path = strings::concat(dir, "/", tmp_name)!;
	defer free(tmp_path);

	match (write_tmp(tmp_path, mode, data)) {
	case void => void;
	case let e: fs::error =>
		safe_remove(tmp_path);
		return e;
	case let e: io::error =>
		safe_remove(tmp_path);
		return e;
	};
	match (os::move(tmp_path, path)) {
	case void => void;
	case let e: fs::error =>
		safe_remove(tmp_path);
		return e;
	};
};

// @param tmp_path: borrowed
// @param data: borrowed
fn write_tmp(
	tmp_path: str,
	mode: fs::mode,
	data: []u8,
) (void | fs::error | io::error) = {
	const f = os::create(tmp_path, mode, fs::flag::WRONLY | fs::flag::TRUNC)?;
	defer io::close(f)!;
	io::writeall(f, data)?;
};

// @param path: borrowed
fn safe_remove(path: str) void = {
	match (os::remove(path)) {
	case void => void;
	case fs::error => void;
	};
};
