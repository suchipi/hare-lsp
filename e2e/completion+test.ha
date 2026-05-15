// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// e2e: textDocument/completion and completionItem/resolve.

use encoding::json;
use os;
use strings;

@test fn e2e_completion_includes_local_decls() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample =
		`export fn my_function() int = 1;
export fn my_other() int = 2;

export fn main() void = {
	my
};
`;
	open_doc(&s, "file:///comp.ha", sample);

	// Cursor right after `my` on line 4, char 4.
	const req =
		`{"jsonrpc":"2.0","id":1800,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///comp.ha"},"position":{"line":4,"character":4}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1800.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = *(json::get(&obj, "result") as *json::value) as json::object;
	const inc = *(json::get(&result, "isIncomplete") as *json::value) as bool;
	assert(
		inc == false,
		"completion result must report isIncomplete=false (server is not truncating)"
	);
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	let saw_my_function = false, saw_my_other = false;
	for (let i = 0z; i < len(items); i += 1) {
		const it = items[i] as json::object;
		const label = *(json::get(&it, "label") as *json::value) as str;
		if (label != "my_function" && label != "my_other") continue;
		// Each local fn decl must carry enough metadata for the editor to
		// render it as a function: kind=Function(3), a non-empty detail,
		// and an insertText snippet beginning with the name.
		const kind = *(json::get(&it, "kind") as *json::value) as f64;
		assert(kind == 3.0, "local fn completion must have kind=Function(3)");
		const detail = *(json::get(&it, "detail") as *json::value) as str;
		assert(
			len(detail) > 0,
			"local fn completion must populate `detail` so the editor can show the signature"
		);
		const it_text = *(json::get(&it, "insertText") as *json::value) as str;
		assert(
			strings::hasprefix(it_text, label),
			"function snippet insertText should start with the function name"
		);
		const fmt_kind = *(json::get(&it, "insertTextFormat") as *json::value) as f64;
		assert(
			fmt_kind == 2.0,
			"function completion items must be Snippet (insertTextFormat=2)"
		);
		if (label == "my_function") saw_my_function = true;
		if (label == "my_other") saw_my_other = true;
	};
	assert(
		saw_my_function && saw_my_other,
		"completion should suggest both local fn decls"
	);
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

	const req =
		`{"jsonrpc":"2.0","id":1801,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///comp_kw.ha"},"position":{"line":1,"character":3}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1801.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = *(json::get(&obj, "result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	let saw_return = false;
	for (let i = 0z; i < len(items); i += 1) {
		const it = items[i] as json::object;
		const label = *(json::get(&it, "label") as *json::value) as str;
		if (label == "return") {
			saw_return = true;
			// Should be marked CompletionItemKind=Keyword(14) with
			// the `detail` label "keyword" so editors can render
			// the item distinctly from local symbols. Without the
			// detail check, a regression that emitted keywords as
			// plain text would still pass.
			const kind = *(json::get(&it, "kind") as *json::value) as f64;
			assert(kind == 14.0, "`return` completion item must have kind=Keyword");
			const detail = *(json::get(&it, "detail") as *json::value) as str;
			assert(
				detail == "keyword",
				"keyword completion items must set detail=\"keyword\""
			);
		};
	};
	assert(saw_return, "completion should include Hare keywords");
};

@test fn e2e_completion_qualified_by_module() void = {
	let s = spawn_session();
	defer finish_session(&s);

	// rootUri matters: workspace indexing scans this folder so qualified
	// completion can list module members.
	const root = os::getcwd();
	const init_msg =
		strings::concat(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":"file://`,
			root, `","workspaceFolders":[{"uri":"file://`, root,
			`","name":"hare-lsp"}],"capabilities":{}}}`)!;
	defer free(init_msg);
	send(&s, strings::toutf8(init_msg));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample = `use server;
export fn main() void = {
	let _ = server::
};
`;
	const did_open = build_did_open("file:///qual_comp.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Wait for indexing to settle so `server::*` symbols are populated.
	for (let i = 0z; i < 20z; i += 1) {
		const body = recv(&s);
		defer free(body);
		const text = strings::fromutf8(body)!;
		if (strings::contains(text, "indexed") &&
				strings::contains(text, "file(s)")) break;
	};

	// Cursor right after `server::` on line 2, character 17.
	const req =
		`{"jsonrpc":"2.0","id":1810,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///qual_comp.ha"},"position":{"line":2,"character":17}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1810.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = *(json::get(&obj, "result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;

	// Every returned item must belong to the `server` module — detail is
	// `<module>::<short>` for workspace entries.
	assert(
		len(items) > 0,
		"qualified completion after `server::` must return at least one member"
	);
	let saw_run = false;
	for (let i = 0z; i < len(items); i += 1) {
		const it = items[i] as json::object;
		const label = *(json::get(&it, "label") as *json::value) as str;
		// Keywords and unrelated top-level symbols must not leak in.
		assert(
			label != "let" && label != "return" && label != "if",
			"qualified completion must not include Hare keywords"
		);
		if (label == "run") saw_run = true;
	};
	assert(
		saw_run,
		"qualified completion after `server::` should include `run` from server/server.ha"
	);
};

@test fn e2e_completion_resolve_passthrough() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	// Resolve is largely a passthrough -- feed a synthetic item and
	// confirm we get a non-error response.
	const req =
		`{"jsonrpc":"2.0","id":1802,"method":"completionItem/resolve","params":{"label":"foo","kind":3}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1802.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	assert(
		json::get(&obj, "error") is void,
		"completionItem/resolve must not error on a well-formed item"
	);
	// Resolve is a passthrough today: the server should echo the input
	// item's `label` and `kind` so the editor's lazy-resolve flow keeps
	// working. A regression to `result: null` or `result: {}` (which
	// drops the popup contents) must fail this test.
	const result = *(json::get(&obj, "result") as *json::value) as json::object;
	const label = *(json::get(&result, "label") as *json::value) as str;
	assert(label == "foo", "completionItem/resolve must echo the input label");
	const kind = *(json::get(&result, "kind") as *json::value) as f64;
	assert(kind == 3.0, "completionItem/resolve must echo the input kind");
};
