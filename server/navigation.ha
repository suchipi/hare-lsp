// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Navigation handlers: hover, definition, type-definition, declaration,
// implementation. Each tries the open file's symbol index first, then
// falls back to analysis::workspace_index for cross-file targets.
// Workspace hits read and re-parse the target file on demand (there is
// no per-file AST cache yet).

use analysis;
use encoding::json;
use hare::ast;
use hare::unparse;
use lsp;
use memio;
use strings;

// Handles textDocument/hover. Returns a MarkupContent with the symbol's
// signature (rendered via hare::unparse) and its doc comment, when known.
export fn handle_hover(s: *server, r: lsp::request) void = {
	const (uri, pos) = match (parse_text_document_position(r.params)) {
	case let v: (str, lsp::position) => yield v;
	case void =>
		send_null(s, r.id);
		return;
	};

	const doc = match (find_document(s, uri)) {
	case let p: *document => yield p;
	case null =>
		send_null(s, r.id);
		return;
	};

	const off = analysis::position_to_byte(
		analysis::bytes(&doc.buf), doc.buf.line_index,
		position_encoding(s),
		analysis::position {
			line = pos.line,
			character = pos.character,
		});

	const data = analysis::bytes(&doc.buf);
	const ident_range = match (analysis::ident_at(data, off)) {
	case let r: (size, size) => yield r;
	case void =>
		send_null(s, r.id);
		return;
	};

	const ident_str = strings::fromutf8(data[ident_range.0..ident_range.1])!;

	const cache = parse_of(doc);

	// Try local file first; on miss, fall back to the workspace index.
	let sig: str = "";
	let docs: str = "";
	let found_local = false;
	const qualifier_peek = qualifier_prefix_at(data, ident_range.0);
	defer free(qualifier_peek);
	if (len(qualifier_peek) == 0) {
		match (analysis::find_by_short_name(&cache.idx, ident_str)) {
		case let p: *analysis::symbol =>
			match (find_decl_by_name(&cache.pr.subunit, ident_str)) {
			case let i: size =>
				sig = render_decl_signature(&cache.pr.subunit.decls[i]);
				docs = strings::dup(p.docs)!;
				found_local = true;
			case void => void;
			};
		case void => void;
		};
	};
	if (!found_local) {
		match (workspace_hover(s, doc, data, ident_range.0, ident_str)) {
		case let r: (str, str) =>
			sig = r.0;
			docs = r.1;
		case void =>
			send_null(s, r.id);
			return;
		};
	};
	defer free(sig);
	defer free(docs);

	const md = build_hover_markdown(sig, docs);
	defer free(md);

	let result = json::newobject();
	let contents = json::newobject();
	json::set(&contents, "kind", "markdown": json::value)!;
	json::set(&contents, "value", md: json::value)!;
	json::put(&result, "contents", contents)!;
	// Range: the identifier itself.
	const enc = position_encoding(s);
	const start_pos = analysis::byte_to_position(data, doc.buf.line_index, enc, ident_range.0);
	const end_pos = analysis::byte_to_position(data, doc.buf.line_index, enc, ident_range.1);
	let range = json::newobject();
	let s_obj = json::newobject();
	json::put(&s_obj, "line", start_pos.line: f64)!;
	json::put(&s_obj, "character", start_pos.character: f64)!;
	let e_obj = json::newobject();
	json::put(&e_obj, "line", end_pos.line: f64)!;
	json::put(&e_obj, "character", end_pos.character: f64)!;
	json::put(&range, "start", s_obj)!;
	json::put(&range, "end", e_obj)!;
	json::put(&result, "range", range)!;

	send_with_finish(s, r.id, result: json::value);
};

// Handles textDocument/definition (and declaration; same per-file behavior
// for now).
export fn handle_definition(s: *server, r: lsp::request) void = {
	send_location_for_ident(s, r);
};

export fn handle_declaration(s: *server, r: lsp::request) void = {
	send_location_for_ident(s, r);
};

// implementation = same as definition for Hare since there's no inheritance.
export fn handle_implementation(s: *server, r: lsp::request) void = {
	send_location_for_ident(s, r);
};

// typeDefinition: resolves the *type* of an expression at the cursor.
// Without full type inference we approximate: if the cursor is on a name
// whose decl is a type, jump there; otherwise null. Falls back to the
// workspace index for types defined in other files.
export fn handle_type_definition(s: *server, r: lsp::request) void = {
	const (uri, pos) = match (parse_text_document_position(r.params)) {
	case let v: (str, lsp::position) => yield v;
	case void =>
		send_null(s, r.id);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document => yield p;
	case null =>
		send_null(s, r.id);
		return;
	};
	const off = analysis::position_to_byte(
		analysis::bytes(&doc.buf), doc.buf.line_index,
		position_encoding(s),
		analysis::position { line = pos.line, character = pos.character });
	const data = analysis::bytes(&doc.buf);
	const ident_range = match (analysis::ident_at(data, off)) {
	case let r: (size, size) => yield r;
	case void =>
		send_null(s, r.id);
		return;
	};
	const ident_str = strings::fromutf8(data[ident_range.0..ident_range.1])!;
	const cache = parse_of(doc);
	const qualifier_peek = qualifier_prefix_at(data, ident_range.0);
	defer free(qualifier_peek);
	if (len(qualifier_peek) == 0) {
		match (analysis::find_by_short_name(&cache.idx, ident_str)) {
		case let p: *analysis::symbol =>
			if (p.kind != analysis::symbol_kind::TYPE) {
				send_null(s, r.id);
				return;
			};
			send_location(s, r.id, uri, p.span, doc);
			return;
		case void => void;
		};
	};
	// Module-aware workspace fallback (TYPE only).
	match (workspace_lookup_aware(s, doc, data, ident_range.0, ident_str)) {
	case let e: *analysis::workspace_entry =>
		if (e.kind != analysis::symbol_kind::TYPE) {
			send_null(s, r.id);
			return;
		};
		send_location_for_entry(s, r.id, e);
	case void =>
		send_null(s, r.id);
	};
};

fn send_location_for_ident(s: *server, r: lsp::request) void = {
	const (uri, pos) = match (parse_text_document_position(r.params)) {
	case let v: (str, lsp::position) => yield v;
	case void =>
		send_null(s, r.id);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document => yield p;
	case null =>
		send_null(s, r.id);
		return;
	};
	const off = analysis::position_to_byte(
		analysis::bytes(&doc.buf), doc.buf.line_index,
		position_encoding(s),
		analysis::position { line = pos.line, character = pos.character });
	const data = analysis::bytes(&doc.buf);
	const ident_range = match (analysis::ident_at(data, off)) {
	case let r: (size, size) => yield r;
	case void =>
		send_null(s, r.id);
		return;
	};
	const ident_str = strings::fromutf8(data[ident_range.0..ident_range.1])!;
	const cache = parse_of(doc);
	// Bare local lookups only apply if the reference is not qualified —
	// if the user wrote `mod::name`, the local file's index never has
	// `name` (it would be in `mod`).
	const qualifier_peek = qualifier_prefix_at(data, ident_range.0);
	defer free(qualifier_peek);
	if (len(qualifier_peek) == 0) {
		match (analysis::find_by_short_name(&cache.idx, ident_str)) {
		case let p: *analysis::symbol =>
			send_location(s, r.id, uri, p.span, doc);
			return;
		case void => void;
		};
	};
	// Module-aware workspace fallback.
	match (workspace_lookup_aware(s, doc, data, ident_range.0, ident_str)) {
	case let e: *analysis::workspace_entry =>
		send_location_for_entry(s, r.id, e);
	case void =>
		send_null(s, r.id);
	};
};

// Emits a Location response for a workspace_entry without needing the file
// open. We fetch the file via the shared parse cache so repeated jumps to
// the same file don't keep re-reading it from disk.
fn send_location_for_entry(s: *server, id: lsp::id, e: *analysis::workspace_entry) void = {
	const fpe = match (cached_parse_or_drop_stale(s, e.path)) {
	case let p: *file_parse_entry => yield p;
	case null =>
		send_null(s, id);
		return;
	};
	const text = fpe.text;
	const line_index = analysis::build_line_index(text);
	defer free(line_index);
	const enc = position_encoding(s);
	const start_pos = analysis::byte_to_position(text, line_index, enc,
		e.start_off: size);
	const end_pos = analysis::byte_to_position(text, line_index, enc,
		e.end_off: size);

	let result = json::newobject();
	json::set(&result, "uri", e.uri: json::value)!;
	let range = json::newobject();
	let s_obj = json::newobject();
	json::put(&s_obj, "line", start_pos.line: f64)!;
	json::put(&s_obj, "character", start_pos.character: f64)!;
	let e_obj = json::newobject();
	json::put(&e_obj, "line", end_pos.line: f64)!;
	json::put(&e_obj, "character", end_pos.character: f64)!;
	json::put(&range, "start", s_obj)!;
	json::put(&range, "end", e_obj)!;
	json::put(&result, "range", range)!;
	const v: json::value = result;
	defer json::finish(v);
	match (lsp::encode_response_result(s.out, id, v)) {
	case size => void;
	case => void;
	};
};

// Looks for ident_str in the workspace index using module-aware
// disambiguation. If found, fetches the owning file's parse (via the
// shared file_parse_cache so repeated hovers don't re-parse the same
// file), locates the matching decl, and returns (sig, docs) — both
// freshly allocated.
// Returns void if no workspace entry matches or the file can't be read.
fn workspace_hover(s: *server, doc: *document, data: []u8,
		ident_start: size, ident_str: str) ((str, str) | void) = {
	const entry = match (workspace_lookup_aware(s, doc, data, ident_start, ident_str)) {
	case let e: *analysis::workspace_entry => yield e;
	case void => return void;
	};
	const fpe = match (cached_parse_or_drop_stale(s, entry.path)) {
	case let p: *file_parse_entry => yield p;
	case null => return void;
	};
	const decl_idx = match (find_decl_by_name(&fpe.pr.subunit, ident_str)) {
	case let i: size => yield i;
	case void => return void;
	};
	const sig = render_decl_signature(&fpe.pr.subunit.decls[decl_idx]);
	const docs = strings::dup(fpe.pr.subunit.decls[decl_idx].docs)!;
	return (sig, docs);
};

fn send_location(s: *server, id: lsp::id, uri: str, loc: ast::location, doc: *document) void = {
	const enc = position_encoding(s);
	const data = analysis::bytes(&doc.buf);
	const start_pos = analysis::byte_to_position(data, doc.buf.line_index, enc,
		loc.start.off: size);
	const end_pos = analysis::byte_to_position(data, doc.buf.line_index, enc,
		loc.end.off: size);

	let result = json::newobject();
	defer json::finish(result);
	json::set(&result, "uri", uri: json::value)!;
	let range = json::newobject();
	let s_obj = json::newobject();
	json::put(&s_obj, "line", start_pos.line: f64)!;
	json::put(&s_obj, "character", start_pos.character: f64)!;
	let e_obj = json::newobject();
	json::put(&e_obj, "line", end_pos.line: f64)!;
	json::put(&e_obj, "character", end_pos.character: f64)!;
	json::put(&range, "start", s_obj)!;
	json::put(&range, "end", e_obj)!;
	json::put(&result, "range", range)!;
	const result_v: json::value = result;
	match (lsp::encode_response_result(s.out, id, result_v)) {
	case size => void;
	case => void;
	};
};

fn find_decl_by_name(su: *ast::subunit, name: str) (size | void) = {
	for (let i = 0z; i < len(su.decls); i += 1) {
		const id = decl_ident(&su.decls[i]);
		if (len(id) > 0 && id[len(id) - 1] == name) return i;
	};
	return void;
};

fn decl_ident(d: *ast::decl) ast::ident = {
	match (d.decl) {
	case let f: ast::decl_func => return f.ident;
	case let t: ast::decl_type => return t.ident;
	case let g: ast::decl_global => return g.ident;
	case let c: ast::decl_const => return c.ident;
	case ast::assert_expr => return [];
	};
};

fn render_decl_signature(d: *ast::decl) str = {
	let buf = memio::dynamic();
	defer lsp::safe_close(&buf);
	match (unparse::decl(&buf, &unparse::syn_nowrap, d)) {
	case size => void;
	case => return strings::dup("<unparse error>")!;
	};
	return strings::dup(memio::string(&buf)!)!;
};

fn build_hover_markdown(sig: str, docs: str) str = {
	let buf = memio::dynamic();
	defer lsp::safe_close(&buf);
	memio::concat(&buf, "```hare\n")!;
	memio::concat(&buf, sig)!;
	memio::concat(&buf, "\n```")!;
	if (len(docs) > 0) {
		memio::concat(&buf, "\n\n")!;
		memio::concat(&buf, docs)!;
	};
	return strings::dup(memio::string(&buf)!)!;
};

fn parse_text_document_position(p: (json::value | void)) ((str, lsp::position) | void) = {
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

// Looks at the bytes immediately before the ident at off and returns the
// qualifier prefix (everything before "::") as a freshly-allocated string,
// or "" if the ident is bare.
fn qualifier_prefix_at(data: []u8, ident_start: size) str = {
	// We're looking for "...::ident" — the "::" must be directly before
	// ident_start (no whitespace between qualifier and "::").
	if (ident_start < 2) return strings::dup("")!;
	if (data[ident_start - 1] != ':': u8 || data[ident_start - 2] != ':': u8) {
		return strings::dup("")!;
	};
	// Walk back over the qualifier ident bytes.
	let q_end = ident_start - 2;
	let q_start = q_end;
	for (q_start > 0; q_start -= 1) {
		const b = data[q_start - 1];
		if (!is_ident_byte_nav(b)) break;
	};
	if (q_start == q_end) return strings::dup("")!;
	return strings::dup(strings::fromutf8(data[q_start..q_end])!)!;
};

fn is_ident_byte_nav(b: u8) bool = {
	if (b >= 'a': u8 && b <= 'z': u8) return true;
	if (b >= 'A': u8 && b <= 'Z': u8) return true;
	if (b >= '0': u8 && b <= '9': u8) return true;
	return b == '_': u8;
};

// Collects the short-name modules imported in the file's `use` block. For
// `use io;` adds "io"; for `use foo::bar;` adds "bar" (the last segment).
// Caller frees the slice and each string.
fn collect_imported_module_names(su: *ast::subunit) []str = {
	let out: []str = [];
	for (let i = 0z; i < len(su.imports); i += 1) {
		const id = su.imports[i].ident;
		if (len(id) == 0) continue;
		append(out, strings::dup(id[len(id) - 1])!)!;
	};
	return out;
};

fn free_str_slice_nav(s: []str) void = {
	for (let i = 0z; i < len(s); i += 1) {
		free(s[i]);
	};
	free(s);
};

// Module-aware workspace lookup. Tries in priority order:
//   1. Qualifier present  -> find_in_module(qualifier, name)
//   2. find_in_imports(file's imports, name)
//   3. find_first_by_short_name (last-resort fallback)
fn workspace_lookup_aware(
	s: *server, doc: *document, data: []u8,
	ident_start: size, ident_str: str,
) (*analysis::workspace_entry | void) = {
	const qualifier = qualifier_prefix_at(data, ident_start);
	defer free(qualifier);
	if (len(qualifier) > 0) {
		match (analysis::find_in_module(&s.workspace_index, qualifier, ident_str)) {
		case let e: *analysis::workspace_entry => return e;
		case void => void;
		};
		// Qualifier was given but no match — don't silently fall back
		// to a different module, that's a real miss.
		return void;
	};
	// Bare name: rank by the open file's imports.
	const cache = parse_of(doc);
	const imports = collect_imported_module_names(&cache.pr.subunit);
	defer free_str_slice_nav(imports);
	match (analysis::find_in_imports(&s.workspace_index, imports, ident_str)) {
	case let e: *analysis::workspace_entry => return e;
	case void => void;
	};
	// Last-resort: any match in the workspace.
	return analysis::find_first_by_short_name(&s.workspace_index, ident_str);
};

fn send_null(s: *server, id: lsp::id) void = {
	const r: json::value = json::_null;
	match (lsp::encode_response_result(s.out, id, r)) {
	case size => void;
	case => void;
	};
};

fn send_with_finish(s: *server, id: lsp::id, v: json::value) void = {
	defer json::finish(v);
	match (lsp::encode_response_result(s.out, id, v)) {
	case size => void;
	case => void;
	};
};
