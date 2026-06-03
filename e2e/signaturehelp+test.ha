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

	const sample =
		`export fn add(a: int, b: int) int = a + b;

export fn main() void = {
	let _ = add(1, );
};
`;
	open_doc(&s, "file:///sh.ha", sample);

	// Cursor right before the closing paren on line 3: "let _ = add(1, "
	// (15 chars including the tab), so char 15.
	const req =
		`{"jsonrpc":"2.0","id":1900,"method":"textDocument/signatureHelp","params":{"textDocument":{"uri":"file:///sh.ha"},"position":{"line":3,"character":15}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1900.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield *p;
	case void =>
		fmt::fatalf("e2e: signatureHelp missing result: {}", text);
	};
	const result_obj = result as json::object;
	const sigs =
		*(json::get(&result_obj, "signatures") as *json::value) as []json::value;
	assert(
		len(sigs) == 1,
		"signatureHelp should return exactly one signature for `add`"
	);
	const sig = sigs[0] as json::object;
	const label = *(json::get(&sig, "label") as *json::value) as str;
	// The signature label must include the parameter list and return
	// type so the editor can render a useful popup. Body must be stripped
	// (handle_signature_help reuses render_decl_signature, which drops
	// `= body`).
	assert(
		strings::contains(label, "fn add(a: int, b: int) int"),
		"signature label should render the full prototype with parameter types and return type"
	);
	assert(
		!strings::contains(label, "a + b"),
		"signature label must not include the function body"
	);
	// Each parameter label must be a substring of the signature label so
	// the editor knows which range to highlight for the active parameter
	// (per the LSP spec for ParameterInformation.label). `"param 0"` /
	// `"param 1"` placeholders would render no highlight at all.
	const params =
		*(json::get(&sig, "parameters") as *json::value) as []json::value;
	assert(
		len(params) == 2,
		"signature should have parameters matching the prototype (2)"
	);
	const p0 = params[0] as json::object;
	const p0_label = *(json::get(&p0, "label") as *json::value) as str;
	assert(
		p0_label == "a: int",
		"first parameter label must be its own `<name>: <type>` text"
	);
	assert(
		strings::contains(label, p0_label),
		"first parameter label must be a substring of the signature label"
	);
	const p1 = params[1] as json::object;
	const p1_label = *(json::get(&p1, "label") as *json::value) as str;
	assert(
		p1_label == "b: int",
		"second parameter label must be its own `<name>: <type>` text"
	);
	assert(
		strings::contains(label, p1_label),
		"second parameter label must be a substring of the signature label"
	);
	// activeParameter should be 1 (we are at the second argument).
	const active =
		*(json::get(&result_obj, "activeParameter") as *json::value) as f64;
	assert(
		active == 1.0,
		"activeParameter should be 1 when the cursor is past one comma"
	);
};

// Cross-file: the called function lives in a workspace file we never
// open. The workspace_index caches the rendered signature label and
// per-parameter labels at indexing time, so the SignatureInformation we
// return here should match the in-file path -- full prototype label,
// substring parameter labels, and an activeParameter that tracks the
// argument the cursor sits in.
//
// Per the project offset rules, the called function uses a multi-rune
// name (`compute_total`) and the caller file has a multi-byte rune (an
// accented Latin letter) above the call so build_line_index has to
// advance past a non-ASCII byte sequence before recording line 2's
// start.
@test fn e2e_signature_help_resolves_across_workspace_files() void = {
	const files: [](str, str) = [
		(
			"util.ha",
			"export fn compute_total(name: str, count: int) int = count;\n",
		),
		(
			"main.ha",
			// `é` on line 0 forces position_to_byte to walk through a
			// 2-byte UTF-8 sequence when computing line 2's start; a
			// regression in the byte/code-unit conversion would shift
			// the cursor off the comma and desync activeParameter.
			"// hare-lsp caller fixture (rés)\n"
			"export fn main() void = {\n"
			"\tlet _ = compute_total(\"x\", );\n"
			"};\n",
		),
	];
	const root = make_workspace("sighelp-crossfile", files);
	defer cleanup_workspace(root);

	let s = spawn_session();
	defer finish_session(&s);
	do_init_with_workspace(&s, root);
	drain_until_indexed_ref(&s);

	const main_uri = strings::concat("file://", root, "/main.ha")!;
	defer free(main_uri);
	const main_body = files[1].1;
	open_doc(&s, main_uri, main_body);

	// Cursor right before the closing paren on line 2:
	//   "\tlet _ = compute_total(\"x\", "
	// = 1 (tab) + "let _ = compute_total(\"x\", " (27 chars) = 28 chars.
	const tmpl =
		`{"jsonrpc":"2.0","id":1910,"method":"textDocument/signatureHelp","params":{"textDocument":{"uri":"`;
	const req =
		strings::concat(tmpl, main_uri,
			`"},"position":{"line":2,"character":28}}}`)!;
	defer free(req);
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1910.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield *p;
	case void =>
		fmt::fatalf("e2e: cross-file signatureHelp missing result: {}", text);
	};
	const result_obj = match (result) {
	case let o: json::object =>
		yield o;
	case =>
		fmt::fatalf(
			"e2e: cross-file signatureHelp returned null/non-object -- workspace fallback regressed. body={}",
			text);
	};
	const sigs =
		*(json::get(&result_obj, "signatures") as *json::value) as []json::value;
	if (len(sigs) != 1) {
		fmt::fatalf(
			"e2e: cross-file signatureHelp returned {} signatures; expected 1. body={}",
			len(sigs), text);
	};
	const sig = sigs[0] as json::object;
	const label = *(json::get(&sig, "label") as *json::value) as str;
	assert(
		strings::contains(label, "fn compute_total(name: str, count: int) int"),
		"cross-file signature label must render the full prototype, not just the bare name"
	);
	assert(
		!strings::contains(label, "= count"),
		"cross-file signature label must strip the function body"
	);
	const params =
		*(json::get(&sig, "parameters") as *json::value) as []json::value;
	if (len(params) != 2) {
		fmt::fatalf(
			"e2e: cross-file signature should have 2 parameters; got {}. body={}",
			len(params), text);
	};
	const p0 = params[0] as json::object;
	const p0_label = *(json::get(&p0, "label") as *json::value) as str;
	assert(
		p0_label == "name: str",
		"cross-file parameter[0] label should be `name: str`"
	);
	assert(
		strings::contains(label, p0_label),
		"parameter[0] label must be a substring of the signature label"
	);
	const p1 = params[1] as json::object;
	const p1_label = *(json::get(&p1, "label") as *json::value) as str;
	assert(
		p1_label == "count: int",
		"cross-file parameter[1] label should be `count: int`"
	);
	assert(
		strings::contains(label, p1_label),
		"parameter[1] label must be a substring of the signature label"
	);
	const active =
		*(json::get(&result_obj, "activeParameter") as *json::value) as f64;
	assert(
		active == 1.0,
		"activeParameter should be 1 when the cursor is past the first comma"
	);
};

@test fn e2e_signature_help_outside_call_returns_null() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `export fn main() void = void;
`;
	open_doc(&s, "file:///sh2.ha", sample);

	// Cursor at the start of `void`, well outside any call.
	const req =
		`{"jsonrpc":"2.0","id":1901,"method":"textDocument/signatureHelp","params":{"textDocument":{"uri":"file:///sh2.ha"},"position":{"line":0,"character":1}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1901.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = *(json::get(&obj, "result") as *json::value);
	// LSP requires `null` here (not just "anything non-object") so the
	// editor closes any open signature popup. Pinning to json::_null
	// catches a regression that returned a string, array, bool, or
	// number — all of which the previous "anything non-object" check
	// would have accepted silently.
	match (result) {
	case json::_null => void;
	case =>
		fmt::fatalf("e2e: signatureHelp outside a call must be JSON null, got: {}",
			text);
	};
};
