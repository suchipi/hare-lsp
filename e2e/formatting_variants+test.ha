// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// e2e: textDocument/rangeFormatting and textDocument/onTypeFormatting.
// The full-document path is exercised by format+test.ha.

use encoding::json;
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

	const req =
		`{"jsonrpc":"2.0","id":2000,"method":"textDocument/rangeFormatting","params":{"textDocument":{"uri":"file:///rfmt.ha"},"range":{"start":{"line":0,"character":0},"end":{"line":2,"character":0}},"options":{"tabSize":8,"insertSpaces":false}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 2000.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	// We expect one edit covering the run.
	assert(len(arr) == 1, "range format over both decls should produce one edit");
	const edit = arr[0] as json::object;
	const new_text = *(json::get(&edit, "newText") as *json::value) as str;
	// Positive structural assertions: both decls survive the rewrite
	// with their messy spacing collapsed. A bare `!contains(...)` on
	// the messy version would also pass if the formatter mangled or
	// dropped the second decl.
	assert(
		strings::contains(new_text, "export fn one() int = 1;"),
		"first decl must be normalized to single-space form"
	);
	assert(
		strings::contains(new_text, "export fn two() int = 2;"),
		"second decl must be normalized too (not dropped or partially rewritten)"
	);
	assert(
		!strings::contains(new_text, "    "),
		"no run of four spaces should remain in the formatted output"
	);
	// The edit must replace the run that covers both decls. The
	// formatter sets range.start = decls[first].loc.start and
	// range.end = decls[last].loc.end (server/formatting.ha:294-299),
	// so the run starts at {0, 0} regardless of indent style.
	const range = *(json::get(&edit, "range") as *json::value) as json::object;
	const start = *(json::get(&range, "start") as *json::value) as json::object;
	const sl = *(json::get(&start, "line") as *json::value) as f64;
	const sc = *(json::get(&start, "character") as *json::value) as f64;
	assert(
		sl == 0.0 && sc == 0.0,
		"range-format edit must start at the first decl ({0,0})"
	);
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
	const req =
		`{"jsonrpc":"2.0","id":2001,"method":"textDocument/rangeFormatting","params":{"textDocument":{"uri":"file:///rfmt2.ha"},"range":{"start":{"line":10,"character":0},"end":{"line":11,"character":0}},"options":{"tabSize":8,"insertSpaces":false}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 2001.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	assert(
		len(arr) == 0,
		"a range with no overlap to any decl should return no edits"
	);
};

@test fn e2e_on_type_formatting_for_brace_reindents() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	// Closing brace over-indented (two tabs) at the end of `main`. The
	// expected indent at depth 0 is empty, so the server must emit one
	// edit that replaces the leading "\t\t" with "". A fixture where
	// the brace is already at column 0 would exercise the no-op path
	// (server/formatting.ha:437) and silently pass regardless of
	// whether the reindent logic works.
	const sample = `export fn main() void = {
	let x = 1;
		}
`;
	open_doc(&s, "file:///otf.ha", sample);

	// Cursor right after the `}` on line 2: position { line: 2, character: 3 }
	// — two tabs + '}'. tabSize/insertSpaces only affect the new indent
	// string; cursor `character` is a UTF-16 unit index in the line.
	const req =
		`{"jsonrpc":"2.0","id":2002,"method":"textDocument/onTypeFormatting","params":{"textDocument":{"uri":"file:///otf.ha"},"position":{"line":2,"character":3},"ch":"}","options":{"tabSize":8,"insertSpaces":false}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 2002.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	assert(
		len(arr) == 1,
		"closing `}` at the wrong indent must produce exactly one edit"
	);
	const edit = arr[0] as json::object;
	const new_text = *(json::get(&edit, "newText") as *json::value) as str;
	assert(
		new_text == "",
		"the reindent edit should erase the over-indent down to depth 0"
	);
	const range = *(json::get(&edit, "range") as *json::value) as json::object;
	const start = *(json::get(&range, "start") as *json::value) as json::object;
	const end = *(json::get(&range, "end") as *json::value) as json::object;
	const sl = *(json::get(&start, "line") as *json::value) as f64;
	const sc = *(json::get(&start, "character") as *json::value) as f64;
	const el = *(json::get(&end, "line") as *json::value) as f64;
	const ec = *(json::get(&end, "character") as *json::value) as f64;
	assert(
		sl == 2.0 && sc == 0.0,
		"reindent edit must start at column 0 of the brace's line"
	);
	assert(
		el == 2.0 && ec == 2.0,
		"reindent edit must end after the leading two-tab over-indent"
	);
};

@test fn e2e_on_type_formatting_ignores_semicolon_trigger() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `export fn main() void = void;
`;
	open_doc(&s, "file:///otf2.ha", sample);

	const req =
		`{"jsonrpc":"2.0","id":2003,"method":"textDocument/onTypeFormatting","params":{"textDocument":{"uri":"file:///otf2.ha"},"position":{"line":0,"character":29},"ch":";","options":{"tabSize":8,"insertSpaces":false}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 2003.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	assert(
		len(arr) == 0,
		"onTypeFormatting must not return edits for `;` in Hare"
	);
};
