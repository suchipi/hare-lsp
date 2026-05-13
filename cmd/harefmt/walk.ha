// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Directory walker for harefmt: glue between `os::iter` and the
// gitignore matcher.
//
// The walker collects per-directory ignore layers (combining
// `.gitignore` and `.harefmtignore` patterns at each level) and walks
// the file tree calling a callback on every `*.ha` file that survives
// the ignore evaluation. Symlinked directories are not entered by
// default (`opts.follow_dir_symlinks` to opt in); symlinked regular
// files are followed by default (`opts.follow_file_symlinks` to opt
// out). Directories that match an ignore pattern are pruned BEFORE
// descent, which is what enforces the gitignore rule "you cannot
// re-include a file if a parent directory of that file is excluded".

use fs;
use gitignore;
use io;
use os;
use path;
use strings;

// Knobs that affect walking behaviour. Field defaults track the CLI
// defaults: ignore files are honoured, symlinked dirs are skipped,
// symlinked regular files are followed.
export type ignore_opts = struct {
	use_harefmtignore: bool,
	use_gitignore: bool,
	follow_dir_symlinks: bool,
	follow_file_symlinks: bool,
};

export fn default_opts() ignore_opts = ignore_opts {
	use_harefmtignore = true,
	use_gitignore = true,
	follow_dir_symlinks = false,
	follow_file_symlinks = true,
};

// Walks upward from `start_dir`, loading per-directory ignore layers
// at each level. Stops at (and includes) the first ancestor that
// contains a `.git/` entry, or at the filesystem root if none is
// found. Result is ordered outermost-first so it composes directly
// with `gitignore::evaluate_layers` and with [[descend]].
//
// The returned layers own their `dir` strings AND their patterns;
// call [[finish_layers]] when done.
export fn collect_ancestors(
	start_dir: str,
	opts: ignore_opts,
) []gitignore::layer = {
	let layers: []gitignore::layer = [];
	let dir = strings::dup(start_dir)!;
	for (true) {
		match (load_layer(dir, opts)) {
		case let l: gitignore::layer =>
			append(layers, l)!;
		case void => void;
		};
		if (has_git_dir(dir)) break;
		if (is_fs_root(dir)) break;
		const parent = strings::dup(path::dirname(dir))!;
		free(dir);
		dir = parent;
		if (len(dir) == 0) {
			free(dir);
			dir = strings::dup(".")!;
			break;
		};
	};
	free(dir);
	reverse_layers(layers);
	return layers;
};

// Frees a slice of layers produced by [[collect_ancestors]] or
// [[load_layer]].
export fn finish_layers(ls: []gitignore::layer) void = {
	for (let i = 0z; i < len(ls); i += 1) {
		free(ls[i].dir);
		gitignore::finish_patterns(ls[i].patterns);
	};
	free(ls);
};

// Builds a single ignore layer for `dir` by concatenating its
// `.gitignore` patterns (first) and `.harefmtignore` patterns (last),
// subject to opts. Last-match-wins gives `.harefmtignore` the final
// word at any single level. Returns void when neither file exists or
// both are disabled.
export fn load_layer(dir: str, opts: ignore_opts) (gitignore::layer | void) = {
	let patterns: []gitignore::pattern = [];
	if (opts.use_gitignore) {
		const p = strings::concat(dir, "/.gitignore")!;
		defer free(p);
		match (read_ignore_file(p)) {
		case let ps: []gitignore::pattern =>
			append(patterns, ps...)!;
			free(ps);
		case void => void;
		};
	};
	if (opts.use_harefmtignore) {
		const p = strings::concat(dir, "/.harefmtignore")!;
		defer free(p);
		match (read_ignore_file(p)) {
		case let ps: []gitignore::pattern =>
			append(patterns, ps...)!;
			free(ps);
		case void => void;
		};
	};
	if (len(patterns) == 0) {
		free(patterns);
		return;
	};
	return gitignore::layer {
		dir = strings::dup(dir)!,
		patterns = patterns,
	};
};

// Visits every `*.ha` file under `dir` that survives the ignore check.
// `stack` contains ancestor layers (outermost first) AS WELL AS
// `dir`'s own layer if any - the caller is expected to have already
// included it (typically by calling [[collect_ancestors]] with `dir`
// as the start). `descend` then handles all SUBDIRECTORY layers as
// it walks.
export fn descend(
	dir: str,
	stack: []gitignore::layer,
	opts: ignore_opts,
	cb: *fn(file_path: str, userdata: nullable *opaque) void,
	userdata: nullable *opaque,
) void = {
	const it = match (os::iter(dir)) {
	case let i: *fs::iterator =>
		yield i;
	case fs::error =>
		return;
	};
	defer fs::finish(it);

	for (true) {
		const ent = match (fs::next(it)) {
		case let d: fs::dirent =>
			yield d;
		case done =>
			break;
		case fs::error =>
			return;
		};
		if (ent.name == "." || ent.name == "..") continue;

		const abs = strings::concat(dir, "/", ent.name)!;
		defer free(abs);
		const cl = classify(abs, ent.ftype);
		const is_dir_like =
			cl == classification::DIR || cl == classification::SYMLINK_DIR;
		if (gitignore::evaluate_layers(stack, abs, is_dir_like)) continue;

		switch (cl) {
		case classification::DIR =>
			descend_into(abs, stack, opts, cb, userdata);
		case classification::SYMLINK_DIR =>
			if (!opts.follow_dir_symlinks) continue;
			descend_into(abs, stack, opts, cb, userdata);
		case classification::FILE =>
			if (strings::hassuffix(ent.name, ".ha")) {
				cb(abs, userdata);
			};
		case classification::SYMLINK_FILE =>
			if (!opts.follow_file_symlinks) continue;
			if (strings::hassuffix(ent.name, ".ha")) {
				cb(abs, userdata);
			};
		case classification::OTHER => void;
		};
	};
};

fn descend_into(
	abs: str,
	stack: []gitignore::layer,
	opts: ignore_opts,
	cb: *fn(file_path: str, userdata: nullable *opaque) void,
	userdata: nullable *opaque,
) void = {
	const new_layer = load_layer(abs, opts);
	match (new_layer) {
	case let l: gitignore::layer =>
		// Build a fresh extended stack rather than mutating the
		// caller's slice in place. Slices in Hare share a backing
		// array; appending across a call boundary can leave the
		// caller's header pointing at a freed array if the append
		// reallocates.
		let extended: []gitignore::layer = [];
		defer free(extended);
		append(extended, stack...)!;
		append(extended, l)!;
		descend(abs, extended, opts, cb, userdata);
		free(l.dir);
		gitignore::finish_patterns(l.patterns);
	case void =>
		descend(abs, stack, opts, cb, userdata);
	};
};

type classification = enum {
	DIR,
	SYMLINK_DIR,
	FILE,
	SYMLINK_FILE,
	OTHER,
};

// Determines what `abs` actually points at, accounting for symlinks.
// For a symlink, the chain is resolved and the final target's mode
// determines DIR-vs-FILE. Broken symlinks classify as OTHER.
fn classify(abs: str, dirent_ftype: fs::mode) classification = {
	const is_link = fs::islink(dirent_ftype);
	if (!is_link) {
		if (fs::isdir(dirent_ftype)) return classification::DIR;
		if (fs::isfile(dirent_ftype)) return classification::FILE;
		return classification::OTHER;
	};
	const real = match (os::realpath(abs)) {
	case let s: str =>
		yield strings::dup(s)!;
	case fs::error =>
		return classification::OTHER;
	};
	defer free(real);
	const st = match (os::stat(real)) {
	case let st: fs::filestat =>
		yield st;
	case fs::error =>
		return classification::OTHER;
	};
	if (fs::isdir(st.mode)) return classification::SYMLINK_DIR;
	if (fs::isfile(st.mode)) return classification::SYMLINK_FILE;
	return classification::OTHER;
};

// Reads `path` and parses it as gitignore syntax. Returns void when
// the file doesn't exist (or can't be read); both are non-fatal.
fn read_ignore_file(path: str) ([]gitignore::pattern | void) = {
	const f = match (os::open(path)) {
	case let f: io::file =>
		yield f;
	case fs::error =>
		return;
	};
	defer io::close(f)!;
	const data = match (io::drain(f)) {
	case let d: []u8 =>
		yield d;
	case io::error =>
		return;
	};
	defer free(data);
	return gitignore::parse_patterns(data);
};

fn has_git_dir(dir: str) bool = {
	const p = strings::concat(dir, "/.git")!;
	defer free(p);
	return os::exists(p);
};

fn is_fs_root(dir: str) bool = {
	return dir == "/" || dir == "" || dir == ".";
};

fn reverse_layers(ls: []gitignore::layer) void = {
	const n = len(ls);
	for (let i = 0z; i < n / 2; i += 1) {
		const tmp = ls[i];
		ls[i] = ls[n - 1 - i];
		ls[n - 1 - i] = tmp;
	};
};
