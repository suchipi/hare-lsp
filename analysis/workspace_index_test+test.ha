// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use fs;
use io;
use os;
use strings;

@test fn index_file_collects_decls_for_workspace() void = {
	let idx = new_workspace_index();
	defer finish_workspace_index(&idx);

	const text = strings::toutf8(
		"export fn alpha() void = void;\nfn beta() void = void;\n");
	index_file(&idx, "/repo/a.ha", text);
	assert(len(idx.entries) == 2);
	assert(idx.entries[0].path == "/repo/a.ha");
	assert(idx.entries[0].uri == "file:///repo/a.ha");
	assert(idx.entries[0].short_name == "alpha");
	assert(idx.entries[1].short_name == "beta");
};

@test fn re_indexing_a_file_replaces_its_entries() void = {
	let idx = new_workspace_index();
	defer finish_workspace_index(&idx);

	index_file(&idx, "/repo/a.ha", strings::toutf8("fn one() void = void;\n"));
	assert(len(idx.entries) == 1);

	index_file(&idx, "/repo/a.ha",
		strings::toutf8("fn two() void = void;\nfn three() void = void;\n"));
	assert(len(idx.entries) == 2);
	assert(idx.entries[0].short_name == "two");
};

@test fn drop_file_removes_entries() void = {
	let idx = new_workspace_index();
	defer finish_workspace_index(&idx);
	index_file(&idx, "/a.ha", strings::toutf8("fn x() void = void;\n"));
	index_file(&idx, "/b.ha", strings::toutf8("fn y() void = void;\n"));
	assert(len(idx.entries) == 2);
	drop_file(&idx, "/a.ha");
	assert(len(idx.entries) == 1);
	assert(idx.entries[0].short_name == "y");
};

@test fn lookup_by_short_name_returns_matches() void = {
	let idx = new_workspace_index();
	defer finish_workspace_index(&idx);
	index_file(&idx, "/a.ha", strings::toutf8("fn target() void = void;\n"));
	index_file(&idx, "/b.ha", strings::toutf8("fn target() void = void;\n"));
	const matches = lookup_by_short_name(&idx, "target");
	defer free(matches);
	assert(len(matches) == 2);
};

// collect_ha_files must return every .ha file under the root,
// recursively, and skip non-.ha files. Mirrors the discovery half of
// index_directory so the chunked indexing job can reuse it.
@test fn collect_ha_files_walks_recursively() void = {
	// Create a temporary tree under .tmp/ with one .ha file and one
	// non-.ha file, plus a nested subdir.
	const root = ".tmp/hare-lsp-collect-ha-files-test";
	const sub = ".tmp/hare-lsp-collect-ha-files-test/sub";
	match (os::mkdirs(sub, 0o755: fs::mode)) {
	case void => void;
	case fs::error =>
		return;
	};
	defer match (os::rmdirall(root)) {
	case => void;
	};
	write_tmp(".tmp/hare-lsp-collect-ha-files-test/a.ha", "fn x() void = void;\n");
	write_tmp(".tmp/hare-lsp-collect-ha-files-test/sub/b.ha",
		"fn y() void = void;\n");
	write_tmp(".tmp/hare-lsp-collect-ha-files-test/notes.txt", "ignore me");

	const paths = collect_ha_files(root);
	defer free_path_slice(paths);
	// Expect 2 .ha files; order is filesystem-dependent, but the set
	// must match.
	let has_a = false, has_b = false, has_notes = false;
	for (let i = 0z; i < len(paths); i += 1) {
		if (strings::hassuffix(paths[i], "/a.ha")) has_a = true;
		if (strings::hassuffix(paths[i], "/sub/b.ha")) has_b = true;
		if (strings::hassuffix(paths[i], "notes.txt")) has_notes = true;
	};
	assert(has_a, "must collect top-level .ha file");
	assert(has_b, "must recurse into subdirs");
	assert(!has_notes, "must skip non-.ha files");
};

fn write_tmp(path: str, body: str) void = {
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

// A `@test fn` must never win a navigation lookup against a real
// implementation of the same name. We index the test file FIRST so that a
// naive first-match lookup would return the test entry; the navigation
// lookups must skip it and resolve to the real `export fn`. Regression
// test for go-to-definition on `mime::lookup_ext` landing on the
// same-named `@test fn` in mime/entries+test.ha.
@test fn navigation_lookups_skip_test_functions() void = {
	let idx = new_workspace_index();
	defer finish_workspace_index(&idx);

	index_file(&idx, "/repo/mime/entries+test.ha",
		strings::toutf8("@test fn lookup_ext() void = void;\n"));
	index_file(&idx, "/repo/mime/lookup.ha",
		strings::toutf8("export fn lookup_ext() void = void;\n"));

	// Both decls are still indexed (so document-symbol / workspace-symbol
	// keep listing tests); only the navigation lookups skip the test one.
	let saw_test = false, saw_real = false;
	for (let i = 0z; i < len(idx.entries); i += 1) {
		if (idx.entries[i].short_name != "lookup_ext") continue;
		if (idx.entries[i].is_test) {
			saw_test = true;
		} else {
			saw_real = true;
		};
	};
	assert(saw_test, "@test fn should still be indexed");
	assert(saw_real, "real fn should still be indexed");

	const e = find_in_module(&idx, "mime", "lookup_ext") as *workspace_entry;
	assert(!e.is_test, "find_in_module must skip @test fn");
	assert(strings::hassuffix(e.path, "/lookup.ha"));

	let imp: []str = ["mime"];
	const e2 = find_in_imports(&idx, imp, "lookup_ext") as *workspace_entry;
	assert(!e2.is_test, "find_in_imports must skip @test fn");

	const e3 = find_first_by_short_name(&idx, "lookup_ext") as *workspace_entry;
	assert(!e3.is_test, "find_first_by_short_name must skip @test fn");
};

// When the only declaration of a name is a `@test fn`, navigation must not
// resolve to it at all — "go-to-definition should not consider functions
// with the @test attribute" means returning no target, not the test fn.
@test fn navigation_lookups_ignore_test_only_names() void = {
	let idx = new_workspace_index();
	defer finish_workspace_index(&idx);
	index_file(&idx, "/repo/mime/entries+test.ha",
		strings::toutf8("@test fn only_in_test() void = void;\n"));
	assert(find_in_module(&idx, "mime", "only_in_test") is void);
	assert(find_first_by_short_name(&idx, "only_in_test") is void);
	let imp: []str = ["mime"];
	assert(find_in_imports(&idx, imp, "only_in_test") is void);
};

@test fn fuzzy_search_substring_match() void = {
	let idx = new_workspace_index();
	defer finish_workspace_index(&idx);
	index_file(&idx, "/a.ha",
		strings::toutf8("fn parse_thing() void = void;\nfn other() void = void;\n"));
	const m = fuzzy_search(&idx, "PARSE");
	defer free(m);
	assert(len(m) == 1);
	assert(idx.entries[m[0]].short_name == "parse_thing");
};
