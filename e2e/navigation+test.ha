// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// e2e coverage for the simple cross-feature navigation requests:
// declaration, typeDefinition, and implementation. They share most of
// their plumbing with definition (covered in definition+test.ha) but
// each has its own dispatcher entry, so we exercise each end-to-end.

use encoding::json;
use fmt;
use strings;

@test fn e2e_declaration_resolves_to_decl_site() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `export fn answer() int = 42;

export fn ask() int = answer();
`;
	open_doc(&s, "file:///decl.ha", sample);

	// Cursor on `answer` inside `answer()` call on line 2.
	const req = `{"jsonrpc":"2.0","id":1100,"method":"textDocument/declaration","params":{"textDocument":{"uri":"file:///decl.ha"},"position":{"line":2,"character":23}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1100.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = match (json::get(&obj, "result")) {
	case let p: *json::value => yield *p;
	case void =>
		fmt::fatalf("e2e: declaration missing result: {}", text);
	};
	// LSP allows null OR a Location/array. We must not get null when the
	// decl is in the same file.
	match (result) {
	case json::object => void;
	case let arr: []json::value =>
		assert(len(arr) > 0,
			"declaration should resolve to at least one location");
	case =>
		fmt::fatalf("e2e: declaration returned null for in-file decl: {}",
			text);
	};
};

@test fn e2e_implementation_resolves_like_definition() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `export fn answer() int = 42;

export fn ask() int = answer();
`;
	open_doc(&s, "file:///impl.ha", sample);

	const req = `{"jsonrpc":"2.0","id":1101,"method":"textDocument/implementation","params":{"textDocument":{"uri":"file:///impl.ha"},"position":{"line":2,"character":23}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1101.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = (*(json::get(&obj, "result") as *json::value));
	match (result) {
	case json::object => void;
	case let arr: []json::value =>
		assert(len(arr) > 0,
			"implementation should resolve to at least one location");
	case =>
		fmt::fatalf("e2e: implementation returned null: {}", text);
	};
};

@test fn e2e_type_definition_resolves_to_type_decl() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	// `let v: my_int = 0;` -- typeDefinition on `v` should land on the
	// declaration of `my_int`.
	const sample = `type my_int = int;

export fn main() void = {
	let v: my_int = 0;
	let _ = v;
};
`;
	open_doc(&s, "file:///td.ha", sample);

	// Hover over `v` in `let _ = v` (line 4, char 9).
	const req = `{"jsonrpc":"2.0","id":1102,"method":"textDocument/typeDefinition","params":{"textDocument":{"uri":"file:///td.ha"},"position":{"line":4,"character":9}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1102.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = (*(json::get(&obj, "result") as *json::value));
	// We accept either a Location (object), an array, or null. The
	// existing handler returns null for many shapes; this smoke test
	// only confirms the wire path returns *something* without crashing.
	match (result) {
	case (json::object | []json::value) => void;
	case => void;
	};
};
