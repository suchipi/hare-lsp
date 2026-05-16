// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Lazy indexing of Hare's stdlib and third-party modules so cross-module
// hover/navigation resolves identifiers like `bufio::newscanner`.
//
// The workspace_index only contains files under the user's workspace
// folders; system modules live elsewhere (typically /usr/local/src/hare/).
// We scan HAREPATH on demand the first time a hover/navigation request
// references a particular module, populating `s.stdlib_index`. Subsequent
// references hit the existing index without re-walking the filesystem.

use analysis;
use fs;
use os;
use strings;

// Returns the list of stdlib search roots in priority order:
//   1. `hare.harepath` setting when non-empty (gives editor users
//      explicit control even when their shell-set $HAREPATH isn't
//      inherited).
//   2. $HAREPATH env var
//   3. Built-in defaults: the distro-package layout under /usr/src/hare
//      when present (e.g. Alpine's `hare` apk), else /usr/local/src/hare
//      (the upstream source-install default). stdlib and third-party are
//      checked independently.
//
// @param s: borrowed
fn stdlib_search_paths(s: *server) []str = {
	let out: []str = [];
	if (len(s.config.harepath) > 0) {
		const tok = strings::tokenize(s.config.harepath, ":");
		for (let item => strings::next_token(&tok)) {
			if (len(item) == 0) continue;
			append(out, strings::dup(item)!)!;
		};
	};
	if (len(out) == 0) {
		match (os::getenv("HAREPATH")) {
		case let raw: str =>
			const tok = strings::tokenize(raw, ":");
			for (let item => strings::next_token(&tok)) {
				if (len(item) == 0) continue;
				append(out, strings::dup(item)!)!;
			};
		case void => void;
		};
	};
	if (len(out) == 0) {
		append(out, strings::dup(default_stdlib_root())!)!;
		append(out, strings::dup(default_thirdparty_root())!)!;
	};
	return out;
};

// /usr/src/hare/stdlib when it exists (Alpine etc.), else the upstream
// source-install default. Mirrors the same priority in stdlib_search_paths
// and in symbols_test's sym_stdlib_module_prefix.
fn default_stdlib_root() str = {
	if (is_directory("/usr/src/hare/stdlib")) {
		return "/usr/src/hare/stdlib";
	};
	return "/usr/local/src/hare/stdlib";
};

fn default_thirdparty_root() str = {
	if (is_directory("/usr/src/hare/third-party")) {
		return "/usr/src/hare/third-party";
	};
	return "/usr/local/src/hare/third-party";
};

// Ensures the named module (e.g. "bufio", "unix::poll") has been scanned
// into `s.stdlib_index`. Returns true if the module was found and indexed
// (now or earlier), false if it doesn't exist on any search path.
//
// Indexing reads every .ha file in the module's directory; expect a small
// but non-zero latency on first use of each module.
//
// @param s: borrowed
// @param module: borrowed
export fn ensure_stdlib_module_indexed(s: *server, module: str) bool = {
	if (len(module) == 0) return false;
	for (let i = 0z; i < len(s.indexed_stdlib_modules); i += 1) {
		if (s.indexed_stdlib_modules[i] == module) return true;
	};
	const subpath = module_subpath(module);
	defer free(subpath);

	const paths = stdlib_search_paths(s);
	defer {
		for (let i = 0z; i < len(paths); i += 1) free(paths[i]);
		free(paths);
	};

	let indexed = false;
	for (let i = 0z; i < len(paths); i += 1) {
		const candidate = strings::concat(paths[i], "/", subpath)!;
		defer free(candidate);
		if (!is_directory(candidate)) continue;
		const _ = analysis::index_directory(&s.stdlib_index, candidate);
		indexed = true;
		// We index every matching path: a module may legitimately
		// appear in more than one root (e.g. stdlib vs third-party).

	};
	if (indexed) {
		append(s.indexed_stdlib_modules, strings::dup(module)!)!;
	};
	return indexed;
};

// Splits "unix::poll" into "unix/poll" for the filesystem path. A module
// without "::" is returned as-is.
//
// @param module: borrowed
fn module_subpath(module: str) str = {
	let out: []u8 = [];
	const bytes = strings::toutf8(module);
	let i = 0z;
	for (i < len(bytes); i += 1) {
		if (i + 1 < len(bytes) && bytes[i] == ':': u8 && bytes[i + 1] == ':': u8) {
			append(out, '/': u8)!;
			i += 1;
			continue;
		};
		append(out, bytes[i])!;
	};
	return strings::fromutf8(out)!;
};

// @param path: borrowed
fn is_directory(path: str) bool = {
	match (os::stat(path)) {
	case let st: fs::filestat =>
		return fs::isdir(st.mode);
	case =>
		return false;
	};
};

// Returns the fully-qualified module name (e.g. "encoding::json", "os")
// for a file located under one of the stdlib OR third-party search roots.
// Both trees share [[stdlib_search_paths]], so the helper handles them
// uniformly: prefix-matches `path` against each search root and joins the
// remaining directory segments with `::`, peeling +tag/-tag dirs that
// Hare treats as part of the parent module.
//
// Falls back to [[analysis::module_from_path]] (the leaf-directory name)
// when no search root matches. Caller frees.
//
// @param s: borrowed
// @param path: borrowed
// @returns: owned
export fn stdlib_qualified_module(s: *server, path: str) str = {
	const roots = stdlib_search_paths(s);
	defer {
		for (let i = 0z; i < len(roots); i += 1) free(roots[i]);
		free(roots);
	};
	for (let i = 0z; i < len(roots); i += 1) {
		const root = roots[i];
		if (len(root) == 0) continue;
		if (!strings::hasprefix(path, root)) continue;
		let rel = strings::sub(path, len(root), strings::end);
		// Require a path-component boundary. Without this, a root
		// "/foo" would silently absorb "/foo-bar/x.ha" (since both
		// share the literal "/foo" prefix) and produce a bogus
		// module name like "-bar::...". The default install layouts
		// don't overlap, but a custom HAREPATH may.
		if (len(rel) > 0 && !strings::hasprefix(rel, "/")) continue;
		if (strings::hasprefix(rel, "/")) {
			rel = strings::sub(rel, 1, strings::end);
		};
		// Strip the filename — keep only the directory portion.
		const dir = match (strings::rindex(rel, '/')) {
		case let idx: size =>
			yield strings::sub(rel, 0, idx);
		case void =>
			// File sits at the root: there's no enclosing module.
			return strings::dup("")!;
		};
		return qualified_module_from_rel_dir(dir);
	};
	return analysis::module_from_path(path);
};

// Joins a relative-from-stdlib-root directory like "encoding/json" or
// "unix/poll/+linux" into the module identifier ("encoding::json" /
// "unix::poll"). Drops trailing +tag/-tag segments because Hare's build
// tag directories belong to their parent module rather than naming a
// module of their own.
//
// @param dir: borrowed
// @returns: owned
fn qualified_module_from_rel_dir(dir: str) str = {
	let segs: [](size, size) = [];
	defer free(segs);
	const bytes = strings::toutf8(dir);
	let start = 0z;
	for (let i = 0z; i <= len(bytes); i += 1) {
		if (i == len(bytes) || bytes[i] == '/': u8) {
			if (i > start) append(segs, (start, i))!;
			start = i + 1;
		};
	};
	// Peel trailing +tag/-tag segments.
	for (len(segs) > 0) {
		const (s0, e0) = segs[len(segs) - 1];
		if (e0 <= s0) break;
		const c = bytes[s0];
		if (c != '+': u8 && c != '-': u8) break;
		delete(segs[len(segs) - 1]);
	};
	if (len(segs) == 0) return strings::dup("")!;
	let out: []u8 = [];
	for (let i = 0z; i < len(segs); i += 1) {
		if (i > 0) {
			append(out, ':': u8)!;
			append(out, ':': u8)!;
		};
		const (s0, e0) = segs[i];
		append(out, bytes[s0..e0]...)!;
	};
	return strings::fromutf8(out)!;
};

// Enqueues a chunked indexing job that walks every `*.ha` file under
// each search root (stdlib AND third-party — they share the same
// [[stdlib_search_paths]]) into `s.stdlib_index`. Idempotent: runs at
// most once per server session. Used by `workspace/symbol` so a user
// can fuzzy-search across the whole stdlib and third-party tree
// without having navigated through each module first.
//
// @param s: borrowed
export fn ensure_full_stdlib_indexed(s: *server) void = {
	if (s.stdlib_fully_indexed) return;
	s.stdlib_fully_indexed = true;
	const roots = stdlib_search_paths(s);
	defer {
		for (let i = 0z; i < len(roots); i += 1) free(roots[i]);
		free(roots);
	};
	if (len(roots) == 0) return;
	start_index_job(s, roots, &s.stdlib_index, "Indexing stdlib",
		"hare-lsp: indexed stdlib");
};
