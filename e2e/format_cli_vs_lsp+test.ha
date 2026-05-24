// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// End-to-end test asserting that the LSP's textDocument/formatting
// output is byte-identical to `harefmt --stdout`'s output for the
// same input. The formatter is fully opinionated; both code paths
// flow through `server::format_source`, so any divergence is a
// regression.

use encoding::json;
use fmt;
use strings;

@test fn e2e_format_lsp_matches_harefmt_cli() void = {
	// Non-canonical input: extra spaces in the let, trailing spaces and
	// blank lines at EOF, no final newline guarantee. The string
	// literal embeds a multi-byte rune so EOF / offset bugs that only
	// fire on multi-byte buffers are caught - ASCII-only inputs mask
	// the bug per the project rune-vs-byte rule. (Hare identifiers
	// themselves are ASCII-only; the lexer asserts on non-printable-
	// ASCII paths, so multi-byte content has to live in strings or
	// comments.)
	const sample =
		"export fn alphabet() str = {\n\tlet s  = \"αβγ\";\n\treturn s;\n};   \n\n\n";

	const formatted_via_cli = match (run_harefmt_stdin_stdout(
		strings::toutf8(sample))) {
	case let b: []u8 =>
		yield b;
	case let err: str =>
		defer free(err);
		fmt::fatalf("e2e: harefmt invocation failed: {}", err);
	};
	defer free(formatted_via_cli);

	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const did_open = build_did_open("file:///cli_vs_lsp.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	const req =
		`{"jsonrpc":"2.0","id":905,"method":"textDocument/formatting","params":{"textDocument":{"uri":"file:///cli_vs_lsp.ha"},"options":{"tabSize":8,"insertSpaces":false}}}`;
	send(&s, strings::toutf8(req));
	const body = wait_for_response(&s, 905.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	assert(
		len(arr) == 1,
		"non-canonical input must produce exactly one full-document edit"
	);
	const edit = arr[0] as json::object;
	const new_text = *(json::get(&edit, "newText") as *json::value) as str;

	const cli_text = strings::fromutf8(formatted_via_cli)!;
	if (new_text != cli_text) {
		fmt::fatalf(
			"e2e: LSP output differs from harefmt --stdout output\nLSP: {}\nCLI: {}",
			new_text, cli_text);
	};
	// Belt-and-suspenders: EOF must be a single '\n' with no trailing
	// whitespace.
	assert(
		strings::hassuffix(cli_text, ";\n"),
		"formatter must emit a single trailing newline"
	);
	assert(
		!strings::hassuffix(cli_text, " \n"),
		"formatter must strip trailing whitespace before the final newline"
	);
	assert(
		!strings::hassuffix(cli_text, "\n\n"),
		"formatter must collapse trailing blank lines to one newline"
	);
};
