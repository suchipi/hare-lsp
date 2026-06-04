// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Completion for `match` case arms.
//
// When the cursor sits in a match case-arm type position (right after
// `case` with optional whitespace, part-way through a type name, or
// after `case let NAME: `) the grammatically valid tokens are the
// variants of the tagged union being matched over. This module detects
// that position and offers those variants.
//
// Detection mirrors the struct-member path: a cheap byte-level pre-check
// (is the cursor preceded by a `case` keyword on a valid prefix?) gates a
// sentinel splice + re-parse. We splice a complete synthetic case arm
// (`<sentinel> => 0;`) so the enclosing function (and therefore the
// `match` expression) parses despite the half-typed arm, then walk the
// AST for the match whose case type is the sentinel and resolve the type
// of that match's value expression.
//
// Enumeration recurses through the union definition. For every named
// union it encounters (the matched type itself, and any union spread or
// nested inside it via `...errors::error`) it offers BOTH the union name
// (so the user can match that whole subset with one `case`) AND each of
// its individual members, recursively. So matching an `io::error`
// (`!(...errors::error | underread | nomem)`) offers `io::error`,
// `errors::error`, every `errors::error` member, `io::underread`, and
// `nomem`. Names are qualified relative to the file being edited (a
// bare member of another module becomes `mod::name`) and carry an
// auto-import edit when their module isn't yet imported.

use analysis;
use encoding::json;
use hare::ast;
use lsp;
use strings;

// One enumerated union variant, ready to emit as a completion item. All
// strings are owned; release the slice with [[free_match_variants]].
type match_variant = struct {
	// The spelling a `case` would use, qualified relative to the edited
	// file: "errors::error", "io::underread", "nomem", or a bare
	// "underread" when the variant lives in the user's own module.
	// @owned
	display: str,
	// The bare type name without a module qualifier ("error",
	// "underread", "nomem"). Used as the label when the user has already
	// typed a `mod::` qualifier.
	// @owned
	leaf: str,
	// Fully-qualified module to `use` for this variant, or "" for a
	// builtin / same-module variant that needs no import.
	// @owned
	module_full: str,
};

// Attempts match-case-arm completion. Returns true (and populates `arr`)
// when the cursor is in a match case-arm type position whose matched value
// resolves to a tagged union; the caller then treats the completion as
// exclusive. Returns false to fall through to ordinary completion.
//
// @param s: borrowed
// @param doc: borrowed
// @param data: borrowed
// @param arr: borrowed
fn try_match_case_completion(
	s: *server,
	doc: *document,
	data: []u8,
	off: size,
	arr: *[]json::value,
) bool = {
	const type_start = match (match_case_type_start(data, off)) {
	case let ts: size =>
		yield ts;
	case void =>
		return false;
	};
	// Capture any trailing identifier bytes so a mid-word cursor
	// (`case io::er|ror`) splices over the whole token.
	let ident_end = off;
	for (ident_end < len(data); ident_end += 1) {
		if (!analysis::is_ident_byte(data[ident_end])) break;
	};
	const full_typed = strings::dup(strings::fromutf8(data[type_start..off])!)!;
	defer free(full_typed);

	// Splice a synthetic case arm so the enclosing match parses. Attempt
	// 1 supplies a body (`=> 0;`) for a brand-new, body-less arm; attempt
	// 2 leaves the body off for when the user already typed `=> expr`.
	let pr = parse_case_sentinel(data, type_start, ident_end, doc.uri, true);
	let found = find_match_value_for_sentinel(&pr.subunit);
	if (found is void) {
		analysis::finish_parse_result(&pr);
		pr = parse_case_sentinel(data, type_start, ident_end, doc.uri, false);
		found = find_match_value_for_sentinel(&pr.subunit);
	};
	defer analysis::finish_parse_result(&pr);
	const ve = match (found) {
	case let v: *ast::expr =>
		yield v;
	case void =>
		return false;
	};

	const lt = match (type_of_expr(s, doc, &pr.subunit, ve, 0)) {
	case let lt: located_type =>
		yield lt;
	case void =>
		return false;
	};
	// Only own the response when the matched value is genuinely a tagged
	// union; otherwise fall through so the user still gets normal
	// completions.
	if (!(resolve_to_union_tagged(s, lt, 0) is ast::tagged_type)) {
		return false;
	};

	const user_path = lsp::uri_decode_path(doc.uri);
	defer free(user_path);
	const user_mod = analysis::module_from_path(user_path);
	defer free(user_mod);

	let variants: []match_variant = [];
	defer free_match_variants(variants);
	walk_match_variant(s, lt, user_mod, &variants, 0);
	if (len(variants) == 0) return false;

	emit_match_variants(s, doc, &variants, full_typed, arr);
	return true;
};

// Byte-level pre-check: returns the start offset of the type token being
// typed when `off` sits in a match case-arm type position, else void. Two
// forms are recognised:
//   1. `case <type>`              (the type token may be empty)
//   2. `case let NAME: <type>`    (the binding form)
// The check is intentionally conservative on the cheap path; the sentinel
// re-parse is the authority on whether a real `match` is involved (a
// `switch` arm, which also uses `case`, fails to produce a sentinel-typed
// match case and so falls through).
//
// @param data: borrowed
fn match_case_type_start(data: []u8, off: size) (size | void) = {
	// Walk back over the partial type token: identifier bytes plus the
	// `:` of a qualified `mod::name`. A `: ` binding separator has a space
	// after it, which stops this scan, so it is not absorbed here.
	let ts = off;
	for (ts > 0) {
		const b = data[ts - 1];
		if (analysis::is_ident_byte(b) || b == ':': u8) {
			ts -= 1;
		} else {
			break;
		};
	};
	const before = skip_ws_back(data, ts);
	// Form 1: `case <type>`.
	if (word_ends_at(data, before, "case")) return ts;
	// Form 2: `case let NAME: <type>`.
	if (before > 0 && data[before - 1] == ':': u8) {
		let j = skip_ws_back(data, before - 1);
		const name_end = j;
		j = skip_ident_back(data, j);
		if (j == name_end) return void;
		j = skip_ws_back(data, j);
		if (!word_ends_at(data, j, "let")) return void;
		j = skip_ws_back(data, j - 3);
		if (word_ends_at(data, j, "case")) return ts;
	};
	return void;
};

// Returns the largest index <= i with no trailing whitespace bytes.
//
// @param data: borrowed
fn skip_ws_back(data: []u8, i: size) size = {
	for (i > 0) {
		const b = data[i - 1];
		if (b == ' ': u8 || b == '\t': u8 || b == '\n': u8 || b == '\r': u8) {
			i -= 1;
		} else {
			break;
		};
	};
	return i;
};

// @param data: borrowed
fn skip_ident_back(data: []u8, i: size) size = {
	for (i > 0 && analysis::is_ident_byte(data[i - 1])) i -= 1;
	return i;
};

// True when the bytes immediately ending at `pos` spell `word` and are not
// part of a longer identifier (so "xcase" does not match "case").
//
// @param data: borrowed
// @param word: borrowed
fn word_ends_at(data: []u8, pos: size, word: str) bool = {
	const wb = strings::toutf8(word);
	if (pos < len(wb)) return false;
	const start = pos - len(wb);
	for (let i = 0z; i < len(wb); i += 1) {
		if (data[start + i] != wb[i]) return false;
	};
	if (start > 0 && analysis::is_ident_byte(data[start - 1])) return false;
	return true;
};

// Re-parses `data` with a synthetic match case arm spliced in over
// [type_start, ident_end): the completion sentinel as the case type,
// optionally followed by `=> 0;` to supply a body.
//
// @param data: borrowed
// @param uri: borrowed
// @returns: owned
fn parse_case_sentinel(
	data: []u8,
	type_start: size,
	ident_end: size,
	uri: str,
	with_body: bool,
) analysis::parse_result = {
	const sentinel = strings::toutf8(COMPLETION_SENTINEL);
	let synth: []u8 = alloc([], len(data) + len(sentinel) + 8)!;
	defer free(synth);
	append(synth, data[..type_start]...)!;
	append(synth, sentinel...)!;
	if (with_body) {
		append(synth, strings::toutf8(" => 0;")...)!;
	};
	if (ident_end < len(data)) {
		append(synth, data[ident_end..]...)!;
	};
	return analysis::parse_recover(synth, uri);
};

// Locates the `match` expression one of whose case types is the completion
// sentinel and returns that match's value expression (the thing being
// matched). Returns void if no such match exists in `su`.
//
// @param su: borrowed
// @returns: borrowed from su
fn find_match_value_for_sentinel(su: *ast::subunit) (*ast::expr | void) = {
	for (let i = 0z; i < len(su.decls); i += 1) {
		match (scan_decl_for_case_sentinel(&su.decls[i])) {
		case let v: *ast::expr =>
			return v;
		case void => void;
		};
	};
	return void;
};

// @param d: borrowed
// @returns: borrowed from d
fn scan_decl_for_case_sentinel(d: *ast::decl) (*ast::expr | void) = {
	match (d.decl) {
	case let f: ast::decl_func =>
		match (f.body) {
		case let e: *ast::expr =>
			return scan_expr_for_case_sentinel(e);
		case null =>
			return void;
		};
	case let g: ast::decl_global =>
		match (g.init) {
		case let e: *ast::expr =>
			return scan_expr_for_case_sentinel(e);
		case null =>
			return void;
		};
	case let c: ast::decl_const =>
		return scan_expr_for_case_sentinel(c.init);
	case =>
		return void;
	};
};

// Recursively searches `e` for the match expression whose case type is the
// sentinel. Covers the expression forms a `match` statement realistically
// nests inside (blocks, bindings, control flow, defer/yield/return, calls,
// assignments, operators). On a hit, returns the match's value expression.
//
// @param e: borrowed
// @returns: borrowed from e
fn scan_expr_for_case_sentinel(e: *ast::expr) (*ast::expr | void) = {
	match (e.expr) {
	case let m: ast::match_expr =>
		for (let i = 0z; i < len(m.cases); i += 1) {
			if (case_type_is_sentinel(m.cases[i]._type)) return m.value;
		};
		match (scan_expr_for_case_sentinel(m.value)) {
		case let v: *ast::expr =>
			return v;
		case void => void;
		};
		for (let i = 0z; i < len(m.cases); i += 1) {
			const exprs = m.cases[i].exprs;
			for (let j = 0z; j < len(exprs); j += 1) {
				match (scan_expr_for_case_sentinel(exprs[j])) {
				case let v: *ast::expr =>
					return v;
				case void => void;
				};
			};
		};
		return void;
	case let c: ast::compound_expr =>
		for (let i = 0z; i < len(c.exprs); i += 1) {
			match (scan_expr_for_case_sentinel(c.exprs[i])) {
			case let v: *ast::expr =>
				return v;
			case void => void;
			};
		};
		return void;
	case let b: ast::binding_expr =>
		for (let i = 0z; i < len(b.bindings); i += 1) {
			match (scan_expr_for_case_sentinel(b.bindings[i].init)) {
			case let v: *ast::expr =>
				return v;
			case void => void;
			};
		};
		return void;
	case let i: ast::if_expr =>
		match (scan_expr_for_case_sentinel(i.cond)) {
		case let v: *ast::expr =>
			return v;
		case void => void;
		};
		match (scan_expr_for_case_sentinel(i.tbranch)) {
		case let v: *ast::expr =>
			return v;
		case void => void;
		};
		match (i.fbranch) {
		case let p: *ast::expr =>
			return scan_expr_for_case_sentinel(p);
		case null =>
			return void;
		};
	case let fr: ast::for_expr =>
		match (fr.bindings) {
		case let p: *ast::expr =>
			match (scan_expr_for_case_sentinel(p)) {
			case let v: *ast::expr =>
				return v;
			case void => void;
			};
		case null => void;
		};
		match (fr.cond) {
		case let p: *ast::expr =>
			match (scan_expr_for_case_sentinel(p)) {
			case let v: *ast::expr =>
				return v;
			case void => void;
			};
		case null => void;
		};
		match (fr.afterthought) {
		case let p: *ast::expr =>
			match (scan_expr_for_case_sentinel(p)) {
			case let v: *ast::expr =>
				return v;
			case void => void;
			};
		case null => void;
		};
		return scan_expr_for_case_sentinel(fr.body);
	case let sw: ast::switch_expr =>
		match (scan_expr_for_case_sentinel(sw.value)) {
		case let v: *ast::expr =>
			return v;
		case void => void;
		};
		for (let i = 0z; i < len(sw.cases); i += 1) {
			const exprs = sw.cases[i].exprs;
			for (let j = 0z; j < len(exprs); j += 1) {
				match (scan_expr_for_case_sentinel(exprs[j])) {
				case let v: *ast::expr =>
					return v;
				case void => void;
				};
			};
		};
		return void;
	case let d: ast::defer_expr =>
		return scan_expr_for_case_sentinel(d: *ast::expr);
	case let y: ast::yield_expr =>
		match (y.value) {
		case let p: *ast::expr =>
			return scan_expr_for_case_sentinel(p);
		case null =>
			return void;
		};
	case let r: ast::return_expr =>
		match (r) {
		case let p: *ast::expr =>
			return scan_expr_for_case_sentinel(p);
		case null =>
			return void;
		};
	case let c: ast::call_expr =>
		match (scan_expr_for_case_sentinel(c.lvalue)) {
		case let v: *ast::expr =>
			return v;
		case void => void;
		};
		for (let i = 0z; i < len(c.args); i += 1) {
			match (scan_expr_for_case_sentinel(c.args[i])) {
			case let v: *ast::expr =>
				return v;
			case void => void;
			};
		};
		return void;
	case let asn: ast::assign_expr =>
		match (asn.object) {
		case let p: *ast::expr =>
			match (scan_expr_for_case_sentinel(p)) {
			case let v: *ast::expr =>
				return v;
			case void => void;
			};
		case null => void;
		};
		return scan_expr_for_case_sentinel(asn.value);
	case let bn: ast::binarithm_expr =>
		match (scan_expr_for_case_sentinel(bn.lvalue)) {
		case let v: *ast::expr =>
			return v;
		case void => void;
		};
		return scan_expr_for_case_sentinel(bn.rvalue);
	case let u: ast::unarithm_expr =>
		return scan_expr_for_case_sentinel(u.operand);
	case let ca: ast::cast_expr =>
		return scan_expr_for_case_sentinel(ca.value);
	case let p: ast::propagate_expr =>
		return scan_expr_for_case_sentinel(p: *ast::expr);
	case let p: ast::error_assert_expr =>
		return scan_expr_for_case_sentinel(p: *ast::expr);
	case =>
		return void;
	};
};

// True when `t` is the completion sentinel used as a case type.
//
// @param t: borrowed
fn case_type_is_sentinel(t: nullable *ast::_type) bool = {
	match (t) {
	case let p: *ast::_type =>
		match (p.repr) {
		case let id: ast::alias_type =>
			return len(id) == 1 && id[0] == COMPLETION_SENTINEL;
		case =>
			return false;
		};
	case null =>
		return false;
	};
};

// Returns the tagged-union member list `lt` ultimately denotes, chasing
// alias and `!` (error) wrappers, or void if `lt` is not a tagged union.
// Used as the gate that decides whether match-case completion applies.
//
// @param s: borrowed
// @returns: borrowed
fn resolve_to_union_tagged(
	s: *server,
	lt: located_type,
	depth: int,
) (ast::tagged_type | void) = {
	if (depth >= MEMBER_RESOLVE_MAX_DEPTH) return void;
	match (lt.t.repr) {
	case let tag: ast::tagged_type =>
		return tag;
	case let et: ast::error_type =>
		return resolve_to_union_tagged(s,
			located_type {
				t = et: *ast::_type,
				text = lt.text,
				uri = lt.uri,
			}, depth + 1);
	case let id: ast::alias_type =>
		const lookup_doc = find_doc_for_uri(s, lt.uri);
		const d = match (resolve_alias_decl(s, lookup_doc, lt.uri, id)) {
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
		const (text, uri) = locate_decl_anywhere(s, d, lt);
		return resolve_to_union_tagged(s,
			located_type {
				t = u,
				text = text,
				uri = uri,
			}, depth + 1);
	case =>
		return void;
	};
};

// Like [[resolve_to_union_tagged]] but does not chase aliases - returns the
// tagged member list when `u` (or the type its `!` wraps) is one directly.
//
// @param u: borrowed
fn union_tagged_of(u: *ast::_type) (ast::tagged_type | void) = {
	match (u.repr) {
	case let tag: ast::tagged_type =>
		return tag;
	case let et: ast::error_type =>
		return union_tagged_of(et: *ast::_type);
	case =>
		return void;
	};
};

// Walks the type `lt` and appends a [[match_variant]] for every nameable
// `case` type it yields: the named unions encountered (so a whole subset
// can be matched at once) plus, recursively, their individual members.
//
// @param s: borrowed
// @param user_mod: borrowed
// @param out: borrowed
fn walk_match_variant(
	s: *server,
	lt: located_type,
	user_mod: str,
	out: *[]match_variant,
	depth: int,
) void = {
	if (depth >= MEMBER_RESOLVE_MAX_DEPTH) return;
	match (lt.t.repr) {
	case let id: ast::alias_type =>
		walk_alias_variant(s, lt, id, user_mod, out, depth);
	case let tag: ast::tagged_type =>
		for (let i = 0z; i < len(tag); i += 1) {
			walk_match_variant(s,
				located_type {
					t = tag[i].0,
					text = lt.text,
					uri = lt.uri,
				}, user_mod, out, depth + 1);
		};
	case let et: ast::error_type =>
		walk_match_variant(s,
			located_type {
				t = et: *ast::_type,
				text = lt.text,
				uri = lt.uri,
			}, user_mod, out, depth + 1);
	case ast::builtin_type =>
		// `nomem`, `void`, `done`, integer types, etc. unparse renders the
		// keyword, which is exactly what a `case` would write.
		const name = render_field_type(lt.t);
		defer free(name);
		add_match_variant(out, name, name, "");
	// Pointer / struct / list / tuple / func members can't be named
	// portably for a `case`; skip them.

	case => void;
	};
};

// Handles an alias-typed union member: emits the alias's (qualified) name
// and, when the alias is itself a named union, recurses into its members.
//
// @param s: borrowed
// @param id: borrowed
// @param user_mod: borrowed
// @param out: borrowed
fn walk_alias_variant(
	s: *server,
	lt: located_type,
	id: ast::alias_type,
	user_mod: str,
	out: *[]match_variant,
	depth: int,
) void = {
	if (len(id) == 0) return;
	const leaf_name = id[len(id) - 1];

	// Resolve the alias so we know its home module (for qualification and
	// auto-import) and can recurse if it is itself a union.
	const lookup_doc = find_doc_for_uri(s, lt.uri);
	const d = resolve_alias_decl(s, lookup_doc, lt.uri, id);

	let home_full = strings::dup("")!;
	defer free(home_full);
	let decl_text: []u8 = lt.text;
	let decl_uri = lt.uri;
	match (d) {
	case let dd: *ast::decl =>
		const (t2, u2) = locate_decl_anywhere(s, dd, lt);
		decl_text = t2;
		decl_uri = u2;
		free(home_full);
		home_full = qualified_module_for_uri(s, u2);
	case void => void;
	};
	const home_leaf = module_leaf_name(home_full);

	// Choose the spelling a `case` would use, and the module (if any) to
	// auto-import.
	let display = "";
	let import_mod = "";
	if (len(id) >= 2) {
		// Already module-qualified in source (e.g. `errors::error`); that
		// spelling is portable as written.
		display = strings::join("::", id...)!;
		import_mod = home_full;
	} else if (len(home_leaf) == 0 || home_leaf == user_mod) {
		// Same module as the file being edited (or unknown): no qualifier.
		display = strings::dup(leaf_name)!;
		import_mod = "";
	} else {
		display = strings::concat(home_leaf, "::", leaf_name)!;
		import_mod = home_full;
	};
	defer free(display);

	const fresh = add_match_variant(out, display, leaf_name, import_mod);
	// Recurse into a named union's members only the first time we see it,
	// which also breaks any pathological alias cycle.
	if (!fresh) return;

	const dd = match (d) {
	case let dd: *ast::decl =>
		yield dd;
	case void =>
		return;
	};
	const u = match (analysis::type_decl_underlying(dd)) {
	case let u: *ast::_type =>
		yield u;
	case void =>
		return;
	};
	match (union_tagged_of(u)) {
	case let tag: ast::tagged_type =>
		for (let i = 0z; i < len(tag); i += 1) {
			walk_match_variant(s,
				located_type {
					t = tag[i].0,
					text = decl_text,
					uri = decl_uri,
				}, user_mod, out, depth + 1);
		};
	case void =>
		// Follow a one-step alias chain (`type a = b;`) so an aliased
		// union still expands; non-union underlying types stop here.
		match (u.repr) {
		case ast::alias_type =>
			walk_match_variant(s,
				located_type {
					t = u,
					text = decl_text,
					uri = decl_uri,
				}, user_mod, out, depth + 1);
		case => void;
		};
	};
};

// Appends a variant unless one with the same `display` is already present.
// Returns true when newly added. Strings are duplicated into the slice.
//
// @param out: borrowed
// @param display: borrowed
// @param leaf: borrowed
// @param module_full: borrowed
fn add_match_variant(
	out: *[]match_variant,
	display: str,
	leaf: str,
	module_full: str,
) bool = {
	let v = *out;
	for (let i = 0z; i < len(v); i += 1) {
		if (v[i].display == display) return false;
	};
	append(v, match_variant {
		display = strings::dup(display)!,
		leaf = strings::dup(leaf)!,
		module_full = strings::dup(module_full)!,
	})!;
	*out = v;
	return true;
};

// @param v: owned
fn free_match_variants(v: []match_variant) void = {
	for (let i = 0z; i < len(v); i += 1) {
		free(v[i].display);
		free(v[i].leaf);
		free(v[i].module_full);
	};
	free(v);
};

// Returns the fully-qualified module name for the file at `uri`. For files
// under a stdlib / third-party root this is the dotted module path
// ("encoding::json"); for workspace files it is the leaf directory name.
//
// @param s: borrowed
// @param uri: borrowed
// @returns: owned
fn qualified_module_for_uri(s: *server, uri: str) str = {
	const path = lsp::uri_decode_path(uri);
	defer free(path);
	// stdlib_qualified_module falls back to module_from_path for paths
	// outside any search root, so this covers workspace files too.
	return stdlib_qualified_module(s, path);
};

// Emits a completion item for each collected variant, filtered by what the
// user has typed. When a `mod::` qualifier is already present the label is
// the bare leaf (the qualifier stays); otherwise the label is the fully
// qualified spelling and an auto-import edit is attached. A `let` keyword
// item is also offered (in the unqualified case) so the binding form
// `case let x: T =>` remains reachable.
//
// @param s: borrowed
// @param doc: borrowed
// @param variants: borrowed
// @param full_typed: borrowed
// @param arr: borrowed
fn emit_match_variants(
	s: *server,
	doc: *document,
	variants: *[]match_variant,
	full_typed: str,
	arr: *[]json::value,
) void = {
	const qualified = strings::contains(full_typed, "::");
	const imported = doc_imported_modules(doc);
	defer analysis::free_str_slice(imported);
	let a = *arr;
	const v = *variants;
	for (let i = 0z; i < len(v); i += 1) {
		const mv = &v[i];
		if (len(full_typed) > 0 && !strings::hasprefix(mv.display, full_typed)
				&& !strings::hasprefix(mv.leaf, full_typed)) {
			continue;
		};
		const label = if (qualified) mv.leaf else mv.display;
		let item = json::newobject();
		json::set(&item, "label", label: json::value)!;
		json::put(&item, "kind", CIK_CLASS)!;
		json::set(&item, "detail", mv.display: json::value)!;
		// Rank union variants above every other source, like struct fields.
		const sort = strings::concat(SORT_MEMBER, mv.display)!;
		defer free(sort);
		json::set(&item, "sortText", sort: json::value)!;
		if (!qualified && len(mv.module_full) > 0) {
			attach_auto_import(s, doc, &item, mv.module_full, imported);
		};
		append(a, item: json::value)!;
	};
	// The binding form is grammatical in any non-default case, so keep
	// `let` reachable when the user hasn't started a qualified name.
	if (!qualified
			&& (len(full_typed) == 0 || strings::hasprefix("let", full_typed))) {
		let item = json::newobject();
		json::set(&item, "label", "let": json::value)!;
		json::put(&item, "kind", CIK_KEYWORD)!;
		json::set(&item, "detail", "keyword": json::value)!;
		const sort = strings::concat(SORT_KEYWORD, "let")!;
		defer free(sort);
		json::set(&item, "sortText", sort: json::value)!;
		append(a, item: json::value)!;
	};
	*arr = a;
};
