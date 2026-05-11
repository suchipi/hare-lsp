// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Workspace indexing: walks workspace folders, populates the workspace
// index, and answers workspace/symbol + workspaceSymbol/resolve.

use analysis;
use encoding::json;
use fmt;
use fs;
use io;
use lsp;
use memio;
use os;
use strings;

// Walks every known workspace folder and populates the workspace index.
// Called from `initialized`. The walk is synchronous (the LSP dispatcher
// is single-threaded), so a very large monorepo will block the main
// loop for the duration. We log start + completion via
// window/logMessage so the user can see why the editor seems
// momentarily stalled on first open.
export fn scan_workspace_folders(s: *server) void = {
	if (len(s.workspace_folders) == 0) return;

	log_info(s, "hare-lsp: indexing workspace...");

	let total: size = 0;
	for (let i = 0z; i < len(s.workspace_folders); i += 1) {
		const path = uri_to_local_path(s.workspace_folders[i].uri);
		defer free(path);
		total += analysis::index_directory(&s.workspace_index, path);
	};

	const msg = fmt_indexed_summary(total, len(s.workspace_folders));
	defer free(msg);
	log_info(s, msg);

	// Notify clients that workspace symbols / diagnostics may be stale.
	request_diagnostic_refresh(s);
};

fn fmt_indexed_summary(files: size, folders: size) str = {
	let buf = memio::dynamic();
	defer io::close(&buf)!;
	fmt::fprintf(&buf, "hare-lsp: indexed {} file(s) across {} folder(s)",
		files, folders)!;
	return strings::dup(memio::string(&buf)!)!;
};

fn uri_to_local_path(uri: str) str = lsp::uri_decode_path(uri);

// Fetches a file_parse_cache entry; on miss, if the underlying file
// has gone missing on disk, drops the matching workspace_index
// entries in passing. This self-heals stale entries left behind by
// a delete that the watcher hasn't reported yet (delete-before-
// watcher-event is a common race on macOS/FSEvents). Returns null
// in either failure mode.
export fn cached_parse_or_drop_stale(
	s: *server, path: str,
) nullable *file_parse_entry = {
	match (file_parse_cache_get(&s.file_parse_cache, path)) {
	case let p: *file_parse_entry => return p;
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

// Handles workspace/symbol. Performs a fuzzy substring match on the
// index. The result shape is a WorkspaceSymbolList so we can carry
// `isIncomplete` when the matches were capped. Polls cancellation
// every 32 result-building iterations so the user can abandon a slow
// query.
export fn handle_workspace_symbol(s: *server, r: lsp::request) void = {
	const query_str = match (extract_query(r.params)) {
	case let s: str => yield s;
	case void => yield "";
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
		total = len(s.workspace_index.entries);
		cap = if (total < WORKSPACE_SYMBOL_CAP) total else WORKSPACE_SYMBOL_CAP;
		for (let i = 0z; i < cap; i += 1) {
			if (i % 32 == 0 && check_cancel(s, r.id)) {
				cancelled = true;
				break;
			};
			append(arr, encode_workspace_symbol(&s.workspace_index.entries[i]))!;
		};
	} else {
		const matches = analysis::fuzzy_search(&s.workspace_index, query_str);
		defer free(matches);
		total = len(matches);
		cap = if (total < WORKSPACE_SYMBOL_CAP) total else WORKSPACE_SYMBOL_CAP;
		for (let i = 0z; i < cap; i += 1) {
			if (i % 32 == 0 && check_cancel(s, r.id)) {
				cancelled = true;
				break;
			};
			append(arr, encode_workspace_symbol(
				&s.workspace_index.entries[matches[i]]))!;
		};
	};
	if (cancelled) return;

	// Build the WorkspaceSymbolList: { isIncomplete, items }. The list
	// shape was added in LSP 3.17 and is preferred over the bare-array
	// response when the server may truncate.
	let result_obj = json::newobject();
	json::put(&result_obj, "isIncomplete",
		(total > cap): json::value)!;
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
export fn handle_workspace_symbol_resolve(s: *server, r: lsp::request) void = {
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
	case analysis::symbol_kind::FUNCTION => return 12.0;
	case analysis::symbol_kind::TYPE => return 23.0;
	case analysis::symbol_kind::CONST => return 14.0;
	case analysis::symbol_kind::GLOBAL => return 13.0;
	case analysis::symbol_kind::DEF => return 14.0;
	case => return 13.0; // Variable, conservative fallback for new variants.
	};
};

fn extract_query(p: (json::value | void)) (str | void) = {
	const v = match (p) {
	case let v: json::value => yield v;
	case void => return void;
	};
	const obj = match (v) {
	case let o: json::object => yield o;
	case => return void;
	};
	match (json::get(&obj, "query")) {
	case let p: *json::value =>
		match (*p) {
		case let s: str =>
			return s;
		case => return void;
		};
	case => return void;
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
export fn workspace_handle_file_event(s: *server, uri: str, event_type: int) void = {
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
		case let b: []u8 => yield b;
		case void => return;
		};
		defer free(f);
		analysis::index_file(&s.workspace_index, path, f);
	case => void;
	};
};

// Whether a path on disk should be parsed as Hare and added to the
// workspace index. Exported only for tests.
export fn is_indexable_path(path_str: str) bool = {
	if (!strings::hassuffix(path_str, ".ha")) return false;
	// Reject anything inside a `.cache/` directory at any depth: the
	// Hare compiler scratches build artifacts there (including
	// `.ha`-suffixed intermediates in the future).
	if (strings::contains(path_str, "/.cache/")) return false;
	return true;
};

fn open_file_for_read(path_str: str) ([]u8 | void) = {
	const f = match (os_open_helper(path_str)) {
	case let f: io_file_helper => yield f;
	case void => return void;
	};
	defer io_close_helper(f);
	let buf: []u8 = [];
	let chunk: [4096]u8 = [0...];
	for (true) {
		match (io_read_helper(f, chunk[..])) {
		case let n: size =>
			append(buf, chunk[..n]...)!;
		case void => break;
		};
	};
	return buf;
};

// Internal type aliases — Hare doesn't need them, but we wrap os::open and
// io::read here to keep the signature local.
type io_file_helper = io::file;

fn os_open_helper(path_str: str) (io_file_helper | void) = {
	match (os::open(path_str)) {
	case let f: io::file => return f;
	case fs::error => return void;
	};
};

fn io_close_helper(f: io_file_helper) void = {
	lsp::safe_close(f);
};

fn io_read_helper(f: io_file_helper, buf: []u8) (size | void) = {
	match (io::read(f, buf)) {
	case let n: size => return n;
	case io::EOF => return void;
	case io::error => return void;
	};
};

