// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Completion. Combines four sources:
//   1. Hare keywords.
//   2. File-local declarations (from analysis::index on the open document).
//   3. Workspace-wide declarations (from the workspace index).
//   4. Module-member completion when the prefix is `mod::`.
//
// completionItem/resolve fills in the documentation field for a selected
// item — kept lazy so the initial list stays small.

use analysis;
use encoding::json;
use lsp;
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

def CIK_VARIABLE: f64 = 6.0;

def CIK_CLASS: f64 = 7.0;

def CIK_CONSTANT: f64 = 21.0;

def CIK_MODULE: f64 = 9.0;

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

	// Inspect the bytes preceding `off` to detect "mod::" context.
	const prefix_info = scan_completion_prefix(data, off);

	let arr: []json::value = [];

	switch (prefix_info.kind) {
	case prefix_kind::QUALIFIED =>
		// Member completion: list exported workspace symbols whose
		// module matches `prefix_info.module`.
		add_module_members(s, &arr, prefix_info.module, prefix_info.partial);
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
};

type prefix_info = struct {
	kind: prefix_kind,
	module: str,
	// For QUALIFIED, the "mod" before "::"; empty otherwise.
	partial: str
	// The text already typed for the completion target.
	,
};

fn scan_completion_prefix(data: []u8, off: size) prefix_info = {
	// Find the start of the current ident-or-empty token.
	let s = off;
	for (s > 0; s -= 1) {
		const b = data[s - 1];
		if (!is_word_byte_comp(b)) break;
	};
	const partial = strings::dup(strings::fromutf8(data[s..off])!)!;

	// Check if preceded by "::".
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
		};
	};

	return prefix_info {
		kind = prefix_kind::PLAIN,
		module = strings::dup("")!,
		partial = partial,
	};
};

fn is_word_byte_comp(b: u8) bool = {
	if (b >= 'a': u8 && b <= 'z': u8) return true;
	if (b >= 'A': u8 && b <= 'Z': u8) return true;
	if (b >= '0': u8 && b <= '9': u8) return true;
	return b == '_': u8;
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
