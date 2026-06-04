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
		const fmt_kind =
			*(json::get(&it, "insertTextFormat") as *json::value) as f64;
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
		if (strings::contains(text, "indexed")
				&& strings::contains(text, "file(s)")) break;
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

@test fn e2e_completion_qualified_by_stdlib_module() void = {
	let s = spawn_session();
	defer finish_session(&s);

	// rootUri matters: workspace indexing scans this folder. Even though
	// the `strings` module lives in stdlib (not the workspace), having a
	// workspace folder lets the LSP fully initialize. Stdlib indexing
	// happens lazily on the first `strings::` lookup.
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

	const sample =
		`use strings;
export fn main() void = {
	let _ = strings::
};
`;
	const did_open = build_did_open("file:///stdlib_qual.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Drain any pending workspace-indexed log lines so the next
	// wait_for_response doesn't trip over them.
	for (let i = 0z; i < 20z; i += 1) {
		const body = recv(&s);
		defer free(body);
		const text = strings::fromutf8(body)!;
		if (strings::contains(text, "indexed")
				&& strings::contains(text, "file(s)")) break;
	};

	// Cursor right after `strings::` on line 2, character 18.
	const req =
		`{"jsonrpc":"2.0","id":1811,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///stdlib_qual.ha"},"position":{"line":2,"character":18}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1811.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = *(json::get(&obj, "result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;

	// Without the stdlib lookup, the LSP returned an empty array and
	// VSCode fell back to word-based completion on the buffer (showing
	// "A", "Always", etc. from comments). Guard against that regression
	// by requiring at least one item AND a known stdlib symbol.
	assert(
		len(items) > 0,
		"qualified completion after `strings::` must return stdlib symbols"
	);
	let saw_concat = false;
	for (let i = 0z; i < len(items); i += 1) {
		const it = items[i] as json::object;
		const label = *(json::get(&it, "label") as *json::value) as str;
		// Keywords and unrelated symbols must not leak in.
		assert(
			label != "let" && label != "return" && label != "if",
			"qualified completion must not include Hare keywords"
		);
		if (label == "concat") saw_concat = true;
	};
	assert(
		saw_concat,
		"qualified completion after `strings::` should include `concat` from stdlib strings"
	);
};

@test fn e2e_completion_stdlib_auto_import_inserts_use_line() void = {
	let s = spawn_session();
	defer finish_session(&s);

	// rootUri is required so the server reaches READY and the
	// `initialized` handler enqueues both the workspace and stdlib
	// indexing jobs.
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

	// `bufio::newscanner` is a familiar stdlib name we can rely on.
	// The open doc deliberately omits `use bufio;` so the auto-import
	// path has work to do.
	const sample = `export fn main() void = {
	let _ = newsca
};
`;
	const did_open = build_did_open("file:///stdlib_autoimport.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Wait for the stdlib indexing job to finish — without it,
	// `add_stdlib_symbols` would skip `newscanner` since its entry
	// wouldn't be in `s.stdlib_index` yet.
	for (let i = 0z; i < 200z; i += 1) {
		const body = recv(&s);
		defer free(body);
		const text = strings::fromutf8(body)!;
		if (strings::contains(text, "indexed stdlib")
				&& strings::contains(text, "file(s)")) break;
	};

	// Cursor sits right after "newsca" on line 1, character 15.
	const req =
		`{"jsonrpc":"2.0","id":1820,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///stdlib_autoimport.ha"},"position":{"line":1,"character":15}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1820.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = *(json::get(&obj, "result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;

	let found = false;
	for (let i = 0z; i < len(items); i += 1) {
		const it = items[i] as json::object;
		const label = *(json::get(&it, "label") as *json::value) as str;
		if (label != "newscanner") continue;
		found = true;
		const edits = match (json::get(&it, "additionalTextEdits")) {
		case let p: *json::value =>
			yield *p as []json::value;
		case => abort(
			"stdlib auto-import: newscanner item must carry additionalTextEdits"
		);
		};
		assert(
			len(edits) >= 1,
			"stdlib auto-import: edits array must be non-empty"
		);
		const e0 = edits[0] as json::object;
		const new_text = *(json::get(&e0, "newText") as *json::value) as str;
		assert(
			strings::contains(new_text, "use bufio;"),
			"stdlib auto-import: edit must insert `use bufio;`"
		);
		// The accepted text itself must be the module-qualified call:
		// `use bufio;` alone doesn't bring `newscanner` into scope
		// unqualified, so a bare `newscanner(...)` would not resolve.
		const it_text = *(json::get(&it, "insertText") as *json::value) as str;
		assert(
			strings::hasprefix(it_text, "bufio::newscanner("),
			"stdlib auto-import: accepted text must be the qualified call `bufio::newscanner(...)`"
		);
		break;
	};
	assert(
		found,
		"completion after partial `newsca` must offer `newscanner` from stdlib bufio"
	);
};

@test fn e2e_completion_third_party_auto_import_inserts_use_line() void = {
	let s = spawn_session();
	defer finish_session(&s);

	// Same setup as the stdlib test — `ensure_full_stdlib_indexed`
	// walks every stdlib_search_paths root, which includes the
	// third-party tree, so `encoding::json` ends up in s.stdlib_index
	// alongside the stdlib modules.
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

	// `encoding::json::newobject` is unambiguously third-party on
	// the standard upstream install. Doc deliberately omits the use
	// line so auto-import has work to do.
	const sample = `export fn main() void = {
	let _ = newobje
};
`;
	const did_open = build_did_open("file:///third_party_autoimport.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	for (let i = 0z; i < 200z; i += 1) {
		const body = recv(&s);
		defer free(body);
		const text = strings::fromutf8(body)!;
		if (strings::contains(text, "indexed stdlib")
				&& strings::contains(text, "file(s)")) break;
	};

	// Cursor sits right after "newobje" on line 1, character 16.
	const req =
		`{"jsonrpc":"2.0","id":1821,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///third_party_autoimport.ha"},"position":{"line":1,"character":16}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1821.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = *(json::get(&obj, "result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;

	let found = false;
	for (let i = 0z; i < len(items); i += 1) {
		const it = items[i] as json::object;
		const label = *(json::get(&it, "label") as *json::value) as str;
		if (label != "newobject") continue;
		found = true;
		const edits = match (json::get(&it, "additionalTextEdits")) {
		case let p: *json::value =>
			yield *p as []json::value;
		case => abort(
			"third-party auto-import: newobject item must carry additionalTextEdits"
		);
		};
		assert(len(edits) >= 1);
		const e0 = edits[0] as json::object;
		const new_text = *(json::get(&e0, "newText") as *json::value) as str;
		assert(
			strings::contains(new_text, "use encoding::json;"),
			"third-party auto-import: edit must insert `use encoding::json;`"
		);
		// Accepted text is qualified by the module leaf `json`, not the
		// full `encoding::json::` path Hare uses in the `use` line.
		const it_text = *(json::get(&it, "insertText") as *json::value) as str;
		assert(
			strings::hasprefix(it_text, "json::newobject("),
			"third-party auto-import: accepted text must be the leaf-qualified call `json::newobject(...)`"
		);
		break;
	};
	assert(
		found,
		"completion after partial `newobje` must offer `newobject` from third-party encoding::json"
	);
};

@test fn e2e_completion_module_name_auto_import() void = {
	let s = spawn_session();
	defer finish_session(&s);

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

	// Type just `json` — expect a MODULE-kind suggestion that inserts
	// `use encoding::json;` (third-party on the standard install).
	const sample = `export fn main() void = {
	json
};
`;
	const did_open = build_did_open("file:///module_name.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	for (let i = 0z; i < 200z; i += 1) {
		const body = recv(&s);
		defer free(body);
		const text = strings::fromutf8(body)!;
		if (strings::contains(text, "indexed stdlib")
				&& strings::contains(text, "file(s)")) break;
	};

	// Cursor sits right after "json" on line 1, character 5.
	const req =
		`{"jsonrpc":"2.0","id":1830,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///module_name.ha"},"position":{"line":1,"character":5}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1830.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = *(json::get(&obj, "result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;

	let found = false;
	for (let i = 0z; i < len(items); i += 1) {
		const it = items[i] as json::object;
		const label = *(json::get(&it, "label") as *json::value) as str;
		if (label != "json") continue;
		const kind = *(json::get(&it, "kind") as *json::value) as f64;
		if (kind != 9.0) continue;
		found = true;
		const detail = *(json::get(&it, "detail") as *json::value) as str;
		assert(
			detail == "encoding::json",
			"module-name completion detail must be the qualified module path"
		);
		const edits = match (json::get(&it, "additionalTextEdits")) {
		case let p: *json::value =>
			yield *p as []json::value;
		case => abort(
			"module-name completion: `json` item must carry an auto-import edit"
		);
		};
		assert(len(edits) >= 1);
		const e0 = edits[0] as json::object;
		const new_text = *(json::get(&e0, "newText") as *json::value) as str;
		assert(strings::contains(new_text, "use encoding::json;"));
		break;
	};
	assert(
		found,
		"completion after typing `json` must offer the module itself as a MODULE item"
	);
};

@test fn e2e_completion_value_position_suggests_local_binding() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	// A `let counter = 0;` binding should be offered when the user starts
	// typing `cou` on a later line — the value-position case the feature
	// targets, exercised end-to-end over the wire.
	const sample = `export fn main() void = {
	let counter = 0;
	cou
};
`;
	open_doc(&s, "file:///vpos_e2e.ha", sample);

	// Line 2 = `\tcou`; char 4 sits right after `cou` (tab=0, then `cou`).
	const req =
		`{"jsonrpc":"2.0","id":1860,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///vpos_e2e.ha"},"position":{"line":2,"character":4}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1860.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = *(json::get(&obj, "result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	let saw_counter = false;
	for (let i = 0z; i < len(items); i += 1) {
		const it = items[i] as json::object;
		const label = *(json::get(&it, "label") as *json::value) as str;
		if (label != "counter") continue;
		saw_counter = true;
		// The local must present as a Variable so editors render it
		// distinctly from keywords / functions.
		const kind = *(json::get(&it, "kind") as *json::value) as f64;
		assert(kind == 6.0, "local binding completion must be Variable(6)");
	};
	assert(
		saw_counter,
		"value-position completion must offer the in-scope local `counter`"
	);
};

@test fn e2e_completion_type_position_suggests_builtin_type() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	// Typing a type annotation `let x: s` (no initializer yet — the
	// realistic mid-typing state) must offer the builtin type `str` while
	// suppressing non-type keywords like `static`.
	const sample = `export fn main() void = {
	let x: s
};
`;
	open_doc(&s, "file:///tpos_e2e.ha", sample);

	// Line 1 = `\tlet x: s`; char 9 sits right after `s`
	// (tab=0, `let x: s` = 8 chars).
	const req =
		`{"jsonrpc":"2.0","id":1861,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///tpos_e2e.ha"},"position":{"line":1,"character":9}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1861.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = *(json::get(&obj, "result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	let saw_str = false, saw_static = false;
	for (let i = 0z; i < len(items); i += 1) {
		const it = items[i] as json::object;
		const label = *(json::get(&it, "label") as *json::value) as str;
		if (label == "str") saw_str = true;
		if (label == "static") saw_static = true;
	};
	assert(saw_str, "type-position completion must offer the builtin type `str`");
	assert(
		!saw_static,
		"type position must exclude the non-type keyword `static`"
	);
};

@test fn e2e_completion_member_access_returns_struct_fields() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample =
		`type buffer = struct { data: []u8, line_index: []size };
export fn main(b: buffer) void = {
	b.
};
`;
	open_doc(&s, "file:///comp_mem.ha", sample);

	// Line 2 = "\tb."; column 3 sits right after the dot.
	const req =
		`{"jsonrpc":"2.0","id":1803,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///comp_mem.ha"},"position":{"line":2,"character":3}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1803.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = *(json::get(&obj, "result") as *json::value) as json::object;
	const items = *(json::get(&result, "items") as *json::value) as []json::value;
	let saw_data = false, saw_line_index = false, saw_keyword = false;
	for (let i = 0z; i < len(items); i += 1) {
		const it = items[i] as json::object;
		const label = *(json::get(&it, "label") as *json::value) as str;
		if (label == "data") {
			saw_data = true;
			// Member completion items must carry kind=Field(5) so
			// editors can render them distinctly from locals/keywords.
			const kind = *(json::get(&it, "kind") as *json::value) as f64;
			assert(
				kind == 5.0,
				"struct field completion item must have kind=Field(5)"
			);
		};
		if (label == "line_index") saw_line_index = true;
		// MEMBER completion is exclusive - keywords/locals must NOT leak in.
		match (json::get(&it, "detail")) {
		case let p: *json::value =>
			match (*p) {
			case let d: str =>
				if (d == "keyword") saw_keyword = true;
			case => void;
			};
		case void => void;
		};
	};
	assert(
		saw_data && saw_line_index,
		"member completion must enumerate the struct's fields over the wire"
	);
	assert(
		!saw_keyword,
		"member completion is exclusive and must not include keyword items"
	);
};

@test fn e2e_completion_resolve_passthrough() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	// Synthetic CompletionItem with no `data` field: the resolve
	// handler can't look anything up, so it must echo the input
	// verbatim. Without this echo behavior, editors that don't drive
	// the lazy-resolve flow would lose their popup contents.
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
	const result = *(json::get(&obj, "result") as *json::value) as json::object;
	const label = *(json::get(&result, "label") as *json::value) as str;
	assert(label == "foo", "completionItem/resolve must echo the input label");
	const kind = *(json::get(&result, "kind") as *json::value) as f64;
	assert(kind == 3.0, "completionItem/resolve must echo the input kind");
};

// Exercises the resolve enrichment over the wire: open a real file
// with a documented function, request completion, grab the `data`
// field the server stashed on the matching item, then send a
// completionItem/resolve carrying that data and assert the response
// carries a populated `detail` and a markdown `documentation`. This
// is the regression guard the plan calls out at
// .tmp/audit-followups/02-completionitem-resolve.md — without the
// e2e check, a regression in the resolve dispatch path could land
// without a unit test catching it. Uses a multi-character identifier
// (Hare's lexer disallows non-ASCII identifier runes).
@test fn e2e_completion_resolve_populates_detail_and_documentation() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample =
		`// Returns an empty label for the widget.
export fn frobnicate_widget(arg: int) str = "";

export fn main() void = {
	frob
};
`;
	open_doc(&s, "file:///res_e2e.ha", sample);

	// Step 1: trigger the initial completion. Cursor sits right after
	// `frob` on line 4, character 5 (\t = char 0, then `f`,`r`,`o`,`b`).
	const req =
		`{"jsonrpc":"2.0","id":1850,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///res_e2e.ha"},"position":{"line":4,"character":5}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1850.0);
	defer free(body);
	let v = json::loadstr(strings::fromutf8(body)!)!;
	defer json::finish(v);
	const result_obj =
		*(json::get(&(v as json::object),
			"result") as *json::value) as json::object;
	const items =
		*(json::get(&result_obj, "items") as *json::value) as []json::value;

	let data_text: str = "";
	let owned_data = false;
	defer if (owned_data) free(data_text);
	for (let i = 0z; i < len(items); i += 1) {
		const it = items[i] as json::object;
		const lbl = *(json::get(&it, "label") as *json::value) as str;
		if (lbl != "frobnicate_widget") continue;
		const dp = json::get(&it, "data") as *json::value;
		data_text = json::dumpstr(*dp);
		owned_data = true;
		break;
	};
	assert(
		owned_data,
		"initial completion must attach `data` to the frobnicate_widget item"
	);

	// Step 2: re-serialize the data into a resolve request and dispatch.
	const resolve_req =
		strings::concat(
			`{"jsonrpc":"2.0","id":1851,"method":"completionItem/resolve","params":{"label":"frobnicate_widget","kind":3,"data":`,
			data_text, `}}`)!;
	defer free(resolve_req);
	send(&s, strings::toutf8(resolve_req));

	const body2 = wait_for_response(&s, 1851.0);
	defer free(body2);
	let v2 = json::loadstr(strings::fromutf8(body2)!)!;
	defer json::finish(v2);
	const r2 = v2 as json::object;
	assert(
		json::get(&r2, "error") is void,
		"completionItem/resolve must not error on a well-formed item"
	);
	const enriched = *(json::get(&r2, "result") as *json::value) as json::object;

	// detail must now carry the rendered signature, not the raw label.
	const detail = *(json::get(&enriched, "detail") as *json::value) as str;
	assert(
		strings::contains(detail, "frobnicate_widget"),
		"resolved detail must include the symbol name"
	);
	assert(
		strings::contains(detail, "fn"),
		"resolved detail must show the function signature"
	);

	// documentation must be MarkupContent(kind=markdown) with the
	// cleaned doc-comment body.
	const doc_obj =
		*(json::get(&enriched, "documentation") as *json::value) as json::object;
	const dkind = *(json::get(&doc_obj, "kind") as *json::value) as str;
	assert(dkind == "markdown", "documentation must be markdown");
	const dvalue = *(json::get(&doc_obj, "value") as *json::value) as str;
	assert(
		strings::contains(dvalue, "Returns an empty label for the widget"),
		"documentation must include the doc-comment text"
	);
};
