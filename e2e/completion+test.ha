// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// e2e: textDocument/completion and completionItem/resolve.

use encoding::json;
use fmt;
use strings;

@test fn e2e_completion_includes_local_decls() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `export fn my_function() int = 1;
export fn my_other() int = 2;

export fn main() void = {
	my
};
`;
	open_doc(&s, "file:///comp.ha", sample);

	// Cursor right after `my` on line 4, char 4.
	const req = `{"jsonrpc":"2.0","id":1800,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///comp.ha"},"position":{"line":4,"character":4}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1800.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = (*(json::get(&obj, "result") as *json::value))
		as json::object;
	assert(json::get(&result, "isIncomplete") is *json::value,
		"completion result must include isIncomplete");
	const items = *(json::get(&result, "items") as *json::value)
		as []json::value;
	let saw_my_function = false, saw_my_other = false;
	for (let i = 0z; i < len(items); i += 1) {
		const it = items[i] as json::object;
		const label = *(json::get(&it, "label") as *json::value) as str;
		if (label == "my_function") saw_my_function = true;
		if (label == "my_other") saw_my_other = true;
	};
	assert(saw_my_function && saw_my_other,
		"completion should suggest both local fn decls");
};

@test fn e2e_completion_includes_keywords() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `export fn main() void = {
	r
};
`;
	open_doc(&s, "file:///comp_kw.ha", sample);

	const req = `{"jsonrpc":"2.0","id":1801,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///comp_kw.ha"},"position":{"line":1,"character":3}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1801.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = (*(json::get(&obj, "result") as *json::value))
		as json::object;
	const items = *(json::get(&result, "items") as *json::value)
		as []json::value;
	let saw_return = false;
	for (let i = 0z; i < len(items); i += 1) {
		const it = items[i] as json::object;
		const label = *(json::get(&it, "label") as *json::value) as str;
		if (label == "return") {
			saw_return = true;
			// Should be marked CompletionItemKind=Keyword(14).
			const kind = *(json::get(&it, "kind") as *json::value) as f64;
			assert(kind == 14.0,
				"`return` completion item must have kind=Keyword");
		};
	};
	assert(saw_return, "completion should include Hare keywords");
};

@test fn e2e_completion_resolve_passthrough() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	// Resolve is largely a passthrough -- feed a synthetic item and
	// confirm we get a non-error response.
	const req = `{"jsonrpc":"2.0","id":1802,"method":"completionItem/resolve","params":{"label":"foo","kind":3}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1802.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	assert(json::get(&obj, "error") is void,
		"completionItem/resolve must not error on a well-formed item");
	assert(json::get(&obj, "result") is *json::value,
		"completionItem/resolve must include a result");
};
