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

// FIXME: textDocument/typeDefinition on a *variable* (e.g. cursor on `v`
// in `let _ = v;`) should resolve to the declaration of `v`'s type. The
// current handler in server/navigation.ha only resolves the cursor when
// it lands directly on a type name (see [[e2e_type_definition_on_type_use_resolves]]);
// it does not yet walk from a local binding to its declared type. Until
// that handler gap is closed, this test pins the current null behavior
// precisely so any change (positive or negative) surfaces. When the
// handler is fixed, update this test to assert the resulting Location.
@test fn e2e_type_definition_on_variable_returns_null_pending_handler_fix() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	// `let v: my_int = 0;` -- ideally typeDefinition on `v` lands on the
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
	// Tight assertion: current behavior is null. When the handler is
	// fixed to resolve through variable bindings, this assertion will
	// fail and the test must be updated to assert a Location pointing
	// at `my_int` on line 0.
	assert(
		result is json::_null,
		"typeDefinition on a variable currently returns null; if the handler now resolves through the binding, update this test"
	);
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
		fmt::fatalf("e2e: {} result was Location[] (len {}); expected a single Location object: {}",
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
