// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use strings;

// workspace_lookup_for_subunit must use the file's `use` list to
// disambiguate identical short names declared in two different
// workspace modules.
@test fn workspace_lookup_for_subunit_picks_imported_module() void = {
	let idx = new_workspace_index();
	defer finish_workspace_index(&idx);
	index_file(&idx, "/repo/mod_a/file.ha",
		strings::toutf8("export fn shared() int = 1;\n"));
	index_file(&idx, "/repo/mod_b/file.ha",
		strings::toutf8("export fn shared() int = 2;\n"));

	// Use mod_a; bare reference to `shared` resolves to mod_a/file.ha.
	const pr_a = parse_recover(strings::toutf8(
		"use mod_a;\nfn caller() int = shared();\n"), "caller_a.ha");
	let pr_a_local = pr_a;
	defer finish_parse_result(&pr_a_local);
	const entry_a = workspace_lookup_for_subunit(&idx, &pr_a_local.subunit,
		"", "", "shared");
	assert(entry_a is *workspace_entry,
		"resolver should find a match");
	const e_a = entry_a as *workspace_entry;
	assert(e_a.module == "mod_a",
		"bare ref must resolve via the file's `use mod_a;`");

	const pr_b = parse_recover(strings::toutf8(
		"use mod_b;\nfn caller() int = shared();\n"), "caller_b.ha");
	let pr_b_local = pr_b;
	defer finish_parse_result(&pr_b_local);
	const entry_b = workspace_lookup_for_subunit(&idx, &pr_b_local.subunit,
		"", "", "shared");
	assert(entry_b is *workspace_entry, "resolver should find a match");
	const e_b = entry_b as *workspace_entry;
	assert(e_b.module == "mod_b",
		"bare ref must resolve via the file's `use mod_b;`");
};

// With a `::`-qualifier, the resolver looks the name up in that specific
// module regardless of the file's `use` list.
@test fn workspace_lookup_for_subunit_uses_qualifier_directly() void = {
	let idx = new_workspace_index();
	defer finish_workspace_index(&idx);
	index_file(&idx, "/repo/mod_a/file.ha",
		strings::toutf8("export fn shared() int = 1;\n"));
	index_file(&idx, "/repo/mod_b/file.ha",
		strings::toutf8("export fn shared() int = 2;\n"));

	const pr = parse_recover(strings::toutf8(
		"use mod_a;\nuse mod_b;\nfn c() int = mod_b::shared();\n"),
		"caller.ha");
	let pr_local = pr;
	defer finish_parse_result(&pr_local);
	const entry = workspace_lookup_for_subunit(&idx, &pr_local.subunit,
		"", "mod_b", "shared");
	assert(entry is *workspace_entry, "resolver should find a match");
	const e = entry as *workspace_entry;
	assert(e.module == "mod_b",
		"qualifier should override import-rank precedence");
};

// When a name appears in only one module and the file doesn't import any
// of the candidates, the last-resort `find_first_by_short_name` lookup
// kicks in. That's important for files that aren't yet edited but
// contain references that should still match.
@test fn workspace_lookup_for_subunit_last_resort_fallback() void = {
	let idx = new_workspace_index();
	defer finish_workspace_index(&idx);
	index_file(&idx, "/repo/mod_a/file.ha",
		strings::toutf8("export fn lonely() int = 1;\n"));

	const pr = parse_recover(strings::toutf8(
		"fn c() int = lonely();\n"), "caller.ha");
	let pr_local = pr;
	defer finish_parse_result(&pr_local);
	const entry = workspace_lookup_for_subunit(&idx, &pr_local.subunit,
		"", "", "lonely");
	assert(entry is *workspace_entry,
		"bare ref with no relevant imports falls back to first match");
};

// The file's own module is the highest-precedence resolution target
// for a bare reference (after a qualifier). Without this, a same-named
// decl in another module could win the lookup by chance of iteration
// order.
@test fn workspace_lookup_for_subunit_prefers_file_module() void = {
	let idx = new_workspace_index();
	defer finish_workspace_index(&idx);
	index_file(&idx, "/repo/mod_a/file.ha",
		strings::toutf8("export fn shared() int = 1;\n"));
	index_file(&idx, "/repo/mod_b/file.ha",
		strings::toutf8("export fn shared() int = 2;\n"));

	// A file in mod_a referencing bare `shared` resolves to mod_a's
	// decl, not mod_b's, even with no `use` statement.
	const pr = parse_recover(strings::toutf8(
		"fn caller() int = shared();\n"), "mod_a/caller.ha");
	let pr_local = pr;
	defer finish_parse_result(&pr_local);
	const entry = workspace_lookup_for_subunit(&idx, &pr_local.subunit,
		"mod_a", "", "shared");
	assert(entry is *workspace_entry, "resolver should find a match");
	const e = entry as *workspace_entry;
	assert(e.module == "mod_a",
		"file_module hint must win over arbitrary first-by-short-name");
};

// With two modules each declaring the same name, a bare reference in an
// unrelated file (no relevant import) falls back to the first hit. The
// reference filter on top distinguishes by re-resolving in the *hit's*
// file rather than treating this as ambiguous.
@test fn workspace_lookup_for_subunit_ambiguous_falls_back_to_first() void = {
	let idx = new_workspace_index();
	defer finish_workspace_index(&idx);
	index_file(&idx, "/repo/mod_a/file.ha",
		strings::toutf8("export fn shared() int = 1;\n"));
	index_file(&idx, "/repo/mod_b/file.ha",
		strings::toutf8("export fn shared() int = 2;\n"));

	const pr = parse_recover(strings::toutf8(
		"fn c() int = shared();\n"), "caller.ha");
	let pr_local = pr;
	defer finish_parse_result(&pr_local);
	const entry = workspace_lookup_for_subunit(&idx, &pr_local.subunit,
		"", "", "shared");
	assert(entry is *workspace_entry,
		"ambiguous bare ref still returns a match (first by short name)");
};
