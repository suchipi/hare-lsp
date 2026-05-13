// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// AST-equivalence cross-check: walk every .ha file under the project
// root, pipe its source through `./harefmt --stdout -`, and assert
// that the AST parsed from the formatted output is structurally
// identical to the AST parsed from the original source. Any AST
// change is treated as a formatter bug - the formatter must only
// rewrite WHITESPACE / LAYOUT, never anything the AST sees.
//
// Comparison is done by unparsing both ASTs through hare::unparse
// (which writes a canonical, loc-independent text form) and comparing
// the resulting strings. Two ASTs that differ only in source
// positions render identical unparsed output; any structural
// difference shows up in the strings.
//
// This catches the entire class of formatter regressions where an
// expression's structure silently changes - parens being added or
// removed in a way that flips precedence, a literal being rewritten
// to a different value, a token being lost, etc.

use bufio;
use fmt;
use fs;
use hare::ast;
use hare::lex;
use hare::parse;
use hare::unparse;
use io;
use memio;
use os;
use os::exec;
use rt;
use strings;

// Path to the formatter binary, resolved relative to the test's
// working directory (the repo root when invoked via `make test`).
def HAREFMT_PATH: str = "./harefmt";

@test fn e2e_harefmt_preserves_ast_for_repo_files() void = {
	const root = ".";
	const files = collect_ast_ha_files(root);
	defer strings::freeall(files);

	if (len(files) == 0) {
		// Sandboxed test runner without filesystem access -
		// nothing to verify. Don't fail; the in-process unit
		// and other e2e tests still cover synthetic inputs.
		return;
	};

	let failures: []str = [];
	defer strings::freeall(failures);
	let parse_skipped: size = 0;
	let checked: size = 0;

	for (let i = 0z; i < len(files); i += 1) {
		const src = match (read_ast_file(root, files[i])) {
		case let b: []u8 =>
			yield b;
		case void =>
			continue;
		};
		defer free(src);

		const before = match (parse_to_canonical(src)) {
		case let s: str =>
			yield s;
		case void =>
			// Original source already doesn't parse; the
			// fmt_roundtrip test in `server/` covers
			// reparse failures separately.
			parse_skipped += 1;
			continue;
		};
		defer free(before);

		const formatted = match (run_harefmt_stdin_stdout(src)) {
		case let b: []u8 =>
			yield b;
		case let e: str =>
			append(failures, fmt::asprintf("{}: {}", files[i], e)!)!;
			continue;
		};
		defer free(formatted);

		const after = match (parse_to_canonical(formatted)) {
		case let s: str =>
			yield s;
		case void =>
			append(failures, fmt::asprintf("{}: harefmt output failed to reparse",
				files[i])!)!;
			continue;
		};
		defer free(after);

		checked += 1;
		if (before != after) {
			append(failures, fmt::asprintf("{}: AST differs after harefmt", files[i])!)!;
			dump_ast_diff(files[i], before, after);
		};
	};

	if (len(failures) > 0) {
		fmt::errorfln(
			"AST roundtrip failures ({} files checked, "
			"{} unparseable inputs skipped):", checked, parse_skipped)!;
		for (let i = 0z; i < len(failures); i += 1) {
			fmt::errorfln("  {}", failures[i])!;
		};
		assert(false, "harefmt must preserve AST for every file "
			"in the repo");
	};
	// Guard against the silent-pass failure mode where every file is
	// either unreadable or unparseable: a `parse::subunit` regression
	// that rejected all real input would otherwise look like a green
	// pass with `checked = 0`.
	assert(
		checked > 0,
		"AST roundtrip must check at least one file"
		" (no files survived to the comparison step)"
	);
};

// Direct test of harefmt's normalization behavior on synthetic input.
// The repo-walk test above only proves AST is preserved when the input
// is already harefmt-clean (every committed file is, by repo policy).
// Here we feed in deliberately-messy source and assert that:
//   - the formatter actually rewrites it (output != input)
//   - every line comment in the input is still present
//   - blank lines between top-level decls are preserved
//   - the parsed AST is identical before and after
// This catches regressions that the repo-walk test cannot, because
// comments and blank lines are not part of the AST and so are
// invisible to `parse_to_canonical`.
@test fn e2e_harefmt_normalizes_and_preserves_comments() void = {
	const messy = strings::toutf8(
		`// header comment
use     io;

// between header and first decl

export fn one() void  = void;

// between the two decls
export fn two() void = void;

// trailing comment
`);

	const formatted = match (run_harefmt_stdin_stdout(messy)) {
	case let b: []u8 =>
		yield b;
	case let e: str =>
		fmt::fatalf("harefmt failed on synthetic input: {}", e);
	};
	defer free(formatted);

	// Formatter must actually do something: input has `use     io;`
	// (multiple spaces) and `void  = void` (double space) which are
	// not canonical. If output == input, either the formatter is a
	// no-op or it failed silently.
	assert(
		!bytes_equal_local(messy, formatted),
		"harefmt must rewrite non-canonical whitespace"
	);

	const formatted_str = strings::fromutf8(formatted)!;

	// Every line comment in the input must appear in the output.
	const required_comments: [_]str = [
		"// header comment",
		"// between header and first decl",
		"// between the two decls",
		"// trailing comment",
	];
	for (let i = 0z; i < len(required_comments); i += 1) {
		assert(
			strings::contains(formatted_str, required_comments[i]),
			"every comment in the input must survive harefmt"
		);
	};

	// At least one blank line (`\n\n`) must remain — otherwise the
	// formatter collapsed all of the source's intentional spacing.
	assert(
		strings::contains(formatted_str, "\n\n"),
		"intentional blank-line separators between decls must be preserved"
	);

	// AST equivalence: the canonical unparsed form of input and output
	// must match. Catches regressions that change tokens or structure.
	const before = match (parse_to_canonical(messy)) {
	case let s: str =>
		yield s;
	case void =>
		fmt::fatalf("synthetic input failed to parse — fix the fixture");
	};
	defer free(before);
	const after = match (parse_to_canonical(formatted)) {
	case let s: str =>
		yield s;
	case void =>
		fmt::fatalf("harefmt output failed to reparse");
	};
	defer free(after);
	assert(
		before == after,
		"harefmt must preserve AST across the rewrite of the synthetic input"
	);
};

fn bytes_equal_local(a: []u8, b: []u8) bool = {
	if (len(a) != len(b)) return false;
	for (let i = 0z; i < len(a); i += 1) {
		if (a[i] != b[i]) return false;
	};
	return true;
};

// Renders the parsed AST of `data` into the canonical text form
// produced by hare::unparse. Returns void if `data` doesn't parse;
// returns a freshly-allocated string the caller frees otherwise.
//
// Comparing canonical-form strings is our AST equality test:
// hare::unparse drops loc fields and renders tokens / structure in a
// fixed order, so two ASTs that differ only in source positions emit
// the same string while any structural change produces a different
// string.
fn parse_to_canonical(data: []u8) (str | void) = {
	if (len(data) == 0) return strings::dup("")!;
	let src = memio::fixed(data);
	let scan = bufio::newscanner(&src);
	defer bufio::finish(&scan);
	let lexer = lex::init(&scan, "<ast-roundtrip>");
	defer lex::finish(&lexer);
	const su = match (parse::subunit(&lexer)) {
	case let s: ast::subunit =>
		yield s;
	case parse::error =>
		return;
	};
	defer ast::subunit_finish(su);

	let buf = memio::dynamic();
	defer io::close(&buf)!;
	match (unparse::subunit(&buf, &unparse::syn_nowrap, su)) {
	case size => void;
	case io::error =>
		return;
	};
	return strings::dup(memio::string(&buf)!)!;
};

// Spawns `./harefmt --stdout -`, writes `src` to its stdin, closes
// stdin to signal EOF, and reads the formatted output from stdout.
// Returns the formatted bytes on success, or a short error string on
// failure (binary missing, non-zero exit, IO error, etc.).
//
// Hare files in this repo are small enough (well under the OS pipe
// buffer of ~64 KiB) that writing the full input before reading the
// output never deadlocks. A larger workload would need
// reader/writer overlap.
fn run_harefmt_stdin_stdout(src: []u8) ([]u8 | str) = {
	const (in_r, in_w) = exec::pipe();
	const (out_r, out_w) = exec::pipe();
	// `unix::pipe` on darwin is implemented over POSIX pipe(2)
	// and silently drops the requested O_CLOEXEC flag (see
	// /usr/local/src/hare/stdlib/rt/+darwin/syscalls.ha::pipe2).
	// Without CLOEXEC, the forked child of `exec::start` keeps a
	// copy of EVERY pipe fd in our process - including the WRITE
	// end of the child's stdin pipe - so when this parent closes
	// `in_w`, the child's `io::drain(os::stdin)` never sees EOF
	// because there's still a writer (the leaked fd 5 inside the
	// child itself). Set CLOEXEC explicitly here to undo the
	// stdlib bug so the child's exec actually closes the leak.
	set_cloexec(in_r);
	set_cloexec(in_w);
	set_cloexec(out_r);
	set_cloexec(out_w);

	let cmd = match (exec::cmd(HAREFMT_PATH, "--stdout", "-")) {
	case let c: exec::command =>
		yield c;
	case let e: exec::error =>
		io::close(in_r)!;
		io::close(in_w)!;
		io::close(out_r)!;
		io::close(out_w)!;
		return strings::dup(exec::strerror(e))!;
	case nomem =>
		return strings::dup("out of memory preparing harefmt")!;
	};

	exec::addfile(&cmd, os::stdin_file, in_r)!;
	exec::addfile(&cmd, os::stdout_file, out_w)!;

	const proc = match (exec::start(&cmd)) {
	case let p: exec::process =>
		yield p;
	case let e: exec::error =>
		io::close(in_r)!;
		io::close(in_w)!;
		io::close(out_r)!;
		io::close(out_w)!;
		return strings::dup(exec::strerror(e))!;
	};
	io::close(in_r)!;
	io::close(out_w)!;

	io::writeall(in_w, src)!;
	io::close(in_w)!;

	const out = match (io::drain(out_r)) {
	case let b: []u8 =>
		yield b;
	case io::error =>
		io::close(out_r)!;
		const _ = exec::wait(&proc);
		return strings::dup("io error reading harefmt stdout")!;
	};
	io::close(out_r)!;

	const status = match (exec::wait(&proc)) {
	case let s: exec::status =>
		yield s;
	case let e: exec::error =>
		free(out);
		return strings::dup(exec::strerror(e))!;
	};
	match (exec::check(&status)) {
	case void => void;
	case !exec::exit_status =>
		const summary = exec::exitstr(exec::exit(&status));
		free(out);
		return fmt::asprintf("harefmt exited with {}", summary)!;
	};
	return out;
};

// Walks `root` recursively for `.ha` files (mirrors the helper in
// server/fmt_roundtrip+test.ha). Skips dot-prefixed dirs and the
// vendored vscode extension under `editors/`.
fn collect_ast_ha_files(root: str) []str = {
	let out: []str = [];
	walk_ast_dir(root, "", &out);
	return out;
};

fn walk_ast_dir(root: str, rel: str, out: *[]str) void = {
	const path = if (rel == "") strings::dup(root)!
		else strings::concat(root, "/", rel)!;
	defer free(path);
	const it = match (fs::iter(os::cwd, path)) {
	case let p: *fs::iterator =>
		yield p;
	case fs::error =>
		return;
	};
	defer fs::finish(it);

	for (true) {
		const ent = match (fs::next(it)) {
		case let e: fs::dirent =>
			yield e;
		case done =>
			break;
		case fs::error =>
			break;
		};
		if (ent.name == "." || ent.name == "..") continue;
		if (strings::hasprefix(ent.name, ".")) continue;
		if (rel == "" && ent.name == "editors") continue;

		const child_rel = if (rel == "") strings::dup(ent.name)!
			else strings::concat(rel, "/", ent.name)!;
		if (fs::isdir(ent.ftype)) {
			walk_ast_dir(root, child_rel, out);
			free(child_rel);
		} else if (fs::isfile(ent.ftype) && strings::hassuffix(ent.name, ".ha")) {
			let cur = *out;
			append(cur, child_rel)!;
			*out = cur;
		} else {
			free(child_rel);
		};
	};
};

// Sets FD_CLOEXEC on `fd`. Used to compensate for the darwin stdlib
// bug in `unix::pipe` (see `run_harefmt_stdin_stdout` for details).
// Errors from fcntl are ignored - on a non-darwin platform the flag
// is already set and the call is a no-op-style success; on any
// platform a failure here would just mean the child inherits the
// fd, which is what we're trying to avoid but also what the test
// would catch (it would hang).
fn set_cloexec(fd: io::file) void = {
	const _ = rt::fcntl(fd, rt::F_SETFD, rt::FD_CLOEXEC);
};

fn read_ast_file(root: str, rel: str) ([]u8 | void) = {
	const path = strings::concat(root, "/", rel)!;
	defer free(path);
	const f = match (os::open(path)) {
	case let f: io::file =>
		yield f;
	case fs::error =>
		return;
	};
	defer io::close(f)!;
	match (io::drain(f)) {
	case let b: []u8 =>
		return b;
	case io::error =>
		return;
	};
};

// Dumps the before / after canonical-AST strings for `rel` into
// `.tmp/ast-diff-<safe_name>.{before,after}` so a developer can
// `diff` them after a failing run.
fn dump_ast_diff(rel: str, before: str, after: str) void = {
	const safe = strings::replace(rel, "/", "__")!;
	defer free(safe);
	dump_one(safe, ".before", before);
	dump_one(safe, ".after", after);
};

fn dump_one(safe: str, suffix: str, content: str) void = {
	const path = strings::concat(".tmp/ast-diff-", safe, suffix)!;
	defer free(path);
	match (os::create(path, 0o644: fs::mode)) {
	case let f: io::file =>
		io::writeall(f, strings::toutf8(content))!;
		io::close(f)!;
	case fs::error => void;
	};
};
