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
use strconv;
use strings;

// Handles textDocument/hover. Returns a MarkupContent with the symbol's
// signature (rendered via hare::unparse) and its doc comment, when known.
//
// @param s: borrowed
export fn handle_hover(s: *server, r: lsp::request) void = {
	const (uri, pos) = match (parse_text_document_position(r.params)) {
	case let v: (str, lsp::position) =>
		yield v;
	case void =>
		send_null_result(s, r.id);
		return;
	};

	const doc = match (find_document(s, uri)) {
	case let p: *document =>
		yield p;
	case null =>
		send_null_result(s, r.id);
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
			// Last resort: an operator token like `||` or `&`.
			if (try_send_operator_hover(s, r, doc, data, off)) {
				return;
			};
			send_null_result(s, r.id);
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
	let fact = analysis::empty_ownership_fact();
	defer analysis::finish_ownership_fact(&fact);
	let found_local = false;
	const qualifier_peek = analysis::qualifier_prefix_at(data, ident_range.0);
	defer free(qualifier_peek);
	if (len(qualifier_peek) == 0) {
		match (analysis::find_by_short_name(&cache.idx, ident_str)) {
		case let p: *analysis::symbol =>
			match (find_decl_by_name(&cache.pr.subunit, ident_str)) {
			case let i: size =>
				const d = &cache.pr.subunit.decls[i];
				sig = render_decl_signature(s, doc, d);
				docs = strings::dup(p.docs)!;
				analysis::finish_ownership_fact(&fact);
				fact = ownership_for_local_symbol(p);
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
			// Resolve the binding/param node to compute ownership.
			analysis::finish_ownership_fact(&fact);
			fact = local_target_ownership(s, doc, &cache.pr.subunit, ident_str,
				ident_range.0);
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
				analysis::finish_ownership_fact(&fact);
				fact = ownership_for_builtin(ident_str);
				found_builtin = true;
			case void => void;
			};
		};
		if (!found_builtin) {
			match (workspace_hover(s, doc, data, ident_range.0, ident_str)) {
			case let r: (str, str, analysis::ownership_fact) =>
				sig = r.0;
				docs = r.1;
				analysis::finish_ownership_fact(&fact);
				fact = r.2;
			case void =>
				send_null_result(s, r.id);
				return;
			};
		};
	};
	defer free(sig);
	defer free(docs);

	const own_line = format_ownership_line(fact, s.config.hover_use_html);
	defer free(own_line);
	const md = build_hover_markdown_with_facts(s, doc, sig, docs, own_line);
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
//
// @param s: borrowed
// @param doc: borrowed
// @param data: borrowed
// @param id: borrowed
// @param md: borrowed
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
//
// @param s: borrowed
export fn handle_definition(s: *server, r: lsp::request) void = {
	send_location_for_ident(s, r);
};

// @param s: borrowed
export fn handle_declaration(s: *server, r: lsp::request) void = {
	send_location_for_ident(s, r);
};

// implementation = same as definition for Hare since there's no inheritance.
//
// @param s: borrowed
export fn handle_implementation(s: *server, r: lsp::request) void = {
	send_location_for_ident(s, r);
};

// typeDefinition: resolves the *type* of an expression at the cursor.
// If the cursor is on a name whose decl is a type, jump there. Otherwise
// walk from the binding (variable, parameter, global, const) to its
// declared type and jump to the type's declaration. Falls back to the
// workspace index for types defined in other files.
//
// @param s: borrowed
export fn handle_type_definition(s: *server, r: lsp::request) void = {
	const (uri, pos) = match (parse_text_document_position(r.params)) {
	case let v: (str, lsp::position) =>
		yield v;
	case void =>
		send_null_result(s, r.id);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document =>
		yield p;
	case null =>
		send_null_result(s, r.id);
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
		send_null_result(s, r.id);
		return;
	};
	const ident_str = strings::fromutf8(data[ident_range.0..ident_range.1])!;
	const cache = parse_of(doc);
	const qualifier_peek = analysis::qualifier_prefix_at(data, ident_range.0);
	defer free(qualifier_peek);
	if (len(qualifier_peek) == 0) {
		match (analysis::find_by_short_name(&cache.idx, ident_str)) {
		case let p: *analysis::symbol =>
			if (p.kind == analysis::symbol_kind::TYPE) {
				// Cursor on a TYPE name declared locally.
				send_location(s, r.id, uri, p.span, doc);
				return;
			};
			// Non-TYPE local symbol (global, const, function). The
			// binding walk might still find a named alias for a
			// global/const declared type. If it doesn't, we return
			// null directly — falling through to the workspace
			// lookup would let a same-named TYPE in another file
			// hijack the response, which is the wrong target for a
			// locally-bound symbol.
			if (try_send_type_def_via_binding(s, r, doc, &cache.pr.subunit, ident_str,
						off)) {
				return;
			};
			send_null_result(s, r.id);
			return;
		case void => void;
		};
		// Not in the local top-level index. Could still be a function
		// parameter or a let/const binding — find_local_binding_type
		// (inside try_send_type_def_via_binding) knows about those.
		if (try_send_type_def_via_binding(s, r, doc, &cache.pr.subunit, ident_str,
					off)) {
			return;
		};
	};
	// Module-aware workspace fallback (TYPE only). Reached for qualified
	// references (`foo::Bar`) or bare names that aren't bound anywhere in
	// the open file.
	match (workspace_lookup_aware(s, doc, data, ident_range.0, ident_str)) {
	case let e: *analysis::workspace_entry =>
		if (e.kind != analysis::symbol_kind::TYPE) {
			send_null_result(s, r.id);
			return;
		};
		send_location_for_entry(s, r.id, e);
	case void =>
		send_null_result(s, r.id);
	};
};

// Resolves a bare identifier at `off` to its declared type and emits a
// Location pointing at that type's declaration. Returns true if a Location
// was sent. Returns false — with no response written — when the binding
// can't be located, its declared type isn't a named alias, or the alias's
// decl can't be resolved; the caller decides whether to fall through to a
// workspace lookup or send null. Only named aliases are followed;
// pointers, slices, tagged unions, and other compound types are not
// chased.
//
// @param s: borrowed
// @param r: borrowed
// @param doc: borrowed
// @param su: borrowed
// @param name: borrowed
fn try_send_type_def_via_binding(
	s: *server,
	r: lsp::request,
	doc: *document,
	su: *ast::subunit,
	name: str,
	off: size,
) bool = {
	let id_arr: [1]str = [name];
	const id: ast::ident = id_arr[..];
	const lt = match (type_of_identifier(s, doc, su, id, off, 0)) {
	case let lt: located_type =>
		yield lt;
	case void =>
		return false;
	};
	const alias = match (lt.t.repr) {
	case let a: ast::alias_type =>
		yield a;
	case =>
		return false;
	};
	const lookup_doc = find_doc_for_uri(s, lt.uri);
	const d = match (resolve_alias_decl(s, lookup_doc, lt.uri, alias)) {
	case let d: *ast::decl =>
		yield d;
	case void =>
		return false;
	};
	const (text, decl_uri) = locate_decl_anywhere(s, d, lt);
	send_location_in_file(s, r.id, decl_uri, text, d.loc);
	return true;
};

// Emits a Location response for an arbitrary decl span in any file.
// Builds the file's line index on demand so this works for decls in the
// open doc, in another open doc, or in a file_parse_cache entry.
//
// @param s: borrowed
// @param id: borrowed
// @param uri: borrowed
// @param text: borrowed
fn send_location_in_file(
	s: *server,
	id: lsp::id,
	uri: str,
	text: []u8,
	loc: ast::location,
) void = {
	const line_index = analysis::build_line_index(text);
	defer free(line_index);
	const enc = position_encoding(s);
	const start_pos = analysis::byte_to_position(text, line_index, enc,
		loc.start.off: size);
	const end_pos = analysis::byte_to_position(text, line_index, enc,
		loc.end.off: size);

	let result = json::newobject();
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
	send_with_finish(s, id, result: json::value);
};

// @param s: borrowed
fn send_location_for_ident(s: *server, r: lsp::request) void = {
	const (uri, pos) = match (parse_text_document_position(r.params)) {
	case let v: (str, lsp::position) =>
		yield v;
	case void =>
		send_null_result(s, r.id);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document =>
		yield p;
	case null =>
		send_null_result(s, r.id);
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
		send_null_result(s, r.id);
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
		send_null_result(s, r.id);
	};
};

// Emits a Location response for a workspace_entry without needing the file
// open. We fetch the file via the shared parse cache so repeated jumps to
// the same file don't keep re-reading it from disk.
//
// @param s: borrowed
// @param id: borrowed
// @param e: borrowed
fn send_location_for_entry(
	s: *server,
	id: lsp::id,
	e: *analysis::workspace_entry,
) void = {
	const fpe = match (cached_parse_or_drop_stale(s, e.path)) {
	case let p: *file_parse_entry =>
		yield p;
	case null =>
		send_null_result(s, id);
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
// file), locates the matching decl, and returns (sig, docs, fact). All
// strings are freshly allocated; `fact.detail` is owned by the caller.
//
// Returns void if no workspace entry matches or the file can't be read.
//
// @param s: borrowed
// @param doc: borrowed
// @param data: borrowed
// @param ident_str: borrowed
fn workspace_hover(
	s: *server,
	doc: *document,
	data: []u8,
	ident_start: size,
	ident_str: str,
) ((str, str, analysis::ownership_fact) | void) = {
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
	const d = &fpe.pr.subunit.decls[decl_idx];
	// Cross-file decl: no open document to resolve the initializer against,
	// so pass a null doc and keep the written-type-only signature.
	const sig = render_decl_signature(s, null, d);
	const docs = strings::dup(fpe.pr.subunit.decls[decl_idx].docs)!;
	const fact = ownership_for_workspace_entry(entry);
	return (sig, docs, fact);
};

// @param s: borrowed
// @param id: borrowed
// @param uri: borrowed
// @param doc: borrowed
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

// Appends `: <inferred>` to `buf` for a top-level decl whose type was
// omitted, inferring it from `init`. A no-op when there's no document
// context (cross-file signature lookups pass a null doc) or inference fails.
//
// @param buf: borrowed
// @param srv: borrowed
// @param doc: borrowed
// @param init: borrowed
fn append_inferred_decl_type(
	buf: *memio::stream,
	srv: *server,
	doc: nullable *document,
	init: *ast::expr,
) void = {
	const d = match (doc) {
	case let d: *document =>
		yield d;
	case null =>
		return;
	};
	match (infer_type_from_init(srv, d, init)) {
	case let t: str =>
		defer free(t);
		match (memio::concat(buf, ": ", t)) {
		case size => void;
		case => void;
		};
	case void => void;
	};
};

// Renders the declaration's signature without its body (for fn) or
// initializer (for global / def). For type aliases we keep the RHS
// because that *is* the type. The intent is that hover shows just what
// the symbol is, not its full definition — e.g.
//   `export fn main() void`   (not `... = { let scan = ...; ... }`)
//   `let stdout_file: io::file`  (not `... = rt::STDOUT_FILENO`)
//
// When a top-level `def`/`let`/`const` omits its type, the type is inferred
// from the initializer (best-effort) so hover shows e.g. `def PI: f64` rather
// than a bare `def PI`. Inference requires the document context, so it only
// fires when `doc` is non-null (the decl lives in the open file); cross-file
// signature lookups pass null and keep the written-type-only behavior.
//
// @param srv: borrowed
// @param doc: borrowed
// @param d: borrowed
fn render_decl_signature(
	srv: *server,
	doc: nullable *document,
	d: *ast::decl,
) str = {
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
		case null =>
			// No written type: infer one from the initializer.
			append_inferred_decl_type(&buf, srv, doc, c.init);
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
		// With the init stripped and no written type, unparse ends right
		// after the name, so we can append the inferred type. (When a type
		// was written, it's already rendered above.)
		if (g._type is null) {
			match (g.init) {
			case let ini: *ast::expr =>
				append_inferred_decl_type(&buf, srv, doc, ini);
			case null => void;
			};
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

// @param s: borrowed
// @param doc: borrowed
// @param sig: borrowed
// @param docs: borrowed
fn build_hover_markdown(s: *server, doc: *document, sig: str, docs: str) str = {
	return build_hover_markdown_with_facts(s, doc, sig, docs, "");
};

// Variant of build_hover_markdown that appends an `extra_facts` line
// (e.g. an Ownership annotation) after the prose body. The doc comment
// is usually more relevant than the ownership label, so it goes first.
// When `extra_facts` is empty, behaves identically.
//
// @param s: borrowed
// @param doc: borrowed
// @param sig: borrowed
// @param docs: borrowed
// @param extra_facts: borrowed
fn build_hover_markdown_with_facts(
	s: *server,
	doc: *document,
	sig: str,
	docs: str,
	extra_facts: str,
) str = {
	const cleaned = clean_doc_comment(docs);
	defer free(cleaned);
	return build_hover_markdown_raw_with_facts(s, doc, sig, cleaned, extra_facts);
};

// Same as build_hover_markdown but assumes `body` is already clean
// markdown (no doc-comment leading-space stripping). Used for README
// hovers where the source is raw markdown.
//
// @param s: borrowed
// @param doc: borrowed
// @param sig: borrowed
// @param body: borrowed
// @returns: owned
export fn build_hover_markdown_raw(
	s: *server,
	doc: *document,
	sig: str,
	body: str,
) str = {
	return build_hover_markdown_raw_with_facts(s, doc, sig, body, "");
};

// @param s: borrowed
// @param doc: borrowed
// @param sig: borrowed
// @param body: borrowed
// @param extra_facts: borrowed
fn build_hover_markdown_raw_with_facts(
	s: *server,
	doc: *document,
	sig: str,
	body: str,
	extra_facts: str,
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
	if (len(extra_facts) > 0) {
		memio::concat(&buf, "\n\n")!;
		memio::concat(&buf, extra_facts)!;
	};
	return strings::dup(memio::string(&buf)!)!;
};

// Normalises a Hare doc-comment string for markdown display. Each line
// produced by hare::lex::comment is the source line minus the leading `//`,
// so it typically begins with one space (e.g. ` One diagnostic.\n`). We
// strip that single leading space per line and trim trailing whitespace so
// the markdown body reads as plain prose. Caller frees.
//
// @param docs: borrowed
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

// Looks at the bytes immediately before the ident at off and returns the
// qualifier prefix (everything before "::") as a freshly-allocated string,
// or "" if the ident is bare.
// If `off` sits on a '@' that precedes an identifier (e.g. cursor on
// the '@' of `@test`), returns the byte range covering '@' through the
// end of the identifier. Returns void otherwise. The leading '@' is
// folded back in by handle_hover for any cursor position; this helper
// only exists so cursor-on-'@' doesn't immediately fail at ident_at.
//
// @param data: borrowed
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
//
// @param s: borrowed
// @param doc: borrowed
// @param data: borrowed
// @param ident_str: borrowed
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

// @param s: borrowed
// @param id: borrowed
// @param v: owned
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
//
// @param srv: borrowed
// @param doc: borrowed
// @param su: borrowed
// @param data: borrowed
// @param name: borrowed
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
//
// @param srv: borrowed
// @param doc: borrowed
// @param data: borrowed
// @param e: borrowed
// @param name: borrowed
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
		// For-each / iterator loops rebind the loop variable to an
		// element of the iterable (`..`), a pointer to one (`&..`), or
		// the generator's unwrapped value (`=>`), not to the iterable /
		// generator expression itself. Render the element type rather
		// than echoing that expression. ACCUMULATOR loops fall through
		// to the generic binding walk.
		if (for_loop_binds_each(fr, name)) {
			return render_for_each_binding(srv, doc, fr, name);
		};
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

// @param srv: borrowed
// @param doc: borrowed
// @param data: borrowed
// @param b: borrowed
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

// Renders the hover signature for a for-each / iterator loop variable
// named `name`. Unlike an ordinary binding, the loop variable is rebound
// each iteration to an element of the iterable (`..`), a pointer to one
// (`&..`), or the generator's unwrapped value (`=>`) — never the iterable
// expression itself. Falls back to a bare `let <name>` (with no echoed
// initializer) when the element type can't be resolved. Assumes `fr` binds
// `name` (see [[for_loop_binds_each]]). Caller frees.
//
// @param srv: borrowed
// @param doc: borrowed
// @param fr: borrowed
// @param name: borrowed
// @returns: owned
fn render_for_each_binding(
	srv: *server,
	doc: *document,
	fr: ast::for_expr,
	name: str,
) str = {
	const (kind, bd) = match (for_binding_and_kind(fr)) {
	case let v: (ast::binding_kind, *ast::binding) =>
		yield v;
	case void =>
		return strings::dup(name)!;
	};
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
	match (memio::concat(&buf, kw, name)) {
	case size => void;
	case =>
		return strings::dup(name)!;
	};
	const cache = parse_of(doc);
	match (for_each_binding_type(srv, doc, &cache.pr.subunit, fr, name, 0)) {
	case let lt: located_type =>
		match (render_type_plain(lt.t)) {
		case let ts: str =>
			defer free(ts);
			// Pointer iteration binds a pointer to the element; an
			// explicitly-typed binding already spells out its own
			// type, so only synthesize the `*` for inferred element
			// types.
			const ptr = fr.kind == ast::for_kind::EACH_POINTER && bd._type is null;
			const sep = if (ptr) ": *" else ": ";
			match (memio::concat(&buf, sep, ts)) {
			case size => void;
			case => void;
			};
		case void => void;
		};
	case void => void;
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
//   - `if`/`else` expressions (recurses into the true branch, falls back
//     to the false branch).
//   - `len(x)` expressions (always `size`).
//   - binary arithmetic expressions: comparison/logical ops render as
//     `bool`; arithmetic ops recurse into the operands.
//   - bare identifiers that resolve to a local `let`/`const` binding in
//     the same file, by following the binding's declared or inferred type.
// Other forms return void; the caller falls back to echoing the source.
// @param srv: borrowed
// @param doc: borrowed
// @param init: borrowed
fn infer_type_from_init(
	srv: *server,
	doc: *document,
	init: *ast::expr,
) (str | void) = {
	return infer_type_from_init_at(srv, doc, init, 0);
};

// @param srv: borrowed
// @param doc: borrowed
// @param init: borrowed
fn infer_type_from_init_at(
	srv: *server,
	doc: *document,
	init: *ast::expr,
	depth: u32,
) (str | void) = {
	match (init.expr) {
	case let l: ast::literal_expr =>
		return type_label_for_literal(srv, doc, l, depth);
	case let c: ast::call_expr =>
		return infer_call_return_type(srv, doc, &c);
	case let c: ast::cast_expr =>
		// `x is T` is a type test that yields bool, not T. Only the
		// `x: T` (CAST) and `x as T` (ASSERTION) forms take on T.
		if (c.kind == ast::cast_kind::TEST) {
			return strings::dup("bool")!;
		};
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
	case let sw: ast::switch_expr =>
		return infer_switch_expr_type(srv, doc, &sw, depth);
	case let cmp: ast::compound_expr =>
		return infer_block_value_type(srv, doc, cmp.exprs, cmp.label, depth);
	case let ie: ast::if_expr =>
		// The compiler removes `never` when reducing the if/else result
		// type, so a diverging true branch (`if (c) abort() else x`)
		// must fall through to the false branch instead of surfacing as
		// `never`. See drop_never.
		match (drop_never(infer_type_from_init_at(srv, doc, ie.tbranch, depth))) {
		case let t: str =>
			return t;
		case void => void;
		};
		match (ie.fbranch) {
		case let fb: *ast::expr =>
			return drop_never(infer_type_from_init_at(srv, doc, fb, depth));
		case null =>
			return void;
		};
	case ast::len_expr =>
		return strings::dup("size")!;
	case ast::size_expr =>
		return strings::dup("size")!;
	case ast::align_expr =>
		return strings::dup("size")!;
	case ast::offset_expr =>
		return strings::dup("size")!;
	case let ba: ast::binarithm_expr =>
		return infer_binarithm_type(srv, doc, ba, depth);
	case let u: ast::unarithm_expr =>
		return infer_unarithm_type(srv, doc, u, init, depth);
	case let sl: ast::slice_expr =>
		return infer_slice_expr_type(srv, doc, sl, depth);
	case let al: ast::alloc_expr =>
		return infer_alloc_expr_type(srv, doc, al, depth);
	case let va: ast::variadic_expr =>
		return infer_variadic_expr_type(va);
	case ast::access_expr =>
		return infer_access_expr_type(srv, doc, init, depth);
	case =>
		return void;
	};
};

// Best-effort type of a C-variadic expression. `vaarg(ap, T)` yields the
// explicit type `T`; `vastart()` / `vaend(ap)` aren't useful binding
// initializers, so we decline them.
//
// @param va: borrowed
fn infer_variadic_expr_type(va: ast::variadic_expr) (str | void) = {
	match (va) {
	case let arg: ast::vaarg_expr =>
		return render_type_plain(arg._type);
	case =>
		return void;
	};
};

// Best-effort type of a binary arithmetic expression. Comparison / logical
// operators always produce `bool`; other operators take on the operand type,
// so we recurse into the left operand first and fall back to the right when
// the left can't be inferred.
//
// @param srv: borrowed
// @param doc: borrowed
fn infer_binarithm_type(
	srv: *server,
	doc: *document,
	ba: ast::binarithm_expr,
	depth: u32,
) (str | void) = {
	switch (ba.op) {
	case ast::binarithm_op::LAND,
	ast::binarithm_op::LOR,
	ast::binarithm_op::LXOR,
	ast::binarithm_op::LEQUAL,
	ast::binarithm_op::NEQUAL,
	ast::binarithm_op::LESS,
	ast::binarithm_op::LESSEQ,
	ast::binarithm_op::GT,
	ast::binarithm_op::GTEQ =>
		return strings::dup("bool")!;
	case =>
		match (infer_type_from_init_at(srv, doc, ba.lvalue, depth)) {
		case let t: str =>
			return t;
		case void => void;
		};
		return infer_type_from_init_at(srv, doc, ba.rvalue, depth);
	};
};

// Best-effort type of a unary arithmetic expression:
//   &x  ->  *T  (a pointer to the operand's type)
//   *p  ->  the referent type (pointer dereference)
//   -x  ->  the operand's type (numeric negation)
//   ~x  ->  the operand's type (bitwise complement)
//   !x  ->  bool (logical negation)
// The `&`/`*` arms route the operand through the receiver-resolution engine
// (which knows how to resolve lvalues and chase pointer/alias wrappers);
// `-`/`~` recurse through the string engine, which handles the wider set of
// numeric operand forms.
//
// @param srv: borrowed
// @param doc: borrowed
// @param u: borrowed
// @param init: borrowed
fn infer_unarithm_type(
	srv: *server,
	doc: *document,
	u: ast::unarithm_expr,
	init: *ast::expr,
	depth: u32,
) (str | void) = {
	switch (u.op) {
	case ast::unarithm_op::LNOT =>
		return strings::dup("bool")!;
	case ast::unarithm_op::MINUS, ast::unarithm_op::BNOT =>
		return infer_type_from_init_at(srv, doc, u.operand, depth);
	case ast::unarithm_op::ADDR =>
		const cache = parse_of(doc);
		const lt = match (type_of_expr(srv, doc, &cache.pr.subunit, u.operand,
			depth: int)) {
		case let lt: located_type =>
			yield lt;
		case void =>
			return void;
		};
		const inner = match (render_type_plain(lt.t)) {
		case let s: str =>
			yield s;
		case void =>
			return void;
		};
		defer free(inner);
		return strings::concat("*", inner)!;
	case ast::unarithm_op::DEREF =>
		// type_of_expr already resolves `*p` (DEREF) to the referent.
		const cache = parse_of(doc);
		match (type_of_expr(srv, doc, &cache.pr.subunit, init, depth: int)) {
		case let lt: located_type =>
			return render_type_plain(lt.t);
		case void =>
			return void;
		};
	};
};

// Best-effort type of a slice expression (`obj[a..b]`): a slice of the
// object's element type, regardless of whether the object is a slice, an
// array, an unbounded array, or a pointer to one. Resolves the object's
// element type through the receiver-resolution engine (which chases
// alias / pointer wrappers) and wraps it in `[]`.
//
// @param srv: borrowed
// @param doc: borrowed
// @param sl: borrowed
fn infer_slice_expr_type(
	srv: *server,
	doc: *document,
	sl: ast::slice_expr,
	depth: u32,
) (str | void) = {
	const cache = parse_of(doc);
	const obj = match (type_of_expr(srv, doc, &cache.pr.subunit, sl.object,
		depth: int)) {
	case let lt: located_type =>
		yield lt;
	case void =>
		return void;
	};
	const elem = match (element_type_in_type(srv, obj, depth: int)) {
	case let e: located_type =>
		yield e;
	case void =>
		return void;
	};
	const inner = match (render_type_plain(elem.t)) {
	case let s: str =>
		yield s;
	case void =>
		return void;
	};
	defer free(inner);
	return strings::concat("[]", inner)!;
};

// Best-effort type of an allocation expression. Every `alloc(...)` in Hare
// v0.26.0 yields a `(... | nomem)` tagged union (see harec check_expr_alloc):
//   alloc(x)            -> (*T | nomem)   (object: T is x's type)
//   alloc(x...)         -> ([]T | nomem)  (slice copy: T is x's element type)
//   alloc(x, cap)       -> ([]T | nomem)  (slice with capacity; also COPY form)
// The object form uses the string engine on the initializer (so literals,
// calls, etc. resolve); the slice forms resolve the initializer's element
// type through the receiver engine (the initializer is a slice/array lvalue).
//
// @param srv: borrowed
// @param doc: borrowed
// @param al: borrowed
fn infer_alloc_expr_type(
	srv: *server,
	doc: *document,
	al: ast::alloc_expr,
	depth: u32,
) (str | void) = {
	switch (al.form) {
	case ast::alloc_form::OBJECT =>
		const inner = match (infer_type_from_init_at(srv, doc, al.init, depth)) {
		case let s: str =>
			yield s;
		case void =>
			return void;
		};
		defer free(inner);
		return strings::concat("(*", inner, " | nomem)")!;
	case ast::alloc_form::COPY =>
		const cache = parse_of(doc);
		const lt = match (type_of_expr(srv, doc, &cache.pr.subunit, al.init,
			depth: int)) {
		case let lt: located_type =>
			yield lt;
		case void =>
			return void;
		};
		const elem = match (element_type_in_type(srv, lt, depth: int)) {
		case let e: located_type =>
			yield e;
		case void =>
			return void;
		};
		const inner = match (render_type_plain(elem.t)) {
		case let s: str =>
			yield s;
		case void =>
			return void;
		};
		defer free(inner);
		return strings::concat("([]", inner, " | nomem)")!;
	};
};

// Infers the type of an access-expression init: a bare identifier (`x`), a
// qualified identifier (`pkg::y`), struct/union field access (`recv.field`),
// index access (`xs[i]`), or tuple field access (`tup.N`).
//
// A single-segment identifier that names a same-file local `let`/`const`/`def`
// binding is resolved through the string engine, which understands more init
// forms (literals, `match`, `if`, binary arithmetic, ...) than `type_of_expr`.
// Everything else — qualified identifiers, single-segment globals, and the
// field / index / tuple access forms — is routed through the receiver-
// resolution engine (`type_of_expr`) and its located type rendered, so these
// forms reuse Engine B's resolvers instead of re-implementing them here.
//
// @param srv: borrowed
// @param doc: borrowed
// @param init: borrowed
fn infer_access_expr_type(
	srv: *server,
	doc: *document,
	init: *ast::expr,
	depth: u32,
) (str | void) = {
	if (depth >= srv.config.inlay_hints_inferred_types_max_depth) return void;
	const cache = parse_of(doc);
	const a = match (init.expr) {
	case let a: ast::access_expr =>
		yield a;
	case =>
		return void;
	};
	match (a) {
	case let id: ast::access_identifier =>
		if (len(id) == 1) {
			match (find_local_binding_node(&cache.pr.subunit, id[0],
				init.loc.start.off: size)) {
			case let b: *ast::binding =>
				match (b._type) {
				case let t: *ast::_type =>
					return render_type_plain(t);
				case null =>
					return infer_type_from_init_at(srv, doc, b.init, depth + 1);
				};
			case void => void;
			// Not a local binding: fall through to
			// type_of_expr, which resolves globals /
			// workspace / stdlib decls.

			};
		};
	case => void;
	};
	// Qualified identifier, single-segment global, or field / index /
	// tuple access: delegate to the receiver-resolution engine and render
	// the located type.
	match (type_of_expr(srv, doc, &cache.pr.subunit, init, depth: int)) {
	case let lt: located_type =>
		return render_type_plain(lt.t);
	case void =>
		return void;
	};
};

// Walks the subunit for the `let`/`const` binding of `name` whose lexical
// scope contains `off`, returning the binding node. Mirrors the structural
// walk in walk_for_local but exposes the raw binding so the caller can read
// its declared or initializer type instead of rendering a hover string.
//
// @param su: borrowed
// @param name: borrowed
fn find_local_binding_node(
	su: *ast::subunit,
	name: str,
	off: size,
) (*ast::binding | void) = {
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
		const body = match (f.body) {
		case let e: *ast::expr =>
			yield e;
		case null =>
			return void;
		};
		return walk_for_local_binding_node(body, name, off);
	};
	return void;
};

// @param e: borrowed
// @param name: borrowed
fn walk_for_local_binding_node(
	e: *ast::expr,
	name: str,
	off: size,
) (*ast::binding | void) = {
	match (e.expr) {
	case let b: ast::binding_expr =>
		for (let i = 0z; i < len(b.bindings); i += 1) {
			const bd = &b.bindings[i];
			for (let j = 0z; j < len(bd.names); j += 1) {
				if (bd.names[j] != name) continue;
				return bd;
			};
		};
		return walk_for_local_binding_node(b.bindings[0].init, name, off);
	case let c: ast::compound_expr =>
		let hit: (*ast::binding | void) = void;
		for (let i = 0z; i < len(c.exprs); i += 1) {
			const child = c.exprs[i];
			if (child.loc.start.off: size > off) break;
			match (walk_for_local_binding_node(child, name, off)) {
			case let r: *ast::binding =>
				hit = r;
			case void => void;
			};
		};
		return hit;
	case let ie: ast::if_expr =>
		match (walk_for_local_binding_node(ie.tbranch, name, off)) {
		case let r: *ast::binding =>
			return r;
		case void => void;
		};
		match (ie.fbranch) {
		case let fb: *ast::expr =>
			return walk_for_local_binding_node(fb, name, off);
		case null =>
			return void;
		};
	case let fr: ast::for_expr =>
		match (fr.bindings) {
		case let b: *ast::expr =>
			match (walk_for_local_binding_node(b, name, off)) {
			case let r: *ast::binding =>
				return r;
			case void => void;
			};
		case null => void;
		};
		return walk_for_local_binding_node(fr.body, name, off);
	case =>
		return void;
	};
};

// `never` is the bottom type: the compiler drops it when reducing a
// result type (harec type_store_reduce_result, "Remove never"), so a
// diverging sub-expression - a `never`-returning call like
// `fmt::fatal(...)`, `abort()`, `os::exit(...)` - contributes nothing to
// a `match` union or an `if`/`else` result. Frees and discards a "never"
// inference (returning void); otherwise passes the owned string through.
//
// @param t: owned
// @returns: owned
fn drop_never(t: (str | void)) (str | void) = {
	match (t) {
	case let s: str =>
		if (s == "never") {
			free(s);
			return void;
		};
		return s;
	case void =>
		return void;
	};
};

// Best-effort type for a match expression: the union of each case's
// contributed value type, deduplicated. Cases whose body always diverges
// (return / abort) contribute nothing. Returns void if no case yields a
// usable type, in which case the caller falls back to echoing the source.
//
// @param srv: borrowed
// @param doc: borrowed
// @param m: borrowed
fn infer_match_expr_type(
	srv: *server,
	doc: *document,
	m: *ast::match_expr,
) (str | void) = {
	let parts: []str = [];
	defer analysis::free_str_slice(parts);
	for (let i = 0z; i < len(m.cases); i += 1) {
		const mc = &m.cases[i];
		match (drop_never(infer_case_value_type(srv, doc, mc))) {
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
//
// @param srv: borrowed
// @param doc: borrowed
// @param mc: borrowed
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
//
// @param srv: borrowed
// @param doc: borrowed
// @param mc: borrowed
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
//
// @param srv: borrowed
// @param doc: borrowed
// @param mc: borrowed
// @param e: borrowed
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
//
// @param mc: borrowed
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

// @param haystack: borrowed
// @param needle: borrowed
fn contains_str(haystack: []str, needle: str) bool = {
	for (let i = 0z; i < len(haystack); i += 1) {
		if (haystack[i] == needle) return true;
	};
	return false;
};

// Best-effort value type of a compound block (or a match/switch case body,
// which Hare lowers to a compound — see harec check_expr_match /
// check_expr_switch). A block's value is the union of the value types of the
// `yield` statements that target it, plus `void` when control can fall off
// the end (Hare inserts an implicit `yield void` there). A bare trailing
// expression is NOT the block's value: only an explicit `yield` contributes.
// Diverging statements contribute nothing. Only top-level yields are
// considered; yields nested in deeper branches or blocks target those scopes
// and are a best-effort gap.
//
// `depth` is the current inference depth; it is threaded through the yield /
// fall-through helpers (which recurse via infer_type_from_init_at at
// depth + 1) so a self- or mutually-referential binding reached through a
// yield trips the cycle guard in infer_access_expr_type instead of recursing
// until the stack overflows.
//
// @param srv: borrowed
// @param doc: borrowed
// @param exprs: borrowed
// @param label: borrowed
fn infer_block_value_type(
	srv: *server,
	doc: *document,
	exprs: []*ast::expr,
	label: ast::label,
	depth: u32,
) (str | void) = {
	let parts: []str = [];
	defer analysis::free_str_slice(parts);
	for (let i = 0z; i < len(exprs); i += 1) {
		const y = match (exprs[i].expr) {
		case let y: ast::yield_expr =>
			yield y;
		case =>
			continue;
		};
		// An unlabeled yield targets the innermost block (this one); a
		// labeled yield targets this block only if the labels match.
		if (len(y.label) != 0 && y.label != label) {
			continue;
		};
		match (drop_never(type_of_yield_expr_value(srv, doc, y, depth))) {
		case let t: str =>
			if (!contains_str(parts, t)) {
				append(parts, t)!;
			} else {
				free(t);
			};
		case void => void;
		};
	};
	// Implicit `yield void` if control can reach the end of the block.
	if (len(exprs) == 0 ||
			block_falls_through(srv, doc, exprs[len(exprs) - 1], depth)) {
		const v = strings::dup("void")!;
		if (!contains_str(parts, v)) {
			append(parts, v)!;
		} else {
			free(v);
		};
	};
	if (len(parts) == 0) return void;
	if (len(parts) == 1) return strings::dup(parts[0])!;
	const joined = strings::join(" | ", parts...)!;
	defer free(joined);
	return strings::concat("(", joined, ")")!;
};

// Type of a `yield <value>`'s value, or void for a bare `yield` (which
// contributes void). Recurses at depth + 1 so cycles through the yield value
// are bounded by the inference depth guard. Caller frees.
//
// @param srv: borrowed
// @param doc: borrowed
fn type_of_yield_expr_value(
	srv: *server,
	doc: *document,
	y: ast::yield_expr,
	depth: u32,
) (str | void) = {
	match (y.value) {
	case let v: *ast::expr =>
		return infer_type_from_init_at(srv, doc, v, depth + 1);
	case null =>
		return strings::dup("void")!;
	};
};

// True when control can fall through past the block's last statement `last`
// to the end of the block (so the block contributes an implicit `yield void`).
// Control-transfer statements (yield / return / break / continue) and the
// always-diverging `abort()` form never fall through; neither does a trailing
// expression whose type is `never` (e.g. a never-returning call).
//
// @param srv: borrowed
// @param doc: borrowed
// @param last: borrowed
fn block_falls_through(
	srv: *server,
	doc: *document,
	last: *ast::expr,
	depth: u32,
) bool = {
	match (last.expr) {
	case ast::yield_expr =>
		return false;
	case ast::return_expr =>
		return false;
	case ast::break_expr =>
		return false;
	case ast::continue_expr =>
		return false;
	case let a: ast::assert_expr =>
		// `abort()` / `abort("msg")` (no condition) always diverges;
		// `assert(cond)` can pass and fall through.
		return !(a.cond is null);
	case => void;
	};
	// Recurse at depth + 1 so a self-referential trailing expression is
	// bounded by the inference depth guard rather than overflowing.
	match (infer_type_from_init_at(srv, doc, last, depth + 1)) {
	case let t: str =>
		defer free(t);
		return t != "never";
	case void =>
		return true;
	};
};

// Best-effort type for a switch expression: the union of each case's value
// type, deduplicated. Each case body is a compound block (see harec
// check_expr_switch), so its value is computed the same way as any block.
// Cases that always diverge contribute nothing.
//
// @param srv: borrowed
// @param doc: borrowed
// @param sw: borrowed
fn infer_switch_expr_type(
	srv: *server,
	doc: *document,
	sw: *ast::switch_expr,
	depth: u32,
) (str | void) = {
	let parts: []str = [];
	defer analysis::free_str_slice(parts);
	for (let i = 0z; i < len(sw.cases); i += 1) {
		const sc = &sw.cases[i];
		match (drop_never(
			infer_block_value_type(srv, doc, sc.exprs, sw.label, depth))) {
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

// Infers the type of an init expression after stripping any error-flagged
// variants from its resulting type. Used for the inner expression of `?` and
// `!`, which both yield the non-error component of the inner type.
//
// @param srv: borrowed
// @param doc: borrowed
// @param inner: borrowed
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

// @param srv: borrowed
// @param doc: borrowed
// @param l: borrowed
fn type_label_for_literal(
	srv: *server,
	doc: *document,
	l: ast::literal_expr,
	depth: u32,
) (str | void) = {
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
	case let arr: ast::array_literal =>
		return array_literal_label(srv, doc, arr, depth);
	case let st: ast::struct_literal =>
		return struct_literal_label(st);
	case let tup: ast::tuple_literal =>
		return tuple_literal_label(srv, doc, tup, depth);
	};
};

// D1: renders an array literal's type as `[N]T` (or `[_]T` for an expanding
// `[v...]` literal whose length is contextual). T is the type of the first
// element. Falls back to `[_]_` for an empty literal or an unresolvable
// element type.
//
// @param srv: borrowed
// @param doc: borrowed
// @param arr: borrowed
fn array_literal_label(
	srv: *server,
	doc: *document,
	arr: ast::array_literal,
	depth: u32,
) (str | void) = {
	if (len(arr.values) == 0) return strings::dup("[_]_")!;
	const elem = match (infer_type_from_init_at(srv, doc, arr.values[0], depth)) {
	case let s: str =>
		yield s;
	case void =>
		return strings::dup("[_]_")!;
	};
	defer free(elem);
	// `[v...]` repeats its last value to fill a context-sized array, so the
	// length isn't known from the literal alone.
	if (arr.expand) {
		return strings::concat("[_]", elem)!;
	};
	return strings::concat("[", strconv::ztos(len(arr.values)), "]", elem)!;
};

// D2: renders a struct literal's type. A named literal (`point { ... }`)
// shows the type name; an anonymous `struct { ... }` literal keeps the
// generic label.
//
// @param st: borrowed
fn struct_literal_label(st: ast::struct_literal) (str | void) = {
	if (len(st.alias) == 0) {
		return strings::dup("struct { ... }")!;
	};
	let buf = memio::dynamic();
	defer lsp::safe_close(&buf);
	match (unparse::ident(&buf, st.alias)) {
	case size => void;
	case =>
		return strings::dup("struct { ... }")!;
	};
	return strings::dup(memio::string(&buf)!)!;
};

// D3: renders a tuple literal's type as `(T, U, ...)` with each element's
// inferred type. Falls back to `(...)` if any element type can't be resolved.
//
// @param srv: borrowed
// @param doc: borrowed
// @param tup: borrowed
fn tuple_literal_label(
	srv: *server,
	doc: *document,
	tup: ast::tuple_literal,
	depth: u32,
) (str | void) = {
	if (len(tup) == 0) return strings::dup("(...)")!;
	let parts: []str = [];
	defer analysis::free_str_slice(parts);
	for (let i = 0z; i < len(tup); i += 1) {
		match (infer_type_from_init_at(srv, doc, tup[i], depth)) {
		case let s: str =>
			append(parts, s)!;
		case void =>
			return strings::dup("(...)")!;
		};
	};
	const joined = strings::join(", ", parts...)!;
	defer free(joined);
	return strings::concat("(", joined, ")")!;
};

// Resolves the callee of a direct call expression and renders its return
// type, e.g. `bufio::newscanner(...)` -> `bufio::scanner`. Returns void if
// the callee isn't a direct access_identifier or can't be resolved.
//
// @param srv: borrowed
// @param doc: borrowed
// @param c: borrowed
fn infer_call_return_type(
	srv: *server,
	doc: *document,
	c: *ast::call_expr,
) (str | void) = {
	// A direct call to a named workspace/stdlib function.
	match (infer_direct_call_return_type(srv, doc, c)) {
	case let s: str =>
		return s;
	case void => void;
	};
	// A12: an indirect call through a local function pointer. Resolve the
	// callee expression's type and read the function's result type.
	const cache = parse_of(doc);
	const lt = match (type_of_expr(srv, doc, &cache.pr.subunit, c.lvalue, 0)) {
	case let lt: located_type =>
		yield lt;
	case void =>
		return void;
	};
	match (func_result_type(srv, lt, 0)) {
	case let rt: located_type =>
		return render_type_plain(rt.t);
	case void =>
		return void;
	};
};

// Resolves a direct call whose callee is a named workspace/stdlib function
// declaration, returning the rendered result type. Returns void for indirect
// callees (handled by the function-pointer fallback in the caller).
//
// @param srv: borrowed
// @param doc: borrowed
// @param c: borrowed
fn infer_direct_call_return_type(
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
//
// @param srv: borrowed
// @param doc: borrowed
// @param callee_ident: borrowed
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

// @param d: borrowed
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
//
// @param srv: borrowed
// @param doc: borrowed
// @param c: borrowed
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
//
// @param srv: borrowed
// @param doc: borrowed
// @param t: borrowed
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

// @param t: borrowed
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
//
// @param srv: borrowed
// @param doc: borrowed
// @param t: borrowed
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
//
// @param srv: borrowed
// @param doc: borrowed
// @param id: borrowed
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

// @param srv: borrowed
// @param e: borrowed
// @param name: borrowed
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
//
// @param exprs: borrowed
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
//
// @param srv: borrowed
// @param doc: borrowed
// @param data: borrowed
// @param exprs: borrowed
// @param name: borrowed
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

// @param mc: borrowed
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

// @param p: borrowed
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
