// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Hover and go-to-definition support for struct/union member accesses.
//
// When the cursor is on an identifier preceded by `.`, we treat it as a
// member access of the form `<receiver>.<name>`:
//   1. Walk the AST to find the [[ast::access_field]] node whose end offset
//      lines up with the cursor's identifier end.
//   2. Resolve the receiver expression to a type AST node (handling local
//      bindings, function parameters, call expressions, nested field
//      accesses, and `?`/`!` unwrapping).
//   3. Chase alias and pointer wrappers down to a struct or union type.
//   4. Look up the named member and return its type, doc comment, and the
//      byte range of its field name in the owning file's source.
//
// The owning file may be the open document or another workspace file
// (reached via the shared file parse cache). Both cases return borrowed
// pointers that the caller uses for the duration of the LSP response.

use analysis;
use encoding::json;
use hare::ast;
use hare::unparse;
use lsp;
use memio;
use strings;

// Recursion cap when chasing alias / pointer / unwrap chains. Realistic
// chains are 1-3 levels; the cap exists to avoid pathological cycles.
def MEMBER_RESOLVE_MAX_DEPTH: int = 16;

// A successful struct-member lookup.
type struct_member_match = struct {
	// The member's type AST node, for hover rendering.
	field_type: *ast::_type,
	// The member's doc comment (the leading `// ...` lines on the line
	// before the field declaration), or "" if absent. Borrowed.
	docs: str,
	// File context that owns `field_type` and is the home of the struct
	// definition. Used to compute the LSP Location for go-to-definition.
	owner_text: []u8,
	owner_uri: str,
	// Byte range of the field name within `owner_text`.
	name_start: size,
	name_end: size,
};

// Cursor-on-member-access detection. Returns true if `ident_start` is
// preceded directly by a single `.` (not `..`, not `::`, no intervening
// whitespace). The canonical Hare style has no space around the dot.
fn is_member_access_at(data: []u8, ident_start: size) bool = {
	if (ident_start == 0) return false;
	if (data[ident_start - 1] != '.': u8) return false;
	// `..` is the slice / variadic operator, not a member access.
	if (ident_start >= 2 && data[ident_start - 2] == '.': u8) return false;
	return true;
};

// Top-level entry point: if `off` is on a struct-member ident, resolves
// the member and returns a [[struct_member_match]]. Returns void otherwise.
fn resolve_struct_member_at(
	s: *server,
	doc: *document,
	data: []u8,
	off: size,
) (struct_member_match | void) = {
	const ident_range = match (analysis::ident_at(data, off)) {
	case let r: (size, size) =>
		yield r;
	case void =>
		return void;
	};
	if (!is_member_access_at(data, ident_range.0)) return void;
	const name = strings::fromutf8(data[ident_range.0..ident_range.1])!;
	const cache = parse_of(doc);
	// hare::lex / hare::parse report `loc.end.off` as the START offset
	// of the last consumed token (see [[hare::lex::prevloc]]). For an
	// access_field `recv.field`, that's the start of `field`. We pass
	// the field name's start offset and match against `loc.end.off`.
	const af = match (find_access_field_in_subunit(&cache.pr.subunit,
		ident_range.0, name)) {
	case let af: ast::access_field =>
		yield af;
	case void =>
		return void;
	};
	const recv_type = match (type_of_expr(s,
		doc, &cache.pr.subunit, af.object, 0)) {
	case let lt: located_type =>
		yield lt;
	case void =>
		return void;
	};
	return lookup_member_in_type(s, recv_type, name, 0);
};

// --- AST walker: finds an access_field whose name ends at `field_start`. ---
fn find_access_field_in_subunit(
	su: *ast::subunit,
	field_start: size,
	name: str,
) (ast::access_field | void) = {
	for (let i = 0z; i < len(su.decls); i += 1) {
		const d = &su.decls[i];
		if (field_start < d.loc.start.off: size) continue;
		if (field_start > d.loc.end.off: size) continue;
		match (scan_decl_for_field(d, field_start, name)) {
		case let af: ast::access_field =>
			return af;
		case void => void;
		};
	};
	return void;
};

fn scan_decl_for_field(
	d: *ast::decl,
	field_start: size,
	name: str,
) (ast::access_field | void) = {
	match (d.decl) {
	case let f: ast::decl_func =>
		match (f.body) {
		case let e: *ast::expr =>
			return scan_expr_for_field(e, field_start, name);
		case null =>
			return void;
		};
	case let g: ast::decl_global =>
		match (g.init) {
		case let e: *ast::expr =>
			return scan_expr_for_field(e, field_start, name);
		case null =>
			return void;
		};
	case let c: ast::decl_const =>
		return scan_expr_for_field(c.init, field_start, name);
	case =>
		return void;
	};
};

// Walks `e` and returns the access_field whose loc.end.off lands on
// `field_start` (the start of the field-name token) and whose field
// text matches `name`. We use that equality because hare::lex tracks
// `loc.end` as the START offset of the last consumed rune (see
// [[hare::lex::prevloc]]), so for an access_field `recv.field` the
// reported `loc.end.off` is the start of `field`.
fn scan_expr_for_field(
	e: *ast::expr,
	field_start: size,
	name: str,
) (ast::access_field | void) = {
	if (field_start < e.loc.start.off: size) return void;
	if (field_start > e.loc.end.off: size) return void;
	match (e.expr) {
	case let a: ast::access_expr =>
		match (a) {
		case ast::access_identifier =>
			return void;
		case let idx: ast::access_index =>
			match (scan_expr_for_field(idx.object, field_start, name)) {
			case let af: ast::access_field =>
				return af;
			case void => void;
			};
			return scan_expr_for_field(idx.index, field_start, name);
		case let fd: ast::access_field =>
			match (scan_expr_for_field(fd.object, field_start, name)) {
			case let af: ast::access_field =>
				return af;
			case void => void;
			};
			if (e.loc.end.off: size == field_start && fd.field == name) {
				return fd;
			};
			return void;
		case let tu: ast::access_tuple =>
			match (scan_expr_for_field(tu.object, field_start, name)) {
			case let af: ast::access_field =>
				return af;
			case void => void;
			};
			return scan_expr_for_field(tu.value, field_start, name);
		};
	case let c: ast::call_expr =>
		match (scan_expr_for_field(c.lvalue, field_start, name)) {
		case let af: ast::access_field =>
			return af;
		case void => void;
		};
		for (let i = 0z; i < len(c.args); i += 1) {
			match (scan_expr_for_field(c.args[i], field_start, name)) {
			case let af: ast::access_field =>
				return af;
			case void => void;
			};
		};
		return void;
	case let b: ast::binding_expr =>
		for (let i = 0z; i < len(b.bindings); i += 1) {
			match (scan_expr_for_field(b.bindings[i].init, field_start, name)) {
			case let af: ast::access_field =>
				return af;
			case void => void;
			};
		};
		return void;
	case let cmp: ast::compound_expr =>
		for (let i = 0z; i < len(cmp.exprs); i += 1) {
			match (scan_expr_for_field(cmp.exprs[i], field_start, name)) {
			case let af: ast::access_field =>
				return af;
			case void => void;
			};
		};
		return void;
	case let i: ast::if_expr =>
		match (scan_expr_for_field(i.cond, field_start, name)) {
		case let af: ast::access_field =>
			return af;
		case void => void;
		};
		match (scan_expr_for_field(i.tbranch, field_start, name)) {
		case let af: ast::access_field =>
			return af;
		case void => void;
		};
		match (i.fbranch) {
		case let e2: *ast::expr =>
			return scan_expr_for_field(e2, field_start, name);
		case null =>
			return void;
		};
	case let fr: ast::for_expr =>
		match (fr.bindings) {
		case let p: *ast::expr =>
			match (scan_expr_for_field(p, field_start, name)) {
			case let af: ast::access_field =>
				return af;
			case void => void;
			};
		case null => void;
		};
		match (fr.cond) {
		case let p: *ast::expr =>
			match (scan_expr_for_field(p, field_start, name)) {
			case let af: ast::access_field =>
				return af;
			case void => void;
			};
		case null => void;
		};
		match (fr.afterthought) {
		case let p: *ast::expr =>
			match (scan_expr_for_field(p, field_start, name)) {
			case let af: ast::access_field =>
				return af;
			case void => void;
			};
		case null => void;
		};
		return scan_expr_for_field(fr.body, field_start, name);
	case let m: ast::match_expr =>
		match (scan_expr_for_field(m.value, field_start, name)) {
		case let af: ast::access_field =>
			return af;
		case void => void;
		};
		for (let i = 0z; i < len(m.cases); i += 1) {
			const mc = &m.cases[i];
			for (let j = 0z; j < len(mc.exprs); j += 1) {
				match (scan_expr_for_field(mc.exprs[j], field_start, name)) {
				case let af: ast::access_field =>
					return af;
				case void => void;
				};
			};
		};
		return void;
	case let sw: ast::switch_expr =>
		match (scan_expr_for_field(sw.value, field_start, name)) {
		case let af: ast::access_field =>
			return af;
		case void => void;
		};
		for (let i = 0z; i < len(sw.cases); i += 1) {
			const sc = &sw.cases[i];
			for (let j = 0z; j < len(sc.exprs); j += 1) {
				match (scan_expr_for_field(sc.exprs[j], field_start, name)) {
				case let af: ast::access_field =>
					return af;
				case void => void;
				};
			};
		};
		return void;
	case let bn: ast::binarithm_expr =>
		match (scan_expr_for_field(bn.lvalue, field_start, name)) {
		case let af: ast::access_field =>
			return af;
		case void => void;
		};
		return scan_expr_for_field(bn.rvalue, field_start, name);
	case let u: ast::unarithm_expr =>
		return scan_expr_for_field(u.operand, field_start, name);
	case let ag: ast::assign_expr =>
		match (ag.object) {
		case let p: *ast::expr =>
			match (scan_expr_for_field(p, field_start, name)) {
			case let af: ast::access_field =>
				return af;
			case void => void;
			};
		case null => void;
		};
		return scan_expr_for_field(ag.value, field_start, name);
	case let ca: ast::cast_expr =>
		return scan_expr_for_field(ca.value, field_start, name);
	case let d: ast::defer_expr =>
		return scan_expr_for_field(d: *ast::expr, field_start, name);
	case let p: ast::propagate_expr =>
		return scan_expr_for_field(p: *ast::expr, field_start, name);
	case let p: ast::error_assert_expr =>
		return scan_expr_for_field(p: *ast::expr, field_start, name);
	case let r: ast::return_expr =>
		match (r) {
		case let p: *ast::expr =>
			return scan_expr_for_field(p, field_start, name);
		case null =>
			return void;
		};
	case let y: ast::yield_expr =>
		match (y.value) {
		case let p: *ast::expr =>
			return scan_expr_for_field(p, field_start, name);
		case null =>
			return void;
		};
	case =>
		return void;
	};
};

// --- Receiver type resolution. ---
// A type AST node together with the file context that owns it. The
// `text`/`uri` fields point to the file containing the AST so callers
// can compute LSP positions in the right file.
type located_type = struct {
	t: *ast::_type,
	text: []u8,
	uri: str,
};

// Returns the type of the given expression as a located_type, or void if
// we don't know. `su` is the subunit of the open document (used to look
// up local bindings).
fn type_of_expr(
	s: *server,
	doc: *document,
	su: *ast::subunit,
	e: *ast::expr,
	depth: int,
) (located_type | void) = {
	if (depth >= MEMBER_RESOLVE_MAX_DEPTH) return void;
	match (e.expr) {
	case let a: ast::access_expr =>
		match (a) {
		case let id: ast::access_identifier =>
			return type_of_identifier(s, doc, su, id, e.loc.start.off: size, depth);
		case let fd: ast::access_field =>
			const recv = match (type_of_expr(s, doc, su, fd.object, depth + 1)) {
			case let lt: located_type =>
				yield lt;
			case void =>
				return void;
			};
			return member_type_in_type(s, recv, fd.field, depth + 1);
		case =>
			return void;
		};
	case let c: ast::call_expr =>
		return call_return_located_type(s, doc, su, &c, depth);
	case let ca: ast::cast_expr =>
		return located_type {
			t = ca._type,
			text = analysis::bytes(&doc.buf),
			uri = doc.uri,
		};
	case let p: ast::propagate_expr =>
		return strip_errors_located(s, doc, su, p: *ast::expr, depth);
	case let p: ast::error_assert_expr =>
		return strip_errors_located(s, doc, su, p: *ast::expr, depth);
	case =>
		return void;
	};
};

// Looks up the type of `id` at byte position `off` within the open doc's
// subunit. Tries locals (function params and let/const bindings) first,
// then top-level decls (local + workspace + stdlib).
fn type_of_identifier(
	s: *server,
	doc: *document,
	su: *ast::subunit,
	id: ast::ident,
	off: size,
	depth: int,
) (located_type | void) = {
	if (len(id) == 0) return void;
	if (len(id) == 1) {
		match (find_local_binding_type(s, doc, su, id[0], off, depth)) {
		case let lt: located_type =>
			return lt;
		case void => void;
		};
	};
	const d = match (lookup_decl_by_ident(s, doc, id)) {
	case let d: *ast::decl =>
		yield d;
	case void =>
		return void;
	};
	return type_of_decl(s, doc, d);
};

fn type_of_decl(
	s: *server,
	doc: *document,
	d: *ast::decl,
) (located_type | void) = {
	// Try the open doc first (cheap); otherwise scan the file_parse_cache
	// for the entry that owns this decl pointer.
	const (text, uri) = locate_decl(s, doc, d);
	match (d.decl) {
	case let g: ast::decl_global =>
		match (g._type) {
		case let t: *ast::_type =>
			return located_type { t = t, text = text, uri = uri };
		case null =>
			return void;
		};
	case let c: ast::decl_const =>
		match (c._type) {
		case let t: *ast::_type =>
			return located_type { t = t, text = text, uri = uri };
		case null =>
			return void;
		};
	case let t: ast::decl_type =>
		return located_type { t = t._type, text = text, uri = uri };
	case =>
		return void;
	};
};

// Returns the (text, uri) pair whose parse owns `d`. Defaults to the open
// document if we can't locate it; that's safe because we only use the
// text/uri for position computation, and a mismatch can only cause a
// degraded (not incorrect) jump target.
fn locate_decl(s: *server, doc: *document, d: *ast::decl) ([]u8, str) = {
	const cache = parse_of(doc);
	for (let i = 0z; i < len(cache.pr.subunit.decls); i += 1) {
		if (&cache.pr.subunit.decls[i] == d) {
			return (analysis::bytes(&doc.buf), doc.uri);
		};
	};
	for (let i = 0z; i < len(s.file_parse_cache.entries); i += 1) {
		const fpe = &s.file_parse_cache.entries[i];
		for (let j = 0z; j < len(fpe.pr.subunit.decls); j += 1) {
			if (&fpe.pr.subunit.decls[j] == d) {
				return (fpe.text, fpe_uri(s, fpe.path));
			};
		};
	};
	return (analysis::bytes(&doc.buf), doc.uri);
};

// Resolves a local binding (function parameter, let, const, def) at
// `off` within the function containing it; returns its declared or
// inferred type as a located_type. Only handles single-segment idents.
fn find_local_binding_type(
	s: *server,
	doc: *document,
	su: *ast::subunit,
	name: str,
	off: size,
	depth: int,
) (located_type | void) = {
	for (let i = 0z; i < len(su.decls); i += 1) {
		const d = &su.decls[i];
		if (off < d.loc.start.off: size) continue;
		if (off > d.loc.end.off: size) continue;
		const f = match (d.decl) {
		case let f: ast::decl_func =>
			yield f;
		case =>
			continue;
		};
		match (f.prototype.repr) {
		case let proto: ast::func_type =>
			for (let j = 0z; j < len(proto.params); j += 1) {
				if (proto.params[j].name != name) continue;
				return located_type {
					t = proto.params[j]._type,
					text = analysis::bytes(&doc.buf),
					uri = doc.uri,
				};
			};
		case => void;
		};
		const body = match (f.body) {
		case let e: *ast::expr =>
			yield e;
		case null =>
			return void;
		};
		return walk_for_binding_type(s, doc, su, body, name, off, depth);
	};
	return void;
};

fn walk_for_binding_type(
	s: *server,
	doc: *document,
	su: *ast::subunit,
	e: *ast::expr,
	name: str,
	off: size,
	depth: int,
) (located_type | void) = {
	match (e.expr) {
	case let b: ast::binding_expr =>
		for (let i = 0z; i < len(b.bindings); i += 1) {
			const bd = &b.bindings[i];
			for (let j = 0z; j < len(bd.names); j += 1) {
				if (bd.names[j] != name) continue;
				return binding_type(s, doc, su, bd, depth);
			};
		};
		return walk_for_binding_type(s,
			doc, su, b.bindings[0].init, name, off, depth);
	case let c: ast::compound_expr =>
		let hit: (located_type | void) = void;
		for (let i = 0z; i < len(c.exprs); i += 1) {
			const child = c.exprs[i];
			if (child.loc.start.off: size > off) break;
			match (walk_for_binding_type(s, doc, su, child, name, off, depth)) {
			case let lt: located_type =>
				hit = lt;
			case void => void;
			};
		};
		return hit;
	case let i: ast::if_expr =>
		match (walk_for_binding_type(s, doc, su, i.tbranch, name, off, depth)) {
		case let lt: located_type =>
			return lt;
		case void => void;
		};
		match (i.fbranch) {
		case let e2: *ast::expr =>
			return walk_for_binding_type(s, doc, su, e2, name, off, depth);
		case null =>
			return void;
		};
	case let fr: ast::for_expr =>
		match (fr.bindings) {
		case let bb: *ast::expr =>
			match (walk_for_binding_type(s, doc, su, bb, name, off, depth)) {
			case let lt: located_type =>
				return lt;
			case void => void;
			};
		case null => void;
		};
		return walk_for_binding_type(s, doc, su, fr.body, name, off, depth);
	case let m: ast::match_expr =>
		for (let i = 0z; i < len(m.cases); i += 1) {
			const mc = &m.cases[i];
			if (!mc_contains(mc.exprs, off)) continue;
			if (mc.name == name) {
				match (mc._type) {
				case let t: *ast::_type =>
					return located_type {
						t = t,
						text = analysis::bytes(&doc.buf),
						uri = doc.uri,
					};
				case null =>
					return void;
				};
			};
			for (let j = 0z; j < len(mc.exprs); j += 1) {
				match (walk_for_binding_type(s, doc, su, mc.exprs[j], name, off, depth)) {
				case let lt: located_type =>
					return lt;
				case void => void;
				};
			};
		};
		return walk_for_binding_type(s, doc, su, m.value, name, off, depth);
	case let d: ast::defer_expr =>
		return walk_for_binding_type(s, doc, su, d: *ast::expr, name, off, depth);
	case =>
		return void;
	};
};

fn mc_contains(exprs: []*ast::expr, off: size) bool = {
	for (let i = 0z; i < len(exprs); i += 1) {
		const e = exprs[i];
		if (off >= e.loc.start.off: size && off <= e.loc.end.off: size) {
			return true;
		};
	};
	return false;
};

// Returns the declared type of `bd`, or the inferred type of its init if
// no type was written.
fn binding_type(
	s: *server,
	doc: *document,
	su: *ast::subunit,
	bd: *ast::binding,
	depth: int,
) (located_type | void) = {
	match (bd._type) {
	case let t: *ast::_type =>
		return located_type {
			t = t,
			text = analysis::bytes(&doc.buf),
			uri = doc.uri,
		};
	case null =>
		return type_of_expr(s, doc, su, bd.init, depth + 1);
	};
};

// Returns the return type of a call expression with a directly-named
// callee, as a located_type whose owner is the file declaring the
// callee. Returns void if the callee isn't a simple identifier or can't
// be resolved.
fn call_return_located_type(
	s: *server,
	doc: *document,
	su: *ast::subunit,
	c: *ast::call_expr,
	depth: int,
) (located_type | void) = {
	const callee_ident = match (c.lvalue.expr) {
	case let a: ast::access_expr =>
		yield match (a) {
		case let id: ast::access_identifier =>
			yield id;
		case =>
			return void;
		};
	case =>
		return void;
	};
	const d = match (lookup_decl_by_ident(s, doc, callee_ident)) {
	case let d: *ast::decl =>
		yield d;
	case void =>
		return void;
	};
	const f = match (d.decl) {
	case let f: ast::decl_func =>
		yield f;
	case =>
		return void;
	};
	const ft = match (f.prototype.repr) {
	case let proto: ast::func_type =>
		yield proto;
	case =>
		return void;
	};
	const (text, uri) = locate_decl(s, doc, d);
	return located_type { t = ft.result, text = text, uri = uri };
};

// Strips `?`/`!` from `inner`'s type — returns the non-error component.
fn strip_errors_located(
	s: *server,
	doc: *document,
	su: *ast::subunit,
	inner: *ast::expr,
	depth: int,
) (located_type | void) = {
	const inner_lt = match (type_of_expr(s, doc, su, inner, depth + 1)) {
	case let lt: located_type =>
		yield lt;
	case void =>
		return void;
	};
	match (inner_lt.t.repr) {
	case let tag: ast::tagged_type =>
		// Find the single non-error variant. If multiple non-error
		// variants remain we can't safely simplify down to one type;
		// give up and return the original tagged type.
		let kept: *ast::_type = inner_lt.t;
		let kept_count = 0;
		for (let i = 0z; i < len(tag); i += 1) {
			if (alias_is_error(s, doc, tag[i].0, 0)) continue;
			kept = tag[i].0;
			kept_count += 1;
		};
		if (kept_count == 1) {
			return located_type {
				t = kept,
				text = inner_lt.text,
				uri = inner_lt.uri,
			};
		};
		return inner_lt;
	case =>
		return inner_lt;
	};
};

fn alias_is_error(
	s: *server,
	doc: *document,
	t: *ast::_type,
	depth: int,
) bool = {
	if (depth >= MEMBER_RESOLVE_MAX_DEPTH) return false;
	match (t.repr) {
	case ast::error_type =>
		return true;
	case let a: ast::alias_type =>
		const d = match (lookup_decl_by_ident(s, doc, a)) {
		case let d: *ast::decl =>
			yield d;
		case void =>
			return false;
		};
		const u = match (analysis::type_decl_underlying(d)) {
		case let u: *ast::_type =>
			yield u;
		case void =>
			return false;
		};
		return alias_is_error(s, doc, u, depth + 1);
	case =>
		return false;
	};
};

// --- Member lookup in a resolved type. ---
// Returns the member type within `holder` for the field named `name`, as
// a located_type whose owner is the file containing the struct. Chases
// alias and pointer wrappers down to a struct or union.
fn member_type_in_type(
	s: *server,
	holder: located_type,
	name: str,
	depth: int,
) (located_type | void) = {
	const m = match (lookup_member_in_type(s, holder, name, depth)) {
	case let m: struct_member_match =>
		yield m;
	case void =>
		return void;
	};
	return located_type {
		t = m.field_type,
		text = m.owner_text,
		uri = m.owner_uri,
	};
};

// Full member lookup including doc comment and source range of the
// field name. Returns void if `holder` isn't a struct or union (after
// chasing aliases/pointers) or `name` isn't a member.
fn lookup_member_in_type(
	s: *server,
	holder: located_type,
	name: str,
	depth: int,
) (struct_member_match | void) = {
	if (depth >= MEMBER_RESOLVE_MAX_DEPTH) return void;
	match (holder.t.repr) {
	case let st: ast::struct_type =>
		return lookup_in_members(holder, st.members, name);
	case let ut: ast::union_type =>
		return lookup_in_members(holder, ut: []ast::struct_member, name);
	case let p: ast::pointer_type =>
		return lookup_member_in_type(s,
			located_type {
				t = p.referent,
				text = holder.text,
				uri = holder.uri,
			}, name, depth + 1);
	case let a: ast::alias_type =>
		const id_lookup_doc = find_doc_for_uri(s, holder.uri);
		const lookup_doc = match (id_lookup_doc) {
		case let d: *document =>
			yield d;
		case null =>
			// Fall through: try without a doc context. We still
			// can't look up via the open-doc index but
			// lookup_decl_by_ident handles workspace fallback.
			yield null: nullable *document;
		};
		const d = match (resolve_alias_decl(s, lookup_doc, a)) {
		case let d: *ast::decl =>
			yield d;
		case void =>
			return void;
		};
		const u = match (analysis::type_decl_underlying(d)) {
		case let u: *ast::_type =>
			yield u;
		case void =>
			return void;
		};
		const (text, uri) = locate_decl_anywhere(s, d, holder);
		return lookup_member_in_type(s,
			located_type {
				t = u,
				text = text,
				uri = uri,
			}, name, depth + 1);
	case =>
		return void;
	};
};

// Resolves an alias ident to its decl. Tries the open document (if
// provided) first, then the workspace and stdlib indexes.
fn resolve_alias_decl(
	s: *server,
	doc: nullable *document,
	id: ast::ident,
) (*ast::decl | void) = {
	match (doc) {
	case let d: *document =>
		return lookup_decl_by_ident(s, d, id);
	case null => void;
	};
	// No open-doc context: only the workspace + stdlib paths are usable.
	if (len(id) == 0) return void;
	const name = id[len(id) - 1];
	if (len(id) >= 2) {
		const qualifier = id[len(id) - 2];
		match (analysis::find_in_module(&s.workspace_index, qualifier, name)) {
		case let e: *analysis::workspace_entry =>
			return decl_from_workspace_entry(s, e, name);
		case void => void;
		};
		if (ensure_stdlib_module_indexed(s, qualifier)) {
			match (analysis::find_in_module(&s.stdlib_index, qualifier, name)) {
			case let e: *analysis::workspace_entry =>
				return decl_from_workspace_entry(s, e, name);
			case void =>
				return void;
			};
		};
		return void;
	};
	match (analysis::find_first_by_short_name(&s.workspace_index, name)) {
	case let e: *analysis::workspace_entry =>
		return decl_from_workspace_entry(s, e, name);
	case void =>
		return void;
	};
};

// Returns the open document whose uri matches, if any. Used to provide
// an alias resolution context that prefers the file where the type was
// declared.
fn find_doc_for_uri(s: *server, uri: str) nullable *document = {
	for (let i = 0z; i < len(s.documents); i += 1) {
		if (s.documents[i].uri == uri) return &s.documents[i];
	};
	return null;
};

// Like [[locate_decl]] but takes a fallback holder for when we can't
// find the decl in either the open doc or the file parse cache.
fn locate_decl_anywhere(
	s: *server,
	d: *ast::decl,
	fallback: located_type,
) ([]u8, str) = {
	for (let i = 0z; i < len(s.documents); i += 1) {
		const doc = &s.documents[i];
		const cache = parse_of(doc);
		for (let j = 0z; j < len(cache.pr.subunit.decls); j += 1) {
			if (&cache.pr.subunit.decls[j] == d) {
				return (analysis::bytes(&doc.buf), doc.uri);
			};
		};
	};
	for (let i = 0z; i < len(s.file_parse_cache.entries); i += 1) {
		const fpe = &s.file_parse_cache.entries[i];
		for (let j = 0z; j < len(fpe.pr.subunit.decls); j += 1) {
			if (&fpe.pr.subunit.decls[j] == d) {
				return (fpe.text, fpe_uri(s, fpe.path));
			};
		};
	};
	return (fallback.text, fallback.uri);
};

// Resolves a file path to its workspace_entry.uri (so we return owned
// strings the index holds). Falls back to `file://<path>`-style by way
// of a workspace_entry scan; if no match, returns the path itself.
fn fpe_uri(s: *server, path: str) str = {
	for (let i = 0z; i < len(s.workspace_index.entries); i += 1) {
		if (s.workspace_index.entries[i].path == path) {
			return s.workspace_index.entries[i].uri;
		};
	};
	for (let i = 0z; i < len(s.stdlib_index.entries); i += 1) {
		if (s.stdlib_index.entries[i].path == path) {
			return s.stdlib_index.entries[i].uri;
		};
	};
	return path;
};

fn lookup_in_members(
	holder: located_type,
	members: []ast::struct_member,
	name: str,
) (struct_member_match | void) = {
	for (let i = 0z; i < len(members); i += 1) {
		const m = &members[i];
		const f = match (m.member) {
		case let f: ast::struct_field =>
			yield f;
		case =>
			continue;
		};
		if (f.name != name) continue;
		const (ns, ne) = field_name_range(holder.text, f);
		return struct_member_match {
			field_type = f._type,
			docs = m.docs,
			owner_text = holder.text,
			owner_uri = holder.uri,
			name_start = ns,
			name_end = ne,
		};
	};
	return void;
};

// Scans backward from a struct_field's type location to recover the
// byte range of the field name. The parser doesn't record name spans on
// struct_field directly, but the type's loc.start.off is right after
// the `:` separator, so we can find the name by walking back over
// whitespace + `:` + whitespace + identifier bytes.
fn field_name_range(data: []u8, f: ast::struct_field) (size, size) = {
	let i = f._type.loc.start.off: size;
	// Walk back over whitespace before the type.
	for (i > 0; i -= 1) {
		const b = data[i - 1];
		if (!is_sm_ws(b)) break;
	};
	// Expect a `:`; if not, give up and point at the type's start.
	if (i == 0 || data[i - 1] != ':': u8) {
		const fallback = f._type.loc.start.off: size;
		return (fallback, fallback);
	};
	i -= 1;
	// Walk back over whitespace before the colon.
	for (i > 0; i -= 1) {
		const b = data[i - 1];
		if (!is_sm_ws(b)) break;
	};
	const name_end = i;
	for (i > 0; i -= 1) {
		const b = data[i - 1];
		if (!analysis::is_ident_byte(b)) break;
	};
	return (i, name_end);
};

fn is_sm_ws(b: u8) bool = {
	return b == ' ': u8 || b == '\t': u8 || b == '\n': u8 || b == '\r': u8;
};

// --- Response builders. ---
// Tries to send a hover response for a struct-member ident. Returns
// true if it handled the request (sent a response); false otherwise.
export fn try_send_struct_member_hover(
	s: *server,
	r: lsp::request,
	doc: *document,
	data: []u8,
	off: size,
) bool = {
	const m = match (resolve_struct_member_at(s, doc, data, off)) {
	case let m: struct_member_match =>
		yield m;
	case void =>
		return false;
	};
	const name = strings::fromutf8(m.owner_text[m.name_start..m.name_end])!;
	const sig = render_field_signature(name, m.field_type);
	defer free(sig);
	const md = build_hover_markdown(s, doc, sig, m.docs);
	defer free(md);

	const ident_range = match (analysis::ident_at(data, off)) {
	case let r: (size, size) =>
		yield r;
	case void =>
		return false;
	};
	const enc = position_encoding(s);
	const start_pos = analysis::byte_to_position(data,
		doc.buf.line_index, enc, ident_range.0);
	const end_pos = analysis::byte_to_position(data,
		doc.buf.line_index, enc, ident_range.1);

	let result = json::newobject();
	let contents = json::newobject();
	json::set(&contents, "kind", "markdown": json::value)!;
	json::set(&contents, "value", md: json::value)!;
	json::put(&result, "contents", contents)!;
	let range = json::newobject();
	let s_obj = json::newobject();
	json::put(&s_obj, "line", start_pos.line: f64)!;
	json::put(&s_obj, "character", start_pos.character: f64)!;
	let e_obj = json::newobject();
	json::put(&e_obj, "line", end_pos.line: f64)!;
	json::put(&e_obj, "character", end_pos.character: f64)!;
	json::put(&range, "start", s_obj)!;
	json::put(&range, "end", e_obj)!;
	json::put(&result, "range", range)!;
	const v: json::value = result;
	defer json::finish(v);
	match (lsp::encode_response_result(s.out, r.id, v)) {
	case size => void;
	case => void;
	};
	return true;
};

// Tries to send a definition / declaration / implementation response
// for a struct-member ident. Returns true if it handled the request.
export fn try_send_struct_member_definition(
	s: *server,
	r: lsp::request,
	doc: *document,
	data: []u8,
	off: size,
) bool = {
	const m = match (resolve_struct_member_at(s, doc, data, off)) {
	case let m: struct_member_match =>
		yield m;
	case void =>
		return false;
	};
	const line_index = analysis::build_line_index(m.owner_text);
	defer free(line_index);
	const enc = position_encoding(s);
	const start_pos = analysis::byte_to_position(m.owner_text,
		line_index, enc, m.name_start);
	const end_pos = analysis::byte_to_position(m.owner_text,
		line_index, enc, m.name_end);

	let result = json::newobject();
	json::set(&result, "uri", m.owner_uri: json::value)!;
	let range = json::newobject();
	let s_obj = json::newobject();
	json::put(&s_obj, "line", start_pos.line: f64)!;
	json::put(&s_obj, "character", start_pos.character: f64)!;
	let e_obj = json::newobject();
	json::put(&e_obj, "line", end_pos.line: f64)!;
	json::put(&e_obj, "character", end_pos.character: f64)!;
	json::put(&range, "start", s_obj)!;
	json::put(&range, "end", e_obj)!;
	json::put(&result, "range", range)!;
	const v: json::value = result;
	defer json::finish(v);
	match (lsp::encode_response_result(s.out, r.id, v)) {
	case size => void;
	case => void;
	};
	return true;
};

// Renders a struct field's signature line for hover. Format mirrors
// what we already show for top-level decls:
//   (field) name: type
fn render_field_signature(name: str, t: *ast::_type) str = {
	let buf = memio::dynamic();
	defer lsp::safe_close(&buf);
	match (memio::concat(&buf, "(field) ", name, ": ")) {
	case size => void;
	case =>
		return strings::dup("(field)")!;
	};
	match (unparse::_type(&buf, &unparse::syn_nowrap, t)) {
	case size => void;
	case =>
		return strings::dup("(field)")!;
	};
	return strings::dup(memio::string(&buf)!)!;
};
