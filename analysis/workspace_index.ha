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
	// The module this entry lives in, derived from the basename of
	// the file's containing directory. For /repo/foo/bar.ha this is
	// "foo". Matches the Hare convention that directory == module name.
	module: str,
	// For FUNCTION-kind entries: parameter names from the prototype.
	// Empty for non-functions and for prototypes with no named params.
	// Used to build snippet placeholders in completion.
	param_names: []str,
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
		free_workspace_entry(&idx.entries[i]);
	};
	free(idx.entries);
	for (let i = 0z; i < len(idx.indexed_files); i += 1) {
		free(idx.indexed_files[i]);
	};
	free(idx.indexed_files);
};

fn free_workspace_entry(e: *workspace_entry) void = {
	free(e.uri);
	free(e.path);
	free(e.short_name);
	free(e.full_name);
	free(e.docs);
	free(e.module);
	for (let j = 0z; j < len(e.param_names); j += 1) {
		free(e.param_names[j]);
	};
	free(e.param_names);
};

// Drops all entries originating from `path`. Used when a file is renamed,
// deleted, or modified before re-indexing.
export fn drop_file(idx: *workspace_index, path_str: str) void = {
	let i = 0z;
	for (i < len(idx.entries)) {
		if (idx.entries[i].path == path_str) {
			free_workspace_entry(&idx.entries[i]);
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
	const module = module_from_path(file_path);
	for (let i = 0z; i < len(fi.symbols); i += 1) {
		const sym = &fi.symbols[i];
		let pn: []str = [];
		for (let j = 0z; j < len(sym.param_names); j += 1) {
			append(pn, strings::dup(sym.param_names[j])!)!;
		};
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
			module = strings::dup(module)!,
			param_names = pn,
		})!;
	};
	free(uri);
	free(module);
	append(idx.indexed_files, strings::dup(file_path)!)!;
};

// Returns the module-name basename of the directory containing the given
// file. For "/repo/foo/bar.ha" returns "foo". For a file in the workspace
// root (no parent directory in the path) returns "".
fn module_from_path(file_path: str) str = {
	const last_slash = match (strings::rindex(file_path, '/')) {
	case let i: size => yield i;
	case void => return strings::dup("")!;
	};
	if (last_slash == 0) return strings::dup("")!;
	const dir = strings::sub(file_path, 0, last_slash);
	const prev = match (strings::rindex(dir, '/')) {
	case let i: size => yield i + 1;
	case void => yield 0z;
	};
	return strings::dup(strings::sub(dir, prev, strings::end))!;
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
		defer match (io::close(f)) { case => void; };
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

// Returns a borrowed pointer to the first entry whose short_name matches,
// or void if none exists. Used by navigation features (hover, definition,
// etc.) that take "any" hit when falling back from per-file resolution.
export fn find_first_by_short_name(idx: *workspace_index, name: str) (*workspace_entry | void) = {
	for (let i = 0z; i < len(idx.entries); i += 1) {
		if (idx.entries[i].short_name == name) {
			return &idx.entries[i];
		};
	};
	return void;
};

// Returns the first entry matching (module, short_name). Used for
// qualified references like `mod::name`.
export fn find_in_module(idx: *workspace_index, module: str, name: str) (*workspace_entry | void) = {
	for (let i = 0z; i < len(idx.entries); i += 1) {
		const e = &idx.entries[i];
		if (e.short_name == name && e.module == module) {
			return e;
		};
	};
	return void;
};

// Returns the first entry matching short_name whose `module` is one of
// the given imported module names. Used for unqualified references in a
// file whose `use` list narrows the candidate set.
//
// `imported_modules` is a slice of module short names (e.g. ["io",
// "strings"]). If empty, this function returns void — callers fall back
// to [[find_first_by_short_name]] only as a last resort.
export fn find_in_imports(
	idx: *workspace_index,
	imported_modules: []str,
	name: str,
) (*workspace_entry | void) = {
	if (len(imported_modules) == 0) return void;
	for (let i = 0z; i < len(idx.entries); i += 1) {
		const e = &idx.entries[i];
		if (e.short_name != name) continue;
		for (let j = 0z; j < len(imported_modules); j += 1) {
			if (e.module == imported_modules[j]) {
				return e;
			};
		};
	};
	return void;
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
