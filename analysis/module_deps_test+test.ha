// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use fs;
use io;
use os;
use strings;

// Fixture map for the stub resolver: each entry is (`a::b::c`, dir).
type md_fixture = struct {
	idents: []str,
	dirs: []str,
};

fn md_resolver(ctx: *opaque, ident: []str) (str | void) = {
	const fx = ctx: *md_fixture;
	const joined = strings::join("::", ident...)!;
	defer free(joined);
	for (let i = 0z; i < len(fx.idents); i += 1) {
		if (fx.idents[i] == joined) return strings::dup(fx.dirs[i])!;
	};
	return void;
};

fn md_mkdirs(path: str) void = {
	match (os::mkdirs(path, 0o755: fs::mode)) {
	case void => void;
	case fs::error => void;
	};
};

fn md_write(path: str, body: str) void = {
	const f = match (os::create(path, 0o644: fs::mode)) {
	case let f: io::file =>
		yield f;
	case fs::error =>
		return;
	};
	defer match (io::close(f)) {
	case => void;
	};
	const _ = io::writeall(f, strings::toutf8(body));
};

fn md_rmtree(path: str) void = {
	match (os::rmdirall(path)) {
	case => void;
	};
};

// Returns true iff `order` contains a dep whose `dir` ends with the
// given trailing path segment.
fn md_order_has_suffix(order: []module_dep, suffix: str) bool = {
	for (let i = 0z; i < len(order); i += 1) {
		if (strings::hassuffix(order[i].dir, suffix)) return true;
	};
	return false;
};

// Returns the index (in `order`) of the first dep whose `dir` ends
// with `suffix`, or -1 if none.
fn md_order_index_of(order: []module_dep, suffix: str) int = {
	for (let i = 0z; i < len(order); i += 1) {
		if (strings::hassuffix(order[i].dir, suffix)) return i: int;
	};
	return -1;
};

@test fn module_deps_empty_dir_returns_self_only() void = {
	const root = ".tmp/hare-lsp-md-empty";
	md_mkdirs(root);
	defer md_rmtree(root);

	let fx = md_fixture { idents = [], dirs = [] };
	const order = build_order(root, [root], &md_resolver, &fx: *opaque);
	defer finish_build_order(order);
	assert(len(order) == 1);
	assert(order[0].dir == root);
	assert(order[0].use_ident == "");
};

@test fn module_deps_no_imports_returns_self_only() void = {
	const root = ".tmp/hare-lsp-md-no-imports";
	md_mkdirs(root);
	defer md_rmtree(root);
	md_write(strings::concat(root, "/a.ha")!, "export fn a() void = void;\n");

	let fx = md_fixture { idents = [], dirs = [] };
	const order = build_order(root, [root], &md_resolver, &fx: *opaque);
	defer finish_build_order(order);
	assert(len(order) == 1);
	assert(order[0].dir == root);
};

@test fn module_deps_one_local_dep_built_first() void = {
	const root = ".tmp/hare-lsp-md-one-local";
	const app = strings::concat(root, "/app")!;
	defer free(app);
	const lib = strings::concat(root, "/lib")!;
	defer free(lib);
	md_mkdirs(app);
	md_mkdirs(lib);
	defer md_rmtree(root);
	md_write(strings::concat(app, "/main.ha")!,
		"use lib;\nexport fn main() void = void;\n");
	md_write(strings::concat(lib, "/x.ha")!, "export fn helper() void = void;\n");

	let idents: []str = [];
	defer free(idents);
	append(idents, "lib")!;
	let dirs: []str = [];
	defer free(dirs);
	append(dirs, lib)!;
	let fx = md_fixture { idents = idents, dirs = dirs };

	const order = build_order(app, [root], &md_resolver, &fx: *opaque);
	defer finish_build_order(order);
	assert(len(order) == 2);
	assert(strings::hassuffix(order[0].dir, "/lib"));
	assert(order[0].use_ident == "lib");
	assert(strings::hassuffix(order[1].dir, "/app"));
	assert(order[1].use_ident == "");
};

@test fn module_deps_external_dep_skipped() void = {
	const root = ".tmp/hare-lsp-md-external";
	const app = strings::concat(root, "/app")!;
	defer free(app);
	md_mkdirs(app);
	defer md_rmtree(root);
	md_write(strings::concat(app, "/main.ha")!,
		"use io;\nexport fn main() void = void;\n");

	let idents: []str = [];
	defer free(idents);
	append(idents, "io")!;
	let dirs: []str = [];
	defer free(dirs);
	// io resolves to a path OUTSIDE the workspace.
	append(dirs, "/usr/local/src/hare/stdlib/io")!;
	let fx = md_fixture { idents = idents, dirs = dirs };

	const order = build_order(app, [root], &md_resolver, &fx: *opaque);
	defer finish_build_order(order);
	assert(len(order) == 1);
	assert(strings::hassuffix(order[0].dir, "/app"));
};

@test fn module_deps_unresolvable_ident_skipped() void = {
	const root = ".tmp/hare-lsp-md-unresolvable";
	const app = strings::concat(root, "/app")!;
	defer free(app);
	md_mkdirs(app);
	defer md_rmtree(root);
	md_write(strings::concat(app, "/main.ha")!,
		"use mystery;\nexport fn main() void = void;\n");

	let fx = md_fixture { idents = [], dirs = [] };
	const order = build_order(app, [root], &md_resolver, &fx: *opaque);
	defer finish_build_order(order);
	assert(len(order) == 1);
};

@test fn module_deps_transitive_chain_topologically_sorted() void = {
	const root = ".tmp/hare-lsp-md-chain";
	const a = strings::concat(root, "/a")!;
	defer free(a);
	const b = strings::concat(root, "/b")!;
	defer free(b);
	const c = strings::concat(root, "/c")!;
	defer free(c);
	md_mkdirs(a);
	md_mkdirs(b);
	md_mkdirs(c);
	defer md_rmtree(root);
	md_write(strings::concat(a, "/x.ha")!, "use b;\nexport fn x() void = void;\n");
	md_write(strings::concat(b, "/x.ha")!, "use c;\nexport fn x() void = void;\n");
	md_write(strings::concat(c, "/x.ha")!, "export fn x() void = void;\n");

	let idents: []str = [];
	defer free(idents);
	append(idents, "b")!;
	append(idents, "c")!;
	let dirs: []str = [];
	defer free(dirs);
	append(dirs, b)!;
	append(dirs, c)!;
	let fx = md_fixture { idents = idents, dirs = dirs };

	const order = build_order(a, [root], &md_resolver, &fx: *opaque);
	defer finish_build_order(order);
	assert(len(order) == 3);
	const ic = md_order_index_of(order, "/c");
	const ib = md_order_index_of(order, "/b");
	const ia = md_order_index_of(order, "/a");
	assert(ic >= 0 && ib >= 0 && ia >= 0);
	assert(ic < ib);
	assert(ib < ia);
};

@test fn module_deps_diamond_each_dep_once() void = {
	const root = ".tmp/hare-lsp-md-diamond";
	const a = strings::concat(root, "/a")!;
	defer free(a);
	const b = strings::concat(root, "/b")!;
	defer free(b);
	const c = strings::concat(root, "/c")!;
	defer free(c);
	const d = strings::concat(root, "/d")!;
	defer free(d);
	md_mkdirs(a);
	md_mkdirs(b);
	md_mkdirs(c);
	md_mkdirs(d);
	defer md_rmtree(root);
	// a -> b, a -> c, b -> d, c -> d.
	md_write(strings::concat(a, "/x.ha")!,
		"use b;\nuse c;\nexport fn x() void = void;\n");
	md_write(strings::concat(b, "/x.ha")!, "use d;\nexport fn x() void = void;\n");
	md_write(strings::concat(c, "/x.ha")!, "use d;\nexport fn x() void = void;\n");
	md_write(strings::concat(d, "/x.ha")!, "export fn x() void = void;\n");

	let idents: []str = [];
	defer free(idents);
	append(idents, "b")!;
	append(idents, "c")!;
	append(idents, "d")!;
	let dirs: []str = [];
	defer free(dirs);
	append(dirs, b)!;
	append(dirs, c)!;
	append(dirs, d)!;
	let fx = md_fixture { idents = idents, dirs = dirs };

	const order = build_order(a, [root], &md_resolver, &fx: *opaque);
	defer finish_build_order(order);
	assert(len(order) == 4);
	const id = md_order_index_of(order, "/d");
	const ib = md_order_index_of(order, "/b");
	const ic = md_order_index_of(order, "/c");
	const ia = md_order_index_of(order, "/a");
	assert(id < ib);
	assert(id < ic);
	assert(ib < ia);
	assert(ic < ia);
};

@test fn module_deps_cycle_terminates() void = {
	const root = ".tmp/hare-lsp-md-cycle";
	const a = strings::concat(root, "/a")!;
	defer free(a);
	const b = strings::concat(root, "/b")!;
	defer free(b);
	md_mkdirs(a);
	md_mkdirs(b);
	defer md_rmtree(root);
	md_write(strings::concat(a, "/x.ha")!, "use b;\nexport fn x() void = void;\n");
	md_write(strings::concat(b, "/x.ha")!, "use a;\nexport fn x() void = void;\n");

	let idents: []str = [];
	defer free(idents);
	append(idents, "a")!;
	append(idents, "b")!;
	let dirs: []str = [];
	defer free(dirs);
	append(dirs, a)!;
	append(dirs, b)!;
	let fx = md_fixture { idents = idents, dirs = dirs };

	const order = build_order(a, [root], &md_resolver, &fx: *opaque);
	defer finish_build_order(order);
	assert(len(order) == 2);
	assert(md_order_has_suffix(order, "/a"));
	assert(md_order_has_suffix(order, "/b"));
};

@test fn module_deps_multifile_module_union_of_uses() void = {
	const root = ".tmp/hare-lsp-md-multifile";
	const app = strings::concat(root, "/app")!;
	defer free(app);
	const u = strings::concat(root, "/u")!;
	defer free(u);
	const v = strings::concat(root, "/v")!;
	defer free(v);
	md_mkdirs(app);
	md_mkdirs(u);
	md_mkdirs(v);
	defer md_rmtree(root);
	md_write(strings::concat(app, "/a.ha")!,
		"use u;\nexport fn aa() void = void;\n");
	md_write(strings::concat(app, "/b.ha")!,
		"use v;\nexport fn bb() void = void;\n");
	md_write(strings::concat(u, "/x.ha")!, "export fn ux() void = void;\n");
	md_write(strings::concat(v, "/x.ha")!, "export fn vx() void = void;\n");

	let idents: []str = [];
	defer free(idents);
	append(idents, "u")!;
	append(idents, "v")!;
	let dirs: []str = [];
	defer free(dirs);
	append(dirs, u)!;
	append(dirs, v)!;
	let fx = md_fixture { idents = idents, dirs = dirs };

	const order = build_order(app, [root], &md_resolver, &fx: *opaque);
	defer finish_build_order(order);
	assert(len(order) == 3);
	assert(md_order_has_suffix(order, "/u"));
	assert(md_order_has_suffix(order, "/v"));
	const ia = md_order_index_of(order, "/app");
	const iu = md_order_index_of(order, "/u");
	const iv = md_order_index_of(order, "/v");
	assert(iu < ia);
	assert(iv < ia);
};

@test fn has_test_tag_no_tags_false() void = {
	assert(!has_test_tag("foo.ha"));
};

@test fn has_test_tag_basic_test_true() void = {
	assert(has_test_tag("foo+test.ha"));
};

@test fn has_test_tag_test_with_other_tag_true() void = {
	assert(has_test_tag("foo+test+libc.ha"));
	assert(has_test_tag("foo+libc+test.ha"));
};

@test fn has_test_tag_non_test_tag_false() void = {
	assert(!has_test_tag("foo+libc.ha"));
	assert(!has_test_tag("foo+darwin.ha"));
};

@test fn has_test_tag_not_a_ha_file_false() void = {
	assert(!has_test_tag("foo+test.txt"));
};

@test fn module_deps_test_files_skipped() void = {
	const root = ".tmp/hare-lsp-md-testfiles";
	const app = strings::concat(root, "/app")!;
	defer free(app);
	const testonly = strings::concat(root, "/testonly")!;
	defer free(testonly);
	md_mkdirs(app);
	md_mkdirs(testonly);
	defer md_rmtree(root);
	md_write(strings::concat(app, "/main.ha")!, "export fn main() void = void;\n");
	// A +test file references `testonly` — should be ignored by the
	// production-style dep walk.
	md_write(strings::concat(app, "/main_test+test.ha")!,
		"use testonly;\n@test fn t() void = void;\n");
	// Multi-tag form (`+test+libc.ha`) must also be skipped: Hare
	// accepts tag-suffixes in any order, so this file is still gated
	// to the +test build.
	md_write(strings::concat(app, "/multi+test+libc.ha")!,
		"use testonly;\n@test fn u() void = void;\n");
	md_write(strings::concat(testonly, "/x.ha")!, "export fn x() void = void;\n");

	let idents: []str = [];
	defer free(idents);
	append(idents, "testonly")!;
	let dirs: []str = [];
	defer free(dirs);
	append(dirs, testonly)!;
	let fx = md_fixture { idents = idents, dirs = dirs };

	const order = build_order(app, [root], &md_resolver, &fx: *opaque);
	defer finish_build_order(order);
	assert(len(order) == 1);
	assert(strings::hassuffix(order[0].dir, "/app"));
};
