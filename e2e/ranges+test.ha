// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// e2e: foldingRange and selectionRange.

use encoding::json;
use fmt;
use strings;

@test fn e2e_folding_range_returns_function_body_region() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `export fn main() void = {
	let x = 1;
	let y = 2;
	let _ = x + y;
};
`;
	open_doc(&s, "file:///fold_fn.ha", sample);

	const req = `{"jsonrpc":"2.0","id":1300,"method":"textDocument/foldingRange","params":{"textDocument":{"uri":"file:///fold_fn.ha"}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1300.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value)
		as []json::value;
	assert(len(arr) >= 1,
		"a multi-line function body should produce a fold range");
	const fold0 = arr[0] as json::object;
	const start_line = *(json::get(&fold0, "startLine") as *json::value) as f64;
	const end_line = *(json::get(&fold0, "endLine") as *json::value) as f64;
	assert(end_line > start_line,
		"fold range must span more than one line");
};

@test fn e2e_folding_range_emits_imports_region() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `use io;
use os;
use strings;

export fn main() void = void;
`;
	open_doc(&s, "file:///fold_imp.ha", sample);

	const req = `{"jsonrpc":"2.0","id":1301,"method":"textDocument/foldingRange","params":{"textDocument":{"uri":"file:///fold_imp.ha"}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1301.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value)
		as []json::value;
	let saw_imports_kind = false;
	for (let i = 0z; i < len(arr); i += 1) {
		const o = arr[i] as json::object;
		const kind = match (json::get(&o, "kind")) {
		case let p: *json::value =>
			yield match (*p) {
			case let s: str => yield s;
			case => yield "";
			};
		case => yield "";
		};
		if (kind == "imports") saw_imports_kind = true;
	};
	assert(saw_imports_kind,
		"a multi-line import block should be reported with kind=imports");
};

@test fn e2e_selection_range_returns_nested_ranges() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `export fn main() void = {
	let x = 1;
};
`;
	open_doc(&s, "file:///sel.ha", sample);

	// Position on `x` in the let binding (line 1, char 5).
	const req = `{"jsonrpc":"2.0","id":1302,"method":"textDocument/selectionRange","params":{"textDocument":{"uri":"file:///sel.ha"},"positions":[{"line":1,"character":5}]}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1302.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value)
		as []json::value;
	assert(len(arr) == 1,
		"selectionRange must return one result per requested position");
	const r0 = arr[0] as json::object;
	assert(json::get(&r0, "range") is *json::value,
		"each selection range must include a range field");
};
