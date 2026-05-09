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
	"abort", "align", "alloc", "append", "as", "assert", "bool", "break",
	"case", "const", "continue", "def", "defer", "delete", "done", "else",
	"enum", "export", "f32", "f64", "false", "fn", "for", "free", "i16",
	"i32", "i64", "i8", "if", "insert", "int", "is", "len", "let", "match",
	"never", "nomem", "null", "nullable", "offset", "opaque", "return",
	"rune", "size", "static", "str", "struct", "switch", "true", "type",
	"u16", "u32", "u64", "u8", "uint", "uintptr", "union", "use", "vaarg",
	"vaend", "valist", "vastart", "void", "yield",
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
	case let v: (str, lsp::position) => yield v;
	case void =>
		send_array_comp(s, r.id, []);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document => yield p;
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
		// Member completion: list workspace symbols whose full_name
		// starts with `prefix_info.module::`.
		add_module_members(s, &arr, prefix_info.module, prefix_info.partial);
	case prefix_kind::PLAIN =>
		add_keywords(&arr, prefix_info.partial);
		add_file_locals(&arr, &doc.buf, uri, prefix_info.partial);
		add_workspace_symbols(s, &arr, prefix_info.partial);
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
	module: str,  // For QUALIFIED, the "mod" before "::"; empty otherwise.
	partial: str, // The text already typed for the completion target.
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

fn add_keywords(arr: *[]json::value, partial: str) void = {
	let a = *arr;
	for (let i = 0z; i < len(KEYWORDS); i += 1) {
		if (len(partial) > 0 && !strings::hasprefix(KEYWORDS[i], partial)) continue;
		let item = json::newobject();
		json::set(&item, "label", KEYWORDS[i]: json::value)!;
		json::put(&item, "kind", CIK_KEYWORD)!;
		json::set(&item, "detail", "keyword": json::value)!;
		append(a, item: json::value)!;
	};
	*arr = a;
};

fn add_file_locals(arr: *[]json::value, buf: *analysis::buffer, uri: str, partial: str) void = {
	let a = *arr;
	let pr = analysis::parse_recover(analysis::bytes(buf), uri);
	defer analysis::finish_parse_result(&pr);
	let idx = analysis::build_index(&pr.subunit);
	defer analysis::finish_index(&idx);
	for (let i = 0z; i < len(idx.symbols); i += 1) {
		const sym = &idx.symbols[i];
		if (len(partial) > 0 && !strings::hasprefix(sym.short_name, partial)) continue;
		let item = json::newobject();
		json::set(&item, "label", sym.short_name: json::value)!;
		json::put(&item, "kind", symbol_kind_to_completion(sym.kind))!;
		json::set(&item, "detail", sym.name: json::value)!;
		if (len(sym.docs) > 0) {
			json::set(&item, "documentation", sym.docs: json::value)!;
		};
		append(a, item: json::value)!;
	};
	*arr = a;
};

fn add_workspace_symbols(s: *server, arr: *[]json::value, partial: str) void = {
	let a = *arr;
	const cap = if (len(s.workspace_index.entries) < 500z) {
		yield len(s.workspace_index.entries);
	} else {
		yield 500z;
	};
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
		append(a, item: json::value)!;
		added += 1;
	};
	*arr = a;
};

fn add_module_members(s: *server, arr: *[]json::value, module: str, partial: str) void = {
	let a = *arr;
	for (let i = 0z; i < len(s.workspace_index.entries); i += 1) {
		const e = &s.workspace_index.entries[i];
		// full_name has the form "<file_module>::<short>" or just "<short>"
		// because we don't currently resolve module paths from disk
		// layout. As a heuristic, match if module appears as a prefix
		// component or if entry.full_name starts with "module::".
		const want_prefix = strings::concat(module, "::")!;
		defer free(want_prefix);
		if (!strings::hasprefix(e.full_name, want_prefix)) continue;
		if (!e.exported) continue;
		if (len(partial) > 0 && !strings::hasprefix(e.short_name, partial)) continue;
		let item = json::newobject();
		json::set(&item, "label", e.short_name: json::value)!;
		json::put(&item, "kind", symbol_kind_to_completion(e.kind))!;
		json::set(&item, "detail", e.full_name: json::value)!;
		if (len(e.docs) > 0) {
			json::set(&item, "documentation", e.docs: json::value)!;
		};
		append(a, item: json::value)!;
	};
	*arr = a;
};

fn symbol_kind_to_completion(k: analysis::symbol_kind) f64 = {
	switch (k) {
	case analysis::symbol_kind::FUNCTION => return CIK_FUNCTION;
	case analysis::symbol_kind::TYPE => return CIK_CLASS;
	case analysis::symbol_kind::CONST => return CIK_CONSTANT;
	case analysis::symbol_kind::GLOBAL => return CIK_VARIABLE;
	case analysis::symbol_kind::DEF => return CIK_CONSTANT;
	case => return CIK_VARIABLE;
	};
};

// completionItem/resolve: just echo the input for now. Future revisions
// will fetch the long doc here.
export fn handle_completion_resolve(s: *server, r: lsp::request) void = {
	const v: json::value = match (r.params) {
	case let v: json::value =>
		yield match (json::dup(v)) {
		case let copy: json::value => yield copy;
		case nomem =>
			send_error(s, r.id, lsp::INTERNAL_ERROR, "out of memory");
			return;
		};
	case void => yield json::_null: json::value;
	};
	defer json::finish(v);
	match (lsp::encode_response_result(s.out, r.id, v)) {
	case size => void;
	case => void;
	};
};

fn parse_pos_comp(p: (json::value | void)) ((str, lsp::position) | void) = {
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
