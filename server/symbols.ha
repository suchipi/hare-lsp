// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Document symbols, folding ranges, selection ranges, document highlights,
// document links — all AST-walk features that share infrastructure.

use analysis;
use encoding::json;
use hare::ast;
use hare::module;
use lsp;
use strings;

// LSP SymbolKind values used here.
def SK_FILE: f64 = 1.0;
def SK_NAMESPACE: f64 = 3.0;
def SK_FUNCTION: f64 = 12.0;
def SK_VARIABLE: f64 = 13.0;
def SK_CONSTANT: f64 = 14.0;
def SK_STRUCT: f64 = 23.0;
def SK_TYPE_PARAMETER: f64 = 26.0;
def SK_OBJECT: f64 = 19.0;

// Handles textDocument/documentSymbol. Returns a flat list of
// SymbolInformation (we use the legacy flat shape for compatibility; the
// hierarchical DocumentSymbol shape would require nesting struct fields
// which a future revision will add).
export fn handle_document_symbol(s: *server, r: lsp::request) void = {
	const uri = match (uri_from_textdoc_request(r.params)) {
	case let s: str => yield s;
	case void =>
		send_empty_array(s, r.id);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document => yield p;
	case null =>
		send_empty_array(s, r.id);
		return;
	};

	const data = analysis::bytes(&doc.buf);
	let pr = analysis::parse_recover(data, uri);
	defer analysis::finish_parse_result(&pr);
	let idx = analysis::build_index(&pr.subunit);
	defer analysis::finish_index(&idx);

	const enc = position_encoding(s);
	let arr: []json::value = [];
	for (let i = 0z; i < len(idx.symbols); i += 1) {
		const sym = &idx.symbols[i];
		let item = json::newobject();
		json::set(&item, "name", sym.short_name: json::value)!;
		json::put(&item, "kind", symbol_kind_to_lsp(sym.kind))!;
		// Location: file URI + full span.
		const start_pos = analysis::byte_to_position(data, doc.buf.line_index,
			enc, sym.span.start.off: size);
		const end_pos = analysis::byte_to_position(data, doc.buf.line_index,
			enc, sym.span.end.off: size);
		let loc = json::newobject();
		json::set(&loc, "uri", uri: json::value)!;
		let range = encode_range_pos(start_pos, end_pos);
		json::put(&loc, "range", range)!;
		json::put(&item, "location", loc)!;
		append(arr, item: json::value)!;
	};
	send_array_result(s, r.id, arr);
};

fn symbol_kind_to_lsp(k: analysis::symbol_kind) f64 = {
	switch (k) {
	case analysis::symbol_kind::FUNCTION => return SK_FUNCTION;
	case analysis::symbol_kind::TYPE => return SK_STRUCT;
	case analysis::symbol_kind::CONST => return SK_CONSTANT;
	case analysis::symbol_kind::GLOBAL => return SK_VARIABLE;
	case analysis::symbol_kind::DEF => return SK_CONSTANT;
	case => return SK_VARIABLE;
	};
};

// Handles textDocument/documentHighlight. For now we highlight the symbol
// definition only; full reference walking lands in step 16.
export fn handle_document_highlight(s: *server, r: lsp::request) void = {
	const (uri, pos) = match (parse_text_document_position_local(r.params)) {
	case let v: (str, lsp::position) => yield v;
	case void =>
		send_empty_array(s, r.id);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document => yield p;
	case null =>
		send_empty_array(s, r.id);
		return;
	};
	const data = analysis::bytes(&doc.buf);
	const off = analysis::position_to_byte(data, doc.buf.line_index,
		position_encoding(s),
		analysis::position { line = pos.line, character = pos.character });
	const ident_range = match (analysis::ident_at(data, off)) {
	case let r: (size, size) => yield r;
	case void =>
		send_empty_array(s, r.id);
		return;
	};
	const ident_str = strings::fromutf8(data[ident_range.0..ident_range.1])!;
	let pr = analysis::parse_recover(data, uri);
	defer analysis::finish_parse_result(&pr);
	let idx = analysis::build_index(&pr.subunit);
	defer analysis::finish_index(&idx);
	const sym = match (analysis::find_by_short_name(&idx, ident_str)) {
	case let p: *analysis::symbol => yield p;
	case void =>
		send_empty_array(s, r.id);
		return;
	};

	let arr: []json::value = [];
	let item = json::newobject();
	const enc = position_encoding(s);
	const start_pos = analysis::byte_to_position(data, doc.buf.line_index,
		enc, sym.span.start.off: size);
	const end_pos = analysis::byte_to_position(data, doc.buf.line_index,
		enc, sym.span.end.off: size);
	json::put(&item, "range", encode_range_pos(start_pos, end_pos))!;
	json::put(&item, "kind", 1: f64)!; // Text
	append(arr, item: json::value)!;
	send_array_result(s, r.id, arr);
};

// Handles textDocument/foldingRange. Emits one folding region per top-level
// declaration spanning multiple lines.
export fn handle_folding_range(s: *server, r: lsp::request) void = {
	const uri = match (uri_from_textdoc_request(r.params)) {
	case let s: str => yield s;
	case void =>
		send_empty_array(s, r.id);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document => yield p;
	case null =>
		send_empty_array(s, r.id);
		return;
	};
	const data = analysis::bytes(&doc.buf);
	let pr = analysis::parse_recover(data, uri);
	defer analysis::finish_parse_result(&pr);
	let idx = analysis::build_index(&pr.subunit);
	defer analysis::finish_index(&idx);
	let arr: []json::value = [];
	for (let i = 0z; i < len(idx.symbols); i += 1) {
		const sym = &idx.symbols[i];
		const start_line = sym.span.start.line: u32;
		const end_line = sym.span.end.line: u32;
		if (end_line <= start_line) continue;
		let item = json::newobject();
		json::put(&item, "startLine", (start_line - 1): f64)!;
		json::put(&item, "endLine", (end_line - 1): f64)!;
		json::set(&item, "kind", "region": json::value)!;
		append(arr, item: json::value)!;
	};
	// Also fold the import block as a region.
	if (len(pr.subunit.imports) >= 2) {
		const first = pr.subunit.imports[0];
		const last = pr.subunit.imports[len(pr.subunit.imports) - 1];
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
export fn handle_selection_range(s: *server, r: lsp::request) void = {
	const params_obj = match (params_object_local(r.params)) {
	case let o: json::object => yield o;
	case void =>
		send_empty_array(s, r.id);
		return;
	};
	const td = match (object_field_object_local(&params_obj, "textDocument")) {
	case let o: json::object => yield o;
	case void =>
		send_empty_array(s, r.id);
		return;
	};
	const uri = match (object_string_local(&td, "uri")) {
	case let s: str => yield s;
	case void =>
		send_empty_array(s, r.id);
		return;
	};
	const positions = match (json::get(&params_obj, "positions")) {
	case let p: *json::value =>
		yield match (*p) {
		case let a: []json::value => yield a;
		case =>
			send_empty_array(s, r.id);
			return;
		};
	case =>
		send_empty_array(s, r.id);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document => yield p;
	case null =>
		send_empty_array(s, r.id);
		return;
	};
	const data = analysis::bytes(&doc.buf);
	let pr = analysis::parse_recover(data, uri);
	defer analysis::finish_parse_result(&pr);
	let idx = analysis::build_index(&pr.subunit);
	defer analysis::finish_index(&idx);

	let arr: []json::value = [];
	for (let i = 0z; i < len(positions); i += 1) {
		const pos_v = positions[i];
		const pos = match (lsp::decode_position(pos_v)) {
		case let p: lsp::position => yield p;
		case lsp::bad_message => continue;
		};
		const off = analysis::position_to_byte(data, doc.buf.line_index,
			position_encoding(s),
			analysis::position {
				line = pos.line, character = pos.character,
			});
		const enc = position_encoding(s);
		// Innermost: the ident at the cursor (if any).
		const ident_rng = analysis::ident_at(data, off);
		// Outer: the containing decl span (if any).
		const sym = analysis::symbol_at(&idx, off);

		let outer_obj: (json::value | void) = void;
		match (sym) {
		case let p: *analysis::symbol =>
			const sp = analysis::byte_to_position(data, doc.buf.line_index,
				enc, p.span.start.off: size);
			const ep = analysis::byte_to_position(data, doc.buf.line_index,
				enc, p.span.end.off: size);
			let o = json::newobject();
			json::put(&o, "range", encode_range_pos(sp, ep))!;
			outer_obj = o: json::value;
		case void => void;
		};

		let inner: json::value = match (ident_rng) {
		case let rng: (size, size) =>
			const sp = analysis::byte_to_position(data, doc.buf.line_index,
				enc, rng.0);
			const ep = analysis::byte_to_position(data, doc.buf.line_index,
				enc, rng.1);
			let o = json::newobject();
			json::put(&o, "range", encode_range_pos(sp, ep))!;
			match (outer_obj) {
			case let v: json::value =>
				json::put(&o, "parent", v)!;
				outer_obj = void;
			case void => void;
			};
			yield o: json::value;
		case void =>
			match (outer_obj) {
			case let v: json::value =>
				outer_obj = void;
				yield v;
			case void =>
				// No selection range available for this position.
				continue;
			};
		};
		append(arr, inner)!;
	};
	send_array_result(s, r.id, arr);
};

// Handles textDocument/documentLink. Emits links for `use foo::bar;`
// imports — pointing back at the import's target. The actual resolution
// (mapping use path -> file URI) lands with the workspace index in step 15;
// for now we emit links with no `target` and rely on documentLink/resolve
// to fill them in if requested.
export fn handle_document_link(s: *server, r: lsp::request) void = {
	const uri = match (uri_from_textdoc_request(r.params)) {
	case let s: str => yield s;
	case void =>
		send_empty_array(s, r.id);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document => yield p;
	case null =>
		send_empty_array(s, r.id);
		return;
	};
	const data = analysis::bytes(&doc.buf);
	let pr = analysis::parse_recover(data, uri);
	defer analysis::finish_parse_result(&pr);
	const enc = position_encoding(s);
	let arr: []json::value = [];
	for (let i = 0z; i < len(pr.subunit.imports); i += 1) {
		const imp = pr.subunit.imports[i];
		const start_pos = analysis::byte_to_position(data, doc.buf.line_index,
			enc, imp.loc.start.off: size);
		const end_pos = analysis::byte_to_position(data, doc.buf.line_index,
			enc, imp.loc.end.off: size);
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
export fn handle_document_link_resolve(s: *server, r: lsp::request) void = {
	const incoming = match (r.params) {
	case let v: json::value =>
		yield match (json::dup(v)) {
		case let copy: json::value => yield copy;
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
	case let o: json::object => yield o;
	case =>
		// Wrong shape; just send back the input.
		match (lsp::encode_response_result(s.out, r.id, incoming)) {
		case size => void;
		case => void;
		};
		return;
	};

	const data_obj = match (json::get(&result, "data")) {
	case let p: *json::value =>
		yield match (*p) {
		case let o: json::object => yield o;
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
		case let a: []json::value => yield a;
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
	case let t: str => yield t;
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

fn resolve_module_target(s: *server, ident: []str) (str | void) = {
	// Build a colon-separated HAREPATH: workspace folder paths followed
	// by the system stdlib + third-party dirs.
	let parts: []str = [];
	defer free(parts);
	for (let i = 0z; i < len(s.workspace_folders); i += 1) {
		const path = strip_file_scheme(s.workspace_folders[i].uri);
		append(parts, path)!;
	};
	append(parts, "/usr/local/src/hare/stdlib")!;
	append(parts, "/usr/local/src/hare/third-party")!;
	const harepath = strings::join(":", parts...)!;
	defer free(harepath);

	// Build the cache directory in our repo's .tmp/ rather than ~/.cache.
	const ctx = module::context {
		harepath = harepath,
		harecache = "",
		tags = [],
	};

	const result = match (module::find(&ctx, ident: ast::ident)) {
	case let pair: (str, module::srcset) =>
		yield pair;
	case module::error =>
		return void;
	};
	const (dir, sset) = result;
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

fn strip_file_scheme(uri: str) str = {
	const prefix = "file://";
	if (strings::hasprefix(uri, prefix)) {
		return strings::sub(uri, len(prefix), strings::end);
	};
	return uri;
};

fn send_response_obj(s: *server, id: lsp::id, result: json::value) void = {
	match (lsp::encode_response_result(s.out, id, result)) {
	case size => void;
	case => void;
	};
};

// --- helpers --------------------------------------------------------

fn uri_from_textdoc_request(p: (json::value | void)) (str | void) = {
	const obj = match (params_object_local(p)) {
	case let o: json::object => yield o;
	case void => return void;
	};
	const td = match (object_field_object_local(&obj, "textDocument")) {
	case let o: json::object => yield o;
	case void => return void;
	};
	return object_string_local(&td, "uri");
};

fn parse_text_document_position_local(p: (json::value | void)) ((str, lsp::position) | void) = {
	const obj = match (params_object_local(p)) {
	case let o: json::object => yield o;
	case void => return void;
	};
	const td = match (object_field_object_local(&obj, "textDocument")) {
	case let o: json::object => yield o;
	case void => return void;
	};
	const uri = match (object_string_local(&td, "uri")) {
	case let s: str => yield s;
	case void => return void;
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

fn params_object_local(p: (json::value | void)) (json::object | void) =
	lsp::params_object(p);
fn object_field_object_local(o: *json::object, key: str) (json::object | void) =
	lsp::json_obj(o, key);
fn object_string_local(o: *json::object, key: str) (str | void) =
	lsp::json_str(o, key);

fn encode_range_pos(start: analysis::position, end: analysis::position) json::value = {
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

fn send_empty_array(s: *server, id: lsp::id) void = {
	const empty: []json::value = [];
	send_array_result(s, id, empty);
};

fn send_array_result(s: *server, id: lsp::id, arr: []json::value) void = {
	const v: json::value = arr;
	defer json::finish(v);
	match (lsp::encode_response_result(s.out, id, v)) {
	case size => void;
	case => void;
	};
};
