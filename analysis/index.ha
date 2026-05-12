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
	name: str,
	// The bare last segment ("baz" in the above example). Most LSP
	// queries match on this.
	short_name: str,
	kind: symbol_kind,
	// Span of the entire decl (for hover preview).
	span: ast::location,
	// Span of just the identifier (for prepareRename / definition target).
	name_span: ast::location,
	// Doc comment captured by the lexer if any. Empty string if absent.
	docs: str,
	// Whether the decl was declared `export`.
	exported: bool,
	// For FUNCTION-kind symbols: parameter names from the prototype, in
	// order. Empty for unnamed parameters and for non-function symbols.
	// Used by completion to render snippet placeholders like ${1:path}.
	param_names: []str,
};

// A per-file symbol index.
export type file_index = struct {
	symbols: []symbol,
};

// Builds a file index from a subunit.
export fn build_index(su: *ast::subunit) file_index = {
	let idx = file_index { symbols = [] };
	for (let i = 0z; i < len(su.decls); i += 1) {
		index_decl(&idx, &su.decls[i]);
	};
	return idx;
};

// Releases resources owned by a file_index.
export fn finish_index(idx: *file_index) void = {
	for (let i = 0z; i < len(idx.symbols); i += 1) {
		free(idx.symbols[i].name);
		free(idx.symbols[i].short_name);
		free(idx.symbols[i].docs);
		for (let j = 0z; j < len(idx.symbols[i].param_names); j += 1) {
			free(idx.symbols[i].param_names[j]);
		};
		free(idx.symbols[i].param_names);
	};
	free(idx.symbols);
};

fn index_decl(idx: *file_index, d: *ast::decl) void = {
	const docs = if (len(d.docs) > 0) strings::dup(d.docs)! else strings::dup("")!;
	match (d.decl) {
	case let f: ast::decl_func =>
		const params = extract_param_names(f);
		add_symbol(idx, f.ident, symbol_kind::FUNCTION, d.loc, docs, d.exported,
			params);
	case let t: ast::decl_type =>
		add_symbol(idx, t.ident, symbol_kind::TYPE, d.loc, docs, d.exported, []);
	case let g: ast::decl_global =>
		const k = if (g.is_const) symbol_kind::CONST else symbol_kind::GLOBAL;
		add_symbol(idx, g.ident, k, d.loc, docs, d.exported, []);
	case let c: ast::decl_const =>
		add_symbol(idx, c.ident, symbol_kind::DEF, d.loc, docs, d.exported, []);
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

fn add_symbol(
	idx: *file_index,
	id: ast::ident,
	kind: symbol_kind,
	loc: ast::location,
	docs: str,
	exported: bool,
	param_names: []str,
) void = {
	const joined = ident_join(id);
	const short = if (len(id) > 0) strings::dup(id[len(id) - 1])!
		else strings::dup("")!;
	// For now the name span is approximated as the loc's start..start+len(short).
	const name_span = ast::location {
		start = loc.start,
		end = loc.start,
	};
	append(idx.symbols, symbol {
		name = joined,
		short_name = short,
		kind = kind,
		span = loc,
		name_span = name_span,
		docs = docs,
		exported = exported,
		param_names = param_names,
	})!;
};

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
export fn symbol_at(idx: *file_index, off: size) (*symbol | void) = {
	for (let i = 0z; i < len(idx.symbols); i += 1) {
		const s = &idx.symbols[i];
		const start = s.span.start.off: size;
		const end = s.span.end.off: size;
		if (off >= start && off <= end) return s;
	};
	return void;
};

// Returns the symbol with the given short name, or void if none.
export fn find_by_short_name(idx: *file_index, name: str) (*symbol | void) = {
	for (let i = 0z; i < len(idx.symbols); i += 1) {
		if (idx.symbols[i].short_name == name) return &idx.symbols[i];
	};
	return void;
};
