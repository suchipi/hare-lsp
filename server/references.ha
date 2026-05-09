// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// References, prepareRename, and rename. The current implementation does a
// textual ident-token scan across the workspace — that's faithful to what
// many production LSPs (gopls, rust-analyzer's fallback path) do when full
// scope-aware analysis is unavailable. False positives within shadowed
// scopes are possible but rare in Hare.

use analysis;
use bufio;
use encoding::json;
use fs;
use io;
use lsp;
use os;
use strings;

// Handles textDocument/references.
export fn handle_references(s: *server, r: lsp::request) void = {
	const (uri, pos) = match (parse_pos(r.params)) {
	case let v: (str, lsp::position) => yield v;
	case void =>
		send_empty_array_local(s, r.id);
		return;
	};

	const include_decl = extract_include_decl(r.params);

	const doc = match (find_document(s, uri)) {
	case let p: *document => yield p;
	case null =>
		send_empty_array_local(s, r.id);
		return;
	};
	const data = analysis::bytes(&doc.buf);
	const off = analysis::position_to_byte(data, doc.buf.line_index,
		position_encoding(s),
		analysis::position { line = pos.line, character = pos.character });
	const ident_range = match (analysis::ident_at(data, off)) {
	case let r: (size, size) => yield r;
	case void =>
		send_empty_array_local(s, r.id);
		return;
	};
	const target = strings::fromutf8(data[ident_range.0..ident_range.1])!;

	let arr: []json::value = [];
	for (let i = 0z; i < len(s.documents); i += 1) {
		const more = find_references_in_doc(s, &s.documents[i], target);
		append(arr, more...)!;
		free(more);
	};
	const seen = collect_open_paths(s);
	defer free(seen);
	for (let i = 0z; i < len(s.workspace_index.indexed_files); i += 1) {
		const path = s.workspace_index.indexed_files[i];
		if (is_in_open_paths(seen, path)) continue;
		const more = find_references_in_file_on_disk(path, target);
		append(arr, more...)!;
		free(more);
	};

	const result_v: json::value = arr;
	defer json::finish(result_v);
	match (lsp::encode_response_result(s.out, r.id, result_v)) {
	case size => void;
	case => void;
	};
};

fn extract_include_decl(p: (json::value | void)) bool = {
	const v = match (p) {
	case let v: json::value => yield v;
	case void => return true;
	};
	const obj = match (v) {
	case let o: json::object => yield o;
	case => return true;
	};
	const ctx = match (json::get(&obj, "context")) {
	case let p: *json::value =>
		yield match (*p) {
		case let o: json::object => yield o;
		case => return true;
		};
	case => return true;
	};
	match (json::get(&ctx, "includeDeclaration")) {
	case let p: *json::value =>
		match (*p) {
		case let b: bool => return b;
		case => return true;
		};
	case => return true;
	};
};

fn collect_open_paths(s: *server) []str = {
	let out: []str = [];
	for (let i = 0z; i < len(s.documents); i += 1) {
		const path = uri_strip_scheme(s.documents[i].uri);
		append(out, path)!;
	};
	return out;
};

fn is_in_open_paths(open_paths: []str, path: str) bool = {
	for (let i = 0z; i < len(open_paths); i += 1) {
		if (open_paths[i] == path) return true;
	};
	return false;
};

fn uri_strip_scheme(uri: str) str = {
	if (strings::hasprefix(uri, "file://")) {
		return strings::sub(uri, len("file://"), strings::end);
	};
	return uri;
};

fn find_references_in_doc(
	s: *server, doc: *document, target: str,
) []json::value = {
	const data = analysis::bytes(&doc.buf);
	return scan_text_for_ident_static(data, doc.uri, doc.buf.line_index, target);
};

fn find_references_in_file_on_disk(path: str, target: str) []json::value = {
	const f = match (os::open(path)) {
	case let f: io::file => yield f;
	case fs::error => return [];
	};
	defer lsp::safe_close(f);
	let buf: []u8 = [];
	defer free(buf);
	let chunk: [4096]u8 = [0...];
	for (true) {
		match (io::read(f, chunk[..])) {
		case let n: size =>
			append(buf, chunk[..n]...)!;
		case io::EOF =>
			break;
		case io::error =>
			break;
		};
	};
	const idx = analysis::build_line_index(buf);
	defer free(idx);
	const uri = strings::concat("file://", path)!;
	defer free(uri);
	return scan_text_for_ident_static(buf, uri, idx, target);
};

// Scans a buffer for ident-token occurrences of `target` and returns a
// new []json::value with the corresponding Location objects.
fn scan_text_for_ident_static(
	data: []u8, uri: str, line_index: []size, target: str,
) []json::value = {
	let arr: []json::value = [];
	const t = strings::toutf8(target);
	let i = 0z;
	for (i + len(t) <= len(data); i += 1) {
		if (i > 0 && is_word_byte(data[i - 1])) continue;
		if (i + len(t) < len(data) && is_word_byte(data[i + len(t)])) continue;
		let ok = true;
		for (let j = 0z; j < len(t); j += 1) {
			if (data[i + j] != t[j]) {
				ok = false;
				break;
			};
		};
		if (!ok) continue;
		const start_pos = analysis::byte_to_position(data, line_index,
			analysis::encoding::UTF16, i);
		const end_pos = analysis::byte_to_position(data, line_index,
			analysis::encoding::UTF16, i + len(t));
		let loc = json::newobject();
		json::set(&loc, "uri", uri: json::value)!;
		let r = json::newobject();
		let s_obj = json::newobject();
		json::put(&s_obj, "line", start_pos.line: f64)!;
		json::put(&s_obj, "character", start_pos.character: f64)!;
		let e_obj = json::newobject();
		json::put(&e_obj, "line", end_pos.line: f64)!;
		json::put(&e_obj, "character", end_pos.character: f64)!;
		json::put(&r, "start", s_obj)!;
		json::put(&r, "end", e_obj)!;
		json::put(&loc, "range", r)!;
		append(arr, loc: json::value)!;
		i += len(t) - 1;
	};
	return arr;
};

fn is_word_byte(b: u8) bool = {
	if (b >= 'a': u8 && b <= 'z': u8) return true;
	if (b >= 'A': u8 && b <= 'Z': u8) return true;
	if (b >= '0': u8 && b <= '9': u8) return true;
	return b == '_': u8;
};

// Handles textDocument/prepareRename. Returns the identifier's range (so
// the editor pre-selects it) or null/an error if the cursor isn't on a
// valid ident.
export fn handle_prepare_rename(s: *server, r: lsp::request) void = {
	const (uri, pos) = match (parse_pos(r.params)) {
	case let v: (str, lsp::position) => yield v;
	case void =>
		send_null_result_local(s, r.id);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document => yield p;
	case null =>
		send_null_result_local(s, r.id);
		return;
	};
	const data = analysis::bytes(&doc.buf);
	const off = analysis::position_to_byte(data, doc.buf.line_index,
		position_encoding(s),
		analysis::position { line = pos.line, character = pos.character });
	const ident_range = match (analysis::ident_at(data, off)) {
	case let r: (size, size) => yield r;
	case void =>
		send_null_result_local(s, r.id);
		return;
	};
	const enc = position_encoding(s);
	const start_pos = analysis::byte_to_position(data, doc.buf.line_index, enc, ident_range.0);
	const end_pos = analysis::byte_to_position(data, doc.buf.line_index, enc, ident_range.1);
	let r_obj = json::newobject();
	let s_obj = json::newobject();
	json::put(&s_obj, "line", start_pos.line: f64)!;
	json::put(&s_obj, "character", start_pos.character: f64)!;
	let e_obj = json::newobject();
	json::put(&e_obj, "line", end_pos.line: f64)!;
	json::put(&e_obj, "character", end_pos.character: f64)!;
	json::put(&r_obj, "start", s_obj)!;
	json::put(&r_obj, "end", e_obj)!;
	const v: json::value = r_obj;
	defer json::finish(v);
	match (lsp::encode_response_result(s.out, r.id, v)) {
	case size => void;
	case => void;
	};
};

// Handles textDocument/rename. Validates the new name and produces a
// WorkspaceEdit replacing every textual occurrence.
export fn handle_rename(s: *server, r: lsp::request) void = {
	const new_name = match (extract_new_name(r.params)) {
	case let s: str => yield s;
	case void =>
		send_null_result_local(s, r.id);
		return;
	};
	if (!is_valid_hare_ident(new_name)) {
		send_error(s, r.id, lsp::INVALID_PARAMS,
			"new name is not a valid Hare identifier");
		return;
	};

	const (uri, pos) = match (parse_pos(r.params)) {
	case let v: (str, lsp::position) => yield v;
	case void =>
		send_null_result_local(s, r.id);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document => yield p;
	case null =>
		send_null_result_local(s, r.id);
		return;
	};
	const data = analysis::bytes(&doc.buf);
	const off = analysis::position_to_byte(data, doc.buf.line_index,
		position_encoding(s),
		analysis::position { line = pos.line, character = pos.character });
	const ident_range = match (analysis::ident_at(data, off)) {
	case let r: (size, size) => yield r;
	case void =>
		send_null_result_local(s, r.id);
		return;
	};
	const target = strings::fromutf8(data[ident_range.0..ident_range.1])!;

	// Build a WorkspaceEdit: { changes: { uri: TextEdit[] } }
	let changes = json::newobject();
	// Collect locations same way as references.
	let locs: []json::value = [];
	let locs_owned = true;
	defer if (locs_owned) {
		for (let i = 0z; i < len(locs); i += 1) {
			json::finish(locs[i]);
		};
		free(locs);
	};
	for (let i = 0z; i < len(s.documents); i += 1) {
		const more = find_references_in_doc(s, &s.documents[i], target);
		append(locs, more...)!;
		free(more);
	};
	const seen = collect_open_paths(s);
	defer free(seen);
	for (let i = 0z; i < len(s.workspace_index.indexed_files); i += 1) {
		const path = s.workspace_index.indexed_files[i];
		if (is_in_open_paths(seen, path)) continue;
		const more = find_references_in_file_on_disk(path, target);
		append(locs, more...)!;
		free(more);
	};

	// Group by uri.
	for (let i = 0z; i < len(locs); i += 1) {
		const loc = locs[i] as json::object;
		const u = *(json::get(&loc, "uri") as *json::value) as str;
		const range = *(json::get(&loc, "range") as *json::value);
		// Build a TextEdit { range, newText }.
		let edit = json::newobject();
		match (json::dup(range)) {
		case let r: json::value =>
			json::put(&edit, "range", r)!;
		case nomem => continue;
		};
		json::set(&edit, "newText", new_name: json::value)!;
		// Append to changes[u].
		const existing = json::get(&changes, u);
		match (existing) {
		case let p: *json::value =>
			let arr = match (*p) {
			case let a: []json::value => yield a;
			case => continue;
			};
			append(arr, edit: json::value)!;
			match (json::take(&changes, u)) {
			case let v: json::value =>
				json::finish(v);
			case void => void;
			};
			json::put(&changes, u, arr: json::value)!;
		case void =>
			let arr: []json::value = [];
			append(arr, edit: json::value)!;
			json::put(&changes, u, arr: json::value)!;
		};
	};

	let result = json::newobject();
	json::put(&result, "changes", changes)!;
	const v: json::value = result;
	defer json::finish(v);
	match (lsp::encode_response_result(s.out, r.id, v)) {
	case size => void;
	case => void;
	};
};

fn extract_new_name(p: (json::value | void)) (str | void) = {
	const v = match (p) {
	case let v: json::value => yield v;
	case void => return void;
	};
	const obj = match (v) {
	case let o: json::object => yield o;
	case => return void;
	};
	match (json::get(&obj, "newName")) {
	case let p: *json::value =>
		match (*p) {
		case let s: str => return s;
		case => return void;
		};
	case => return void;
	};
};

fn is_valid_hare_ident(name: str) bool = {
	const b = strings::toutf8(name);
	if (len(b) == 0) return false;
	if (!is_ident_first(b[0])) return false;
	for (let i = 1z; i < len(b); i += 1) {
		if (!is_word_byte(b[i])) return false;
	};
	// Check against keywords.
	switch (name) {
	case "abort", "align", "alloc", "append", "as", "assert", "bool",
		"break", "case", "const", "continue", "def", "defer",
		"delete", "done", "else", "enum", "export", "f32", "f64",
		"false", "fn", "for", "free", "i16", "i32", "i64", "i8",
		"if", "insert", "int", "is", "len", "let", "match", "never",
		"nomem", "null", "nullable", "offset", "opaque", "return",
		"rune", "size", "static", "str", "struct", "switch", "true",
		"type", "u16", "u32", "u64", "u8", "uint", "uintptr", "union",
		"use", "vaarg", "vaend", "valist", "vastart", "void", "yield" =>
		return false;
	case => void;
	};
	return true;
};

fn is_ident_first(b: u8) bool = {
	if (b >= 'a': u8 && b <= 'z': u8) return true;
	if (b >= 'A': u8 && b <= 'Z': u8) return true;
	return b == '_': u8;
};

fn parse_pos(p: (json::value | void)) ((str, lsp::position) | void) = {
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

fn send_empty_array_local(s: *server, id: lsp::id) void = {
	const arr: []json::value = [];
	const v: json::value = arr;
	defer json::finish(v);
	match (lsp::encode_response_result(s.out, id, v)) {
	case size => void;
	case => void;
	};
};

fn send_null_result_local(s: *server, id: lsp::id) void = {
	const v: json::value = json::_null;
	match (lsp::encode_response_result(s.out, id, v)) {
	case size => void;
	case => void;
	};
};
