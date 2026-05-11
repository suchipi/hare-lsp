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

	send(&s, strings::toutf8(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`));
	free(wait_for_response(&s, 1.0));
	send(&s, strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample = `// SPDX-License-Identifier: MPL-2.0
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

	const req = `{"jsonrpc":"2.0","id":900,"method":"textDocument/formatting","params":{"textDocument":{"uri":"file:///fmt_e2e.ha"},"options":{"tabSize":8,"insertSpaces":false}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 900.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = match (json::get(&obj, "result")) {
	case let p: *json::value => yield *p;
	case void =>
		fmt::fatalf("e2e: format response missing result: {}", text);
	};
	const arr = match (result) {
	case let a: []json::value => yield a;
	case =>
		fmt::fatalf("e2e: format result is not an array: {}", text);
	};
	assert(len(arr) == 1, "expected exactly one text edit");
	const edit = arr[0] as json::object;
	const new_text = match (json::get(&edit, "newText")) {
	case let p: *json::value => yield *p as str;
	case void =>
		fmt::fatalf("e2e: edit missing newText: {}", text);
	};

	assert(strings::contains(new_text, "SPDX-License-Identifier"),
		"file-header comment must survive format-on-save");
	assert(strings::contains(new_text, "(c) e2e test"),
		"second header comment must survive");
	assert(strings::contains(new_text, "leading note"),
		"inline comment before a statement must survive");
	assert(strings::contains(new_text, "trailing note"),
		"inline comment between statements must survive");
};
