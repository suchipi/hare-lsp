// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// References, prepareRename, and rename.
//
// Two-tier strategy:
//   - If the cursor resolves to a local binding (let / const / def / for /
//     match / function parameter), the search is bounded to that binding's
//     lexical scope via scope_local_binding. Shadowing works correctly: a
//     `let foo` inside one function won't pull in a same-named global.
//   - For top-level decls the workspace is scanned textually for matching
//     ident tokens. Comments, strings, char literals, and raw strings are
//     skipped via token_skip_noncode so prose matches don't produce false
//     positives. Two unrelated top-level idents with the same name in
//     different modules are still indistinguishable; see the "Known
//     limitations" sections of README.md and docs/features.md.

use analysis;
use encoding::json;
use fs;
use io;
use lsp;
use os;
use strings;

// Handles textDocument/references.
export fn handle_references(s: *server, r: lsp::request) void = {
	const (uri, pos) = match (parse_pos(r.params)) {
	case let v: (str, lsp::position) =>
		yield v;
	case void =>
		send_empty_array_local(s, r.id);
		return;
	};

	const include_decl = extract_include_decl(r.params);

	const doc = match (find_document(s, uri)) {
	case let p: *document =>
		yield p;
	case null =>
		send_empty_array_local(s, r.id);
		return;
	};
	const data = analysis::bytes(&doc.buf);
	const off = analysis::position_to_byte(data, doc.buf.line_index,
		position_encoding(s),
		analysis::position { line = pos.line, character = pos.character });
	const ident_range = match (analysis::ident_at(data, off)) {
	case let r: (size, size) =>
		yield r;
	case void =>
		send_empty_array_local(s, r.id);
		return;
	};
	const target = strings::fromutf8(data[ident_range.0..ident_range.1])!;

	// Scope-aware fast path: if the cursor resolves to a binding that
	// only lives in the current file (a let/const/def/for/match/func
	// param), the search is bounded to that binding's lexical scope.
	const local = scope_local_binding(doc, target, ident_range.0: u32);
	if (local is scope_local) {
		const lb = local as scope_local;
		let arr: []json::value = scan_text_for_ident_static_in_range(data, doc.uri,
			doc.buf.line_index, target, lb.scope_start: size, lb.scope_end: size);
		const result_v: json::value = arr;
		defer json::finish(result_v);
		match (lsp::encode_response_result(s.out, r.id, result_v)) {
		case size => void;
		case => void;
		};
		return;
	};

	// Resolve the cursor's symbol to a workspace entry. When this
	// succeeds we use it to disambiguate textual hits across modules
	// (drop hits that re-resolve to a different decl). When it fails
	// (unindexed file, fresh symbol, stdlib-only target), fall back to
	// the unfiltered scan to preserve prior behavior.
	const expected = expected_entry_for_cursor(s, doc, data, ident_range.0,
		target);

	let arr: []json::value = [];
	let cancelled = false;
	for (let i = 0z; i < len(s.documents); i += 1) {
		if (i % 32 == 0 && check_cancel(s, r.id)) {
			cancelled = true;
			break;
		};
		const more = find_references_in_doc(s, &s.documents[i], target, expected);
		append(arr, more...)!;
		free(more);
	};
	const seen = collect_open_paths(s);
	defer finish_open_paths(seen);
	if (!cancelled)
		for (let i = 0z; i < len(s.workspace_index.indexed_files); i += 1) {
			if (i % 32 == 0 && check_cancel(s, r.id)) {
				cancelled = true;
				break;
			};
			const path = s.workspace_index.indexed_files[i];
			if (is_in_open_paths(seen, path)) continue;
			const more = find_references_in_file_on_disk(s, path, target, expected);
			append(arr, more...)!;
			free(more);
		};

	if (cancelled) {
		const v: json::value = arr;
		json::finish(v);
		return;
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
	case let v: json::value =>
		yield v;
	case void =>
		return true;
	};
	const obj = match (v) {
	case let o: json::object =>
		yield o;
	case =>
		return true;
	};
	const ctx = match (json::get(&obj, "context")) {
	case let p: *json::value =>
		yield match (*p) {
		case let o: json::object =>
			yield o;
		case =>
			return true;
		};
	case =>
		return true;
	};
	match (json::get(&ctx, "includeDeclaration")) {
	case let p: *json::value =>
		match (*p) {
		case let b: bool =>
			return b;
		case =>
			return true;
		};
	case =>
		return true;
	};
};

// Returns a freshly-allocated slice of paths corresponding to each
// open document's URI (percent-decoded). Caller must call
// [[finish_open_paths]] to free both the slice and its elements.
fn collect_open_paths(s: *server) []str = {
	let out: []str = [];
	for (let i = 0z; i < len(s.documents); i += 1) {
		append(out, lsp::uri_decode_path(s.documents[i].uri))!;
	};
	return out;
};

fn finish_open_paths(paths: []str) void = {
	for (let i = 0z; i < len(paths); i += 1) {
		free(paths[i]);
	};
	free(paths);
};

fn is_in_open_paths(open_paths: []str, path: str) bool = {
	for (let i = 0z; i < len(open_paths); i += 1) {
		if (open_paths[i] == path) return true;
	};
	return false;
};

fn find_references_in_doc(
	s: *server,
	doc: *document,
	target: str,
	expected: (*analysis::workspace_entry | void),
) []json::value = {
	const data = analysis::bytes(&doc.buf);
	const offsets = scan_text_for_ident_offsets_in_range(data, target, 0z,
		len(data));
	defer free(offsets);
	const name_len = len(strings::toutf8(target));
	let arr: []json::value = [];
	if (expected is void) {
		for (let i = 0z; i < len(offsets); i += 1) {
			append(arr, build_location(data, doc.uri, doc.buf.line_index, offsets[i],
				name_len))!;
		};
		return arr;
	};
	const exp = expected as *analysis::workspace_entry;
	const path = lsp::uri_decode_path(doc.uri);
	defer free(path);
	for (let i = 0z; i < len(offsets); i += 1) {
		if (!hit_resolves_to(s, path, data, offsets[i], exp)) continue;
		append(arr, build_location(data, doc.uri, doc.buf.line_index, offsets[i],
			name_len))!;
	};
	return arr;
};

fn find_references_in_file_on_disk(
	s: *server,
	path: str,
	target: str,
	expected: (*analysis::workspace_entry | void),
) []json::value = {
	const f = match (os::open(path)) {
	case let f: io::file =>
		yield f;
	case fs::error =>
		return [];
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
	const offsets = scan_text_for_ident_offsets_in_range(buf, target, 0z,
		len(buf));
	defer free(offsets);
	const name_len = len(strings::toutf8(target));
	let arr: []json::value = [];
	if (expected is void) {
		for (let i = 0z; i < len(offsets); i += 1) {
			append(arr, build_location(buf, uri, idx, offsets[i], name_len))!;
		};
		return arr;
	};
	const exp = expected as *analysis::workspace_entry;
	for (let i = 0z; i < len(offsets); i += 1) {
		if (!hit_resolves_to(s, path, buf, offsets[i], exp)) continue;
		append(arr, build_location(buf, uri, idx, offsets[i], name_len))!;
	};
	return arr;
};

// Resolves the cursor in `doc` at `off` to a scope_binding scoped to the
// open document. Returns void when the cursor refers to a top-level decl
// (which may have callers in other files) or to no known binding.
type scope_local = struct {
	scope_start: u32,
	scope_end: u32,
};

fn scope_local_binding(
	doc: *document,
	name: str,
	off: u32,
) (scope_local | void) = {
	const cache = parse_of(doc);
	const b = match (analysis::resolve_binding_at_byte(&cache.scope, name, off)) {
	case let b: analysis::scope_binding =>
		yield b;
	case void =>
		return void;
	};
	if (b.kind == analysis::binding_kind::TOPLEVEL_DECL) return void;
	return scope_local {
		scope_start = b.scope_start,
		scope_end = b.scope_end,
	};
};

// Scans a buffer for ident-token occurrences of `target` and returns a
// new []json::value with the corresponding Location objects.
fn scan_text_for_ident_static(
	data: []u8,
	uri: str,
	line_index: []size,
	target: str,
) []json::value = {
	return scan_text_for_ident_static_in_range(data, uri, line_index, target, 0z,
		len(data));
};

// Scans `data[start..end]` for ident-token occurrences of `target`.
// Skips over string literals, char literals, raw strings, line comments,
// and block comments so a match inside text/prose doesn't produce a
// false-positive reference (which would otherwise let a rename silently
// rewrite a doc comment).
fn scan_text_for_ident_static_in_range(
	data: []u8,
	uri: str,
	line_index: []size,
	target: str,
	start: size,
	end: size,
) []json::value = {
	const offsets = scan_text_for_ident_offsets_in_range(data, target, start, end);
	defer free(offsets);
	let arr: []json::value = [];
	for (let i = 0z; i < len(offsets); i += 1) {
		append(arr, build_location(data, uri, line_index, offsets[i],
			len(strings::toutf8(target))): json::value)!;
	};
	return arr;
};

// Returns the byte offsets where ident-token occurrences of `target`
// begin in `data[start..end]`. Same skipping rules as the location-
// emitting scan but returns offsets so callers can filter before
// building Location objects.
fn scan_text_for_ident_offsets_in_range(
	data: []u8,
	target: str,
	start: size,
	end: size,
) []size = {
	let out: []size = [];
	const t = strings::toutf8(target);
	const limit = if (end > len(data)) len(data) else end;
	let i = start;
	for (i + len(t) <= limit) {
		const after = analysis::token_skip_noncode(data, i, limit);
		if (after > i) {
			i = after;
			continue;
		};
		if (i > 0 && analysis::is_ident_byte(data[i - 1])) {
			i += 1;
			continue;
		};
		if (i + len(t) < limit && analysis::is_ident_byte(data[i + len(t)])) {
			i += 1;
			continue;
		};
		let ok = true;
		for (let j = 0z; j < len(t); j += 1) {
			if (data[i + j] != t[j]) {
				ok = false;
				break;
			};
		};
		if (!ok) {
			i += 1;
			continue;
		};
		append(out, i)!;
		i += len(t);
	};
	return out;
};

// Builds an LSP Location JSON value for an ident hit at byte offset `off`
// of length `name_len`. Always uses UTF-16 positions (matching the scan
// callers' historical behavior).
fn build_location(
	data: []u8,
	uri: str,
	line_index: []size,
	off: size,
	name_len: size,
) json::value = {
	const start_pos = analysis::byte_to_position(data, line_index,
		analysis::encoding::UTF16, off);
	const end_pos = analysis::byte_to_position(data, line_index,
		analysis::encoding::UTF16, off + name_len);
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
	return loc: json::value;
};

// Handles textDocument/prepareRename. Returns the identifier's range (so
// the editor pre-selects it) or null/an error if the cursor isn't on a
// valid ident.
export fn handle_prepare_rename(s: *server, r: lsp::request) void = {
	const (uri, pos) = match (parse_pos(r.params)) {
	case let v: (str, lsp::position) =>
		yield v;
	case void =>
		send_null_result_local(s, r.id);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document =>
		yield p;
	case null =>
		send_null_result_local(s, r.id);
		return;
	};
	const data = analysis::bytes(&doc.buf);
	const off = analysis::position_to_byte(data, doc.buf.line_index,
		position_encoding(s),
		analysis::position { line = pos.line, character = pos.character });
	const ident_range = match (analysis::ident_at(data, off)) {
	case let r: (size, size) =>
		yield r;
	case void =>
		send_null_result_local(s, r.id);
		return;
	};
	const enc = position_encoding(s);
	const start_pos = analysis::byte_to_position(data, doc.buf.line_index, enc,
		ident_range.0);
	const end_pos = analysis::byte_to_position(data, doc.buf.line_index, enc,
		ident_range.1);
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
	case let s: str =>
		yield s;
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
	case let v: (str, lsp::position) =>
		yield v;
	case void =>
		send_null_result_local(s, r.id);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document =>
		yield p;
	case null =>
		send_null_result_local(s, r.id);
		return;
	};
	const data = analysis::bytes(&doc.buf);
	const off = analysis::position_to_byte(data, doc.buf.line_index,
		position_encoding(s),
		analysis::position { line = pos.line, character = pos.character });
	const ident_range = match (analysis::ident_at(data, off)) {
	case let r: (size, size) =>
		yield r;
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
	let cancelled = false;

	// Scope-aware fast path: a local binding never escapes its lexical
	// scope, so rename limits its edits to that range. Skips the
	// workspace and other-document scan entirely.
	const local = scope_local_binding(doc, target, ident_range.0: u32);
	const expected: (
		*analysis::workspace_entry |
		void
	) = if (local is scope_local) void
		else expected_entry_for_cursor(s, doc, data, ident_range.0, target);
	if (local is scope_local) {
		const lb = local as scope_local;
		let more = scan_text_for_ident_static_in_range(data, doc.uri,
			doc.buf.line_index, target, lb.scope_start: size, lb.scope_end: size);
		append(locs, more...)!;
		free(more);
	} else {
		for (let i = 0z; i < len(s.documents); i += 1) {
			if (i % 32 == 0 && check_cancel(s, r.id)) {
				cancelled = true;
				break;
			};
			const more = find_references_in_doc(s, &s.documents[i], target, expected);
			append(locs, more...)!;
			free(more);
		};
	};
	const seen = collect_open_paths(s);
	defer finish_open_paths(seen);
	if (!cancelled && !(local is scope_local))
		for (let i = 0z; i < len(s.workspace_index.indexed_files); i += 1) {
			if (i % 32 == 0 && check_cancel(s, r.id)) {
				cancelled = true;
				break;
			};
			const path = s.workspace_index.indexed_files[i];
			if (is_in_open_paths(seen, path)) continue;
			const more = find_references_in_file_on_disk(s, path, target, expected);
			append(locs, more...)!;
			free(more);
		};

	if (cancelled) {
		// `changes` and `locs` are freed via the surrounding defer/finish.
		json::finish(changes);
		return;
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
		case nomem =>
			continue;
		};
		json::set(&edit, "newText", new_name: json::value)!;
		// Append to changes[u]. Take the value out of the object
		// before appending so the object no longer aliases the slice's
		// backing buffer — `append` may realloc and invalidate the
		// pointer we'd otherwise leave behind in `changes[u]`.
		const taken = json::take(&changes, u);
		let arr = match (taken) {
		case let v: json::value =>
			yield match (v) {
			case let a: []json::value =>
				yield a;
			case =>
				json::finish(v);
				yield []: []json::value;
			};
		case void =>
			yield []: []json::value;
		};
		append(arr, edit: json::value)!;
		json::put(&changes, u, arr: json::value)!;
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
	match (json::get(&obj, "newName")) {
	case let p: *json::value =>
		match (*p) {
		case let s: str =>
			return s;
		case =>
			return void;
		};
	case =>
		return void;
	};
};

fn is_valid_hare_ident(name: str) bool = {
	const b = strings::toutf8(name);
	if (len(b) == 0) return false;
	if (!is_ident_first(b[0])) return false;
	for (let i = 1z; i < len(b); i += 1) {
		if (!analysis::is_ident_byte(b[i])) return false;
	};
	// Check against keywords.
	switch (name) {
	case "abort",
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
	"yield" =>
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
