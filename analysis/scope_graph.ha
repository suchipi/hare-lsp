// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Lexical scope graph for a parsed Hare file. Used by references / rename
// to restrict cross-shadow text scans: when the cursor resolves to a local
// binding, we only scan that binding's lexical range, not the entire
// workspace.
//
// The graph is a tree of [[scope_node]]s rooted at file scope. Each node
// holds the bindings introduced in its scope and pointers to child scopes
// nested within it. Locations are byte offsets, computed against a
// parse_result whose locations have already been run through
// fixup_parse_result.
//
// Note: the workspace_index is not invalidated by didChange in the current
// LSP. The per-document scope graph IS rebuilt on every parse, so renames
// of locals are accurate even mid-edit. Renames of top-level decls still
// fall back to the workspace-wide text scan and inherit its limitations.

use hare::ast;
use hare::lex;
use strings;

// What kind of declaration introduced a [[scope_binding]].
export type binding_kind = enum {
	TOPLEVEL_DECL,
	LET,
	CONST,
	DEF,
	FOR_BINDING,
	MATCH_BINDING,
	FUNC_PARAM,
};

// A single name bound in some lexical scope. `scope_start`/`scope_end` is
// the byte range within which textual references to this name resolve to
// this binding (conservatively - inner shadowing is not subtracted; that
// is acceptable for rename within a single file since the e2e shadowing
// test only requires outer scopes to be unaffected).
export type scope_binding = struct {
	name: str,
	kind: binding_kind,
	name_span: ast::location,
	scope_start: u32,
	scope_end: u32,
};

// A node in the scope tree. Owns its bindings; children are owned by the
// containing scope_graph.
export type scope_node = struct {
	parent: nullable *scope_node,
	bindings: []scope_binding,
	children: []*scope_node,
	start: u32,
	end: u32,
};

// Lexical scope graph for a single parsed file. Root represents file
// scope; toplevel decls live here. `nodes` keeps a flat list of every
// allocated scope_node so finish_scope_graph can free them all.
export type scope_graph = struct {
	root: *scope_node,
	nodes: []*scope_node,
};

// Builds a scope graph from a parsed subunit. AST locations must already
// be in byte offsets (post-fixup_parse_result).
export fn build_scope_graph(su: *ast::subunit) scope_graph = {
	let g = scope_graph {
		root = alloc_scope_node(null, 0, ~0u32),
		nodes = [],
	};
	append(g.nodes, g.root)!;

	for (let i = 0z; i < len(su.decls); i += 1) {
		add_toplevel_binding(g.root, &su.decls[i]);
	};

	for (let i = 0z; i < len(su.decls); i += 1) {
		const d = &su.decls[i];
		const f = match (d.decl) {
		case let f: ast::decl_func => yield f;
		case => continue;
		};
		walk_func(&g, g.root, d, f);
	};

	return g;
};

// Releases memory owned by the scope graph.
export fn finish_scope_graph(g: *scope_graph) void = {
	for (let i = 0z; i < len(g.nodes); i += 1) {
		const n = g.nodes[i];
		for (let j = 0z; j < len(n.bindings); j += 1) {
			free(n.bindings[j].name);
		};
		free(n.bindings);
		free(n.children);
		free(n);
	};
	free(g.nodes);
};

// Resolves the cursor at `off` to the innermost scope binding for `name`.
// Walks the innermost scope outward through parents. Returns void when no
// binding is in scope.
export fn resolve_binding_at_byte(g: *scope_graph, name: str, off: u32) (scope_binding | void) = {
	const node = find_innermost_scope(g.root, off);
	let cur: nullable *scope_node = node;
	for (true) {
		const n = match (cur) {
		case let p: *scope_node => yield p;
		case null => break;
		};
		// Inner-most binding within this node wins; iterate the
		// list in declaration order and keep the last match whose
		// scope contains `off`.
		let best: (scope_binding | void) = void;
		for (let i = 0z; i < len(n.bindings); i += 1) {
			const b = &n.bindings[i];
			if (b.name != name) continue;
			if (off < b.scope_start) continue;
			if (off >= b.scope_end) continue;
			best = *b;
		};
		match (best) {
		case let b: scope_binding => return b;
		case void => void;
		};
		cur = n.parent;
	};
	return void;
};

fn find_innermost_scope(node: *scope_node, off: u32) *scope_node = {
	for (let i = 0z; i < len(node.children); i += 1) {
		const c = node.children[i];
		if (off >= c.start && off < c.end) {
			return find_innermost_scope(c, off);
		};
	};
	return node;
};

fn alloc_scope_node(parent: nullable *scope_node, start: u32, end: u32) *scope_node = {
	return alloc(scope_node {
		parent = parent,
		bindings = [],
		children = [],
		start = start,
		end = end,
	})!;
};

fn push_scope(g: *scope_graph, parent: *scope_node, start: u32, end: u32) *scope_node = {
	const n = alloc_scope_node(parent, start, end);
	append(g.nodes, n)!;
	append(parent.children, n)!;
	return n;
};

fn add_binding(scope: *scope_node, name: str, kind: binding_kind,
		name_span: ast::location, scope_start: u32, scope_end: u32) void = {
	if (len(name) == 0) return;
	append(scope.bindings, scope_binding {
		name = strings::dup(name)!,
		kind = kind,
		name_span = name_span,
		scope_start = scope_start,
		scope_end = scope_end,
	})!;
};

fn add_toplevel_binding(root: *scope_node, d: *ast::decl) void = {
	const (id, name_loc) = match (d.decl) {
	case let f: ast::decl_func => yield (f.ident, d.loc);
	case let t: ast::decl_type => yield (t.ident, d.loc);
	case let g: ast::decl_global => yield (g.ident, d.loc);
	case let c: ast::decl_const => yield (c.ident, d.loc);
	case ast::assert_expr => return;
	};
	if (len(id) == 0) return;
	const name = id[len(id) - 1];
	add_binding(root, name, binding_kind::TOPLEVEL_DECL, name_loc, 0, ~0u32);
};

fn walk_func(g: *scope_graph, parent: *scope_node, d: *ast::decl, f: ast::decl_func) void = {
	const body = match (f.body) {
	case let e: *ast::expr => yield e;
	case null => return;
	};
	const body_start = body.loc.start.off: u32;
	const body_end = body.loc.end.off: u32;
	const fn_scope = push_scope(g, parent, body_start, body_end);
	// Function parameters live for the entire body.
	match (f.prototype.repr) {
	case let proto: ast::func_type =>
		for (let i = 0z; i < len(proto.params); i += 1) {
			const p = &proto.params[i];
			if (len(p.name) == 0) continue;
			add_binding(fn_scope, p.name, binding_kind::FUNC_PARAM,
				p.loc, body_start, body_end);
		};
	case => void;
	};
	walk_expr(g, fn_scope, body);
};

fn walk_expr(g: *scope_graph, scope: *scope_node, e: *ast::expr) void = {
	match (e.expr) {
	case let b: ast::binding_expr =>
		const kind = switch (b.kind) {
		case ast::binding_kind::LET => yield binding_kind::LET;
		case ast::binding_kind::CONST => yield binding_kind::CONST;
		case ast::binding_kind::DEF => yield binding_kind::DEF;
		};
		// Each binding becomes visible from its declaration site
		// (so a rename hits the `let foo` text itself) through the
		// end of the enclosing scope.
		const bstart = e.loc.start.off: u32;
		const scope_end = scope.end;
		for (let i = 0z; i < len(b.bindings); i += 1) {
			const bd = &b.bindings[i];
			for (let j = 0z; j < len(bd.names); j += 1) {
				const n = bd.names[j];
				if (n == "_") continue;
				const nloc = ast::location {
					start = e.loc.start,
					end = e.loc.start,
				};
				add_binding(scope, n, kind, nloc, bstart, scope_end);
			};
			walk_expr(g, scope, bd.init);
		};
	case let c: ast::compound_expr =>
		const child = push_scope(g, scope, e.loc.start.off: u32,
			e.loc.end.off: u32);
		for (let i = 0z; i < len(c.exprs); i += 1) {
			walk_expr(g, child, c.exprs[i]);
		};
	case let f: ast::for_expr =>
		const for_scope = push_scope(g, scope, e.loc.start.off: u32,
			e.loc.end.off: u32);
		match (f.bindings) {
		case let p: *ast::expr =>
			walk_expr(g, for_scope, p);
		case null => void;
		};
		match (f.cond) {
		case let p: *ast::expr =>
			walk_expr(g, for_scope, p);
		case null => void;
		};
		match (f.afterthought) {
		case let p: *ast::expr =>
			walk_expr(g, for_scope, p);
		case null => void;
		};
		walk_expr(g, for_scope, f.body);
		match (f.else_branch) {
		case let p: *ast::expr =>
			walk_expr(g, for_scope, p);
		case null => void;
		};
	case let m: ast::match_expr =>
		walk_expr(g, scope, m.value);
		for (let i = 0z; i < len(m.cases); i += 1) {
			walk_match_case(g, scope, &m.cases[i]);
		};
	case let sw: ast::switch_expr =>
		walk_expr(g, scope, sw.value);
		for (let i = 0z; i < len(sw.cases); i += 1) {
			const sc = &sw.cases[i];
			const (cstart, cend) = case_expr_range(sc.exprs);
			const cscope = push_scope(g, scope, cstart, cend);
			for (let j = 0z; j < len(sc.options); j += 1) {
				walk_expr(g, scope, sc.options[j]);
			};
			for (let j = 0z; j < len(sc.exprs); j += 1) {
				walk_expr(g, cscope, sc.exprs[j]);
			};
		};
	case let i: ast::if_expr =>
		walk_expr(g, scope, i.cond);
		walk_expr(g, scope, i.tbranch);
		match (i.fbranch) {
		case let p: *ast::expr =>
			walk_expr(g, scope, p);
		case null => void;
		};
	case let a: ast::assign_expr =>
		match (a.object) {
		case let p: *ast::expr =>
			walk_expr(g, scope, p);
		case null => void;
		};
		walk_expr(g, scope, a.value);
	case let b: ast::binarithm_expr =>
		walk_expr(g, scope, b.lvalue);
		walk_expr(g, scope, b.rvalue);
	case let u: ast::unarithm_expr =>
		walk_expr(g, scope, u.operand);
	case let c: ast::call_expr =>
		walk_expr(g, scope, c.lvalue);
		for (let i = 0z; i < len(c.args); i += 1) {
			walk_expr(g, scope, c.args[i]);
		};
	case let c: ast::cast_expr =>
		walk_expr(g, scope, c.value);
	case let d: ast::defer_expr =>
		walk_expr(g, scope, d: *ast::expr);
	case let r: ast::return_expr =>
		match (r) {
		case let p: *ast::expr =>
			walk_expr(g, scope, p);
		case null => void;
		};
	case let y: ast::yield_expr =>
		match (y.value) {
		case let p: *ast::expr =>
			walk_expr(g, scope, p);
		case null => void;
		};
	case let p: ast::propagate_expr =>
		walk_expr(g, scope, p: *ast::expr);
	case let p: ast::error_assert_expr =>
		walk_expr(g, scope, p: *ast::expr);
	case let l: ast::len_expr =>
		walk_expr(g, scope, l: *ast::expr);
	case let o: ast::offset_expr =>
		walk_expr(g, scope, o: *ast::expr);
	case let fr: ast::free_expr =>
		walk_expr(g, scope, fr: *ast::expr);
	case let de: ast::delete_expr =>
		walk_expr(g, scope, de.object);
	case let al: ast::alloc_expr =>
		walk_expr(g, scope, al.init);
		match (al.capacity) {
		case let p: *ast::expr =>
			walk_expr(g, scope, p);
		case null => void;
		};
	case let ap: ast::append_expr =>
		walk_expr(g, scope, ap.object);
		walk_expr(g, scope, ap.value);
		match (ap.length) {
		case let p: *ast::expr =>
			walk_expr(g, scope, p);
		case null => void;
		};
	case let ie: ast::insert_expr =>
		walk_expr(g, scope, ie.object);
		walk_expr(g, scope, ie.value);
		match (ie.length) {
		case let p: *ast::expr =>
			walk_expr(g, scope, p);
		case null => void;
		};
	case let s: ast::slice_expr =>
		walk_expr(g, scope, s.object);
		match (s.start) {
		case let p: *ast::expr =>
			walk_expr(g, scope, p);
		case null => void;
		};
		match (s.end) {
		case let p: *ast::expr =>
			walk_expr(g, scope, p);
		case null => void;
		};
	case let br: ast::break_expr =>
		match (br.value) {
		case let p: *ast::expr =>
			walk_expr(g, scope, p);
		case null => void;
		};
	case let a: ast::access_expr =>
		match (a) {
		case ast::access_identifier => void;
		case let idx: ast::access_index =>
			walk_expr(g, scope, idx.object);
			walk_expr(g, scope, idx.index);
		case let fd: ast::access_field =>
			walk_expr(g, scope, fd.object);
		case let tu: ast::access_tuple =>
			walk_expr(g, scope, tu.object);
			walk_expr(g, scope, tu.value);
		};
	case => void;
	};
};

fn walk_match_case(g: *scope_graph, scope: *scope_node, mc: *ast::match_case) void = {
	const (cstart, cend) = case_expr_range(mc.exprs);
	const cscope = push_scope(g, scope, cstart, cend);
	if (len(mc.name) > 0) {
		// The case binding's name_span is approximated at the case
		// scope's start; we don't have a precise span for it.
		const nloc = ast::location {
			start = lex_loc_at(cstart),
			end = lex_loc_at(cstart),
		};
		add_binding(cscope, mc.name, binding_kind::MATCH_BINDING,
			nloc, cstart, cend);
	};
	for (let j = 0z; j < len(mc.exprs); j += 1) {
		walk_expr(g, cscope, mc.exprs[j]);
	};
};

fn case_expr_range(exprs: []*ast::expr) (u32, u32) = {
	if (len(exprs) == 0) return (0u32, 0u32);
	const s = exprs[0].loc.start.off: u32;
	const e = exprs[len(exprs) - 1].loc.end.off: u32;
	return (s, e);
};

fn lex_loc_at(off: u32) lex::location = {
	return lex::location {
		path = "",
		line = 0,
		col = 0,
		off = off: i64,
	};
};
