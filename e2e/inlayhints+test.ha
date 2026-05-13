// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// e2e: textDocument/inlayHint and inlayHint/resolve.

use encoding::json;
use fmt;
use fs;
use os;
use strings;

@test fn e2e_inlay_hint_returns_inferred_type_hints() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	// Top-level `let g_x = 1` lacks an explicit type; the server
	// should emit a type-inference hint after the binding name. We use
	// a top-level let (rather than a body-local one) because the inlay
	// scanner currently only walks subunit decls.
	const sample = `let g_x = 1;
`;
	open_doc(&s, "file:///ih.ha", sample);

	const req =
		`{"jsonrpc":"2.0","id":2200,"method":"textDocument/inlayHint","params":{"textDocument":{"uri":"file:///ih.ha"},"range":{"start":{"line":0,"character":0},"end":{"line":2,"character":0}}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 2200.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	// One hint: ": int" after `g_x`. A regression that emits nothing
	// would render the editor with no type annotation for an obvious
	// integer literal.
	let saw_int_hint = false;
	for (let i = 0z; i < len(arr); i += 1) {
		const h = arr[i] as json::object;
		const pos = *(json::get(&h, "position") as *json::value) as json::object;
		const label = *(json::get(&h, "label") as *json::value) as str;
		const line = *(json::get(&pos, "line") as *json::value) as f64;
		const ch = *(json::get(&pos, "character") as *json::value) as f64;
		// The hint anchors right after `g_x` (cols 0-3 then "let " = 4
		// chars; name is 3 chars → insertion at column 7).
		if (line == 0.0 && ch == 7.0 && strings::contains(label, "int")) {
			saw_int_hint = true;
		};
	};
	assert(
		saw_int_hint,
		"inferred-type hint for `let g_x = 1` must label it as int"
	);
};

// With `hare.inlayHints.inferredTypesMaxDepth` >= 2, the hint for
// `let x = foo()` where foo returns an aliased type should unwrap the
// alias chain instead of stopping at the alias name. Default depth is
// 10, so we don't need to set it explicitly.
@test fn e2e_inlay_hint_follows_alias_chain() void = {
	// Fixture: a workspace folder with `type my_alias = int; fn foo()
	// my_alias = 0;` so the call return type and the alias are both
	// in the workspace index.
	const cwd = os::getcwd();
	const root = strings::concat(cwd, "/.tmp/e2e-inlay-alias-chain")!;
	defer free(root);
	cleanup_crossmod_workspace(root);
	defer cleanup_crossmod_workspace(root);
	const mod_dir = strings::concat(root, "/m")!;
	defer free(mod_dir);
	match (os::mkdirs(mod_dir, 0o755: fs::mode)) {
	case void => void;
	case let e: fs::error =>
		fmt::fatalf("e2e: cannot mkdir {}: {}", mod_dir, fs::strerror(e));
	};
	const file_path = strings::concat(mod_dir, "/m.ha")!;
	defer free(file_path);
	write_test_file(file_path,
		"type my_alias = int;\nexport fn foo() my_alias = 0;\n");

	let s = spawn_session();
	defer finish_session(&s);
	init_with_workspace_folder(&s, root);
	drain_until_indexed_ref(&s);

	// Open a caller file inside the same workspace. We use a
	// top-level `let` so the inlay-hints scanner (which currently
	// only walks top-level decls) actually sees the binding.
	const caller_path = strings::concat(mod_dir, "/caller.ha")!;
	defer free(caller_path);
	const caller_uri = strings::concat("file://", caller_path)!;
	defer free(caller_uri);
	const sample = "let g_x = foo();\n";
	open_doc(&s, caller_uri, sample);

	const req_tmpl =
		`{"jsonrpc":"2.0","id":2210,"method":"textDocument/inlayHint","params":{"textDocument":{"uri":"`;
	const req =
		strings::concat(req_tmpl, caller_uri,
			`"},"range":{"start":{"line":0,"character":0},"end":{"line":1,"character":0}}}}`
		)!;
	defer free(req);
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 2210.0);
	defer free(body);
	const v = json::loadstr(strings::fromutf8(body)!)!;
	defer json::finish(v);
	const arr =
		*(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	let saw_int_label = false;
	let saw_alias_only = false;
	for (let i = 0z; i < len(arr); i += 1) {
		const h = arr[i] as json::object;
		const label = match (json::get(&h, "label")) {
		case let p: *json::value =>
			yield match (*p) {
			case let s: str =>
				yield s;
			case =>
				continue;
			};
		case =>
			continue;
		};
		if (strings::contains(label, "int")) {
			saw_int_label = true;
		} else if (strings::contains(label, "my_alias")) {
			saw_alias_only = true;
		};
	};
	assert(
		saw_int_label,
		"inlay hint must follow `my_alias` chain to its underlying `int`"
	);
	assert(
		!saw_alias_only,
		"inlay hint should not stop at the alias name when depth allows"
	);
};

@test fn e2e_inlay_hint_resolve_passthrough() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const req =
		`{"jsonrpc":"2.0","id":2201,"method":"inlayHint/resolve","params":{"position":{"line":0,"character":0},"label":"x"}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 2201.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	assert(
		json::get(&obj, "error") is void,
		"inlayHint/resolve passthrough must not error"
	);
	// Resolve is a passthrough — verify both required fields round-tripped
	// rather than just confirming the field exists. A regression that
	// returned null or `{}` would slip past a presence-only check.
	const result = *(json::get(&obj, "result") as *json::value) as json::object;
	const label = *(json::get(&result, "label") as *json::value) as str;
	assert(label == "x", "passthrough must preserve label");
	const pos = *(json::get(&result, "position") as *json::value) as json::object;
	const line = *(json::get(&pos, "line") as *json::value) as f64;
	const ch = *(json::get(&pos, "character") as *json::value) as f64;
	assert(line == 0.0 && ch == 0.0, "passthrough must preserve position");
};
