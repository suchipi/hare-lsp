// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Tests for `hare.tags` plumbing through module::find (used by hover /
// definition / completion) and the executeCommand spawn path.

use bufio;
use fs;
use hare::module;
use io;
use memio;
use os;
use strings;

@test fn config_tags_to_module_tags_strips_plus_prefix() void = {
	let cfg: []str = ["+linux", "+x86_64"];
	const out = config_tags_to_module_tags(cfg);
	defer free(out);
	assert(len(out) == 2);
	assert(out[0] == "linux");
	assert(out[1] == "x86_64");
};

@test fn config_tags_to_module_tags_drops_minus_prefix() void = {
	// `-tag` in the user-facing form means "tag should be unset"; the
	// bare-name model `module::context.tags` uses already treats absence
	// as unset, so these entries contribute nothing.
	let cfg: []str = ["+linux", "-libc"];
	const out = config_tags_to_module_tags(cfg);
	defer free(out);
	assert(len(out) == 1);
	assert(out[0] == "linux");
};

@test fn config_tags_to_module_tags_passes_bare_names_through() void = {
	// Defensive: clients that omit the `+` prefix for the inclusive
	// case should still get the tag enabled.
	let cfg: []str = ["linux"];
	const out = config_tags_to_module_tags(cfg);
	defer free(out);
	assert(len(out) == 1);
	assert(out[0] == "linux");
};

@test fn config_tags_to_module_tags_skips_empty_entries() void = {
	let cfg: []str = ["", "+linux", ""];
	const out = config_tags_to_module_tags(cfg);
	defer free(out);
	assert(len(out) == 1);
	assert(out[0] == "linux");
};

@test fn config_tags_to_module_tags_empty_input() void = {
	let cfg: []str = [];
	const out = config_tags_to_module_tags(cfg);
	defer free(out);
	assert(len(out) == 0);
};

// End-to-end: with a tag-gated source file on disk, configuring the
// matching `+tag` in `s.config.tags` should make `module::find` (via
// `find_module`) include that file in the srcset.
@test fn find_module_honors_config_tags() void = {
	let out = memio::dynamic();
	defer io::close(&out)!;
	let in_buf = alloc(memio::fixed([]))!;
	defer free(in_buf);
	let scan = alloc(bufio::newscanner(in_buf))!;
	defer {
		bufio::finish(scan);
		free(scan);
	};
	let s = new(scan, &out, void);
	defer finish(&s);

	// Self-contained scratch per .claude/rules/test-fixtures-and-tmp-dir.md:
	// create, exercise, clean up within this test. Unique paths so this
	// test doesn't collide with parallel ones.
	const mod_dir = ".tmp/hare-lsp-tags-find-module-ws/mymod";
	const always_path = ".tmp/hare-lsp-tags-find-module-ws/mymod/always.ha";
	const tagged_path =
		".tmp/hare-lsp-tags-find-module-ws/mymod/tagged+harelsptesttag.ha";
	tags_mkdir_p(mod_dir);
	tags_write(always_path, "export let always_v: int = 1;\n");
	tags_write(tagged_path, "export let tagged_v: int = 2;\n");
	defer {
		tags_rm(always_path);
		tags_rm(tagged_path);
		tags_rmdir(mod_dir);
		tags_rmdir(".tmp/hare-lsp-tags-find-module-ws");
	};

	// Resolve the workspace dir to an absolute path so the synthetic
	// file:// URI is well-formed regardless of cwd.
	const abs_ws = match (os::realpath(".tmp/hare-lsp-tags-find-module-ws")) {
	case let p: str =>
		yield strings::dup(p)!;
	case fs::error => abort("realpath(.tmp workspace) failed");
	};
	defer free(abs_ws);
	let folders: []workspace_folder = [];
	append(folders, workspace_folder {
		uri = strings::concat("file://", abs_ws)!,
		name = strings::dup("ws")!,
	})!;
	set_workspace_folders(&s, folders);

	// Configure the tag so the tagged file is selected.
	append(s.config.tags, strings::dup("+harelsptesttag")!)!;

	let ident: []str = ["mymod"];
	match (find_module(&s, ident)) {
	case let pair: (str, module::srcset) =>
		let srcs = pair.1;
		defer module::finish_srcset(&srcs);
		assert(
			len(srcs.ha) == 2,
			"with +harelsptesttag set, both always.ha and the"
			" +harelsptesttag-tagged file should be in the srcset"
		);
	case void => abort("find_module failed to resolve mymod");
	};
};

fn tags_write(path: str, text: str) void = {
	const f = match (os::create(path, 0o644)) {
	case let f: io::file =>
		yield f;
	case fs::error => abort("tags_write: cannot create file");
	};
	defer io::close(f)!;
	io::writeall(f, strings::toutf8(text))!;
};

fn tags_mkdir_p(path: str) void = {
	// Best-effort; tolerate "already exists" but also create missing
	// parents (the test runs from the repo root and `.tmp/` itself may
	// not exist yet on a clean checkout).
	match (os::mkdirs(path, 0o755)) {
	case => void;
	};
};

fn tags_rm(path: str) void = {
	match (os::remove(path)) {
	case => void;
	};
};

fn tags_rmdir(path: str) void = {
	match (os::rmdir(path)) {
	case => void;
	};
};
