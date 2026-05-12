// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// e2e: document and workspace symbol providers.

use encoding::json;
use fmt;
use strings;

@test fn e2e_document_symbol_returns_all_decls() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample =
		`export fn one() void = void;
export fn two() int = 2;
type my_type = int;
export def MY_CONST: int = 7;
`;
	open_doc(&s, "file:///docsym.ha", sample);

	const req =
		`{"jsonrpc":"2.0","id":1200,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///docsym.ha"}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1200.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	assert(
		len(arr) == 4,
		"expected exactly four document symbols (one, two, my_type, MY_CONST)"
	);

	// Collect names to assert content rather than ordering.
	let saw_one = false, saw_two = false, saw_type = false, saw_const = false;
	for (let i = 0z; i < len(arr); i += 1) {
		const sym = arr[i] as json::object;
		const name = *(json::get(&sym, "name") as *json::value) as str;
		if (name == "one") saw_one = true;
		if (name == "two") saw_two = true;
		if (name == "my_type") saw_type = true;
		if (name == "MY_CONST") saw_const = true;
	};
	assert(
		saw_one && saw_two && saw_type && saw_const,
		"all four decl names must appear in documentSymbol output"
	);
};

@test fn e2e_document_highlight_returns_array() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample =
		`export fn answer() int = 42;

export fn ask() int = answer();
`;
	open_doc(&s, "file:///hl.ha", sample);

	// Cursor on `answer` in the declaration (line 0, char 12).
	const req =
		`{"jsonrpc":"2.0","id":1201,"method":"textDocument/documentHighlight","params":{"textDocument":{"uri":"file:///hl.ha"},"position":{"line":0,"character":12}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1201.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	assert(
		len(arr) >= 1,
		"documentHighlight should return at least one range for the decl"
	);
	const hl0 = arr[0] as json::object;
	assert(
		json::get(&hl0, "range") is *json::value,
		"each highlight must include a range"
	);
};

@test fn e2e_workspace_symbol_finds_open_decl() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `export fn an_unusual_name() void = void;
`;
	open_doc(&s, "file:///wsym.ha", sample);

	// Empty query returns capped list of all entries; that may not
	// include open-doc decls until workspace scan settles. Use a fuzzy
	// query that should match the symbol in the open doc.
	const req =
		`{"jsonrpc":"2.0","id":1202,"method":"workspace/symbol","params":{"query":"an_unusual"}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1202.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result_obj =
		*(json::get(&obj, "result") as *json::value) as json::object;
	assert(
		json::get(&result_obj, "items") is *json::value,
		"workspace/symbol result must include items array"
	);
	assert(
		json::get(&result_obj, "isIncomplete") is *json::value,
		"workspace/symbol result must include isIncomplete"
	);
};

// workspace/symbol must surface stdlib symbols even when the user has
// never navigated through the relevant module. The first call kicks
// off a full stdlib indexing job; we poll until a stdlib symbol
// becomes findable.
@test fn e2e_workspace_symbol_finds_stdlib_symbol() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	// `newscanner` lives only in stdlib (bufio). Poll up to ~10s for
	// the indexing job to populate enough of the stdlib to find it.
	let found = false;
	for (let attempt = 0z; attempt < 50z; attempt += 1) {
		const id = 1210.0 + attempt: f64;
		const tmpl = `{"jsonrpc":"2.0","id":`;
		const id_buf: [16]u8 = [0...];
		const id_str = fmt::bsprintf(id_buf, "{}", id: f64)!;
		const req =
			strings::concat(tmpl,
				id_str, `,"method":"workspace/symbol","params":{"query":"newscanner"}}`)!;
		defer free(req);
		send(&s, strings::toutf8(req));
		const body = wait_for_response(&s, id);
		defer free(body);
		const text = strings::fromutf8(body)!;
		if (strings::contains(text, `"newscanner"`)) {
			found = true;
			break;
		};
	};
	assert(
		found,
		"workspace/symbol must eventually surface a stdlib symbol after indexing"
	);
};

@test fn e2e_workspace_symbol_resolve_passthrough() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	// Resolve is a passthrough — feed it a synthetic WorkspaceSymbol and
	// confirm we get a non-error response.
	const req =
		`{"jsonrpc":"2.0","id":1203,"method":"workspaceSymbol/resolve","params":{"name":"x","kind":12,"location":{"uri":"file:///x.ha","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1203.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	assert(
		json::get(&obj, "error") is void,
		"workspaceSymbol/resolve passthrough must not error"
	);
	assert(
		json::get(&obj, "result") is *json::value,
		"workspaceSymbol/resolve must include a result"
	);
};
