// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// didSave build-diagnostics path. Given the saved document, walk its
// module's dependency graph (via [[analysis::build_order]]), then run
// `hare build -t o <module>` for each module in topological order.
// Aggregate the per-build diagnostics so the LSP can publish them as a
// single set.
//
// Why `-t o` instead of `-t bin` (the default): library modules don't
// have a `main` function, and `hare build <library-dir>` would fail
// before producing any useful diagnostics. Object-file builds still
// type-check the whole module without requiring `main`, which is what
// we want for diagnostics.
//
// Why walk dependencies ourselves: hare's compiler already follows
// `use` declarations recursively, so for any single module its imports
// are pulled in automatically. We walk explicitly so that (a) we use
// the LSP's own HAREPATH-aware resolver (`find_module`) to classify
// each dep as local vs external, and (b) errors in a dep get reported
// against that dep's own files in the right order, rather than only
// surfacing as cascaded errors when their consumer is built.

use analysis;
use hare::module;
use lsp;
use strings;
use time;

// Runs the dep-walk + per-module `hare build -t o` flow for `doc`,
// returning the aggregated diagnostics. Caller takes ownership via
// [[finish_build_diagnostics]].
//
// @param s: borrowed
// @param doc: borrowed
// @returns: owned
export fn run_dep_build_for_doc(
	s: *server,
	doc: *document,
) []build_diagnostic = {
	const file_path = uri_to_path(doc.uri);
	defer free(file_path);
	const mod_dir = parent_dir_of_file(file_path);
	defer free(mod_dir);

	// Decoded workspace folder paths — used both to classify local
	// deps in the walker and to compose HAREPATH for spawned hare.
	let folders: []str = [];
	defer strings::freeall(folders);
	for (let i = 0z; i < len(s.workspace_folders); i += 1) {
		append(folders, lsp::uri_decode_path(s.workspace_folders[i].uri))!;
	};

	let ctx = dep_resolver_ctx { s = s, cache = [] };
	defer finish_dep_resolver_cache(&ctx);
	const order = analysis::build_order(mod_dir, folders, &dep_resolver_fn,
		&ctx: *opaque);
	defer analysis::finish_build_order(order);

	// HAREPATH for the spawned hare child: workspace folders first
	// (so local-module use names win), then whatever stdlib search
	// paths the server already computes from config / env / defaults.
	const stdlib = stdlib_search_paths(s);
	defer strings::freeall(stdlib);
	const harepath = compose_harepath(folders, stdlib);
	defer free(harepath);

	// cwd for the child: deepest workspace folder containing the
	// saved file (so a relative HARECACHE doesn't land beside the
	// edited file), falling back to the file's parent directory.
	const cwd = spawn_cwd_for_path(s, file_path);
	defer free(cwd);

	// build_timeout_ms is the whole-pass budget, not per subprocess —
	// otherwise a 60s default × N modules would hold the LSP main
	// loop hostage for N minutes on a deadlocked compile. Compute
	// the absolute deadline once and let each subprocess see the
	// remainder.
	const total_ms = s.config.build_timeout_ms;
	const deadline = if (total_ms == 0) {
		yield time::instant { sec = 0, nsec = 0 };
	} else {
		yield time::add(time::now(time::clock::MONOTONIC),
			total_ms: i64 * time::MILLISECOND);
	};

	let all_diags: []build_diagnostic = [];
	for (let i = 0z; i < len(order); i += 1) {
		const per_call_ms = remaining_budget_ms(total_ms, deadline);
		if (total_ms != 0 && per_call_ms == 0) break;
		const diags = run_build_obj(s, order[i].dir, cwd, harepath, per_call_ms);
		merge_dedup_diags(&all_diags, diags);
	};
	return all_diags;
};

// Returns the wall-clock milliseconds remaining until `deadline`,
// clamped to at least 1 when the deadline is in the future. Returns 0
// when the deadline has passed. When `total_ms` is 0 (no deadline),
// returns 0 to signal "wait indefinitely" — callers must check
// `total_ms` themselves to distinguish "no budget left" from "no
// deadline configured".
fn remaining_budget_ms(total_ms: u32, deadline: time::instant) u32 = {
	if (total_ms == 0) return 0;
	const now = time::now(time::clock::MONOTONIC);
	const remaining = time::diff(now, deadline);
	if (remaining <= 0) return 0;
	const ms = remaining / time::MILLISECOND;
	if (ms <= 0) return 1;
	return ms: u32;
};

// Returns the directory containing `file_path`. Caller frees.
//
// @param file_path: borrowed
// @returns: owned
fn parent_dir_of_file(file_path: str) str = {
	const idx = match (strings::rindex(file_path, '/')) {
	case let i: size =>
		yield i;
	case void =>
		return strings::dup(".")!;
	};
	if (idx == 0) return strings::dup("/")!;
	return strings::dup(strings::sub(file_path, 0, idx))!;
};

// Resolver-callback context: server state plus a per-pass cache of
// previously-resolved idents. The cache lives for one
// `run_dep_build_for_doc` invocation; a fresh ctx is allocated per
// save so the cache can't go stale across builds.
type dep_resolver_ctx = struct {
	s: *server,
	cache: []cache_entry,
};

// `dir` is the joined-ident's resolved directory, or empty when the
// ident is known-unresolvable. We cache the unresolvable verdict too
// so the walker doesn't re-scan HAREPATH for the same `use io`
// import from every file in a deep dep graph.
type cache_entry = struct {
	ident: str,
	dir: str,
};

// @param c: borrowed
fn finish_dep_resolver_cache(c: *dep_resolver_ctx) void = {
	for (let i = 0z; i < len(c.cache); i += 1) {
		free(c.cache[i].ident);
		free(c.cache[i].dir);
	};
	free(c.cache);
};

// @param ctx: borrowed
// @param ident: borrowed
// @returns: owned
fn dep_resolver_fn(ctx: *opaque, ident: []str) (str | void) = {
	const c = ctx: *dep_resolver_ctx;
	const joined = strings::join("::", ident...)!;
	for (let i = 0z; i < len(c.cache); i += 1) {
		if (c.cache[i].ident != joined) continue;
		free(joined);
		if (len(c.cache[i].dir) == 0) return void;
		return strings::dup(c.cache[i].dir)!;
	};
	const (dir, sset) = match (find_module(c.s, ident)) {
	case let pair: (str, module::srcset) =>
		yield pair;
	case void =>
		append(c.cache, cache_entry {
			ident = joined,
			dir = strings::dup("")!,
		})!;
		return void;
	};
	let owned_set = sset;
	defer module::finish_srcset(&owned_set);
	// `dir` is borrowed from a static buffer inside module::find,
	// overwritten on the next call. Dup so the cache + walker both
	// hold stable strings.
	const dir_copy = strings::dup(dir)!;
	append(c.cache, cache_entry {
		ident = joined,
		dir = strings::dup(dir_copy)!,
	})!;
	return dir_copy;
};

// Joins workspace-folder paths and stdlib search paths with `:` into a
// single HAREPATH string. Caller frees.
//
// @param folders: borrowed
// @param stdlib: borrowed
// @returns: owned
fn compose_harepath(folders: []str, stdlib: []str) str = {
	let parts: []str = [];
	defer free(parts);
	for (let i = 0z; i < len(folders); i += 1) {
		append(parts, folders[i])!;
	};
	for (let i = 0z; i < len(stdlib); i += 1) {
		append(parts, stdlib[i])!;
	};
	return strings::join(":", parts...)!;
};

// Spawns `hare build -t o <module_dir>` with HAREPATH set, returns the
// parsed diagnostics. `cwd` is the working dir for the child;
// `timeout_ms` is the remaining slice of the whole-didSave budget for
// this one subprocess.
//
// @param s: borrowed
// @param module_dir: borrowed
// @param cwd: borrowed
// @param harepath: borrowed
// @returns: owned
fn run_build_obj(
	s: *server,
	module_dir: str,
	cwd: str,
	harepath: str,
	timeout_ms: u32,
) []build_diagnostic = {
	let argv: []str = [];
	defer free(argv);
	append(argv, "build")!;
	append(argv, "-t")!;
	append(argv, "o")!;
	// Discard the .o output: we only care about the diagnostics on
	// stderr. Without -o, hare writes `<module>.o` into cwd and litters
	// the workspace.
	append(argv, "-o")!;
	append(argv, "/dev/null")!;
	for (let i = 0z; i < len(s.config.tags); i += 1) {
		append(argv, "-T")!;
		append(argv, s.config.tags[i])!;
	};
	append(argv, module_dir)!;

	return spawn_hare_capture_stderr(s.config.hare_path, argv, cwd, harepath,
		timeout_ms);
};

// Appends `incoming` into `acc`, dropping entries that are duplicates
// (by path/line/col/message) of something already in `acc`. Transfers
// ownership of accepted entries; frees the rest.
//
// @param acc: borrowed
// @param incoming: owned
fn merge_dedup_diags(
	acc: *[]build_diagnostic,
	incoming: []build_diagnostic,
) void = {
	for (let i = 0z; i < len(incoming); i += 1) {
		if (build_diag_already_in(acc, incoming[i])) {
			free(incoming[i].path);
			free(incoming[i].kind);
			free(incoming[i].message);
			continue;
		};
		append(acc, incoming[i])!;
	};
	free(incoming);
};

// @param acc: borrowed
fn build_diag_already_in(acc: *[]build_diagnostic, d: build_diagnostic) bool = {
	for (let i = 0z; i < len(acc); i += 1) {
		const a = acc[i];
		if (a.line != d.line) continue;
		if (a.col != d.col) continue;
		if (a.kind != d.kind) continue;
		if (a.path != d.path) continue;
		if (a.message != d.message) continue;
		return true;
	};
	return false;
};
