// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// End-to-end test for textDocument/formatting: spawn the real binary,
// open a document containing inline comments, request formatting, and
// assert the returned newText contains every comment from the input.
// Guards against the comment-loss regression where the old
// unparse-based formatter silently dropped non-doc comments.

use encoding::json;
use fmt;
use strings;

@test fn e2e_format_preserves_inline_comments() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(
		&s,
		strings::toutf8(

			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`,
		),
	);
	free(wait_for_response(&s, 1.0));
	send(
		&s, strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`),
	);

	const sample =
		`// SPDX-License-Identifier: MPL-2.0
// (c) e2e test

use io;

export fn main() void = {
	// leading note
	let x = 1;
	let y = 2;
	// trailing note
	let z = x + y;
};
`;
	const did_open = build_did_open("file:///fmt_e2e.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	const req =
		`{"jsonrpc":"2.0","id":900,"method":"textDocument/formatting","params":{"textDocument":{"uri":"file:///fmt_e2e.ha"},"options":{"tabSize":8,"insertSpaces":false}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 900.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield *p;
	case void =>
		fmt::fatalf("e2e: format response missing result: {}", text);
	};
	const arr = match (result) {
	case let a: []json::value =>
		yield a;
	case =>
		fmt::fatalf("e2e: format result is not an array: {}", text);
	};
	// If the formatter returns no edit, the source is already in the
	// canonical form — which trivially preserves every comment. The
	// regression we guard against is a format that returns an edit
	// missing one of the comments.
	if (len(arr) == 0) return;
	const edit = arr[0] as json::object;
	const new_text = match (json::get(&edit, "newText")) {
	case let p: *json::value =>
		yield *p as str;
	case void =>
		fmt::fatalf("e2e: edit missing newText: {}", text);
	};

	assert(
		strings::contains(new_text, "SPDX-License-Identifier"),
		"file-header comment must survive format-on-save"
	);
	assert(
		strings::contains(new_text, "(c) e2e test"),
		"second header comment must survive"
	);
	assert(
		strings::contains(new_text, "leading note"),
		"inline comment before a statement must survive"
	);
	assert(
		strings::contains(new_text, "trailing note"),
		"inline comment between statements must survive"
	);
};

// Captures the format-output shape we expect from the wrapping
// formatter: comment text isn't double-spaced after `//`, and a
// source blank line between the header and `use io;` survives.
@test fn e2e_format_comment_spacing_and_header_blank_line() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(
		&s,
		strings::toutf8(

			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`,
		),
	);
	free(wait_for_response(&s, 1.0));
	send(
		&s, strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`),
	);

	// Source has " hi" (one leading space) inside the comment. The
	// formatter must NOT add a second leading space, so the rendered
	// line stays "// hi" rather than "//  hi".
	const sample = `// hi

use io;
`;
	const did_open = build_did_open("file:///cmt_space.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	const req =
		`{"jsonrpc":"2.0","id":901,"method":"textDocument/formatting","params":{"textDocument":{"uri":"file:///cmt_space.ha"},"options":{"tabSize":8,"insertSpaces":false}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 901.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield *p;
	case void =>
		fmt::fatalf("e2e: format response missing result: {}", text);
	};
	const arr = result as []json::value;
	if (len(arr) == 0) {
		// No edit means input == output, which is the ideal.
		return;
	};
	const edit = arr[0] as json::object;
	const new_text = *(json::get(&edit, "newText") as *json::value) as str;

	assert(
		strings::contains(new_text, "// hi"),
		"comment renders with single space after //"
	);
	assert(
		!strings::contains(new_text, "//  hi"),
		"comment must not be double-spaced after //"
	);
	assert(
		strings::contains(new_text, "// hi\n\nuse io;"),
		"source blank line between comment and use must survive"
	);
};

// Long fn signatures wrap their parameter list per the style guide:
// each param on its own line, trailing comma, closing `)` on its own
// line. No formatted line should exceed 80 columns.
@test fn e2e_format_wraps_long_signature() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(
		&s,
		strings::toutf8(

			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`,
		),
	);
	free(wait_for_response(&s, 1.0));
	send(
		&s, strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`),
	);

	// One-line signature whose flat width is well past 80 columns.
	const sample =
		`export fn really_long_fn_name(alpha: int, beta: int, gamma: int, delta: int, epsilon: int) int = alpha;
`;
	const did_open = build_did_open("file:///long_sig.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	const req =
		`{"jsonrpc":"2.0","id":902,"method":"textDocument/formatting","params":{"textDocument":{"uri":"file:///long_sig.ha"},"options":{"tabSize":8,"insertSpaces":false}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 902.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	assert(len(arr) == 1, "expected one text edit for the wrapped signature");
	const edit = arr[0] as json::object;
	const new_text = *(json::get(&edit, "newText") as *json::value) as str;

	// Each param on its own indented line.
	assert(
		strings::contains(new_text, "\n\talpha: int,"),
		"alpha param on its own indented line"
	);
	assert(
		strings::contains(new_text, "\n\tepsilon: int,"),
		"epsilon param wraps too (trailing comma when broken)"
	);
	// Closing `) int =` on its own line.
	assert(
		strings::contains(new_text, "\n) int = alpha;"),
		"closing paren + return type on own line, body follows"
	);

	// Hard upper bound: no line longer than 80 cols (with tabs counted
	// as one column, matching the pretty-printer's tab convention).
	const lines = strings::split(new_text, "\n")!;
	defer free(lines);
	for (let i = 0z; i < len(lines); i += 1) {
		assert(len(lines[i]) <= 80, "every formatted line fits in 80 columns");
	};
};

// Calls past 80 cols wrap their argument list the same way.
@test fn e2e_format_wraps_long_call_args() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(
		&s,
		strings::toutf8(

			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`,
		),
	);
	free(wait_for_response(&s, 1.0));
	send(
		&s, strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`),
	);

	const sample =
		`export fn main() void = {
	some_function(argument_one, argument_two, argument_three, argument_four, argument_five);
};
`;
	const did_open = build_did_open("file:///long_call.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	const req =
		`{"jsonrpc":"2.0","id":903,"method":"textDocument/formatting","params":{"textDocument":{"uri":"file:///long_call.ha"},"options":{"tabSize":8,"insertSpaces":false}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 903.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	assert(len(arr) == 1, "expected one text edit for the wrapped call");
	const edit = arr[0] as json::object;
	const new_text = *(json::get(&edit, "newText") as *json::value) as str;

	assert(
		strings::contains(new_text, "some_function(\n\t\targument_one,"),
		"first arg on its own indented line (depth 2 inside fn body)"
	);
	assert(
		strings::contains(new_text, "argument_five,\n\t)"),
		"trailing comma + closing paren on own line"
	);

	const lines = strings::split(new_text, "\n")!;
	defer free(lines);
	for (let i = 0z; i < len(lines); i += 1) {
		assert(len(lines[i]) <= 80, "every formatted line fits in 80 columns");
	};
};

// Short signatures and calls stay on one line.
@test fn e2e_format_short_signature_stays_flat() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(
		&s,
		strings::toutf8(

			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`,
		),
	);
	free(wait_for_response(&s, 1.0));
	send(
		&s, strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`),
	);

	// Already-formatted file; idempotent format should produce no edits
	// (or, at worst, a byte-identical replacement).
	const sample = `export fn add(a: int, b: int) int = a + b;
`;
	const did_open = build_did_open("file:///short_sig.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	const req =
		`{"jsonrpc":"2.0","id":904,"method":"textDocument/formatting","params":{"textDocument":{"uri":"file:///short_sig.ha"},"options":{"tabSize":8,"insertSpaces":false}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 904.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	if (len(arr) == 0) return; // identical → ideal
	const edit = arr[0] as json::object;
	const new_text = *(json::get(&edit, "newText") as *json::value) as str;
	assert(
		strings::contains(new_text, "export fn add(a: int, b: int) int = a + b;"),
		"short signature must stay on one line"
	);
};
