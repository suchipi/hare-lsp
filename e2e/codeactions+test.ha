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

	const req =
		`{"jsonrpc":"2.0","id":2300,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///ca.ha"},"range":{"start":{"line":0,"character":0},"end":{"line":1,"character":10}},"context":{"diagnostics":[]}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 2300.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	assert(
		len(arr) >= 1,
		"out-of-order imports should produce at least one code action"
	);

	// Find the organize-imports action and verify it carries a real
	// edit. Without checking the edit, a regression that emitted an
	// empty-payload `source.organizeImports` action - a lightbulb that
	// does nothing when clicked - would pass.
	let saw_org = false;
	for (let i = 0z; i < len(arr); i += 1) {
		const a = arr[i] as json::object;
		const kind = match (json::get(&a, "kind")) {
		case let p: *json::value =>
			yield match (*p) {
			case let s: str =>
				yield s;
			case =>
				yield "";
			};
		case =>
			yield "";
		};
		if (kind != "source.organizeImports") continue;
		saw_org = true;

		const title = match (json::get(&a, "title")) {
		case let p: *json::value =>
			yield match (*p) {
			case let s: str =>
				yield s;
			case =>
				fmt::fatalf("e2e: organizeImports action title is not a string: {}", text);
			};
		case =>
			fmt::fatalf("e2e: organizeImports action missing title: {}", text);
		};
		assert(
			len(title) > 0,
			"organizeImports action must carry a non-empty title (clients show it in the lightbulb menu)"
		);

		const edit = match (json::get(&a, "edit")) {
		case let p: *json::value =>
			yield match (*p) {
			case let o: json::object =>
				yield o;
			case =>
				fmt::fatalf("e2e: organizeImports action edit must be an object: {}", text);
			};
		case =>
			fmt::fatalf("e2e: organizeImports action missing edit: {}", text);
		};
		const new_text = extract_organize_edit_newtext(&edit, "file:///ca.ha", text);
		// The server sorts `use bufio;` before `use strings;`.
		assert(
			new_text == "use bufio;\nuse strings;\n",
			"organizeImports edit must replace the import block with sorted imports"
		);
	};
	assert(
		saw_org,
		"organize imports action must be offered for unsorted imports"
	);
};

// The resolve handler is a passthrough: the server constructs the full
// action eagerly in textDocument/codeAction, so resolve just hands the
// input back. This test exercises the real flow - pick a real action
// returned by codeAction, send it through resolve, and assert the
// response carries the same kind + a non-empty edit. A regression that
// stripped fields on resolve (or that erred on a structurally-correct
// action) would fail here.
@test fn e2e_code_action_resolve_round_trips_real_action() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `use strings;
use bufio;

export fn main() void = void;
`;
	open_doc(&s, "file:///car.ha", sample);

	const ca_req =
		`{"jsonrpc":"2.0","id":2301,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///car.ha"},"range":{"start":{"line":0,"character":0},"end":{"line":1,"character":10}},"context":{"diagnostics":[]}}}`;
	send(&s, strings::toutf8(ca_req));
	const ca_body = wait_for_response(&s, 2301.0);
	defer free(ca_body);
	let ca_v = json::loadstr(strings::fromutf8(ca_body)!)!;
	defer json::finish(ca_v);
	const ca_obj = ca_v as json::object;
	const actions =
		*(json::get(&ca_obj, "result") as *json::value) as []json::value;
	let action_idx: size = len(actions);
	for (let i = 0z; i < len(actions); i += 1) {
		const a = actions[i] as json::object;
		const kind = match (json::get(&a, "kind")) {
		case let p: *json::value =>
			yield match (*p) {
			case let s: str =>
				yield s;
			case =>
				continue;
			};
		case =>
			continue;
		};
		if (kind == "source.organizeImports") {
			action_idx = i;
			break;
		};
	};
	assert(
		action_idx < len(actions),
		"prerequisite: codeAction must offer source.organizeImports for unsorted imports"
	);
	const action_json = json::dumpstr(actions[action_idx]);
	defer free(action_json);

	// Send the *real* action through resolve.
	const resolve_req =
		strings::concat(
			`{"jsonrpc":"2.0","id":2304,"method":"codeAction/resolve","params":`,
			action_json, `}`)!;
	defer free(resolve_req);
	send(&s, strings::toutf8(resolve_req));

	const body = wait_for_response(&s, 2304.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	assert(
		json::get(&obj, "error") is void,
		"codeAction/resolve on a real action must not error"
	);
	const result = *(json::get(&obj, "result") as *json::value) as json::object;
	const kind = *(json::get(&result, "kind") as *json::value) as str;
	assert(
		kind == "source.organizeImports",
		"resolve must preserve the action's kind"
	);
	const edit = *(json::get(&result, "edit") as *json::value) as json::object;
	const new_text = extract_organize_edit_newtext(&edit, "file:///car.ha", text);
	assert(
		new_text == "use bufio;\nuse strings;\n",
		"resolved action must still carry the import-sort edit"
	);
};

// hare-lsp.organizeImports without arguments is intentionally a no-op:
// the real work flows through codeAction/resolve. The test pins down
// (a) the result is JSON null (positive check, not just absence of
// error), and (b) the command is in fact advertised in the initialize
// response's executeCommandProvider.commands. A regression that
// unadvertised the command but kept the no-op handler would pass a
// pure-server check; a regression that started returning an error
// would fail the positive null check.
@test fn e2e_execute_command_organize_imports_no_op() void = {
	let s = spawn_session();
	defer finish_session(&s);
	// Use the manual initialize handshake so we can inspect the
	// response body for the command list. do_init discards it.
	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	const init_body = wait_for_response(&s, 1.0);
	defer free(init_body);
	const init_text = strings::fromutf8(init_body)!;
	let init_v = json::loadstr(init_text)!;
	defer json::finish(init_v);
	const init_obj = init_v as json::object;
	const init_result =
		*(json::get(&init_obj, "result") as *json::value) as json::object;
	const caps =
		*(json::get(&init_result, "capabilities") as *json::value) as json::object;
	const xc_provider = match (json::get(&caps, "executeCommandProvider")) {
	case let p: *json::value =>
		yield *p as json::object;
	case =>
		fmt::fatalf("e2e: initialize must advertise executeCommandProvider: {}",
			init_text);
	};
	const cmds =
		*(json::get(&xc_provider, "commands") as *json::value) as []json::value;
	let advertised = false;
	for (let i = 0z; i < len(cmds); i += 1) {
		const name = cmds[i] as str;
		if (name == "hare-lsp.organizeImports") {
			advertised = true;
			break;
		};
	};
	assert(
		advertised,
		"server must advertise hare-lsp.organizeImports in executeCommandProvider.commands"
	);
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const req =
		`{"jsonrpc":"2.0","id":2302,"method":"workspace/executeCommand","params":{"command":"hare-lsp.organizeImports"}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 2302.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	assert(
		json::get(&obj, "error") is void,
		"executeCommand for a known command must not error"
	);
	const result = *(json::get(&obj, "result") as *json::value);
	match (result) {
	case json::_null => void;
	case =>
		fmt::fatalf(
			"e2e: executeCommand(hare-lsp.organizeImports) without args must return JSON null, got: {}",
			text);
	};
};

@test fn e2e_execute_command_unknown_returns_error() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const req =
		`{"jsonrpc":"2.0","id":2303,"method":"workspace/executeCommand","params":{"command":"not.a.real.command"}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 2303.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const err = *(json::get(&obj, "error") as *json::value) as json::object;
	// LSP spec MethodNotFound is -32601; the server uses this code for
	// unknown executeCommand names (see server/commands.ha). Editors
	// surface different recovery paths based on the error code, so the
	// numeric value matters - a generic InternalError would be a worse
	// UX.
	const code = *(json::get(&err, "code") as *json::value) as f64;
	assert(
		code == -32601.0,
		"executeCommand for an unknown command must return MethodNotFound (-32601)"
	);
	const msg = *(json::get(&err, "message") as *json::value) as str;
	assert(len(msg) > 0, "executeCommand error must carry a non-empty message");
};

// Drills into a WorkspaceEdit `{ changes: { uri: [TextEdit] } }` to
// retrieve the `newText` of the single TextEdit targeting `uri`. Fails
// the test with `raw` in the message if any layer is missing.
fn extract_organize_edit_newtext(
	edit: *json::object,
	uri: str,
	raw: str,
) str = {
	const changes = match (json::get(edit, "changes")) {
	case let p: *json::value =>
		yield match (*p) {
		case let o: json::object =>
			yield o;
		case =>
			fmt::fatalf("e2e: organize-imports edit.changes must be an object: {}", raw);
		};
	case =>
		fmt::fatalf("e2e: organize-imports edit missing changes: {}", raw);
	};
	const edits = match (json::get(&changes, uri)) {
	case let p: *json::value =>
		yield match (*p) {
		case let a: []json::value =>
			yield a;
		case =>
			fmt::fatalf("e2e: edit.changes[{}] must be an array: {}", uri, raw);
		};
	case =>
		fmt::fatalf("e2e: edit.changes does not target {}: {}", uri, raw);
	};
	assert(
		len(edits) == 1,
		"organize-imports edit should be a single TextEdit replacing the import block"
	);
	const te = edits[0] as json::object;
	return *(json::get(&te, "newText") as *json::value) as str;
};
