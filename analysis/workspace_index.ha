// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Workspace-wide index. Walks `*.ha` files under each workspace root and
// keeps a per-file index of declarations, plus a flat name -> []entry
// table for fast workspace-symbol lookup.
//
// The current implementation does a synchronous walk on demand. Step 28's
// hardening pass will move expensive walks behind a $/progress-reported
// background task that yields between files.

use fs;
use io;
use os;
use path;
use strings;

// One indexed declaration in the workspace.
export type workspace_entry = struct {
	// File URI (file://...).
	uri: str,
	// File path on disk.
	path: str,
	// Symbol short name and kind.
	short_name: str,
	full_name: str,
	kind: symbol_kind,
	// AST span byte offsets.
	start_off: u32,
	end_off: u32,
	// Doc comment, if any.
	docs: str,
	exported: bool,
};

// The workspace index.
export type workspace_index = struct {
	entries: []workspace_entry,
	// File paths whose directories were scanned. Used to avoid re-indexing.
	indexed_files: []str,
};

// Returns an empty index.
export fn new_workspace_index() workspace_index = workspace_index {
	entries = [],
	indexed_files = [],
};

// Releases owned memory.
export fn finish_workspace_index(idx: *workspace_index) void = {
	for (let i = 0z; i < len(idx.entries); i += 1) {
		free(idx.entries[i].uri);
		free(idx.entries[i].path);
		free(idx.entries[i].short_name);
		free(idx.entries[i].full_name);
		free(idx.entries[i].docs);
	};
	free(idx.entries);
	for (let i = 0z; i < len(idx.indexed_files); i += 1) {
		free(idx.indexed_files[i]);
	};
	free(idx.indexed_files);
};

// Drops all entries originating from `path`. Used when a file is renamed,
// deleted, or modified before re-indexing.
export fn drop_file(idx: *workspace_index, path_str: str) void = {
	let i = 0z;
	for (i < len(idx.entries)) {
		if (idx.entries[i].path == path_str) {
			free(idx.entries[i].uri);
			free(idx.entries[i].path);
			free(idx.entries[i].short_name);
			free(idx.entries[i].full_name);
			free(idx.entries[i].docs);
			delete(idx.entries[i]);
		} else {
			i += 1;
		};
	};
	for (let j = 0z; j < len(idx.indexed_files); j += 1) {
		if (idx.indexed_files[j] == path_str) {
			free(idx.indexed_files[j]);
			delete(idx.indexed_files[j]);
			return;
		};
	};
};

// Adds entries for a single file. text is the file contents.
export fn index_file(idx: *workspace_index, file_path: str, text: []u8) void = {
	drop_file(idx, file_path);
	let pr = parse_recover(text, file_path);
	defer finish_parse_result(&pr);
	let fi = build_index(&pr.subunit);
	defer finish_index(&fi);

	const uri = strings::concat("file://", file_path)!;
	for (let i = 0z; i < len(fi.symbols); i += 1) {
		const sym = &fi.symbols[i];
		append(idx.entries, workspace_entry {
			uri = strings::dup(uri)!,
			path = strings::dup(file_path)!,
			short_name = strings::dup(sym.short_name)!,
			full_name = strings::dup(sym.name)!,
			kind = sym.kind,
			start_off = sym.span.start.off: u32,
			end_off = sym.span.end.off: u32,
			docs = strings::dup(sym.docs)!,
			exported = sym.exported,
		})!;
	};
	free(uri);
	append(idx.indexed_files, strings::dup(file_path)!)!;
};

// Recursively walks `root` looking for *.ha files; calls index_file on each.
//
// Returns the number of files indexed. Best-effort: I/O errors on individual
// files are skipped silently so a permission-denied subdir doesn't take
// down the whole walk.
export fn index_directory(idx: *workspace_index, root: str) size = {
	let count = 0z;
	walk_dir(idx, root, &count);
	return count;
};

fn walk_dir(idx: *workspace_index, dir: str, count: *size) void = {
	const it = match (os::iter(dir)) {
	case let it: *fs::iterator => yield it;
	case fs::error => return;
	};
	defer fs::finish(it);
	for (true) {
		const entry = match (fs::next(it)) {
		case let e: fs::dirent => yield e;
		case done => break;
		case let e: fs::error =>
			break;
		};
		if (entry.name == "." || entry.name == "..") continue;
		const sub = strings::concat(dir, "/", entry.name)!;
		defer free(sub);
		if (fs::isdir(entry.ftype)) {
			walk_dir(idx, sub, count);
			continue;
		};
		if (!fs::isfile(entry.ftype)) continue;
		if (!strings::hassuffix(entry.name, ".ha")) continue;
		// Read the file.
		const f = match (os::open(sub)) {
		case let f: io::file => yield f;
		case fs::error => continue;
		};
		defer io::close(f)!;
		let buf: []u8 = [];
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
		index_file(idx, sub, buf);
		free(buf);
		*count += 1;
	};
};

// Looks up entries by short name. Returns a borrowed slice; callers must
// not mutate the index while holding it.
export fn lookup_by_short_name(idx: *workspace_index, name: str) []workspace_entry = {
	let out: []workspace_entry = [];
	for (let i = 0z; i < len(idx.entries); i += 1) {
		if (idx.entries[i].short_name == name) {
			append(out, idx.entries[i])!;
		};
	};
	return out;
};

// Returns indices into idx.entries whose short names contain the query
// substring (case-insensitive, ASCII fold).
export fn fuzzy_search(idx: *workspace_index, query: str) []size = {
	let out: []size = [];
	const q = ascii_lower(query);
	defer free(q);
	for (let i = 0z; i < len(idx.entries); i += 1) {
		const lower = ascii_lower(idx.entries[i].short_name);
		if (strings::contains(lower, q)) {
			append(out, i)!;
		};
		free(lower);
	};
	return out;
};

fn ascii_lower(s: str) str = {
	let bytes = strings::toutf8(s);
	let buf: []u8 = alloc([], len(bytes))!;
	for (let i = 0z; i < len(bytes); i += 1) {
		let b = bytes[i];
		if (b >= 'A': u8 && b <= 'Z': u8) {
			b += ('a': u8 - 'A': u8);
		};
		append(buf, b)!;
	};
	const result = strings::fromutf8(buf)!;
	const dup = strings::dup(result)!;
	free(buf);
	return dup;
};
