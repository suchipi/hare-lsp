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
	// Result must be an array (possibly empty if workspace index isn't
	// populated for the open doc -- that's a known limitation).
	assert(
		*(json::get(&obj, "result") as *json::value) is []json::value,
		"supertypes must return an array"
	);
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
		strings::concat(
			tmpl, uri_a,
			`","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":11}},"selectionRange":{"start":{"line":0,"character":5},"end":{"line":0,"character":6}}}}}`,
		)!;
	defer free(req);
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1720.0);
	defer free(body);
	const v = json::loadstr(strings::fromutf8(body)!)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	for (let i = 0z; i < len(arr); i += 1) {
		const item = arr[i] as json::object;
		const u = *(json::get(&item, "uri") as *json::value) as str;
		assert(
			strings::contains(u, "/mod_a/"),
			"supertypes must come from the cursor's module"
		);
		assert(
			!strings::contains(u, "/mod_b/"),
			"supertypes must not leak into the unrelated module"
		);
	};

	// Symmetric subtypes check.
	const tmpl2 =
		`{"jsonrpc":"2.0","id":1721,"method":"typeHierarchy/subtypes","params":{"item":{"name":"X","kind":23,"uri":"`;
	const req2 =
		strings::concat(
			tmpl2, uri_a,
			`","range":{"start":{"line":1,"character":0},"end":{"line":1,"character":13}},"selectionRange":{"start":{"line":1,"character":5},"end":{"line":1,"character":6}}}}}`,
		)!;
	defer free(req2);
	send(&s, strings::toutf8(req2));

	const body2 = wait_for_response(&s, 1721.0);
	defer free(body2);
	const v2 = json::loadstr(strings::fromutf8(body2)!)!;
	defer json::finish(v2);
	const arr2 =
		*(json::get(
			&(v2 as json::object), "result",
		) as *json::value) as []json::value;
	for (let i = 0z; i < len(arr2); i += 1) {
		const item = arr2[i] as json::object;
		const u = *(json::get(&item, "uri") as *json::value) as str;
		assert(
			strings::contains(u, "/mod_a/"),
			"subtypes must come from the cursor's module"
		);
		assert(
			!strings::contains(u, "/mod_b/"),
			"subtypes must not leak into the unrelated module"
		);
	};
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
	assert(
		*(json::get(&obj, "result") as *json::value) is []json::value,
		"subtypes must return an array"
	);
};
