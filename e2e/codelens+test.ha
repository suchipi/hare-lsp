// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// CodeLens e2e: regression coverage for the "N references" lens whose
// resolve step used to hand showReferences the byte offset of the
// decl's start — which is `export` for an exported fn, making
// references match every `export` keyword in the workspace. The
// resolve must instead point at the identifier itself.

use encoding::json;
use strings;

@test fn e2e_codelens_references_anchored_at_name() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s, strings::toutf8(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`));
	free(wait_for_response(&s, 1.0));
	send(&s, strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample = `export fn main() void = void;
`;
	const did_open = build_did_open("file:///cl_anchor.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Ask for the file's lenses.
	send(&s, strings::toutf8(`{"jsonrpc":"2.0","id":10,"method":"textDocument/codeLens","params":{"textDocument":{"uri":"file:///cl_anchor.ha"}}}`));
	const lenses_body = wait_for_response(&s, 10.0);
	defer free(lenses_body);
	let lenses_v = json::loadstr(strings::fromutf8(lenses_body)!)!;
	defer json::finish(lenses_v);
	const lenses_obj = lenses_v as json::object;
	const lenses = (*(json::get(&lenses_obj, "result") as *json::value)) as []json::value;
	assert(len(lenses) >= 1, "expected at least one CodeLens for `main`");

	// Resolve the first lens — its data carries kind=references.
	const lens0_obj = lenses[0] as json::object;
	const data_v = (*(json::get(&lens0_obj, "data") as *json::value));
	const range_v = (*(json::get(&lens0_obj, "range") as *json::value));

	// Build a codeLens/resolve request manually with the lens we got back.
	const resolve_msg = strings::concat(
		`{"jsonrpc":"2.0","id":11,"method":"codeLens/resolve","params":{"range":`,
		dump_value(range_v),
		`,"data":`,
		dump_value(data_v),
		`}}`)!;
	defer free(resolve_msg);
	send(&s, strings::toutf8(resolve_msg));

	const resolved_body = wait_for_response(&s, 11.0);
	defer free(resolved_body);
	let resolved_v = json::loadstr(strings::fromutf8(resolved_body)!)!;
	defer json::finish(resolved_v);
	const resolved_obj = resolved_v as json::object;
	const result_obj = (*(json::get(&resolved_obj, "result") as *json::value)) as json::object;
	const command_obj = (*(json::get(&result_obj, "command") as *json::value)) as json::object;

	const cmd_name = (*(json::get(&command_obj, "command") as *json::value)) as str;
	assert(cmd_name == "hare-lsp.showReferences",
		"resolved command must be hare-lsp.showReferences");

	const args = (*(json::get(&command_obj, "arguments") as *json::value)) as []json::value;
	assert(len(args) == 2,
		"showReferences must receive [uri, position]");
	const pos_obj = args[1] as json::object;
	const line = (*(json::get(&pos_obj, "line") as *json::value)) as f64;
	const character = (*(json::get(&pos_obj, "character") as *json::value)) as f64;
	// "export fn main()" — `main` begins at column 10 (UTF-16 chars):
	// "export fn " is 10 characters. We accept any column past the `e`
	// of `export` to catch the regression where the position was at 0.
	assert(line == 0.0, "main is declared on line 0");
	assert(character > 0.0,
		"position must point at the identifier, not the start of `export`");
};

// Roundtrip a json::value through strings — keeps the resolve test free of
// json::dump dependencies. We rely on the server's own framing of the lens
// object, which uses ASCII keys we don't need to escape.
fn dump_value(v: json::value) str = {
	return json::dumpstr(v);
};
