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

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	// Mirrors the lsp/codec.ha and server/navigation.ha shape that
	// triggered the bug: a single `use` followed by a blank line
	// followed by a `//` comment.
	const sample =
		`use strings;

// LSP SymbolKind values used here.
export fn main() void = void;
`;
	const did_open = build_did_open("file:///dl_cmt.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	const req =
		`{"jsonrpc":"2.0","id":710,"method":"textDocument/documentLink","params":{"textDocument":{"uri":"file:///dl_cmt.ha"}}}`;
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
		case let a: []json::value =>
			yield a;
		case =>
			fmt::fatalf("e2e: documentLink result not an array: {}", text);
		};
	case void =>
		fmt::fatalf("e2e: documentLink response missing result: {}", text);
	};
	assert(len(arr) == 1, "expected exactly one DocumentLink for the import");
	const link = arr[0] as json::object;
	const range = *(json::get(&link, "range") as *json::value) as json::object;
	const end = *(json::get(&range, "end") as *json::value) as json::object;
	const end_line = *(json::get(&end, "line") as *json::value) as f64;
	// The import is on line 0; its DocumentLink range must NOT
	// extend past line 0.
	assert(
		end_line == 0.0,
		"DocumentLink for `use` must not extend into the blank line or following comment"
	);
};

// The DocumentLink range for an import should cover exactly the
// module identifier (cmd+click underline in VS Code highlights this
// range). For `use strings;` that's `strings`, columns 4..11. The
// bug we're guarding against shifts the range earlier than the
// identifier so the underline straddles the `use` keyword.
@test fn e2e_documentlink_covers_single_segment_identifier() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample = `use strings;
export fn main() void = void;
`;
	const did_open = build_did_open("file:///dl_single.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	const req =
		`{"jsonrpc":"2.0","id":711,"method":"textDocument/documentLink","params":{"textDocument":{"uri":"file:///dl_single.ha"}}}`;
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

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample = `use hare::ast;
export fn main() void = void;
`;
	const did_open = build_did_open("file:///dl_multi.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	const req =
		`{"jsonrpc":"2.0","id":712,"method":"textDocument/documentLink","params":{"textDocument":{"uri":"file:///dl_multi.ha"}}}`;
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

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample =
		`use analysis;
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

	const req =
		`{"jsonrpc":"2.0","id":713,"method":"textDocument/documentLink","params":{"textDocument":{"uri":"file:///dl_many.ha"}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 713.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	assert(len(arr) == 6, "expected six DocumentLinks");

	// Each tuple = (line, expected_start_char, expected_end_char).
	const expected: [_](f64, f64, f64) = [
		(0.0, 4.0, 12.0),
		(1.0, 4.0, 18.0),
		(2.0, 4.0, 13.0),
		(3.0, 4.0, 16.0),
		(4.0, 4.0, 7.0),
		(5.0, 4.0, 11.0),
	];
	// `use analysis;`        -> "analysis"     cols 4..12
	// `use encoding::json;`  -> "encoding::json" cols 4..18
	// `use hare::ast;`       -> "hare::ast"    cols 4..13
	// `use hare::module;`    -> "hare::module" cols 4..16
	// `use lsp;`             -> "lsp"          cols 4..7
	// `use strings;`         -> "strings"      cols 4..11
	for (let i = 0z; i < len(arr); i += 1) {
		const link = arr[i] as json::object;
		const range = *(json::get(&link, "range") as *json::value) as json::object;
		const start = *(json::get(&range, "start") as *json::value) as json::object;
		const end = *(json::get(&range, "end") as *json::value) as json::object;
		const start_line = *(json::get(&start, "line") as *json::value) as f64;
		const start_char = *(json::get(&start, "character") as *json::value) as f64;
		const end_line = *(json::get(&end, "line") as *json::value) as f64;
		const end_char = *(json::get(&end, "character") as *json::value) as f64;
		const exp = expected[i];
		if (start_line != exp.0 || end_line != exp.0 || start_char != exp.1 ||
				end_char != exp.2) {
			fmt::fatalf("link[{}] = ({},{}..{},{}), expected ({},{}..{},{}). body={}", i,
				start_line, start_char, end_line, end_char, exp.0, exp.1, exp.0, exp.2,
				text);
		};
	};
};

fn check_link_range(
	body: []u8,
	line: f64,
	start_col: f64,
	end_col: f64,
) void = {
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	assert(len(arr) == 1, "expected one DocumentLink");
	const link = arr[0] as json::object;
	const range = *(json::get(&link, "range") as *json::value) as json::object;
	const start = *(json::get(&range, "start") as *json::value) as json::object;
	const end = *(json::get(&range, "end") as *json::value) as json::object;
	const start_line = *(json::get(&start, "line") as *json::value) as f64;
	const start_char = *(json::get(&start, "character") as *json::value) as f64;
	const end_line = *(json::get(&end, "line") as *json::value) as f64;
	const end_char = *(json::get(&end, "character") as *json::value) as f64;
	if (start_line != line || end_line != line || start_char != start_col ||
			end_char != end_col) {
		fmt::fatalf(
			"DocumentLink range = ({},{}..{},{}), expected ({},{}..{},{}). body={}",
			start_line, start_char, end_line, end_char, line, start_col, line, end_col,
			text);
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

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample =
		`// header — has an em-dash
use strings;
export fn main() void = void;
`;
	const did_open = build_did_open("file:///dl_mb.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	const req =
		`{"jsonrpc":"2.0","id":714,"method":"textDocument/documentLink","params":{"textDocument":{"uri":"file:///dl_mb.ha"}}}`;
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

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample =
		`use strings;

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
	const req =
		`{"jsonrpc":"2.0","id":701,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///def_real.ha"},"position":{"line":3,"character":19}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 701.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield *p;
	case void =>
		fmt::fatalf("e2e: definition response missing result: {}", text);
	};
	// Definition for a single, in-file decl should be a Location object
	// (not an array, not null). If the server changes to LocationLink[],
	// update this test deliberately.
	const loc = match (result) {
	case let o: json::object =>
		yield o;
	case =>
		fmt::fatalf("e2e: definition result not a Location object: {}", text);
	};
	const uri = *(json::get(&loc, "uri") as *json::value) as str;
	// Tight URI check: must land in stdlib's `strings` module, on the
	// `dup.ha` file specifically. `strings::contains(.../strings/)`
	// would also match unrelated paths that happen to contain `/strings/`.
	assert(
		strings::hassuffix(uri, "/strings/dup.ha"),
		"definition should point at stdlib's strings/dup.ha specifically"
	);
	// Range must be non-degenerate and within the dup() decl region.
	// `dup` is the first decl in dup.ha (the file also contains
	// `dupall` further down); locking the line range to the dup() block
	// guards against the handler returning `dupall`'s location or a
	// zero-default range pointing at the file header.
	const range = *(json::get(&loc, "range") as *json::value) as json::object;
	const start = *(json::get(&range, "start") as *json::value) as json::object;
	const end = *(json::get(&range, "end") as *json::value) as json::object;
	const start_line = *(json::get(&start, "line") as *json::value) as f64;
	const start_char = *(json::get(&start, "character") as *json::value) as f64;
	const end_line = *(json::get(&end, "line") as *json::value) as f64;
	const end_char = *(json::get(&end, "character") as *json::value) as f64;
	assert(
		start_line >= 4.0 && start_line < 20.0,
		"definition's range.start.line should land in dup()'s decl, not dupall() or the file header"
	);
	assert(
		end_line > start_line || end_char > start_char,
		"definition's range must be non-empty"
	);
};

// Regression: go-to-definition on `mime::lookup_ext` must resolve to the
// real `export fn lookup_ext` in stdlib's mime/lookup.ha, NOT the
// same-named `@test fn lookup_ext` in mime/entries+test.ha. The stdlib
// indexer walks every `*.ha` file in the module (including `+test.ha`),
// so without filtering out `@test` decls the test function could win the
// lookup. Exercises the full lazy-stdlib-index + workspace-fallback path.
@test fn e2e_definition_skips_test_function_in_stdlib() void = {
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
		`use mime;

export fn main() void = {
	let _ = mime::lookup_ext("txt");
};
`;
	const did_open = build_did_open("file:///def_test_attr.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Line 3: "\tlet _ = mime::lookup_ext(\"txt\");". After the tab,
	// `let _ = mime::` is 14 cols, so `lookup_ext` starts at col 15;
	// char 17 lands inside it.
	const req =
		`{"jsonrpc":"2.0","id":702,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///def_test_attr.ha"},"position":{"line":3,"character":17}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 702.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield *p;
	case void =>
		fmt::fatalf("e2e: definition response missing result: {}", text);
	};
	const loc = match (result) {
	case let o: json::object =>
		yield o;
	case =>
		fmt::fatalf(
			"e2e: definition on mime::lookup_ext returned null/non-object -- stdlib fallback regressed. body={}",
			text);
	};
	const uri = *(json::get(&loc, "uri") as *json::value) as str;
	assert(
		!strings::hassuffix(uri, "/mime/entries+test.ha"),
		"definition must not resolve to the @test fn in mime/entries+test.ha"
	);
	assert(
		strings::hassuffix(uri, "/mime/lookup.ha"),
		"definition on mime::lookup_ext should point at the real impl in mime/lookup.ha"
	);
};

// Same-file regression: editing a test file whose `@test fn` is named after
// the function under test, a bare call to that function inside the test body
// must jump to the real implementation in the sibling file, not to the
// enclosing `@test fn`. Test files are routinely named after the function
// they test, so landing on the test itself is useless.
@test fn e2e_definition_skips_local_test_fn_for_real_impl() void = {
	const files: [](str, str) = [
		("mymod/impl.ha", "export fn samename(x: int) int = x;\n"),
		(
			"mymod/impl+test.ha",
			"@test fn samename() void = {\n\tlet _ = samename(1);\n};\n",
		),
	];
	const root = make_workspace("def-samefile-test", files);
	defer cleanup_workspace(root);

	let s = spawn_session();
	defer finish_session(&s);
	do_init_with_workspace(&s, root);
	drain_until_indexed_ref(&s);

	const test_uri = strings::concat("file://", root, "/mymod/impl+test.ha")!;
	defer free(test_uri);
	open_doc(&s, test_uri, files[1].1);

	// Line 1: "\tlet _ = samename(1);". After the tab, `let _ = ` is 8
	// cols, so the call `samename` starts at col 9; char 11 lands inside.
	const tmpl =
		`{"jsonrpc":"2.0","id":703,"method":"textDocument/definition","params":{"textDocument":{"uri":"`;
	const req =
		strings::concat(tmpl, test_uri, `"},"position":{"line":1,"character":11}}}`)!;
	defer free(req);
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 703.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield *p;
	case void =>
		fmt::fatalf("e2e: definition response missing result: {}", text);
	};
	const loc = match (result) {
	case let o: json::object =>
		yield o;
	case =>
		fmt::fatalf(
			"e2e: same-file definition returned null/non-object -- workspace fallback regressed. body={}",
			text);
	};
	const uri = *(json::get(&loc, "uri") as *json::value) as str;
	assert(
		!strings::hassuffix(uri, "/mymod/impl+test.ha"),
		"definition must not land on the enclosing @test fn in the open test file"
	);
	assert(
		strings::hassuffix(uri, "/mymod/impl.ha"),
		"definition should resolve to the real impl in the sibling mymod/impl.ha"
	);
};
