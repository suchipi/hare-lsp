// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Code actions. Provides:
//   - source.organizeImports: sort + dedupe `use` statements.

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
	const cache = parse_of(doc);
	const pr = &cache.pr;

	if (len(pr.subunit.imports) == 0) return;

	// Render each import to its `use ...;` source form, preserving the
	// bindings variant (alias / member list / wildcard). Then sort by
	// the rendered text and dedupe equal lines. Sorting by text gives
	// a stable ordering that still respects Hare conventions:
	//   use bar = foo;
	//   use foo;
	//   use foo::*;
	//   use foo::{a, b};
	let lines: []str = [];
	defer {
		for (let i = 0z; i < len(lines); i += 1) {
			free(lines[i]);
		};
		free(lines);
	};
	for (let i = 0z; i < len(pr.subunit.imports); i += 1) {
		const rendered = render_import(&pr.subunit.imports[i]);
		let dup = false;
		for (let j = 0z; j < len(lines); j += 1) {
			if (lines[j] == rendered) {
				dup = true;
				break;
			};
		};
		if (dup) {
			free(rendered);
		} else {
			append(lines, rendered)!;
		};
	};
	if (len(lines) == 0) return;
	sort::sort(lines, size(str), &cmp::strs)!;

	// Build the new import block text.
	let new_text: str = strings::dup("")!;
	defer free(new_text);
	for (let i = 0z; i < len(lines); i += 1) {
		const with_nl = strings::concat(lines[i], "\n")!;
		const next = strings::concat(new_text, with_nl)!;
		free(with_nl);
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

// Renders a single import back to source form, preserving the bindings
// variant. The returned string is freshly allocated; the caller frees it.
//
//   use foo;            (void bindings)
//   use foo = bar::baz; (import_alias — Hare syntax puts the alias first)
//   use foo::{a, b};    (import_members)
//   use foo::*;         (import_wildcard)
fn render_import(imp: *ast::import) str = {
	let parts: []str = [];
	defer free(parts);
	for (let i = 0z; i < len(imp.ident); i += 1) {
		append(parts, imp.ident[i])!;
	};
	const joined = strings::join("::", parts...)!;
	defer free(joined);

	match (imp.bindings) {
	case void =>
		return strings::concat("use ", joined, ";")!;
	case let alias: ast::import_alias =>
		return strings::concat("use ", alias, " = ", joined, ";")!;
	case let members: ast::import_members =>
		// Sort member list deterministically for organize-imports.
		let members_copy: []str = [];
		defer free(members_copy);
		for (let i = 0z; i < len(members); i += 1) {
			append(members_copy, members[i])!;
		};
		sort::sort(members_copy, size(str), &cmp::strs)!;
		const inner = strings::join(", ", members_copy...)!;
		defer free(inner);
		return strings::concat("use ", joined, "::{", inner, "};")!;
	case ast::import_wildcard =>
		return strings::concat("use ", joined, "::*;")!;
	};
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
