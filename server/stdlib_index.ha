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

// Default search paths used when $HAREPATH isn't set in the server's env.
// vscode-languageclient spawns us without inheriting the user's shell
// rc-files, so we can't rely on $HAREPATH being present.
const STDLIB_DEFAULTS: [_]str = [
	"/usr/local/src/hare/stdlib",
	"/usr/local/src/hare/third-party",
];

// Returns the list of stdlib search roots in priority order:
//   1. `hare.harepath` setting when non-empty (gives editor users
//      explicit control even when their shell-set $HAREPATH isn't
//      inherited).
//   2. $HAREPATH env var
//   3. Built-in defaults for /usr/local/src/hare.
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
		for (let i = 0z; i < len(STDLIB_DEFAULTS); i += 1) {
			append(out, strings::dup(STDLIB_DEFAULTS[i])!)!;
		};
	};
	return out;
};

// Ensures the named module (e.g. "bufio", "unix::poll") has been scanned
// into `s.stdlib_index`. Returns true if the module was found and indexed
// (now or earlier), false if it doesn't exist on any search path.
//
// Indexing reads every .ha file in the module's directory; expect a small
// but non-zero latency on first use of each module.
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
fn module_subpath(module: str) str = {
	let out: []u8 = [];
	const bytes = strings::toutf8(module);
	let i = 0z;
	for (i < len(bytes); i += 1) {
		if (i + 1 < len(bytes) && bytes[i] == ':': u8
				&& bytes[i + 1] == ':': u8) {
			append(out, '/': u8)!;
			i += 1;
			continue;
		};
		append(out, bytes[i])!;
	};
	return strings::fromutf8(out)!;
};

fn is_directory(path: str) bool = {
	match (os::stat(path)) {
	case let st: fs::filestat =>
		return fs::isdir(st.mode);
	case =>
		return false;
	};
};
