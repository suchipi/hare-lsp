// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Shared parse cache for files on disk (i.e. files that are NOT open
// documents). Cross-file features — workspace-hover, type-hierarchy
// supertypes/subtypes, references' workspace scan, rename's workspace
// scan — all need to read+parse other files. Without a cache, each
// keystroke that triggers one of these handlers re-reads and re-parses
// the same target file from scratch.
//
// Strategy:
//   - Bounded LRU keyed by absolute file path.
//   - On lookup, stat() the path; if mtime differs from the cached
//     entry's recorded mtime, invalidate.
//   - Files known to be `open documents` are NOT cached here — those
//     have their own per-document parse cache off [[parse_of]].
//
// Invariants:
//   - Cache size bounded by [[FILE_PARSE_CACHE_CAP]]. When full, the
//     least-recently-used entry is evicted.
//   - Cache entries own their raw bytes and parse_result. Callers
//     borrow these for the duration of the request and MUST NOT keep
//     pointers past the next file_parse_cache_get call (LRU eviction
//     may free).
//
// The cap is small on purpose: cross-file work touches a handful of
// files per request; we don't want to retain hundreds of multi-kilobyte
// parse results indefinitely.

use analysis;
use fs;
use io;
use lsp;
use os;
use strings;
use time;

// Maximum number of files cached. Bounded to keep memory in check;
// chosen empirically — most cross-file requests touch < 16 files.
export def FILE_PARSE_CACHE_CAP: size = 32;

// One cached parse for a single file on disk.
export type file_parse_entry = struct {
	path: str,
	mtime: time::instant,
	text: []u8,
	pr: analysis::parse_result,
	idx: analysis::file_index,
	// Monotonic counter, larger = more recent. Updated on each hit.
	last_used: u64,
};

// LRU cache of file parses.
export type file_parse_cache = struct {
	entries: []file_parse_entry,
	tick: u64,
};

// Returns a fresh empty cache.
export fn new_file_parse_cache() file_parse_cache = file_parse_cache {
	entries = [],
	tick = 0,
};

// Releases all entries.
export fn finish_file_parse_cache(c: *file_parse_cache) void = {
	for (let i = 0z; i < len(c.entries); i += 1) {
		free_file_parse_entry(&c.entries[i]);
	};
	free(c.entries);
};

fn free_file_parse_entry(e: *file_parse_entry) void = {
	free(e.path);
	free(e.text);
	analysis::finish_parse_result(&e.pr);
	analysis::finish_index(&e.idx);
};

// Looks up the entry for `path`, validating mtime. Returns null if the
// file can't be read; otherwise returns a borrowed pointer that's
// valid until the next call.
export fn file_parse_cache_get(
	c: *file_parse_cache,
	path: str,
) nullable *file_parse_entry = {
	// Stat the file; on stat failure the file is unreadable and we
	// drop any stale entry.
	const st = match (os::stat(path)) {
	case let s: fs::filestat => yield s;
	case fs::error =>
		drop_path(c, path);
		return null;
	};
	const mtime = st.mtime;

	// Existing entry?
	for (let i = 0z; i < len(c.entries); i += 1) {
		if (c.entries[i].path != path) continue;
		if (!instant_eq(c.entries[i].mtime, mtime)) {
			// Stale — evict.
			free_file_parse_entry(&c.entries[i]);
			delete(c.entries[i]);
			break;
		};
		c.tick += 1;
		c.entries[i].last_used = c.tick;
		return &c.entries[i];
	};

	// Miss — read, parse, insert.
	const text = match (read_path_bytes(path)) {
	case let b: []u8 => yield b;
	case void => return null;
	};
	let pr = analysis::parse_recover(text, path);
	const idx = analysis::build_index(&pr.subunit);
	if (len(c.entries) >= FILE_PARSE_CACHE_CAP) {
		evict_lru(c);
	};
	c.tick += 1;
	append(c.entries, file_parse_entry {
		path = strings::dup(path)!,
		mtime = mtime,
		text = text,
		pr = pr,
		idx = idx,
		last_used = c.tick,
	})!;
	return &c.entries[len(c.entries) - 1];
};

fn instant_eq(a: time::instant, b: time::instant) bool = {
	return a.sec == b.sec && a.nsec == b.nsec;
};

fn drop_path(c: *file_parse_cache, path: str) void = {
	for (let i = 0z; i < len(c.entries); i += 1) {
		if (c.entries[i].path == path) {
			free_file_parse_entry(&c.entries[i]);
			delete(c.entries[i]);
			return;
		};
	};
};

fn evict_lru(c: *file_parse_cache) void = {
	if (len(c.entries) == 0) return;
	let oldest = 0z;
	for (let i = 1z; i < len(c.entries); i += 1) {
		if (c.entries[i].last_used < c.entries[oldest].last_used) {
			oldest = i;
		};
	};
	// Move the to-be-evicted entry to the end of the slice via swap,
	// then free its contents and pop. This avoids relying on whether
	// `delete` shifts heap-owning structs (some Hare versions abort if
	// the shifted struct is treated as freed by later destruction).
	const last = len(c.entries) - 1;
	if (oldest != last) {
		const tmp = c.entries[oldest];
		c.entries[oldest] = c.entries[last];
		c.entries[last] = tmp;
	};
	free_file_parse_entry(&c.entries[last]);
	delete(c.entries[last]);
};

fn read_path_bytes(path: str) ([]u8 | void) = {
	const f = match (os::open(path)) {
	case let h: io::file => yield h;
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
		case io::error =>
			free(buf);
			return void;
		};
	};
	return buf;
};

// Drops the cached entry for `path`, if any. Used when an external file
// event (didChangeWatchedFiles) reports the path was created, changed,
// or deleted — the cached parse is no longer valid.
export fn file_parse_cache_drop_path(c: *file_parse_cache, path: str) void = {
	drop_path(c, path);
};

// Drops every cached entry whose path is at or under `root_dir`.
// Used when a workspace folder is removed or a file is deleted.
export fn file_parse_cache_drop_under(c: *file_parse_cache, root_dir: str) void = {
	const prefix = strings::concat(root_dir, "/")!;
	defer free(prefix);
	let i = 0z;
	for (i < len(c.entries)) {
		const p = c.entries[i].path;
		if (strings::hasprefix(p, prefix) || p == root_dir) {
			free_file_parse_entry(&c.entries[i]);
			delete(c.entries[i]);
		} else {
			i += 1;
		};
	};
};
