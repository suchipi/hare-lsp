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
	case let v: (str, lsp::position) =>
		yield v;
	case void =>
		send_null(s, r.id);
		return;
	};

	const doc = match (find_document(s, uri)) {
	case let p: *document =>
		yield p;
	case null =>
		send_null(s, r.id);
		return;
	};

	const off = analysis::position_to_byte(analysis::bytes(&doc.buf),
		doc.buf.line_index, position_encoding(s),
		analysis::position {
			line = pos.line,
			character = pos.character,
		});

	const data = analysis::bytes(&doc.buf);

	// Struct-member hover: cursor on `<receiver>.<name>`. Tried before
	// module hover and the bare-ident path because a member ident is
	// otherwise indistinguishable from a top-level name.
	if (try_send_struct_member_hover(s, r, doc, data, off)) return;

	// Module-name hover: a `use foo::bar;` statement, a `::`
	// separator, or a code-position qualifier like `bufio` in
	// `bufio::newscanner`. If the cursor lands on a resolvable module
	// path, render its README and return.
	match (try_module_hover(s, doc, data, off)) {
	case let md: str =>
		defer free(md);
		send_module_hover_response(s, doc, data, off, r.id, md);
		return;
	case void => void;
	};

	let ident_range = match (analysis::ident_at(data, off)) {
	case let r: (size, size) =>
		yield r;
	case void =>
		// Cursor may be sitting on the leading '@' of an attribute
		// like `@test`; in that case ident_at fails (since '@' isn't
		// an ident byte). Peek one byte forward.
		yield match (attr_at(data, off)) {
		case let r: (size, size) =>
			yield r;
		case void =>
			send_null(s, r.id);
			return;
		};
	};

	// If a '@' directly precedes the ident, fold it in so attribute
	// names like `@test` and `@init` resolve as a single token.
	if (ident_range.0 > 0 && data[ident_range.0 - 1] == '@': u8) {
		ident_range = (ident_range.0 - 1, ident_range.1);
	};

	const ident_str = strings::fromutf8(data[ident_range.0..ident_range.1])!;

	const cache = parse_of(doc);

	// Try local file first; on miss, fall back to the workspace index.
	let sig: str = "";
	let docs: str = "";
	let found_local = false;
	const qualifier_peek = analysis::qualifier_prefix_at(data, ident_range.0);
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
	if (!found_local && len(qualifier_peek) == 0) {
		match (find_local_binding(s, doc, &cache.pr.subunit, data, ident_str,
			ident_range.0)) {
		case let rendered: str =>
			sig = rendered;
			docs = strings::dup("")!;
			found_local = true;
		case void => void;
		};
	};
	if (!found_local) {
		let found_builtin = false;
		if (len(qualifier_peek) == 0) {
			match (lookup_builtin(ident_str)) {
			case let b: (str, str) =>
				sig = b.0;
				docs = b.1;
				found_builtin = true;
			case void => void;
			};
		};
		if (!found_builtin) {
			match (workspace_hover(s, doc, data, ident_range.0, ident_str)) {
			case let r: (str, str) =>
				sig = r.0;
				docs = r.1;
			case void =>
				send_null(s, r.id);
				return;
			};
		};
	};
	defer free(sig);
	defer free(docs);

	const md = build_hover_markdown(s, doc, sig, docs);
	defer free(md);

	let result = json::newobject();
	let contents = json::newobject();
	json::set(&contents, "kind", "markdown": json::value)!;
	json::set(&contents, "value", md: json::value)!;
	json::put(&result, "contents", contents)!;
	// Range: the identifier itself.
	const enc = position_encoding(s);
	const start_pos = analysis::byte_to_position(data, doc.buf.line_index, enc,
		ident_range.0);
	const end_pos = analysis::byte_to_position(data, doc.buf.line_index, enc,
		ident_range.1);
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

// Sends a hover response whose contents is `md` and whose range is the
// best textual range we can compute around `off`. We don't have the
// module-path span pre-computed, so widen to the surrounding `ident::ident`
// run; if that fails, fall back to the single ident at `off`.
fn send_module_hover_response(
	s: *server,
	doc: *document,
	data: []u8,
	off: size,
	id: lsp::id,
	md: str,
) void = {
	const enc = position_encoding(s);
	let start_off = off;
	let end_off = off;
	match (path_run_at(data, off)) {
	case let r: (size, size) =>
		start_off = r.0;
		end_off = r.1;
	case void =>
		match (analysis::ident_at(data, off)) {
		case let r: (size, size) =>
			start_off = r.0;
			end_off = r.1;
		case void => void;
		};
	};
	const start_pos = analysis::byte_to_position(data, doc.buf.line_index, enc,
		start_off);
	const end_pos = analysis::byte_to_position(data, doc.buf.line_index, enc,
		end_off);
	let result = json::newobject();
	let contents = json::newobject();
	json::set(&contents, "kind", "markdown": json::value)!;
	json::set(&contents, "value", md: json::value)!;
	json::put(&result, "contents", contents)!;
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
	send_with_finish(s, id, result: json::value);
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
	case let v: (str, lsp::position) =>
		yield v;
	case void =>
		send_null(s, r.id);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document =>
		yield p;
	case null =>
		send_null(s, r.id);
		return;
	};
	const off = analysis::position_to_byte(analysis::bytes(&doc.buf),
		doc.buf.line_index, position_encoding(s),
		analysis::position { line = pos.line, character = pos.character });
	const data = analysis::bytes(&doc.buf);
	const ident_range = match (analysis::ident_at(data, off)) {
	case let r: (size, size) =>
		yield r;
	case void =>
		send_null(s, r.id);
		return;
	};
	const ident_str = strings::fromutf8(data[ident_range.0..ident_range.1])!;
	const cache = parse_of(doc);
	const qualifier_peek = analysis::qualifier_prefix_at(data, ident_range.0);
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
	case let v: (str, lsp::position) =>
		yield v;
	case void =>
		send_null(s, r.id);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document =>
		yield p;
	case null =>
		send_null(s, r.id);
		return;
	};
	const off = analysis::position_to_byte(analysis::bytes(&doc.buf),
		doc.buf.line_index, position_encoding(s),
		analysis::position { line = pos.line, character = pos.character });
	const data = analysis::bytes(&doc.buf);
	if (try_send_struct_member_definition(s, r, doc, data, off)) return;
	const ident_range = match (analysis::ident_at(data, off)) {
	case let r: (size, size) =>
		yield r;
	case void =>
		send_null(s, r.id);
		return;
	};
	const ident_str = strings::fromutf8(data[ident_range.0..ident_range.1])!;
	const cache = parse_of(doc);
	// Bare local lookups only apply if the reference is not qualified —
	// if the user wrote `mod::name`, the local file's index never has
	// `name` (it would be in `mod`).
	const qualifier_peek = analysis::qualifier_prefix_at(data, ident_range.0);
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
fn send_location_for_entry(
	s: *server,
	id: lsp::id,
	e: *analysis::workspace_entry,
) void = {
	const fpe = match (cached_parse_or_drop_stale(s, e.path)) {
	case let p: *file_parse_entry =>
		yield p;
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
fn workspace_hover(
	s: *server,
	doc: *document,
	data: []u8,
	ident_start: size,
	ident_str: str,
) ((str, str) | void) = {
	const entry = match (workspace_lookup_aware(s, doc, data, ident_start,
		ident_str)) {
	case let e: *analysis::workspace_entry =>
		yield e;
	case void =>
		return void;
	};
	const fpe = match (cached_parse_or_drop_stale(s, entry.path)) {
	case let p: *file_parse_entry =>
		yield p;
	case null =>
		return void;
	};
	const decl_idx = match (find_decl_by_name(&fpe.pr.subunit, ident_str)) {
	case let i: size =>
		yield i;
	case void =>
		return void;
	};
	const sig = render_decl_signature(&fpe.pr.subunit.decls[decl_idx]);
	const docs = strings::dup(fpe.pr.subunit.decls[decl_idx].docs)!;
	return (sig, docs);
};

fn send_location(
	s: *server,
	id: lsp::id,
	uri: str,
	loc: ast::location,
	doc: *document,
) void = {
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
	case let f: ast::decl_func =>
		return f.ident;
	case let t: ast::decl_type =>
		return t.ident;
	case let g: ast::decl_global =>
		return g.ident;
	case let c: ast::decl_const =>
		return c.ident;
	case ast::assert_expr =>
		return [];
	};
};

// Renders the declaration's signature without its body (for fn) or
// initializer (for global / def). For type aliases we keep the RHS
// because that *is* the type. The intent is that hover shows just what
// the symbol is, not its full definition — e.g.
//   `export fn main() void`   (not `... = { let scan = ...; ... }`)
//   `let stdout_file: io::file`  (not `... = rt::STDOUT_FILENO`)
fn render_decl_signature(d: *ast::decl) str = {
	let buf = memio::dynamic();
	defer lsp::safe_close(&buf);

	match (d.decl) {
	case let c: ast::decl_const =>
		// decl_const.init is non-nullable, so we can't strip it by
		// re-pointing a field. Render manually.
		if (d.exported) {
			match (memio::concat(&buf, "export ")) {
			case size => void;
			case =>
				return strings::dup("<unparse error>")!;
			};
		};
		match (memio::concat(&buf, "def ")) {
		case size => void;
		case =>
			return strings::dup("<unparse error>")!;
		};
		match (unparse::ident(&buf, c.ident)) {
		case size => void;
		case =>
			return strings::dup("<unparse error>")!;
		};
		match (c._type) {
		case let t: *ast::_type =>
			match (memio::concat(&buf, ": ")) {
			case size => void;
			case => void;
			};
			match (unparse::_type(&buf, &unparse::syn_nowrap, t)) {
			case size => void;
			case => void;
			};
		case null => void;
		};
		return strings::dup(memio::string(&buf)!)!;
	case let f: ast::decl_func =>
		// Re-emit through unparse::decl with the body stripped. The
		// upstream renderer skips the `= body` block when f.body is
		// null. Clear docs so the comment isn't baked into the code
		// fence — build_hover_markdown appends it as prose below.
		let copy = *d;
		copy.docs = "";
		copy.decl = ast::decl_func {
			symbol = f.symbol,
			ident = f.ident,
			prototype = f.prototype,
			body = null,
			attrs = f.attrs,
		};
		match (unparse::decl(&buf, &unparse::syn_nowrap, &copy)) {
		case size => void;
		case =>
			return strings::dup("<unparse error>")!;
		};
	case let g: ast::decl_global =>
		let copy = *d;
		copy.docs = "";
		copy.decl = ast::decl_global {
			is_const = g.is_const,
			is_threadlocal = g.is_threadlocal,
			symbol = g.symbol,
			ident = g.ident,
			_type = g._type,
			init = null,
		};
		match (unparse::decl(&buf, &unparse::syn_nowrap, &copy)) {
		case size => void;
		case =>
			return strings::dup("<unparse error>")!;
		};
	// Type alias / assert — keep as-is. For a type alias, the
	// RHS *is* the type definition, so we want to show it.

	case =>
		let copy = *d;
		copy.docs = "";
		match (unparse::decl(&buf, &unparse::syn_nowrap, &copy)) {
		case size => void;
		case =>
			return strings::dup("<unparse error>")!;
		};
	};
	return strings::dup(memio::string(&buf)!)!;
};

fn build_hover_markdown(s: *server, doc: *document, sig: str, docs: str) str = {
	const cleaned = clean_doc_comment(docs);
	defer free(cleaned);
	return build_hover_markdown_raw(s, doc, sig, cleaned);
};

// Same as build_hover_markdown but assumes `body` is already clean
// markdown (no doc-comment leading-space stripping). Used for README
// hovers where the source is raw markdown.
export fn build_hover_markdown_raw(
	s: *server,
	doc: *document,
	sig: str,
	body: str,
) str = {
	let buf = memio::dynamic();
	defer lsp::safe_close(&buf);
	memio::concat(&buf, "```hare\n")!;
	memio::concat(&buf, sig)!;
	memio::concat(&buf, "\n```")!;
	if (len(body) > 0) {
		const linked = render_doc_refs(s, doc, body);
		defer free(linked);
		memio::concat(&buf, "\n\n")!;
		memio::concat(&buf, linked)!;
	};
	return strings::dup(memio::string(&buf)!)!;
};

// Normalises a Hare doc-comment string for markdown display. Each line
// produced by hare::lex::comment is the source line minus the leading `//`,
// so it typically begins with one space (e.g. ` One diagnostic.\n`). We
// strip that single leading space per line and trim trailing whitespace so
// the markdown body reads as plain prose. Caller frees.
fn clean_doc_comment(docs: str) str = {
	if (len(docs) == 0) return strings::dup("")!;
	const trimmed = strings::trimsuffix(docs, "\n");
	const lines = strings::split(trimmed, "\n")!;
	defer free(lines);
	let cleaned: []str = [];
	defer free(cleaned);
	for (let i = 0z; i < len(lines); i += 1) {
		append(cleaned, strings::trimprefix(lines[i], " "))!;
	};
	return strings::join("\n", cleaned...)!;
};

fn parse_text_document_position(
	p: (json::value | void),
) ((str, lsp::position) | void) = {
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

// Looks at the bytes immediately before the ident at off and returns the
// qualifier prefix (everything before "::") as a freshly-allocated string,
// or "" if the ident is bare.
// If `off` sits on a '@' that precedes an identifier (e.g. cursor on
// the '@' of `@test`), returns the byte range covering '@' through the
// end of the identifier. Returns void otherwise. The leading '@' is
// folded back in by handle_hover for any cursor position; this helper
// only exists so cursor-on-'@' doesn't immediately fail at ident_at.
fn attr_at(data: []u8, off: size) ((size, size) | void) = {
	if (off >= len(data)) return void;
	if (data[off] != '@': u8) return void;
	if (off + 1 >= len(data)) return void;
	return match (analysis::ident_at(data, off + 1)) {
	case let r: (size, size) =>
		if (r.0 != off + 1) yield void;
		yield (off, r.1);
	case void =>
		yield void;
	};
};

// Module-aware workspace lookup. Tries in priority order:
//   1. Qualifier present  -> workspace, then stdlib (lazily indexing)
//   2. Bare: file's imports against workspace, then stdlib
//   3. Last-resort: any match in workspace, then stdlib
//
// The workspace-only resolution is delegated to
// `analysis::workspace_lookup_for_subunit`; stdlib resolution layers on
// top here because it needs `*server` to drive lazy indexing.
fn workspace_lookup_aware(
	s: *server,
	doc: *document,
	data: []u8,
	ident_start: size,
	ident_str: str,
) (*analysis::workspace_entry | void) = {
	const qualifier = analysis::qualifier_prefix_at(data, ident_start);
	defer free(qualifier);
	const cache = parse_of(doc);
	const doc_path = lsp::uri_decode_path(doc.uri);
	defer free(doc_path);
	const file_module = analysis::module_from_path(doc_path);
	defer free(file_module);
	if (len(qualifier) > 0) {
		match (analysis::workspace_lookup_for_subunit(&s.workspace_index,
			&cache.pr.subunit, file_module, qualifier, ident_str)) {
		case let e: *analysis::workspace_entry =>
			return e;
		case void => void;
		};
		// Workspace miss — try resolving against stdlib/third-party,
		// lazily indexing the named module the first time we see it.
		// The qualifier we see is the last segment of the use path
		// (e.g. "poll" for `use unix::poll;`), so we also try the
		// fully-qualified module identifier when the open file's
		// imports point to a multi-segment path ending in `qualifier`.
		const full = analysis::full_module_for_qualifier(&cache.pr.subunit,
			qualifier);
		defer free(full);
		const lookup_module = if (len(full) > 0) full else qualifier;
		if (ensure_stdlib_module_indexed(s, lookup_module)) {
			match (analysis::find_in_module(&s.stdlib_index, qualifier, ident_str)) {
			case let e: *analysis::workspace_entry =>
				return e;
			case void => void;
			};
		};
		return void;
	};
	// Bare name: try the file's own module first (a same-module
	// reference is the most common case), then rank by the open file's
	// imports.
	if (len(file_module) > 0) {
		match (analysis::find_in_module(&s.workspace_index, file_module, ident_str)) {
		case let e: *analysis::workspace_entry =>
			return e;
		case void => void;
		};
	};
	const imports = analysis::collect_imported_module_names(&cache.pr.subunit);
	defer analysis::free_str_slice(imports);
	match (analysis::find_in_imports(&s.workspace_index, imports, ident_str)) {
	case let e: *analysis::workspace_entry =>
		return e;
	case void => void;
	};
	// Ensure each import is indexed in stdlib, then try matching.
	const full_imports = analysis::collect_imported_module_paths(
		&cache.pr.subunit);
	defer analysis::free_str_slice(full_imports);
	for (let i = 0z; i < len(full_imports); i += 1) {
		const _ = ensure_stdlib_module_indexed(s, full_imports[i]);
	};
	match (analysis::find_in_imports(&s.stdlib_index, imports, ident_str)) {
	case let e: *analysis::workspace_entry =>
		return e;
	case void => void;
	};
	// Last-resort: any match in the workspace, then stdlib.
	match (analysis::find_first_by_short_name(&s.workspace_index, ident_str)) {
	case let e: *analysis::workspace_entry =>
		return e;
	case void => void;
	};
	return analysis::find_first_by_short_name(&s.stdlib_index, ident_str);
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

// Renders a hover signature for an unqualified identifier that refers to a
// local `let` / `const` / function-parameter binding. Walks the body of the
// containing function decl. Returns void if no matching binding is in
// scope at `off`. Caller frees the result.
fn find_local_binding(
	srv: *server,
	doc: *document,
	su: *ast::subunit,
	data: []u8,
	name: str,
	off: size,
) (str | void) = {
	for (let i = 0z; i < len(su.decls); i += 1) {
		const d = &su.decls[i];
		if (off < d.loc.start.off: size) continue;
		if (off > d.loc.end.off: size) continue;
		const f = match (d.decl) {
		case let f: ast::decl_func =>
			yield f;
		case =>
			continue;
		};
		// Function parameter?
		match (f.prototype.repr) {
		case let proto: ast::func_type =>
			for (let j = 0z; j < len(proto.params); j += 1) {
				if (proto.params[j].name != name) continue;
				return render_param_binding(&proto.params[j]);
			};
		case => void;
		};
		const body = match (f.body) {
		case let e: *ast::expr =>
			yield e;
		case null =>
			return void;
		};
		// Innermost wins: walk recursively, tracking the best (deepest
		// containing) hit.
		match (walk_for_local(srv, doc, data, body, name, off)) {
		case let r: str =>
			return r;
		case void =>
			return void;
		};
	};
	return void;
};

// Recurses through the common expression forms looking for a `let`/`const`
// binding of `name` whose textual range encloses `off`. Returns the
// rendered signature or void.
fn walk_for_local(
	srv: *server,
	doc: *document,
	data: []u8,
	e: *ast::expr,
	name: str,
	off: size,
) (str | void) = {
	// We never early-return on range mismatch: for compound bodies,
	// preceding sibling bindings are still in scope at `off`.
	match (e.expr) {
	case let b: ast::binding_expr =>
		// Only consider bindings declared lexically before `off`.
		// `e.end.off` is the end of the whole `let foo = bar;`
		// statement; anything past it is in scope.
		for (let i = 0z; i < len(b.bindings); i += 1) {
			const bd = &b.bindings[i];
			for (let j = 0z; j < len(bd.names); j += 1) {
				if (bd.names[j] != name) continue;
				return render_local_binding(srv, doc, data, b.kind, bd);
			};
		};
		// Also walk into the init expression in case it contains
		// nested bindings (rare but valid).
		return walk_for_local(srv, doc, data, b.bindings[0].init, name, off);
	case let c: ast::compound_expr =>
		// Visit in order so an inner shadowing binding wins.
		let hit: (str | void) = void;
		for (let i = 0z; i < len(c.exprs); i += 1) {
			const child = c.exprs[i];
			if (child.loc.start.off: size > off) break;
			match (walk_for_local(srv, doc, data, child, name, off)) {
			case let r: str =>
				match (hit) {
				case let prev: str =>
					free(prev);
				case void => void;
				};
				hit = r;
			case void => void;
			};
		};
		return hit;
	case let i: ast::if_expr =>
		match (walk_for_local(srv, doc, data, i.tbranch, name, off)) {
		case let r: str =>
			return r;
		case void => void;
		};
		match (i.fbranch) {
		case let e2: *ast::expr =>
			return walk_for_local(srv, doc, data, e2, name, off);
		case null =>
			return void;
		};
	case let fr: ast::for_expr =>
		match (fr.bindings) {
		case let b: *ast::expr =>
			match (walk_for_local(srv, doc, data, b, name, off)) {
			case let r: str =>
				return r;
			case void => void;
			};
		case null => void;
		};
		return walk_for_local(srv, doc, data, fr.body, name, off);
	case let m: ast::match_expr =>
		// Match-case bindings (`case let x: T => ...`) introduce a
		// local for the duration of the case body. The case range is
		// the span of its first expr through its last; we approximate
		// "in scope" by checking whether off lies within any expr.
		for (let i = 0z; i < len(m.cases); i += 1) {
			const mc = &m.cases[i];
			const in_case = case_contains(mc.exprs, off);
			if (in_case && mc.name == name) {
				return render_match_case_binding(mc);
			};
			if (!in_case) continue;
			match (walk_case_exprs(srv, doc, data, mc.exprs, name, off)) {
			case let r: str =>
				return r;
			case void => void;
			};
		};
		return walk_for_local(srv, doc, data, m.value, name, off);
	case let sw: ast::switch_expr =>
		for (let i = 0z; i < len(sw.cases); i += 1) {
			const sc = &sw.cases[i];
			if (!case_contains(sc.exprs, off)) continue;
			match (walk_case_exprs(srv, doc, data, sc.exprs, name, off)) {
			case let r: str =>
				return r;
			case void => void;
			};
		};
		return walk_for_local(srv, doc, data, sw.value, name, off);
	case let d: ast::defer_expr =>
		return walk_for_local(srv, doc, data, d: *ast::expr, name, off);
	case let r: ast::return_expr =>
		match (r) {
		case let inner: *ast::expr =>
			return walk_for_local(srv, doc, data, inner, name, off);
		case null =>
			return void;
		};
	case let y: ast::yield_expr =>
		match (y.value) {
		case let inner: *ast::expr =>
			return walk_for_local(srv, doc, data, inner, name, off);
		case null =>
			return void;
		};
	case let p: ast::propagate_expr =>
		return walk_for_local(srv, doc, data, p: *ast::expr, name, off);
	case let p: ast::error_assert_expr =>
		return walk_for_local(srv, doc, data, p: *ast::expr, name, off);
	case let c: ast::call_expr =>
		// Walks the callee and arguments. Rarely useful for bindings
		// but covers nested expression bodies.
		match (walk_for_local(srv, doc, data, c.lvalue, name, off)) {
		case let r: str =>
			return r;
		case void => void;
		};
		for (let i = 0z; i < len(c.args); i += 1) {
			match (walk_for_local(srv, doc, data, c.args[i], name, off)) {
			case let r: str =>
				return r;
			case void => void;
			};
		};
		return void;
	case let a: ast::assign_expr =>
		match (a.object) {
		case let lhs: *ast::expr =>
			match (walk_for_local(srv, doc, data, lhs, name, off)) {
			case let r: str =>
				return r;
			case void => void;
			};
		case null => void;
		};
		return walk_for_local(srv, doc, data, a.value, name, off);
	case =>
		return void;
	};
};

fn render_local_binding(
	srv: *server,
	doc: *document,
	data: []u8,
	kind: ast::binding_kind,
	b: *ast::binding,
) str = {
	let buf = memio::dynamic();
	defer lsp::safe_close(&buf);
	const kw = switch (kind) {
	case ast::binding_kind::LET =>
		yield "let ";
	case ast::binding_kind::CONST =>
		yield "const ";
	case ast::binding_kind::DEF =>
		yield "def ";
	};
	match (memio::concat(&buf, kw)) {
	case size => void;
	case =>
		return strings::dup("<binding>")!;
	};
	for (let i = 0z; i < len(b.names); i += 1) {
		if (i > 0) {
			match (memio::concat(&buf, ", ")) {
			case size => void;
			case => void;
			};
		};
		match (memio::concat(&buf, b.names[i])) {
		case size => void;
		case => void;
		};
	};
	match (b._type) {
	case let t: *ast::_type =>
		match (memio::concat(&buf, ": ")) {
		case size => void;
		case => void;
		};
		match (unparse::_type(&buf, &unparse::syn_nowrap, t)) {
		case size => void;
		case => void;
		};
	case null =>
		// No explicit type — try to infer one from the init.
		match (infer_type_from_init(srv, doc, b.init)) {
		case let inferred: str =>
			defer free(inferred);
			match (memio::concat(&buf, ": ", inferred)) {
			case size => void;
			case => void;
			};
		case void =>
			// Last resort: echo the init source so the user at
			// least sees what they wrote, instead of a bare
			// `let scan` with no information.
			const init_off_start = b.init.loc.start.off: size;
			const init_off_end = b.init.loc.end.off: size;
			if (init_off_end <= len(data) && init_off_start <= init_off_end) {
				const init_src = strings::fromutf8(data[init_off_start..init_off_end])!;
				match (memio::concat(&buf, " = ", init_src)) {
				case size => void;
				case => void;
				};
			};
		};
	};
	return strings::dup(memio::string(&buf)!)!;
};

// Best-effort inference of the type of `init`. Handles:
//   - plain literals (int, str, etc.)
//   - direct call expressions (workspace + stdlib callee return type)
//   - cast expressions
//   - struct/array/tuple literals (renders the literal type only)
//   - `?` / `!` wrappers, by recursing into the inner expression and
//     stripping any error-flagged variants from the resulting type
//     (matching Hare's actual semantics for propagate / error-assert).
// Other forms return void; the caller falls back to echoing the source.
fn infer_type_from_init(
	srv: *server,
	doc: *document,
	init: *ast::expr,
) (str | void) = {
	match (init.expr) {
	case let l: ast::literal_expr =>
		return type_label_for_literal(l);
	case let c: ast::call_expr =>
		return infer_call_return_type(srv, doc, &c);
	case let c: ast::cast_expr =>
		let buf = memio::dynamic();
		defer lsp::safe_close(&buf);
		match (unparse::_type(&buf, &unparse::syn_nowrap, c._type)) {
		case size => void;
		case =>
			return void;
		};
		return strings::dup(memio::string(&buf)!)!;
	case let p: ast::propagate_expr =>
		return infer_unwrapped_init(srv, doc, p: *ast::expr);
	case let p: ast::error_assert_expr =>
		return infer_unwrapped_init(srv, doc, p: *ast::expr);
	case let m: ast::match_expr =>
		return infer_match_expr_type(srv, doc, &m);
	case =>
		return void;
	};
};

// Best-effort type for a match expression: the union of each case's
// contributed value type, deduplicated. Cases whose body always diverges
// (return / abort) contribute nothing. Returns void if no case yields a
// usable type, in which case the caller falls back to echoing the source.
fn infer_match_expr_type(
	srv: *server,
	doc: *document,
	m: *ast::match_expr,
) (str | void) = {
	let parts: []str = [];
	defer analysis::free_str_slice(parts);
	for (let i = 0z; i < len(m.cases); i += 1) {
		const mc = &m.cases[i];
		match (infer_case_value_type(srv, doc, mc)) {
		case let t: str =>
			if (!contains_str(parts, t)) {
				append(parts, t)!;
			} else {
				free(t);
			};
		case void => void;
		};
	};
	if (len(parts) == 0) return void;
	if (len(parts) == 1) return strings::dup(parts[0])!;
	const joined = strings::join(" | ", parts...)!;
	defer free(joined);
	return strings::concat("(", joined, ")")!;
};

// Returns the value type a single match case contributes back to the
// surrounding match expression, or void if the case always diverges
// (e.g. `return foo;`). Caller frees.
fn infer_case_value_type(
	srv: *server,
	doc: *document,
	mc: *ast::match_case,
) (str | void) = {
	if (len(mc.exprs) == 0) return void;
	// Walk the body. An explicit `yield` short-circuits the case's
	// contribution. A `return` (anywhere we can see it at the top
	// level) means this path diverges. Otherwise the implicit-yield
	// rule applies: the type of the last expression.
	for (let i = 0z; i < len(mc.exprs); i += 1) {
		const e = mc.exprs[i];
		match (e.expr) {
		case ast::return_expr =>
			return void;
		case let y: ast::yield_expr =>
			return type_of_yield_value(srv, doc, mc, y);
		case => void;
		};
	};
	return type_of_case_value_expr(srv, doc, mc, mc.exprs[len(mc.exprs) - 1]);
};

// Type of a `yield <value>`'s value, or void for bare `yield` (which
// contributes void in Hare's type rules).
fn type_of_yield_value(
	srv: *server,
	doc: *document,
	mc: *ast::match_case,
	y: ast::yield_expr,
) (str | void) = {
	const v = match (y.value) {
	case let v: *ast::expr =>
		yield v;
	case null =>
		return strings::dup("void")!;
	};
	return type_of_case_value_expr(srv, doc, mc, v);
};

// Best-effort type for an expression that flows out of a match case body.
// Recognises references to the case's own binding (`yield i` where the
// case is `case let i: T`) and otherwise reuses infer_type_from_init for
// literals / calls / casts.
fn type_of_case_value_expr(
	srv: *server,
	doc: *document,
	mc: *ast::match_case,
	e: *ast::expr,
) (str | void) = {
	match (e.expr) {
	case let a: ast::access_expr =>
		match (a) {
		case let id: ast::access_identifier =>
			if (len(id) == 1 && len(mc.name) > 0 && id[0] == mc.name) {
				return render_case_binding_type(mc);
			};
		case => void;
		};
	case => void;
	};
	return infer_type_from_init(srv, doc, e);
};

// Renders the case's binding type (`case let i: T` -> "T"). For a default
// case or a case without an explicit type, returns void.
fn render_case_binding_type(mc: *ast::match_case) (str | void) = {
	const t = match (mc._type) {
	case let t: *ast::_type =>
		yield t;
	case null =>
		return void;
	};
	let buf = memio::dynamic();
	defer lsp::safe_close(&buf);
	match (unparse::_type(&buf, &unparse::syn_nowrap, t)) {
	case size => void;
	case =>
		return void;
	};
	return strings::dup(memio::string(&buf)!)!;
};

fn contains_str(haystack: []str, needle: str) bool = {
	for (let i = 0z; i < len(haystack); i += 1) {
		if (haystack[i] == needle) return true;
	};
	return false;
};

// Infers the type of an init expression after stripping any error-flagged
// variants from its resulting type. Used for the inner expression of `?` and
// `!`, which both yield the non-error component of the inner type.
fn infer_unwrapped_init(
	srv: *server,
	doc: *document,
	inner: *ast::expr,
) (str | void) = {
	const result_t = match (inner.expr) {
	case let c: ast::call_expr =>
		yield match (infer_call_return_type_node(srv, doc, &c)) {
		case let t: *ast::_type =>
			yield t;
		case void =>
			// Fall back to the un-stripped string form so the user
			// at least sees something useful.
			return infer_type_from_init(srv, doc, inner);
		};
	case =>
		return infer_type_from_init(srv, doc, inner);
	};
	return render_type_without_errors(srv, doc, result_t);
};

fn type_label_for_literal(l: ast::literal_expr) (str | void) = {
	match (l) {
	case let p: ast::plain_literal =>
		// unparse::builtin_type aborts on the untyped const storages
		// (ICONST, FCONST, RCONST). They have no lexical name; show
		// the closest concrete type so hover stays useful.
		switch (p.storage) {
		case ast::builtin_type::ICONST =>
			return strings::dup("int")!;
		case ast::builtin_type::FCONST =>
			return strings::dup("f64")!;
		case ast::builtin_type::RCONST =>
			return strings::dup("rune")!;
		case =>
			return strings::dup(unparse::builtin_type(p.storage))!;
		};
	case ast::array_literal =>
		return strings::dup("[_]_")!;
	case ast::struct_literal =>
		return strings::dup("struct { ... }")!;
	case ast::tuple_literal =>
		return strings::dup("(...)")!;
	};
};

// Resolves the callee of a direct call expression and renders its return
// type, e.g. `bufio::newscanner(...)` -> `bufio::scanner`. Returns void if
// the callee isn't a direct access_identifier or can't be resolved.
fn infer_call_return_type(
	srv: *server,
	doc: *document,
	c: *ast::call_expr,
) (str | void) = {
	const callee_ident = match (c.lvalue.expr) {
	case let a: ast::access_expr =>
		yield match (a) {
		case let id: ast::access_identifier =>
			yield id;
		case =>
			return void;
		};
	case =>
		return void;
	};
	if (len(callee_ident) == 0) return void;
	const callee_name = callee_ident[len(callee_ident) - 1];

	const entry = match (lookup_callee(srv, doc, callee_ident)) {
	case let e: *analysis::workspace_entry =>
		yield e;
	case void =>
		return void;
	};
	const fpe = match (cached_parse_or_drop_stale(srv, entry.path)) {
	case let p: *file_parse_entry =>
		yield p;
	case null =>
		return void;
	};
	const idx = match (find_decl_by_name(&fpe.pr.subunit, callee_name)) {
	case let i: size =>
		yield i;
	case void =>
		return void;
	};
	return render_func_result(&fpe.pr.subunit.decls[idx]);
};

// Finds the workspace/stdlib entry for a callee identifier list like
// ["bufio", "newscanner"] or ["foo"]. Mirrors workspace_lookup_aware but
// works from the AST identifier rather than a byte offset + qualifier
// scan.
fn lookup_callee(
	srv: *server,
	doc: *document,
	callee_ident: []str,
) (*analysis::workspace_entry | void) = {
	if (len(callee_ident) == 0) return void;
	const name = callee_ident[len(callee_ident) - 1];
	if (len(callee_ident) >= 2) {
		const qualifier = callee_ident[len(callee_ident) - 2];
		match (analysis::find_in_module(&srv.workspace_index, qualifier, name)) {
		case let e: *analysis::workspace_entry =>
			return e;
		case void => void;
		};
		const cache = parse_of(doc);
		const full = analysis::full_module_for_qualifier(&cache.pr.subunit,
			qualifier);
		defer free(full);
		const mod_to_index = if (len(full) > 0) full else qualifier;
		if (ensure_stdlib_module_indexed(srv, mod_to_index)) {
			return analysis::find_in_module(&srv.stdlib_index, qualifier, name);
		};
		return void;
	};
	const cache = parse_of(doc);
	const imports = analysis::collect_imported_module_names(&cache.pr.subunit);
	defer analysis::free_str_slice(imports);
	match (analysis::find_in_imports(&srv.workspace_index, imports, name)) {
	case let e: *analysis::workspace_entry =>
		return e;
	case void => void;
	};
	return analysis::find_first_by_short_name(&srv.workspace_index, name);
};

fn render_func_result(d: *ast::decl) (str | void) = {
	const f = match (d.decl) {
	case let f: ast::decl_func =>
		yield f;
	case =>
		return void;
	};
	const ft = match (f.prototype.repr) {
	case let proto: ast::func_type =>
		yield proto;
	case =>
		return void;
	};
	let buf = memio::dynamic();
	defer lsp::safe_close(&buf);
	match (unparse::_type(&buf, &unparse::syn_nowrap, ft.result)) {
	case size => void;
	case =>
		return void;
	};
	return strings::dup(memio::string(&buf)!)!;
};

// Like [[infer_call_return_type]] but returns the result type's AST node so
// callers can post-process it (e.g. strip error variants for `?` / `!`).
fn infer_call_return_type_node(
	srv: *server,
	doc: *document,
	c: *ast::call_expr,
) (*ast::_type | void) = {
	const callee_ident = match (c.lvalue.expr) {
	case let a: ast::access_expr =>
		yield match (a) {
		case let id: ast::access_identifier =>
			yield id;
		case =>
			return void;
		};
	case =>
		return void;
	};
	if (len(callee_ident) == 0) return void;
	const callee_name = callee_ident[len(callee_ident) - 1];
	const entry = match (lookup_callee(srv, doc, callee_ident)) {
	case let e: *analysis::workspace_entry =>
		yield e;
	case void =>
		return void;
	};
	const fpe = match (cached_parse_or_drop_stale(srv, entry.path)) {
	case let p: *file_parse_entry =>
		yield p;
	case null =>
		return void;
	};
	const idx = match (find_decl_by_name(&fpe.pr.subunit, callee_name)) {
	case let i: size =>
		yield i;
	case void =>
		return void;
	};
	const f = match (fpe.pr.subunit.decls[idx].decl) {
	case let f: ast::decl_func =>
		yield f;
	case =>
		return void;
	};
	const ft = match (f.prototype.repr) {
	case let proto: ast::func_type =>
		yield proto;
	case =>
		return void;
	};
	return ft.result;
};

// Renders `t` with all error-flagged variants stripped — the result of `?`
// or `!` applied to an expression of type `t`. Returns void if every
// component of `t` was an error (nothing meaningful to show).
fn render_type_without_errors(
	srv: *server,
	doc: *document,
	t: *ast::_type,
) (str | void) = {
	match (t.repr) {
	case ast::error_type =>
		return void;
	case let tag: ast::tagged_type =>
		let kept: []*ast::_type = [];
		defer free(kept);
		for (let i = 0z; i < len(tag); i += 1) {
			if (type_is_error(srv, doc, tag[i].0, 0)) continue;
			append(kept, tag[i].0)!;
		};
		if (len(kept) == 0) return void;
		if (len(kept) == 1) return render_type_plain(kept[0]);
		let buf = memio::dynamic();
		defer lsp::safe_close(&buf);
		match (memio::concat(&buf, "(")) {
		case size => void;
		case =>
			return void;
		};
		for (let i = 0z; i < len(kept); i += 1) {
			if (i > 0) {
				match (memio::concat(&buf, " | ")) {
				case size => void;
				case =>
					return void;
				};
			};
			match (unparse::_type(&buf, &unparse::syn_nowrap, kept[i])) {
			case size => void;
			case =>
				return void;
			};
		};
		match (memio::concat(&buf, ")")) {
		case size => void;
		case =>
			return void;
		};
		return strings::dup(memio::string(&buf)!)!;
	case =>
		return render_type_plain(t);
	};
};

fn render_type_plain(t: *ast::_type) (str | void) = {
	let buf = memio::dynamic();
	defer lsp::safe_close(&buf);
	match (unparse::_type(&buf, &unparse::syn_nowrap, t)) {
	case size => void;
	case =>
		return void;
	};
	return strings::dup(memio::string(&buf)!)!;
};

// True when `t` is an error type, either directly (`!T`) or through alias
// resolution (`type myerr = !T`, possibly chained). `depth` guards against
// pathological alias cycles.
fn type_is_error(
	srv: *server,
	doc: *document,
	t: *ast::_type,
	depth: int,
) bool = {
	if (depth >= 8) return false;
	match (t.repr) {
	case ast::error_type =>
		return true;
	case let a: ast::alias_type =>
		const d = match (lookup_decl_by_ident(srv, doc, a)) {
		case let d: *ast::decl =>
			yield d;
		case void =>
			return false;
		};
		const u = match (analysis::type_decl_underlying(d)) {
		case let u: *ast::_type =>
			yield u;
		case void =>
			return false;
		};
		return type_is_error(srv, doc, u, depth + 1);
	case =>
		return false;
	};
};

// Resolves an ident to its `decl` by searching the local subunit, the
// workspace index (qualified or via imports), and the indexed stdlib.
// Mirrors [[lookup_callee]] but returns the decl directly.
fn lookup_decl_by_ident(
	srv: *server,
	doc: *document,
	id: ast::ident,
) (*ast::decl | void) = {
	if (len(id) == 0) return void;
	const name = id[len(id) - 1];
	if (len(id) >= 2) {
		const qualifier = id[len(id) - 2];
		match (analysis::find_in_module(&srv.workspace_index, qualifier, name)) {
		case let e: *analysis::workspace_entry =>
			return decl_from_workspace_entry(srv, e, name);
		case void => void;
		};
		const cache = parse_of(doc);
		const full = analysis::full_module_for_qualifier(&cache.pr.subunit,
			qualifier);
		defer free(full);
		const mod_to_index = if (len(full) > 0) full else qualifier;
		if (ensure_stdlib_module_indexed(srv, mod_to_index)) {
			match (analysis::find_in_module(&srv.stdlib_index, qualifier, name)) {
			case let e: *analysis::workspace_entry =>
				return decl_from_workspace_entry(srv, e, name);
			case void =>
				return void;
			};
		};
		return void;
	};
	const cache = parse_of(doc);
	match (find_decl_by_name(&cache.pr.subunit, name)) {
	case let i: size =>
		return &cache.pr.subunit.decls[i];
	case void => void;
	};
	const imports = analysis::collect_imported_module_names(&cache.pr.subunit);
	defer analysis::free_str_slice(imports);
	match (analysis::find_in_imports(&srv.workspace_index, imports, name)) {
	case let e: *analysis::workspace_entry =>
		return decl_from_workspace_entry(srv, e, name);
	case void => void;
	};
	match (analysis::find_first_by_short_name(&srv.workspace_index, name)) {
	case let e: *analysis::workspace_entry =>
		return decl_from_workspace_entry(srv, e, name);
	case void =>
		return void;
	};
};

fn decl_from_workspace_entry(
	srv: *server,
	e: *analysis::workspace_entry,
	name: str,
) (*ast::decl | void) = {
	const fpe = match (cached_parse_or_drop_stale(srv, e.path)) {
	case let p: *file_parse_entry =>
		yield p;
	case null =>
		return void;
	};
	match (find_decl_by_name(&fpe.pr.subunit, name)) {
	case let i: size =>
		return &fpe.pr.subunit.decls[i];
	case void =>
		return void;
	};
};

// True when at least one expression in `exprs` textually encloses `off`.
fn case_contains(exprs: []*ast::expr, off: size) bool = {
	for (let i = 0z; i < len(exprs); i += 1) {
		const e = exprs[i];
		if (off >= e.loc.start.off: size && off <= e.loc.end.off: size) {
			return true;
		};
	};
	return false;
};

// Walks each expression in a match/switch case body.
fn walk_case_exprs(
	srv: *server,
	doc: *document,
	data: []u8,
	exprs: []*ast::expr,
	name: str,
	off: size,
) (str | void) = {
	let hit: (str | void) = void;
	for (let i = 0z; i < len(exprs); i += 1) {
		const child = exprs[i];
		if (child.loc.start.off: size > off) break;
		match (walk_for_local(srv, doc, data, child, name, off)) {
		case let r: str =>
			match (hit) {
			case let prev: str =>
				free(prev);
			case void => void;
			};
			hit = r;
		case void => void;
		};
	};
	return hit;
};

fn render_match_case_binding(mc: *ast::match_case) str = {
	let buf = memio::dynamic();
	defer lsp::safe_close(&buf);
	match (memio::concat(&buf, "(match binding) ", mc.name, ": ")) {
	case size => void;
	case =>
		return strings::dup("(match binding)")!;
	};
	match (mc._type) {
	case let t: *ast::_type =>
		match (unparse::_type(&buf, &unparse::syn_nowrap, t)) {
		case size => void;
		case => void;
		};
	case null =>
		match (memio::concat(&buf, "_")) {
		case size => void;
		case => void;
		};
	};
	return strings::dup(memio::string(&buf)!)!;
};

fn render_param_binding(p: *ast::func_param) str = {
	let buf = memio::dynamic();
	defer lsp::safe_close(&buf);
	match (memio::concat(&buf, "(parameter) ", p.name, ": ")) {
	case size => void;
	case =>
		return strings::dup("(parameter)")!;
	};
	match (unparse::_type(&buf, &unparse::syn_nowrap, p._type)) {
	case size => void;
	case => void;
	};
	return strings::dup(memio::string(&buf)!)!;
};
