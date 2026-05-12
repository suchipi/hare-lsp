// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// e2e: textDocument/signatureHelp.

use encoding::json;
use fmt;
use strings;

@test fn e2e_signature_help_inside_call_returns_signature() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `export fn add(a: int, b: int) int = a + b;

export fn main() void = {
	let _ = add(1, );
};
`;
	open_doc(&s, "file:///sh.ha", sample);

	// Cursor right before the closing paren on line 3: "let _ = add(1, "
	// (15 chars including the tab), so char 15.
	const req = `{"jsonrpc":"2.0","id":1900,"method":"textDocument/signatureHelp","params":{"textDocument":{"uri":"file:///sh.ha"},"position":{"line":3,"character":15}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1900.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = match (json::get(&obj, "result")) {
	case let p: *json::value => yield *p;
	case void =>
		fmt::fatalf("e2e: signatureHelp missing result: {}", text);
	};
	const result_obj = result as json::object;
	const sigs = *(json::get(&result_obj, "signatures") as *json::value)
		as []json::value;
	assert(len(sigs) >= 1,
		"signatureHelp should return at least one signature inside a call");
	const sig = sigs[0] as json::object;
	const label = *(json::get(&sig, "label") as *json::value) as str;
	assert(strings::contains(label, "add"),
		"signature label should mention the callee");
	// activeParameter should be 1 (we are at the second argument).
	const active = *(json::get(&result_obj, "activeParameter") as *json::value) as f64;
	assert(active == 1.0,
		"activeParameter should be 1 when the cursor is past one comma");
};

@test fn e2e_signature_help_outside_call_returns_null() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `export fn main() void = void;
`;
	open_doc(&s, "file:///sh2.ha", sample);

	// Cursor at the start of `void`, well outside any call.
	const req = `{"jsonrpc":"2.0","id":1901,"method":"textDocument/signatureHelp","params":{"textDocument":{"uri":"file:///sh2.ha"},"position":{"line":0,"character":1}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1901.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = *(json::get(&obj, "result") as *json::value);
	match (result) {
	case json::object =>
		fmt::fatalf("e2e: signatureHelp outside a call should be null, got: {}",
			text);
	case => void;
	};
};
