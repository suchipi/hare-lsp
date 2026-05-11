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
use fs;
use hare::ast;
use hare::unparse;
use io;
use lsp;
use memio;
use os;
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

	// Re-parse to get an AST (the document store doesn't keep one yet —
	// it will once parse caching is added in a follow-up).
	let pr = analysis::parse_recover(data, uri);
	defer analysis::finish_parse_result(&pr);
	let idx = analysis::build_index(&pr.subunit);
	defer analysis::finish_index(&idx);

	// Try local file first; on miss, fall back to the workspace index.
	let sig: str = "";
	let docs: str = "";
	let found_local = false;
	match (analysis::find_by_short_name(&idx, ident_str)) {
	case let p: *analysis::symbol =>
		match (find_decl_by_name(&pr.subunit, ident_str)) {
		case let i: size =>
			sig = render_decl_signature(&pr.subunit.decls[i]);
			docs = strings::dup(p.docs)!;
			found_local = true;
		case void => void;
		};
	case void => void;
	};
	if (!found_local) {
		match (workspace_hover(s, ident_str)) {
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
	let pr = analysis::parse_recover(data, uri);
	defer analysis::finish_parse_result(&pr);
	let idx = analysis::build_index(&pr.subunit);
	defer analysis::finish_index(&idx);
	match (analysis::find_by_short_name(&idx, ident_str)) {
	case let p: *analysis::symbol =>
		if (p.kind != analysis::symbol_kind::TYPE) {
			send_null(s, r.id);
			return;
		};
		send_location(s, r.id, uri, p.span, doc);
		return;
	case void => void;
	};
	// Workspace fallback: find a TYPE entry with this short name.
	match (analysis::find_first_by_short_name(&s.workspace_index, ident_str)) {
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
	let pr = analysis::parse_recover(data, uri);
	defer analysis::finish_parse_result(&pr);
	let idx = analysis::build_index(&pr.subunit);
	defer analysis::finish_index(&idx);
	match (analysis::find_by_short_name(&idx, ident_str)) {
	case let p: *analysis::symbol =>
		send_location(s, r.id, uri, p.span, doc);
		return;
	case void => void;
	};
	// Workspace fallback.
	match (analysis::find_first_by_short_name(&s.workspace_index, ident_str)) {
	case let e: *analysis::workspace_entry =>
		send_location_for_entry(s, r.id, e);
	case void =>
		send_null(s, r.id);
	};
};

// Emits a Location response for a workspace_entry without needing the file
// open. We read the file fresh to build a line index and convert byte
// offsets into LSP positions.
fn send_location_for_entry(s: *server, id: lsp::id, e: *analysis::workspace_entry) void = {
	const text = match (read_workspace_file(e.path)) {
	case let t: []u8 => yield t;
	case void =>
		send_null(s, id);
		return;
	};
	defer free(text);
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

// Looks for ident_str in the workspace index; if found, re-parses the
// owning file, locates the matching decl, and returns (sig, docs) — both
// freshly allocated. Returns void if no workspace entry matches or the
// file can't be read.
fn workspace_hover(s: *server, ident_str: str) ((str, str) | void) = {
	const entry = match (analysis::find_first_by_short_name(&s.workspace_index, ident_str)) {
	case let e: *analysis::workspace_entry => yield e;
	case void => return void;
	};
	const text = match (read_workspace_file(entry.path)) {
	case let t: []u8 => yield t;
	case void => return void;
	};
	defer free(text);
	let pr = analysis::parse_recover(text, entry.path);
	defer analysis::finish_parse_result(&pr);
	const decl_idx = match (find_decl_by_name(&pr.subunit, ident_str)) {
	case let i: size => yield i;
	case void => return void;
	};
	const sig = render_decl_signature(&pr.subunit.decls[decl_idx]);
	const docs = strings::dup(pr.subunit.decls[decl_idx].docs)!;
	return (sig, docs);
};

fn read_workspace_file(path: str) ([]u8 | void) = {
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
		case io::EOF => break;
		case io::error => break;
		};
	};
	return buf;
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
