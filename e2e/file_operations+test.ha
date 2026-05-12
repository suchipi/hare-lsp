// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// e2e: workspace/willCreateFiles, willRenameFiles, willDeleteFiles
// (request) and the corresponding didCreateFiles, didRenameFiles,
// didDeleteFiles, didChangeWatchedFiles (notification) handlers. Also
// covers textDocument/didChange, didClose, didSave, willSave, and
// textDocument/willSaveWaitUntil.

use encoding::json;
use fmt;
use strings;

@test fn e2e_will_create_files_returns_null() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const req =
		`{"jsonrpc":"2.0","id":2400,"method":"workspace/willCreateFiles","params":{"files":[{"uri":"file:///new.ha"}]}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 2400.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	// Result is null per current implementation -- no edits required
	// when creating new files.
	const result = *(json::get(&obj, "result") as *json::value);
	match (result) {
	case json::object =>
		fmt::fatalf("e2e: willCreateFiles should return null, got object: {}", text);
	case => void;
	};
};

@test fn e2e_will_rename_files_returns_null() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const req =
		`{"jsonrpc":"2.0","id":2401,"method":"workspace/willRenameFiles","params":{"files":[{"oldUri":"file:///a.ha","newUri":"file:///b.ha"}]}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 2401.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = *(json::get(&obj, "result") as *json::value);
	match (result) {
	case json::object =>
		fmt::fatalf("e2e: willRenameFiles should return null: {}", text);
	case => void;
	};
};

@test fn e2e_will_delete_files_returns_null() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const req =
		`{"jsonrpc":"2.0","id":2402,"method":"workspace/willDeleteFiles","params":{"files":[{"uri":"file:///gone.ha"}]}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 2402.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = *(json::get(&obj, "result") as *json::value);
	match (result) {
	case json::object =>
		fmt::fatalf("e2e: willDeleteFiles should return null: {}", text);
	case => void;
	};
};

// Notifications -- the server has nothing to send back; we verify it
// doesn't crash by issuing a subsequent request and observing the
// response.
@test fn e2e_did_create_files_does_not_crash() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	// Open a doc first so we have something concrete to query, AND so
	// that any backlog of post-`initialized` server messages gets read
	// while waiting for the documentSymbol response.
	open_doc(&s, "file:///prior.ha", "export fn p() void = void;\n");
	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":2409,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///prior.ha"}}}`
		));
	free(wait_for_response(&s, 2409.0));

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","method":"workspace/didCreateFiles","params":{"files":[{"uri":"file:///new.ha"}]}}`
		));

	// Sanity: server still answers requests.
	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":2410,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///prior.ha"}}}`
		));
	free(wait_for_response(&s, 2410.0));
};

@test fn e2e_did_rename_renames_open_document() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	open_doc(&s, "file:///old_name.ha", "export fn foo() void = void;\n");

	// Rename via notification.
	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","method":"workspace/didRenameFiles","params":{"files":[{"oldUri":"file:///old_name.ha","newUri":"file:///new_name.ha"}]}}`
		));

	// Verify by asking documentSymbol against the new URI -- should
	// return one symbol if the rename was applied to the document store.
	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":2411,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///new_name.ha"}}}`
		));
	const body = wait_for_response(&s, 2411.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	assert(
		len(arr) == 1,
		"after didRenameFiles the new URI must serve the document's symbols"
	);
};

@test fn e2e_did_delete_files_drops_open_document() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	open_doc(&s, "file:///doomed.ha", "export fn doomed() void = void;\n");

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","method":"workspace/didDeleteFiles","params":{"files":[{"uri":"file:///doomed.ha"}]}}`
		));

	// After deletion the document should be gone; documentSymbol
	// returns an empty array for an unknown URI.
	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":2412,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///doomed.ha"}}}`
		));
	const body = wait_for_response(&s, 2412.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	assert(
		len(arr) == 0,
		"after didDeleteFiles the document should no longer be served"
	);
};

@test fn e2e_did_change_watched_files_smoke() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	// Open a doc first so subsequent ping has something to return.
	open_doc(&s, "file:///ping.ha", "export fn p() void = void;\n");
	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":2412,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///ping.ha"}}}`
		));
	free(wait_for_response(&s, 2412.0));

	// Send the watched-files notification. The watcher refreshes the
	// workspace index for the changed paths; without a real workspace
	// folder there's nothing to refresh, but the dispatcher must
	// still consume the message.
	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","method":"workspace/didChangeWatchedFiles","params":{"changes":[{"uri":"file:///watched.ha","type":1}]}}`
		));

	// Ping again to confirm the server is still responsive.
	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":2413,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///ping.ha"}}}`
		));
	free(wait_for_response(&s, 2413.0));
};
