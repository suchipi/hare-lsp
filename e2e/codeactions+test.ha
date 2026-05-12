// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// e2e: textDocument/codeAction, codeAction/resolve, and
// workspace/executeCommand.

use encoding::json;
use fmt;
use strings;

@test fn e2e_code_action_offers_organize_imports() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	// Out-of-order imports trigger the organizeImports action.
	const sample = `use strings;
use bufio;

export fn main() void = void;
`;
	open_doc(&s, "file:///ca.ha", sample);

	const req = `{"jsonrpc":"2.0","id":2300,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///ca.ha"},"range":{"start":{"line":0,"character":0},"end":{"line":1,"character":12}},"context":{"diagnostics":[]}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 2300.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value)
		as []json::value;
	assert(len(arr) >= 1,
		"out-of-order imports should produce at least one code action");

	let saw_org = false;
	for (let i = 0z; i < len(arr); i += 1) {
		const a = arr[i] as json::object;
		const kind = match (json::get(&a, "kind")) {
		case let p: *json::value =>
			yield match (*p) {
			case let s: str => yield s;
			case => yield "";
			};
		case => yield "";
		};
		if (kind == "source.organizeImports") saw_org = true;
	};
	assert(saw_org,
		"organize imports action must be offered for unsorted imports");
};

@test fn e2e_code_action_resolve_passthrough() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const req = `{"jsonrpc":"2.0","id":2301,"method":"codeAction/resolve","params":{"title":"Foo","kind":"quickfix"}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 2301.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	assert(json::get(&obj, "error") is void,
		"codeAction/resolve passthrough must not error");
	assert(json::get(&obj, "result") is *json::value,
		"codeAction/resolve must include a result");
};

@test fn e2e_execute_command_organize_imports_no_op() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	// hare-lsp.organizeImports is a registered command. Without arguments
	// the server returns null without erroring (the actual work flows
	// through codeAction/resolve in practice).
	const req = `{"jsonrpc":"2.0","id":2302,"method":"workspace/executeCommand","params":{"command":"hare-lsp.organizeImports"}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 2302.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	assert(json::get(&obj, "error") is void,
		"executeCommand for a known command must not error");
};

@test fn e2e_execute_command_unknown_returns_error() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const req = `{"jsonrpc":"2.0","id":2303,"method":"workspace/executeCommand","params":{"command":"not.a.real.command"}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 2303.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	assert(json::get(&obj, "error") is *json::value,
		"executeCommand for an unknown command must return an error");
};
