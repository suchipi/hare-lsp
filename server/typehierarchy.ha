// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Type hierarchy. Hare doesn't have inheritance; the meaningful structural
// relationships are:
//
//   - Tagged unions: variants are "sub" of the union, the union is "super"
//     of each variant.
//   - Type aliases: the underlying named type is a "super" of the alias;
//     the alias is a "sub" of its underlying type.
//
// We implement both by re-parsing the relevant files, extracting the
// underlying ast::_type for the named type, and walking it via
// analysis::collect_referenced_idents.

use analysis;
use encoding::json;
use fs;
use hare::ast;
use io;
use lsp;
use os;
use strings;

export fn handle_prepare_type_hierarchy(s: *server, r: lsp::request) void = {
	const (uri, pos) = match (parse_pos_th(r.params)) {
	case let v: (str, lsp::position) => yield v;
	case void =>
		send_array_th(s, r.id, []);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document => yield p;
	case null =>
		send_array_th(s, r.id, []);
		return;
	};
	const data = analysis::bytes(&doc.buf);
	const off = analysis::position_to_byte(data, doc.buf.line_index,
		position_encoding(s),
		analysis::position { line = pos.line, character = pos.character });
	let pr = analysis::parse_recover(data, uri);
	defer analysis::finish_parse_result(&pr);
	let idx = analysis::build_index(&pr.subunit);
	defer analysis::finish_index(&idx);
	const sym = match (analysis::symbol_at(&idx, off)) {
	case let p: *analysis::symbol => yield p;
	case void =>
		send_array_th(s, r.id, []);
		return;
	};
	if (sym.kind != analysis::symbol_kind::TYPE) {
		send_array_th(s, r.id, []);
		return;
	};
	let arr: []json::value = [];
	append(arr, build_type_item(s, doc, uri, sym.short_name,
		sym.span.start.off: size, sym.span.end.off: size))!;
	send_array_th(s, r.id, arr);
};

// Returns the typeHierarchy supertypes for the given item: every named
// type referenced by the item type's underlying definition.
export fn handle_supertypes(s: *server, r: lsp::request) void = {
	const item = match (parse_item(r.params)) {
	case let v: type_item => yield v;
	case void =>
		send_array_th(s, r.id, []);
		return;
	};
	defer free_type_item(item);

	// Re-parse the source file to get the AST.
	const text = match (load_file_text(s, item.uri)) {
	case let t: []u8 => yield t;
	case void =>
		send_array_th(s, r.id, []);
		return;
	};
	defer free(text);
	let pr = analysis::parse_recover(text, item.uri);
	defer analysis::finish_parse_result(&pr);

	// Find the matching type decl.
	const decl = match (find_type_decl(&pr.subunit, item.name)) {
	case let d: *ast::decl => yield d;
	case void =>
		send_array_th(s, r.id, []);
		return;
	};
	const underlying = match (analysis::type_decl_underlying(decl)) {
	case let t: *ast::_type => yield t;
	case void =>
		send_array_th(s, r.id, []);
		return;
	};

	// Walk the underlying type, collecting referenced idents.
	let idents = analysis::collect_referenced_idents(underlying);
	defer analysis::finish_idents(idents);

	// For each referenced ident, look up its TYPE entries in the workspace
	// and emit one TypeHierarchyItem per match.
	let arr: []json::value = [];
	for (let i = 0z; i < len(idents); i += 1) {
		if (len(idents[i]) == 0) continue;
		const short = idents[i][len(idents[i]) - 1];
		emit_workspace_type_items(s, short, &arr);
	};
	send_array_th(s, r.id, arr);
};

// Returns the typeHierarchy subtypes for the given item: every workspace
// type decl whose underlying definition references the item's name.
export fn handle_subtypes(s: *server, r: lsp::request) void = {
	const item = match (parse_item(r.params)) {
	case let v: type_item => yield v;
	case void =>
		send_array_th(s, r.id, []);
		return;
	};
	defer free_type_item(item);

	let arr: []json::value = [];
	// Group workspace TYPE entries by file so we re-parse each file once.
	let seen_paths: []str = [];
	defer free(seen_paths);
	for (let i = 0z; i < len(s.workspace_index.entries); i += 1) {
		const e = &s.workspace_index.entries[i];
		if (e.kind != analysis::symbol_kind::TYPE) continue;
		if (str_in(seen_paths, e.path)) continue;
		append(seen_paths, e.path)!;

		const text = match (read_file_bytes(e.path)) {
		case let t: []u8 => yield t;
		case void => continue;
		};
		defer free(text);
		let pr = analysis::parse_recover(text, e.path);
		defer analysis::finish_parse_result(&pr);

		// For each type decl in this file, check whether its underlying
		// type references item.name.
		for (let j = 0z; j < len(pr.subunit.decls); j += 1) {
			const d = &pr.subunit.decls[j];
			match (d.decl) {
			case ast::decl_type =>
				void;
			case => continue;
			};
			const underlying = match (analysis::type_decl_underlying(d)) {
			case let t: *ast::_type => yield t;
			case void => continue;
			};
			let idents = analysis::collect_referenced_idents(underlying);
			defer analysis::finish_idents(idents);
			let matched = false;
			for (let k = 0z; k < len(idents); k += 1) {
				if (len(idents[k]) == 0) continue;
				if (idents[k][len(idents[k]) - 1] == item.name) {
					matched = true;
					break;
				};
			};
			if (!matched) continue;

			// Build an item for this decl. Need its short_name and span.
			const short = decl_type_short_name(d);
			if (short == "") continue;
			if (short == item.name) continue; // skip self
			const sp_off = d.loc.start.off: size;
			const ep_off = d.loc.end.off: size;
			append(arr, build_type_item_for_path(s, e.path,
				e.uri, short, sp_off, ep_off, text))!;
		};
	};
	send_array_th(s, r.id, arr);
};

// --- helpers ---

type type_item = struct {
	name: str,
	uri: str,
};

fn parse_item(p: (json::value | void)) (type_item | void) = {
	const v = match (p) {
	case let v: json::value => yield v;
	case void => return void;
	};
	const obj = match (v) {
	case let o: json::object => yield o;
	case => return void;
	};
	const item = match (json::get(&obj, "item")) {
	case let p: *json::value =>
		yield match (*p) {
		case let o: json::object => yield o;
		case => return void;
		};
	case => return void;
	};
	const name = match (json::get(&item, "name")) {
	case let p: *json::value =>
		yield match (*p) {
		case let s: str => yield strings::dup(s)!;
		case => return void;
		};
	case => return void;
	};
	const uri = match (json::get(&item, "uri")) {
	case let p: *json::value =>
		yield match (*p) {
		case let s: str => yield strings::dup(s)!;
		case =>
			free(name);
			return void;
		};
	case =>
		free(name);
		return void;
	};
	return type_item { name = name, uri = uri };
};

fn free_type_item(t: type_item) void = {
	free(t.name);
	free(t.uri);
};

fn find_type_decl(su: *ast::subunit, name: str) (*ast::decl | void) = {
	for (let i = 0z; i < len(su.decls); i += 1) {
		const d = &su.decls[i];
		match (d.decl) {
		case let t: ast::decl_type =>
			if (len(t.ident) > 0 && t.ident[len(t.ident) - 1] == name) {
				return d;
			};
		case => void;
		};
	};
	return void;
};

fn decl_type_short_name(d: *ast::decl) str = {
	match (d.decl) {
	case let t: ast::decl_type =>
		if (len(t.ident) > 0) return t.ident[len(t.ident) - 1];
		return "";
	case => return "";
	};
};

fn load_file_text(s: *server, uri: str) ([]u8 | void) = {
	// Prefer an open document if we have one (more up-to-date than disk).
	match (find_document(s, uri)) {
	case let d: *document =>
		const cur = analysis::bytes(&d.buf);
		let copy: []u8 = alloc([], len(cur))!;
		append(copy, cur...)!;
		return copy;
	case null => void;
	};
	// Strip file:// and read from disk.
	const path = uri_to_path_th(uri);
	defer free(path);
	return read_file_bytes(path);
};

fn read_file_bytes(path: str) ([]u8 | void) = {
	const f = match (os::open(path)) {
	case let f: io::file => yield f;
	case fs::error => return void;
	};
	defer lsp::safe_close(f);
	let buf: []u8 = [];
	let chunk: [4096]u8 = [0...];
	for (true) {
		match (io::read(f, chunk[..])) {
		case let n: size =>
			append(buf, chunk[..n]...)!;
		case io::EOF =>
			break;
		case io::error =>
			break;
		};
	};
	return buf;
};

fn uri_to_path_th(uri: str) str = {
	const prefix = "file://";
	if (strings::hasprefix(uri, prefix)) {
		return strings::dup(strings::sub(uri, len(prefix), strings::end))!;
	};
	return strings::dup(uri)!;
};

fn str_in(slice: []str, needle: str) bool = {
	for (let i = 0z; i < len(slice); i += 1) {
		if (slice[i] == needle) return true;
	};
	return false;
};

// Walks workspace TYPE entries with the given short name and appends a
// TypeHierarchyItem per match into `arr`.
fn emit_workspace_type_items(s: *server, name: str, arr: *[]json::value) void = {
	let cur = *arr;
	for (let i = 0z; i < len(s.workspace_index.entries); i += 1) {
		const e = &s.workspace_index.entries[i];
		if (e.kind != analysis::symbol_kind::TYPE) continue;
		if (e.short_name != name) continue;
		// Prefer an open document's text if one exists for this URI.
		const text = match (load_file_text(s, e.uri)) {
		case let t: []u8 => yield t;
		case void => continue;
		};
		defer free(text);
		append(cur, build_type_item_for_path(s, e.path, e.uri,
			name, e.start_off: size, e.end_off: size, text))!;
	};
	*arr = cur;
};

fn build_type_item(
	s: *server, doc: *document, uri: str, name: str,
	start_off: size, end_off: size,
) json::value = {
	let item = json::newobject();
	json::set(&item, "name", name: json::value)!;
	json::put(&item, "kind", 23: f64)!; // 23 = Struct
	json::set(&item, "uri", uri: json::value)!;
	const enc = position_encoding(s);
	const data = analysis::bytes(&doc.buf);
	const sp = analysis::byte_to_position(data, doc.buf.line_index, enc, start_off);
	const ep = analysis::byte_to_position(data, doc.buf.line_index, enc, end_off);
	json::put(&item, "range", encode_range_th(sp, ep))!;
	json::put(&item, "selectionRange", encode_range_th(sp, ep))!;
	return item;
};

fn build_type_item_for_path(
	s: *server, path: str, uri: str, name: str,
	start_off: size, end_off: size, text: []u8,
) json::value = {
	let item = json::newobject();
	json::set(&item, "name", name: json::value)!;
	json::put(&item, "kind", 23: f64)!;
	json::set(&item, "uri", uri: json::value)!;
	// Build a line index for the file text so we can convert offsets
	// to LSP positions.
	const idx = analysis::build_line_index(text);
	defer free(idx);
	const enc = position_encoding(s);
	const sp = analysis::byte_to_position(text, idx, enc, start_off);
	const ep = analysis::byte_to_position(text, idx, enc, end_off);
	json::put(&item, "range", encode_range_th(sp, ep))!;
	json::put(&item, "selectionRange", encode_range_th(sp, ep))!;
	return item;
};

fn parse_pos_th(p: (json::value | void)) ((str, lsp::position) | void) = {
	const v = match (p) {
	case let v: json::value => yield v;
	case void => return void;
	};
	const obj = match (v) {
	case let o: json::object => yield o;
	case => return void;
	};
	const td = match (json::get(&obj, "textDocument")) {
	case let p: *json::value =>
		yield match (*p) {
		case let o: json::object => yield o;
		case => return void;
		};
	case => return void;
	};
	const uri = match (json::get(&td, "uri")) {
	case let p: *json::value =>
		yield match (*p) {
		case let s: str => yield s;
		case => return void;
		};
	case => return void;
	};
	const pos = match (json::get(&obj, "position")) {
	case let p: *json::value =>
		yield match (lsp::decode_position(*p)) {
		case let pos: lsp::position => yield pos;
		case lsp::bad_message => return void;
		};
	case => return void;
	};
	return (uri, pos);
};

fn encode_range_th(start: analysis::position, end: analysis::position) json::value = {
	let r = json::newobject();
	let s_obj = json::newobject();
	json::put(&s_obj, "line", start.line: f64)!;
	json::put(&s_obj, "character", start.character: f64)!;
	let e_obj = json::newobject();
	json::put(&e_obj, "line", end.line: f64)!;
	json::put(&e_obj, "character", end.character: f64)!;
	json::put(&r, "start", s_obj)!;
	json::put(&r, "end", e_obj)!;
	return r;
};

fn send_array_th(s: *server, id: lsp::id, arr: []json::value) void = {
	const v: json::value = arr;
	defer json::finish(v);
	match (lsp::encode_response_result(s.out, id, v)) {
	case size => void;
	case => void;
	};
};
