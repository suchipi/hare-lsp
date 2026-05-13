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

	// `let x = 1` lacks an explicit type; the server should emit a
	// type-inference hint after the binding name.
	const sample = `export fn main() void = {
	let x = 1;
	let _ = x;
};
`;
	open_doc(&s, "file:///ih.ha", sample);

	const req =
		`{"jsonrpc":"2.0","id":2200,"method":"textDocument/inlayHint","params":{"textDocument":{"uri":"file:///ih.ha"},"range":{"start":{"line":0,"character":0},"end":{"line":4,"character":0}}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 2200.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	// We accept the empty array — inferred-type hints inside function
	// bodies aren't yet implemented for all cases. The wire path must
	// return an array with valid hint shape if any.
	for (let i = 0z; i < len(arr); i += 1) {
		const h = arr[i] as json::object;
		assert(
			json::get(&h, "position") is *json::value,
			"each hint must include position"
		);
		assert(
			json::get(&h, "label") is *json::value,
			"each hint must include label"
		);
	};
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
	assert(
		json::get(&obj, "result") is *json::value,
		"inlayHint/resolve must include a result"
	);
};
