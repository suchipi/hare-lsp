// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Post-parse fixup for AST location offsets.
//
// `hare::lex` tracks source position by RUNE count, not BYTE count
// (see `hare::lex::lexloc`, which does `lex.loc.2 += 1` per rune
// regardless of UTF-8 width). Every `loc.start.off` and `loc.end.off`
// in the AST therefore counts runes from the start of the file.
//
// Downstream code in this project — notably `byte_to_position` and
// every navigation / hover / documentLink handler that slices into
// the source `text` — treats those offsets as BYTE offsets. For pure
// ASCII files the two coincide, but as soon as the file contains a
// multi-byte UTF-8 sequence above an AST node, that node's reported
// position drifts.
//
// This module walks the parse result once after parsing, replacing
// every `loc.off` with the corresponding byte offset. Once that's
// done, every existing offset-consuming caller becomes correct
// without changes.
//
// The translator uses a precomputed rune-index → byte-offset table
// over the source bytes. Building the table is O(n); each lookup is
// O(1).

use hare::ast;
use hare::lex;

// Walks `r` and translates every embedded `loc.off` from a
// rune-index (the lex convention) into a byte offset into `data`.
// Not idempotent — call once per parse, with the source bytes the
// parse was performed against.
export fn fixup_parse_result(r: *parse_result, data: []u8) void = {
	const r2b = build_rune_to_byte_table(data);
	defer free(r2b);
	for (let i = 0z; i < len(r.subunit.imports); i += 1) {
		fixup_location(&r.subunit.imports[i].loc, r2b, len(data));
	};
	for (let i = 0z; i < len(r.subunit.decls); i += 1) {
		fixup_decl(&r.subunit.decls[i], r2b, len(data));
	};
	for (let i = 0z; i < len(r.errors); i += 1) {
		fixup_lex_location(&r.errors[i].location, r2b, len(data));
	};
};

fn fixup_decl(d: *ast::decl, r2b: []size, data_len: size) void = {
	fixup_location(&d.loc, r2b, data_len);
	match (d.decl) {
	case let f: ast::decl_func =>
		fixup_type(f.prototype, r2b, data_len);
		match (f.body) {
		case null => void;
		case let e: *ast::expr =>
			fixup_expr(e, r2b, data_len);
		};
	case let g: ast::decl_global =>
		match (g._type) {
		case null => void;
		case let t: *ast::_type =>
			fixup_type(t, r2b, data_len);
		};
		match (g.init) {
		case null => void;
		case let e: *ast::expr =>
			fixup_expr(e, r2b, data_len);
		};
	case let c: ast::decl_const =>
		match (c._type) {
		case null => void;
		case let t: *ast::_type =>
			fixup_type(t, r2b, data_len);
		};
		fixup_expr(c.init, r2b, data_len);
	case let t: ast::decl_type =>
		fixup_type(t._type, r2b, data_len);
	case let e: ast::assert_expr =>
		match (e.cond) {
		case null => void;
		case let p: *ast::expr =>
			fixup_expr(p, r2b, data_len);
		};
		match (e.message) {
		case null => void;
		case let p: *ast::expr =>
			fixup_expr(p, r2b, data_len);
		};
	};
};

fn fixup_type(t: *ast::_type, r2b: []size, data_len: size) void = {
	fixup_location(&t.loc, r2b, data_len);
	match (t.repr) {
	case ast::alias_type => void;
	case ast::builtin_type => void;
	case let e: ast::enum_type =>
		for (let i = 0z; i < len(e.values); i += 1) {
			fixup_lex_location(&e.values[i].loc, r2b, data_len);
			match (e.values[i].value) {
			case null => void;
			case let p: *ast::expr =>
				fixup_expr(p, r2b, data_len);
			};
		};
	case let e: ast::error_type =>
		fixup_type(e: *ast::_type, r2b, data_len);
	case let f: ast::func_type =>
		fixup_type(f.result, r2b, data_len);
		for (let i = 0z; i < len(f.params); i += 1) {
			fixup_lex_location(&f.params[i].loc, r2b, data_len);
			fixup_type(f.params[i]._type, r2b, data_len);
			match (&f.params[i].default_value) {
			case let p: *ast::expr =>
				fixup_expr(p, r2b, data_len);
			case void => void;
			};
		};
	case let l: ast::list_type =>
		match (l.length) {
		case let p: *ast::expr =>
			fixup_expr(p, r2b, data_len);
		case => void;
		};
		fixup_type(l.members, r2b, data_len);
	case let p: ast::pointer_type =>
		fixup_type(p.referent, r2b, data_len);
	case let s: ast::struct_type =>
		for (let i = 0z; i < len(s.members); i += 1) {
			fixup_struct_member(&s.members[i], r2b, data_len);
		};
	case let u: ast::union_type =>
		for (let i = 0z; i < len(u); i += 1) {
			fixup_struct_member(&u[i], r2b, data_len);
		};
	case let tt: ast::tagged_type =>
		for (let i = 0z; i < len(tt); i += 1) {
			fixup_type(tt[i].0, r2b, data_len);
		};
	case let tt: ast::tuple_type =>
		for (let i = 0z; i < len(tt); i += 1) {
			fixup_type(tt[i], r2b, data_len);
		};
	};
};

fn fixup_struct_member(
	m: *ast::struct_member,
	r2b: []size,
	data_len: size,
) void = {
	match (m.member) {
	case let f: ast::struct_field =>
		fixup_type(f._type, r2b, data_len);
	case let e: ast::struct_embedded =>
		fixup_type(e: *ast::_type, r2b, data_len);
	case ast::struct_alias => void;
	};
};

fn fixup_expr(e: *ast::expr, r2b: []size, data_len: size) void = {
	fixup_location(&e.loc, r2b, data_len);
	match (e.expr) {
	case let a: ast::access_expr =>
		match (a) {
		case ast::access_identifier => void;
		case let i: ast::access_index =>
			fixup_expr(i.object, r2b, data_len);
			fixup_expr(i.index, r2b, data_len);
		case let f: ast::access_field =>
			fixup_expr(f.object, r2b, data_len);
		case let t: ast::access_tuple =>
			fixup_expr(t.object, r2b, data_len);
			fixup_expr(t.value, r2b, data_len);
		};
	case let a: ast::align_expr =>
		fixup_type(a, r2b, data_len);
	case let a: ast::alloc_expr =>
		fixup_expr(a.init, r2b, data_len);
		match (a.capacity) {
		case let p: *ast::expr =>
			fixup_expr(p, r2b, data_len);
		case null => void;
		};
	case let a: ast::append_expr =>
		fixup_expr(a.object, r2b, data_len);
		fixup_expr(a.value, r2b, data_len);
		match (a.length) {
		case let p: *ast::expr =>
			fixup_expr(p, r2b, data_len);
		case null => void;
		};
	case let a: ast::assert_expr =>
		match (a.cond) {
		case let p: *ast::expr =>
			fixup_expr(p, r2b, data_len);
		case null => void;
		};
		match (a.message) {
		case let p: *ast::expr =>
			fixup_expr(p, r2b, data_len);
		case null => void;
		};
	case let a: ast::assign_expr =>
		match (a.object) {
		case let p: *ast::expr =>
			fixup_expr(p, r2b, data_len);
		case null => void;
		};
		fixup_expr(a.value, r2b, data_len);
	case let b: ast::binarithm_expr =>
		fixup_expr(b.lvalue, r2b, data_len);
		fixup_expr(b.rvalue, r2b, data_len);
	case let b: ast::binding_expr =>
		for (let i = 0z; i < len(b.bindings); i += 1) {
			match (b.bindings[i]._type) {
			case let t: *ast::_type =>
				fixup_type(t, r2b, data_len);
			case null => void;
			};
			fixup_expr(b.bindings[i].init, r2b, data_len);
		};
	case let b: ast::break_expr =>
		match (b.value) {
		case let p: *ast::expr =>
			fixup_expr(p, r2b, data_len);
		case null => void;
		};
	case let c: ast::call_expr =>
		fixup_expr(c.lvalue, r2b, data_len);
		for (let i = 0z; i < len(c.args); i += 1) {
			fixup_expr(c.args[i], r2b, data_len);
		};
	case let c: ast::cast_expr =>
		fixup_expr(c.value, r2b, data_len);
		fixup_type(c._type, r2b, data_len);
	case let l: ast::literal_expr =>
		fixup_literal(l, r2b, data_len);
	case ast::continue_expr => void;
	case let d: ast::defer_expr =>
		fixup_expr(d, r2b, data_len);
	case let d: ast::delete_expr =>
		fixup_expr(d.object, r2b, data_len);
	case let f: ast::for_expr =>
		match (f.bindings) {
		case let p: *ast::expr =>
			fixup_expr(p, r2b, data_len);
		case null => void;
		};
		match (f.cond) {
		case let p: *ast::expr =>
			fixup_expr(p, r2b, data_len);
		case null => void;
		};
		match (f.afterthought) {
		case let p: *ast::expr =>
			fixup_expr(p, r2b, data_len);
		case null => void;
		};
		fixup_expr(f.body, r2b, data_len);
		match (f.else_branch) {
		case let p: *ast::expr =>
			fixup_expr(p, r2b, data_len);
		case null => void;
		};
	case let f: ast::free_expr =>
		fixup_expr(f, r2b, data_len);
	case let e: ast::error_assert_expr =>
		fixup_expr(e, r2b, data_len);
	case let i: ast::if_expr =>
		fixup_expr(i.cond, r2b, data_len);
		fixup_expr(i.tbranch, r2b, data_len);
		match (i.fbranch) {
		case let p: *ast::expr =>
			fixup_expr(p, r2b, data_len);
		case null => void;
		};
	case let ie: ast::insert_expr =>
		fixup_expr(ie.object, r2b, data_len);
		fixup_expr(ie.value, r2b, data_len);
		match (ie.length) {
		case let p: *ast::expr =>
			fixup_expr(p, r2b, data_len);
		case null => void;
		};
	case let cmp: ast::compound_expr =>
		for (let i = 0z; i < len(cmp.exprs); i += 1) {
			fixup_expr(cmp.exprs[i], r2b, data_len);
		};
	case let m: ast::match_expr =>
		fixup_expr(m.value, r2b, data_len);
		for (let i = 0z; i < len(m.cases); i += 1) {
			match (m.cases[i]._type) {
			case let t: *ast::_type =>
				fixup_type(t, r2b, data_len);
			case null => void;
			};
			for (let j = 0z; j < len(m.cases[i].exprs); j += 1) {
				fixup_expr(m.cases[i].exprs[j], r2b, data_len);
			};
		};
	case let l: ast::len_expr =>
		fixup_expr(l, r2b, data_len);
	case let s: ast::size_expr =>
		fixup_type(s, r2b, data_len);
	case let o: ast::offset_expr =>
		fixup_expr(o, r2b, data_len);
	case let p: ast::propagate_expr =>
		fixup_expr(p, r2b, data_len);
	case let r: ast::return_expr =>
		match (r) {
		case let p: *ast::expr =>
			fixup_expr(p, r2b, data_len);
		case null => void;
		};
	case let s: ast::slice_expr =>
		fixup_expr(s.object, r2b, data_len);
		match (s.start) {
		case let p: *ast::expr =>
			fixup_expr(p, r2b, data_len);
		case null => void;
		};
		match (s.end) {
		case let p: *ast::expr =>
			fixup_expr(p, r2b, data_len);
		case null => void;
		};
	case let sw: ast::switch_expr =>
		fixup_expr(sw.value, r2b, data_len);
		for (let i = 0z; i < len(sw.cases); i += 1) {
			for (let j = 0z; j < len(sw.cases[i].options); j += 1) {
				fixup_expr(sw.cases[i].options[j], r2b, data_len);
			};
			for (let j = 0z; j < len(sw.cases[i].exprs); j += 1) {
				fixup_expr(sw.cases[i].exprs[j], r2b, data_len);
			};
		};
	case let u: ast::unarithm_expr =>
		fixup_expr(u.operand, r2b, data_len);
	case ast::undefined_expr => void;
	case let v: ast::variadic_expr =>
		match (v) {
		case ast::vastart_expr => void;
		case let va: ast::vaarg_expr =>
			fixup_expr(va.ap, r2b, data_len);
			fixup_type(va._type, r2b, data_len);
		case let ve: ast::vaend_expr =>
			fixup_expr(ve, r2b, data_len);
		};
	case let y: ast::yield_expr =>
		match (y.value) {
		case let p: *ast::expr =>
			fixup_expr(p, r2b, data_len);
		case null => void;
		};
	};
};

fn fixup_literal(l: ast::literal_expr, r2b: []size, data_len: size) void = {
	match (l) {
	case ast::plain_literal => void;
	case let a: ast::array_literal =>
		for (let i = 0z; i < len(a.values); i += 1) {
			fixup_expr(a.values[i], r2b, data_len);
		};
	case let s: ast::struct_literal =>
		fixup_struct_literal(&s, r2b, data_len);
	case let t: ast::tuple_literal =>
		for (let i = 0z; i < len(t); i += 1) {
			fixup_expr(t[i], r2b, data_len);
		};
	};
};

fn fixup_struct_literal(
	s: *ast::struct_literal,
	r2b: []size,
	data_len: size,
) void = {
	for (let i = 0z; i < len(s.fields); i += 1) {
		match (s.fields[i]) {
		case let v: ast::struct_value =>
			match (v._type) {
			case let t: *ast::_type =>
				fixup_type(t, r2b, data_len);
			case null => void;
			};
			fixup_expr(v.init, r2b, data_len);
		case let nested: *ast::struct_literal =>
			fixup_struct_literal(nested, r2b, data_len);
		};
	};
};

// Translates a single ast::location's start/end from rune-offsets to
// byte-offsets in place.
fn fixup_location(loc: *ast::location, r2b: []size, data_len: size) void = {
	loc.start.off = translate_off(loc.start.off, r2b, data_len);
	loc.end.off = translate_off(loc.end.off, r2b, data_len);
};

// Same, for a bare lex::location (used by enum_field, func_param,
// parse_diagnostic).
fn fixup_lex_location(loc: *lex::location, r2b: []size, data_len: size) void = {
	loc.off = translate_off(loc.off, r2b, data_len);
};

// Translates a single rune-offset to a byte offset. Out-of-range
// indices clamp to data_len.
fn translate_off(off: i64, r2b: []size, data_len: size) i64 = {
	if (off < 0) return 0;
	const u = off: size;
	if (u >= len(r2b)) return data_len: i64;
	return r2b[u]: i64;
};

// Builds a slice mapping rune index -> byte offset. Length is
// (rune count) + 1, so the past-the-end position translates too.
fn build_rune_to_byte_table(data: []u8) []size = {
	let out: []size = [];
	let i = 0z;
	for (i < len(data)) {
		append(out, i)!;
		const b = data[i];
		const width: size = if (b < 0x80)
			1z
		else if (b < 0xc0) 1z else if (b < 0xe0) 2z else if (b < 0xf0) 3z else 4z;
		i += width;
		if (i > len(data)) i = len(data);
	};
	append(out, len(data))!;
	return out;
};
