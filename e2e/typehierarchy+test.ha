// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// e2e: type hierarchy. prepareTypeHierarchy + supertypes + subtypes.

use encoding::json;
use fmt;
use fs;
use os;
use strings;

@test fn e2e_prepare_type_hierarchy_returns_item_for_type() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `type my_int = int;
`;
	open_doc(&s, "file:///th.ha", sample);

	// Cursor on `my_int` (line 0, char 7).
	const req =
		`{"jsonrpc":"2.0","id":1700,"method":"textDocument/prepareTypeHierarchy","params":{"textDocument":{"uri":"file:///th.ha"},"position":{"line":0,"character":7}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1700.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	assert(
		len(arr) == 1,
		"prepareTypeHierarchy should return one item for a type decl"
	);
	const item = arr[0] as json::object;
	const name = *(json::get(&item, "name") as *json::value) as str;
	assert(name == "my_int", "item name should match the type under the cursor");
	const kind = *(json::get(&item, "kind") as *json::value) as f64;
	assert(kind == 23.0, "kind must be SymbolKind.Struct (23)");
	// selectionRange should span only the identifier `my_int` (cols
	// 5-11 of "type my_int = int;") so editors land the cursor on the
	// name when navigating into a hierarchy item.
	const sel =
		*(json::get(&item, "selectionRange") as *json::value) as json::object;
	const sp = *(json::get(&sel, "start") as *json::value) as json::object;
	const ep = *(json::get(&sel, "end") as *json::value) as json::object;
	const sp_ch = *(json::get(&sp, "character") as *json::value) as f64;
	const ep_ch = *(json::get(&ep, "character") as *json::value) as f64;
	assert(
		sp_ch == 5.0,
		"selectionRange.start.character points at the identifier"
	);
	assert(
		ep_ch == 11.0,
		"selectionRange.end.character ends after the identifier"
	);
};

@test fn e2e_type_hierarchy_supertypes_returns_array() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `type my_int = int;
`;
	open_doc(&s, "file:///ths.ha", sample);

	const req =
		`{"jsonrpc":"2.0","id":1701,"method":"typeHierarchy/supertypes","params":{"item":{"name":"my_int","kind":23,"uri":"file:///ths.ha","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":17}},"selectionRange":{"start":{"line":0,"character":5},"end":{"line":0,"character":11}}}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1701.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	// Result must be an array. The underlying `int` is a builtin
	// rather than a user-defined type decl, so the workspace lookup
	// can't yield an entry and the array is expected to be empty.
	// e2e_typehierarchy_distinguishes_same_name_across_modules covers
	// the user-defined-supertype case with a real workspace.
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	// Every emitted item must have the required CallHierarchy fields
	// so a regression that emits malformed items fails here.
	for (let i = 0z; i < len(arr); i += 1) {
		const it = arr[i] as json::object;
		const _ = *(json::get(&it, "name") as *json::value) as str;
		const _ = *(json::get(&it, "uri") as *json::value) as str;
		const _ = *(json::get(&it, "kind") as *json::value) as f64;
	};
};

// Two TYPE decls with the same short name in different modules must
// not be conflated: supertypes from mod_a's type returns only mod_a's
// supertype, not the unrelated same-named decl in mod_b.
@test fn e2e_typehierarchy_distinguishes_same_name_across_modules() void = {
	const root = setup_crossmod_typehier_workspace();
	defer cleanup_crossmod_workspace(root);

	let s = spawn_session();
	defer finish_session(&s);
	init_with_workspace_folder(&s, root);
	drain_until_indexed_ref(&s);

	const uri_a = strings::concat("file://", root, "/mod_a/types.ha")!;
	defer free(uri_a);

	// Supertypes of mod_a's `T`: should yield mod_a's `X`, not mod_b's.
	const tmpl =
		`{"jsonrpc":"2.0","id":1720,"method":"typeHierarchy/supertypes","params":{"item":{"name":"T","kind":23,"uri":"`;
	const req =
		strings::concat(tmpl, uri_a,
			`","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":11}},"selectionRange":{"start":{"line":0,"character":5},"end":{"line":0,"character":6}}}}}`
		)!;
	defer free(req);
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1720.0);
	defer free(body);
	const v = json::loadstr(strings::fromutf8(body)!)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	// mod_a's `type T = X;` should resolve its supertype to mod_a's
	// `X`. An empty array would mean the resolver silently dropped a
	// real cross-decl link inside the same module — which would look
	// broken to a user clicking "go to supertype".
	let saw_mod_a_x = false;
	for (let i = 0z; i < len(arr); i += 1) {
		const item = arr[i] as json::object;
		const u = *(json::get(&item, "uri") as *json::value) as str;
		const n = *(json::get(&item, "name") as *json::value) as str;
		assert(
			strings::contains(u, "/mod_a/"),
			"supertypes must come from the cursor's module"
		);
		assert(
			!strings::contains(u, "/mod_b/"),
			"supertypes must not leak into the unrelated module"
		);
		if (n == "X") saw_mod_a_x = true;
	};
	assert(saw_mod_a_x, "supertypes of mod_a's T must include mod_a's X");

	// Symmetric subtypes check.
	const tmpl2 =
		`{"jsonrpc":"2.0","id":1721,"method":"typeHierarchy/subtypes","params":{"item":{"name":"X","kind":23,"uri":"`;
	const req2 =
		strings::concat(tmpl2, uri_a,
			`","range":{"start":{"line":1,"character":0},"end":{"line":1,"character":13}},"selectionRange":{"start":{"line":1,"character":5},"end":{"line":1,"character":6}}}}}`
		)!;
	defer free(req2);
	send(&s, strings::toutf8(req2));

	const body2 = wait_for_response(&s, 1721.0);
	defer free(body2);
	const v2 = json::loadstr(strings::fromutf8(body2)!)!;
	defer json::finish(v2);
	const arr2 =
		*(json::get(&(v2 as json::object),
			"result") as *json::value) as []json::value;
	// Subtypes of mod_a's X should include mod_a's T (the alias that
	// references X). mod_b's U also references its own X but should
	// not appear here, since the resolver disambiguates by module.
	let saw_mod_a_t = false;
	for (let i = 0z; i < len(arr2); i += 1) {
		const item = arr2[i] as json::object;
		const u = *(json::get(&item, "uri") as *json::value) as str;
		const n = *(json::get(&item, "name") as *json::value) as str;
		assert(
			strings::contains(u, "/mod_a/"),
			"subtypes must come from the cursor's module"
		);
		assert(
			!strings::contains(u, "/mod_b/"),
			"subtypes must not leak into the unrelated module"
		);
		if (n == "T") saw_mod_a_t = true;
	};
	assert(saw_mod_a_t, "subtypes of mod_a's X must include mod_a's T");
};

// Lays down `.tmp/e2e-crossmod-typehier/{mod_a,mod_b}/types.ha`. mod_a
// defines `type T = X; type X = int;` so supertypes of T should resolve
// to X. mod_b also has `type X = ...; type U = X;` so naive short-name
// matching would lump mod_b's X into mod_a's supertype set.
fn setup_crossmod_typehier_workspace() str = {
	const cwd = os::getcwd();
	const root = strings::concat(cwd, "/.tmp/e2e-crossmod-typehier")!;
	cleanup_crossmod_workspace(root);
	const mod_a = strings::concat(root, "/mod_a")!;
	defer free(mod_a);
	const mod_b = strings::concat(root, "/mod_b")!;
	defer free(mod_b);
	match (os::mkdirs(mod_a, 0o755: fs::mode)) {
	case void => void;
	case let e: fs::error =>
		fmt::fatalf("e2e: cannot mkdir {}: {}", mod_a, fs::strerror(e));
	};
	match (os::mkdirs(mod_b, 0o755: fs::mode)) {
	case void => void;
	case let e: fs::error =>
		fmt::fatalf("e2e: cannot mkdir {}: {}", mod_b, fs::strerror(e));
	};
	const file_a = strings::concat(mod_a, "/types.ha")!;
	defer free(file_a);
	const file_b = strings::concat(mod_b, "/types.ha")!;
	defer free(file_b);
	write_test_file(file_a, "type T = X;\ntype X = int;\n");
	write_test_file(file_b, "type U = X;\ntype X = str;\n");
	return root;
};

@test fn e2e_type_hierarchy_subtypes_returns_array() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `type my_int = int;
`;
	open_doc(&s, "file:///thsub.ha", sample);

	const req =
		`{"jsonrpc":"2.0","id":1702,"method":"typeHierarchy/subtypes","params":{"item":{"name":"int","kind":23,"uri":"file:///thsub.ha","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":17}},"selectionRange":{"start":{"line":0,"character":14},"end":{"line":0,"character":17}}}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1702.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	// Subtypes of `int` (a builtin) in a single-doc fixture yields an
	// empty array: the cursor's "X" doesn't resolve to a workspace
	// entry without a workspace folder, so the resolver short-circuits.
	// e2e_typehierarchy_distinguishes_same_name_across_modules covers
	// the user-defined-subtype case with a real workspace.
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	for (let i = 0z; i < len(arr); i += 1) {
		const it = arr[i] as json::object;
		const _ = *(json::get(&it, "name") as *json::value) as str;
		const _ = *(json::get(&it, "uri") as *json::value) as str;
		const _ = *(json::get(&it, "kind") as *json::value) as f64;
	};
};
