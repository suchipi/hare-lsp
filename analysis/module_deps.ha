// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Module-dependency walker for "build a module and everything local it
// imports, in topological order" workflows (e.g. the LSP's didSave
// diagnostics path).
//
// Given a starting module directory and a resolver callback that maps a
// `use` ident to an on-disk module dir, this returns the list of module
// dirs to compile, ordered so each module's dependencies appear before
// it. Modules whose resolved dir doesn't fall under any of the supplied
// workspace folders are treated as "external" (stdlib, third-party,
// vendored installs elsewhere on disk) and excluded from the build
// order — they're already compiled / not part of the user's project.
//
// Pure logic + targeted FS reads (directory enumeration, file slurp).
// No subprocess execution. No assumptions about HAREPATH layout.

use fs;
use hare::ast;
use io;
use os;
use strings;

// One module that should be built.
export type module_dep = struct {
	// Absolute path to the module's source directory.
	// @owned
	dir: str,
	// The `use` identifier that first referenced this module, joined
	// with "::". Empty for the root (the starting module passed to
	// [[build_order]]).
	// @owned
	use_ident: str,
};

// Resolver callback shape. `ctx` is the opaque context value passed
// alongside the callback; the walker just threads it through. `ident`
// is the `::`-separated parts of a `use` declaration. Return a
// freshly-allocated string holding the absolute on-disk dir Hare
// would compile for that ident, or void if unresolvable.
//
// Ownership: the returned string is freed by the walker after use.
// Resolvers must NOT return aliases into longer-lived storage.
export type resolver = fn(ctx: *opaque, ident: []str) (str | void);

// Walks the dependency graph starting at `module_dir`, returning the
// list of modules to build in topological order: leaves (modules with
// no local deps) first, the starting module last.
//
// `workspace_folders` is the list of absolute workspace-folder paths.
// A resolved module dir is considered "local" (and thus added to the
// build order) iff it equals one of those folders or lies underneath
// one. Anything outside is silently skipped.
//
// `resolve` (with `resolver_ctx`) is invoked for each unique `use`
// ident encountered. The walker is agnostic about how resolution
// happens; callers wire it to Hare's `module::find` or to a stub.
//
// Caller frees the returned slice via [[finish_build_order]].
//
// @returns: owned
// @param module_dir: borrowed
// @param workspace_folders: borrowed
// @param resolve: borrowed
// @param resolver_ctx: borrowed
export fn build_order(
	module_dir: str,
	workspace_folders: []str,
	resolve: *resolver,
	resolver_ctx: *opaque,
) []module_dep = {
	let visited: []str = [];
	defer strings::freeall(visited);
	let out: []module_dep = [];
	walk_module(module_dir, "", workspace_folders, resolve, resolver_ctx, &visited,
		&out);
	return out;
};

// Frees a slice returned by [[build_order]].
//
// @param o: owned
export fn finish_build_order(o: []module_dep) void = {
	for (let i = 0z; i < len(o); i += 1) {
		free(o[i].dir);
		free(o[i].use_ident);
	};
	free(o);
};

// @param dir: borrowed
// @param use_ident: borrowed
// @param workspace_folders: borrowed
// @param resolve: borrowed
// @param resolver_ctx: borrowed
// @param visited: borrowed
// @param out: borrowed
fn walk_module(
	dir: str,
	use_ident: str,
	workspace_folders: []str,
	resolve: *resolver,
	resolver_ctx: *opaque,
	visited: *[]str,
	out: *[]module_dep,
) void = {
	for (let i = 0z; i < len(visited); i += 1) {
		if (visited[i] == dir) return;
	};
	append(visited, strings::dup(dir)!)!;

	const idents = collect_imports(dir);
	defer free_idents(idents);

	for (let i = 0z; i < len(idents); i += 1) {
		const id = idents[i];
		const resolved = match (resolve(resolver_ctx, id)) {
		case let s: str =>
			yield s;
		case void =>
			continue;
		};
		defer free(resolved);
		if (!is_under_any(resolved, workspace_folders)) continue;
		const child_ident = strings::join("::", id...)!;
		defer free(child_ident);
		walk_module(resolved, child_ident, workspace_folders, resolve, resolver_ctx,
			visited, out);
	};

	append(out, module_dep {
		dir = strings::dup(dir)!,
		use_ident = strings::dup(use_ident)!,
	})!;
};

// Returns the union of `use` idents found across every `.ha` file in
// `dir`. Each returned ident is a freshly-owned `[]str`; caller frees
// via [[free_idents]]. Files gated to the `+test` build (any
// `+test`-bearing tag combination — see [[has_test_tag]]) are skipped:
// their dependencies are test-time only and shouldn't drive
// production-style build diagnostics.
//
// @param dir: borrowed
fn collect_imports(dir: str) [][]str = {
	let out: [][]str = [];
	const it = match (os::iter(dir)) {
	case let it: *fs::iterator =>
		yield it;
	case fs::error =>
		return out;
	};
	defer fs::finish(it);
	for (true) {
		const entry = match (fs::next(it)) {
		case let e: fs::dirent =>
			yield e;
		case done =>
			break;
		case fs::error =>
			break;
		};
		if (entry.name == "." || entry.name == "..") continue;
		if (!fs::isfile(entry.ftype)) continue;
		if (!strings::hassuffix(entry.name, ".ha")) continue;
		if (has_test_tag(entry.name)) continue;
		const path = strings::concat(dir, "/", entry.name)!;
		defer free(path);
		const bytes = read_file_bytes(path);
		defer free(bytes);
		let pr = parse_recover(bytes, path);
		defer finish_parse_result(&pr);
		for (let j = 0z; j < len(pr.subunit.imports); j += 1) {
			const imp = pr.subunit.imports[j];
			append(out, dup_ident(imp.ident))!;
		};
	};
	return out;
};

// @param id: borrowed
fn dup_ident(id: []str) []str = {
	let copy: []str = [];
	for (let i = 0z; i < len(id); i += 1) {
		append(copy, strings::dup(id[i])!)!;
	};
	return copy;
};

// @param ids: owned
fn free_idents(ids: [][]str) void = {
	for (let i = 0z; i < len(ids); i += 1) {
		strings::freeall(ids[i]);
	};
	free(ids);
};

// @param path: borrowed
fn read_file_bytes(path: str) []u8 = {
	const f = match (os::open(path)) {
	case let f: io::file =>
		yield f;
	case fs::error =>
		return [];
	};
	defer match (io::close(f)) {
	case => void;
	};
	let buf: []u8 = [];
	let chunk: [4096]u8 = [0...];
	for (true) {
		match (io::read(f, chunk[..])) {
		case let n: size =>
			append(buf, chunk[..n]...)!;
		case io::EOF =>
			break;
		case io::error =>
			break;
		};
	};
	return buf;
};

// Returns true when `name` is a `.ha` filename whose tag-suffix list
// contains `test`. Hare accepts tags in any order, so all of
// `foo+test.ha`, `foo+test+libc.ha`, and `foo+libc+test.ha` count.
// Names without a `+` (e.g. `foo.ha`) have no tags.
//
// @param name: borrowed
fn has_test_tag(name: str) bool = {
	if (!strings::hassuffix(name, ".ha")) return false;
	const base = strings::sub(name, 0, len(name) - 3);
	const tag_start = match (strings::index(base, '+')) {
	case let i: size =>
		yield i + 1;
	case void =>
		return false;
	};
	const tags = strings::sub(base, tag_start, strings::end);
	const tok = strings::tokenize(tags, "+");
	for (let t => strings::next_token(&tok)) {
		if (t == "test") return true;
	};
	return false;
};

// @param path: borrowed
// @param roots: borrowed
fn is_under_any(path: str, roots: []str) bool = {
	for (let i = 0z; i < len(roots); i += 1) {
		const root = roots[i];
		if (path == root) return true;
		const prefix = strings::concat(root, "/")!;
		defer free(prefix);
		if (strings::hasprefix(path, prefix)) return true;
	};
	return false;
};
