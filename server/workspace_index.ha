// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Workspace indexing: walks workspace folders, populates the workspace
// index, and answers workspace/symbol + workspaceSymbol/resolve.

use analysis;
use encoding::json;
use fs;
use io;
use lsp;
use os;
use strings;

// Walks every known workspace folder and populates the workspace index.
// Called from `initialized`. The walk is synchronous (the LSP dispatcher
// is single-threaded), so a very large monorepo will block the main
// loop for the duration. We log start + completion via
// window/logMessage so the user can see why the editor seems
// momentarily stalled on first open.
//
// @param s: borrowed
export fn scan_workspace_folders(s: *server) void = {
	if (len(s.workspace_folders) == 0) return;

	log_info(s, "hare-lsp: indexing workspace...");

	let roots: []str = [];
	defer {
		for (let i = 0z; i < len(roots); i += 1) free(roots[i]);
		free(roots);
	};
	for (let i = 0z; i < len(s.workspace_folders); i += 1) {
		append(roots, uri_to_local_path(s.workspace_folders[i].uri))!;
	};
	start_index_job(s, roots, &s.workspace_index, "Indexing workspace",
		"hare-lsp: indexed");
};

// @param uri: borrowed
// @returns: owned
fn uri_to_local_path(uri: str) str = lsp::uri_decode_path(uri);

// Fetches a file_parse_cache entry; on miss, if the underlying file
// has gone missing on disk, drops the matching workspace_index
// entries in passing. This self-heals stale entries left behind by
// a delete that the watcher hasn't reported yet (delete-before-
// watcher-event is a common race on macOS/FSEvents). Returns null
// in either failure mode.
//
// @param s: borrowed
// @param path: borrowed
// @returns: borrowed from s
export fn cached_parse_or_drop_stale(
	s: *server,
	path: str,
) nullable *file_parse_entry = {
	match (file_parse_cache_get(&s.file_parse_cache, path)) {
	case let p: *file_parse_entry =>
		return p;
	case null =>
		if (file_path_missing(path)) {
			analysis::drop_file(&s.workspace_index, path);
		};
		return null;
	};
};

// Maximum number of symbols returned in a single workspace/symbol
// response. When the available match set exceeds this, the response
// is flagged `isIncomplete: true` (via WorkspaceSymbolList shape) so
// the client knows to refine.
def WORKSPACE_SYMBOL_CAP: size = 200;

// Handles workspace/symbol. Performs a fuzzy substring match across the
// workspace index AND the stdlib index. The result shape is a
// WorkspaceSymbolList so we can carry `isIncomplete` either when the
// matches were capped or when stdlib indexing hasn't finished yet.
// Polls cancellation every 32 result-building iterations so the user
// can abandon a slow query.
//
// @param s: borrowed
export fn handle_workspace_symbol(s: *server, r: lsp::request) void = {
	// Kick off full stdlib indexing on first call so subsequent
	// queries can match stdlib symbols. The job is chunked so this
	// returns immediately.
	ensure_full_stdlib_indexed(s);

	const query_str = match (extract_query(r.params)) {
	case let s: str =>
		yield s;
	case void =>
		yield "";
	};

	let arr: []json::value = [];
	let arr_owned = true;
	defer if (arr_owned) {
		for (let i = 0z; i < len(arr); i += 1) {
			json::finish(arr[i]);
		};
		free(arr);
	};

	let total: size = 0;
	let cap: size = 0;
	let cancelled = false;
	if (len(query_str) == 0) {
		total = len(s.workspace_index.entries) + len(s.stdlib_index.entries);
		cap = if (total < WORKSPACE_SYMBOL_CAP) total else WORKSPACE_SYMBOL_CAP;
		// Emit workspace entries first so they outrank stdlib in
		// the truncated set.
		for (let i = 0z; i < len(s.workspace_index.entries); i += 1) {
			if (len(arr) >= cap) break;
			if (i % 32 == 0 && check_cancel(s, r.id)) {
				cancelled = true;
				break;
			};
			append(arr, encode_workspace_symbol(&s.workspace_index.entries[i]))!;
		};
		if (!cancelled)
			for (let i = 0z; i < len(s.stdlib_index.entries); i += 1) {
				if (len(arr) >= cap) break;
				if (i % 32 == 0 && check_cancel(s, r.id)) {
					cancelled = true;
					break;
				};
				append(arr, encode_workspace_symbol(&s.stdlib_index.entries[i]))!;
			};
	} else {
		const ws = analysis::fuzzy_search(&s.workspace_index, query_str);
		defer free(ws);
		const stdlib = analysis::fuzzy_search(&s.stdlib_index, query_str);
		defer free(stdlib);
		// Also surface symbols from open documents so the picker
		// works when the user has unsaved files (and especially when
		// no workspace folder is configured — without this, neither
		// workspace_index nor stdlib_index would reach the user's
		// own decls).
		let open_hits = collect_open_doc_symbol_hits(s, query_str);
		defer free(open_hits);
		total = len(ws) + len(stdlib) + len(open_hits);
		cap = if (total < WORKSPACE_SYMBOL_CAP) total else WORKSPACE_SYMBOL_CAP;
		for (let i = 0z; i < len(ws); i += 1) {
			if (len(arr) >= cap) break;
			if (i % 32 == 0 && check_cancel(s, r.id)) {
				cancelled = true;
				break;
			};
			append(arr, encode_workspace_symbol(&s.workspace_index.entries[ws[i]]))!;
		};
		if (!cancelled)
			for (let i = 0z; i < len(open_hits); i += 1) {
				if (len(arr) >= cap) break;
				append(arr, encode_open_doc_symbol(s, open_hits[i].0, open_hits[i].1))!;
			};
		if (!cancelled)
			for (let i = 0z; i < len(stdlib); i += 1) {
				if (len(arr) >= cap) break;
				if (i % 32 == 0 && check_cancel(s, r.id)) {
					cancelled = true;
					break;
				};
				append(arr, encode_workspace_symbol(&s.stdlib_index.entries[stdlib[i]]))!;
			};
	};
	if (cancelled) return;

	// `isIncomplete` is true either when results were truncated or
	// when stdlib indexing is still pending (in which case more
	// matches may appear on a subsequent query).
	const indexing_in_flight = len(s.pending_index_jobs) > 0;
	let result_obj = json::newobject();
	json::put(&result_obj, "isIncomplete",
		(total > cap || indexing_in_flight): json::value)!;
	json::put(&result_obj, "items", arr: json::value)!;
	arr_owned = false;
	const result_v: json::value = result_obj;
	defer json::finish(result_v);
	match (lsp::encode_response_result(s.out, r.id, result_v)) {
	case size => void;
	case => void;
	};
};

// Handles workspaceSymbol/resolve. Currently a no-op: we already include
// the location in workspace/symbol. Some clients still call resolve, so we
// pass the input through unchanged.
//
// @param s: borrowed
export fn handle_workspace_symbol_resolve(s: *server, r: lsp::request) void = {
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

// Returns (doc, sym) pairs for every open-document symbol whose
// short_name contains `query` (case-insensitive substring). Skips
// open docs whose URI corresponds to a path already covered by the
// workspace index — that way an open file inside a workspace folder
// doesn't appear twice.
//
// @param s: borrowed
// @param query: borrowed
// @returns: owned
fn collect_open_doc_symbol_hits(
	s: *server,
	query: str,
) [](*document, *analysis::symbol) = {
	let out: [](*document, *analysis::symbol) = [];
	const q_lower = wsym_ascii_lower(query);
	defer free(q_lower);
	for (let i = 0z; i < len(s.documents); i += 1) {
		const doc = &s.documents[i];
		if (open_doc_indexed_on_disk(s, doc.uri)) continue;
		const cache = parse_of(doc);
		for (let j = 0z; j < len(cache.idx.symbols); j += 1) {
			const sym = &cache.idx.symbols[j];
			const sn_lower = wsym_ascii_lower(sym.short_name);
			const matches = len(q_lower) == 0 || strings::contains(sn_lower, q_lower);
			free(sn_lower);
			if (!matches) continue;
			append(out, (doc, sym))!;
		};
	};
	return out;
};

// @param s: borrowed
// @returns: owned
fn wsym_ascii_lower(s: str) str = {
	const bytes = strings::toutf8(s);
	let buf: []u8 = alloc([], len(bytes))!;
	defer free(buf);
	for (let i = 0z; i < len(bytes); i += 1) {
		let b = bytes[i];
		if (b >= 'A': u8 && b <= 'Z': u8) {
			b += 'a': u8 - 'A': u8;
		};
		append(buf, b)!;
	};
	return strings::dup(strings::fromutf8(buf)!)!;
};

// @param s: borrowed
// @param uri: borrowed
fn open_doc_indexed_on_disk(s: *server, uri: str) bool = {
	const path = lsp::uri_decode_path(uri);
	defer free(path);
	for (let i = 0z; i < len(s.workspace_index.entries); i += 1) {
		if (s.workspace_index.entries[i].path == path) return true;
	};
	return false;
};

// @param s: borrowed
// @param doc: borrowed
// @param sym: borrowed
// @returns: owned
fn encode_open_doc_symbol(
	s: *server,
	doc: *document,
	sym: *analysis::symbol,
) json::value = {
	let o = json::newobject();
	json::set(&o, "name", sym.short_name: json::value)!;
	json::put(&o, "kind", workspace_entry_kind_to_lsp(sym.kind))!;
	let loc = json::newobject();
	json::set(&loc, "uri", doc.uri: json::value)!;
	// Open docs have a live line index, so we can hand the editor a
	// precise range instead of the degenerate 0:0 fallback used for
	// on-disk entries.
	const data = analysis::bytes(&doc.buf);
	const enc = position_encoding(s);
	const sp = analysis::byte_to_position(data, doc.buf.line_index, enc,
		sym.span.start.off: size);
	const ep = analysis::byte_to_position(data, doc.buf.line_index, enc,
		sym.span.end.off: size);
	let range = json::newobject();
	let s_obj = json::newobject();
	json::put(&s_obj, "line", sp.line: f64)!;
	json::put(&s_obj, "character", sp.character: f64)!;
	let e_obj = json::newobject();
	json::put(&e_obj, "line", ep.line: f64)!;
	json::put(&e_obj, "character", ep.character: f64)!;
	json::put(&range, "start", s_obj)!;
	json::put(&range, "end", e_obj)!;
	json::put(&loc, "range", range)!;
	json::put(&o, "location", loc)!;
	return o;
};

// @param e: borrowed
// @returns: owned
fn encode_workspace_symbol(e: *analysis::workspace_entry) json::value = {
	let o = json::newobject();
	json::set(&o, "name", e.short_name: json::value)!;
	json::put(&o, "kind", workspace_entry_kind_to_lsp(e.kind))!;
	let loc = json::newobject();
	json::set(&loc, "uri", e.uri: json::value)!;
	// We don't have line indices for the file's text here; report a
	// degenerate range pointing at the start. Clients use uri to navigate
	// and the range mostly to scroll; we keep it cheap and accept the
	// imprecision until per-file caches land.
	let range = json::newobject();
	let zero = json::newobject();
	json::put(&zero, "line", 0: f64)!;
	json::put(&zero, "character", 0: f64)!;
	json::put(&range, "start", zero)!;
	let zero2 = json::newobject();
	json::put(&zero2, "line", 0: f64)!;
	json::put(&zero2, "character", 0: f64)!;
	json::put(&range, "end", zero2)!;
	json::put(&loc, "range", range)!;
	json::put(&o, "location", loc)!;
	if (len(e.docs) > 0) {
		json::set(&o, "containerName", e.full_name: json::value)!;
	};
	return o;
};

fn workspace_entry_kind_to_lsp(k: analysis::symbol_kind) f64 = {
	switch (k) {
	case analysis::symbol_kind::FUNCTION =>
		return 12.0;
	case analysis::symbol_kind::TYPE =>
		return 23.0;
	case analysis::symbol_kind::CONST =>
		return 14.0;
	case analysis::symbol_kind::GLOBAL =>
		return 13.0;
	case analysis::symbol_kind::DEF =>
		return 14.0;
	case =>
		return 13.0; // Variable, conservative fallback for new variants.
	};
};

// @param p: borrowed
// @returns: borrowed from p
fn extract_query(p: (json::value | void)) (str | void) = {
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
	match (json::get(&obj, "query")) {
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

// Refreshes the workspace index for files reported by
// workspace/didChangeWatchedFiles. Called from the file watch handler.
//
// Only `.ha` files are indexed: the watcher's glob may include other
// patterns (notably `*.s`, since assembly is part of a Hare module's
// source set), but the parser would abort on non-Hare bytes. We also
// ignore anything inside our own `.cache/` since the Hare compiler
// drops `*.o.tmp.s` artifacts there.
//
// @param s: borrowed
// @param uri: borrowed
export fn workspace_handle_file_event(
	s: *server,
	uri: str,
	event_type: int,
) void = {
	const path = uri_to_local_path(uri);
	defer free(path);
	if (!is_indexable_path(path)) return;
	// Invalidate the on-disk parse cache for this path regardless of
	// event type — any change makes the cached parse stale.
	file_parse_cache_drop_path(&s.file_parse_cache, path);
	switch (event_type) {
	case 3 =>
		// Deleted.
		analysis::drop_file(&s.workspace_index, path);
	case 1, 2 =>
		// Created or Changed: re-index the file.
		const f = match (open_file_for_read(path)) {
		case let b: []u8 =>
			yield b;
		case void =>
			return;
		};
		defer free(f);
		analysis::index_file(&s.workspace_index, path, f);
	case => void;
	};
};

// Whether a path on disk should be parsed as Hare and added to the
// workspace index. Exported only for tests.
//
// @param path_str: borrowed
export fn is_indexable_path(path_str: str) bool = {
	if (!strings::hassuffix(path_str, ".ha")) return false;
	// Reject anything inside a `.cache/` directory at any depth: the
	// Hare compiler scratches build artifacts there (including
	// `.ha`-suffixed intermediates in the future).
	if (strings::contains(path_str, "/.cache/")) return false;
	return true;
};

// @param path_str: borrowed
// @returns: owned
fn open_file_for_read(path_str: str) ([]u8 | void) = {
	const f = match (os_open_helper(path_str)) {
	case let f: io_file_helper =>
		yield f;
	case void =>
		return void;
	};
	defer io_close_helper(f);
	let buf: []u8 = [];
	let chunk: [4096]u8 = [0...];
	for (true) {
		match (io_read_helper(f, chunk[..])) {
		case let n: size =>
			append(buf, chunk[..n]...)!;
		case void =>
			break;
		};
	};
	return buf;
};

// Internal type aliases — Hare doesn't need them, but we wrap os::open and
// io::read here to keep the signature local.
type io_file_helper = io::file;

// @param path_str: borrowed
fn os_open_helper(path_str: str) (io_file_helper | void) = {
	match (os::open(path_str)) {
	case let f: io::file =>
		return f;
	case fs::error =>
		return void;
	};
};

fn io_close_helper(f: io_file_helper) void = {
	lsp::safe_close(f);
};

// @param buf: borrowed
fn io_read_helper(f: io_file_helper, buf: []u8) (size | void) = {
	match (io::read(f, buf)) {
	case let n: size =>
		return n;
	case io::EOF =>
		return void;
	case io::error =>
		return void;
	};
};
