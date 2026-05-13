// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// e2e: document and workspace symbol providers.

use encoding::json;
use fmt;
use strings;

@test fn e2e_document_symbol_returns_all_decls() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample =
		`export fn one() void = void;
export fn two() int = 2;
type my_type = int;
export def MY_CONST: int = 7;
`;
	open_doc(&s, "file:///docsym.ha", sample);

	const req =
		`{"jsonrpc":"2.0","id":1200,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///docsym.ha"}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1200.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	assert(
		len(arr) == 4,
		"expected exactly four document symbols (one, two, my_type, MY_CONST)"
	);

	// Capture each symbol's (kind, line) so we verify outline-view
	// shape, not just that the names showed up. The fixture pins down
	// the kind values (function=12, struct=23, constant=14) and the
	// decl's source line so a server regression that emits everything
	// as kind=0, or collapses ranges to 0:0, fails here.
	let one_kind = -1.0, one_line = -1.0;
	let two_kind = -1.0, two_line = -1.0;
	let type_kind = -1.0, type_line = -1.0;
	let const_kind = -1.0, const_line = -1.0;
	for (let i = 0z; i < len(arr); i += 1) {
		const sym = arr[i] as json::object;
		const name = *(json::get(&sym, "name") as *json::value) as str;
		const kind = *(json::get(&sym, "kind") as *json::value) as f64;
		const loc = *(json::get(&sym, "location") as *json::value) as json::object;
		const rng = *(json::get(&loc, "range") as *json::value) as json::object;
		const start = *(json::get(&rng, "start") as *json::value) as json::object;
		const line = *(json::get(&start, "line") as *json::value) as f64;
		if (name == "one") {
			one_kind = kind;
			one_line = line;
		};
		if (name == "two") {
			two_kind = kind;
			two_line = line;
		};
		if (name == "my_type") {
			type_kind = kind;
			type_line = line;
		};
		if (name == "MY_CONST") {
			const_kind = kind;
			const_line = line;
		};
	};
	assert(one_kind == 12.0, "one must be SymbolKind.Function (12)");
	assert(two_kind == 12.0, "two must be SymbolKind.Function (12)");
	assert(type_kind == 23.0, "my_type must be SymbolKind.Struct (23)");
	assert(const_kind == 14.0, "MY_CONST must be SymbolKind.Constant (14)");
	assert(one_line == 0.0, "one decl is on line 0");
	assert(two_line == 1.0, "two decl is on line 1");
	assert(type_line == 2.0, "my_type decl is on line 2");
	assert(const_line == 3.0, "MY_CONST decl is on line 3");
};

@test fn e2e_document_highlight_returns_array() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample =
		`export fn answer() int = 42;

export fn ask() int = answer();
`;
	open_doc(&s, "file:///hl.ha", sample);

	// Cursor on `answer` in the declaration (line 0, char 12).
	const req =
		`{"jsonrpc":"2.0","id":1201,"method":"textDocument/documentHighlight","params":{"textDocument":{"uri":"file:///hl.ha"},"position":{"line":0,"character":12}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1201.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	// `answer` appears twice in the fixture: once at the decl on line
	// 0 and once at the call site inside `ask` on line 2. Both should
	// echo back as highlights so a user putting the cursor on the
	// function name sees every usage glow in the editor.
	assert(
		len(arr) == 2,
		"documentHighlight should return one highlight per occurrence of `answer`"
	);
	let saw_decl = false, saw_call = false;
	for (let i = 0z; i < len(arr); i += 1) {
		const hl = arr[i] as json::object;
		const rng = *(json::get(&hl, "range") as *json::value) as json::object;
		const start = *(json::get(&rng, "start") as *json::value) as json::object;
		const _end = *(json::get(&rng, "end") as *json::value) as json::object;
		const line = *(json::get(&start, "line") as *json::value) as f64;
		const ch = *(json::get(&start, "character") as *json::value) as f64;
		const end_ch = *(json::get(&_end, "character") as *json::value) as f64;
		// Each highlight must span just the identifier `answer` (6
		// chars), not the whole decl/call line.
		assert(
			end_ch - ch == 6.0,
			"highlight range must span the identifier exactly"
		);
		// `answer` starts at column 10 on the decl line and column 22
		// on the call line.
		if (line == 0.0 && ch == 10.0) saw_decl = true;
		if (line == 2.0 && ch == 22.0) saw_call = true;
	};
	assert(saw_decl, "decl-site highlight must appear at line 0 col 10");
	assert(saw_call, "call-site highlight must appear at line 2 col 22");
};

@test fn e2e_workspace_symbol_finds_open_decl() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `export fn an_unusual_name() void = void;
`;
	open_doc(&s, "file:///wsym.ha", sample);

	// Empty query returns capped list of all entries; that may not
	// include open-doc decls until workspace scan settles. Use a fuzzy
	// query that should match the symbol in the open doc.
	const req =
		`{"jsonrpc":"2.0","id":1202,"method":"workspace/symbol","params":{"query":"an_unusual"}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1202.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result_obj =
		*(json::get(&obj, "result") as *json::value) as json::object;
	const items =
		*(json::get(&result_obj, "items") as *json::value) as []json::value;
	// The whole point of the picker is finding the open-doc decl. If
	// items came back empty, the workspace-symbol picker would show
	// nothing for a user with unsaved files.
	let found = false;
	for (let i = 0z; i < len(items); i += 1) {
		const it = items[i] as json::object;
		const name = *(json::get(&it, "name") as *json::value) as str;
		if (name == "an_unusual_name") {
			const loc = *(json::get(&it, "location") as *json::value) as json::object;
			const uri = *(json::get(&loc, "uri") as *json::value) as str;
			assert(
				uri == "file:///wsym.ha",
				"open-doc symbol must point at the open-doc URI"
			);
			found = true;
			break;
		};
	};
	assert(
		found,
		"workspace/symbol must surface `an_unusual_name` from the open doc"
	);
	// Verify isIncomplete is a bool (LSP spec required field). The
	// value itself may be either: workspace/symbol kicks off stdlib
	// indexing on first call, so the first query in a session can
	// legitimately report isIncomplete=true.
	const _ = *(json::get(&result_obj, "isIncomplete") as *json::value) as bool;
};

// workspace/symbol must surface stdlib symbols even when the user has
// never navigated through the relevant module. The first call kicks
// off a full stdlib indexing job; we poll until a stdlib symbol
// becomes findable.
@test fn e2e_workspace_symbol_finds_stdlib_symbol() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	// `newscanner` lives only in stdlib (bufio). Poll up to ~10s for
	// the indexing job to populate enough of the stdlib to find it.
	// On each poll, parse the response and walk `result.items` so
	// the match has to land in an entry's `name` (and the location's
	// URI has to point at /bufio/) rather than anywhere in the raw
	// JSON body where the substring might coincidentally appear.
	let found = false;
	for (let attempt = 0z; attempt < 50z; attempt += 1) {
		const id = 1210.0 + attempt: f64;
		const tmpl = `{"jsonrpc":"2.0","id":`;
		const id_buf: [16]u8 = [0...];
		const id_str = fmt::bsprintf(id_buf, "{}", id: f64)!;
		const req =
			strings::concat(tmpl, id_str,
				`,"method":"workspace/symbol","params":{"query":"newscanner"}}`)!;
		defer free(req);
		send(&s, strings::toutf8(req));
		const body = wait_for_response(&s, id);
		defer free(body);
		const text = strings::fromutf8(body)!;
		let v = json::loadstr(text)!;
		const matched = match (v) {
		case let o: json::object =>
			yield match (json::get(&o, "result")) {
			case let p: *json::value =>
				yield match (*p) {
				case let res: json::object =>
					yield match (json::get(&res, "items")) {
					case let pi: *json::value =>
						yield match (*pi) {
						case let items: []json::value =>
							yield items_contain_bufio_newscanner(items);
						case =>
							yield false;
						};
					case void =>
						yield false;
					};
				case =>
					yield false;
				};
			case void =>
				yield false;
			};
		case =>
			yield false;
		};
		json::finish(v);
		if (matched) {
			found = true;
			break;
		};
	};
	assert(
		found,
		"workspace/symbol must eventually surface bufio::newscanner after indexing"
	);
};

// Returns true if any item in the slice has name="newscanner" and a
// location.uri that lives in stdlib's bufio module.
fn items_contain_bufio_newscanner(items: []json::value) bool = {
	for (let i = 0z; i < len(items); i += 1) {
		const it = match (items[i]) {
		case let o: json::object =>
			yield o;
		case =>
			continue;
		};
		const name = match (json::get(&it, "name")) {
		case let p: *json::value =>
			yield match (*p) {
			case let s: str =>
				yield s;
			case =>
				continue;
			};
		case void =>
			continue;
		};
		if (name != "newscanner") continue;
		const loc = match (json::get(&it, "location")) {
		case let p: *json::value =>
			yield match (*p) {
			case let o: json::object =>
				yield o;
			case =>
				continue;
			};
		case void =>
			continue;
		};
		const uri = match (json::get(&loc, "uri")) {
		case let p: *json::value =>
			yield match (*p) {
			case let s: str =>
				yield s;
			case =>
				continue;
			};
		case void =>
			continue;
		};
		if (strings::contains(uri, "/bufio/")) return true;
	};
	return false;
};

@test fn e2e_workspace_symbol_resolve_passthrough() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	// Resolve is a passthrough — feed it a synthetic WorkspaceSymbol and
	// confirm the response echoes back the same name/kind/location.
	const req =
		`{"jsonrpc":"2.0","id":1203,"method":"workspaceSymbol/resolve","params":{"name":"x","kind":12,"location":{"uri":"file:///x.ha","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1203.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	assert(
		json::get(&obj, "error") is void,
		"workspaceSymbol/resolve passthrough must not error"
	);
	// Verify the result preserved the input fields. A regression that
	// returned `null`, `{}`, or a different symbol would slip past a
	// field-presence-only check.
	const result = *(json::get(&obj, "result") as *json::value) as json::object;
	const name = *(json::get(&result, "name") as *json::value) as str;
	const kind = *(json::get(&result, "kind") as *json::value) as f64;
	const loc = *(json::get(&result, "location") as *json::value) as json::object;
	const uri = *(json::get(&loc, "uri") as *json::value) as str;
	assert(name == "x", "passthrough must preserve name");
	assert(kind == 12.0, "passthrough must preserve kind");
	assert(uri == "file:///x.ha", "passthrough must preserve location.uri");
};
