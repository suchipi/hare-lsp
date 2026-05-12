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
	for (let i = 0z; i < len(cache.idx.symbols); i += 1) {
		const sym = &cache.idx.symbols[i];
		let item = json::newobject();
		json::set(&item, "name", sym.short_name: json::value)!;
		json::put(&item, "kind", symbol_kind_to_lsp(sym.kind))!;
		// Location: file URI + full span.
		const start_pos =
			analysis::byte_to_position(
				data, doc.buf.line_index, enc, sym.span.start.off: size,
			);
		const end_pos =
			analysis::byte_to_position(
				data, doc.buf.line_index, enc, sym.span.end.off: size,
			);
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

// Handles textDocument/documentHighlight. Highlights the symbol's
// declaration span. Highlighting every reference in the file would
// duplicate handle_references' work; the LSP spec lets the client fall
// back to references for occurrence highlighting when it wants more.
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
	const off =
		analysis::position_to_byte(
			data, doc.buf.line_index, position_encoding(s),
			analysis::position { line = pos.line, character = pos.character },
		);
	const ident_range = match (analysis::ident_at(data, off)) {
	case let r: (size, size) =>
		yield r;
	case void =>
		send_empty_array(s, r.id);
		return;
	};
	const ident_str = strings::fromutf8(data[ident_range.0..ident_range.1])!;
	const cache = parse_of(doc);
	const sym = match (analysis::find_by_short_name(&cache.idx, ident_str)) {
	case let p: *analysis::symbol =>
		yield p;
	case void =>
		send_empty_array(s, r.id);
		return;
	};

	let arr: []json::value = [];
	let item = json::newobject();
	const enc = position_encoding(s);
	const start_pos =
		analysis::byte_to_position(
			data, doc.buf.line_index, enc, sym.span.start.off: size,
		);
	const end_pos =
		analysis::byte_to_position(
			data, doc.buf.line_index, enc, sym.span.end.off: size,
		);
	json::put(&item, "range", encode_range_pos(start_pos, end_pos))!;
	json::put(&item, "kind", 1: f64)!; // Text
	append(arr, item: json::value)!;
	send_array_result(s, r.id, arr);
};

// Handles textDocument/foldingRange. Emits one folding region per top-level
// declaration spanning multiple lines.
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
		const end_line = sym.span.end.line: u32;
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
		const off =
			analysis::position_to_byte(
				data, doc.buf.line_index, position_encoding(s),
				analysis::position {
					line = pos.line,
					character = pos.character,
				},
			);
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

// Returns the [start, end) byte range of the line containing `off`,
// without the trailing newline. If `off` is beyond the buffer, clamps.
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
		const start_pos =
			analysis::byte_to_position(
				data, doc.buf.line_index, enc, imp.loc.start.off: size,
			);
		const end_pos =
			analysis::byte_to_position(
				data, doc.buf.line_index, enc, imp.loc.end.off: size,
			);
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

fn send_response_obj(s: *server, id: lsp::id, result: json::value) void = {
	match (lsp::encode_response_result(s.out, id, result)) {
	case size => void;
	case => void;
	};
};

// --- helpers --------------------------------------------------------
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

fn params_object_local(
	p: (json::value | void),
) (json::object | void) = lsp::params_object(p);

fn object_field_object_local(
	o: *json::object,
	key: str,
) (json::object | void) = lsp::json_obj(o, key);

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
