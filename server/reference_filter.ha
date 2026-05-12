// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Module-aware filtering for the references/rename textual workspace
// scan. The scan finds every ident token whose text matches the target,
// then this predicate verifies each hit re-resolves (in its file's
// scope) to the same workspace_entry the cursor pointed at. Hits in
// stdlib or unindexed files are dropped — they can't be authoritatively
// linked to a workspace decl.

use analysis;
use hare::ast;
use lsp;
use strings;

// Returns the file's parsed subunit and text via the existing caches.
// For an open document, uses the open-doc parse cache. Otherwise consults
// the file_parse_cache (which reads + parses on demand). Returns void
// when neither path is available, signaling the hit should be dropped.
fn subunit_for_path(s: *server, path: str) (*ast::subunit | void) = {
	for (let i = 0z; i < len(s.documents); i += 1) {
		const doc = &s.documents[i];
		const doc_path = lsp::uri_decode_path(doc.uri);
		defer free(doc_path);
		if (doc_path == path) {
			return &parse_of(doc).pr.subunit;
		};
	};
	match (cached_parse_or_drop_stale(s, path)) {
	case let p: *file_parse_entry =>
		return &p.pr.subunit;
	case null =>
		return void;
	};
};

// Resolves the cursor's identifier to the workspace_entry it points at,
// or void when no workspace match exists (e.g. unindexed file, fresh
// symbol, or stdlib-only target). The caller falls back to the existing
// behavior (return all textual hits) when this returns void.
export fn expected_entry_for_cursor(
	s: *server,
	doc: *document,
	data: []u8,
	ident_start: size,
	ident_str: str,
) (*analysis::workspace_entry | void) = {
	const cache = parse_of(doc);
	const qualifier = analysis::qualifier_prefix_at(data, ident_start);
	defer free(qualifier);
	const doc_path = lsp::uri_decode_path(doc.uri);
	defer free(doc_path);
	const file_module = analysis::module_from_path(doc_path);
	defer free(file_module);
	return analysis::workspace_lookup_for_subunit(&s.workspace_index,
		&cache.pr.subunit, file_module, qualifier, ident_str);
};

// Returns true if the ident at `(text, off)` in `path` resolves (via the
// file's `use` list + workspace index) to the same workspace_entry as
// `expected`. False when the resolution misses or points elsewhere.
//
// Hits in files that aren't workspace-indexed (stdlib, third-party)
// return false because there's no entry to match against.
export fn hit_resolves_to(
	s: *server,
	path: str,
	text: []u8,
	off: size,
	expected: *analysis::workspace_entry,
) bool = {
	const ident_range = match (analysis::ident_at(text, off)) {
	case let r: (size, size) => yield r;
	case void => return false;
	};
	const ident_str = strings::fromutf8(text[ident_range.0..ident_range.1])!;
	const qualifier = analysis::qualifier_prefix_at(text, ident_range.0);
	defer free(qualifier);

	const su = match (subunit_for_path(s, path)) {
	case let p: *ast::subunit => yield p;
	case void => return false;
	};

	const file_module = analysis::module_from_path(path);
	defer free(file_module);
	match (analysis::workspace_lookup_for_subunit(&s.workspace_index,
			su, file_module, qualifier, ident_str)) {
	case let e: *analysis::workspace_entry =>
		return e.path == expected.path &&
			e.short_name == expected.short_name &&
			e.kind == expected.kind;
	case void =>
		return false;
	};
};
