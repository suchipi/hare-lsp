// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use strings;

// Tests for the lexical scope graph used by references/rename to
// bound text scans when the cursor resolves to a local binding.
// These exercise scope_graph in isolation; references/rename e2e
// coverage doesn't always surface scope-graph bugs.
//
// `byte_index` is shared with loc_fixup_test+test.ha — it returns
// the byte offset of a needle within a string (vs strings::index,
// which returns a rune index).
@test fn scope_graph_resolves_local_let_binding() void = {
	// `let answer` is bound inside `main`'s body. Looking up
	// `answer` at a byte inside that body returns the local
	// binding, not a void.
	const src_str =
		"fn main() void = { let answer: int = 42; let _ = answer; };\n";
	const src = strings::toutf8(src_str);
	let r = parse_recover(src, "test.ha");
	defer finish_parse_result(&r);
	let g = build_scope_graph(&r.subunit);
	defer finish_scope_graph(&g);
	const use_off = byte_index(src_str, "answer;"): u32;
	const b = resolve_binding_at_byte(&g, "answer", use_off);
	match (b) {
	case let bind: scope_binding =>
		assert(bind.kind == binding_kind::LET);
	case void => abort("expected LET binding for `answer`");
	};
};

@test fn scope_graph_local_not_visible_outside_function() void = {
	// `answer` is a local to `main`. Looking it up from inside
	// `helper`'s body must NOT resolve to `main`'s binding.
	const src_str =
		"fn main() void = { let answer: int = 42; };\nfn helper() int = answer;\n";
	const src = strings::toutf8(src_str);
	let r = parse_recover(src, "test.ha");
	defer finish_parse_result(&r);
	let g = build_scope_graph(&r.subunit);
	defer finish_scope_graph(&g);
	const helper_use = byte_index(src_str, "= answer"): u32 + 2;
	const b = resolve_binding_at_byte(&g, "answer", helper_use);
	// `helper` doesn't bind `answer` locally, and `answer` was
	// never a toplevel decl. Expect void.
	assert(b is void, "a local from another function must not be in scope here");
};

@test fn scope_graph_nested_block_shadows_outer() void = {
	// Inner `let x` in the nested block shadows the outer `let x`.
	// Resolving `x` inside the inner block returns the inner
	// binding; outside the inner block, the outer binding wins.
	// Distinctive markers (`+ 100` vs `+ 200`) keep the two cursor
	// positions unambiguous when looked up by needle.
	const src_str =
		"fn f() void = { let x: int = 1; { let x: int = 2; let _ = x + 100; }; let _ = x + 200; };\n";
	const src = strings::toutf8(src_str);
	let r = parse_recover(src, "test.ha");
	defer finish_parse_result(&r);
	let g = build_scope_graph(&r.subunit);
	defer finish_scope_graph(&g);
	const inner_use = byte_index(src_str, "x + 100"): u32;
	const outer_use = byte_index(src_str, "x + 200"): u32;
	const inner = resolve_binding_at_byte(&g, "x", inner_use);
	const outer = resolve_binding_at_byte(&g, "x", outer_use);
	match (inner) {
	case let b: scope_binding =>
		assert(b.kind == binding_kind::LET);
	case void => abort("inner shadow not found");
	};
	match (outer) {
	case let b: scope_binding =>
		assert(b.kind == binding_kind::LET);
	case void => abort("outer binding not found");
	};
	// The two bindings must be different — different name_spans.
	const inner_b = inner as scope_binding;
	const outer_b = outer as scope_binding;
	assert(
		inner_b.name_span.start.off != outer_b.name_span.start.off,
		"nested let should not resolve to the outer let's binding"
	);
};

@test fn scope_graph_function_parameter_is_visible_in_body() void = {
	// A function parameter is bound for the entire body.
	const src_str = "fn greet(name: str) void = { let _ = name; };\n";
	const src = strings::toutf8(src_str);
	let r = parse_recover(src, "test.ha");
	defer finish_parse_result(&r);
	let g = build_scope_graph(&r.subunit);
	defer finish_scope_graph(&g);
	const use_off = byte_index(src_str, "= name"): u32 + 2;
	const b = resolve_binding_at_byte(&g, "name", use_off);
	match (b) {
	case let bind: scope_binding =>
		assert(bind.kind == binding_kind::FUNC_PARAM);
	case void => abort("function parameter binding not found");
	};
};

@test fn scope_graph_for_binding_is_visible_in_loop_body() void = {
	// A `for (let i = ...)` binding is in scope inside the loop
	// body but not after the loop.
	const src_str =
		"fn f() void = { for (let i = 0; i < 10; i += 1) { let _ = i; }; };\n";
	const src = strings::toutf8(src_str);
	let r = parse_recover(src, "test.ha");
	defer finish_parse_result(&r);
	let g = build_scope_graph(&r.subunit);
	defer finish_scope_graph(&g);
	const use_off = byte_index(src_str, "= i; }"): u32 + 2;
	const b = resolve_binding_at_byte(&g, "i", use_off);
	match (b) {
	case let bind: scope_binding =>
		assert(
			bind.kind == binding_kind::LET,
			"for-loop bindings are introduced via `let` and should report LET kind"
		);
	case void => abort("for-binding `i` not found in loop body");
	};
};

@test fn scope_graph_for_binding_not_visible_after_loop() void = {
	// After the loop closes, the for-binding `i` must be out of
	// scope.
	const src_str =
		"fn f() void = { for (let i = 0; i < 10; i += 1) void; let i: int = 99; };\n";
	const src = strings::toutf8(src_str);
	let r = parse_recover(src, "test.ha");
	defer finish_parse_result(&r);
	let g = build_scope_graph(&r.subunit);
	defer finish_scope_graph(&g);
	// The second `let i: int = 99;` is a fresh let in the enclosing
	// scope. Resolving `i` at that binding site should find the
	// fresh let, not the loop's `i`.
	const fresh = byte_index(src_str, "let i: int = 99"): u32 + 4;
	const b = resolve_binding_at_byte(&g, "i", fresh);
	match (b) {
	case let bind: scope_binding =>
		// The binding at this offset must be the fresh `let i`
		// in the function body, not the for-loop's `i`.
		const fresh_loc = byte_index(src_str, "let i: int = 99"): i64;
		assert(
			bind.scope_start: i64 == fresh_loc,
			"resolution must find the fresh `let i`, not the loop's `i`"
		);
	case void => abort("fresh `let i` not found");
	};
};

@test fn scope_graph_sibling_scopes_dont_leak() void = {
	// Two sibling blocks each bind `x`. A reference in one block
	// must resolve to that block's binding, not the other's.
	const src_str =
		"fn f() void = { { let x: int = 1; let _ = x; }; { let x: int = 2; let _ = x; }; };\n";
	const src = strings::toutf8(src_str);
	let r = parse_recover(src, "test.ha");
	defer finish_parse_result(&r);
	let g = build_scope_graph(&r.subunit);
	defer finish_scope_graph(&g);
	const first_use = byte_index(src_str, "= x; }; { let"): u32 + 2;
	const second_use = byte_index(src_str, "= x; }; };"): u32 + 2;
	const a = resolve_binding_at_byte(&g, "x", first_use);
	const b = resolve_binding_at_byte(&g, "x", second_use);
	const a_bind = match (a) {
	case let v: scope_binding =>
		yield v;
	case void => abort("first sibling binding not found");
	};
	const b_bind = match (b) {
	case let v: scope_binding =>
		yield v;
	case void => abort("second sibling binding not found");
	};
	assert(
		a_bind.name_span.start.off != b_bind.name_span.start.off,
		"sibling scopes must each have their own binding"
	);
};

@test fn scope_graph_resolves_toplevel_decl() void = {
	// Toplevel decls live in the file-scope root and should resolve
	// from anywhere with no enclosing local binding.
	const src_str = "fn helper() void = void;\nfn caller() void = helper();\n";
	const src = strings::toutf8(src_str);
	let r = parse_recover(src, "test.ha");
	defer finish_parse_result(&r);
	let g = build_scope_graph(&r.subunit);
	defer finish_scope_graph(&g);
	const use_off = byte_index(src_str, "= helper"): u32 + 2;
	const b = resolve_binding_at_byte(&g, "helper", use_off);
	match (b) {
	case let bind: scope_binding =>
		assert(bind.kind == binding_kind::TOPLEVEL_DECL);
	case void => abort("toplevel helper not in scope");
	};
};

@test fn scope_graph_unknown_name_returns_void() void = {
	// A name with no binding in any enclosing scope returns void.
	const src_str = "fn f() void = { let x: int = 1; };\n";
	const src = strings::toutf8(src_str);
	let r = parse_recover(src, "test.ha");
	defer finish_parse_result(&r);
	let g = build_scope_graph(&r.subunit);
	defer finish_scope_graph(&g);
	const use_off = byte_index(src_str, "x:"): u32;
	const b = resolve_binding_at_byte(&g, "nonexistent", use_off);
	assert(b is void, "unknown name should resolve to void");
};
