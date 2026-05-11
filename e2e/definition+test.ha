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

// The DocumentLink range for an import should cover exactly the
// module identifier (cmd+click underline in VS Code highlights this
// range). For `use strings;` that's `strings`, columns 4..11. The
// bug we're guarding against shifts the range earlier than the
// identifier so the underline straddles the `use` keyword.
@test fn e2e_documentlink_covers_single_segment_identifier() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s, strings::toutf8(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`));
	free(wait_for_response(&s, 1.0));
	send(&s, strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample = `use strings;
export fn main() void = void;
`;
	const did_open = build_did_open("file:///dl_single.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	const req = `{"jsonrpc":"2.0","id":711,"method":"textDocument/documentLink","params":{"textDocument":{"uri":"file:///dl_single.ha"}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 711.0);
	defer free(body);
	check_link_range(body, 0.0, 4.0, 11.0);
};

// Same property for a multi-segment import: `use hare::ast;` should
// underline `hare::ast` (columns 4..13), not something shifted.
@test fn e2e_documentlink_covers_multi_segment_identifier() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s, strings::toutf8(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`));
	free(wait_for_response(&s, 1.0));
	send(&s, strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample = `use hare::ast;
export fn main() void = void;
`;
	const did_open = build_did_open("file:///dl_multi.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	const req = `{"jsonrpc":"2.0","id":712,"method":"textDocument/documentLink","params":{"textDocument":{"uri":"file:///dl_multi.ha"}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 712.0);
	defer free(body);
	check_link_range(body, 0.0, 4.0, 13.0);
};

// Verifies the alignment is correct for EVERY import in a file with
// many imports of varying segment counts — mirrors the actual
// server/symbols.ha header where the user reported the misalignment.
@test fn e2e_documentlink_aligns_in_multi_import_header() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s, strings::toutf8(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`));
	free(wait_for_response(&s, 1.0));
	send(&s, strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample = `use analysis;
use encoding::json;
use hare::ast;
use hare::module;
use lsp;
use strings;

export fn main() void = void;
`;
	const did_open = build_did_open("file:///dl_many.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	const req = `{"jsonrpc":"2.0","id":713,"method":"textDocument/documentLink","params":{"textDocument":{"uri":"file:///dl_many.ha"}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 713.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value)
		as []json::value;
	assert(len(arr) == 6, "expected six DocumentLinks");

	// Each tuple = (line, expected_start_char, expected_end_char).
	const expected: [_](f64, f64, f64) = [
		(0.0, 4.0, 12.0),  // `use analysis;`        -> "analysis"     cols 4..12
		(1.0, 4.0, 18.0),  // `use encoding::json;`  -> "encoding::json" cols 4..18
		(2.0, 4.0, 13.0),  // `use hare::ast;`       -> "hare::ast"    cols 4..13
		(3.0, 4.0, 16.0),  // `use hare::module;`    -> "hare::module" cols 4..16
		(4.0, 4.0, 7.0),   // `use lsp;`             -> "lsp"          cols 4..7
		(5.0, 4.0, 11.0),  // `use strings;`         -> "strings"      cols 4..11
	];
	for (let i = 0z; i < len(arr); i += 1) {
		const link = arr[i] as json::object;
		const range = *(json::get(&link, "range") as *json::value)
			as json::object;
		const start = *(json::get(&range, "start") as *json::value)
			as json::object;
		const end = *(json::get(&range, "end") as *json::value)
			as json::object;
		const start_line = *(json::get(&start, "line")
			as *json::value) as f64;
		const start_char = *(json::get(&start, "character")
			as *json::value) as f64;
		const end_line = *(json::get(&end, "line")
			as *json::value) as f64;
		const end_char = *(json::get(&end, "character")
			as *json::value) as f64;
		const exp = expected[i];
		if (start_line != exp.0 || end_line != exp.0
				|| start_char != exp.1
				|| end_char != exp.2) {
			fmt::fatalf("link[{}] = ({},{}..{},{}), expected ({},{}..{},{}). body={}",
				i, start_line, start_char,
				end_line, end_char,
				exp.0, exp.1, exp.0, exp.2, text);
		};
	};
};

fn check_link_range(body: []u8, line: f64, start_col: f64, end_col: f64) void = {
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value)
		as []json::value;
	assert(len(arr) == 1, "expected one DocumentLink");
	const link = arr[0] as json::object;
	const range = *(json::get(&link, "range") as *json::value)
		as json::object;
	const start = *(json::get(&range, "start") as *json::value)
		as json::object;
	const end = *(json::get(&range, "end") as *json::value)
		as json::object;
	const start_line = *(json::get(&start, "line")
		as *json::value) as f64;
	const start_char = *(json::get(&start, "character")
		as *json::value) as f64;
	const end_line = *(json::get(&end, "line")
		as *json::value) as f64;
	const end_char = *(json::get(&end, "character")
		as *json::value) as f64;
	if (start_line != line || end_line != line
			|| start_char != start_col
			|| end_char != end_col) {
		fmt::fatalf("DocumentLink range = ({},{}..{},{}), expected ({},{}..{},{}). body={}",
			start_line, start_char, end_line, end_char,
			line, start_col, line, end_col, text);
	};
};

// When the file contains multi-byte UTF-8 characters BEFORE the
// `use` block (e.g. an em-dash in a header comment), the AST's
// loc.start.off is rune-indexed by hare::lex while
// `byte_to_position` interprets it as a byte offset. Each em-dash
// (3 bytes, 1 rune) shifts the apparent column by 2 to the LEFT.
// Reproduces by putting an em-dash above the imports.
@test fn e2e_documentlink_aligns_with_multibyte_above() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s, strings::toutf8(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`));
	free(wait_for_response(&s, 1.0));
	send(&s, strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample = `// header — has an em-dash
use strings;
export fn main() void = void;
`;
	const did_open = build_did_open("file:///dl_mb.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	const req = `{"jsonrpc":"2.0","id":714,"method":"textDocument/documentLink","params":{"textDocument":{"uri":"file:///dl_mb.ha"}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 714.0);
	defer free(body);
	// `use strings;` is on line 1; "strings" is at columns 4..11.
	check_link_range(body, 1.0, 4.0, 11.0);
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
