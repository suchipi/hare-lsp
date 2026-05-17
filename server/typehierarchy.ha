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
use hare::ast;
use lsp;
use strings;

// @param s: borrowed
export fn handle_prepare_type_hierarchy(s: *server, r: lsp::request) void = {
	const (uri, pos) = match (parse_pos_th(r.params)) {
	case let v: (str, lsp::position) =>
		yield v;
	case void =>
		send_array_result(s, r.id, []);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document =>
		yield p;
	case null =>
		send_array_result(s, r.id, []);
		return;
	};
	const data = analysis::bytes(&doc.buf);
	const off = analysis::position_to_byte(data, doc.buf.line_index,
		position_encoding(s),
		analysis::position { line = pos.line, character = pos.character });
	const cache = parse_of(doc);
	const sym = match (analysis::symbol_at(&cache.idx, off)) {
	case let p: *analysis::symbol =>
		yield p;
	case void =>
		send_array_result(s, r.id, []);
		return;
	};
	if (sym.kind != analysis::symbol_kind::TYPE) {
		send_array_result(s, r.id, []);
		return;
	};
	let arr: []json::value = [];
	append(arr, build_type_item(s, doc, uri, sym.short_name,
		sym.span.start.off: size, sym.span.end.off: size))!;
	send_array_result(s, r.id, arr);
};

// Returns the typeHierarchy supertypes for the given item: every named
// type referenced by the item type's underlying definition. Self
// (same uri + same name) is filtered out and within a single response
// we dedupe by (uri, name) so a name referenced by multiple distinct
// idents in the underlying doesn't produce duplicate items. Cycle
// avoidance across calls (e.g. A -> B -> A) is the client's
// responsibility - the server returns one level per call.
//
// @param s: borrowed
export fn handle_supertypes(s: *server, r: lsp::request) void = {
	const item = match (parse_item(r.params)) {
	case let v: type_item =>
		yield v;
	case void =>
		send_array_result(s, r.id, []);
		return;
	};
	defer free_type_item(item);

	// Look up the file's AST. Prefer the open-document parse cache when
	// we have it; otherwise hit the shared on-disk file_parse_cache so
	// repeated supertype queries against the same file don't re-parse.
	const su = match (load_subunit(s, item.uri)) {
	case let su: *ast::subunit =>
		yield su;
	case void =>
		send_array_result(s, r.id, []);
		return;
	};

	// Find the matching type decl.
	const decl = match (find_type_decl(su, item.name)) {
	case let d: *ast::decl =>
		yield d;
	case void =>
		send_array_result(s, r.id, []);
		return;
	};
	const underlying = match (analysis::type_decl_underlying(decl)) {
	case let t: *ast::_type =>
		yield t;
	case void =>
		send_array_result(s, r.id, []);
		return;
	};

	// Walk the underlying type, collecting referenced idents.
	let idents = analysis::collect_referenced_idents(underlying);
	defer analysis::finish_idents(idents);

	// For each referenced ident, resolve it through the file's `use`
	// list + workspace index to a single TYPE entry, rather than
	// matching every workspace entry with the same short name. This
	// keeps unrelated types in different modules from appearing linked.
	const item_path = uri_to_path_th(item.uri);
	defer free(item_path);
	const item_module = analysis::module_from_path(item_path);
	defer free(item_module);

	let arr: []json::value = [];
	let visited: [](str, str) = [];
	defer free(visited);
	for (let i = 0z; i < len(idents); i += 1) {
		const path = idents[i];
		if (len(path) == 0) continue;
		const name = path[len(path) - 1];
		// `foo::bar::baz` -> qualifier "bar" (the single-segment
		// module name workspace_entry.module records).
		const qualifier = if (len(path) >= 2) path[len(path) - 2] else "";
		const entry = match (analysis::workspace_lookup_for_subunit(
			&s.workspace_index, su, item_module, qualifier, name)) {
		case let e: *analysis::workspace_entry =>
			yield e;
		case void =>
			continue;
		};
		if (entry.kind != analysis::symbol_kind::TYPE) continue;
		if (entry.uri == item.uri && entry.short_name == item.name) continue;
		if (visited_pair_has(visited, entry.uri, entry.short_name)) continue;
		const text = match (find_document(s, entry.uri)) {
		case let d: *document =>
			yield analysis::bytes(&d.buf);
		case null =>
			yield match (cached_parse_or_drop_stale(s, entry.path)) {
			case let p: *file_parse_entry =>
				yield p.text;
			case null =>
				continue;
			};
		};
		append(arr, build_type_item_for_path(s, entry.path, entry.uri,
			entry.short_name, entry.start_off: size, entry.end_off: size, text))!;
		append(visited, (entry.uri, entry.short_name))!;
	};
	send_array_result(s, r.id, arr);
};

// Returns a borrowed pointer to the subunit for a URI. Prefers the
// open-document parse cache when the URI matches an open doc;
// otherwise consults the on-disk file_parse_cache.
//
// @param s: borrowed
// @param uri: borrowed
fn load_subunit(s: *server, uri: str) (*ast::subunit | void) = {
	match (find_document(s, uri)) {
	case let d: *document =>
		return &parse_of(d).pr.subunit;
	case null => void;
	};
	const path = uri_to_path_th(uri);
	defer free(path);
	const fpe = match (cached_parse_or_drop_stale(s, path)) {
	case let p: *file_parse_entry =>
		yield p;
	case null =>
		return void;
	};
	return &fpe.pr.subunit;
};

// Returns the typeHierarchy subtypes for the given item: every workspace
// type decl whose underlying definition references the item's name.
// Self (matching uri + name) is excluded. Within a single response we
// dedupe by (uri, name) so two decls in the same file that share a
// short_name don't both emit. Cycle avoidance across calls is the
// client's responsibility.
//
// @param s: borrowed
export fn handle_subtypes(s: *server, r: lsp::request) void = {
	const item = match (parse_item(r.params)) {
	case let v: type_item =>
		yield v;
	case void =>
		send_array_result(s, r.id, []);
		return;
	};
	defer free_type_item(item);

	// Look up the cursor's item in the workspace index so we can use
	// it as the expected target. Without this we'd be back to matching
	// by short name only.
	const item_path = uri_to_path_th(item.uri);
	defer free(item_path);
	const expected = match (find_workspace_type_entry(s, item_path, item.name)) {
	case let e: *analysis::workspace_entry =>
		yield e;
	case void =>
		// Unindexed file or fresh type: fall back to short-name
		// matching (no regression vs prior behavior).
		yield null: nullable *analysis::workspace_entry;
	};

	let arr: []json::value = [];
	let visited: [](str, str) = [];
	defer free(visited);
	let seen_paths: []str = [];
	defer free(seen_paths);
	for (let i = 0z; i < len(s.workspace_index.entries); i += 1) {
		if (i % 32 == 0 && check_cancel(s, r.id)) {
			const v: json::value = arr;
			json::finish(v);
			return;
		};
		const e = &s.workspace_index.entries[i];
		if (e.kind != analysis::symbol_kind::TYPE) continue;
		if (str_in(seen_paths, e.path)) continue;
		append(seen_paths, e.path)!;

		const fpe = match (cached_parse_or_drop_stale(s, e.path)) {
		case let p: *file_parse_entry =>
			yield p;
		case null =>
			continue;
		};

		const file_module = analysis::module_from_path(e.path);
		defer free(file_module);

		for (let j = 0z; j < len(fpe.pr.subunit.decls); j += 1) {
			const d = &fpe.pr.subunit.decls[j];
			match (d.decl) {
			case ast::decl_type => void;
			case =>
				continue;
			};
			const underlying = match (analysis::type_decl_underlying(d)) {
			case let t: *ast::_type =>
				yield t;
			case void =>
				continue;
			};
			let idents = analysis::collect_referenced_idents(underlying);
			defer analysis::finish_idents(idents);
			let matched = false;
			for (let k = 0z; k < len(idents); k += 1) {
				const path = idents[k];
				if (len(path) == 0) continue;
				if (path[len(path) - 1] != item.name) continue;
				// Short name matches; verify it resolves to the
				// same entry as the cursor's item. When we have
				// no expected entry (item not yet indexed),
				// accept the short-name match as a fallback.
				match (expected) {
				case null =>
					matched = true;
				case let exp: *analysis::workspace_entry =>
					const qualifier = if (len(path) >= 2) path[len(path) - 2] else "";
					match (analysis::workspace_lookup_for_subunit(&s.workspace_index,
						&fpe.pr.subunit, file_module, qualifier, item.name)) {
					case let r: *analysis::workspace_entry =>
						if (r.path == exp.path && r.short_name == exp.short_name &&
								r.kind == exp.kind) {
							matched = true;
						};
					case void => void;
					};
				};
				if (matched) break;
			};
			if (!matched) continue;

			const short = decl_type_short_name(d);
			if (short == "") continue;
			if (e.uri == item.uri && short == item.name) continue;
			if (visited_pair_has(visited, e.uri, short)) continue;
			const sp_off = d.loc.start.off: size;
			const ep_off = d.loc.end.off: size;
			append(arr, build_type_item_for_path(s, e.path, e.uri, short, sp_off, ep_off,
				fpe.text))!;
			append(visited, (e.uri, short))!;
		};
	};
	send_array_result(s, r.id, arr);
};

// Returns the workspace_entry for the TYPE decl at (path, name), or
// void when none exists. Used to anchor the supertypes/subtypes filter.
//
// @param s: borrowed
// @param path: borrowed
// @param name: borrowed
fn find_workspace_type_entry(
	s: *server,
	path: str,
	name: str,
) (*analysis::workspace_entry | void) = {
	for (let i = 0z; i < len(s.workspace_index.entries); i += 1) {
		const e = &s.workspace_index.entries[i];
		if (e.kind != analysis::symbol_kind::TYPE) continue;
		if (e.path != path) continue;
		if (e.short_name != name) continue;
		return e;
	};
	return void;
};

// --- helpers ---
type type_item = struct {
	name: str,
	uri: str,
};

// @param p: borrowed
fn parse_item(p: (json::value | void)) (type_item | void) = {
	const v = match (p) {
	case let v: json::value =>
		yield v;
	case void =>
		return void;
	};
	const obj = match (v) {
	case let o: json::object =>
		yield o;
	case =>
		return void;
	};
	const item = match (json::get(&obj, "item")) {
	case let p: *json::value =>
		yield match (*p) {
		case let o: json::object =>
			yield o;
		case =>
			return void;
		};
	case =>
		return void;
	};
	const name = match (json::get(&item, "name")) {
	case let p: *json::value =>
		yield match (*p) {
		case let s: str =>
			yield strings::dup(s)!;
		case =>
			return void;
		};
	case =>
		return void;
	};
	const uri = match (json::get(&item, "uri")) {
	case let p: *json::value =>
		yield match (*p) {
		case let s: str =>
			yield strings::dup(s)!;
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

// @param su: borrowed
// @param name: borrowed
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

// @param d: borrowed
fn decl_type_short_name(d: *ast::decl) str = {
	match (d.decl) {
	case let t: ast::decl_type =>
		if (len(t.ident) > 0) return t.ident[len(t.ident) - 1];
		return "";
	case =>
		return "";
	};
};

// @param uri: borrowed
fn uri_to_path_th(uri: str) str = lsp::uri_decode_path(uri);

// @param slice: borrowed
// @param needle: borrowed
fn str_in(slice: []str, needle: str) bool = {
	for (let i = 0z; i < len(slice); i += 1) {
		if (slice[i] == needle) return true;
	};
	return false;
};

// Walks workspace TYPE entries with the given short name and appends a
// TypeHierarchyItem per match into `arr`. Skips an entry if its
// (uri, name) matches `self_uri`+`self_name` (the input item) or is
// already in `visited` (this-response dedup).
//
// @param s: borrowed
// @param name: borrowed
// @param arr: borrowed
// @param visited: borrowed
// @param self_uri: borrowed
// @param self_name: borrowed
fn emit_workspace_type_items(
	s: *server,
	name: str,
	arr: *[]json::value,
	visited: *[](str, str),
	self_uri: str,
	self_name: str,
) void = {
	let cur = *arr;
	let vis = *visited;
	defer {
		*arr = cur;
		*visited = vis;
	};

	for (let i = 0z; i < len(s.workspace_index.entries); i += 1) {
		const e = &s.workspace_index.entries[i];
		if (e.kind != analysis::symbol_kind::TYPE) continue;
		if (e.short_name != name) continue;
		if (e.uri == self_uri && e.short_name == self_name) continue;
		if (visited_pair_has(vis, e.uri, e.short_name)) continue;
		// Prefer an open document's bytes if one exists for this URI;
		// otherwise use the shared on-disk parse cache.
		const text = match (find_document(s, e.uri)) {
		case let d: *document =>
			yield analysis::bytes(&d.buf);
		case null =>
			yield match (cached_parse_or_drop_stale(s, e.path)) {
			case let p: *file_parse_entry =>
				yield p.text;
			case null =>
				continue;
			};
		};
		append(cur, build_type_item_for_path(s, e.path, e.uri, name,
			e.start_off: size, e.end_off: size, text))!;
		append(vis, (e.uri, e.short_name))!;
	};
};

// Reports whether the (uri, name) pair has already been visited in this
// traversal. Linear scan: type hierarchies in Hare are shallow (a
// handful of levels at most), and each level adds one entry, so the
// O(n) cost stays well below the per-entry work below. Iterates newest-
// first because the dominant pattern is "revisit the previous frame
// while unwinding a recursion", which short-circuits on the first
// element.
//
// @param vis: borrowed
// @param uri: borrowed
// @param name: borrowed
fn visited_pair_has(vis: [](str, str), uri: str, name: str) bool = {
	for (let i = len(vis); i > 0; i -= 1) {
		const v = vis[i - 1];
		if (v.0 == uri && v.1 == name) return true;
	};
	return false;
};

// @param s: borrowed
// @param doc: borrowed
// @param uri: borrowed
// @param name: borrowed
fn build_type_item(
	s: *server,
	doc: *document,
	uri: str,
	name: str,
	start_off: size,
	end_off: size,
) json::value = {
	let item = json::newobject();
	json::set(&item, "name", name: json::value)!;
	json::put(&item, "kind", 23: f64)!; // 23 = Struct
	json::set(&item, "uri", uri: json::value)!;
	const enc = position_encoding(s);
	const data = analysis::bytes(&doc.buf);
	const sp = analysis::byte_to_position(data, doc.buf.line_index, enc,
		start_off);
	const ep = analysis::byte_to_position(data, doc.buf.line_index, enc, end_off);
	json::put(&item, "range", encode_range_th(sp, ep))!;
	// selectionRange is the identifier itself per LSP spec (so a
	// "navigate to this item" lands on the type name, not on `type`).
	const ident_off = find_ident_in_type_decl(data, start_off, end_off, name);
	const ident_len = len(strings::toutf8(name));
	const sel_sp = analysis::byte_to_position(data, doc.buf.line_index, enc,
		ident_off);
	const sel_ep = analysis::byte_to_position(data, doc.buf.line_index, enc,
		ident_off + ident_len);
	json::put(&item, "selectionRange", encode_range_th(sel_sp, sel_ep))!;
	return item;
};

// @param s: borrowed
// @param path: borrowed
// @param uri: borrowed
// @param name: borrowed
// @param text: borrowed
fn build_type_item_for_path(
	s: *server,
	path: str,
	uri: str,
	name: str,
	start_off: size,
	end_off: size,
	text: []u8,
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
	const ident_off = find_ident_in_type_decl(text, start_off, end_off, name);
	const ident_len = len(strings::toutf8(name));
	const sel_sp = analysis::byte_to_position(text, idx, enc, ident_off);
	const sel_ep = analysis::byte_to_position(text, idx, enc,
		ident_off + ident_len);
	json::put(&item, "selectionRange", encode_range_th(sel_sp, sel_ep))!;
	return item;
};

// Returns the byte offset of `name` within data[span_start..span_end]
// matched as a whole word. Falls back to `span_start` when not found,
// so a malformed decl still produces a sensible (if imprecise) range.
//
// @param data: borrowed
// @param name: borrowed
fn find_ident_in_type_decl(
	data: []u8,
	span_start: size,
	span_end: size,
	name: str,
) size = {
	const target = strings::toutf8(name);
	if (len(target) == 0) return span_start;
	const end = if (span_end > len(data)) len(data) else span_end;
	if (span_start >= end) return span_start;
	for (let i = span_start; i + len(target) <= end; i += 1) {
		let ok = true;
		for (let j = 0z; j < len(target); j += 1) {
			if (data[i + j] != target[j]) {
				ok = false;
				break;
			};
		};
		if (!ok) continue;
		if (i > span_start && is_word_byte_th(data[i - 1])) continue;
		if (i + len(target) < end && is_word_byte_th(data[i + len(target)])) continue;
		return i;
	};
	return span_start;
};

fn is_word_byte_th(b: u8) bool = {
	if (b >= 'a': u8 && b <= 'z': u8) return true;
	if (b >= 'A': u8 && b <= 'Z': u8) return true;
	if (b >= '0': u8 && b <= '9': u8) return true;
	return b == '_': u8;
};

// @param p: borrowed
fn parse_pos_th(p: (json::value | void)) ((str, lsp::position) | void) = {
	const v = match (p) {
	case let v: json::value =>
		yield v;
	case void =>
		return void;
	};
	const obj = match (v) {
	case let o: json::object =>
		yield o;
	case =>
		return void;
	};
	const td = match (json::get(&obj, "textDocument")) {
	case let p: *json::value =>
		yield match (*p) {
		case let o: json::object =>
			yield o;
		case =>
			return void;
		};
	case =>
		return void;
	};
	const uri = match (json::get(&td, "uri")) {
	case let p: *json::value =>
		yield match (*p) {
		case let s: str =>
			yield s;
		case =>
			return void;
		};
	case =>
		return void;
	};
	const pos = match (json::get(&obj, "position")) {
	case let p: *json::value =>
		yield match (lsp::decode_position(*p)) {
		case let pos: lsp::position =>
			yield pos;
		case lsp::bad_message =>
			return void;
		};
	case =>
		return void;
	};
	return (uri, pos);
};

fn encode_range_th(
	start: analysis::position,
	end: analysis::position,
) json::value = {
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
