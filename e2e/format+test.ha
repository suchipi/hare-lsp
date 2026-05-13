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

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	// Non-canonical spacing (`let x  = 1;` with two spaces) forces the
	// formatter to emit an edit, so a parse-failure or other silent-
	// degrade path that returns `[]` will fail the test instead of
	// passing trivially.
	const sample =
		`// SPDX-License-Identifier: MPL-2.0
// (c) e2e test

use io;

export fn main() void = {
	// leading note
	let x  = 1;
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
	assert(
		len(arr) == 1,
		"format must emit one edit for non-canonical input "
		"(any silent fallback path returning [] is a regression)"
	);
	const edit = arr[0] as json::object;
	const new_text = match (json::get(&edit, "newText")) {
	case let p: *json::value =>
		yield *p as str;
	case void =>
		fmt::fatalf("e2e: edit missing newText: {}", text);
	};
	// Full-document edit: range.start must be (0, 0). End is the EOF
	// position; we only pin the start tightly because the end depends
	// on the negotiated position encoding.
	const range_obj = field(&edit, "range") as json::object;
	const start_obj = field(&range_obj, "start") as json::object;
	const start_line = field(&start_obj, "line") as f64;
	const start_char = field(&start_obj, "character") as f64;
	assert(start_line == 0.0 && start_char == 0.0,
		"format edit must replace the whole document, not a partial range");

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
	// The non-canonical `let x  = 1;` must be collapsed to single-space.
	assert(
		strings::contains(new_text, "let x = 1;") &&
			!strings::contains(new_text, "let x  = 1;"),
		"formatter must normalize the double space introduced in the fixture"
	);
};

// Captures the format-output shape we expect from the wrapping
// formatter: comment text isn't double-spaced after `//`, and a
// source blank line between the header and `use io;` survives.
@test fn e2e_format_comment_spacing_and_header_blank_line() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	// `// hi` (one leading space) is what the formatter must emit. The
	// `use     io;` line is intentionally non-canonical so an edit is
	// forced — without it, the bytes_equal short-circuit in
	// handle_formatting would return []. Then assertions actually
	// inspect the formatter's output rather than the input.
	const sample = `// hi

use     io;
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
	assert(
		len(arr) == 1,
		"format must emit one edit for non-canonical input"
	);
	const edit = arr[0] as json::object;
	const new_text = *(json::get(&edit, "newText") as *json::value) as str;

	// Find the comment line in the output by splitting on '\n' and
	// asserting it equals exactly "// hi". A substring `!contains(...)`
	// would also be satisfied by the comment being dropped entirely.
	const lines = strings::split(new_text, "\n")!;
	defer free(lines);
	let saw_comment_line = false;
	for (let i = 0z; i < len(lines); i += 1) {
		if (lines[i] == "// hi") {
			saw_comment_line = true;
			break;
		};
	};
	assert(
		saw_comment_line,
		"`// hi` must appear as its own line, exactly one space after //"
	);
	assert(
		strings::contains(new_text, "// hi\n\nuse io;"),
		"source blank line between comment and use must survive,"
		" and `use     io;` must be normalized to `use io;`"
	);
};

// Long fn signatures wrap their parameter list per the style guide:
// each param on its own line, trailing comma, closing `)` on its own
// line. No formatted line should exceed 80 columns.
@test fn e2e_format_wraps_long_signature() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

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

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

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
		strings::contains(new_text, "some_function(argument_one,"),
		"first arg stays inline with `(` (style guide first code block)"
	);
	assert(
		strings::contains(new_text, "argument_five);"),
		"closing `)` stays adjacent to the last arg, no trailing comma"
	);

	const lines = strings::split(new_text, "\n")!;
	defer free(lines);

	// All five argument names must appear exactly once in the output —
	// catches a regression that duplicates, drops, or reorders args.
	const arg_names: [_]str = ["argument_one", "argument_two",
		"argument_three", "argument_four", "argument_five"];
	for (let a = 0z; a < len(arg_names); a += 1) {
		let count = 0;
		for (let i = 0z; i < len(lines); i += 1) {
			if (strings::contains(lines[i], arg_names[a])) {
				count += 1;
			};
		};
		assert(count == 1,
			"each argument must appear exactly once in the wrapped output");
	};

	// The continuation args (two, three, four) must each start their
	// own line indented with exactly two tabs — depth 1 for `main`'s
	// body plus one more for the call's continuation indent.
	const continuation_args: [_]str = ["argument_two", "argument_three",
		"argument_four"];
	for (let a = 0z; a < len(continuation_args); a += 1) {
		const expected = strings::concat("\t\t", continuation_args[a])!;
		defer free(expected);
		let found = false;
		for (let i = 0z; i < len(lines); i += 1) {
			if (strings::hasprefix(lines[i], expected)) {
				found = true;
				break;
			};
		};
		assert(found,
			"continuation arg must begin its own line at exactly two tabs");
	};

	for (let i = 0z; i < len(lines); i += 1) {
		assert(len(lines[i]) <= 80, "every formatted line fits in 80 columns");
	};
};

// Short signatures and calls stay on one line.
@test fn e2e_format_short_signature_stays_flat() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	// Already-formatted file: the formatter must be idempotent here and
	// emit no edits (the `bytes_equal` short-circuit in handle_formatting
	// at server/formatting.ha:156 should fire). If a regression made the
	// formatter rewrite already-canonical input, len(arr) would be 1.
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
	assert(
		len(arr) == 0,
		"already-canonical short signature must be a no-op format"
	);
};
