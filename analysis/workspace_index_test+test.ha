// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use fs;
use io;
use os;
use strings;

@test fn index_file_collects_decls_for_workspace() void = {
	let idx = new_workspace_index();
	defer finish_workspace_index(&idx);

	const text = strings::toutf8("export fn alpha() void = void;\nfn beta() void = void;\n");
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

	index_file(&idx, "/repo/a.ha", strings::toutf8("fn two() void = void;\nfn three() void = void;\n"));
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
	case fs::error => return;
	};
	defer match (os::rmdirall(root)) { case => void; };
	write_tmp(".tmp/hare-lsp-collect-ha-files-test/a.ha",
		"fn x() void = void;\n");
	write_tmp(".tmp/hare-lsp-collect-ha-files-test/sub/b.ha",
		"fn y() void = void;\n");
	write_tmp(".tmp/hare-lsp-collect-ha-files-test/notes.txt",
		"ignore me");

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
	case let f: io::file => yield f;
	case fs::error => return;
	};
	defer match (io::close(f)) { case => void; };
	const _ = io::writeall(f, strings::toutf8(body));
};

@test fn fuzzy_search_substring_match() void = {
	let idx = new_workspace_index();
	defer finish_workspace_index(&idx);
	index_file(&idx, "/a.ha", strings::toutf8("fn parse_thing() void = void;\nfn other() void = void;\n"));
	const m = fuzzy_search(&idx, "PARSE");
	defer free(m);
	assert(len(m) == 1);
	assert(idx.entries[m[0]].short_name == "parse_thing");
};
