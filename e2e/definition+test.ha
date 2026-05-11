// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// e2e checks for textDocument/documentLink and textDocument/definition.
// These spawn the real binary so we catch issues that depend on the
// full workspace + stdlib indexing path the way VSCode hits it.

use encoding::json;
use fmt;
use strings;

// Reproduces a VS Code regression where, in any file matching the
// pattern `use X;\n\n// comment\n...`, the FIRST comment after the
// `use` block was fully underlined and cmd+clicking it navigated
// into module X. Cause: `textDocument/documentLink` used the
// import's `loc.end.off`, which the upstream parser sets to the
// position of the NEXT token via `mkloc(lexer)`. Because the LSP
// parses without comment tokens, "next token" was whatever real
// code came after the `use` block — possibly several lines later,
// across blank lines and intervening comments — so the emitted
// DocumentLink range covered the comment too. Fix: capture the
// `;` token's own location during parse and use that for loc.end.
@test fn e2e_documentlink_does_not_extend_into_following_comment() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s, strings::toutf8(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`));
	free(wait_for_response(&s, 1.0));
	send(&s, strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	// Mirrors the lsp/codec.ha and server/navigation.ha shape that
	// triggered the bug: a single `use` followed by a blank line
	// followed by a `//` comment.
	const sample = `use strings;

// LSP SymbolKind values used here.
export fn main() void = void;
`;
	const did_open = build_did_open("file:///dl_cmt.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	const req = `{"jsonrpc":"2.0","id":710,"method":"textDocument/documentLink","params":{"textDocument":{"uri":"file:///dl_cmt.ha"}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 710.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield match (*p) {
		case let a: []json::value => yield a;
		case =>
			fmt::fatalf("e2e: documentLink result not an array: {}",
				text);
		};
	case void =>
		fmt::fatalf("e2e: documentLink response missing result: {}",
			text);
	};
	assert(len(arr) == 1, "expected exactly one DocumentLink for the import");
	const link = arr[0] as json::object;
	const range = *(json::get(&link, "range") as *json::value)
		as json::object;
	const end = *(json::get(&range, "end") as *json::value)
		as json::object;
	const end_line = *(json::get(&end, "line") as *json::value)
		as f64;
	// The import is on line 0; its DocumentLink range must NOT
	// extend past line 0.
	assert(end_line == 0.0,
		"DocumentLink for `use` must not extend into the blank line or following comment");
};

// Sanity check that documentLink + resolve still works end-to-end on
// a real qualified call after the parser fix above.
@test fn e2e_definition_on_qualified_call_resolves() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s, strings::toutf8(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`));
	free(wait_for_response(&s, 1.0));
	send(&s, strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample = `use strings;

export fn main() void = {
	let s = strings::dup("hello")!;
	let _ = s;
};
`;
	const did_open = build_did_open("file:///def_real.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Line 3, char 19 = the `u` of `dup` in `strings::dup(...)`.
	// This SHOULD resolve to the stdlib strings module.
	const req = `{"jsonrpc":"2.0","id":701,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///def_real.ha"},"position":{"line":3,"character":19}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 701.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = match (json::get(&obj, "result")) {
	case let p: *json::value => yield *p;
	case void =>
		fmt::fatalf("e2e: definition response missing result: {}",
			text);
	};
	assert(result is json::object,
		"definition on a real qualified call must return a Location");
	const loc = result as json::object;
	const uri = *(json::get(&loc, "uri") as *json::value) as str;
	assert(strings::contains(uri, "/strings/"),
		"definition should point into the strings module");
};
