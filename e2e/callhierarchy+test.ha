// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// e2e: call hierarchy. The three methods compose:
//   prepareCallHierarchy -> CallHierarchyItem
//   callHierarchy/incomingCalls -> CallHierarchyIncomingCall[]
//   callHierarchy/outgoingCalls -> CallHierarchyOutgoingCall[]

use encoding::json;
use fmt;
use strings;

@test fn e2e_prepare_call_hierarchy_returns_item_for_fn() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `export fn answer() int = 42;

export fn ask() int = answer();
`;
	open_doc(&s, "file:///ch.ha", sample);

	// Cursor on `answer` in the decl (line 0, char 12).
	const req = `{"jsonrpc":"2.0","id":1600,"method":"textDocument/prepareCallHierarchy","params":{"textDocument":{"uri":"file:///ch.ha"},"position":{"line":0,"character":12}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1600.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value)
		as []json::value;
	assert(len(arr) == 1,
		"prepareCallHierarchy should return one item for a fn decl");
	const item = arr[0] as json::object;
	const name = *(json::get(&item, "name") as *json::value) as str;
	assert(name == "answer",
		"item name should match the function under the cursor");
	assert(json::get(&item, "range") is *json::value,
		"call hierarchy item must include a range");
	assert(json::get(&item, "selectionRange") is *json::value,
		"call hierarchy item must include a selectionRange");
};

@test fn e2e_call_hierarchy_incoming_returns_array() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `export fn answer() int = 42;

export fn ask() int = answer();
`;
	open_doc(&s, "file:///chi.ha", sample);

	// Feed a CallHierarchyItem we know corresponds to `answer`.
	const req = `{"jsonrpc":"2.0","id":1601,"method":"callHierarchy/incomingCalls","params":{"item":{"name":"answer","kind":12,"uri":"file:///chi.ha","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":28}},"selectionRange":{"start":{"line":0,"character":10},"end":{"line":0,"character":16}}}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1601.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value)
		as []json::value;
	// The call from `ask` to `answer` should appear.
	assert(len(arr) >= 1,
		"incomingCalls should find at least one caller of `answer`");
};

@test fn e2e_call_hierarchy_outgoing_returns_array() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `export fn answer() int = 42;

export fn ask() int = answer();
`;
	open_doc(&s, "file:///cho.ha", sample);

	// Outgoing from `ask` -> should include `answer`.
	const req = `{"jsonrpc":"2.0","id":1602,"method":"callHierarchy/outgoingCalls","params":{"item":{"name":"ask","kind":12,"uri":"file:///cho.ha","range":{"start":{"line":2,"character":0},"end":{"line":2,"character":31}},"selectionRange":{"start":{"line":2,"character":10},"end":{"line":2,"character":13}}}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1602.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value)
		as []json::value;
	assert(len(arr) >= 1,
		"outgoingCalls should include the call to `answer`");
};
