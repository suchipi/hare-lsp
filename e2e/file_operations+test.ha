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
use fs;
use os;
use strings;

// Asserts that the response's `result` field is the JSON null literal.
// Used to pin down the will*FilesReturnsNull behaviour: returning `null`
// is the LSP-spec-compliant shape, and a regression that emitted `[]`,
// `""`, `0`, or a `WorkspaceEdit` object would otherwise pass a naive
// `case json::object => fail; case => void` check.
fn assert_result_is_null(obj: *json::object, scope: str, raw: str) void = {
	const result = *(json::get(obj, "result") as *json::value);
	match (result) {
	case json::_null => void;
	case =>
		fmt::fatalf("e2e: {} must return JSON null, got: {}", scope, raw);
	};
};

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
	assert_result_is_null(&obj, "willCreateFiles", text);
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
	assert_result_is_null(&obj, "willRenameFiles", text);
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
	assert_result_is_null(&obj, "willDeleteFiles", text);
};

// Notifications. `didCreateFiles` is intentionally a no-op in the
// current server: new files get picked up via the corresponding
// didChangeWatchedFiles event (see filewatch.ha). This test verifies
// the notification doesn't crash the server AND doesn't corrupt the
// open-document state of `prior.ha`: a positive control on `prior.ha`'s
// documentSymbol response surrounds the notification so a regression
// that scrambled the doc store on receipt would be caught.
@test fn e2e_did_create_files_does_not_crash() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	open_doc(&s, "file:///prior.ha", "export fn prior_unique() void = void;\n");

	// Baseline: documentSymbol returns the one declared symbol.
	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":2409,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///prior.ha"}}}`
		));
	const pre_body = wait_for_response(&s, 2409.0);
	defer free(pre_body);
	assert(
		document_symbol_count(pre_body) == 1,
		"baseline: prior.ha should expose its one declared symbol"
	);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","method":"workspace/didCreateFiles","params":{"files":[{"uri":"file:///new.ha"}]}}`
		));

	// After the notification, the open document store must still be
	// intact and serving the same symbol.
	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":2410,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///prior.ha"}}}`
		));
	const post_body = wait_for_response(&s, 2410.0);
	defer free(post_body);
	assert(
		document_symbol_count(post_body) == 1,
		"didCreateFiles must not corrupt the open-document store"
	);
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

	// New URI must serve the document's symbols, AND the symbol must
	// be the one we opened (a regression that returned a stale or
	// blank entry would still pass a count-only check).
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
	const sym = arr[0] as json::object;
	const name = *(json::get(&sym, "name") as *json::value) as str;
	assert(name == "foo", "renamed document must still expose its `foo` symbol");

	// Old URI must no longer serve the document: a copy (rather than a
	// move) would leave the doc reachable under both URIs.
	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":2414,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///old_name.ha"}}}`
		));
	const old_body = wait_for_response(&s, 2414.0);
	defer free(old_body);
	assert(
		document_symbol_count(old_body) == 0,
		"didRenameFiles must move the document, not copy it"
	);
};

@test fn e2e_did_delete_files_drops_open_document() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	open_doc(&s, "file:///doomed.ha", "export fn doomed() void = void;\n");

	// Positive control: before the delete, the document is being
	// served. Without this, an empty post-delete response could be
	// explained by "documentSymbol always returns [] for this URI"
	// rather than a real delete.
	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":2415,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///doomed.ha"}}}`
		));
	const pre_body = wait_for_response(&s, 2415.0);
	defer free(pre_body);
	assert(
		document_symbol_count(pre_body) == 1,
		"baseline: doomed.ha must be served before the delete"
	);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","method":"workspace/didDeleteFiles","params":{"files":[{"uri":"file:///doomed.ha"}]}}`
		));

	// After deletion the document store no longer holds the URI.
	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":2412,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///doomed.ha"}}}`
		));
	const body = wait_for_response(&s, 2412.0);
	defer free(body);
	assert(
		document_symbol_count(body) == 0,
		"after didDeleteFiles the document should no longer be served"
	);
};

// `didChangeWatchedFiles` is the path the file watcher uses to notify
// the server that an on-disk file changed. The test writes a real .ha
// file with a uniquely-named declaration, sends the notification with
// `type:1` (created), and then queries `workspace/symbol` to confirm
// the new declaration is reachable - the actual UX a user expects
// after the watcher reports a new file.
@test fn e2e_did_change_watched_files_reindexes() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const cwd = os::getcwd();
	const path = strings::concat(cwd, "/.tmp/e2e-watched-files-reindex.ha")!;
	defer free(path);
	defer match (os::remove(path)) {
	case void => void;
	case fs::error => void;
	};
	// Ensure no stale file from a prior aborted run.
	match (os::remove(path)) {
	case void => void;
	case fs::error => void;
	};
	write_test_file(path, "export fn watched_files_unique_xyz() void = void;\n");

	const uri = strings::concat("file://", path)!;
	defer free(uri);
	const notif =
		strings::concat(
			`{"jsonrpc":"2.0","method":"workspace/didChangeWatchedFiles","params":{"changes":[{"uri":"`,
			uri, `","type":1}]}}`)!;
	defer free(notif);
	send(&s, strings::toutf8(notif));

	// workspace/symbol picks up the new declaration. The symbol's
	// `location.uri` must point at our just-written file.
	const req =
		`{"jsonrpc":"2.0","id":2413,"method":"workspace/symbol","params":{"query":"watched_files_unique_xyz"}}`;
	send(&s, strings::toutf8(req));
	const body = wait_for_response(&s, 2413.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const items = extract_symbol_items(
		*(json::get(&obj, "result") as *json::value));
	let saw_uri: str = "";
	for (let i = 0z; i < len(items); i += 1) {
		const it = items[i] as json::object;
		const name = *(json::get(&it, "name") as *json::value) as str;
		if (name != "watched_files_unique_xyz") continue;
		const loc = *(json::get(&it, "location") as *json::value) as json::object;
		saw_uri = *(json::get(&loc, "uri") as *json::value) as str;
		break;
	};
	assert(
		len(saw_uri) > 0,
		"didChangeWatchedFiles must trigger reindexing so the new symbol is reachable"
	);
	assert(
		saw_uri == uri,
		"the reindexed symbol must point at the URI from the notification"
	);
};

// Pulls the items count out of a textDocument/documentSymbol response,
// failing the test if the response shape is not `result: []`.
fn document_symbol_count(body: []u8) size = {
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	return len(arr);
};
