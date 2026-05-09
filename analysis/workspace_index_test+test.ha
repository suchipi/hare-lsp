// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

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

@test fn fuzzy_search_substring_match() void = {
	let idx = new_workspace_index();
	defer finish_workspace_index(&idx);
	index_file(&idx, "/a.ha", strings::toutf8("fn parse_thing() void = void;\nfn other() void = void;\n"));
	const m = fuzzy_search(&idx, "PARSE");
	defer free(m);
	assert(len(m) == 1);
	assert(idx.entries[m[0]].short_name == "parse_thing");
};
