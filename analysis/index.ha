// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Per-file symbol index. Walks an ast::subunit and collects each
// declaration with its identifier, kind, source span, doc comment, and a
// borrowed reference back to the AST node for richer use later (signature
// rendering, etc.).
//
// The resolver layer (see resolver.ha) uses this index plus
// analysis::workspace_index to answer go-to-definition / hover queries.

use hare::ast;
use strings;

// Kind of declaration.
export type symbol_kind = enum {
	FUNCTION,
	TYPE,
	CONST,
	GLOBAL,
	DEF,
};

// One indexed top-level symbol.
export type symbol = struct {
	// The symbol's name as written. For a `foo::bar::baz` decl, this is
	// the joined string "foo::bar::baz".
	// @owned
	name: str,
	// The bare last segment ("baz" in the above example). Most LSP
	// queries match on this.
	// @owned
	short_name: str,
	kind: symbol_kind,
	// Span of the entire decl (for hover preview).
	span: ast::location,
	// Doc comment captured by the lexer if any. Empty string if absent.
	// @owned
	docs: str,
	// Whether the decl was declared `export`.
	exported: bool,
	// For FUNCTION-kind symbols: parameter names from the prototype, in
	// order. Empty for unnamed parameters and for non-function symbols.
	// Used by completion to render snippet placeholders like ${1:path}.
	// @owned
	param_names: []str,
	// Ownership classification of the value the decl produces (return
	// value for functions, the value itself for globals/consts). Populated
	// at index time from Layer-1 annotations only. Layer 2 (stdlib doc
	// comments) is applied later by the stdlib indexer; Layer 3
	// (heuristics) is computed at hover time and never stored here.
	return_ownership: ownership,
	return_ownership_source: ownership_source,
	// @owned
	return_ownership_detail: str,
	// Parallel to `param_names`: per-parameter ownership from Layer-1
	// `@param <name>: ...` tags. Empty slice for non-functions.
	// @owned
	param_ownerships: []ownership,
	// @owned
	param_ownership_details: []str,
};

// A per-file symbol index.
export type file_index = struct {
	// @owned
	symbols: []symbol,
};

// Builds a file index from a subunit.
//
// @param su: borrowed
export fn build_index(su: *ast::subunit) file_index = {
	let idx = file_index { symbols = [] };
	for (let i = 0z; i < len(su.decls); i += 1) {
		index_decl(&idx, &su.decls[i]);
	};
	return idx;
};

// Releases resources owned by a file_index.
//
// @param idx: borrowed
export fn finish_index(idx: *file_index) void = {
	for (let i = 0z; i < len(idx.symbols); i += 1) {
		free(idx.symbols[i].name);
		free(idx.symbols[i].short_name);
		free(idx.symbols[i].docs);
		for (let j = 0z; j < len(idx.symbols[i].param_names); j += 1) {
			free(idx.symbols[i].param_names[j]);
		};
		free(idx.symbols[i].param_names);
		free(idx.symbols[i].return_ownership_detail);
		free(idx.symbols[i].param_ownerships);
		for (let j = 0z; j < len(idx.symbols[i].param_ownership_details); j += 1) {
			free(idx.symbols[i].param_ownership_details[j]);
		};
		free(idx.symbols[i].param_ownership_details);
	};
	free(idx.symbols);
};

// @param idx: borrowed
// @param d: borrowed
fn index_decl(idx: *file_index, d: *ast::decl) void = {
	const docs = if (len(d.docs) > 0) strings::dup(d.docs)! else strings::dup("")!;
	match (d.decl) {
	case let f: ast::decl_func =>
		const params = extract_param_names(f);
		const fact = annotations_from_docs(docs, true);
		const po = param_annotations_from_docs(docs, params);
		add_symbol(idx, f.ident, symbol_kind::FUNCTION, d.loc, docs, d.exported,
			params, fact, po.0, po.1);
	case let t: ast::decl_type =>
		const fact = empty_ownership_fact();
		add_symbol(idx, t.ident, symbol_kind::TYPE, d.loc, docs, d.exported, [], fact,
			[], []);
	case let g: ast::decl_global =>
		const k = if (g.is_const) symbol_kind::CONST else symbol_kind::GLOBAL;
		const fact = annotations_from_docs(docs, false);
		add_symbol(idx, g.ident, k, d.loc, docs, d.exported, [], fact, [], []);
	case let c: ast::decl_const =>
		const fact = annotations_from_docs(docs, false);
		add_symbol(idx, c.ident, symbol_kind::DEF, d.loc, docs, d.exported, [], fact,
			[], []);
	case ast::assert_expr =>
		// `static assert(...)` — no symbol introduced.
		free(docs);
	};
};

fn extract_param_names(f: ast::decl_func) []str = {
	let out: []str = [];
	match (f.prototype.repr) {
	case let proto: ast::func_type =>
		for (let i = 0z; i < len(proto.params); i += 1) {
			append(out, strings::dup(proto.params[i].name)!)!;
		};
	case => void;
	};
	return out;
};

// @param idx: borrowed
// @param id: borrowed
// @param docs: owned
// @param param_names: owned
// @param param_ownerships: owned
// @param param_ownership_details: owned
fn add_symbol(
	idx: *file_index,
	id: ast::ident,
	kind: symbol_kind,
	loc: ast::location,
	docs: str,
	exported: bool,
	param_names: []str,
	fact: ownership_fact,
	param_ownerships: []ownership,
	param_ownership_details: []str,
) void = {
	const joined = ident_join(id);
	const short = if (len(id) > 0) strings::dup(id[len(id) - 1])!
		else strings::dup("")!;
	append(idx.symbols, symbol {
		name = joined,
		short_name = short,
		kind = kind,
		span = loc,
		docs = docs,
		exported = exported,
		param_names = param_names,
		return_ownership = fact.kind,
		return_ownership_source = fact.source,
		return_ownership_detail = fact.detail,
		param_ownerships = param_ownerships,
		param_ownership_details = param_ownership_details,
	})!;
};

// @param id: borrowed
fn ident_join(id: ast::ident) str = {
	if (len(id) == 0) return strings::dup("")!;
	if (len(id) == 1) return strings::dup(id[0])!;
	let parts: []str = [];
	defer free(parts);
	for (let i = 0z; i < len(id); i += 1) {
		append(parts, id[i])!;
	};
	return strings::join("::", parts...)!;
};

// Returns the symbol whose span contains the given byte offset, or void if
// none. Linear scan; per-file decl counts are small enough that a binary
// tree wouldn't pay off.
//
// @returns: borrowed from idx
// @param idx: borrowed
export fn symbol_at(idx: *file_index, off: size) (*symbol | void) = {
	for (let i = 0z; i < len(idx.symbols); i += 1) {
		const s = &idx.symbols[i];
		if (offset_in_span(off, s.span)) return s;
	};
	return void;
};

// Returns the symbol with the given short name, or void if none.
//
// @returns: borrowed from idx
// @param idx: borrowed
// @param name: borrowed
export fn find_by_short_name(idx: *file_index, name: str) (*symbol | void) = {
	for (let i = 0z; i < len(idx.symbols); i += 1) {
		if (idx.symbols[i].short_name == name) return &idx.symbols[i];
	};
	return void;
};
