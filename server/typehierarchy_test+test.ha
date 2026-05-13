// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use analysis;
use bufio;
use bytes;
use encoding::json;
use fs;
use io;
use lsp;
use memio;
use os;
use strconv;
use strings;

fn th_test_server(

) (server, *bufio::scanner, *memio::stream, *memio::stream) = {
	let in_buf = alloc(memio::fixed([]))!;
	let scan = alloc(bufio::newscanner(in_buf))!;
	let out = alloc(memio::dynamic())!;
	let s = new(scan, out, void);
	return (s, scan, in_buf, out);
};

fn th_test_cleanup(
	s: *server,
	scan: *bufio::scanner,
	in_buf: *memio::stream,
	out: *memio::stream,
) void = {
	finish(s);
	bufio::finish(scan);
	free(scan);
	free(in_buf);
	io::close(out)!;
	free(out);
};

fn th_open(s: *server, uri: str, text: str) void = {
	const open =
		strings::concat(`{"textDocument":{"uri":"`, uri,
			`","languageId":"hare","version":1,"text":"`, text, `"}}`)!;
	defer free(open);
	let pv = json::loadstr(open)!;
	const n = lsp::notification {
		method = strings::dup("textDocument/didOpen")!,
		params = pv,
	};
	defer {
		free(n.method);
		json::finish(pv);
	};
	handle_did_open(s, n);
};

fn th_skip_to_response(out: *memio::stream, request_id: f64) json::value = {
	const data = memio::buffer(out);
	let off = 0z;
	for (off < len(data)) {
		const sep = bytes::index(data[off..], strings::toutf8("\r\n\r\n")) as size;
		const headers = strings::fromutf8(data[off..off + sep])!;
		let length: size = 0;
		const lines = strings::split(headers, "\r\n")!;
		defer free(lines);
		for (let i = 0z; i < len(lines); i += 1) {
			const idx = strings::index(lines[i], ':') as size;
			const name = strings::sub(lines[i], 0, idx);
			const value = strings::trim(strings::sub(lines[i], idx + 1, strings::end));
			if (name == "Content-Length") {
				length = strconv::stoz(value)!;
			};
		};
		const body_start = off + sep + 4;
		const body = data[body_start..body_start + length];
		const v = json::loadstr(strings::fromutf8(body)!)!;
		const obj = v as json::object;
		match (json::get(&obj, "id")) {
		case let p: *json::value =>
			match (*p) {
			case let f: f64 =>
				if (f == request_id) return v;
			case => void;
			};
		case => void;
		};
		json::finish(v);
		off = body_start + length;
	};
	abort("response not found");
};

// Indexes a fake file directly into the workspace index.
fn th_index(s: *server, path: str, text: str) void = {
	analysis::index_file(&s.workspace_index, path, strings::toutf8(text));
};

@test fn supertypes_of_alias_returns_underlying_type() void = {
	let (s, scan, in_buf, out) = th_test_server();
	defer th_test_cleanup(&s, scan, in_buf, out);

	// Create a workspace where A = B and B = int.
	// Both decls live in /repo/x.ha.
	const text = "type A = B;\\ntype B = int;\\n";
	th_open(&s, "file:///repo/x.ha", text);
	// Also index it so subtypes can find it.
	th_index(&s, "/repo/x.ha", "type A = B;\ntype B = int;\n");

	const params =
		`{"item":{"name":"A","kind":23,"uri":"file:///repo/x.ha","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":11}},"selectionRange":{"start":{"line":0,"character":0},"end":{"line":0,"character":11}}}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 1.0,
		method = strings::dup("typeHierarchy/supertypes")!,
		params = pv,
	};
	defer free(r.method);
	handle_supertypes(&s, r);
	const v = th_skip_to_response(out, 1.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	// Expect at least one item (B).
	assert(len(result) >= 1);
	let found_b = false;
	for (let i = 0z; i < len(result); i += 1) {
		const item = result[i] as json::object;
		const n = *(json::get(&item, "name") as *json::value) as str;
		if (n == "B") found_b = true;
	};
	assert(found_b);
};

@test fn subtypes_of_underlying_returns_alias() void = {
	let (s, scan, in_buf, out) = th_test_server();
	defer th_test_cleanup(&s, scan, in_buf, out);

	// Build a file on disk so the subtypes scan can find it.
	// We use the .tmp dir per project rules.
	const path = ".tmp/hare-lsp-th-subtypes-test.ha";
	const text = "type Wrapper = Inner;\ntype Inner = int;\n";
	let f = match (writefile(path, text)) {
	case bool =>
		yield true;
	case => abort("cannot write fixture");
	};
	defer rmfile(path);

	th_index(&s, path, text);

	// Ask: what are Inner's subtypes? Expect Wrapper.
	const params_str =
		strings::concat(`{"item":{"name":"Inner","kind":23,"uri":"file://`, path,
			`","range":{"start":{"line":1,"character":0},"end":{"line":1,"character":17}},"selectionRange":{"start":{"line":1,"character":0},"end":{"line":1,"character":17}}}}`
		)!;
	defer free(params_str);
	let pv = json::loadstr(params_str)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 2.0,
		method = strings::dup("typeHierarchy/subtypes")!,
		params = pv,
	};
	defer free(r.method);
	handle_subtypes(&s, r);
	const v = th_skip_to_response(out, 2.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	let found_wrapper = false;
	for (let i = 0z; i < len(result); i += 1) {
		const item = result[i] as json::object;
		const n = *(json::get(&item, "name") as *json::value) as str;
		if (n == "Wrapper") found_wrapper = true;
	};
	assert(found_wrapper);
};

@test fn supertypes_of_tagged_union_lists_variants() void = {
	let (s, scan, in_buf, out) = th_test_server();
	defer th_test_cleanup(&s, scan, in_buf, out);

	// type T = (A | B); type A = int; type B = str;
	const path = ".tmp/hare-lsp-th-tagged-test.ha";
	const text = "type T = (A | B);\ntype A = int;\ntype B = str;\n";
	let _ = match (writefile(path, text)) {
	case bool =>
		yield true;
	case => abort("cannot write fixture");
	};
	defer rmfile(path);

	th_index(&s, path, text);
	th_open(&s, "file://.tmp/hare-lsp-th-tagged-test.ha",
		"type T = (A | B);\\ntype A = int;\\ntype B = str;\\n");

	const params_str =
		strings::concat(`{"item":{"name":"T","kind":23,"uri":"file://`, path,
			`","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":17}},"selectionRange":{"start":{"line":0,"character":0},"end":{"line":0,"character":17}}}}`
		)!;
	defer free(params_str);
	let pv = json::loadstr(params_str)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 3.0,
		method = strings::dup("typeHierarchy/supertypes")!,
		params = pv,
	};
	defer free(r.method);
	handle_supertypes(&s, r);
	const v = th_skip_to_response(out, 3.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	let found_a = false, found_b = false;
	for (let i = 0z; i < len(result); i += 1) {
		const item = result[i] as json::object;
		const n = *(json::get(&item, "name") as *json::value) as str;
		if (n == "A") found_a = true;
		if (n == "B") found_b = true;
	};
	assert(found_a);
	assert(found_b);
};

// A self-referential type (e.g. type Node = struct { next: *Node; })
// must not return itself in supertypes - that would cause clients
// walking the hierarchy to recurse forever.
@test fn supertypes_skip_self_for_self_referential_type() void = {
	let (s, scan, in_buf, out) = th_test_server();
	defer th_test_cleanup(&s, scan, in_buf, out);

	const text = "type Node = struct { next: *Node };\\n";
	th_open(&s, "file:///repo/self.ha", text);
	th_index(&s, "/repo/self.ha", "type Node = struct { next: *Node };\n");

	const params =
		`{"item":{"name":"Node","kind":23,"uri":"file:///repo/self.ha","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":35}},"selectionRange":{"start":{"line":0,"character":0},"end":{"line":0,"character":35}}}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 10.0,
		method = strings::dup("typeHierarchy/supertypes")!,
		params = pv,
	};
	defer free(r.method);
	handle_supertypes(&s, r);
	const v = th_skip_to_response(out, 10.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	// The only ident referenced by Node's underlying is Node itself,
	// which we filter out. Result should be empty.
	for (let i = 0z; i < len(result); i += 1) {
		const item = result[i] as json::object;
		const n = *(json::get(&item, "name") as *json::value) as str;
		const u = *(json::get(&item, "uri") as *json::value) as str;
		assert(!(n == "Node" && u == "file:///repo/self.ha"));
	};
};

// A self-referential subtype query (e.g. asking for subtypes of the
// type itself) must not include the input item in the result.
@test fn subtypes_skip_self_when_underlying_refs_self() void = {
	let (s, scan, in_buf, out) = th_test_server();
	defer th_test_cleanup(&s, scan, in_buf, out);

	const path = ".tmp/hare-lsp-th-self-ref-subtypes.ha";
	const text = "type Node = struct { next: *Node };\n";
	let _ = match (writefile(path, text)) {
	case bool =>
		yield true;
	case => abort("cannot write fixture");
	};
	defer rmfile(path);

	th_index(&s, path, text);

	const params_str =
		strings::concat(`{"item":{"name":"Node","kind":23,"uri":"file://`, path,
			`","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":35}},"selectionRange":{"start":{"line":0,"character":0},"end":{"line":0,"character":35}}}}`
		)!;
	defer free(params_str);
	let pv = json::loadstr(params_str)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 11.0,
		method = strings::dup("typeHierarchy/subtypes")!,
		params = pv,
	};
	defer free(r.method);
	handle_subtypes(&s, r);
	const v = th_skip_to_response(out, 11.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	// Node refs itself; expect no items returned (filtered as self).
	assert(len(result) == 0);
};

// When two distinct workspace entries match a referenced ident, both
// should appear - they are different types - but the same (uri, name)
// must not be emitted twice from a single response.
@test fn supertypes_dedupes_within_single_response() void = {
	let (s, scan, in_buf, out) = th_test_server();
	defer th_test_cleanup(&s, scan, in_buf, out);

	// Type T has underlying that references B twice (e.g. T = (B | B)).
	// `collect_referenced_idents` already dedupes the ident list, but
	// our visited-set is a belt-and-braces check.
	const text = "type T = (B | B);\\ntype B = int;\\n";
	th_open(&s, "file:///repo/dup.ha", text);
	th_index(&s, "/repo/dup.ha", "type T = (B | B);\ntype B = int;\n");

	const params =
		`{"item":{"name":"T","kind":23,"uri":"file:///repo/dup.ha","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":17}},"selectionRange":{"start":{"line":0,"character":0},"end":{"line":0,"character":17}}}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 12.0,
		method = strings::dup("typeHierarchy/supertypes")!,
		params = pv,
	};
	defer free(r.method);
	handle_supertypes(&s, r);
	const v = th_skip_to_response(out, 12.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	let count_b = 0;
	for (let i = 0z; i < len(result); i += 1) {
		const item = result[i] as json::object;
		const n = *(json::get(&item, "name") as *json::value) as str;
		if (n == "B") count_b += 1;
	};
	assert(count_b == 1);
};

// Two TYPE decls with the same short name in different modules must not
// be conflated. When asking for supertypes of mod_a's `T = X;` where
// each module declares its own `X`, only mod_a's `X` should appear.
@test fn supertypes_distinguish_same_name_across_modules() void = {
	let (s, scan, in_buf, out) = th_test_server();
	defer th_test_cleanup(&s, scan, in_buf, out);

	const a_path = ".tmp/hare-lsp-th-crossmod-supertypes-a.ha";
	const b_path = ".tmp/hare-lsp-th-crossmod-supertypes-b.ha";
	// Both files declare `X`. mod_a's file has `type T = X;` so the
	// supertypes walk should pick mod_a's X — never mod_b's.
	const a_text = "type T = X;\ntype X = int;\n";
	const b_text = "type X = str;\n";
	// The path layout determines module: ".tmp/mod_a/x.ha" -> module
	// "mod_a". Use directories so module_from_path returns distinct values.
	const a_dir = ".tmp/hare-lsp-th-crossmod-st-mod_a";
	const b_dir = ".tmp/hare-lsp-th-crossmod-st-mod_b";
	match (os::mkdirs(a_dir, 0o755)) {
	case => void;
	};
	match (os::mkdirs(b_dir, 0o755)) {
	case => void;
	};
	const a_real = strings::concat(a_dir, "/x.ha")!;
	defer free(a_real);
	const b_real = strings::concat(b_dir, "/x.ha")!;
	defer free(b_real);
	let _ = match (writefile(a_real, a_text)) {
	case bool =>
		yield true;
	case => abort("cannot write fixture");
	};
	defer rmfile(a_real);
	let _ = match (writefile(b_real, b_text)) {
	case bool =>
		yield true;
	case => abort("cannot write fixture");
	};
	defer rmfile(b_real);
	th_index(&s, a_real, a_text);
	th_index(&s, b_real, b_text);

	const a_uri = strings::concat("file://", a_real)!;
	defer free(a_uri);
	const params =
		strings::concat(`{"item":{"name":"T","kind":23,"uri":"`, a_uri,
			`","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":11}},"selectionRange":{"start":{"line":0,"character":0},"end":{"line":0,"character":11}}}}`
		)!;
	defer free(params);
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 20.0,
		method = strings::dup("typeHierarchy/supertypes")!,
		params = pv,
	};
	defer free(r.method);
	handle_supertypes(&s, r);
	const v = th_skip_to_response(out, 20.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	// Exactly one supertype: X from mod_a's file. mod_b's X must not appear.
	assert(
		len(result) == 1,
		"supertypes should return exactly the in-module match"
	);
	const item = result[0] as json::object;
	const item_uri = *(json::get(&item, "uri") as *json::value) as str;
	assert(
		strings::contains(item_uri, "mod_a"),
		"supertype must be from the cursor's module, not the unrelated same-named one"
	);
};

// Same fixture for subtypes: asking for subtypes of mod_a's `X` returns
// only mod_a's `T`, never any unrelated type in mod_b that references a
// short name `X`.
@test fn subtypes_distinguish_same_name_across_modules() void = {
	let (s, scan, in_buf, out) = th_test_server();
	defer th_test_cleanup(&s, scan, in_buf, out);

	const a_dir = ".tmp/hare-lsp-th-crossmod-sb-mod_a";
	const b_dir = ".tmp/hare-lsp-th-crossmod-sb-mod_b";
	match (os::mkdirs(a_dir, 0o755)) {
	case => void;
	};
	match (os::mkdirs(b_dir, 0o755)) {
	case => void;
	};
	const a_real = strings::concat(a_dir, "/x.ha")!;
	defer free(a_real);
	const b_real = strings::concat(b_dir, "/x.ha")!;
	defer free(b_real);
	// mod_a has `T` which references its own `X`. mod_b has `U` which
	// references a *different* `X` (its own). Only mod_a's `T` should be
	// reported as a subtype of mod_a's `X`.
	const a_text = "type T = X;\ntype X = int;\n";
	const b_text = "type U = X;\ntype X = str;\n";
	let _ = match (writefile(a_real, a_text)) {
	case bool =>
		yield true;
	case => abort("cannot write fixture");
	};
	defer rmfile(a_real);
	let _ = match (writefile(b_real, b_text)) {
	case bool =>
		yield true;
	case => abort("cannot write fixture");
	};
	defer rmfile(b_real);
	th_index(&s, a_real, a_text);
	th_index(&s, b_real, b_text);

	const a_uri = strings::concat("file://", a_real)!;
	defer free(a_uri);
	// Cursor on mod_a's X (line 1).
	const params =
		strings::concat(`{"item":{"name":"X","kind":23,"uri":"`, a_uri,
			`","range":{"start":{"line":1,"character":0},"end":{"line":1,"character":13}},"selectionRange":{"start":{"line":1,"character":0},"end":{"line":1,"character":13}}}}`
		)!;
	defer free(params);
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 21.0,
		method = strings::dup("typeHierarchy/subtypes")!,
		params = pv,
	};
	defer free(r.method);
	handle_subtypes(&s, r);
	const v = th_skip_to_response(out, 21.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	// Only mod_a's `T` should appear.
	for (let i = 0z; i < len(result); i += 1) {
		const item = result[i] as json::object;
		const item_uri = *(json::get(&item, "uri") as *json::value) as str;
		const item_name = *(json::get(&item, "name") as *json::value) as str;
		assert(
			strings::contains(item_uri, "mod_a"),
			"subtypes must not include candidates from the unrelated same-named module"
		);
		assert(item_name == "T", "subtype must be `T`, not `U` from mod_b");
	};
	assert(len(result) == 1, "subtypes should return exactly the in-module match");
};

// --- file fixture helpers ---
fn writefile(path: str, text: str) (bool | fs::error) = {
	const f = os::create(path, 0o644)?;
	defer io::close(f)!;
	io::writeall(f, strings::toutf8(text))!;
	return true;
};

fn rmfile(path: str) void = {
	match (os::remove(path)) {
	case => void;
	};
};
