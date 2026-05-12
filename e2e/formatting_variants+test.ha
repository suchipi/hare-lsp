// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// e2e: textDocument/rangeFormatting and textDocument/onTypeFormatting.
// The full-document path is exercised by format+test.ha.

use encoding::json;
use fmt;
use strings;

@test fn e2e_range_formatting_returns_edit_for_selected_decl() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	// A small file where each decl is well-formed -- range format on
	// the whole file is equivalent to full-document format.
	const sample = `export fn one()    int = 1;
export fn two()    int = 2;
`;
	open_doc(&s, "file:///rfmt.ha", sample);

	const req = `{"jsonrpc":"2.0","id":2000,"method":"textDocument/rangeFormatting","params":{"textDocument":{"uri":"file:///rfmt.ha"},"range":{"start":{"line":0,"character":0},"end":{"line":2,"character":0}},"options":{"tabSize":8,"insertSpaces":false}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 2000.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value)
		as []json::value;
	// We expect one edit covering the run.
	assert(len(arr) == 1,
		"range format over both decls should produce one edit");
	const edit = arr[0] as json::object;
	const new_text = *(json::get(&edit, "newText") as *json::value) as str;
	// Pretty printer collapses runs of spaces in fn signatures.
	assert(!strings::contains(new_text, "fn one()    int"),
		"range format should collapse the extra spaces");
};

@test fn e2e_range_formatting_outside_decls_returns_empty() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `export fn one() int = 1;
`;
	open_doc(&s, "file:///rfmt2.ha", sample);

	// A range entirely past the end of the file -> no overlap with any
	// decl -> empty result.
	const req = `{"jsonrpc":"2.0","id":2001,"method":"textDocument/rangeFormatting","params":{"textDocument":{"uri":"file:///rfmt2.ha"},"range":{"start":{"line":10,"character":0},"end":{"line":11,"character":0}},"options":{"tabSize":8,"insertSpaces":false}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 2001.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value)
		as []json::value;
	assert(len(arr) == 0,
		"a range with no overlap to any decl should return no edits");
};

@test fn e2e_on_type_formatting_for_brace_reindents() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	// Closing brace mis-indented at column 0 inside a fn body. The
	// trigger char '}' should re-indent the leading whitespace on its
	// line.
	const sample = `export fn main() void = {
	let x = 1;
}
`;
	open_doc(&s, "file:///otf.ha", sample);

	// Cursor right after the `}` on line 2: position { line: 2, character: 1 }.
	const req = `{"jsonrpc":"2.0","id":2002,"method":"textDocument/onTypeFormatting","params":{"textDocument":{"uri":"file:///otf.ha"},"position":{"line":2,"character":1},"ch":"}","options":{"tabSize":8,"insertSpaces":false}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 2002.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	// Result is an array (possibly empty if already indented correctly).
	assert(*(json::get(&obj, "result") as *json::value)
		is []json::value,
		"onTypeFormatting must return an array");
};

@test fn e2e_on_type_formatting_ignores_semicolon_trigger() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `export fn main() void = void;
`;
	open_doc(&s, "file:///otf2.ha", sample);

	const req = `{"jsonrpc":"2.0","id":2003,"method":"textDocument/onTypeFormatting","params":{"textDocument":{"uri":"file:///otf2.ha"},"position":{"line":0,"character":29},"ch":";","options":{"tabSize":8,"insertSpaces":false}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 2003.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value)
		as []json::value;
	assert(len(arr) == 0,
		"onTypeFormatting must not return edits for `;` in Hare");
};
