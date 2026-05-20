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

	const sample =
		`export fn answer() int = 42;

export fn ask() int = answer();
`;
	open_doc(&s, "file:///decl.ha", sample);

	// Cursor on `answer` inside `answer()` call on line 2.
	const req =
		`{"jsonrpc":"2.0","id":1100,"method":"textDocument/declaration","params":{"textDocument":{"uri":"file:///decl.ha"},"position":{"line":2,"character":23}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1100.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield *p;
	case void =>
		fmt::fatalf("e2e: declaration missing result: {}", text);
	};
	// Pin both the response shape and the actual target. Without uri/range
	// checks the handler could resolve to the cursor's own position or
	// any other symbol in the file and still pass.
	check_decl_location(result, text, "file:///decl.ha", "declaration");
};

@test fn e2e_implementation_resolves_like_definition() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample =
		`export fn answer() int = 42;

export fn ask() int = answer();
`;
	open_doc(&s, "file:///impl.ha", sample);

	const req =
		`{"jsonrpc":"2.0","id":1101,"method":"textDocument/implementation","params":{"textDocument":{"uri":"file:///impl.ha"},"position":{"line":2,"character":23}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1101.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = *(json::get(&obj, "result") as *json::value);
	check_decl_location(result, text, "file:///impl.ha", "implementation");
};

// typeDefinition on a local variable should walk from the binding to its
// declared type and return the type decl's Location. Mirror of the
// type-name path in [[e2e_type_definition_on_type_use_resolves]], but
// exercising the binding-walk fall-through in handle_type_definition.
@test fn e2e_type_definition_on_variable_resolves_to_type_decl() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	// `let v: my_int = 0;` -- typeDefinition on `v` lands on the
	// declaration of `my_int` (line 0).
	const sample =
		`type my_int = int;

export fn main() void = {
	let v: my_int = 0;
	let _ = v;
};
`;
	open_doc(&s, "file:///td.ha", sample);

	// Cursor on `v` in `let _ = v` (line 4, char 9).
	const req =
		`{"jsonrpc":"2.0","id":1102,"method":"textDocument/typeDefinition","params":{"textDocument":{"uri":"file:///td.ha"},"position":{"line":4,"character":9}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1102.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = *(json::get(&obj, "result") as *json::value);
	check_decl_location(result, text, "file:///td.ha", "typeDefinition");
};

// Multi-byte coverage required by CLAUDE.md's "Byte / rune offsets"
// section: the cursor line contains a `"日本語"` string literal before
// the identifier, so a buggy UTF-16-vs-byte conversion lands the cursor
// on a different token entirely. The identifier names themselves are
// multi-character (not single-letter `v`), the other guard CLAUDE.md
// asks for: single-char names mask the `loc.end.off = start of last
// rune` semantic. (Block comments `/* */` are avoided here because the
// upstream Hare lexer aborts when unreading a multi-byte rune past the
// comment's terminator.)
@test fn e2e_type_definition_on_variable_handles_multibyte_offsets() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	// On the cursor's line `\tlet label = "日本語"; let _ = user_id;`,
	// bytes 14-22 hold the 9-byte `日本語` block (3 bytes per rune)
	// while UTF-16 columns 14-16 hold the same three BMP runes (each 1
	// unit). UTF-16 column 30 lands on `e` in `user_id` (byte 36).
	// A regression that re-uses UTF-16 columns as raw byte offsets
	// would instead read byte 30 — the `_` discard ident in
	// `let _ = user_id` — and `let _ = ...` parses with an empty
	// `names` slice on the binding, so the binding walk wouldn't match
	// anything and the test would observe `result:null` rather than a
	// Location.
	const sample =
		`type customer_id = u64;

export fn main() void = {
	let user_id: customer_id = 0;
	let label = "日本語"; let _ = user_id;
};
`;
	open_doc(&s, "file:///td_mb.ha", sample);

	const req =
		`{"jsonrpc":"2.0","id":1104,"method":"textDocument/typeDefinition","params":{"textDocument":{"uri":"file:///td_mb.ha"},"position":{"line":4,"character":30}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1104.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = *(json::get(&obj, "result") as *json::value);
	check_decl_location(result, text, "file:///td_mb.ha", "typeDefinition");
};

// typeDefinition on a function parameter should resolve through the
// parameter's declared type the same way it does for `let` bindings.
@test fn e2e_type_definition_on_parameter_resolves() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample =
		`type my_int = int;

export fn check(value: my_int) void = {
	let _ = value;
};
`;
	open_doc(&s, "file:///td_param.ha", sample);

	// `let _ = value;` on line 3, leading tab + `let _ = ` = 8 cols,
	// `value` starts at column 9, so cursor at column 11 lands on `l`.
	const req =
		`{"jsonrpc":"2.0","id":1105,"method":"textDocument/typeDefinition","params":{"textDocument":{"uri":"file:///td_param.ha"},"position":{"line":3,"character":11}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1105.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = *(json::get(&obj, "result") as *json::value);
	check_decl_location(result, text, "file:///td_param.ha", "typeDefinition");
};

// Pins the rule that a cursor on a *local* non-TYPE symbol (function,
// global, const) returns null even if a same-short-named TYPE exists in
// another workspace file. The handler must NOT silently re-target a
// function call to a workspace alias decl just because their short
// names coincide; that would be a wrong-target jump for the user.
@test fn e2e_type_definition_on_local_non_type_does_not_fall_back_to_workspace(

) void = {
	const root = setup_typedef_no_fallback_workspace();
	defer cleanup_workspace(root);

	let s = spawn_session();
	defer finish_session(&s);
	do_init_with_workspace(&s, root);
	drain_until_indexed_ref(&s);

	// `alias_mod/aliases.ha` (on disk) defines `type shadowed_name = int;`.
	// The doc we open lives at `main_mod/main.ha`, which exists only as
	// an open buffer — main_mod is not on disk, so the workspace index
	// only contains alias_mod's TYPE entry. That is exactly the layout
	// in which the buggy fall-through would emit the alias's Location.
	const uri = strings::concat("file://", root, "/main_mod/main.ha")!;
	defer free(uri);
	const sample =
		`export fn shadowed_name() void = void;
export fn caller() void = shadowed_name();
`;
	open_doc(&s, uri, sample);

	// Cursor on `shadowed_name` inside `caller`'s body. Line 1's
	// `export fn caller() void = ` is 26 ASCII cols; the identifier
	// starts at col 26, so col 32 lands on `e` in `shadowed_name`.
	const req =
		strings::concat(
			`{"jsonrpc":"2.0","id":1106,"method":"textDocument/typeDefinition","params":{"textDocument":{"uri":"`,
			uri, `"},"position":{"line":1,"character":32}}}`)!;
	defer free(req);
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1106.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = *(json::get(&obj, "result") as *json::value);
	assert(
		result is json::_null,
		"typeDefinition on a local non-TYPE symbol must return null, not jump to a same-named workspace TYPE"
	);
};

fn setup_typedef_no_fallback_workspace() str = {
	const files: [](str, str) = [
		("alias_mod/aliases.ha", "type shadowed_name = int;\n"),
	];
	return make_workspace("typedef-no-fallback", files);
};

// Positive coverage for the working path: cursor on a *type name* (the
// `my_int` reference inside `let v: my_int = 0;`) should resolve to
// `type my_int = int;` on line 0. This exercises the
// `find_by_short_name -> TYPE` branch of handle_type_definition.
@test fn e2e_type_definition_on_type_use_resolves() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample =
		`type my_int = int;

export fn main() void = {
	let v: my_int = 0;
	let _ = v;
};
`;
	open_doc(&s, "file:///td2.ha", sample);

	// `let v: my_int = 0;` on line 3, indented by one tab. After the
	// tab, `let v: ` consumes 7 chars; `my_int` starts at column 8.
	// Cursor inside `my_int` -> char 10.
	const req =
		`{"jsonrpc":"2.0","id":1103,"method":"textDocument/typeDefinition","params":{"textDocument":{"uri":"file:///td2.ha"},"position":{"line":3,"character":10}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1103.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = *(json::get(&obj, "result") as *json::value);
	check_decl_location(result, text, "file:///td2.ha", "typeDefinition");
};

// Asserts that `result` is a single Location pointing at a top-level decl
// on line 0 of `expected_uri`. The server's send_location uses the symbol's
// full decl span, which begins at column 0 (`export`/`type` keyword) and
// extends through the trailing `;` or closing brace, so we require:
//   - exactly a Location object (not null, not an array, not a LocationLink),
//   - URI equals `expected_uri`,
//   - range.start = (0, 0) and range covers a non-empty span on line 0.
// `label` is included in failure messages so the caller can tell which
// request produced the bad result.
fn check_decl_location(
	result: json::value,
	body_text: str,
	expected_uri: str,
	label: str,
) void = {
	const loc = match (result) {
	case let o: json::object =>
		yield o;
	case let arr: []json::value =>
		// A Location[] with a single element is also acceptable shape per
		// LSP, but pinning the test to whichever the server currently emits
		// is more useful than allowing both forms silently. The server
		// returns a single Location object today; flag the array form as
		// a deliberate shape change.
		fmt::fatalf(
			"e2e: {} result was Location[] (len {}); expected a single Location object: {}",
			label, len(arr), body_text);
	case =>
		fmt::fatalf("e2e: {} returned null/non-Location: {}", label, body_text);
	};
	const uri = *(json::get(&loc, "uri") as *json::value) as str;
	if (uri != expected_uri) {
		fmt::fatalf("e2e: {} uri = {}, expected {}. body={}", label, uri,
			expected_uri, body_text);
	};
	const range = *(json::get(&loc, "range") as *json::value) as json::object;
	const start = *(json::get(&range, "start") as *json::value) as json::object;
	const end = *(json::get(&range, "end") as *json::value) as json::object;
	const sl = *(json::get(&start, "line") as *json::value) as f64;
	const sc = *(json::get(&start, "character") as *json::value) as f64;
	const el = *(json::get(&end, "line") as *json::value) as f64;
	const ec = *(json::get(&end, "character") as *json::value) as f64;
	if (sl != 0.0 || sc != 0.0) {
		fmt::fatalf(
			"e2e: {} range.start = ({}, {}), expected (0, 0) -- start of the decl. body={}",
			label, sl, sc, body_text);
	};
	if (!(el > sl || ec > sc)) {
		fmt::fatalf(
			"e2e: {} range is empty: ({},{}..{},{}); decl span should cover the full declaration. body={}",
			label, sl, sc, el, ec, body_text);
	};
};
