// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Walks an `ast::_type.repr` tree and collects every `ast::ident` it
// references. Used by the type hierarchy handlers to find supertypes
// (idents named in a type's underlying definition) and subtypes (other
// type decls that name us).
//
// Defensive notes (see also resolver.ha, types.ha):
// - No `abort()` calls live in this file; the match arms are exhaustive
//   over `ast::_type.repr` and Hare's compiler enforces that, so a new
//   stdlib variant turns into a build error rather than a runtime crash.
// - Recursive walks are bounded by [[MAX_WALK_DEPTH]] so a pathological
//   AST (deeply nested generic / tuple / tagged type) cannot blow the
//   call stack and crash the server.

use hare::ast;
use strings;

// Hard cap on AST recursion depth for `walk_type`. Realistic Hare types
// nest a handful of levels; 256 is well past anything a human writes
// while still being shallow enough to fit on a default-sized stack.
def MAX_WALK_DEPTH: u32 = 256;

// Returns a fresh slice of every ident referenced by `t`. The caller owns
// the result — the inner ident slices are duplicated via [[strings::dup]]
// so they can outlive the input AST.
//
// Duplicates within the result are removed (so e.g. `(A | A)` yields a
// single ident).
export fn collect_referenced_idents(t: *ast::_type) []ast::ident = {
	let out: []ast::ident = [];
	walk_type(t, &out, 0);
	return out;
};

// Returns the underlying _type of a `type T = U;` decl, or void for any
// other decl variant.
export fn type_decl_underlying(d: *ast::decl) (*ast::_type | void) = {
	match (d.decl) {
	case let t: ast::decl_type =>
		return t._type;
	case =>
		return void;
	};
};

fn walk_type(t: *ast::_type, out: *[]ast::ident, depth: u32) void = {
	if (depth >= MAX_WALK_DEPTH) return;
	const next = depth + 1;
	match (t.repr) {
	case let a: ast::alias_type =>
		add_ident(out, a);
	case ast::builtin_type => void;
	case let e: ast::enum_type => void;
	case let er: ast::error_type =>
		walk_type(er: *ast::_type, out, next);
	case let f: ast::func_type =>
		walk_type(f.result, out, next);
		for (let i = 0z; i < len(f.params); i += 1) {
			walk_type(f.params[i]._type, out, next);
		};
	case let l: ast::list_type =>
		walk_type(l.members, out, next);
	case let p: ast::pointer_type =>
		walk_type(p.referent, out, next);
	case let s: ast::struct_type =>
		walk_struct_members(s.members, out, next);
	case let u: ast::union_type =>
		walk_struct_members(u, out, next);
	case let tag: ast::tagged_type =>
		for (let i = 0z; i < len(tag); i += 1) {
			walk_type(tag[i].0, out, next);
		};
	case let tup: ast::tuple_type =>
		for (let i = 0z; i < len(tup); i += 1) {
			walk_type(tup[i], out, next);
		};
	};
};

fn walk_struct_members(
	membs: []ast::struct_member,
	out: *[]ast::ident,
	depth: u32,
) void = {
	if (depth >= MAX_WALK_DEPTH) return;
	for (let i = 0z; i < len(membs); i += 1) {
		match (membs[i].member) {
		case let f: ast::struct_field =>
			walk_type(f._type, out, depth + 1);
		case let e: ast::struct_embedded =>
			walk_type(e: *ast::_type, out, depth + 1);
		case let a: ast::struct_alias =>
			add_ident(out, a);
		};
	};
};

fn add_ident(out: *[]ast::ident, id: ast::ident) void = {
	let cur = *out;
	for (let i = 0z; i < len(cur); i += 1) {
		if (ident_eq(cur[i], id)) return;
	};
	let dup: ast::ident = alloc([], len(id))!;
	for (let i = 0z; i < len(id); i += 1) {
		append(dup, strings::dup(id[i])!)!;
	};
	append(cur, dup)!;
	*out = cur;
};

fn ident_eq(a: ast::ident, b: ast::ident) bool = {
	if (len(a) != len(b)) return false;
	for (let i = 0z; i < len(a); i += 1) {
		if (a[i] != b[i]) return false;
	};
	return true;
};

// Frees the result of [[collect_referenced_idents]].
export fn finish_idents(idents: []ast::ident) void = {
	for (let i = 0z; i < len(idents); i += 1) {
		for (let j = 0z; j < len(idents[i]); j += 1) {
			free(idents[i][j]);
		};
		free(idents[i]);
	};
	free(idents);
};
