// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// e2e: pull-style diagnostics (textDocument/diagnostic and
// workspace/diagnostic). Push-style diagnostics arrive as
// `textDocument/publishDiagnostics` notifications after didOpen/didChange
// and are exercised here as well by waiting for the notification.

use encoding::json;
use fmt;
use strings;

@test fn e2e_pull_diagnostic_full_report_for_open_doc() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `export fn main() void = void;
`;
	open_doc(&s, "file:///pull_diag_ok.ha", sample);

	const req =
		`{"jsonrpc":"2.0","id":1000,"method":"textDocument/diagnostic","params":{"textDocument":{"uri":"file:///pull_diag_ok.ha"}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1000.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield *p;
	case void =>
		fmt::fatalf("e2e: pull diag missing result: {}", text);
	};
	const result_obj = result as json::object;
	const kind = *(json::get(&result_obj, "kind") as *json::value) as str;
	assert(kind == "full", "diagnostic report kind must be `full`");
	const items =
		*(json::get(&result_obj, "items") as *json::value) as []json::value;
	// Clean file: should be empty.
	assert(
		len(items) == 0,
		"a syntactically valid file should produce no diagnostics"
	);
};

@test fn e2e_pull_diagnostic_reports_parse_error() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	// Missing closing brace -> parser produces an error diagnostic.
	const sample = `export fn main() void = {
	let x = 1;
`;
	open_doc(&s, "file:///pull_diag_bad.ha", sample);

	const req =
		`{"jsonrpc":"2.0","id":1001,"method":"textDocument/diagnostic","params":{"textDocument":{"uri":"file:///pull_diag_bad.ha"}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1001.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result_obj =
		*(json::get(&obj, "result") as *json::value) as json::object;
	const items =
		*(json::get(&result_obj, "items") as *json::value) as []json::value;
	assert(len(items) >= 1, "broken file should produce at least one diagnostic");
	// Sanity: first item has a `message` and a `range`.
	const d0 = items[0] as json::object;
	assert(
		json::get(&d0, "message") is *json::value,
		"diagnostic must include message"
	);
	assert(
		json::get(&d0, "range") is *json::value,
		"diagnostic must include range"
	);
};

@test fn e2e_workspace_diagnostic_returns_per_doc_reports() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	open_doc(&s, "file:///ws_diag_a.ha", "export fn a() void = void;\n");
	open_doc(&s, "file:///ws_diag_b.ha", "export fn b() void = void;\n");

	const req =
		`{"jsonrpc":"2.0","id":1002,"method":"workspace/diagnostic","params":{"previousResultIds":[]}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1002.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result_obj =
		*(json::get(&obj, "result") as *json::value) as json::object;
	const items =
		*(json::get(&result_obj, "items") as *json::value) as []json::value;
	assert(
		len(items) == 2,
		"workspace diagnostic should report exactly one entry per open doc"
	);
	for (let i = 0z; i < len(items); i += 1) {
		const r = items[i] as json::object;
		assert(
			*(json::get(&r, "kind") as *json::value) as str == "full",
			"each per-doc report is a full report"
		);
		assert(json::get(&r, "uri") is *json::value, "each report carries its uri");
		assert(
			json::get(&r, "items") is *json::value,
			"each report carries its items array"
		);
	};
};

// Push-style: opening a broken doc produces a publishDiagnostics
// notification. Drain frames until we see it.
@test fn e2e_push_diagnostic_published_after_didopen() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `export fn main() void = {
	let x = 1;
`;
	open_doc(&s, "file:///push_diag.ha", sample);

	let saw = false;
	for (let i = 0z; i < 20z && !saw; i += 1) {
		const body = recv(&s);
		defer free(body);
		const text = strings::fromutf8(body)!;
		if (strings::contains(text, `"method":"textDocument/publishDiagnostics"`) &&
		strings::contains(text, "push_diag.ha")) {
			saw = true;
		};
	};
	assert(saw, "server must publish diagnostics for a broken doc after didOpen");
};
