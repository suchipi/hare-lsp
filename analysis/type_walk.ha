// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Walks an `ast::_type.repr` tree and collects every `ast::ident` it
// references. Used by the type hierarchy handlers to find supertypes
// (idents named in a type's underlying definition) and subtypes (other
// type decls that name us).

use hare::ast;
use strings;

// Returns a fresh slice of every ident referenced by `t`. The caller owns
// the result — the inner ident slices are duplicated via [[strings::dup]]
// so they can outlive the input AST.
//
// Duplicates within the result are removed (so e.g. `(A | A)` yields a
// single ident).
export fn collect_referenced_idents(t: *ast::_type) []ast::ident = {
	let out: []ast::ident = [];
	walk_type(t, &out);
	return out;
};

// Returns the underlying _type of a `type T = U;` decl, or void for any
// other decl variant.
export fn type_decl_underlying(d: *ast::decl) (*ast::_type | void) = {
	match (d.decl) {
	case let t: ast::decl_type =>
		return t._type;
	case => return void;
	};
};

fn walk_type(t: *ast::_type, out: *[]ast::ident) void = {
	match (t.repr) {
	case let a: ast::alias_type =>
		add_ident(out, a);
	case ast::builtin_type => void;
	case let e: ast::enum_type => void;
	case let er: ast::error_type =>
		walk_type(er: *ast::_type, out);
	case let f: ast::func_type =>
		walk_type(f.result, out);
		for (let i = 0z; i < len(f.params); i += 1) {
			walk_type(f.params[i]._type, out);
		};
	case let l: ast::list_type =>
		walk_type(l.members, out);
	case let p: ast::pointer_type =>
		walk_type(p.referent, out);
	case let s: ast::struct_type =>
		walk_struct_members(s.members, out);
	case let u: ast::union_type =>
		walk_struct_members(u, out);
	case let tag: ast::tagged_type =>
		for (let i = 0z; i < len(tag); i += 1) {
			walk_type(tag[i].0, out);
		};
	case let tup: ast::tuple_type =>
		for (let i = 0z; i < len(tup); i += 1) {
			walk_type(tup[i], out);
		};
	};
};

fn walk_struct_members(membs: []ast::struct_member, out: *[]ast::ident) void = {
	for (let i = 0z; i < len(membs); i += 1) {
		match (membs[i].member) {
		case let f: ast::struct_field =>
			walk_type(f._type, out);
		case let e: ast::struct_embedded =>
			walk_type(e: *ast::_type, out);
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
