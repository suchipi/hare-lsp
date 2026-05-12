// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Deeper inlay-hint type inference. Wraps `infer_type_from_init` (from
// navigation.ha) with an additional alias-following pass so a hint can
// see through type aliases like `type result = int;` -> "int" instead
// of stopping at the alias name. Recursion is bounded by
// `s.config.inlay_hints_inferred_types_max_depth`.
//
// Each hop counts towards the depth budget:
//   * Hop 1 — the initial `infer_type_from_init` call (call return,
//     literal, declared type, etc.).
//   * Hop 2..N — follow a workspace TYPE alias to its underlying type.
//
// On any hop that can't make progress (no init, name doesn't resolve,
// underlying isn't an alias), we return the best string we have so far.
// Returning the unresolved name beats hiding the hint entirely — a
// label like "result" still tells the user something meaningful.

use analysis;
use hare::ast;
use hare::unparse;
use io;
use memio;
use strings;

// Renders the inferred-type hint for the init expression of a let/const
// decl. Returns void to suppress the hint (no first-hop inference
// possible); otherwise returns a freshly-allocated label the caller
// must free.
export fn infer_let_type_deep(
	s: *server, doc: *document, init: *ast::expr,
) (str | void) = {
	const max_depth = effective_inlay_depth(s);
	if (max_depth == 0) return void;
	const first = match (infer_type_from_init(s, doc, init)) {
	case let label: str => yield label;
	case void => return void;
	};
	if (max_depth <= 1) return first;
	return follow_alias_chain(s, first, max_depth - 1);
};

// Clamps the user-configured depth to [[INLAY_DEPTH_HARD_MAX]].
fn effective_inlay_depth(s: *server) u32 = {
	const n = s.config.inlay_hints_inferred_types_max_depth;
	if (n > INLAY_DEPTH_HARD_MAX) return INLAY_DEPTH_HARD_MAX;
	return n;
};

// Given a type label (e.g. "result"), tries to unwrap it as an alias up
// to `budget` more times. Stops as soon as the current label doesn't
// match a workspace TYPE entry or its underlying isn't easily rendered.
// `current` is consumed; the returned string is freshly allocated.
fn follow_alias_chain(s: *server, current: str, budget: u32) str = {
	let label = current;
	let visited: []str = [];
	defer analysis::free_str_slice(visited);
	append(visited, strings::dup(label)!)!;
	for (let hops: u32 = 0; hops < budget; hops += 1) {
		const next = match (resolve_alias_once(s, label)) {
		case let s: str => yield s;
		case void => break;
		};
		if (contains_str_ih(visited, next)) {
			free(next);
			break;
		};
		append(visited, strings::dup(next)!)!;
		free(label);
		label = next;
	};
	return label;
};

// Looks up `name` as a TYPE entry in the workspace and renders its
// underlying type. Returns void when the name doesn't resolve, isn't a
// TYPE, doesn't have an underlying, or the underlying can't be
// rendered.
fn resolve_alias_once(s: *server, name: str) (str | void) = {
	const entry = match (analysis::find_first_by_short_name(
			&s.workspace_index, name)) {
	case let e: *analysis::workspace_entry =>
		if (e.kind != analysis::symbol_kind::TYPE) return void;
		yield e;
	case void => return void;
	};
	const fpe = match (cached_parse_or_drop_stale(s, entry.path)) {
	case let p: *file_parse_entry => yield p;
	case null => return void;
	};
	const decl = match (find_type_decl_by_name(&fpe.pr.subunit, name)) {
	case let d: *ast::decl => yield d;
	case void => return void;
	};
	const underlying = match (analysis::type_decl_underlying(decl)) {
	case let t: *ast::_type => yield t;
	case void => return void;
	};
	return render_type_ih(underlying);
};

fn find_type_decl_by_name(
	su: *ast::subunit, name: str,
) (*ast::decl | void) = {
	for (let i = 0z; i < len(su.decls); i += 1) {
		const d = &su.decls[i];
		match (d.decl) {
		case let t: ast::decl_type =>
			if (len(t.ident) > 0 &&
					t.ident[len(t.ident) - 1] == name) {
				return d;
			};
		case => void;
		};
	};
	return void;
};

fn render_type_ih(t: *ast::_type) (str | void) = {
	let buf = memio::dynamic();
	defer match (io::close(&buf)) { case => void; };
	match (unparse::_type(&buf, &unparse::syn_nowrap, t)) {
	case size => void;
	case => return void;
	};
	return strings::dup(memio::string(&buf)!)!;
};

fn contains_str_ih(haystack: []str, needle: str) bool = {
	for (let i = 0z; i < len(haystack); i += 1) {
		if (haystack[i] == needle) return true;
	};
	return false;
};
