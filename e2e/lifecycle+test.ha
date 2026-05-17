// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// e2e: lifecycle/misc notifications and pre-init request gating.
//
//   - $/cancelRequest
//   - $/setTrace
//   - window/workDoneProgress/cancel
//   - workspace/didChangeConfiguration
//   - workspace/didChangeWorkspaceFolders
//   - request received before `initialize` -> SERVER_NOT_INITIALIZED

use encoding::json;
use strings;

@test fn e2e_pre_init_request_returns_server_not_initialized() void = {
	let s = spawn_session();
	defer finish_session(&s);

	// Skip do_init(): send a non-initialize request first.
	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":2600,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///x.ha"},"position":{"line":0,"character":0}}}`
		));

	const body = wait_for_response(&s, 2600.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const err = *(json::get(&obj, "error") as *json::value) as json::object;
	const code = *(json::get(&err, "code") as *json::value) as f64;
	// SERVER_NOT_INITIALIZED = -32002.
	assert(code == -32002.0, "pre-init request must yield SERVER_NOT_INITIALIZED");
};

// Sends one of the misc-notification methods and confirms the server
// stays responsive afterwards by round-tripping a documentSymbol
// request. Each test uses a unique probe URI so they don't share
// state. We do an initial ping before the notification so any
// post-`initialized` backlog has been drained from the pipe first.
fn smoke_notification(notif: str, probe_uri: str, ping_id: f64) void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	open_doc(&s, probe_uri, "export fn p() void = void;\n");
	const ping =
		strings::concat(`{"jsonrpc":"2.0","id":`, f64_to_int_str(ping_id),
			`,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"`,
			probe_uri, `"}}}`)!;
	defer free(ping);
	send(&s, strings::toutf8(ping));
	free(wait_for_response(&s, ping_id));

	send(&s, strings::toutf8(notif));

	const ping2_id = ping_id + 1.0;
	const ping2 =
		strings::concat(`{"jsonrpc":"2.0","id":`, f64_to_int_str(ping2_id),
			`,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"`,
			probe_uri, `"}}}`)!;
	defer free(ping2);
	send(&s, strings::toutf8(ping2));
	free(wait_for_response(&s, ping2_id));
};

// $/cancelRequest with an id that doesn't match any in-flight request
// is a no-op per LSP spec. The only observable behavior is that the
// server keeps responding to subsequent requests.
@test fn e2e_cancel_request_for_unknown_id_is_noop() void = {
	smoke_notification(
		`{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":9999}}`,
		"file:///lc_cancel.ha", 2601.0);
};

// $/cancelRequest with the id of an actually-in-flight request: the
// server records the cancellation but does NOT proactively short-
// circuit handlers (cancellation is cooperative; no handler currently
// consults `is_cancelled` mid-execution). The observable behavior is
// therefore that the request still gets a normal response, and the
// server continues handling subsequent traffic without crashing.
//
// This documents the actual implementation. If a handler later starts
// honoring cancellation by returning the `RequestCancelled` error
// code (-32800), this test needs to be updated to accept either
// outcome.
@test fn e2e_cancel_request_for_inflight_id_does_not_break_server() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const uri = "file:///lc_inflight_cancel.ha";
	open_doc(&s, uri, "export fn answer() int = 42;\n");

	// Issue a real request whose id we will then cancel. Pipeline the
	// cancel right after so it arrives before the server has finished
	// the response.
	const req =
		`{"jsonrpc":"2.0","id":2700,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///lc_inflight_cancel.ha"}}}`;
	send(&s, strings::toutf8(req));
	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":2700}}`));

	// Server should still respond to id=2700 (cooperative cancel: no
	// handler interrupts itself today).
	const body = wait_for_response(&s, 2700.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	// Result or error must be present; the documentSymbol handler
	// doesn't currently check is_cancelled, so we expect a result.
	// If the implementation grows a real cancel path, that's also
	// valid — accept either the success response or a -32800 error.
	match (json::get(&obj, "result")) {
	case let p: *json::value => void;
	// Normal completion path — documents the cooperative-only
	// nature of cancellation today.

	case void =>
		const err = *(json::get(&obj, "error") as *json::value) as json::object;
		const code = *(json::get(&err, "code") as *json::value) as f64;
		assert(
			code == -32800.0,
			"if cancellation interrupts a handler, the error code must be RequestCancelled (-32800)"
		);
	};

	// Server must still be alive — a follow-up request must succeed.
	const ping =
		`{"jsonrpc":"2.0","id":2701,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///lc_inflight_cancel.ha"}}}`;
	send(&s, strings::toutf8(ping));
	free(wait_for_response(&s, 2701.0));
};

// $/setTrace changes server-side trace verbosity. There is no observable
// wire effect beyond future $/logTrace notifications (which this server
// does not emit), so the test only verifies the notification is accepted.
@test fn e2e_set_trace_is_accepted() void = {
	smoke_notification(
		`{"jsonrpc":"2.0","method":"$/setTrace","params":{"value":"verbose"}}`,
		"file:///lc_trace.ha", 2603.0);
};

// window/workDoneProgress/cancel for a token the server never originated
// is a no-op. As with $/cancelRequest, exercising the active-progress
// path would need a server-initiated progress stream to race against.
@test fn e2e_workdone_progress_cancel_for_unknown_token_is_noop() void = {
	smoke_notification(
		`{"jsonrpc":"2.0","method":"window/workDoneProgress/cancel","params":{"token":"my-token"}}`,
		"file:///lc_progress.ha", 2605.0);
};

// workspace/didChangeConfiguration is accepted without disturbing the
// server. Verifying that the new debounce value actually changes the
// diagnostics-flush timing would require timing-sensitive assertions
// against publishDiagnostics; this test deliberately scopes itself to
// acceptance only.
@test fn e2e_did_change_configuration_is_accepted() void = {
	smoke_notification(
		`{"jsonrpc":"2.0","method":"workspace/didChangeConfiguration","params":{"settings":{"hare":{"diagnostics":{"debounceMs":250}}}}}`,
		"file:///lc_config.ha", 2607.0);
};

// workspace/didChangeWorkspaceFolders is accepted. A full test that
// the new folder is actually used for cross-file resolution would need
// a real on-disk fixture; this one only checks acceptance.
@test fn e2e_did_change_workspace_folders_is_accepted() void = {
	smoke_notification(
		`{"jsonrpc":"2.0","method":"workspace/didChangeWorkspaceFolders","params":{"event":{"added":[{"uri":"file:///newfolder","name":"new"}],"removed":[]}}}`,
		"file:///lc_folders.ha", 2609.0);
};
