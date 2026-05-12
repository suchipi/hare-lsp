// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// e2e: type hierarchy. prepareTypeHierarchy + supertypes + subtypes.

use encoding::json;
use fmt;
use strings;

@test fn e2e_prepare_type_hierarchy_returns_item_for_type() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `type my_int = int;
`;
	open_doc(&s, "file:///th.ha", sample);

	// Cursor on `my_int` (line 0, char 7).
	const req = `{"jsonrpc":"2.0","id":1700,"method":"textDocument/prepareTypeHierarchy","params":{"textDocument":{"uri":"file:///th.ha"},"position":{"line":0,"character":7}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1700.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value)
		as []json::value;
	assert(len(arr) == 1,
		"prepareTypeHierarchy should return one item for a type decl");
	const item = arr[0] as json::object;
	const name = *(json::get(&item, "name") as *json::value) as str;
	assert(name == "my_int",
		"item name should match the type under the cursor");
};

@test fn e2e_type_hierarchy_supertypes_returns_array() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `type my_int = int;
`;
	open_doc(&s, "file:///ths.ha", sample);

	const req = `{"jsonrpc":"2.0","id":1701,"method":"typeHierarchy/supertypes","params":{"item":{"name":"my_int","kind":23,"uri":"file:///ths.ha","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":17}},"selectionRange":{"start":{"line":0,"character":5},"end":{"line":0,"character":11}}}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1701.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	// Result must be an array (possibly empty if workspace index isn't
	// populated for the open doc -- that's a known limitation).
	assert(*(json::get(&obj, "result") as *json::value)
		is []json::value,
		"supertypes must return an array");
};

@test fn e2e_type_hierarchy_subtypes_returns_array() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `type my_int = int;
`;
	open_doc(&s, "file:///thsub.ha", sample);

	const req = `{"jsonrpc":"2.0","id":1702,"method":"typeHierarchy/subtypes","params":{"item":{"name":"int","kind":23,"uri":"file:///thsub.ha","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":17}},"selectionRange":{"start":{"line":0,"character":14},"end":{"line":0,"character":17}}}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1702.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	assert(*(json::get(&obj, "result") as *json::value)
		is []json::value,
		"subtypes must return an array");
};
