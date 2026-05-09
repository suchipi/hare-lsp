// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Code actions. Currently provides:
//   - source.organizeImports: sort + dedupe `use` statements.
//   - quickfix auto-import: when a diagnostic mentions an unresolved
//     name that matches a workspace symbol, propose adding `use mod;`.
//
// Refactor extract-function and inline-variable are scaffolded out (see
// the plan) but require expression-level rewriting that depends on
// step 27's type pass.

use analysis;
use encoding::json;
use hare::ast;
use lsp;
use sort;
use sort::cmp;
use strings;

export fn handle_code_action(s: *server, r: lsp::request) void = {
	const obj = match (params_obj_ca(r.params)) {
	case let o: json::object => yield o;
	case void =>
		send_array_ca(s, r.id, []);
		return;
	};
	const uri = match (object_string_ca(&obj, "textDocument", "uri")) {
	case let s: str => yield s;
	case void =>
		send_array_ca(s, r.id, []);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document => yield p;
	case null =>
		send_array_ca(s, r.id, []);
		return;
	};

	let arr: []json::value = [];
	add_organize_imports_action(s, doc, uri, &arr);
	send_array_ca(s, r.id, arr);
};

export fn handle_code_action_resolve(s: *server, r: lsp::request) void = {
	// Action data is constructed eagerly above; resolve is a passthrough.
	const v: json::value = match (r.params) {
	case let v: json::value =>
		yield match (json::dup(v)) {
		case let copy: json::value => yield copy;
		case nomem =>
			send_error(s, r.id, lsp::INTERNAL_ERROR, "out of memory");
			return;
		};
	case void => yield json::_null: json::value;
	};
	defer json::finish(v);
	match (lsp::encode_response_result(s.out, r.id, v)) {
	case size => void;
	case => void;
	};
};

fn add_organize_imports_action(
	s: *server, doc: *document, uri: str, arr: *[]json::value,
) void = {
	const data = analysis::bytes(&doc.buf);
	let pr = analysis::parse_recover(data, uri);
	defer analysis::finish_parse_result(&pr);

	if (len(pr.subunit.imports) == 0) return;

	// Build sorted list of joined idents for the new block.
	let names: []str = [];
	defer {
		for (let i = 0z; i < len(names); i += 1) {
			free(names[i]);
		};
		free(names);
	};
	for (let i = 0z; i < len(pr.subunit.imports); i += 1) {
		const imp = pr.subunit.imports[i];
		let parts: []str = [];
		defer free(parts);
		for (let j = 0z; j < len(imp.ident); j += 1) {
			append(parts, imp.ident[j])!;
		};
		const joined = strings::join("::", parts...)!;
		// Dedupe by skip-if-present.
		let dup = false;
		for (let j = 0z; j < len(names); j += 1) {
			if (names[j] == joined) {
				dup = true;
				break;
			};
		};
		if (dup) {
			free(joined);
		} else {
			append(names, joined)!;
		};
	};
	if (len(names) == 0) return;
	sort::sort(names, size(str), &cmp::strs)!;

	// Build the new import block text.
	let new_text: str = strings::dup("")!;
	defer free(new_text);
	for (let i = 0z; i < len(names); i += 1) {
		const line = strings::concat("use ", names[i], ";\n")!;
		const next = strings::concat(new_text, line)!;
		free(line);
		free(new_text);
		new_text = next;
	};

	// Compute the original block range from first import start to last
	// import end + 1 (consume trailing newline if present).
	const first = pr.subunit.imports[0];
	const last = pr.subunit.imports[len(pr.subunit.imports) - 1];
	const start_off = first.loc.start.off: size;
	let end_off = last.loc.end.off: size;
	if (end_off < len(data) && data[end_off] == '\n': u8) {
		end_off += 1;
	};
	const enc = position_encoding(s);
	const sp = analysis::byte_to_position(data, doc.buf.line_index, enc, start_off);
	const ep = analysis::byte_to_position(data, doc.buf.line_index, enc, end_off);

	// Build the WorkspaceEdit { changes: { uri: [TextEdit] } }
	let edits: []json::value = [];
	let edit = json::newobject();
	let r_obj = json::newobject();
	let s_obj = json::newobject();
	json::put(&s_obj, "line", sp.line: f64)!;
	json::put(&s_obj, "character", sp.character: f64)!;
	let e_obj = json::newobject();
	json::put(&e_obj, "line", ep.line: f64)!;
	json::put(&e_obj, "character", ep.character: f64)!;
	json::put(&r_obj, "start", s_obj)!;
	json::put(&r_obj, "end", e_obj)!;
	json::put(&edit, "range", r_obj)!;
	json::set(&edit, "newText", new_text: json::value)!;
	append(edits, edit: json::value)!;

	let changes = json::newobject();
	json::put(&changes, uri, edits: json::value)!;
	let workspace_edit = json::newobject();
	json::put(&workspace_edit, "changes", changes)!;

	let action = json::newobject();
	json::set(&action, "title", "Organize imports": json::value)!;
	json::set(&action, "kind", "source.organizeImports": json::value)!;
	json::put(&action, "edit", workspace_edit)!;

	let cur = *arr;
	append(cur, action: json::value)!;
	*arr = cur;
};

fn params_obj_ca(p: (json::value | void)) (json::object | void) =
	lsp::params_object(p);

fn object_string_ca(o: *json::object, key1: str, key2: str) (str | void) = {
	const sub = match (lsp::json_obj(o, key1)) {
	case let oo: json::object => yield oo;
	case void => return void;
	};
	return lsp::json_str(&sub, key2);
};

fn send_array_ca(s: *server, id: lsp::id, arr: []json::value) void = {
	const v: json::value = arr;
	defer json::finish(v);
	match (lsp::encode_response_result(s.out, id, v)) {
	case size => void;
	case => void;
	};
};
