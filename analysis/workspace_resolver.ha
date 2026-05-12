// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Module-aware workspace-symbol resolver. Given a parsed subunit, an
// identifier name, and an optional `::`-qualifier, returns the
// workspace_entry the reference points at, ranked by the file's `use`
// list. Pure: no `*server` dependency, no stdlib lookup. Stdlib resolution
// is handled at the server layer (see `server/navigation.ha`).

use hare::ast;
use strings;

// Collects the short-name modules imported in the file's `use` block. For
// `use io;` adds "io"; for `use foo::bar;` adds "bar" (the last segment).
// Caller frees the slice and each string via [[free_str_slice]].
export fn collect_imported_module_names(su: *ast::subunit) []str = {
	let out: []str = [];
	for (let i = 0z; i < len(su.imports); i += 1) {
		const id = su.imports[i].ident;
		if (len(id) == 0) continue;
		append(out, strings::dup(id[len(id) - 1])!)!;
	};
	return out;
};

// Like [[collect_imported_module_names]] but returns the full module identifier
// ("unix::poll") rather than just the last segment. Used by callers that
// need the full path for directory lookups.
export fn collect_imported_module_paths(su: *ast::subunit) []str = {
	let out: []str = [];
	for (let i = 0z; i < len(su.imports); i += 1) {
		const id = su.imports[i].ident;
		if (len(id) == 0) continue;
		append(out, join_module_ident(id))!;
	};
	return out;
};

// Finds the full module identifier for an import whose last segment matches
// `qualifier` ("poll" -> "unix::poll" if such an import exists). Returns
// the empty string when nothing matches; the result is always allocated.
export fn full_module_for_qualifier(su: *ast::subunit, qualifier: str) str = {
	for (let i = 0z; i < len(su.imports); i += 1) {
		const id = su.imports[i].ident;
		if (len(id) == 0) continue;
		if (id[len(id) - 1] != qualifier) continue;
		return join_module_ident(id);
	};
	return strings::dup("")!;
};

// Joins an `ast::ident` (a sequence of segments) into the canonical
// `::`-separated form. Caller frees.
export fn join_module_ident(id: ast::ident) str = {
	let out: []u8 = [];
	for (let i = 0z; i < len(id); i += 1) {
		if (i > 0) {
			append(out, ':': u8)!;
			append(out, ':': u8)!;
		};
		const seg = strings::toutf8(id[i]);
		for (let j = 0z; j < len(seg); j += 1) {
			append(out, seg[j])!;
		};
	};
	return strings::fromutf8(out)!;
};

// Frees each string in a slice, then frees the slice itself.
export fn free_str_slice(s: []str) void = {
	for (let i = 0z; i < len(s); i += 1) {
		free(s[i]);
	};
	free(s);
};

// Module-aware workspace lookup, pure version. Tries in priority order:
//   1. Qualifier present  -> find_in_module(qualifier, name)
//   2. find_in_module(file_module, name) when file_module is non-empty
//   3. find_in_imports(file's imports, name)
//   4. find_first_by_short_name (last-resort fallback)
//
// `file_module` is the short module name of the file holding the
// reference (e.g. "io" for a file under `/repo/io/`). Pass the empty
// string to skip the same-module check.
//
// Returns void when no workspace match is found. Callers that also want
// stdlib coverage layer that on top (see `server/navigation.ha`).
export fn workspace_lookup_for_subunit(
	idx: *workspace_index,
	su: *ast::subunit,
	file_module: str,
	qualifier: str,
	name: str,
) (*workspace_entry | void) = {
	if (len(qualifier) > 0) {
		return find_in_module(idx, qualifier, name);
	};
	if (len(file_module) > 0) {
		match (find_in_module(idx, file_module, name)) {
		case let e: *workspace_entry =>
			return e;
		case void => void;
		};
	};
	const imports = collect_imported_module_names(su);
	defer free_str_slice(imports);
	match (find_in_imports(idx, imports, name)) {
	case let e: *workspace_entry =>
		return e;
	case void => void;
	};
	return find_first_by_short_name(idx, name);
};
