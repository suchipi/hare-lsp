// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// e2e: text document sync notifications and willSaveWaitUntil.
//
//   - textDocument/didChange (incremental + full)
//   - textDocument/didClose
//   - textDocument/didSave
//   - textDocument/willSave
//   - textDocument/willSaveWaitUntil

use encoding::json;
use strings;

@test fn e2e_did_change_full_replaces_document() void = {
	// Pinned to spawn_session_with_logs so the log-dir codepath is
	// exercised on every test run. See e2e/README.md.
	let s = spawn_session_with_logs("logs-did-change");
	defer finish_session(&s);
	do_init(&s);

	open_doc(&s, "file:///dc.ha", "export fn original() void = void;\n");

	// Full-document content change (no `range` field -> full sync).
	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///dc.ha","version":2},"contentChanges":[{"text":"export fn replaced() void = void;\n"}]}}`
		));

	// Confirm by asking documentSymbol -- the new name should appear.
	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":2500,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///dc.ha"}}}`
		));
	const body = wait_for_response(&s, 2500.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	assert(len(arr) == 1, "after full didChange the doc should have one symbol");
	const sym = arr[0] as json::object;
	const name = *(json::get(&sym, "name") as *json::value) as str;
	assert(
		name == "replaced",
		"the new symbol name must reflect the didChange payload"
	);
};

@test fn e2e_did_change_incremental_replaces_range() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	open_doc(&s, "file:///dci.ha", "export fn a_name() void = void;\n");

	// Replace `a_name` (chars 10..16 on line 0) with `b_name`.
	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///dci.ha","version":2},"contentChanges":[{"range":{"start":{"line":0,"character":10},"end":{"line":0,"character":16}},"text":"b_name"}]}}`
		));

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":2501,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///dci.ha"}}}`
		));
	const body = wait_for_response(&s, 2501.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	const sym = arr[0] as json::object;
	const name = *(json::get(&sym, "name") as *json::value) as str;
	assert(name == "b_name", "incremental didChange must apply the replacement");
};

@test fn e2e_did_close_drops_document() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	open_doc(&s, "file:///close.ha", "export fn keep() void = void;\n");

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///close.ha"}}}`
		));

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":2502,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///close.ha"}}}`
		));
	const body = wait_for_response(&s, 2502.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	assert(len(arr) == 0, "after didClose the doc should no longer be served");
};

@test fn e2e_did_save_triggers_publish_diagnostics() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	open_doc(&s, "file:///save.ha", "export fn s() void = void;\n");
	// Drain the didOpen-driven publishDiagnostics so the next wait
	// observes the publish that didSave itself triggers, not the
	// stale didOpen one.
	free(wait_for_publish_diagnostics(&s, "file:///save.ha"));

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","method":"textDocument/didSave","params":{"textDocument":{"uri":"file:///save.ha"}}}`
		));

	// A successful didSave handler republishes diagnostics for the
	// saved URI. If the notification were silently dropped, this
	// wait would time out.
	free(wait_for_publish_diagnostics(&s, "file:///save.ha"));
};

// willSave is a notification the client sends before saving. The server's
// handler is intentionally a no-op (see server/documents.ha:handle_will_save);
// there's no response and no observable wire effect. This test asserts only
// that accepting the notification doesn't put the server into a bad state,
// by round-tripping a follow-up request afterwards.
@test fn e2e_will_save_is_accepted_as_noop() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	open_doc(&s, "file:///ws.ha", "export fn w() void = void;\n");

	// reason: 1 = Manual.
	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","method":"textDocument/willSave","params":{"textDocument":{"uri":"file:///ws.ha"},"reason":1}}`
		));

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":2504,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///ws.ha"}}}`
		));
	free(wait_for_response(&s, 2504.0));
};

@test fn e2e_will_save_wait_until_returns_text_edits() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	// Trailing whitespace + no final newline -> handler emits trim+EOL fixups.
	open_doc(&s, "file:///wsw.ha", "export fn x() void = void;   ");

	const req =
		`{"jsonrpc":"2.0","id":2505,"method":"textDocument/willSaveWaitUntil","params":{"textDocument":{"uri":"file:///wsw.ha"},"reason":1}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 2505.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	// The fixture has trailing whitespace and no final newline; with
	// default config (trim_final_newlines + insert_final_newline both
	// true) the handler must return at least one TextEdit. Accepting
	// just a present-but-empty result here would silently regress the
	// auto-fix-on-save integration in editors.
	const edits = *(json::get(&obj, "result") as *json::value) as []json::value;
	assert(
		len(edits) >= 1,
		"willSaveWaitUntil on a file with trailing whitespace must return at least one edit"
	);
	let saw_trim_or_newline = false;
	for (let i = 0z; i < len(edits); i += 1) {
		const e = edits[i] as json::object;
		const new_text = *(json::get(&e, "newText") as *json::value) as str;
		// A trim edit replaces the trailing whitespace with "" or
		// with "\n" (when insert_final_newline is also on); a
		// pure final-newline append uses "\n".
		if (new_text == "" || strings::contains(new_text, "\n")) {
			saw_trim_or_newline = true;
			break;
		};
	};
	assert(
		saw_trim_or_newline,
		"willSaveWaitUntil edits must include a trim (newText=\"\") or a final-newline append (newText contains \"\\n\")"
	);
};
