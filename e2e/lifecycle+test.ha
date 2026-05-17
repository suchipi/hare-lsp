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
// server keeps responding to subsequent requests. A test that actually
// cancels an in-flight request would need a long-running request to
// race against, which we don't have a stable mechanism for here.
@test fn e2e_cancel_request_for_unknown_id_is_noop() void = {
	smoke_notification(
		`{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":9999}}`,
		"file:///lc_cancel.ha", 2601.0);
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

// `shutdown` must drain any debounced-but-not-yet-published diagnostics
// before responding. Otherwise editors miss the final error state when
// the user shuts the server down mid-edit. We push debounce out to one
// minute so a normal didChange-driven flush cannot fire, then collect
// every frame up to the shutdown response and assert a v=2 publish
// landed before it.
@test fn e2e_shutdown_drains_pending_diagnostics() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);
	// Push the debounce window way out so the next didChange won't
	// publish on its own; only the shutdown drain should.
	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","method":"workspace/didChangeConfiguration","params":{"settings":{"hare":{"diagnostics":{"debounceMs":60000}}}}}`
		));
	open_doc(&s, "file:///shutdown_drain.ha", "export fn main() void = void;\n");

	// Replace with a parse-broken body. Without the shutdown drain
	// this didChange would only mark diagnostics_pending and the
	// 60s debounce would swallow the publish.
	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///shutdown_drain.ha","version":2},"contentChanges":[{"text":"export fn main() void = {\nlet x = 1;\n"}]}}`
		));
	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":2700,"method":"shutdown","params":null}`));

	// Collect every frame up to and including the shutdown response,
	// then assert a v=2 publishDiagnostics for our URI landed first.
	let saw_v2_publish = false;
	for (let i = 0z; i < 100z; i += 1) {
		const body = recv(&s);
		defer free(body);
		const text = strings::fromutf8(body)!;
		if (strings::contains(text, `"method":"textDocument/publishDiagnostics"`) &&
				strings::contains(text, `file:///shutdown_drain.ha`) &&
				strings::contains(text, `"version":2`)) {
			saw_v2_publish = true;
		};
		if (strings::contains(text, `"id":2700`)) {
			break;
		};
	};
	assert(
		saw_v2_publish,
		"shutdown drain must publish v=2 diagnostics before responding"
	);
};
