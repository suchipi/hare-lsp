// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Document symbols, folding ranges, selection ranges, document highlights,
// document links — all AST-walk features that share infrastructure.

use analysis;
use bytes;
use encoding::json;
use hare::ast;
use hare::module;
use lsp;
use strings;

// LSP SymbolKind values used here.
def SK_FILE: f64 = 1.0;

def SK_NAMESPACE: f64 = 3.0;

def SK_ENUM: f64 = 10.0;

def SK_FUNCTION: f64 = 12.0;

def SK_VARIABLE: f64 = 13.0;

def SK_CONSTANT: f64 = 14.0;

def SK_OBJECT: f64 = 19.0;

def SK_ENUM_MEMBER: f64 = 22.0;

def SK_STRUCT: f64 = 23.0;

def SK_TYPE_PARAMETER: f64 = 26.0;

def SK_FIELD: f64 = 8.0;

// Handles textDocument/documentSymbol. Returns the hierarchical
// `DocumentSymbol[]` shape (struct fields nested under the struct decl,
// enum variants nested under the enum decl, etc.) when the client
// advertises `hierarchicalDocumentSymbolSupport`; otherwise falls back
// to the legacy flat `SymbolInformation[]` list one entry per top-level
// decl.
//
// @param s: borrowed
export fn handle_document_symbol(s: *server, r: lsp::request) void = {
	const uri = match (uri_from_textdoc_request(r.params)) {
	case let s: str =>
		yield s;
	case void =>
		send_empty_array(s, r.id);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document =>
		yield p;
	case null =>
		send_empty_array(s, r.id);
		return;
	};

	const data = analysis::bytes(&doc.buf);
	const cache = parse_of(doc);
	const enc = position_encoding(s);
	let arr: []json::value = if (client_supports_hierarchical_doc_symbol(s)) {
		yield build_document_symbols(data, doc.buf.line_index, enc,
			&cache.pr.subunit);
	} else {
		yield build_flat_symbols(data, doc.buf.line_index, enc, uri, &cache.idx);
	};
	send_array_result(s, r.id, arr);
};

// Builds the flat `SymbolInformation[]` shape from the per-file index.
//
// @param data: borrowed
// @param line_index: borrowed
// @param uri: borrowed
// @param idx: borrowed
// @returns: owned
fn build_flat_symbols(
	data: []u8,
	line_index: []size,
	enc: analysis::encoding,
	uri: str,
	idx: *analysis::file_index,
) []json::value = {
	let arr: []json::value = [];
	for (let i = 0z; i < len(idx.symbols); i += 1) {
		const sym = &idx.symbols[i];
		let item = json::newobject();
		json::set(&item, "name", sym.short_name: json::value)!;
		json::put(&item, "kind", symbol_kind_to_lsp(sym.kind))!;
		const start_pos = analysis::byte_to_position(data, line_index, enc,
			sym.span.start.off: size);
		const end_pos = analysis::byte_to_position(data, line_index, enc,
			sym.span.end.off: size);
		let loc = json::newobject();
		json::set(&loc, "uri", uri: json::value)!;
		let range = encode_range_pos(start_pos, end_pos);
		json::put(&loc, "range", range)!;
		json::put(&item, "location", loc)!;
		append(arr, item: json::value)!;
	};
	return arr;
};

// Builds the hierarchical `DocumentSymbol[]` shape. Walks the parsed
// subunit so children (struct fields, enum variants, union members) can
// be nested under their parent decl.
//
// @param data: borrowed
// @param line_index: borrowed
// @param su: borrowed
// @returns: owned
fn build_document_symbols(
	data: []u8,
	line_index: []size,
	enc: analysis::encoding,
	su: *ast::subunit,
) []json::value = {
	let arr: []json::value = [];
	for (let i = 0z; i < len(su.decls); i += 1) {
		match (build_decl_document_symbol(data, line_index, enc, &su.decls[i])) {
		case let v: json::value =>
			append(arr, v)!;
		case void => void;
		};
	};
	return arr;
};

// Builds a single DocumentSymbol entry for a top-level decl. Returns
// void for decls that have no associated symbol (e.g. `static assert`).
//
// @param data: borrowed
// @param line_index: borrowed
// @param d: borrowed
fn build_decl_document_symbol(
	data: []u8,
	line_index: []size,
	enc: analysis::encoding,
	d: *ast::decl,
) (json::value | void) = {
	const (name, kind, is_type, type_ptr) = match (d.decl) {
	case let f: ast::decl_func =>
		yield (
			ident_join_borrowed(f.ident),
			SK_FUNCTION,
			false,
			null: nullable *ast::_type,
		);
	case let t: ast::decl_type =>
		yield (
			ident_join_borrowed(t.ident),
			decl_type_kind(t._type),
			true,
			t._type: nullable *ast::_type,
		);
	case let g: ast::decl_global =>
		const k = if (g.is_const) SK_CONSTANT else SK_VARIABLE;
		yield (ident_join_borrowed(g.ident), k, false, null: nullable *ast::_type);
	case let c: ast::decl_const =>
		yield (
			ident_join_borrowed(c.ident),
			SK_CONSTANT,
			false,
			null: nullable *ast::_type,
		);
	case ast::assert_expr =>
		return void;
	};
	defer free(name);
	if (len(name) == 0) return void;

	const range_start = d.loc.start.off: size;
	let range_end = d.loc.end.off: size;
	if (range_end > len(data)) range_end = len(data);
	if (range_end < range_start) range_end = range_start;

	const (sel_start, sel_end) = decl_name_range(data, range_start, range_end,
		name);

	let item = json::newobject();
	json::set(&item, "name", name: json::value)!;
	json::put(&item, "kind", kind)!;
	json::put(&item, "range",
		encode_byte_range(data, line_index, enc, range_start, range_end))!;
	json::put(&item, "selectionRange",
		encode_byte_range(data, line_index, enc, sel_start, sel_end))!;

	if (is_type) {
		match (type_ptr) {
		case let t: *ast::_type =>
			let children = build_type_children(data, line_index, enc, t);
			if (len(children) > 0) {
				json::put(&item, "children", children: json::value)!;
			} else {
				free(children);
			};
		case null => void;
		};
	};
	return item: json::value;
};

// Picks the LSP SymbolKind for a `type` decl based on its inner type.
// Struct → Struct, enum → Enum, union → Struct (no dedicated LSP kind),
// everything else → TypeParameter so generic aliases (tagged unions,
// tuples, etc.) at least render distinctly from concrete struct types.
//
// @param t: borrowed
fn decl_type_kind(t: *ast::_type) f64 = {
	match (t.repr) {
	case ast::struct_type =>
		return SK_STRUCT;
	case ast::enum_type =>
		return SK_ENUM;
	case ast::union_type =>
		return SK_STRUCT;
	case =>
		return SK_TYPE_PARAMETER;
	};
};

// Builds the `children` array for a type decl. Struct fields become
// Field children, enum variants become EnumMember children, and union
// alternatives become Field children. Other type shapes have no natural
// children and return an empty slice.
//
// @param data: borrowed
// @param line_index: borrowed
// @param t: borrowed
// @returns: owned
fn build_type_children(
	data: []u8,
	line_index: []size,
	enc: analysis::encoding,
	t: *ast::_type,
) []json::value = {
	let out: []json::value = [];
	match (t.repr) {
	case let st: ast::struct_type =>
		struct_member_children(&out, data, line_index, enc, st.members);
	case let un: ast::union_type =>
		struct_member_children(&out, data, line_index, enc, un);
	case let en: ast::enum_type =>
		for (let i = 0z; i < len(en.values); i += 1) {
			const v = &en.values[i];
			const name_start = v.loc.start.off: size;
			const name_end = name_start + len(v.name);
			let item = json::newobject();
			json::set(&item, "name", v.name: json::value)!;
			json::put(&item, "kind", SK_ENUM_MEMBER)!;
			json::put(&item, "range",
				encode_byte_range(data, line_index, enc, name_start, name_end))!;
			json::put(&item, "selectionRange",
				encode_byte_range(data, line_index, enc, name_start, name_end))!;
			append(out, item: json::value)!;
		};
	case => void;
	};
	return out;
};

// Appends a Field child for each named member in `members`. Embedded
// types and struct aliases are skipped — they don't have a distinct
// field name to anchor a child entry on.
//
// @param out: borrowed
// @param data: borrowed
// @param line_index: borrowed
// @param members: borrowed
fn struct_member_children(
	out: *[]json::value,
	data: []u8,
	line_index: []size,
	enc: analysis::encoding,
	members: []ast::struct_member,
) void = {
	for (let i = 0z; i < len(members); i += 1) {
		const f = match (members[i].member) {
		case let f: ast::struct_field =>
			yield f;
		case =>
			continue;
		};
		const (name_start, name_end) = field_name_range(data, f);
		if (name_start == name_end) continue;
		let type_end = f._type.loc.end.off: size;
		if (type_end > len(data)) type_end = len(data);
		if (type_end < name_end) type_end = name_end;
		let item = json::newobject();
		json::set(&item, "name", f.name: json::value)!;
		json::put(&item, "kind", SK_FIELD)!;
		json::put(&item, "range",
			encode_byte_range(data, line_index, enc, name_start, type_end))!;
		json::put(&item, "selectionRange",
			encode_byte_range(data, line_index, enc, name_start, name_end))!;
		append(out, item: json::value)!;
	};
};

// Joins an ident with "::" and returns an owned string. Mirrors
// `analysis::ident_join` (which is package-private to `analysis`).
//
// @param id: borrowed
// @returns: owned
fn ident_join_borrowed(id: ast::ident) str = {
	if (len(id) == 0) return strings::dup("")!;
	if (len(id) == 1) return strings::dup(id[0])!;
	let parts: []str = [];
	defer free(parts);
	for (let i = 0z; i < len(id); i += 1) {
		append(parts, id[i])!;
	};
	return strings::join("::", parts...)!;
};

// Locates the joined identifier `name` within the decl span, returning
// its byte range. The decl's `loc.start.off` points at the start of any
// leading `export` / `@symbol(...)` / `@threadlocal` modifiers, so we
// scan forward (skipping comments and string contents) for the
// declaration keyword (`fn` / `type` / `let` / `const` / `def`),
// step past whitespace, and read off the identifier. Returns
// `(start, start)` as a fallback when the scan fails — callers treat an
// empty range as "use the decl span itself for selectionRange".
//
// @param data: borrowed
// @param name: borrowed
fn decl_name_range(
	data: []u8,
	decl_start: size,
	decl_end: size,
	name: str,
) (size, size) = {
	if (len(name) == 0) return (decl_start, decl_start);
	const name_bytes = strings::toutf8(name);
	let end = decl_end;
	if (end > len(data)) end = len(data);
	if (decl_start >= end) return (decl_start, decl_start);

	// Walk forward looking for the joined name as a whole token.
	// Skipping noncode regions (strings, comments, raw strings) avoids
	// false matches inside `@symbol("...")` attributes and docstrings.
	let i = decl_start;
	for (i + len(name_bytes) <= end) {
		const after = analysis::token_skip_noncode(data, i, end);
		if (after != i) {
			i = after;
			continue;
		};
		if (!is_decl_name_start(data, i, name_bytes, end)) {
			i += 1;
			continue;
		};
		return (i, i + len(name_bytes));
	};
	return (decl_start, decl_start);
};

// Returns true if `data[i..i+len(name)]` equals `name` AND is bounded
// by non-ident bytes on either side (so we don't match `foo` inside
// `foobar` or `prefix::foo` mid-segment).
//
// @param data: borrowed
// @param name: borrowed
fn is_decl_name_start(data: []u8, i: size, name: []u8, end: size) bool = {
	if (i + len(name) > end) return false;
	if (!bytes::equal(data[i..i + len(name)], name)) return false;
	if (i > 0) {
		const prev = data[i - 1];
		if (analysis::is_ident_byte(prev)) return false;
		// Reject matches that look like the tail of a `pre::name`
		// qualifier — selectionRange should always be the full
		// joined name, not just its last segment.
		if (prev == ':': u8) return false;
	};
	const after = i + len(name);
	if (after < end) {
		const next = data[after];
		if (analysis::is_ident_byte(next)) return false;
		if (next == ':': u8 && after + 1 < end && data[after + 1] == ':': u8) {
			return false;
		};
	};
	return true;
};

// Builds a JSON `range` object directly from byte offsets.
//
// @param data: borrowed
// @param line_index: borrowed
fn encode_byte_range(
	data: []u8,
	line_index: []size,
	enc: analysis::encoding,
	start: size,
	end: size,
) json::value = {
	const sp = analysis::byte_to_position(data, line_index, enc, start);
	const ep = analysis::byte_to_position(data, line_index, enc, end);
	return encode_range_pos(sp, ep);
};

// Returns true if the client advertised support for the hierarchical
// `DocumentSymbol[]` response shape. Defaults to false when the
// capability subtree is absent (older clients only handle the flat
// `SymbolInformation[]` shape).
//
// @param s: borrowed
fn client_supports_hierarchical_doc_symbol(s: *server) bool = {
	const caps = match (s.client_capabilities) {
	case void =>
		return false;
	case let v: json::value =>
		yield match (v) {
		case let o: json::object =>
			yield o;
		case =>
			return false;
		};
	};
	const td = match (lsp::json_obj(&caps, "textDocument")) {
	case let o: json::object =>
		yield o;
	case void =>
		return false;
	};
	const ds = match (lsp::json_obj(&td, "documentSymbol")) {
	case let o: json::object =>
		yield o;
	case void =>
		return false;
	};
	return match (json::get(&ds, "hierarchicalDocumentSymbolSupport")) {
	case let p: *json::value =>
		yield match (*p) {
		case let b: bool =>
			yield b;
		case =>
			yield false;
		};
	case void =>
		yield false;
	};
};

fn symbol_kind_to_lsp(k: analysis::symbol_kind) f64 = {
	switch (k) {
	case analysis::symbol_kind::FUNCTION =>
		return SK_FUNCTION;
	case analysis::symbol_kind::TYPE =>
		return SK_STRUCT;
	case analysis::symbol_kind::CONST =>
		return SK_CONSTANT;
	case analysis::symbol_kind::GLOBAL =>
		return SK_VARIABLE;
	case analysis::symbol_kind::DEF =>
		return SK_CONSTANT;
	case =>
		return SK_VARIABLE;
	};
};

// Handles textDocument/documentHighlight. Emits one highlight per
// whole-word occurrence of the cursor's identifier in the document
// (skipping strings, comments, and char literals via the references
// scanner). LSP clients render these as occurrence highlights, so a
// user putting the cursor on a function name sees every call site
// echo back in the editor.
//
// @param s: borrowed
export fn handle_document_highlight(s: *server, r: lsp::request) void = {
	const (uri, pos) = match (parse_text_document_position_local(r.params)) {
	case let v: (str, lsp::position) =>
		yield v;
	case void =>
		send_empty_array(s, r.id);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document =>
		yield p;
	case null =>
		send_empty_array(s, r.id);
		return;
	};
	const data = analysis::bytes(&doc.buf);
	const off = analysis::position_to_byte(data, doc.buf.line_index,
		position_encoding(s),
		analysis::position { line = pos.line, character = pos.character });
	const ident_range = match (analysis::ident_at(data, off)) {
	case let r: (size, size) =>
		yield r;
	case void =>
		send_empty_array(s, r.id);
		return;
	};
	const ident_str = strings::fromutf8(data[ident_range.0..ident_range.1])!;
	const offsets = scan_text_for_ident_offsets_in_range(data, ident_str, 0z,
		len(data));
	defer free(offsets);
	const name_len = len(strings::toutf8(ident_str));
	const enc = position_encoding(s);
	let arr: []json::value = [];
	for (let i = 0z; i < len(offsets); i += 1) {
		const off = offsets[i];
		const start_pos = analysis::byte_to_position(data, doc.buf.line_index, enc,
			off);
		const end_pos = analysis::byte_to_position(data, doc.buf.line_index, enc,
			off + name_len);
		let item = json::newobject();
		json::put(&item, "range", encode_range_pos(start_pos, end_pos))!;
		json::put(&item, "kind", 1: f64)!; // Text
		append(arr, item: json::value)!;
	};
	send_array_result(s, r.id, arr);
};

// Handles textDocument/foldingRange. Emits one folding region per top-level
// declaration spanning multiple lines.
//
// @param s: borrowed
export fn handle_folding_range(s: *server, r: lsp::request) void = {
	const uri = match (uri_from_textdoc_request(r.params)) {
	case let s: str =>
		yield s;
	case void =>
		send_empty_array(s, r.id);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document =>
		yield p;
	case null =>
		send_empty_array(s, r.id);
		return;
	};
	const data = analysis::bytes(&doc.buf);
	const cache = parse_of(doc);
	let arr: []json::value = [];
	for (let i = 0z; i < len(cache.idx.symbols); i += 1) {
		const sym = &cache.idx.symbols[i];
		const start_line = sym.span.start.line: u32;
		// loc.end from hare::parse points one position past the decl —
		// often the start of the next line — so end.line can be one
		// line past the `};` or `;` that actually closes the decl.
		// Back up over trailing whitespace to find the real last line.
		let end_off = sym.span.end.off: size;
		if (end_off > len(data)) end_off = len(data);
		for (end_off > 0 && is_ws_byte(data[end_off - 1]); end_off -= 1) void;
		const end_pos = analysis::byte_to_position(data, doc.buf.line_index,
			position_encoding(s), end_off);
		const end_line = (end_pos.line + 1): u32;
		if (end_line <= start_line) continue;
		let item = json::newobject();
		json::put(&item, "startLine", (start_line - 1): f64)!;
		json::put(&item, "endLine", (end_line - 1): f64)!;
		json::set(&item, "kind", "region": json::value)!;
		append(arr, item: json::value)!;
	};
	// Also fold the import block as a region.
	if (len(cache.pr.subunit.imports) >= 2) {
		const first = cache.pr.subunit.imports[0];
		const last = cache.pr.subunit.imports[len(cache.pr.subunit.imports) - 1];
		if (last.loc.end.line > first.loc.start.line) {
			let item = json::newobject();
			json::put(&item, "startLine", (first.loc.start.line - 1): f64)!;
			json::put(&item, "endLine", (last.loc.end.line - 1): f64)!;
			json::set(&item, "kind", "imports": json::value)!;
			append(arr, item: json::value)!;
		};
	};
	send_array_result(s, r.id, arr);
};

// Handles textDocument/selectionRange. For each given position, walks
// outward through enclosing AST nodes producing nested selection ranges.
// Currently we support: ident → enclosing decl. Step 14b will deepen the
// hierarchy when we pull in expression visitor support.
//
// @param s: borrowed
export fn handle_selection_range(s: *server, r: lsp::request) void = {
	const params_obj = match (params_object_local(r.params)) {
	case let o: json::object =>
		yield o;
	case void =>
		send_empty_array(s, r.id);
		return;
	};
	const td = match (object_field_object_local(&params_obj, "textDocument")) {
	case let o: json::object =>
		yield o;
	case void =>
		send_empty_array(s, r.id);
		return;
	};
	const uri = match (object_string_local(&td, "uri")) {
	case let s: str =>
		yield s;
	case void =>
		send_empty_array(s, r.id);
		return;
	};
	const positions = match (json::get(&params_obj, "positions")) {
	case let p: *json::value =>
		yield match (*p) {
		case let a: []json::value =>
			yield a;
		case =>
			send_empty_array(s, r.id);
			return;
		};
	case =>
		send_empty_array(s, r.id);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document =>
		yield p;
	case null =>
		send_empty_array(s, r.id);
		return;
	};
	const data = analysis::bytes(&doc.buf);
	const cache = parse_of(doc);

	let arr: []json::value = [];
	for (let i = 0z; i < len(positions); i += 1) {
		const pos_v = positions[i];
		const pos = match (lsp::decode_position(pos_v)) {
		case let p: lsp::position =>
			yield p;
		case lsp::bad_message =>
			continue;
		};
		const off = analysis::position_to_byte(data, doc.buf.line_index,
			position_encoding(s),
			analysis::position {
				line = pos.line,
				character = pos.character,
			});
		const enc = position_encoding(s);
		// Build the expansion chain from innermost to outermost. The
		// LSP SelectionRange shape is recursive — each level has an
		// optional `parent` field that wraps the next-outer level.
		// We collect candidate ranges first, dedup adjacent equal
		// ones, then build the linked structure.
		let levels: [](size, size) = [];
		defer free(levels);

		// L0: ident at cursor (if any).
		match (analysis::ident_at(data, off)) {
		case let rng: (size, size) =>
			append(levels, rng)!;
		case void => void;
		};

		// L1: the line containing the cursor (without trailing newline).
		const line_rng = line_range_around(data, off);
		append(levels, line_rng)!;

		// L2: containing decl (if any).
		match (analysis::symbol_at(&cache.idx, off)) {
		case let p: *analysis::symbol =>
			append(levels, (p.span.start.off: size, p.span.end.off: size))!;
		case void => void;
		};

		// L3: whole subunit — start = 0, end = len(data).
		append(levels, (0z, len(data)))!;

		// Dedup adjacent equal ranges so we don't emit a chain with
		// no expansion between two levels.
		let unique: [](size, size) = [];
		defer free(unique);
		for (let j = 0z; j < len(levels); j += 1) {
			if (len(unique) > 0 && unique[len(unique) - 1].0 == levels[j].0 &&
					unique[len(unique) - 1].1 == levels[j].1) {
				continue;
			};
			// Each outer level must strictly contain the previous one.
			if (len(unique) > 0) {
				const prev = unique[len(unique) - 1];
				if (levels[j].0 > prev.0 || levels[j].1 < prev.1) {
					continue;
				};
			};
			append(unique, levels[j])!;
		};

		if (len(unique) == 0) continue;

		// Build the outermost object first, then nest each inner level.
		let outer_obj: (json::value | void) = void;
		for (let j = len(unique); j > 0; j -= 1) {
			const rng = unique[j - 1];
			const sp = analysis::byte_to_position(data, doc.buf.line_index, enc, rng.0);
			const ep = analysis::byte_to_position(data, doc.buf.line_index, enc, rng.1);
			let o = json::newobject();
			json::put(&o, "range", encode_range_pos(sp, ep))!;
			match (outer_obj) {
			case let v: json::value =>
				json::put(&o, "parent", v)!;
			case void => void;
			};
			outer_obj = o: json::value;
		};
		match (outer_obj) {
		case let v: json::value =>
			append(arr, v)!;
		case void => void;
		};
	};
	send_array_result(s, r.id, arr);
};

fn is_ws_byte(b: u8) bool = {
	return b == ' ': u8 || b == '\t': u8 || b == '\n': u8 || b == '\r': u8;
};

// Returns the [start, end) byte range of the line containing `off`,
// without the trailing newline. If `off` is beyond the buffer, clamps.
//
// @param data: borrowed
fn line_range_around(data: []u8, off: size) (size, size) = {
	const o = if (off > len(data)) len(data) else off;
	let s = o;
	for (s > 0 && data[s - 1] != '\n': u8; s -= 1) void;
	let e = o;
	for (e < len(data) && data[e] != '\n': u8; e += 1) void;
	return (s, e);
};

// Handles textDocument/documentLink. Emits one DocumentLink per import
// statement; the link carries a `data: {ident: [...]}` carrier that
// handle_document_link_resolve uses to fill in `target` via
// hare::module::find.
//
// @param s: borrowed
export fn handle_document_link(s: *server, r: lsp::request) void = {
	const uri = match (uri_from_textdoc_request(r.params)) {
	case let s: str =>
		yield s;
	case void =>
		send_empty_array(s, r.id);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document =>
		yield p;
	case null =>
		send_empty_array(s, r.id);
		return;
	};
	const data = analysis::bytes(&doc.buf);
	const cache = parse_of(doc);
	const enc = position_encoding(s);
	let arr: []json::value = [];
	for (let i = 0z; i < len(cache.pr.subunit.imports); i += 1) {
		const imp = cache.pr.subunit.imports[i];
		const start_pos = analysis::byte_to_position(data, doc.buf.line_index, enc,
			imp.loc.start.off: size);
		const end_pos = analysis::byte_to_position(data, doc.buf.line_index, enc,
			imp.loc.end.off: size);
		let item = json::newobject();
		json::put(&item, "range", encode_range_pos(start_pos, end_pos))!;
		let parts: []str = [];
		defer free(parts);
		for (let j = 0z; j < len(imp.ident); j += 1) {
			append(parts, imp.ident[j])!;
		};
		const joined = strings::join("::", parts...)!;
		defer free(joined);
		const tip = strings::concat("module ", joined)!;
		defer free(tip);
		json::set(&item, "tooltip", tip: json::value)!;
		// Carry the parsed ident so documentLink/resolve can map it
		// to a target file.
		let ident_arr: []json::value = [];
		for (let j = 0z; j < len(imp.ident); j += 1) {
			append(ident_arr, strings::dup(imp.ident[j])!: json::value)!;
		};
		let link_data = json::newobject();
		json::put(&link_data, "ident", ident_arr: json::value)!;
		json::put(&item, "data", link_data)!;
		// `target` left absent so the client triggers documentLink/resolve.
		append(arr, item: json::value)!;
	};
	send_array_result(s, r.id, arr);
};

// Handles documentLink/resolve. Reads the module ident carried in `data`,
// resolves it via hare::module::find using each workspace folder as a
// HAREPATH entry, and fills in the link's `target` field with a file://
// URI pointing at the lexicographically first .ha file in the module.
//
// @param s: borrowed
export fn handle_document_link_resolve(s: *server, r: lsp::request) void = {
	const incoming = match (r.params) {
	case let v: json::value =>
		yield match (json::dup(v)) {
		case let copy: json::value =>
			yield copy;
		case nomem =>
			send_empty_array(s, r.id);
			return;
		};
	case void =>
		send_empty_array(s, r.id);
		return;
	};
	defer json::finish(incoming);
	let result = match (incoming) {
	case let o: json::object =>
		yield o;
	// Wrong shape; just send back the input.

	case =>
		match (lsp::encode_response_result(s.out, r.id, incoming)) {
		case size => void;
		case => void;
		};
		return;
	};

	const data_obj = match (json::get(&result, "data")) {
	case let p: *json::value =>
		yield match (*p) {
		case let o: json::object =>
			yield o;
		case =>
			send_response_obj(s, r.id, incoming);
			return;
		};
	case =>
		send_response_obj(s, r.id, incoming);
		return;
	};
	const ident_arr = match (json::get(&data_obj, "ident")) {
	case let p: *json::value =>
		yield match (*p) {
		case let a: []json::value =>
			yield a;
		case =>
			send_response_obj(s, r.id, incoming);
			return;
		};
	case =>
		send_response_obj(s, r.id, incoming);
		return;
	};
	let ident: ast_ident_strs = [];
	defer free(ident);
	for (let i = 0z; i < len(ident_arr); i += 1) {
		match (ident_arr[i]) {
		case let str_val: str =>
			append(ident, str_val)!;
		case =>
			send_response_obj(s, r.id, incoming);
			return;
		};
	};

	// Build a HAREPATH from the workspace folders. Fall back to the
	// stdlib's known location at /usr/local/src/hare/stdlib so that
	// `use io;`-style imports resolve.
	const target = match (resolve_module_target(s, ident)) {
	case let t: str =>
		yield t;
	case void =>
		send_response_obj(s, r.id, incoming);
		return;
	};
	defer free(target);
	json::set(&result, "target", target: json::value)!;
	send_response_obj(s, r.id, result);
};

// Internal alias to keep the imports in this file stable.
type ast_ident_strs = []str;

// @param s: borrowed
// @param ident: borrowed
fn resolve_module_target(s: *server, ident: []str) (str | void) = {
	const (dir, sset) = match (find_module(s, ident)) {
	case let pair: (str, module::srcset) =>
		yield pair;
	case void =>
		return void;
	};
	// `dir` is borrowed from a static buffer in module::find; do NOT
	// free it. The srcset IS owned and must be cleaned up.
	let owned_set = sset;
	defer module::finish_srcset(&owned_set);
	if (len(sset.ha) == 0) return void;

	// Find the lexicographically smallest .ha file.
	let best = sset.ha[0];
	for (let i = 1z; i < len(sset.ha); i += 1) {
		if (strings::compare(sset.ha[i], best) < 0) {
			best = sset.ha[i];
		};
	};
	// `best` may already be an absolute path; if not, prepend dir.
	const full = if (strings::hasprefix(best, "/")) {
		yield strings::dup(best)!;
	} else {
		yield strings::concat(dir, "/", best)!;
	};
	defer free(full);
	return strings::concat("file://", full)!;
};

// Resolves a module ident to its on-disk directory using the workspace
// folders + stdlib + third-party as HAREPATH. Returns the directory path
// (BORROWED — do not free; backed by a static buffer inside module::find
// that is overwritten on the next call) and the module's srcset (OWNED —
// caller must call module::finish_srcset). On miss, returns void.
//
// The return is a tuple with mixed ownership; no single @returns line can
// capture both halves accurately, so the prose above stands without a tag.
//
// @param s: borrowed
// @param ident: borrowed
export fn find_module(
	s: *server,
	ident: []str,
) ((str, module::srcset) | void) = {
	let parts: []str = [];
	let owned_parts: []str = [];
	defer {
		free(parts);
		for (let i = 0z; i < len(owned_parts); i += 1) {
			free(owned_parts[i]);
		};
		free(owned_parts);
	};
	for (let i = 0z; i < len(s.workspace_folders); i += 1) {
		const path = lsp::uri_decode_path(s.workspace_folders[i].uri);
		append(owned_parts, path)!;
		append(parts, path)!;
	};
	// Honor `hare.harepath` config / $HAREPATH / built-in defaults so
	// the resolver works on installs that don't put stdlib under
	// /usr/local/src/hare (e.g. Alpine packages at /usr/src/hare).
	const stdlib_parts = stdlib_search_paths(s);
	for (let i = 0z; i < len(stdlib_parts); i += 1) {
		append(owned_parts, stdlib_parts[i])!;
		append(parts, stdlib_parts[i])!;
	};
	free(stdlib_parts);
	const harepath = strings::join(":", parts...)!;
	defer free(harepath);

	const ctx = module::context {
		harepath = harepath,
		harecache = "",
		tags = [],
	};
	match (module::find(&ctx, ident: ast::ident)) {
	case let pair: (str, module::srcset) =>
		return pair;
	case module::error =>
		return void;
	};
};

// @param s: borrowed
// @param id: borrowed
// @param result: borrowed
fn send_response_obj(s: *server, id: lsp::id, result: json::value) void = {
	match (lsp::encode_response_result(s.out, id, result)) {
	case size => void;
	case => void;
	};
};

// --- helpers --------------------------------------------------------
// @param p: borrowed
fn uri_from_textdoc_request(p: (json::value | void)) (str | void) = {
	const obj = match (params_object_local(p)) {
	case let o: json::object =>
		yield o;
	case void =>
		return void;
	};
	const td = match (object_field_object_local(&obj, "textDocument")) {
	case let o: json::object =>
		yield o;
	case void =>
		return void;
	};
	return object_string_local(&td, "uri");
};

// @param p: borrowed
fn parse_text_document_position_local(
	p: (json::value | void),
) ((str, lsp::position) | void) = {
	const obj = match (params_object_local(p)) {
	case let o: json::object =>
		yield o;
	case void =>
		return void;
	};
	const td = match (object_field_object_local(&obj, "textDocument")) {
	case let o: json::object =>
		yield o;
	case void =>
		return void;
	};
	const uri = match (object_string_local(&td, "uri")) {
	case let s: str =>
		yield s;
	case void =>
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

// @param p: borrowed
fn params_object_local(
	p: (json::value | void),
) (json::object | void) = lsp::params_object(p);

// @param o: borrowed
// @param key: borrowed
fn object_field_object_local(
	o: *json::object,
	key: str,
) (json::object | void) = lsp::json_obj(o, key);

// @param o: borrowed
// @param key: borrowed
fn object_string_local(
	o: *json::object,
	key: str,
) (str | void) = lsp::json_str(o, key);

fn encode_range_pos(
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

// @param s: borrowed
// @param id: borrowed
fn send_empty_array(s: *server, id: lsp::id) void = {
	const empty: []json::value = [];
	send_array_result(s, id, empty);
};

// @param s: borrowed
// @param id: borrowed
// @param arr: owned
fn send_array_result(s: *server, id: lsp::id, arr: []json::value) void = {
	const v: json::value = arr;
	defer json::finish(v);
	match (lsp::encode_response_result(s.out, id, v)) {
	case size => void;
	case => void;
	};
};
