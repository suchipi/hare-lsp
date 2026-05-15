// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Completion. Combines several sources:
//   1. Hare keywords.
//   2. File-local declarations (from analysis::index on the open document).
//   3. Workspace-wide declarations (from the workspace index).
//   4. Module-member completion when the prefix is `mod::`.
//   5. Struct/union field completion when the prefix is `<expr>.`.
//
// Member completion (`<expr>.`) works by injecting a sentinel identifier
// at the cursor position, re-parsing the buffer (the existing recovering
// parser produces a complete AST for `<expr>.<sentinel>`), finding the
// resulting `ast::access_field` node, resolving its receiver expression
// to a type via the shared machinery in [[struct_member.ha]], and
// enumerating the struct/union members of that type (chasing pointer,
// alias, embedded, and embedded-alias wrappers).
//
// completionItem/resolve fills in the documentation field for a selected
// item — kept lazy so the initial list stays small.

use analysis;
use encoding::json;
use hare::ast;
use hare::unparse;
use lsp;
use memio;
use strings;

// Static list of Hare keywords.
const KEYWORDS: []str = [
	"abort",
	"align",
	"alloc",
	"append",
	"as",
	"assert",
	"bool",
	"break",
	"case",
	"const",
	"continue",
	"def",
	"defer",
	"delete",
	"done",
	"else",
	"enum",
	"export",
	"f32",
	"f64",
	"false",
	"fn",
	"for",
	"free",
	"i16",
	"i32",
	"i64",
	"i8",
	"if",
	"insert",
	"int",
	"is",
	"len",
	"let",
	"match",
	"never",
	"nomem",
	"null",
	"nullable",
	"offset",
	"opaque",
	"return",
	"rune",
	"size",
	"static",
	"str",
	"struct",
	"switch",
	"true",
	"type",
	"u16",
	"u32",
	"u64",
	"u8",
	"uint",
	"uintptr",
	"union",
	"use",
	"vaarg",
	"vaend",
	"valist",
	"vastart",
	"void",
	"yield",
];

// LSP CompletionItemKind values.
def CIK_TEXT: f64 = 1.0;

def CIK_KEYWORD: f64 = 14.0;

def CIK_FUNCTION: f64 = 3.0;

def CIK_FIELD: f64 = 5.0;

def CIK_VARIABLE: f64 = 6.0;

def CIK_CLASS: f64 = 7.0;

def CIK_CONSTANT: f64 = 21.0;

def CIK_MODULE: f64 = 9.0;

// Sentinel identifier we splice in at the cursor when handling
// `<expr>.|` completion. Chosen to be unmistakably synthetic so we can
// match it exactly when walking the resulting AST. The leading
// underscores and `halsp` prefix make it impossible to collide with any
// real Hare identifier in practice — and even if a file happened to
// contain it, the sentinel would only match when the access lands at
// the cursor's exact byte offset.
def COMPLETION_SENTINEL: str = "__halsp_completion_marker__";

export fn handle_completion(s: *server, r: lsp::request) void = {
	const (uri, pos) = match (parse_pos_comp(r.params)) {
	case let v: (str, lsp::position) =>
		yield v;
	case void =>
		send_array_comp(s, r.id, []);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document =>
		yield p;
	case null =>
		send_array_comp(s, r.id, []);
		return;
	};
	const data = analysis::bytes(&doc.buf);
	const off = analysis::position_to_byte(data, doc.buf.line_index,
		position_encoding(s),
		analysis::position { line = pos.line, character = pos.character });

	// Inspect the bytes around `off` to decide which kind of completion
	// the cursor is in.
	const prefix_info = scan_completion_prefix(data, off);

	let arr: []json::value = [];

	switch (prefix_info.kind) {
	case prefix_kind::QUALIFIED =>
		// Module-qualified: list exported workspace symbols whose
		// module matches `prefix_info.module`.
		add_module_members(s, &arr, prefix_info.module, prefix_info.partial);
	case prefix_kind::MEMBER =>
		// `<expr>.<partial>`: re-parse with a sentinel, resolve the
		// receiver expression's type, and enumerate the struct/union
		// fields that the type exposes. Member completion is exclusive
		// (no keywords, locals, or workspace symbols) because the
		// grammar position only accepts a field name.
		add_struct_members(s, doc, data, &prefix_info, &arr);
	case prefix_kind::PLAIN =>
		add_keywords(&arr, prefix_info.partial);
		add_file_locals(&arr, doc, prefix_info.partial);
		add_workspace_symbols(s, doc, &arr, prefix_info.partial);
	};
	free(prefix_info.module);
	free(prefix_info.partial);

	let result = json::newobject();
	json::put(&result, "isIncomplete", false: json::value)!;
	json::put(&result, "items", arr: json::value)!;
	const v: json::value = result;
	defer json::finish(v);
	match (lsp::encode_response_result(s.out, r.id, v)) {
	case size => void;
	case => void;
	};
};

type prefix_kind = enum {
	PLAIN,
	QUALIFIED,
	MEMBER,
};

type prefix_info = struct {
	kind: prefix_kind,
	// For QUALIFIED, the "mod" before "::"; empty otherwise.
	module: str,
	// The text already typed for the completion target (between the
	// trigger — `.` or `::` — and the cursor). Used to filter the
	// emitted item list.
	partial: str,
	// Byte offset where the partial begins. For MEMBER this is the byte
	// immediately after the `.`; the sentinel is spliced in starting
	// here.
	partial_start: size,
	// Byte offset of the cursor.
	partial_end: size,
	// Byte offset of the end of the existing identifier the cursor is
	// inside (may be > partial_end if the cursor sits in the middle of
	// a word). For MEMBER, the splice replaces [partial_start, ident_end)
	// with the sentinel so the parser sees a single, complete identifier.
	ident_end: size,
};

fn scan_completion_prefix(data: []u8, off: size) prefix_info = {
	// Walk back over word bytes to find the start of the current
	// identifier-or-empty token.
	let s = off;
	for (s > 0; s -= 1) {
		const b = data[s - 1];
		if (!is_word_byte_comp(b)) break;
	};
	// Walk forward past `off` over any trailing word bytes so we capture
	// chars the user already typed when editing in the middle of an
	// existing identifier (e.g., `b.fi|eld` with cursor after `fi`). The
	// MEMBER path splices over [partial_start, ident_end) so the
	// re-parse sees a single sentinel identifier rather than
	// `<sentinel>field`.
	let e = off;
	for (e < len(data); e += 1) {
		if (!is_word_byte_comp(data[e])) break;
	};
	const partial = strings::dup(strings::fromutf8(data[s..off])!)!;

	// Member access: `<expr>.<partial>` where the dot is a real member
	// access (not part of `..`, not part of a float literal, not
	// preceded by whitespace). The byte before the dot must be one that
	// can plausibly terminate an expression - see
	// [[receiver_ends_before_dot]].
	if (s >= 1 && data[s - 1] == '.': u8 && s >= 2 &&
			receiver_ends_before_dot(data, s - 1)) {
		return prefix_info {
			kind = prefix_kind::MEMBER,
			module = strings::dup("")!,
			partial = partial,
			partial_start = s,
			partial_end = off,
			ident_end = e,
		};
	};

	// Module-qualified: `module::partial`.
	if (s >= 2 && data[s - 1] == ':': u8 && data[s - 2] == ':': u8) {
		// Walk further to capture the module ident.
		let m = s - 2;
		for (m > 0; m -= 1) {
			if (!is_word_byte_comp(data[m - 1])) break;
		};
		const module_str = strings::dup(strings::fromutf8(data[m..s - 2])!)!;
		return prefix_info {
			kind = prefix_kind::QUALIFIED,
			module = module_str,
			partial = partial,
			partial_start = s,
			partial_end = off,
			ident_end = e,
		};
	};

	return prefix_info {
		kind = prefix_kind::PLAIN,
		module = strings::dup("")!,
		partial = partial,
		partial_start = s,
		partial_end = off,
		ident_end = e,
	};
};

fn is_word_byte_comp(b: u8) bool = {
	if (b >= 'a': u8 && b <= 'z': u8) return true;
	if (b >= 'A': u8 && b <= 'Z': u8) return true;
	if (b >= '0': u8 && b <= '9': u8) return true;
	return b == '_': u8;
};

// Returns true when the byte slice ending at `dot_off` (exclusive)
// looks like an expression a member access could chain off, given that
// `data[dot_off] == '.'`. We accept `)`, `]`, `!`, `?` (postfix
// error-assert / propagate, as in `foo()!.field`), or a word ending in
// any alphanumeric/underscore - but if the preceding word is all
// digits we reject it, because `1.` is a float literal, not a member
// access on `1`. Identifiers like `buf1` or `hash32` end in a digit
// but still have non-digit characters earlier in the word, so they
// pass.
fn receiver_ends_before_dot(data: []u8, dot_off: size) bool = {
	if (dot_off == 0) return false;
	const b = data[dot_off - 1];
	if (b == ')': u8) return true;
	if (b == ']': u8) return true;
	if (b == '!': u8) return true;
	if (b == '?': u8) return true;
	if (!is_word_byte_comp(b)) return false;
	// Walk back over the word and check whether any byte is non-digit.
	// Pure-digit prefix means this `.` belongs to a numeric literal.
	let i = dot_off;
	for (i > 0; i -= 1) {
		const c = data[i - 1];
		if (!is_word_byte_comp(c)) break;
		if (c < '0': u8 || c > '9': u8) return true;
	};
	return false;
};


// sortText prefixes: clients rank lexicographically. We bias toward
// what the user typed in this file first, then workspace symbols,
// then keywords. The labels following these prefixes are the
// completion text, so identical sources sort alphabetically within
// their priority band.
def SORT_LOCAL: str = "1-";

def SORT_WORKSPACE: str = "2-";

def SORT_KEYWORD: str = "3-";

fn add_keywords(arr: *[]json::value, partial: str) void = {
	let a = *arr;
	for (let i = 0z; i < len(KEYWORDS); i += 1) {
		if (len(partial) > 0 && !strings::hasprefix(KEYWORDS[i], partial)) continue;
		let item = json::newobject();
		json::set(&item, "label", KEYWORDS[i]: json::value)!;
		json::put(&item, "kind", CIK_KEYWORD)!;
		json::set(&item, "detail", "keyword": json::value)!;
		const sort = strings::concat(SORT_KEYWORD, KEYWORDS[i])!;
		defer free(sort);
		json::set(&item, "sortText", sort: json::value)!;
		append(a, item: json::value)!;
	};
	*arr = a;
};

fn add_file_locals(arr: *[]json::value, doc: *document, partial: str) void = {
	let a = *arr;
	const cache = parse_of(doc);
	for (let i = 0z; i < len(cache.idx.symbols); i += 1) {
		const sym = &cache.idx.symbols[i];
		if (len(partial) > 0 &&
				!strings::hasprefix(sym.short_name, partial)) continue;
		let item = json::newobject();
		json::set(&item, "label", sym.short_name: json::value)!;
		json::put(&item, "kind", symbol_kind_to_completion(sym.kind))!;
		json::set(&item, "detail", sym.name: json::value)!;
		if (len(sym.docs) > 0) {
			json::set(&item, "documentation", sym.docs: json::value)!;
		};
		const sort = strings::concat(SORT_LOCAL, sym.short_name)!;
		defer free(sort);
		json::set(&item, "sortText", sort: json::value)!;
		if (sym.kind == analysis::symbol_kind::FUNCTION) {
			attach_function_snippet(&item, sym.short_name, sym.param_names);
		};
		append(a, item: json::value)!;
	};
	*arr = a;
};

fn add_workspace_symbols(
	s: *server,
	doc: *document,
	arr: *[]json::value,
	partial: str,
) void = {
	let a = *arr;
	const cap = if (len(s.workspace_index.entries) < 500z) {
		yield len(s.workspace_index.entries);
	} else {
		yield 500z;
	};
	// Snapshot the doc's already-imported modules once so we can decide
	// per-entry whether to attach an auto-import edit.
	const imported = doc_imported_modules(doc);
	defer strings_free_all(imported);
	let added = 0z;
	for (let i = 0z; i < cap && added < 200z; i += 1) {
		const e = &s.workspace_index.entries[i];
		if (len(partial) > 0 && !strings::hasprefix(e.short_name, partial)) continue;
		let item = json::newobject();
		json::set(&item, "label", e.short_name: json::value)!;
		json::put(&item, "kind", symbol_kind_to_completion(e.kind))!;
		json::set(&item, "detail", e.full_name: json::value)!;
		if (len(e.docs) > 0) {
			json::set(&item, "documentation", e.docs: json::value)!;
		};
		const sort = strings::concat(SORT_WORKSPACE, e.short_name)!;
		defer free(sort);
		json::set(&item, "sortText", sort: json::value)!;
		if (e.kind == analysis::symbol_kind::FUNCTION) {
			attach_function_snippet(&item, e.short_name, e.param_names);
		};
		attach_auto_import(s, doc, &item, e.module, imported);
		append(a, item: json::value)!;
		added += 1;
	};
	*arr = a;
};

// Returns the list of module names already imported by `doc`, using the
// last segment of each import's ident path as the module name. Caller
// frees with strings_free_all.
fn doc_imported_modules(doc: *document) []str = {
	let out: []str = [];
	const cache = parse_of(doc);
	const pr = &cache.pr;
	for (let i = 0z; i < len(pr.subunit.imports); i += 1) {
		const imp = &pr.subunit.imports[i];
		if (len(imp.ident) == 0) continue;
		append(out, strings::dup(imp.ident[len(imp.ident) - 1])!)!;
	};
	return out;
};

fn strings_free_all(list: []str) void = {
	for (let i = 0z; i < len(list); i += 1) {
		free(list[i]);
	};
	free(list);
};

// When the entry's module is non-empty and not present in the doc's
// existing imports, attaches an additionalTextEdits to the completion
// item that inserts `use <module>;` near the top of the file. The
// inserted module is the leaf directory name (workspace_entry.module);
// nested module paths like `encoding::json` are not yet recovered.
fn attach_auto_import(
	s: *server,
	doc: *document,
	item: *json::object,
	module: str,
	imported: []str,
) void = {
	if (len(module) == 0) return;
	for (let i = 0z; i < len(imported); i += 1) {
		if (imported[i] == module) return;
	};
	const data = analysis::bytes(&doc.buf);
	const cache = parse_of(doc);
	const pr = &cache.pr;
	const enc = position_encoding(s);
	const line_idx = doc.buf.line_index;
	// Decide where to insert: after the last existing `use` (on its own
	// line) or at the top of the file.
	let insert_off: size = 0;
	let new_text = "";
	if (len(pr.subunit.imports) > 0) {
		const last = &pr.subunit.imports[len(pr.subunit.imports) - 1];
		insert_off = last.loc.end.off: size + 1;
		if (insert_off < len(data) && data[insert_off] == '\n': u8) {
			insert_off += 1;
		};
	};
	const pos = analysis::byte_to_position(data, line_idx, enc, insert_off);
	const tail = if (len(pr.subunit.imports) == 0 && len(data) > 0) "\n" else "";
	const line_text = strings::concat("use ", module, ";\n", tail)!;
	new_text = line_text;
	defer free(new_text);

	let edit = json::newobject();
	let r_obj = json::newobject();
	let s_obj = json::newobject();
	json::put(&s_obj, "line", pos.line: f64)!;
	json::put(&s_obj, "character", pos.character: f64)!;
	let e_obj = json::newobject();
	json::put(&e_obj, "line", pos.line: f64)!;
	json::put(&e_obj, "character", pos.character: f64)!;
	json::put(&r_obj, "start", s_obj)!;
	json::put(&r_obj, "end", e_obj)!;
	json::put(&edit, "range", r_obj)!;
	json::set(&edit, "newText", new_text: json::value)!;

	let edits: []json::value = [];
	append(edits, edit: json::value)!;
	json::put(item, "additionalTextEdits", edits: json::value)!;
};

fn add_module_members(
	s: *server,
	arr: *[]json::value,
	module: str,
	partial: str,
) void = {
	let a = *arr;
	for (let i = 0z; i < len(s.workspace_index.entries); i += 1) {
		const e = &s.workspace_index.entries[i];
		if (e.module != module) continue;
		if (!e.exported) continue;
		if (len(partial) > 0 && !strings::hasprefix(e.short_name, partial)) continue;
		let item = json::newobject();
		json::set(&item, "label", e.short_name: json::value)!;
		json::put(&item, "kind", symbol_kind_to_completion(e.kind))!;
		json::set(&item, "detail", e.full_name: json::value)!;
		if (len(e.docs) > 0) {
			json::set(&item, "documentation", e.docs: json::value)!;
		};
		const sort = strings::concat(SORT_WORKSPACE, e.short_name)!;
		defer free(sort);
		json::set(&item, "sortText", sort: json::value)!;
		if (e.kind == analysis::symbol_kind::FUNCTION) {
			attach_function_snippet(&item, e.short_name, e.param_names);
		};
		append(a, item: json::value)!;
	};
	*arr = a;
};

// Member completion: re-parse the buffer with a sentinel identifier
// spliced in at the cursor, locate the resulting `access_field`, resolve
// its receiver to a type, and emit a completion item for every struct
// or union field that type exposes (chasing pointer / alias / embedded
// / embedded-alias wrappers).
//
// We invoke the recovering parser, not the stdlib one, because the rest
// of the buffer may contain unrelated parse errors that must not block
// the synthesis. The parser is fast enough at hare-lsp's typical file
// sizes that paying a full re-parse per completion request is fine.
fn parse_with_sentinel(
	data: []u8,
	info: *prefix_info,
	uri: str,
	add_semi: bool,
) analysis::parse_result = {
	const sentinel_bytes = strings::toutf8(COMPLETION_SENTINEL);
	let synth: []u8 = alloc([],
		len(data) + len(sentinel_bytes) + 1)!;
	defer free(synth);
	append(synth, data[..info.partial_start]...)!;
	append(synth, sentinel_bytes...)!;
	if (add_semi) {
		append(synth, ';': u8)!;
	};
	if (info.ident_end < len(data)) {
		append(synth, data[info.ident_end..]...)!;
	};
	return analysis::parse_recover(synth, uri);
};

fn add_struct_members(
	s: *server,
	doc: *document,
	data: []u8,
	info: *prefix_info,
	arr: *[]json::value,
) void = {
	// We try two splices: one with just the sentinel, and one with an
	// extra `;` after it. The bare splice handles mid-expression cases
	// like `foo(a, b.|, c)`, struct literal initializers (`{ v = b.| }`),
	// and match heads (`match (b.|)`). The `;`-suffixed splice handles
	// end-of-statement cases like `{ b.| }` where the parser would
	// otherwise reject the missing terminator. Whichever variant the
	// AST walker finds the sentinel in is the right one.
	let pr = parse_with_sentinel(data, info, doc.uri, false);
	let af_match = find_sentinel_access_field(&pr.subunit);
	if (af_match is void) {
		analysis::finish_parse_result(&pr);
		pr = parse_with_sentinel(data, info, doc.uri, true);
		af_match = find_sentinel_access_field(&pr.subunit);
	};
	defer analysis::finish_parse_result(&pr);
	const af = match (af_match) {
	case let af: ast::access_field =>
		yield af;
	case void =>
		return;
	};

	const recv_type = match (type_of_expr(s, doc, &pr.subunit, af.object, 0)) {
	case let lt: located_type =>
		yield lt;
	case void =>
		return;
	};

	let a = *arr;
	let seen: []str = [];
	defer strings_free_all(seen);
	emit_struct_member_completions(s, doc, recv_type, info.partial, &a, &seen, 0);
	*arr = a;
};

// Locates the unique `access_field` whose field name is the completion
// sentinel anywhere in `su`. The sentinel string is deliberately
// unlikely to collide with any real source identifier, so we don't need
// to bound the search by position - a name match in the AST means we
// found the splice site.
fn find_sentinel_access_field(su: *ast::subunit) (ast::access_field | void) = {
	for (let i = 0z; i < len(su.decls); i += 1) {
		match (scan_decl_for_sentinel(&su.decls[i])) {
		case let af: ast::access_field =>
			return af;
		case void => void;
		};
	};
	return void;
};

fn scan_decl_for_sentinel(d: *ast::decl) (ast::access_field | void) = {
	match (d.decl) {
	case let f: ast::decl_func =>
		match (f.body) {
		case let e: *ast::expr =>
			return scan_expr_for_sentinel(e);
		case null =>
			return void;
		};
	case let g: ast::decl_global =>
		match (g.init) {
		case let e: *ast::expr =>
			return scan_expr_for_sentinel(e);
		case null =>
			return void;
		};
	case let c: ast::decl_const =>
		return scan_expr_for_sentinel(c.init);
	case =>
		return void;
	};
};

fn scan_expr_for_sentinel(e: *ast::expr) (ast::access_field | void) = {
	match (e.expr) {
	case let a: ast::access_expr =>
		match (a) {
		case ast::access_identifier =>
			return void;
		case let idx: ast::access_index =>
			match (scan_expr_for_sentinel(idx.object)) {
			case let af: ast::access_field => return af;
			case void => void;
			};
			return scan_expr_for_sentinel(idx.index);
		case let fd: ast::access_field =>
			match (scan_expr_for_sentinel(fd.object)) {
			case let af: ast::access_field => return af;
			case void => void;
			};
			if (fd.field == COMPLETION_SENTINEL) return fd;
			return void;
		case let tu: ast::access_tuple =>
			match (scan_expr_for_sentinel(tu.object)) {
			case let af: ast::access_field => return af;
			case void => void;
			};
			return scan_expr_for_sentinel(tu.value);
		};
	case let c: ast::call_expr =>
		match (scan_expr_for_sentinel(c.lvalue)) {
		case let af: ast::access_field => return af;
		case void => void;
		};
		for (let i = 0z; i < len(c.args); i += 1) {
			match (scan_expr_for_sentinel(c.args[i])) {
			case let af: ast::access_field => return af;
			case void => void;
			};
		};
		return void;
	case let cmp: ast::compound_expr =>
		for (let i = 0z; i < len(cmp.exprs); i += 1) {
			match (scan_expr_for_sentinel(cmp.exprs[i])) {
			case let af: ast::access_field => return af;
			case void => void;
			};
		};
		return void;
	case let b: ast::binarithm_expr =>
		match (scan_expr_for_sentinel(b.lvalue)) {
		case let af: ast::access_field => return af;
		case void => void;
		};
		return scan_expr_for_sentinel(b.rvalue);
	case let u: ast::unarithm_expr =>
		return scan_expr_for_sentinel(u.operand);
	case let ca: ast::cast_expr =>
		return scan_expr_for_sentinel(ca.value);
	case let bd: ast::binding_expr =>
		for (let i = 0z; i < len(bd.bindings); i += 1) {
			match (scan_expr_for_sentinel(bd.bindings[i].init)) {
			case let af: ast::access_field => return af;
			case void => void;
			};
		};
		return void;
	case let asn: ast::assign_expr =>
		match (asn.object) {
		case let p: *ast::expr =>
			match (scan_expr_for_sentinel(p)) {
			case let af: ast::access_field => return af;
			case void => void;
			};
		case null => void;
		};
		return scan_expr_for_sentinel(asn.value);
	case let i: ast::if_expr =>
		match (scan_expr_for_sentinel(i.cond)) {
		case let af: ast::access_field => return af;
		case void => void;
		};
		match (scan_expr_for_sentinel(i.tbranch)) {
		case let af: ast::access_field => return af;
		case void => void;
		};
		match (i.fbranch) {
		case let p: *ast::expr =>
			return scan_expr_for_sentinel(p);
		case null =>
			return void;
		};
	case let r: ast::return_expr =>
		match (r) {
		case let p: *ast::expr =>
			return scan_expr_for_sentinel(p);
		case null =>
			return void;
		};
	case let p: ast::propagate_expr =>
		return scan_expr_for_sentinel(p);
	case let ea: ast::error_assert_expr =>
		return scan_expr_for_sentinel(ea);
	case let d: ast::defer_expr =>
		return scan_expr_for_sentinel(d: *ast::expr);
	case let y: ast::yield_expr =>
		match (y.value) {
		case let p: *ast::expr =>
			return scan_expr_for_sentinel(p);
		case null =>
			return void;
		};
	case let fr: ast::for_expr =>
		match (fr.bindings) {
		case let p: *ast::expr =>
			match (scan_expr_for_sentinel(p)) {
			case let af: ast::access_field => return af;
			case void => void;
			};
		case null => void;
		};
		match (fr.cond) {
		case let p: *ast::expr =>
			match (scan_expr_for_sentinel(p)) {
			case let af: ast::access_field => return af;
			case void => void;
			};
		case null => void;
		};
		match (fr.afterthought) {
		case let p: *ast::expr =>
			match (scan_expr_for_sentinel(p)) {
			case let af: ast::access_field => return af;
			case void => void;
			};
		case null => void;
		};
		return scan_expr_for_sentinel(fr.body);
	case let m: ast::match_expr =>
		match (scan_expr_for_sentinel(m.value)) {
		case let af: ast::access_field => return af;
		case void => void;
		};
		for (let i = 0z; i < len(m.cases); i += 1) {
			const mc = &m.cases[i];
			for (let j = 0z; j < len(mc.exprs); j += 1) {
				match (scan_expr_for_sentinel(mc.exprs[j])) {
				case let af: ast::access_field => return af;
				case void => void;
				};
			};
		};
		return void;
	case let sw: ast::switch_expr =>
		match (scan_expr_for_sentinel(sw.value)) {
		case let af: ast::access_field => return af;
		case void => void;
		};
		for (let i = 0z; i < len(sw.cases); i += 1) {
			const sc = &sw.cases[i];
			for (let j = 0z; j < len(sc.exprs); j += 1) {
				match (scan_expr_for_sentinel(sc.exprs[j])) {
				case let af: ast::access_field => return af;
				case void => void;
				};
			};
		};
		return void;
	case let ae: ast::assert_expr =>
		match (ae.cond) {
		case let p: *ast::expr =>
			match (scan_expr_for_sentinel(p)) {
			case let af: ast::access_field => return af;
			case void => void;
			};
		case null => void;
		};
		match (ae.message) {
		case let p: *ast::expr =>
			return scan_expr_for_sentinel(p);
		case null => void;
		};
		return void;
	case let l: ast::len_expr =>
		return scan_expr_for_sentinel(l);
	case let a: ast::alloc_expr =>
		match (scan_expr_for_sentinel(a.init)) {
		case let af: ast::access_field => return af;
		case void => void;
		};
		match (a.capacity) {
		case let p: *ast::expr =>
			return scan_expr_for_sentinel(p);
		case null => void;
		};
		return void;
	case let a: ast::append_expr =>
		match (scan_expr_for_sentinel(a.object)) {
		case let af: ast::access_field => return af;
		case void => void;
		};
		match (scan_expr_for_sentinel(a.value)) {
		case let af: ast::access_field => return af;
		case void => void;
		};
		match (a.length) {
		case let p: *ast::expr =>
			return scan_expr_for_sentinel(p);
		case null => void;
		};
		return void;
	case let ie: ast::insert_expr =>
		match (scan_expr_for_sentinel(ie.object)) {
		case let af: ast::access_field => return af;
		case void => void;
		};
		match (scan_expr_for_sentinel(ie.value)) {
		case let af: ast::access_field => return af;
		case void => void;
		};
		match (ie.length) {
		case let p: *ast::expr =>
			return scan_expr_for_sentinel(p);
		case null => void;
		};
		return void;
	case let d: ast::delete_expr =>
		return scan_expr_for_sentinel(d.object);
	case let f: ast::free_expr =>
		return scan_expr_for_sentinel(f);
	case let sl: ast::slice_expr =>
		match (scan_expr_for_sentinel(sl.object)) {
		case let af: ast::access_field => return af;
		case void => void;
		};
		match (sl.start) {
		case let p: *ast::expr =>
			match (scan_expr_for_sentinel(p)) {
			case let af: ast::access_field => return af;
			case void => void;
			};
		case null => void;
		};
		match (sl.end) {
		case let p: *ast::expr =>
			return scan_expr_for_sentinel(p);
		case null => void;
		};
		return void;
	case let lit: ast::literal_expr =>
		return scan_literal_for_sentinel(lit);
	case =>
		return void;
	};
};

fn scan_literal_for_sentinel(
	l: ast::literal_expr,
) (ast::access_field | void) = {
	match (l) {
	case ast::plain_literal =>
		return void;
	case let a: ast::array_literal =>
		for (let i = 0z; i < len(a.values); i += 1) {
			match (scan_expr_for_sentinel(a.values[i])) {
			case let af: ast::access_field => return af;
			case void => void;
			};
		};
		return void;
	case let s: ast::struct_literal =>
		return scan_struct_literal_for_sentinel(&s);
	case let t: ast::tuple_literal =>
		for (let i = 0z; i < len(t); i += 1) {
			match (scan_expr_for_sentinel(t[i])) {
			case let af: ast::access_field => return af;
			case void => void;
			};
		};
		return void;
	};
};

fn scan_struct_literal_for_sentinel(
	s: *ast::struct_literal,
) (ast::access_field | void) = {
	for (let i = 0z; i < len(s.fields); i += 1) {
		match (s.fields[i]) {
		case let v: ast::struct_value =>
			match (scan_expr_for_sentinel(v.init)) {
			case let af: ast::access_field => return af;
			case void => void;
			};
		case let nested: *ast::struct_literal =>
			match (scan_struct_literal_for_sentinel(nested)) {
			case let af: ast::access_field => return af;
			case void => void;
			};
		};
	};
	return void;
};

// Walks the receiver type, chasing pointer and alias wrappers, and
// pushes a completion item for every named field it discovers.
//
// `seen` is a running set of labels we've already emitted; needed
// because an alias chain or embedded struct can surface the same field
// name twice in the natural recursion, and clients dislike duplicates.
fn emit_struct_member_completions(
	s: *server,
	doc: *document,
	holder: located_type,
	partial: str,
	arr: *[]json::value,
	seen: *[]str,
	depth: int,
) void = {
	if (depth >= MEMBER_RESOLVE_MAX_DEPTH) return;
	match (holder.t.repr) {
	case let st: ast::struct_type =>
		emit_members_from_list(s, doc, holder, st.members, partial, arr,
			seen, depth);
	case let ut: ast::union_type =>
		emit_members_from_list(s, doc, holder, ut: []ast::struct_member,
			partial, arr, seen, depth);
	case let p: ast::pointer_type =>
		emit_struct_member_completions(s, doc,
			located_type {
				t = p.referent,
				text = holder.text,
				uri = holder.uri,
			}, partial, arr, seen, depth + 1);
	case let a: ast::alias_type =>
		const lookup_doc: nullable *document = find_doc_for_uri(s, holder.uri);
		const d = match (resolve_alias_decl(s, lookup_doc, a)) {
		case let d: *ast::decl =>
			yield d;
		case void =>
			return;
		};
		const u = match (analysis::type_decl_underlying(d)) {
		case let u: *ast::_type =>
			yield u;
		case void =>
			return;
		};
		const (text, uri) = locate_decl_anywhere(s, d, holder);
		emit_struct_member_completions(s, doc,
			located_type { t = u, text = text, uri = uri },
			partial, arr, seen, depth + 1);
	case => void;
	};
};

fn emit_members_from_list(
	s: *server,
	doc: *document,
	holder: located_type,
	members: []ast::struct_member,
	partial: str,
	arr: *[]json::value,
	seen: *[]str,
	depth: int,
) void = {
	for (let i = 0z; i < len(members); i += 1) {
		const m = &members[i];
		match (m.member) {
		case let f: ast::struct_field =>
			// `_` fields are anonymous padding and aren't accessible
			// by name; skip them.
			if (f.name == "_") continue;
			if (len(partial) > 0 &&
					!strings::hasprefix(f.name, partial)) continue;
			if (already_emitted(*seen, f.name)) continue;
			emit_struct_field_item(f, m.docs, arr);
			let s_list = *seen;
			append(s_list, strings::dup(f.name)!)!;
			*seen = s_list;
		case let emb: ast::struct_embedded =>
			emit_struct_member_completions(s, doc,
				located_type {
					t = emb: *ast::_type,
					text = holder.text,
					uri = holder.uri,
				}, partial, arr, seen, depth + 1);
		case let alias: ast::struct_alias =>
			const lookup_doc: nullable *document =
				find_doc_for_uri(s, holder.uri);
			const d = match (resolve_alias_decl(s, lookup_doc, alias)) {
			case let d: *ast::decl =>
				yield d;
			case void =>
				continue;
			};
			const u = match (analysis::type_decl_underlying(d)) {
			case let u: *ast::_type =>
				yield u;
			case void =>
				continue;
			};
			const (text, uri) = locate_decl_anywhere(s, d, holder);
			emit_struct_member_completions(s, doc,
				located_type { t = u, text = text, uri = uri },
				partial, arr, seen, depth + 1);
		};
	};
};

fn already_emitted(seen: []str, name: str) bool = {
	for (let i = 0z; i < len(seen); i += 1) {
		if (seen[i] == name) return true;
	};
	return false;
};

fn emit_struct_field_item(
	f: ast::struct_field,
	docs: str,
	arr: *[]json::value,
) void = {
	let item = json::newobject();
	json::set(&item, "label", f.name: json::value)!;
	json::put(&item, "kind", CIK_FIELD)!;
	const type_str = render_field_type(f._type);
	defer free(type_str);
	const detail = strings::concat(f.name, ": ", type_str)!;
	defer free(detail);
	json::set(&item, "detail", detail: json::value)!;
	if (len(docs) > 0) {
		json::set(&item, "documentation", docs: json::value)!;
	};
	const sort = strings::concat(SORT_MEMBER, f.name)!;
	defer free(sort);
	json::set(&item, "sortText", sort: json::value)!;
	let a = *arr;
	append(a, item: json::value)!;
	*arr = a;
};

// Renders a type AST node for use in a completion item's `detail` line.
// Mirrors the rendering hover uses so member and hover details look
// consistent.
fn render_field_type(t: *ast::_type) str = {
	let buf = memio::dynamic();
	defer lsp::safe_close(&buf);
	match (unparse::_type(&buf, &unparse::syn_nowrap, t)) {
	case size => void;
	case =>
		return strings::dup("?")!;
	};
	return strings::dup(memio::string(&buf)!)!;
};

// sortText prefix for struct field completions. Ranks fields above
// every other source (locals, workspace symbols, keywords) so that in
// the unusual case where a non-member fallback also matched the
// partial, the fields still surface first.
def SORT_MEMBER: str = "0-";

// Attaches an insertText snippet of the form
//   name(${1:p1}, ${2:p2})$0
// plus insertTextFormat: 2 (Snippet). For zero-arg functions emits
// "name()$0". param_names may contain empty strings for unnamed params,
// in which case we substitute `p<N>`.
fn attach_function_snippet(
	item: *json::object,
	name: str,
	param_names: []str,
) void = {
	let buf: []u8 = [];
	defer free(buf);
	append(buf, strings::toutf8(name)...)!;
	append(buf, '(': u8)!;
	for (let i = 0z; i < len(param_names); i += 1) {
		if (i > 0) {
			append(buf, ',': u8)!;
			append(buf, ' ': u8)!;
		};
		append(buf, '$': u8)!;
		append(buf, '{': u8)!;
		const idx_str = fmt_size_local_comp(i + 1);
		defer free(idx_str);
		append(buf, strings::toutf8(idx_str)...)!;
		append(buf, ':': u8)!;
		if (len(param_names[i]) > 0) {
			append(buf, strings::toutf8(param_names[i])...)!;
		} else {
			append(buf, 'p': u8)!;
			append(buf, strings::toutf8(idx_str)...)!;
		};
		append(buf, '}': u8)!;
	};
	append(buf, ')': u8)!;
	append(buf, '$': u8)!;
	append(buf, '0': u8)!;
	// json::set duplicates the string, so we can pass the borrowed view.
	const view = strings::fromutf8(buf)!;
	json::set(item, "insertText", view: json::value)!;
	json::put(item, "insertTextFormat", 2: f64)!;
};

fn fmt_size_local_comp(n: size) str = {
	// Caller copies the returned bytes immediately (into a json string
	// via toutf8/fromutf8), so a local stack buffer would be unsafe —
	// it would go out of scope before the copy. Allocate a fresh string
	// each time. Caller does not free; the result is small and short-lived.
	if (n == 0) return strings::dup("0")!;
	let buf: [21]u8 = [0...];
	let i = len(buf);
	let v = n;
	for (v > 0; v /= 10) {
		i -= 1;
		buf[i] = '0': u8 + (v % 10): u8;
	};
	return strings::dup(strings::fromutf8(buf[i..])!)!;
};

fn symbol_kind_to_completion(k: analysis::symbol_kind) f64 = {
	switch (k) {
	case analysis::symbol_kind::FUNCTION =>
		return CIK_FUNCTION;
	case analysis::symbol_kind::TYPE =>
		return CIK_CLASS;
	case analysis::symbol_kind::CONST =>
		return CIK_CONSTANT;
	case analysis::symbol_kind::GLOBAL =>
		return CIK_VARIABLE;
	case analysis::symbol_kind::DEF =>
		return CIK_CONSTANT;
	case =>
		return CIK_VARIABLE;
	};
};

// completionItem/resolve: just echo the input for now. Future revisions
// will fetch the long doc here.
export fn handle_completion_resolve(s: *server, r: lsp::request) void = {
	const v: json::value = match (r.params) {
	case let v: json::value =>
		yield match (json::dup(v)) {
		case let copy: json::value =>
			yield copy;
		case nomem =>
			send_error(s, r.id, lsp::INTERNAL_ERROR, "out of memory");
			return;
		};
	case void =>
		yield json::_null: json::value;
	};
	defer json::finish(v);
	match (lsp::encode_response_result(s.out, r.id, v)) {
	case size => void;
	case => void;
	};
};

fn parse_pos_comp(p: (json::value | void)) ((str, lsp::position) | void) = {
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

fn send_array_comp(s: *server, id: lsp::id, arr: []json::value) void = {
	let result = json::newobject();
	json::put(&result, "isIncomplete", false: json::value)!;
	json::put(&result, "items", arr: json::value)!;
	const v: json::value = result;
	defer json::finish(v);
	match (lsp::encode_response_result(s.out, id, v)) {
	case size => void;
	case => void;
	};
};
