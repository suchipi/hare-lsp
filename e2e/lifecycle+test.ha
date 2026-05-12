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
use fmt;
use strings;

@test fn e2e_pre_init_request_returns_server_not_initialized() void = {
	let s = spawn_session();
	defer finish_session(&s);

	// Skip do_init(): send a non-initialize request first.
	send(&s, strings::toutf8(`{"jsonrpc":"2.0","id":2600,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///x.ha"},"position":{"line":0,"character":0}}}`));

	const body = wait_for_response(&s, 2600.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const err = (*(json::get(&obj, "error") as *json::value)) as json::object;
	const code = *(json::get(&err, "code") as *json::value) as f64;
	// SERVER_NOT_INITIALIZED = -32002.
	assert(code == -32002.0,
		"pre-init request must yield SERVER_NOT_INITIALIZED");
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
	const ping = strings::concat(
		`{"jsonrpc":"2.0","id":`,
		f64_to_int_str(ping_id),
		`,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"`,
		probe_uri,
		`"}}}`)!;
	defer free(ping);
	send(&s, strings::toutf8(ping));
	free(wait_for_response(&s, ping_id));

	send(&s, strings::toutf8(notif));

	const ping2_id = ping_id + 1.0;
	const ping2 = strings::concat(
		`{"jsonrpc":"2.0","id":`,
		f64_to_int_str(ping2_id),
		`,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"`,
		probe_uri,
		`"}}}`)!;
	defer free(ping2);
	send(&s, strings::toutf8(ping2));
	free(wait_for_response(&s, ping2_id));
};

// Renders an integer-valued f64 as decimal text for embedding in JSON
// (we only ever use whole-number ids in these helpers).
fn f64_to_int_str(v: f64) str = {
	const n = v: i64;
	let buf: [21]u8 = [0...];
	let i = len(buf);
	let val = if (n < 0) -n else n;
	if (val == 0) {
		i -= 1;
		buf[i] = '0': u8;
	};
	for (val > 0; val /= 10) {
		i -= 1;
		buf[i] = ('0': u8) + (val % 10): u8;
	};
	if (n < 0) {
		i -= 1;
		buf[i] = '-': u8;
	};
	return strings::dup(strings::fromutf8(buf[i..])!)!;
};

@test fn e2e_cancel_request_is_consumed() void = {
	smoke_notification(
		`{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":9999}}`,
		"file:///lc_cancel.ha", 2601.0);
};

@test fn e2e_set_trace_is_consumed() void = {
	smoke_notification(
		`{"jsonrpc":"2.0","method":"$/setTrace","params":{"value":"verbose"}}`,
		"file:///lc_trace.ha", 2603.0);
};

@test fn e2e_workdone_progress_cancel_is_consumed() void = {
	smoke_notification(
		`{"jsonrpc":"2.0","method":"window/workDoneProgress/cancel","params":{"token":"my-token"}}`,
		"file:///lc_progress.ha", 2605.0);
};

@test fn e2e_did_change_configuration_is_consumed() void = {
	smoke_notification(
		`{"jsonrpc":"2.0","method":"workspace/didChangeConfiguration","params":{"settings":{"hare":{"diagnostics":{"debounceMs":250}}}}}`,
		"file:///lc_config.ha", 2607.0);
};

@test fn e2e_did_change_workspace_folders_is_consumed() void = {
	smoke_notification(
		`{"jsonrpc":"2.0","method":"workspace/didChangeWorkspaceFolders","params":{"event":{"added":[{"uri":"file:///newfolder","name":"new"}],"removed":[]}}}`,
		"file:///lc_folders.ha", 2609.0);
};
