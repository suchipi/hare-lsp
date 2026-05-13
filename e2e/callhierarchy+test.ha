// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// e2e: call hierarchy. The three methods compose:
//   prepareCallHierarchy -> CallHierarchyItem
//   callHierarchy/incomingCalls -> CallHierarchyIncomingCall[]
//   callHierarchy/outgoingCalls -> CallHierarchyOutgoingCall[]

use encoding::json;
use strings;

@test fn e2e_prepare_call_hierarchy_returns_item_for_fn() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample =
		`export fn answer() int = 42;

export fn ask() int = answer();
`;
	open_doc(&s, "file:///ch.ha", sample);

	// Cursor on `answer` in the decl (line 0, char 12).
	const req =
		`{"jsonrpc":"2.0","id":1600,"method":"textDocument/prepareCallHierarchy","params":{"textDocument":{"uri":"file:///ch.ha"},"position":{"line":0,"character":12}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1600.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	assert(
		len(arr) == 1,
		"prepareCallHierarchy should return one item for a fn decl"
	);
	const item = arr[0] as json::object;
	const name = *(json::get(&item, "name") as *json::value) as str;
	assert(
		name == "answer",
		"item name should match the function under the cursor"
	);
	const kind = *(json::get(&item, "kind") as *json::value) as f64;
	assert(kind == 12.0, "kind must be SymbolKind.Function (12)");
	// `range` should cover the whole decl (so the editor can show the
	// outline pointer at it); `selectionRange` should be just the
	// identifier so clicking the item lands the cursor on the name.
	const rng = *(json::get(&item, "range") as *json::value) as json::object;
	const r_start = *(json::get(&rng, "start") as *json::value) as json::object;
	const r_line = *(json::get(&r_start, "line") as *json::value) as f64;
	assert(r_line == 0.0, "range starts on the decl's line");

	const sel =
		*(json::get(&item, "selectionRange") as *json::value) as json::object;
	const s_start = *(json::get(&sel, "start") as *json::value) as json::object;
	const s_end = *(json::get(&sel, "end") as *json::value) as json::object;
	const s_line = *(json::get(&s_start, "line") as *json::value) as f64;
	const s_ch = *(json::get(&s_start, "character") as *json::value) as f64;
	const e_ch = *(json::get(&s_end, "character") as *json::value) as f64;
	assert(s_line == 0.0, "selectionRange is on the decl line");
	// `answer` starts at column 10 in "export fn answer(" and is 6
	// chars long.
	assert(
		s_ch == 10.0,
		"selectionRange.start.character must point at the identifier"
	);
	assert(
		e_ch == 16.0,
		"selectionRange.end.character must end after the identifier"
	);
};

@test fn e2e_call_hierarchy_incoming_returns_array() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample =
		`export fn answer() int = 42;

export fn ask() int = answer();
`;
	open_doc(&s, "file:///chi.ha", sample);

	// Feed a CallHierarchyItem we know corresponds to `answer`.
	const req =
		`{"jsonrpc":"2.0","id":1601,"method":"callHierarchy/incomingCalls","params":{"item":{"name":"answer","kind":12,"uri":"file:///chi.ha","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":28}},"selectionRange":{"start":{"line":0,"character":10},"end":{"line":0,"character":16}}}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1601.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	// The call from `ask` to `answer` should appear.
	assert(len(arr) == 1, "incomingCalls should report one caller of `answer`");
	const call = arr[0] as json::object;
	const from = *(json::get(&call, "from") as *json::value) as json::object;
	// from.name + from.uri identify the caller. The server currently
	// groups by file (so `from.name` is a file basename and `from.kind`
	// is SymbolKind.Module=2); this test pins down enough structure to
	// catch regressions like empty names, wrong URI, or missing
	// fromRanges without locking in the basename behavior itself.
	const from_name = *(json::get(&from, "name") as *json::value) as str;
	const from_uri = *(json::get(&from, "uri") as *json::value) as str;
	const from_kind = *(json::get(&from, "kind") as *json::value) as f64;
	assert(len(from_name) > 0, "from.name must not be empty");
	assert(
		from_uri == "file:///chi.ha",
		"from.uri must point at the caller's file"
	);
	assert(from_kind > 0.0, "from.kind must be a real SymbolKind value");

	const from_ranges =
		*(json::get(&call, "fromRanges") as *json::value) as []json::value;
	assert(
		len(from_ranges) >= 1,
		"fromRanges must include the call site inside `ask`"
	);
	const fr0 = from_ranges[0] as json::object;
	const fr_start = *(json::get(&fr0, "start") as *json::value) as json::object;
	const fr_end = *(json::get(&fr0, "end") as *json::value) as json::object;
	const fr_line = *(json::get(&fr_start, "line") as *json::value) as f64;
	const fr_ch = *(json::get(&fr_start, "character") as *json::value) as f64;
	const fr_ech = *(json::get(&fr_end, "character") as *json::value) as f64;
	// `answer()` is called from line 2 at column 22 of "export fn ask() int = answer();".
	assert(fr_line == 2.0, "call site is on line 2");
	assert(fr_ch == 22.0, "call site starts at column 22");
	assert(fr_ech == 28.0, "call site ends at column 28 (after `answer`)");
};

@test fn e2e_call_hierarchy_outgoing_returns_array() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample =
		`export fn answer() int = 42;

export fn ask() int = answer();
`;
	open_doc(&s, "file:///cho.ha", sample);

	// Outgoing from `ask` -> should include `answer`.
	const req =
		`{"jsonrpc":"2.0","id":1602,"method":"callHierarchy/outgoingCalls","params":{"item":{"name":"ask","kind":12,"uri":"file:///cho.ha","range":{"start":{"line":2,"character":0},"end":{"line":2,"character":31}},"selectionRange":{"start":{"line":2,"character":10},"end":{"line":2,"character":13}}}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1602.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	// Find the `answer` callee. Outgoing calls may include other open
	// symbols, so we search for the one we expect rather than fixing
	// the count.
	let saw_answer = false;
	for (let i = 0z; i < len(arr); i += 1) {
		const call = arr[i] as json::object;
		const to = *(json::get(&call, "to") as *json::value) as json::object;
		const to_name = *(json::get(&to, "name") as *json::value) as str;
		if (to_name != "answer") continue;
		const to_uri = *(json::get(&to, "uri") as *json::value) as str;
		const to_kind = *(json::get(&to, "kind") as *json::value) as f64;
		assert(
			to_uri == "file:///cho.ha",
			"`answer` callee's uri must point at its defining file"
		);
		assert(
			to_kind == 12.0,
			"`answer` callee kind must be SymbolKind.Function (12)"
		);

		const from_ranges =
			*(json::get(&call, "fromRanges") as *json::value) as []json::value;
		assert(
			len(from_ranges) >= 1,
			"fromRanges must include the call site inside `ask`"
		);
		const fr0 = from_ranges[0] as json::object;
		const fr_start = *(json::get(&fr0, "start") as *json::value) as json::object;
		const fr_line = *(json::get(&fr_start, "line") as *json::value) as f64;
		const fr_ch = *(json::get(&fr_start, "character") as *json::value) as f64;
		assert(fr_line == 2.0, "outgoing call site is on line 2 of `ask`");
		assert(fr_ch == 22.0, "outgoing call site starts at column 22");
		saw_answer = true;
		break;
	};
	assert(
		saw_answer,
		"outgoingCalls must include the call to `answer` from `ask`"
	);
};
