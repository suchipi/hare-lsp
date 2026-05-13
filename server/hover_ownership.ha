// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Hover-time ownership inference: composes Layer 1 (annotations, cached
// on the analysis::symbol for local-file hits, computed inline for
// workspace/stdlib hits) with Layer 2 (stdlib doc-comment table) and
// Layer 3 (expression heuristics for locals and built-ins).
//
// Each `ownership_for_*` helper returns an `analysis::ownership_fact`
// whose `detail` the caller frees. `format_ownership_line` renders the
// final line; it returns "" when the type doesn't carry ownership, so
// callers can splice unconditionally.

use analysis;
use hare::ast;
use hare::unparse;
use lsp;
use memio;
use strings;

// Returns the Ownership-line markdown for `fact` and the rendered type.
// Emits the line when either:
//   - we have a positive signal (`fact.source != NONE`), so the user
//     explicitly told us or a heuristic decided; or
//   - the rendered type carries ownership semantics, in which case we
//     emit "Ownership: unknown" to acknowledge we looked.
// Returns "" only when the type doesn't carry ownership AND we have no
// signal — silence reserved for "this question doesn't apply".
//
// When `use_html` is true, the line is wrapped in `<small>` so HTML-aware
// clients (VSCode) render it as fine print. Disable for clients that
// don't render HTML in hover markdown (Neovim, Helix, Emacs default
// renderers) via `hare.hover.useHtml = false`, which suppresses the
// wrapper.
//
// Output forms (with `use_html = false`):
//   "Ownership: owned (annotation)"
//   "Ownership: owned (doc comment: ...)"
//   "Ownership: borrowed (heuristic: ...)"
//   "Ownership: unknown"
//
// Caller frees.
fn format_ownership_line(
	fact: analysis::ownership_fact,
	type_str: str,
	use_html: bool,
) str = {
	if (fact.source == analysis::ownership_source::NONE &&
			!type_string_carries_ownership(type_str)) {
		return strings::dup("")!;
	};
	let buf = memio::dynamic();
	defer lsp::safe_close(&buf);
	if (use_html) memio::concat(&buf, "<small>")!;
	memio::concat(&buf, "Ownership: ")!;
	memio::concat(&buf, kind_word(fact.kind))!;
	if (fact.source != analysis::ownership_source::NONE) {
		memio::concat(&buf, " (")!;
		memio::concat(&buf, fact.detail)!;
		memio::concat(&buf, ")")!;
	};
	if (use_html) memio::concat(&buf, "</small>")!;
	return strings::dup(memio::string(&buf)!)!;
};

fn kind_word(k: analysis::ownership) str = {
	switch (k) {
	case analysis::ownership::OWNED =>
		return "owned";
	case analysis::ownership::BORROWED =>
		return "borrowed";
	case analysis::ownership::UNKNOWN =>
		return "unknown";
	};
};

// True if the bare type string `s` carries memory ownership semantics:
// pointer (`*T`), nullable pointer (`nullable *T`), slice (`[]T`), or
// `str`. Callers pass the bare type only (not a full hover signature);
// each hover path computes the bare type via `rendered_type_for_decl`,
// `bare_type_for_param`, or `bare_type_for_binding`.
fn type_string_carries_ownership(s: str) bool = {
	if (len(s) == 0) return false;
	return tail_starts_ownership_type(trim_ascii_space(s));
};

// Scans the type tail for an ownership-carrying head token. We accept any
// prefix that matches the leading characters of `*`, `[]`, `str`,
// `nullable`, or `const *`/`const []` (since `const *T` is a Hare-valid
// pointer-to-const).
fn tail_starts_ownership_type(s: str) bool = {
	let t = s;
	for (true) {
		t = trim_ascii_space(t);
		if (len(t) == 0) return false;
		const bytes = strings::toutf8(t);
		if (bytes[0] == '*': u8) return true;
		if (bytes[0] == '[': u8) {
			if (len(bytes) >= 2 && bytes[1] == ']': u8) return true;
			// `[N]T` is an array, not a slice — fixed-size arrays
			// don't carry ownership.
			return false;
		};
		if (strings::hasprefix(t, "str")) {
			if (len(bytes) == 3) return true;
			const after = bytes[3];
			if (!is_ident_byte(after)) return true;
			return false;
		};
		if (strings::hasprefix(t, "nullable")) {
			t = strings::sub(t, len("nullable"), strings::end);
			continue;
		};
		if (strings::hasprefix(t, "const")) {
			const after_bytes = strings::toutf8(t);
			if (len(after_bytes) > 5 && !is_ident_byte(after_bytes[5])) {
				t = strings::sub(t, len("const"), strings::end);
				continue;
			};
			return false;
		};
		return false;
	};
};

fn trim_ascii_space(s: str) str = {
	const bytes = strings::toutf8(s);
	let start = 0z;
	for (start < len(bytes)) {
		const b = bytes[start];
		if (b != ' ': u8 && b != '\t': u8 && b != '\n': u8 && b != '\r': u8) break;
		start += 1;
	};
	let end = len(bytes);
	for (end > start) {
		const b = bytes[end - 1];
		if (b != ' ': u8 && b != '\t': u8 && b != '\n': u8 && b != '\r': u8) break;
		end -= 1;
	};
	return strings::sub(s, start, end);
};

// Ownership fact for a local-file symbol (cached from indexing).
fn ownership_for_local_symbol(
	sym: *analysis::symbol,
) analysis::ownership_fact = {
	return analysis::ownership_fact {
		kind = sym.return_ownership,
		source = sym.return_ownership_source,
		detail = strings::dup(sym.return_ownership_detail)!,
	};
};

// Ownership fact for a workspace/stdlib entry. Layer 1 (annotations from
// docs) first, then Layer 2 (stdlib table). When neither fires returns
// the empty fact.
fn ownership_for_workspace_entry(
	e: *analysis::workspace_entry,
) analysis::ownership_fact = {
	const is_func = e.kind == analysis::symbol_kind::FUNCTION;
	return analysis::compute_ownership_for(e.docs, is_func, e.module,
		e.short_name);
};

// Ownership fact for a builtin name. Currently only `alloc` carries
// ownership information; every other builtin returns the empty fact.
fn ownership_for_builtin(name: str) analysis::ownership_fact = {
	if (name == "alloc") {
		return analysis::ownership_fact {
			kind = analysis::ownership::OWNED,
			source = analysis::ownership_source::HEURISTIC,
			detail = strings::dup("heuristic: alloc returns owned memory")!,
		};
	};
	return analysis::empty_ownership_fact();
};

// Heuristic ownership for an expression. Used for local-binding hovers
// (the init expression) and for any future expression-level hover.
// Returns the empty fact when nothing matches.
fn ownership_for_expr(
	srv: *server,
	doc: *document,
	e: *ast::expr,
) analysis::ownership_fact = {
	match (e.expr) {
	case let l: ast::literal_expr =>
		match (l) {
		case let p: ast::plain_literal =>
			if (p.storage == ast::builtin_type::STR) {
				return analysis::ownership_fact {
					kind = analysis::ownership::BORROWED,
					source = analysis::ownership_source::HEURISTIC,
					detail = strings::dup(
						"heuristic: string literal lives in static storage")!,
				};
			};
			return analysis::empty_ownership_fact();
		case => void;
		};
		return analysis::empty_ownership_fact();
	case let u: ast::unarithm_expr =>
		if (u.op == ast::unarithm_op::ADDR) {
			return analysis::ownership_fact {
				kind = analysis::ownership::BORROWED,
				source = analysis::ownership_source::HEURISTIC,
				detail = strings::dup("heuristic: address-of borrows local storage")!,
			};
		};
		return analysis::empty_ownership_fact();
	case ast::alloc_expr =>
		return analysis::ownership_fact {
			kind = analysis::ownership::OWNED,
			source = analysis::ownership_source::HEURISTIC,
			detail = strings::dup("heuristic: alloc returns owned memory")!,
		};
	case let s2: ast::slice_expr =>
		return analysis::ownership_fact {
			kind = analysis::ownership::BORROWED,
			source = analysis::ownership_source::HEURISTIC,
			detail = strings::dup("heuristic: sub-slice borrows from its source")!,
		};
	case let c: ast::call_expr =>
		return ownership_for_call(srv, doc, &c);
	case let p: ast::propagate_expr =>
		return ownership_for_expr(srv, doc, p: *ast::expr);
	case let p: ast::error_assert_expr =>
		return ownership_for_expr(srv, doc, p: *ast::expr);
	case let ce: ast::cast_expr =>
		return ownership_for_expr(srv, doc, ce.value);
	case =>
		return analysis::empty_ownership_fact();
	};
};

// Ownership for a call expression: resolves the callee and propagates
// the callee's ownership. `alloc(...)` is special-cased via
// `ownership_for_builtin`. Returns empty if the callee is unresolvable
// or carries no ownership info.
fn ownership_for_call(
	srv: *server,
	doc: *document,
	c: *ast::call_expr,
) analysis::ownership_fact = {
	const callee_ident = match (c.lvalue.expr) {
	case let a: ast::access_expr =>
		yield match (a) {
		case let id: ast::access_identifier =>
			yield id;
		case =>
			return analysis::empty_ownership_fact();
		};
	case =>
		return analysis::empty_ownership_fact();
	};
	if (len(callee_ident) == 0) return analysis::empty_ownership_fact();
	const name = callee_ident[len(callee_ident) - 1];
	if (len(callee_ident) == 1) {
		const bf = ownership_for_builtin(name);
		if (bf.source != analysis::ownership_source::NONE) {
			return bf;
		};
	};
	match (lookup_callee(srv, doc, callee_ident)) {
	case let e: *analysis::workspace_entry =>
		return ownership_for_workspace_entry(e);
	case void =>
		return analysis::empty_ownership_fact();
	};
};

// Ownership for the value bound by a local `let`/`const` binding: walks
// the init expression with the heuristic walker.
fn ownership_for_local_binding(
	srv: *server,
	doc: *document,
	b: *ast::binding,
) analysis::ownership_fact = {
	return ownership_for_expr(srv, doc, b.init);
};

// Ownership for a function parameter. Looks up the enclosing function's
// symbol in the file index and reads the cached param_ownerships slot.
// Returns empty if the function isn't in the local index (e.g. cursor
// is inside an unindexable decl).
fn ownership_for_param(
	srv: *server,
	doc: *document,
	param_name: str,
	off: size,
) analysis::ownership_fact = {
	const cache = parse_of(doc);
	for (let i = 0z; i < len(cache.pr.subunit.decls); i += 1) {
		const d = &cache.pr.subunit.decls[i];
		if (off < d.loc.start.off: size) continue;
		if (off > d.loc.end.off: size) continue;
		const f = match (d.decl) {
		case let f: ast::decl_func =>
			yield f;
		case =>
			continue;
		};
		const fn_name = if (len(f.ident) > 0) f.ident[len(f.ident) - 1] else "";
		match (analysis::find_by_short_name(&cache.idx, fn_name)) {
		case let sym: *analysis::symbol =>
			for (let j = 0z; j < len(sym.param_names); j += 1) {
				if (sym.param_names[j] != param_name) continue;
				if (j >= len(sym.param_ownerships)) break;
				return analysis::ownership_fact {
					kind = sym.param_ownerships[j],
					source = if (sym.param_ownerships[j] != analysis::ownership::UNKNOWN)
						analysis::ownership_source::ANNOTATION
						else analysis::ownership_source::NONE,
					detail = strings::dup(sym.param_ownership_details[j])!,
				};
			};
		case void => void;
		};
		break;
	};
	return analysis::empty_ownership_fact();
};

// Locates the binding/param node at `off` for the local-binding hover
// path and returns the (ownership_fact, bare type_str) pair derived from
// it. Returns (empty fact, "") if the cursor isn't on a local target.
//
// Mirrors the same dispatch as `find_local_binding`: function parameter
// first, then `let`/`const` bindings.
fn local_target_ownership(
	srv: *server,
	doc: *document,
	su: *ast::subunit,
	name: str,
	off: size,
) (analysis::ownership_fact, str) = {
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
		// Parameter?
		match (f.prototype.repr) {
		case let proto: ast::func_type =>
			for (let j = 0z; j < len(proto.params); j += 1) {
				if (proto.params[j].name != name) continue;
				const t = bare_type_for_param(&proto.params[j]);
				const fact = ownership_for_param(srv, doc, name, off);
				return (fact, t);
			};
		case => void;
		};
		// Local binding inside the body.
		match (f.body) {
		case let body: *ast::expr =>
			match (find_local_binding_node(su, name, off)) {
			case let b: *ast::binding =>
				const t = bare_type_for_binding(srv, doc, b);
				const fact = ownership_for_local_binding(srv, doc, b);
				return (fact, t);
			case void => void;
			};
		case null => void;
		};
		break;
	};
	return (analysis::empty_ownership_fact(), strings::dup("")!);
};

// Bare type string for an AST type node (e.g. "*int", "str"). Caller
// frees. Returns "" on render error.
fn bare_type_for_ast_type(t: *ast::_type) str = {
	let buf = memio::dynamic();
	defer lsp::safe_close(&buf);
	match (unparse::_type(&buf, &unparse::syn_nowrap, t)) {
	case size => void;
	case =>
		return strings::dup("")!;
	};
	return strings::dup(memio::string(&buf)!)!;
};

// Bare type string for a function parameter (e.g. "*int", "str").
// Caller frees.
fn bare_type_for_param(p: *ast::func_param) str = {
	let buf = memio::dynamic();
	defer lsp::safe_close(&buf);
	match (unparse::_type(&buf, &unparse::syn_nowrap, p._type)) {
	case size => void;
	case =>
		return strings::dup("")!;
	};
	return strings::dup(memio::string(&buf)!)!;
};

// Bare type string for a local `let`/`const` binding. Uses the declared
// type if present; otherwise tries to infer from the init expression.
// Falls back to "" if nothing useful is available. Caller frees.
fn bare_type_for_binding(srv: *server, doc: *document, b: *ast::binding) str = {
	match (b._type) {
	case let t: *ast::_type =>
		let buf = memio::dynamic();
		defer lsp::safe_close(&buf);
		match (unparse::_type(&buf, &unparse::syn_nowrap, t)) {
		case size => void;
		case =>
			return strings::dup("")!;
		};
		return strings::dup(memio::string(&buf)!)!;
	case null =>
		match (infer_type_from_init(srv, doc, b.init)) {
		case let t: str =>
			return t;
		case void =>
			return strings::dup("")!;
		};
	};
};

// Rendered return-type string for a decl, used to decide whether to emit
// an Ownership line. For a function returns the result type only; for a
// global/const returns the declared type. Caller frees.
fn rendered_type_for_decl(d: *ast::decl) str = {
	match (d.decl) {
	case let f: ast::decl_func =>
		match (f.prototype.repr) {
		case let proto: ast::func_type =>
			let buf = memio::dynamic();
			defer lsp::safe_close(&buf);
			match (unparse::_type(&buf, &unparse::syn_nowrap, proto.result)) {
			case size => void;
			case =>
				return strings::dup("")!;
			};
			return strings::dup(memio::string(&buf)!)!;
		case =>
			return strings::dup("")!;
		};
	case let g: ast::decl_global =>
		match (g._type) {
		case let t: *ast::_type =>
			let buf = memio::dynamic();
			defer lsp::safe_close(&buf);
			match (unparse::_type(&buf, &unparse::syn_nowrap, t)) {
			case size => void;
			case =>
				return strings::dup("")!;
			};
			return strings::dup(memio::string(&buf)!)!;
		case null =>
			return strings::dup("")!;
		};
	case let c: ast::decl_const =>
		match (c._type) {
		case let t: *ast::_type =>
			let buf = memio::dynamic();
			defer lsp::safe_close(&buf);
			match (unparse::_type(&buf, &unparse::syn_nowrap, t)) {
			case size => void;
			case =>
				return strings::dup("")!;
			};
			return strings::dup(memio::string(&buf)!)!;
		case null =>
			return strings::dup("")!;
		};
	case =>
		return strings::dup("")!;
	};
};
