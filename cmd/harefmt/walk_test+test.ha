// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use fmt;
use fs;
use io;
use os;
use os::exec;
use strings;

// Visited-paths accumulator passed through descend() via userdata.
type visited = struct {
	paths: []str,
};

fn collect_cb(file_path: str, ud: nullable *opaque) void = {
	const v = ud: *visited;
	append(v.paths, strings::dup(file_path)!)!;
};

fn finish_visited(v: *visited) void = {
	for (let i = 0z; i < len(v.paths); i += 1) {
		free(v.paths[i]);
	};
	free(v.paths);
};

fn make_dir(p: str) void = {
	os::mkdirs(p, 0o755: fs::mode)!;
};

fn write_test_file(path: str, content: str) void = {
	const f =
		os::create(path, 0o644: fs::mode, fs::flag::WRONLY | fs::flag::TRUNC)!;
	defer io::close(f)!;
	io::writeall(f, strings::toutf8(content))!;
};

fn contains(paths: []str, needle: str) bool = {
	for (let i = 0z; i < len(paths); i += 1) {
		if (paths[i] == needle) return true;
	};
	return false;
};

fn cleanup(root: str) void = {
	match (os::rmdirall(root)) {
	case void => void;
	case fs::error => void;
	};
};

// stdlib's os::symlink isn't implemented on Darwin's dirfd-based fs,
// so the symlink tests shell out to `ln -s`. `target` is what the
// symlink resolves to (interpreted relative to `link_path`'s parent);
// `link_path` is where the symlink is created.
fn make_symlink(target: str, link_path: str) void = {
	let cmd = exec::cmd("ln", "-s", target, link_path)!;
	const proc = exec::start(&cmd)!;
	const st = exec::wait(&proc)!;
	assert(exec::exit(&st) == 0, "ln -s failed");
};

// Helper: invoke a descent and collect the file paths visited.
fn walk_collect(root: str, opts: ignore_opts) []str = {
	const layers = collect_ancestors(root, opts);
	defer finish_layers(layers);
	let v = visited { paths = [] };
	descend(root, layers, opts, &collect_cb, &v);
	return v.paths;
};

@test fn walk_visits_ha_files() void = {
	const root = ".tmp/harefmt-walk-basic";
	cleanup(root);
	make_dir(root);
	defer cleanup(root);
	write_test_file(strings::concat(root, "/a.ha")!, "fn a() void = void;\n");
	write_test_file(strings::concat(root, "/b.txt")!, "not hare\n");
	make_dir(strings::concat(root, "/sub")!);
	write_test_file(strings::concat(root, "/sub/c.ha")!, "fn c() void = void;\n");

	const paths = walk_collect(os::resolve(root), default_opts());
	defer {
		for (let i = 0z; i < len(paths); i += 1) free(paths[i]);
		free(paths);
	};

	assert(contains(paths, strings::concat(os::resolve(root), "/a.ha")!));
	assert(contains(paths, strings::concat(os::resolve(root), "/sub/c.ha")!));
	assert(!contains(paths, strings::concat(os::resolve(root), "/b.txt")!));
};

@test fn walk_respects_harefmtignore() void = {
	const root = ".tmp/harefmt-walk-ignore";
	cleanup(root);
	make_dir(root);
	defer cleanup(root);
	write_test_file(strings::concat(root, "/a.ha")!, "fn a() void = void;\n");
	write_test_file(strings::concat(root, "/b.skip.ha")!, "fn b() void = void;\n");
	write_test_file(strings::concat(root, "/.harefmtignore")!, "*.skip.ha\n");

	const abs = os::resolve(root);
	const paths = walk_collect(abs, default_opts());
	defer {
		for (let i = 0z; i < len(paths); i += 1) free(paths[i]);
		free(paths);
	};

	assert(contains(paths, strings::concat(abs, "/a.ha")!));
	assert(!contains(paths, strings::concat(abs, "/b.skip.ha")!));
};

@test fn walk_negation_reincludes_file() void = {
	// `*.skip.ha` ignores, `!keep.skip.ha` un-ignores. Verifies the
	// negation pattern works through layer evaluation.
	const root = ".tmp/harefmt-walk-negation";
	cleanup(root);
	make_dir(root);
	defer cleanup(root);
	write_test_file(strings::concat(root, "/keep.skip.ha")!,
		"fn k() void = void;\n");
	write_test_file(strings::concat(root, "/noise.skip.ha")!,
		"fn n() void = void;\n");
	write_test_file(strings::concat(root, "/.harefmtignore")!,
		"*.skip.ha\n!keep.skip.ha\n");

	const abs = os::resolve(root);
	const paths = walk_collect(abs, default_opts());
	defer {
		for (let i = 0z; i < len(paths); i += 1) free(paths[i]);
		free(paths);
	};

	assert(contains(paths, strings::concat(abs, "/keep.skip.ha")!));
	assert(!contains(paths, strings::concat(abs, "/noise.skip.ha")!));
};

@test fn walk_excluded_dir_blocks_unignore() void = {
	// gitignore: "It is not possible to re-include a file if a parent
	// directory of that file is excluded." With `vendor/` followed by
	// `!vendor/keep.ha`, vendor/ is pruned outright and keep.ha is
	// never visited.
	const root = ".tmp/harefmt-walk-prune";
	cleanup(root);
	make_dir(root);
	defer cleanup(root);
	make_dir(strings::concat(root, "/vendor")!);
	write_test_file(strings::concat(root, "/vendor/keep.ha")!,
		"fn k() void = void;\n");
	write_test_file(strings::concat(root, "/.harefmtignore")!,
		"vendor/\n!vendor/keep.ha\n");
	write_test_file(strings::concat(root, "/top.ha")!, "fn t() void = void;\n");

	const abs = os::resolve(root);
	const paths = walk_collect(abs, default_opts());
	defer {
		for (let i = 0z; i < len(paths); i += 1) free(paths[i]);
		free(paths);
	};

	assert(contains(paths, strings::concat(abs, "/top.ha")!));
	assert(!contains(paths, strings::concat(abs, "/vendor/keep.ha")!));
};

@test fn walk_gitignore_honored_by_default() void = {
	// A .gitignore in the walk root is consulted just like a
	// .harefmtignore; both files share gitignore syntax.
	const root = ".tmp/harefmt-walk-gitignore";
	cleanup(root);
	make_dir(root);
	defer cleanup(root);
	write_test_file(strings::concat(root, "/keep.ha")!, "fn k() void = void;\n");
	write_test_file(strings::concat(root, "/gen.ha")!, "fn g() void = void;\n");
	write_test_file(strings::concat(root, "/.gitignore")!, "gen.ha\n");

	const abs = os::resolve(root);
	const paths = walk_collect(abs, default_opts());
	defer {
		for (let i = 0z; i < len(paths); i += 1) free(paths[i]);
		free(paths);
	};

	assert(contains(paths, strings::concat(abs, "/keep.ha")!));
	assert(!contains(paths, strings::concat(abs, "/gen.ha")!));
};

@test fn walk_no_gitignore_flag_skips_gitignore() void = {
	const root = ".tmp/harefmt-walk-no-gi";
	cleanup(root);
	make_dir(root);
	defer cleanup(root);
	write_test_file(strings::concat(root, "/keep.ha")!, "fn k() void = void;\n");
	write_test_file(strings::concat(root, "/gen.ha")!, "fn g() void = void;\n");
	write_test_file(strings::concat(root, "/.gitignore")!, "gen.ha\n");

	let opts = default_opts();
	opts.use_gitignore = false;
	const abs = os::resolve(root);
	const paths = walk_collect(abs, opts);
	defer {
		for (let i = 0z; i < len(paths); i += 1) free(paths[i]);
		free(paths);
	};

	assert(contains(paths, strings::concat(abs, "/keep.ha")!));
	assert(contains(paths, strings::concat(abs, "/gen.ha")!));
};

@test fn walk_nested_ignore_overrides_outer() void = {
	// Outer ignores *.tmp.ha; inner subdir un-ignores keep.tmp.ha.
	// Only files inside the inner dir get the un-ignore.
	const root = ".tmp/harefmt-walk-nested";
	cleanup(root);
	make_dir(root);
	defer cleanup(root);
	make_dir(strings::concat(root, "/sub")!);
	write_test_file(strings::concat(root, "/.harefmtignore")!, "*.tmp.ha\n");
	write_test_file(strings::concat(root, "/outer.tmp.ha")!,
		"fn a() void = void;\n");
	write_test_file(strings::concat(root, "/sub/.harefmtignore")!,
		"!keep.tmp.ha\n");
	write_test_file(strings::concat(root, "/sub/keep.tmp.ha")!,
		"fn k() void = void;\n");
	write_test_file(strings::concat(root, "/sub/other.tmp.ha")!,
		"fn o() void = void;\n");

	const abs = os::resolve(root);
	const paths = walk_collect(abs, default_opts());
	defer {
		for (let i = 0z; i < len(paths); i += 1) free(paths[i]);
		free(paths);
	};

	assert(!contains(paths, strings::concat(abs, "/outer.tmp.ha")!));
	assert(contains(paths, strings::concat(abs, "/sub/keep.tmp.ha")!));
	assert(!contains(paths, strings::concat(abs, "/sub/other.tmp.ha")!));
};

@test fn walk_skips_symlinked_dir_by_default() void = {
	const root = ".tmp/harefmt-walk-symdir";
	cleanup(root);
	make_dir(root);
	defer cleanup(root);
	make_dir(strings::concat(root, "/real")!);
	write_test_file(strings::concat(root, "/real/a.ha")!, "fn a() void = void;\n");
	// Symlink at root level pointing to the real dir.
	const link_path = strings::concat(root, "/link")!;
	defer free(link_path);
	make_symlink("real", link_path);

	const abs = os::resolve(root);
	const paths = walk_collect(abs, default_opts());
	defer {
		for (let i = 0z; i < len(paths); i += 1) free(paths[i]);
		free(paths);
	};

	// Real dir entered.
	assert(contains(paths, strings::concat(abs, "/real/a.ha")!));
	// Symlink dir NOT followed (default).
	assert(!contains(paths, strings::concat(abs, "/link/a.ha")!));
};

@test fn walk_follow_dir_symlinks_enters_symlinked_dirs() void = {
	const root = ".tmp/harefmt-walk-symdir-follow";
	cleanup(root);
	make_dir(root);
	defer cleanup(root);
	make_dir(strings::concat(root, "/real")!);
	write_test_file(strings::concat(root, "/real/a.ha")!, "fn a() void = void;\n");
	make_symlink("real", strings::concat(root, "/link")!);

	let opts = default_opts();
	opts.follow_dir_symlinks = true;
	const abs = os::resolve(root);
	const paths = walk_collect(abs, opts);
	defer {
		for (let i = 0z; i < len(paths); i += 1) free(paths[i]);
		free(paths);
	};

	assert(contains(paths, strings::concat(abs, "/real/a.ha")!));
	assert(contains(paths, strings::concat(abs, "/link/a.ha")!));
};

@test fn walk_follows_file_symlinks_by_default() void = {
	const root = ".tmp/harefmt-walk-symfile";
	cleanup(root);
	make_dir(root);
	defer cleanup(root);
	write_test_file(strings::concat(root, "/real.ha")!, "fn r() void = void;\n");
	make_symlink("real.ha", strings::concat(root, "/link.ha")!);

	const abs = os::resolve(root);
	const paths = walk_collect(abs, default_opts());
	defer {
		for (let i = 0z; i < len(paths); i += 1) free(paths[i]);
		free(paths);
	};

	assert(contains(paths, strings::concat(abs, "/real.ha")!));
	assert(contains(paths, strings::concat(abs, "/link.ha")!));
};

@test fn walk_no_follow_file_symlinks_skips_symlinked_files() void = {
	const root = ".tmp/harefmt-walk-symfile-skip";
	cleanup(root);
	make_dir(root);
	defer cleanup(root);
	write_test_file(strings::concat(root, "/real.ha")!, "fn r() void = void;\n");
	make_symlink("real.ha", strings::concat(root, "/link.ha")!);

	let opts = default_opts();
	opts.follow_file_symlinks = false;
	const abs = os::resolve(root);
	const paths = walk_collect(abs, opts);
	defer {
		for (let i = 0z; i < len(paths); i += 1) free(paths[i]);
		free(paths);
	};

	assert(contains(paths, strings::concat(abs, "/real.ha")!));
	assert(!contains(paths, strings::concat(abs, "/link.ha")!));
};
