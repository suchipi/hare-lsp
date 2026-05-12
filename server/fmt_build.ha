// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// AST -> doc builder for the comment-preserving formatter.
//
// The builders here walk a Hare subunit and emit a `doc` tree
// (server/fmt_doc.ha) that the pretty-printer then renders. Each
// wrappable construct (call args, struct fields, function signatures,
// long binary chains, …) emits a `group` whose contents fit in flat
// mode if there's room and break onto multiple lines otherwise. This
// matches the approach Prettier uses for JS / TS, adapted to Hare's
// style guide (https://harelang.org/documentation/usage/style.html):
// 80-column soft limit, tabs for indent, trailing commas when broken,
// `|` on the first line for tagged unions, double-indent for `&&` /
// `||` continuations inside `if` / `for` conditions, etc.
//
// Comment splicing: comments are popped from the cursor at every item
// boundary in a list. A comment popped inside a list emits as
// `comment_doc`, which forces the enclosing `group` into broken mode —
// so a list with a comment inside it always wraps.

use hare::ast;
use hare::ast::{binarithm_op};
use hare::unparse;
use io;
use memio;
use strings;

// Per-format-call state shared by every builder. Threaded through so
// the blank-line scan only happens once per format request, and so
// the literal-renderer can peek at source bytes (for detecting raw
// strings, which the AST otherwise throws away).
//
// `loc.start.off` and `loc.end.off` on every AST node are byte
// offsets into `data` - `analysis::parse_recover` runs
// `fixup_parse_result` to translate the lexer's native rune indices
// up front, so callers slicing `data` here can use those offsets
// directly without further conversion.
export type build_ctx = struct {
	c: *comment_cursor,
	bl: blank_lines,
	data: []u8,
};

// Builds the doc for an entire compilation subunit (a single .ha
// file), interleaving the comments from `c` at the right positions.
// `data_len` is the size of the source bytes; used as the boundary
// for trailing comments after the last decl.
export fn build_subunit_doc(
	su: *ast::subunit,
	c: *comment_cursor,
	bl: blank_lines,
	data: []u8,
) doc = {
	const data_len = len(data);
	let bc = build_ctx { c = c, bl = bl, data = data };
	let items: []doc = [];

	// Boundary for "file header" comments: the start of whichever
	// real construct comes first.
	let first_off = data_len;
	if (len(su.imports) > 0) {
		const off = su.imports[0].loc.start.off: size;
		if (off < first_off) first_off = off;
	};
	if (len(su.decls) > 0) {
		const off = su.decls[0].loc.start.off: size;
		if (off < first_off) first_off = off;
	};

	const last_header_end = push_comments_before(&items, c, first_off);

	// Preserve a blank line between the file header and the first
	// real construct if the source had one.
	match (last_header_end) {
	case void => void;
	case let end: size =>
		if (blank_between(bl, end, first_off)) {
			append(items, hardline())!;
		};
	};

	// Imports.
	for (let i = 0z; i < len(su.imports); i += 1) {
		const imp_off = su.imports[i].loc.start.off: size;
		const imp_end = su.imports[i].loc.end.off: size;
		const _ = push_comments_before(&items, c, imp_off);
		append(items, build_import_doc(&su.imports[i]))!;
		const next_imp_off = if (i + 1 <
			len(su.imports)) su.imports[i + 1].loc.start.off: size
			else if (len(su.decls) > 0) su.decls[0].loc.start.off: size
			else data_len;
		flush_trailing_comments_to_eol(&items, c, next_imp_off,
			imp_end, data);
		append(items, hardline())!;
		if (i + 1 < len(su.imports)) {
			const next_off = su.imports[i + 1].loc.start.off: size;
			if (blank_between(bl, imp_end, next_off)) {
				append(items, hardline())!;
			};
		};
	};

	// Blank line between imports and decls.
	if (len(su.imports) > 0 && len(su.decls) > 0) {
		append(items, hardline())!;
	};

	// Decls.
	for (let i = 0z; i < len(su.decls); i += 1) {
		const decl_off = su.decls[i].loc.start.off: size;
		const _ = push_comments_before(&items, c, decl_off);
		append(items, build_decl_doc(&su.decls[i], &bc))!;
		// Flush trailing comments on the same line as the decl's
		// closing `;` BEFORE the hardline that ends this decl's
		// line - otherwise the trailing comment would be picked up
		// by the next decl's leading flush and emitted with no
		// break (since trailing-comment doc nodes intentionally
		// don't emit one), gluing it onto the next decl.
		const next_decl_off = if (i + 1 <
			len(su.decls)) su.decls[i + 1].loc.start.off: size
			else data_len;
		// `decl.loc.end.off` includes any trailing-line comment
		// (the lexer's `mkloc` peeks past comments to the next
		// real token). Use the source-content end derived by
		// trimming whitespace backward from `next_decl_off`
		// instead, so the line check inside the flush picks up
		// the actual closing `;` line.
		const decl_src_end =
			source_content_end(data, decl_off, next_decl_off);
		flush_trailing_comments_to_eol(&items, c, next_decl_off,
			decl_src_end, data);
		append(items, hardline())!;
		if (i + 1 < len(su.decls)) {
			// Blank line between top-level decls — always emit
			// one blank to keep them visually separated, the
			// style guide groups decls together so this matches
			// idiomatic layout regardless of source spacing.
			append(items, hardline())!;
		};
	};

	// Trailing comments (after the last decl).
	const _ = push_comments_before(&items, c, data_len);

	return concat(items);
};

// Builds a doc for a run of consecutive top-level decls (used by
// range formatting). Leading comments before each decl and trailing
// comments inside fn bodies are preserved exactly as in
// build_subunit_doc, but file-header and trailing-EOF comments are
// not emitted — they're outside the range.
export fn build_decls_range_doc(
	su: *ast::subunit,
	first: size,
	last: size,
	c: *comment_cursor,
	bl: blank_lines,
	data: []u8,
) doc = {
	let bc = build_ctx { c = c, bl = bl, data = data };
	let items: []doc = [];
	for (let i = first; i <= last; i += 1) {
		const decl_off = su.decls[i].loc.start.off: size;
		const _ = push_comments_before(&items, c, decl_off);
		append(items, build_decl_doc(&su.decls[i], &bc))!;
		append(items, hardline())!;
		if (i < last) append(items, hardline())!;
	};
	return concat(items);
};

// ----- Decls --------------------------------------------------------
export fn build_decl_doc(d: *ast::decl, bc: *build_ctx) doc = {
	let items: []doc = [];

	if (d.exported) {
		append(items, text("export "))!;
	};

	match (d.decl) {
	case let f: ast::decl_func =>
		append(items, build_decl_func(d, f, bc))!;
	case let g: ast::decl_global =>
		append(items, build_decl_global(g, bc))!;
		append(items, text(";"))!;
	case let c: ast::decl_const =>
		append(items, build_decl_const(c, bc))!;
		append(items, text(";"))!;
	case let t: ast::decl_type =>
		append(items, build_decl_type(t, bc))!;
		append(items, text(";"))!;
	case let e: ast::assert_expr =>
		append(items, build_assert_expr(&e, bc))!;
		append(items, text(";"))!;
	};

	return concat(items);
};

fn build_decl_func(d: *ast::decl, f: ast::decl_func, bc: *build_ctx) doc = {
	let items: []doc = [];

	switch (f.attrs) {
	case ast::fndecl_attr::NONE => void;
	case ast::fndecl_attr::FINI =>
		append(items, text("@fini "))!;
	case ast::fndecl_attr::INIT =>
		append(items, text("@init "))!;
	case ast::fndecl_attr::TEST =>
		append(items, text("@test "))!;
	};

	if (len(f.symbol) != 0) {
		append(items, text(`@symbol("`))!;
		append(items, text(escape_str(f.symbol)))!;
		append(items, text(`") `))!;
	};

	append(items, text("fn "))!;
	append(items, text(render_ident(f.ident)))!;

	const proto = f.prototype.repr as ast::func_type;
	append(items, build_func_proto_doc(&proto, bc))!;

	match (f.body) {
	case null =>
		append(items, text(";"))!;
	case let body: *ast::expr =>
		append(items, text(" ="))!;
		match (body.expr) {
		case let cmp: ast::compound_expr =>
			append(items, text(" "))!;
			append(items, build_compound_body(body, &cmp, bc))!;
		case =>
			append(items, build_init_value_doc(body, bc))!;
		};
		append(items, text(";"))!;
	};
	return concat(items);
};

fn build_decl_global(g: ast::decl_global, bc: *build_ctx) doc = {
	let items: []doc = [];
	if (len(g.symbol) != 0) {
		append(items, text(`@symbol("`))!;
		append(items, text(escape_str(g.symbol)))!;
		append(items, text(`") `))!;
	} else if (g.is_threadlocal) {
		append(items, text("@threadlocal "))!;
	};
	append(items, text(if (g.is_const) "const " else "let "))!;
	append(items, text(render_ident(g.ident)))!;
	match (g._type) {
	case null => void;
	case let t: *ast::_type =>
		append(items, text(": "))!;
		if (type_has_const_prefix(bc, t.loc)) {
			append(items, text("const "))!;
		};
		append(items, build_type_doc(t, bc))!;
	};
	match (g.init) {
	case null => void;
	case let e: *ast::expr =>
		append(items, text(" ="))!;
		append(items, build_init_value_doc(e, bc))!;
	};
	return concat(items);
};

fn build_decl_const(c: ast::decl_const, bc: *build_ctx) doc = {
	let items: []doc = [];
	append(items, text("def "))!;
	append(items, text(render_ident(c.ident)))!;
	match (c._type) {
	case null => void;
	case let t: *ast::_type =>
		append(items, text(": "))!;
		if (type_has_const_prefix(bc, t.loc)) {
			append(items, text("const "))!;
		};
		append(items, build_type_doc(t, bc))!;
	};
	append(items, text(" ="))!;
	append(items, build_init_value_doc(c.init, bc))!;
	return concat(items);
};

fn build_decl_type(t: ast::decl_type, bc: *build_ctx) doc = {
	let items: []doc = [];
	append(items, text("type "))!;
	append(items, text(render_ident(t.ident)))!;
	append(items, text(" = "))!;
	if (type_has_const_prefix(bc, t._type.loc)) {
		append(items, text("const "))!;
	};
	append(items, build_type_doc(t._type, bc))!;
	return concat(items);
};

// Wraps an init value in a group that breaks BEFORE the value if the
// `key = value` form doesn't fit on one line. In flat mode renders as
// ` value`; in broken mode renders as `\n\tvalue` at the current
// indent + 1.
//
// EXCEPTION: when the RHS opens its own block (`match { ... }`,
// `switch { ... }`, `for { ... }`, `if { ... } else { ... }`, a
// compound `{ ... }`, or a multi-line struct/array/tuple literal),
// keep the keyword/opening bracket on the same line as `=` and let
// the block contents wrap inside. Per the Hare style guide examples,
// `const x = match (foo) {` stays on one line; only the cases break.
// Forcing a break BEFORE the RHS in those cases produces a stray
// `=` at end of line followed by `\n\tmatch (...)` which is uglier
// and consumes a full line for nothing.
fn build_init_value_doc(e: *ast::expr, bc: *build_ctx) doc = {
	if (rhs_introduces_own_block(e)) {
		let items: []doc = [];
		append(items, text(" "))!;
		append(items, build_expr_doc(e, bc))!;
		return concat(items);
	};
	let inner: []doc = [];
	append(inner, line(" "))!;
	append(inner, build_expr_doc(e, bc))!;
	let g_items: []doc = [];
	append(g_items, nest(1, concat(inner)))!;
	return group(g_items);
};

// Returns true if `e` renders as a construct whose first token is
// followed by an opening `(`, `{`, or `[` and whose body wraps
// internally - keeping such constructs on the `=` line preserves the
// visual cue that the RHS continues into a block, instead of pushing
// the keyword down to a new indented line.
fn rhs_introduces_own_block(e: *ast::expr) bool = {
	match (e.expr) {
	case ast::match_expr =>
		return true;
	case ast::switch_expr =>
		return true;
	case ast::for_expr =>
		return true;
	case ast::compound_expr =>
		return true;
	case let i: ast::if_expr =>
		return i.fbranch != null;
	// An `if` without an `else` branch can render flat as a
	// single line (`if (cond) value`); only when there's an
	// else branch does it span multiple lines and benefit
	// from staying glued to `=`.

	case let l: ast::literal_expr =>
		match (l) {
		case ast::struct_literal =>
			return true;
		case ast::array_literal =>
			return true;
		case ast::tuple_literal =>
			return true;
		case ast::plain_literal =>
			return false;
		};
	case =>
		return false;
	};
};

// ----- Imports ------------------------------------------------------
export fn build_import_doc(im: *ast::import) doc = {
	let items: []doc = [];
	append(items, text("use "))!;
	match (im.bindings) {
	case void =>
		append(items, text(render_ident(im.ident)))!;
	case let alias: ast::import_alias =>
		append(items, text(alias))!;
		append(items, text(" = "))!;
		append(items, text(render_ident(im.ident)))!;
	case let objects: ast::import_members =>
		append(items, text(render_ident(im.ident)))!;
		append(items, text("::"))!;
		append(items, build_member_list(objects))!;
	case ast::import_wildcard =>
		append(items, text(render_ident(im.ident)))!;
		append(items, text("::*"))!;
	};
	append(items, text(";"))!;
	return concat(items);
};

fn build_member_list(members: []str) doc = {
	let inner: []doc = [];
	append(inner, line(""))!;
	for (let i = 0z; i < len(members); i += 1) {
		append(inner, text(members[i]))!;
		if (i + 1 < len(members)) {
			append(inner, text(","))!;
			append(inner, line(" "))!;
		};
	};
	append(inner, if_broken(","))!;

	let g_items: []doc = [];
	append(g_items, text("{"))!;
	append(g_items, nest(1, concat(inner)))!;
	append(g_items, line(""))!;
	append(g_items, text("}"))!;
	return group(g_items);
};

// ----- Compound body & statements ----------------------------------
fn build_compound_body(
	body: *ast::expr,
	cmp: *ast::compound_expr,
	bc: *build_ctx,
) doc = {
	let outer: []doc = [];
	if (cmp.label != "") {
		append(outer, text(":"))!;
		append(outer, text(cmp.label))!;
		append(outer, text(" "))!;
	};
	append(outer, text("{"))!;

	let inner: []doc = [];
	const body_end = body.loc.end.off: size;
	for (let i = 0z; i < len(cmp.exprs); i += 1) {
		const stmt = cmp.exprs[i];
		const stmt_off = stmt.loc.start.off: size;
		const stmt_end = stmt.loc.end.off: size;
		append(inner, hardline())!;
		const _ = push_comments_before(&inner, bc.c, stmt_off);
		append(inner, build_expr_doc(stmt, bc))!;
		append(inner, text(";"))!;
		// After emitting the statement and its `;`, eagerly flush
		// any trailing comments that share the statement's source
		// line. This must happen BEFORE the next iteration's
		// hardline; otherwise a trailing `// note` would land on
		// its own line below the code instead of inline with it.
		const next_stmt_off = if (i + 1 <
			len(cmp.exprs)) cmp.exprs[i + 1].loc.start.off: size
			else body_end;
		flush_trailing_comments_to_eol(&inner, bc.c, next_stmt_off,
			stmt_end, bc.data);
		if (i + 1 < len(cmp.exprs)) {
			const next_off = cmp.exprs[i + 1].loc.start.off: size;
			if (blank_between(bc.bl, stmt_end, next_off)) {
				append(inner, hardline())!;
			};
		};
	};
	const _ = push_comments_before(&inner, bc.c, body_end);

	append(outer, nest(1, concat(inner)))!;
	append(outer, hardline())!;
	append(outer, text("}"))!;
	return concat(outer);
};

// Returns the end offset of the last comment popped, or void if no
// comments were popped. Callers use this to decide whether to emit a
// blank line between the leading comments and the next construct.
fn push_comments_before(
	items: *[]doc,
	c: *comment_cursor,
	boundary: size,
) (size | void) = {
	const cs = pop_before(c, boundary);
	if (len(cs) == 0) return;
	for (let i = 0z; i < len(cs); i += 1) {
		let cur = *items;
		// Always emit as full-line here. Trailing comments (the
		// is_trailing flag) only stay inline when picked up by
		// `flush_trailing_comments_to_eol` immediately after the
		// owning code; once a comment lingers long enough to be
		// popped by `push_comments_before`, the code it would
		// have trailed has already been emitted (with its own
		// hardline), and there's no way to put the comment back
		// on that line. Treat it as a leading comment for the
		// next construct so it lands on a fresh line.
		append(cur, comment(cs[i].text))!;
		*items = cur;
	};
	return cs[len(cs) - 1].end_off;
};

// Flushes any pending trailing comments that fall before `boundary`
// AND share their source line with the byte offset `code_pos`.
// Called immediately after emitting a code item (a statement, decl,
// import) so a trailing `// note` lands inline with that item's
// closing `;` instead of waiting for the next iteration's leading
// `push_comments_before` - which fires AFTER a hardline and would
// therefore drop the comment onto a new line.
//
// `code_pos` is any byte offset inside (or at the end of) the
// just-emitted code; we count `\n`s from start of `data` to find its
// source line. Only comments on that exact line are popped, so a
// chain of `case ... =>; // note` lines doesn't fold every note onto
// the first line emitted.
fn flush_trailing_comments_to_eol(
	items: *[]doc,
	c: *comment_cursor,
	boundary: size,
	code_pos: size,
	data: []u8,
) void = {
	const code_line = line_of(data, code_pos);
	for (c.pos < len(c.comments)) {
		const ci = &c.comments[c.pos];
		if (!ci.is_trailing) break;
		if (ci.start_off >= boundary) break;
		if (ci.line != code_line) break;
		let cur = *items;
		append(cur, trailing_comment(ci.text))!;
		*items = cur;
		c.pos += 1;
	};
};

// Returns the byte offset of the LAST non-whitespace byte in
// `data[lo..hi)` - i.e., where the actual code content of a span
// ends, ignoring any trailing whitespace. Used to find the source
// line a decl's `;` lives on, since `decl.loc.end.off` from the
// parser points at the next decl's start (mkloc peeks past
// intervening comments). Returns `lo` if the span is all whitespace.
fn source_content_end(data: []u8, lo: size, hi: size) size = {
	let cap = if (hi > len(data)) len(data) else hi;
	let i = cap;
	for (i > lo; i -= 1) {
		const b = data[i - 1];
		if (b != ' ': u8 && b != '\t': u8 && b != '\n': u8) {
			return i - 1;
		};
	};
	return lo;
};

// Returns the 0-based line number of byte offset `pos` in `data`,
// counting `\n` bytes before it. `pos` is clamped to `len(data)`.
fn line_of(data: []u8, pos: size) size = {
	const p = if (pos > len(data)) len(data) else pos;
	let count: size = 0;
	for (let i = 0z; i < p; i += 1) {
		if (data[i] == '\n': u8) count += 1;
	};
	return count;
};

// ----- Types --------------------------------------------------------
export fn build_type_doc(t: *ast::_type, bc: *build_ctx) doc = {
	match (t.repr) {
	case let a: ast::alias_type =>
		return text(render_ident(a));
	case let b: ast::builtin_type =>
		return text(unparse::builtin_type(b));
	case let e: ast::enum_type =>
		return build_enum_type(&e, bc);
	case let e: ast::error_type =>
		let items: []doc = [];
		append(items, text("!"))!;
		append(items, build_type_doc(e: *ast::_type, bc))!;
		return concat(items);
	case let f: ast::func_type =>
		let items: []doc = [];
		append(items, text("fn"))!;
		append(items, build_func_proto_doc(&f, bc))!;
		return concat(items);
	case let l: ast::list_type =>
		return build_list_type(&l, bc);
	case let p: ast::pointer_type =>
		let items: []doc = [];
		if (p.flags & ast::pointer_flag::NULLABLE != 0) {
			append(items, text("nullable *"))!;
		} else {
			append(items, text("*"))!;
		};
		if (type_has_const_prefix(bc, p.referent.loc)) {
			append(items, text("const "))!;
		};
		append(items, build_type_doc(p.referent, bc))!;
		return concat(items);
	case let s: ast::struct_type =>
		return build_struct_union_type(t, bc);
	case let u: ast::union_type =>
		return build_struct_union_type(t, bc);
	case let tt: ast::tagged_type =>
		return build_tagged_type(tt, bc);
	case let tt: ast::tuple_type =>
		return build_tuple_type(tt, bc);
	};
};

fn build_func_proto_doc(t: *ast::func_type, bc: *build_ctx) doc = {
	let inner: []doc = [];
	append(inner, line(""))!;
	for (let i = 0z; i < len(t.params); i += 1) {
		const p = &t.params[i];
		if (p.name == "") {
			append(inner, text("_: "))!;
		} else {
			append(inner, text(p.name))!;
			append(inner, text(": "))!;
		};
		if (type_has_const_prefix(bc, p._type.loc)) {
			append(inner, text("const "))!;
		};
		append(inner, build_type_doc(p._type, bc))!;
		match (p.default_value) {
		case void => void;
		case let e: ast::expr =>
			append(inner, text(" = "))!;
			append(inner, build_expr_doc(&e, bc))!;
		};
		const more = i + 1 < len(t.params) || t.variadism == ast::variadism::C;
		if (more) {
			append(inner, text(","))!;
			append(inner, line(" "))!;
		};
	};
	if (t.variadism == ast::variadism::HARE) {
		append(inner, text("..."))!;
	} else if (t.variadism == ast::variadism::C) {
		append(inner, text("..."))!;
	};
	// Hare's grammar requires `)` immediately after a `...` variadic
	// marker — no trailing comma allowed. Only emit the broken-mode
	// trailing comma for plain parameter lists.
	if (len(t.params) > 0 && t.variadism == ast::variadism::NONE) {
		append(inner, if_broken(","))!;
	};

	let g_items: []doc = [];
	append(g_items, text("("))!;
	append(g_items, nest(1, concat(inner)))!;
	append(g_items, line(""))!;
	append(g_items, text(") "))!;
	if (type_has_const_prefix(bc, t.result.loc)) {
		append(g_items, text("const "))!;
	};
	append(g_items, build_type_doc(t.result, bc))!;
	return group(g_items);
};

fn build_enum_type(e: *ast::enum_type, bc: *build_ctx) doc = {
	// Always render multi-line (one variant per line, trailing
	// comma). Per project convention enums are not collapsed onto
	// a single line even when they would fit, since editing a
	// constant set of names is easier when each lives on its own
	// line and version-control diffs touch one line per change.
	let inner: []doc = [];
	for (let i = 0z; i < len(e.values); i += 1) {
		append(inner, hardline())!;
		const v = &e.values[i];
		append(inner, text(v.name))!;
		match (v.value) {
		case null => void;
		case let ex: *ast::expr =>
			append(inner, text(" = "))!;
			append(inner, build_expr_doc(ex, bc))!;
		};
		append(inner, text(","))!;
	};

	let outer: []doc = [];
	append(outer, text("enum "))!;
	if (e.storage != ast::builtin_type::INT) {
		append(outer, text(unparse::builtin_type(e.storage)))!;
		append(outer, text(" "))!;
	};
	append(outer, text("{"))!;
	append(outer, nest(1, concat(inner)))!;
	append(outer, hardline())!;
	append(outer, text("}"))!;
	return concat(outer);
};

fn build_list_type(l: *ast::list_type, bc: *build_ctx) doc = {
	let items: []doc = [];
	append(items, text("["))!;
	match (l.length) {
	case ast::len_slice => void;
	case ast::len_unbounded =>
		append(items, text("*"))!;
	case ast::len_contextual =>
		append(items, text("_"))!;
	case let e: *ast::expr =>
		append(items, build_expr_doc(e, bc))!;
	};
	append(items, text("]"))!;
	if (type_has_const_prefix(bc, l.members.loc)) {
		append(items, text("const "))!;
	};
	append(items, build_type_doc(l.members, bc))!;
	return concat(items);
};

fn build_struct_union_type(t: *ast::_type, bc: *build_ctx) doc = {
	let outer: []doc = [];
	let members: []ast::struct_member = match (t.repr) {
	case let s: ast::struct_type =>
		append(outer, text("struct "))!;
		if (s.packed) {
			append(outer, text("@packed "))!;
		};
		append(outer, text("{"))!;
		yield s.members;
	case let u: ast::union_type =>
		append(outer, text("union {"))!;
		yield u: []ast::struct_member;
	case => abort();
	};

	// Softline-separated members so a tiny struct (e.g.
	// `struct { x: int, y: int }`) renders inline if it fits within
	// 80 cols. Per the Hare style guide, single-line struct uses
	// `{ field, field }` (spaces, no trailing comma); multi-line
	// uses one field per line with a required trailing comma.
	const force_break = source_opens_multiline(bc, t.loc, ['{': u8]);
	let inner: []doc = [];
	append(inner, leading_softline(force_break, " "))!;
	for (let i = 0z; i < len(members); i += 1) {
		const m = &members[i];
		// Flush comments above this field. Approximation: use the
		// field's `_type` loc as the boundary - per-field doc
		// comments live on the line(s) just before the type. The
		// struct_member AST node itself has no loc.
		const field_off = struct_member_off(m);
		if (field_off != 0z) {
			const _ = push_comments_before(&inner, bc.c, field_off);
		};
		match (m.member) {
		case let f: ast::struct_field =>
			append(inner, text(f.name))!;
			append(inner, text(": "))!;
			if (type_has_const_prefix(bc, f._type.loc)) {
				append(inner, text("const "))!;
			};
			append(inner, build_type_doc(f._type, bc))!;
		case let e: ast::struct_embedded =>
			append(inner, build_type_doc(e: *ast::_type, bc))!;
		case let a: ast::struct_alias =>
			append(inner, text(render_ident(a)))!;
		};
		if (i + 1 < len(members)) {
			append(inner, text(","))!;
			append(inner, line(" "))!;
		};
	};
	// Flush any comments that appear after the last field but
	// before the closing `}` (file-internal trailing notes).
	const struct_end = t.loc.end.off: size;
	const _ = push_comments_before(&inner, bc.c, struct_end);
	if (len(members) > 0) {
		append(inner, if_broken(","))!;
	};

	append(outer, nest(1, concat(inner)))!;
	append(outer, line(" "))!;
	append(outer, text("}"))!;
	return group(outer);
};

// Best-effort byte offset for the start of a struct/union member.
// Returns 0 for struct_alias members (the alias is a bare ident with
// no loc reachable here).
fn struct_member_off(m: *ast::struct_member) size = {
	match (m.member) {
	case let f: ast::struct_field =>
		return f._type.loc.start.off: size;
	case let e: ast::struct_embedded =>
		return (e: *ast::_type).loc.start.off: size;
	case ast::struct_alias =>
		return 0z;
	};
};

fn build_tagged_type(tt: ast::tagged_type, bc: *build_ctx) doc = {
	// Style guide: when broken, `|` stays on the FIRST line of each
	// pair (i.e. break after `|`, not before). `(A |\n\tB |\n\tC)`.
	let inner: []doc = [];
	append(inner, line(""))!;
	for (let i = 0z; i < len(tt); i += 1) {
		if (tt[i].1) {
			append(inner, text("..."))!;
		};
		append(inner, build_type_doc(tt[i].0, bc))!;
		if (i + 1 < len(tt)) {
			append(inner, text(" |"))!;
			append(inner, line(" "))!;
		};
	};

	let g_items: []doc = [];
	append(g_items, text("("))!;
	append(g_items, nest(1, concat(inner)))!;
	append(g_items, line(""))!;
	append(g_items, text(")"))!;
	return group(g_items);
};

fn build_tuple_type(tt: ast::tuple_type, bc: *build_ctx) doc = {
	let inner: []doc = [];
	append(inner, line(""))!;
	for (let i = 0z; i < len(tt); i += 1) {
		append(inner, build_type_doc(tt[i], bc))!;
		if (i + 1 < len(tt)) {
			append(inner, text(","))!;
			append(inner, line(" "))!;
		};
	};
	if (len(tt) > 0) {
		append(inner, if_broken(","))!;
	};

	let g_items: []doc = [];
	append(g_items, text("("))!;
	append(g_items, nest(1, concat(inner)))!;
	append(g_items, line(""))!;
	append(g_items, text(")"))!;
	return group(g_items);
};

// ----- Expressions --------------------------------------------------
export fn build_expr_doc(e: *ast::expr, bc: *build_ctx) doc = {
	match (e.expr) {
	case let a: ast::access_expr =>
		return build_access_expr(a, bc);
	case let a: ast::align_expr =>
		let items: []doc = [];
		append(items, text("align("))!;
		append(items, build_type_doc(a, bc))!;
		append(items, text(")"))!;
		return concat(items);
	case let a: ast::alloc_expr =>
		return build_alloc_expr(&a, bc);
	case let a: ast::append_expr =>
		return build_append_insert(e, bc);
	case let a: ast::assert_expr =>
		return build_assert_expr(&a, bc);
	case let a: ast::assign_expr =>
		return build_assign_expr(&a, bc);
	case let b: ast::binarithm_expr =>
		return build_binarithm_expr(&b, bc, 0u);
	case let b: ast::binding_expr =>
		return build_binding_expr(&b, bc, "=");
	case let br: ast::break_expr =>
		return build_break_yield("break", &br, bc);
	case let c: ast::call_expr =>
		return build_call_expr(&c, bc);
	case let c: ast::cast_expr =>
		return build_cast_expr(&c, bc);
	case let l: ast::literal_expr =>
		return build_literal_expr(l, e.loc, bc);
	case let c: ast::continue_expr =>
		if (c == "") return text("continue");
		let items: []doc = [];
		append(items, text("continue :"))!;
		append(items, text(c))!;
		return concat(items);
	case let d: ast::defer_expr =>
		let items: []doc = [];
		append(items, text("defer "))!;
		append(items, build_expr_doc(d, bc))!;
		return concat(items);
	case let d: ast::delete_expr =>
		let items: []doc = [];
		if (d.is_static) append(items, text("static "))!;
		append(items, text("delete("))!;
		append(items, build_expr_doc(d.object, bc))!;
		append(items, text(")"))!;
		return concat(items);
	case let f: ast::for_expr =>
		return build_for_expr(&f, bc);
	case let f: ast::free_expr =>
		let items: []doc = [];
		append(items, text("free("))!;
		append(items, build_expr_doc(f, bc))!;
		append(items, text(")"))!;
		return concat(items);
	case let ea: ast::error_assert_expr =>
		let items: []doc = [];
		const needs_parens = !is_postfix(ea);
		if (needs_parens) append(items, text("("))!;
		append(items, build_expr_doc(ea, bc))!;
		if (needs_parens) append(items, text(")"))!;
		append(items, text("!"))!;
		return concat(items);
	case let i: ast::if_expr =>
		return build_if_expr(&i, bc);
	case let ie: ast::insert_expr =>
		return build_append_insert(e, bc);
	case let cmp: ast::compound_expr =>
		return build_compound_body(e, &cmp, bc);
	case let m: ast::match_expr =>
		return build_match_expr(&m, e.loc, bc);
	case let l: ast::len_expr =>
		let items: []doc = [];
		append(items, text("len("))!;
		append(items, build_expr_doc(l, bc))!;
		append(items, text(")"))!;
		return concat(items);
	case let s: ast::size_expr =>
		let items: []doc = [];
		append(items, text("size("))!;
		append(items, build_type_doc(s, bc))!;
		append(items, text(")"))!;
		return concat(items);
	case let o: ast::offset_expr =>
		let items: []doc = [];
		append(items, text("offset("))!;
		append(items, build_expr_doc(o, bc))!;
		append(items, text(")"))!;
		return concat(items);
	case let p: ast::propagate_expr =>
		let items: []doc = [];
		const needs_parens = !is_postfix(p);
		if (needs_parens) append(items, text("("))!;
		append(items, build_expr_doc(p, bc))!;
		if (needs_parens) append(items, text(")"))!;
		append(items, text("?"))!;
		return concat(items);
	case let r: ast::return_expr =>
		match (r) {
		case null =>
			return text("return");
		case let inner: *ast::expr =>
			let items: []doc = [];
			append(items, text("return "))!;
			append(items, build_expr_doc(inner, bc))!;
			return concat(items);
		};
	case let s: ast::slice_expr =>
		return build_slice_expr(&s, bc);
	case let s: ast::switch_expr =>
		return build_switch_expr(&s, e.loc, bc);
	case let u: ast::unarithm_expr =>
		return build_unarithm_expr(&u, bc);
	case ast::undefined_expr =>
		return text("@undefined");
	case let v: ast::variadic_expr =>
		return build_variadic_expr(v, bc);
	case let y: ast::yield_expr =>
		return build_break_yield("yield", &y, bc);
	};
};

fn build_access_expr(a: ast::access_expr, bc: *build_ctx) doc = {
	match (a) {
	case let id: ast::access_identifier =>
		return text(render_ident(id));
	case let ix: ast::access_index =>
		let items: []doc = [];
		const np = !is_postfix(ix.object);
		if (np) append(items, text("("))!;
		append(items, build_expr_doc(ix.object, bc))!;
		if (np) append(items, text(")"))!;
		append(items, text("["))!;
		append(items, build_expr_doc(ix.index, bc))!;
		append(items, text("]"))!;
		return concat(items);
	case let fi: ast::access_field =>
		let items: []doc = [];
		const np = !is_postfix(fi.object);
		if (np) append(items, text("("))!;
		append(items, build_expr_doc(fi.object, bc))!;
		if (np) append(items, text(")"))!;
		append(items, text("."))!;
		append(items, text(fi.field))!;
		return concat(items);
	case let tp: ast::access_tuple =>
		let items: []doc = [];
		const np = !is_postfix(tp.object);
		if (np) append(items, text("("))!;
		append(items, build_expr_doc(tp.object, bc))!;
		if (np) append(items, text(")"))!;
		append(items, text("."))!;
		append(items, build_expr_doc(tp.value, bc))!;
		return concat(items);
	};
};

fn build_alloc_expr(a: *ast::alloc_expr, bc: *build_ctx) doc = {
	let items: []doc = [];
	append(items, text("alloc("))!;
	append(items, build_expr_doc(a.init, bc))!;
	match (a.capacity) {
	case null =>
		if (a.form == ast::alloc_form::COPY) {
			append(items, text("..."))!;
		};
	case let e: *ast::expr =>
		append(items, text(", "))!;
		append(items, build_expr_doc(e, bc))!;
	};
	append(items, text(")"))!;
	return concat(items);
};

fn build_append_insert(e: *ast::expr, bc: *build_ctx) doc = {
	let items: []doc = [];
	const inner: *ast::append_expr = match (e.expr) {
	case let a: ast::append_expr =>
		if (a.is_static) append(items, text("static "))!;
		append(items, text("append"))!;
		yield &a;
	case let a: ast::insert_expr =>
		if (a.is_static) append(items, text("static "))!;
		append(items, text("insert"))!;
		yield &a;
	case => abort();
	};
	append(items, text("("))!;
	append(items, build_expr_doc(inner.object, bc))!;
	append(items, text(", "))!;
	append(items, build_expr_doc(inner.value, bc))!;
	if (inner.variadic) {
		append(items, text("..."))!;
	};
	match (inner.length) {
	case null => void;
	case let l: *ast::expr =>
		append(items, text(", "))!;
		append(items, build_expr_doc(l, bc))!;
	};
	append(items, text(")"))!;
	return concat(items);
};

fn build_assert_expr(a: *ast::assert_expr, bc: *build_ctx) doc = {
	let items: []doc = [];
	if (a.is_static) append(items, text("static "))!;

	let opener: str = "abort(";
	let arg_count: size = 0;
	match (a.cond) {
	case *ast::expr =>
		opener = "assert(";
		arg_count += 1;
	case null => void;
	};
	match (a.message) {
	case *ast::expr =>
		arg_count += 1;
	case null => void;
	};

	let inner: []doc = [];
	append(inner, line(""))!;
	match (a.cond) {
	case let c: *ast::expr =>
		append(inner, build_expr_doc(c, bc))!;
	case null => void;
	};
	match (a.message) {
	case let m: *ast::expr =>
		match (a.cond) {
		case let c: *ast::expr =>
			append(inner, text(","))!;
			append(inner, line(" "))!;
		case null => void;
		};
		append(inner, build_expr_doc(m, bc))!;
	case null => void;
	};
	// Note: Hare's grammar for `assert(cond, message)` and
	// `abort(message)` does NOT accept a trailing comma after the
	// last argument, even when the call is broken across lines —
	// unlike regular function calls. Don't emit `if_broken(",")`
	// here.
	let g_items: []doc = [];
	append(g_items, text(opener))!;
	append(g_items, nest(1, concat(inner)))!;
	append(g_items, line(""))!;
	append(g_items, text(")"))!;
	append(items, group(g_items))!;
	_ = arg_count;
	return concat(items);
};

fn build_assign_expr(a: *ast::assign_expr, bc: *build_ctx) doc = {
	let items: []doc = [];
	match (a.object) {
	case null =>
		append(items, text("_"))!;
	case let e: *ast::expr =>
		append(items, build_expr_doc(e, bc))!;
	};
	const op_str = match (a.op) {
	case void =>
		yield "=";
	case let op: binarithm_op =>
		yield assign_op_str(op);
	};
	append(items, text(" "))!;
	append(items, text(op_str))!;
	append(items, build_init_value_doc(a.value, bc))!;
	return concat(items);
};

fn assign_op_str(op: binarithm_op) str = {
	switch (op) {
	case binarithm_op::BAND =>
		return "&=";
	case binarithm_op::LAND =>
		return "&&=";
	case binarithm_op::BOR =>
		return "|=";
	case binarithm_op::LOR =>
		return "||=";
	case binarithm_op::DIV =>
		return "/=";
	case binarithm_op::LSHIFT =>
		return "<<=";
	case binarithm_op::MINUS =>
		return "-=";
	case binarithm_op::MODULO =>
		return "%=";
	case binarithm_op::PLUS =>
		return "+=";
	case binarithm_op::RSHIFT =>
		return ">>=";
	case binarithm_op::TIMES =>
		return "*=";
	case binarithm_op::BXOR =>
		return "^=";
	case binarithm_op::LXOR =>
		return "^^=";
	case => abort("non-assignable op");
	};
};

fn binarithm_op_str(op: binarithm_op) str = {
	switch (op) {
	case binarithm_op::BAND =>
		return "&";
	case binarithm_op::BOR =>
		return "|";
	case binarithm_op::DIV =>
		return "/";
	case binarithm_op::GT =>
		return ">";
	case binarithm_op::GTEQ =>
		return ">=";
	case binarithm_op::LAND =>
		return "&&";
	case binarithm_op::LEQUAL =>
		return "==";
	case binarithm_op::LESS =>
		return "<";
	case binarithm_op::LESSEQ =>
		return "<=";
	case binarithm_op::LOR =>
		return "||";
	case binarithm_op::LSHIFT =>
		return "<<";
	case binarithm_op::LXOR =>
		return "^^";
	case binarithm_op::MINUS =>
		return "-";
	case binarithm_op::MODULO =>
		return "%";
	case binarithm_op::NEQUAL =>
		return "!=";
	case binarithm_op::PLUS =>
		return "+";
	case binarithm_op::RSHIFT =>
		return ">>";
	case binarithm_op::TIMES =>
		return "*";
	case binarithm_op::BXOR =>
		return "^";
	};
};

fn binprec(op: binarithm_op) uint = {
	switch (op) {
	case binarithm_op::DIV, binarithm_op::MODULO, binarithm_op::TIMES =>
		return 10;
	case binarithm_op::MINUS, binarithm_op::PLUS =>
		return 9;
	case binarithm_op::LSHIFT, binarithm_op::RSHIFT =>
		return 8;
	case binarithm_op::BAND =>
		return 7;
	case binarithm_op::BXOR =>
		return 6;
	case binarithm_op::BOR =>
		return 5;
	case binarithm_op::GT,
	binarithm_op::GTEQ,
	binarithm_op::LESS,
	binarithm_op::LESSEQ =>
		return 4;
	case binarithm_op::LEQUAL, binarithm_op::NEQUAL =>
		return 3;
	case binarithm_op::LAND =>
		return 2;
	case binarithm_op::LXOR =>
		return 1;
	case binarithm_op::LOR =>
		return 0;
	};
};

fn build_binarithm_expr(
	b: *ast::binarithm_expr,
	bc: *build_ctx,
	parent_prec: uint,
) doc = {
	const prec = binprec(b.op);
	let items: []doc = [];
	const need_outer_parens = prec < parent_prec;
	if (need_outer_parens) append(items, text("("))!;

	// Only the lowest-precedence operators (`&&`, `||`, `^^`) get a
	// soft break point AFTER the operator; arithmetic, shift, and
	// comparison operators stay on one line, since wrapping a
	// `len(id) >\n\t0` mid-comparison is uglier than letting the
	// line run a few cols past 80. Logical chains commonly span
	// lines (e.g. `if (a && b &&\n\t\tc && d)`) so they keep their
	// soft break.
	const sep: doc = if (prec <= binprec_lor()) line(" ") else text(" ");
	append(items, build_binexpr_operand(b.lvalue, bc, prec))!;
	append(items, text(" "))!;
	append(items, text(binarithm_op_str(b.op)))!;
	append(items, sep)!;
	append(items, build_binexpr_operand(b.rvalue, bc, prec))!;

	if (need_outer_parens) {
		append(items, text(")"))!;
		return concat(items);
	};
	if (prec <= binprec_lor()) return group(items);
	return concat(items);
};

// The precedence of `&&` (the lowest non-logical-XOR boolean).
// Anything at this precedence or below gets a soft-break inside
// `build_binarithm_expr`; everything above stays on one line.
fn binprec_lor() uint = 2;

fn build_binexpr_operand(
	e: *ast::expr,
	bc: *build_ctx,
	parent_prec: uint,
) doc = {
	match (e.expr) {
	case let b: ast::binarithm_expr =>
		return build_binarithm_expr(&b, bc, parent_prec);
	case =>
		const needs_parens = !is_cast(e);
		if (!needs_parens) return build_expr_doc(e, bc);
		let items: []doc = [];
		append(items, text("("))!;
		append(items, build_expr_doc(e, bc))!;
		append(items, text(")"))!;
		return concat(items);
	};
};

fn build_binding_expr(b: *ast::binding_expr, bc: *build_ctx, op: str) doc = {
	let items: []doc = [];
	if (b.is_static) append(items, text("static "))!;
	switch (b.kind) {
	case ast::binding_kind::DEF =>
		append(items, text("def "))!;
	case ast::binding_kind::CONST =>
		append(items, text("const "))!;
	case ast::binding_kind::LET =>
		append(items, text("let "))!;
	};
	for (let i = 0z; i < len(b.bindings); i += 1) {
		const bi = b.bindings[i];
		switch (len(bi.names)) {
		case 0 =>
			append(items, text("_"))!;
		case 1 =>
			append(items, text(bi.names[0]))!;
		case =>
			append(items, text("("))!;
			for (let j = 0z; j < len(bi.names); j += 1) {
				const n = bi.names[j];
				append(items, text(if (n == "") "_" else n))!;
				if (j + 1 < len(bi.names)) {
					append(items, text(", "))!;
				};
			};
			append(items, text(")"))!;
		};
		match (bi._type) {
		case let t: *ast::_type =>
			append(items, text(": "))!;
			if (type_has_const_prefix(bc, t.loc)) {
				append(items, text("const "))!;
			};
			append(items, build_type_doc(t, bc))!;
		case null => void;
		};
		append(items, text(" "))!;
		append(items, text(op))!;
		if (op == "=") {
			append(items, build_init_value_doc(bi.init, bc))!;
		} else {
			append(items, text(" "))!;
			append(items, build_expr_doc(bi.init, bc))!;
		};
		if (i + 1 < len(b.bindings)) {
			append(items, text(", "))!;
		};
	};
	return concat(items);
};

fn build_break_yield(
	keyword: str,
	by: *ast::break_yield,
	bc: *build_ctx,
) doc = {
	let items: []doc = [];
	append(items, text(keyword))!;
	if (by.label != "") {
		append(items, text(" :"))!;
		append(items, text(by.label))!;
	};
	match (by.value) {
	case null => void;
	case let v: *ast::expr =>
		if (by.label != "") {
			append(items, text(","))!;
		};
		append(items, text(" "))!;
		append(items, build_expr_doc(v, bc))!;
	};
	return concat(items);
};

fn build_call_expr(c: *ast::call_expr, bc: *build_ctx) doc = {
	let items: []doc = [];
	const np = !is_postfix(c.lvalue);
	if (np) append(items, text("("))!;
	append(items, build_expr_doc(c.lvalue, bc))!;
	if (np) append(items, text(")"))!;

	if (len(c.args) == 0 && !c.variadic) {
		append(items, text("()"))!;
		return concat(items);
	};

	// Pack arguments into fill mode so when the call doesn't fit
	// on a single line, args wrap greedily (as many per line as fit
	// at indent + 1) instead of being forced one-per-line. When the
	// outer group decides to break, a softline before `)` puts the
	// closing paren on its own line at the call's outer indent -
	// this gives the trailing arg a clean line and avoids cases
	// where `arg)?;` would push past 80 cols.
	//
	// Variadic spreads (`fn(a, b, args...)`) glue the trailing
	// `...` directly onto the last argument with no space and no
	// leading comma, so the last arg + `...` are folded into a
	// single fill content item. Variadic spread also suppresses the
	// trailing comma in broken mode (it would be a syntax error).
	let fill_items: []doc = [];
	for (let i = 0z; i < len(c.args); i += 1) {
		let arg_pieces: []doc = [];
		append(arg_pieces, build_expr_doc(c.args[i], bc))!;
		const is_last = i + 1 == len(c.args);
		if (is_last && c.variadic) {
			append(arg_pieces, text("..."))!;
		} else if (!is_last) {
			append(arg_pieces, text(","))!;
		};
		append(fill_items, concat(arg_pieces))!;
		if (!is_last) {
			append(fill_items, line(" "))!;
		};
	};

	let nested_items: []doc = [];
	append(nested_items, line(""))!;
	append(nested_items, fill(fill_items))!;
	if (!c.variadic) {
		append(nested_items, if_broken(","))!;
	};

	let g_items: []doc = [];
	append(g_items, text("("))!;
	append(g_items, nest(1, concat(nested_items)))!;
	append(g_items, line(""))!;
	append(g_items, text(")"))!;
	append(items, group(g_items))!;
	return concat(items);
};

fn build_cast_expr(c: *ast::cast_expr, bc: *build_ctx) doc = {
	let items: []doc = [];
	const np = !is_cast(c.value);
	if (np) append(items, text("("))!;
	append(items, build_expr_doc(c.value, bc))!;
	if (np) append(items, text(")"))!;
	switch (c.kind) {
	case ast::cast_kind::CAST =>
		append(items, text(": "))!;
	case ast::cast_kind::ASSERTION =>
		append(items, text(" as "))!;
	case ast::cast_kind::TEST =>
		append(items, text(" is "))!;
	};
	if (type_has_const_prefix(bc, c._type.loc)) {
		append(items, text("const "))!;
	};
	append(items, build_type_doc(c._type, bc))!;
	return concat(items);
};

fn build_for_expr(f: *ast::for_expr, bc: *build_ctx) doc = {
	let items: []doc = [];
	append(items, text("for "))!;
	if (f.label != "") {
		append(items, text(":"))!;
		append(items, text(f.label))!;
		append(items, text(" "))!;
	};
	append(items, text("("))!;

	const op = switch (f.kind) {
	case ast::for_kind::ACCUMULATOR =>
		yield "=";
	case ast::for_kind::EACH_VALUE =>
		yield "..";
	case ast::for_kind::EACH_POINTER =>
		yield "&..";
	case ast::for_kind::ITERATOR =>
		yield "=>";
	};

	match (f.bindings) {
	case let b: *ast::expr =>
		const be = b.expr as ast::binding_expr;
		append(items, build_binding_expr(&be, bc, op))!;
		if (f.kind == ast::for_kind::ACCUMULATOR) {
			append(items, text("; "))!;
		};
	case null => void;
	};

	if (f.kind == ast::for_kind::ACCUMULATOR) {
		append(items, build_expr_doc(f.cond as *ast::expr, bc))!;
		match (f.afterthought) {
		case null => void;
		case let e: *ast::expr =>
			append(items, text("; "))!;
			append(items, build_expr_doc(e, bc))!;
		};
	};
	append(items, text(") "))!;
	append(items, build_expr_doc(f.body, bc))!;
	match (f.else_branch) {
	case let e: *ast::expr =>
		append(items, text(" else "))!;
		append(items, build_expr_doc(e, bc))!;
	case => void;
	};
	return concat(items);
};

fn build_if_expr(i: *ast::if_expr, bc: *build_ctx) doc = {
	// `if (cond) tbranch else fbranch` — fits flat as one line, or
	// breaks to:
	//
	//     if (cond)
	//             tbranch
	//     else
	//             fbranch
	//
	// Compound `{ ... }` branches always inline with the keyword,
	// since the compound itself wraps its contents.
	let items: []doc = [];
	append(items, text("if ("))!;
	append(items, build_expr_doc(i.cond, bc))!;
	append(items, text(")"))!;

	const tbranch_compound = i.tbranch.expr is ast::compound_expr;

	let body_inner: []doc = [];
	if (tbranch_compound) {
		append(body_inner, text(" "))!;
		append(body_inner, build_expr_doc(i.tbranch, bc))!;
	} else {
		// Wrap the leading line+body as a single nested unit so
		// that, in broken mode, the line-break indents the body
		// one level past `if`. Nesting only the body would leave
		// the break itself at the outer indent.
		let tb: []doc = [];
		append(tb, line(" "))!;
		append(tb, build_expr_doc(i.tbranch, bc))!;
		append(body_inner, nest(1, concat(tb)))!;
	};

	match (i.fbranch) {
	case null => void;
	case let e: *ast::expr =>
		const else_compound = e.expr is ast::compound_expr;
		const else_if = e.expr is ast::if_expr;
		if (tbranch_compound) {
			append(body_inner, text(" else"))!;
		} else {
			append(body_inner, line(" "))!;
			append(body_inner, text("else"))!;
		};
		if (else_compound || else_if) {
			append(body_inner, text(" "))!;
			append(body_inner, build_expr_doc(e, bc))!;
		} else {
			let fb: []doc = [];
			append(fb, line(" "))!;
			append(fb, build_expr_doc(e, bc))!;
			append(body_inner, nest(1, concat(fb)))!;
		};
	};

	append(items, group(body_inner))!;
	return concat(items);
};

fn build_match_expr(
	m: *ast::match_expr,
	loc: ast::location,
	bc: *build_ctx,
) doc = {
	let outer: []doc = [];
	append(outer, text("match "))!;
	if (m.label != "") {
		append(outer, text(":"))!;
		append(outer, text(m.label))!;
		append(outer, text(" "))!;
	};
	append(outer, text("("))!;
	append(outer, build_expr_doc(m.value, bc))!;
	append(outer, text(") {"))!;

	let inner: []doc = [];
	for (let i = 0z; i < len(m.cases); i += 1) {
		append(inner, hardline())!;
		const cs = &m.cases[i];
		append(inner, text("case"))!;
		if (len(cs.name) > 0) {
			append(inner, text(" let "))!;
			append(inner, text(cs.name))!;
		};
		match (cs._type) {
		case let t: *ast::_type =>
			if (len(cs.name) > 0) {
				append(inner, text(":"))!;
			};
			append(inner, text(" "))!;
			if (type_has_const_prefix(bc, t.loc)) {
				append(inner, text("const "))!;
			};
			append(inner, build_type_doc(t, bc))!;
		case null => void;
		};
		append(inner, text(" =>"))!;
		append(inner, build_case_exprs(cs.exprs, bc))!;
		// Flush any trailing comments inside this case body (e.g.
		// `case => abort(); // unreachable`) before moving on.
		// Boundary is the next case's start, or - for the last
		// case - the byte before the closing `}`.
		const boundary = if (i + 1 <
		len(m.cases)) case_boundary_match(&m.cases[i + 1]) else loc.end.off: size;
		const _ = push_comments_before(&inner, bc.c, boundary);
	};

	// Per the Hare style guide, `case` labels align with the `match`
	// keyword's column - they are NOT nested inside the braces. The
	// case bodies (after `=>`) get indented one level deeper, which
	// `build_case_exprs` handles via its own `nest(1, ...)` wrapper.
	append(outer, concat(inner))!;
	append(outer, hardline())!;
	append(outer, text("}"))!;
	return concat(outer);
};

// Best-effort byte offset for the start of a match case. The match
// case AST has no loc of its own, so we approximate using the first
// available child loc - the binding type, then the first body expr.
// Returns 0 (no flush) when nothing usable is reachable.
fn case_boundary_match(cs: *ast::match_case) size = {
	match (cs._type) {
	case let t: *ast::_type =>
		return t.loc.start.off: size;
	case null => void;
	};
	if (len(cs.exprs) > 0) return cs.exprs[0].loc.start.off: size;
	return 0z;
};

fn build_switch_expr(
	s: *ast::switch_expr,
	loc: ast::location,
	bc: *build_ctx,
) doc = {
	let outer: []doc = [];
	append(outer, text("switch "))!;
	if (s.label != "") {
		append(outer, text(":"))!;
		append(outer, text(s.label))!;
		append(outer, text(" "))!;
	};
	append(outer, text("("))!;
	append(outer, build_expr_doc(s.value, bc))!;
	append(outer, text(") {"))!;

	let inner: []doc = [];
	for (let i = 0z; i < len(s.cases); i += 1) {
		append(inner, hardline())!;
		const cs = &s.cases[i];
		append(inner, text("case"))!;
		if (len(cs.options) == 0) {
			append(inner, text(" =>"))!;
		} else {
			let opts: []doc = [];
			append(opts, text(" "))!;
			for (let j = 0z; j < len(cs.options); j += 1) {
				append(opts, build_expr_doc(cs.options[j], bc))!;
				if (j + 1 < len(cs.options)) {
					append(opts, text(","))!;
					append(opts, line(" "))!;
				};
			};
			append(opts, text(" =>"))!;
			append(inner, group(opts))!;
		};
		append(inner, build_case_exprs(cs.exprs, bc))!;
		// See the matching comment in `build_match_expr`. Flush
		// trailing case-body comments (e.g. `case => abort(); //
		// unreachable`) at each case boundary or before `}`.
		const boundary = if (i + 1 <
		len(s.cases)) case_boundary_switch(&s.cases[i + 1]) else loc.end.off: size;
		const _ = push_comments_before(&inner, bc.c, boundary);
	};

	// `case` labels align with the `switch` keyword's column - see
	// the matching comment in `build_match_expr`.
	append(outer, concat(inner))!;
	append(outer, hardline())!;
	append(outer, text("}"))!;
	return concat(outer);
};

fn case_boundary_switch(cs: *ast::switch_case) size = {
	if (len(cs.options) > 0) return cs.options[0].loc.start.off: size;
	if (len(cs.exprs) > 0) return cs.exprs[0].loc.start.off: size;
	return 0z;
};

fn build_case_exprs(exprs: []*ast::expr, bc: *build_ctx) doc = {
	// Special case: a single `void;` or `abort(...)` stays inline
	// after `=>`, matching the style guide / unparse behavior.
	if (len(exprs) == 1) {
		match (exprs[0].expr) {
		case let e: ast::assert_expr =>
			if (e.cond == null) {
				let items: []doc = [];
				append(items, text(" "))!;
				append(items, build_assert_expr(&e, bc))!;
				append(items, text(";"))!;
				return concat(items);
			};
		case let p: ast::plain_literal =>
			if (p.storage == ast::builtin_type::VOID) {
				return text(" void;");
			};
		case => void;
		};
	};
	let inner: []doc = [];
	for (let i = 0z; i < len(exprs); i += 1) {
		append(inner, hardline())!;
		// Flush comments that live BEFORE this case-body
		// expression in the source. Without this, a comment
		// like `case X =>\n\t// note\n\tbody;` would leave the
		// `// note` in the cursor and it would be re-emitted at
		// the next match boundary - past the closing `}`,
		// detached from the code it documents.
		const _ = push_comments_before(
			&inner,
			bc.c,
			exprs[i].loc.start.off: size,
		);
		append(inner, build_expr_doc(exprs[i], bc))!;
		append(inner, text(";"))!;
		const next_off = if (i + 1 <
			len(exprs)) exprs[i + 1].loc.start.off: size
			else ~0z;
		flush_trailing_comments_to_eol(&inner, bc.c, next_off,
			exprs[i].loc.end.off: size, bc.data);
	};
	return nest(1, concat(inner));
};

fn build_unarithm_expr(u: *ast::unarithm_expr, bc: *build_ctx) doc = {
	let items: []doc = [];
	const op_str = switch (u.op) {
	case ast::unarithm_op::ADDR =>
		yield "&";
	case ast::unarithm_op::BNOT =>
		yield "~";
	case ast::unarithm_op::DEREF =>
		yield "*";
	case ast::unarithm_op::LNOT =>
		yield "!";
	case ast::unarithm_op::MINUS =>
		yield "-";
	};
	append(items, text(op_str))!;
	const needs_parens = match (u.operand.expr) {
	case let inner: ast::unarithm_expr =>
		yield u.op == ast::unarithm_op::ADDR && inner.op == u.op;
	case =>
		yield !is_unary(u.operand);
	};
	if (needs_parens) append(items, text("("))!;
	append(items, build_expr_doc(u.operand, bc))!;
	if (needs_parens) append(items, text(")"))!;
	return concat(items);
};

fn build_slice_expr(s: *ast::slice_expr, bc: *build_ctx) doc = {
	let items: []doc = [];
	const np = !is_postfix(s.object);
	if (np) append(items, text("("))!;
	append(items, build_expr_doc(s.object, bc))!;
	if (np) append(items, text(")"))!;
	append(items, text("["))!;
	match (s.start) {
	case null => void;
	case let e: *ast::expr =>
		append(items, build_expr_doc(e, bc))!;
	};
	append(items, text(".."))!;
	match (s.end) {
	case null => void;
	case let e: *ast::expr =>
		append(items, build_expr_doc(e, bc))!;
	};
	append(items, text("]"))!;
	return concat(items);
};

fn build_variadic_expr(v: ast::variadic_expr, bc: *build_ctx) doc = {
	match (v) {
	case ast::vastart_expr =>
		return text("vastart()");
	case let va: ast::vaarg_expr =>
		let items: []doc = [];
		append(items, text("vaarg("))!;
		append(items, build_expr_doc(va.ap, bc))!;
		append(items, text(", "))!;
		append(items, build_type_doc(va._type, bc))!;
		append(items, text(")"))!;
		return concat(items);
	case let ve: ast::vaend_expr =>
		let items: []doc = [];
		append(items, text("vaend("))!;
		append(items, build_expr_doc(ve, bc))!;
		append(items, text(")"))!;
		return concat(items);
	};
};

fn build_literal_expr(
	l: ast::literal_expr,
	loc: ast::location,
	bc: *build_ctx,
) doc = {
	// For literals we can't easily reproduce upstream's escape /
	// formatting code without copying it, so render via unparse and
	// wrap as flat text. Inner expressions inside array / struct /
	// tuple literals could in principle wrap, but for v0 leaving
	// them flat keeps behavior parity.
	//
	// The hare::ast AST throws away whether a string literal was
	// originally written as a backtick raw string or a quoted
	// string. To preserve fidelity (raw strings can contain
	// newlines and characters that would need escaping in quoted
	// form, blowing up line lengths), we peek at the source bytes
	// at the literal's location to recover the lexical form.
	match (l) {
	case let p: ast::plain_literal =>
		if (p.storage == ast::builtin_type::STR) {
			// For STRING literals, prefer the verbatim source text over
			// upstream's `unparse` rendering. The upstream renderer
			// only escapes `\` and `"` — not `\r`, `\n`, `\t`, etc. —
			// so a literal containing escape sequences round-trips
			// through `unparse` as raw bytes inside `"..."`, breaking
			// any file that uses things like "\r\n". This also
			// preserves the original lexical form: backtick raw
			// strings stay as raw strings, adjacent concatenated
			// literals stay concatenated, etc.
			match (verbatim_string_at(bc, loc)) {
			case let s: str =>
				return text(s);
			case void => void;
			};
		};
		if (is_numeric_or_rune_storage(p.storage)) {
			// Numeric and rune literals: preserve the user's chosen
			// base, digit grouping, suffix, and escape form. `unparse`
			// would normalize 0x80 -> 128, 0o755 -> 493, 1_000_000 ->
			// 1000000, etc.
			match (verbatim_token_at(bc, loc)) {
			case let s: str =>
				return text(s);
			case void => void;
			};
		};
		return text(render_literal(l));
	case let a: ast::array_literal =>
		return build_array_literal(&a, loc, bc);
	case let s: ast::struct_literal =>
		return build_struct_literal(&s, loc, bc);
	case let t: ast::tuple_literal =>
		return build_tuple_literal(t, loc, bc);
	};
};

// Returns true iff the source bytes immediately before `loc.start`
// are the keyword `const ` (ignoring intervening whitespace). Used
// to recover the `const` modifier on return types — `hare::parse`
// consumes the keyword but throws it away (see hare/parse/type.ha
// `_type`, which calls `try(lexer, ltok::CONST)?;` and never stores
// the result).
fn type_has_const_prefix(bc: *build_ctx, loc: ast::location) bool = {
	const start = loc.start.off: size;
	if (start < 6) return false;
	// Walk backwards through whitespace to find the previous non-
	// whitespace byte run.
	let i = start;
	for (i > 0; i -= 1) {
		const b = bc.data[i - 1];
		if (b != ' ': u8 && b != '\t': u8 && b != '\n': u8) break;
	};
	if (i < 5) return false;
	const candidate = bc.data[i - 5..i];
	if (candidate[0] != 'c': u8) return false;
	if (candidate[1] != 'o': u8) return false;
	if (candidate[2] != 'n': u8) return false;
	if (candidate[3] != 's': u8) return false;
	if (candidate[4] != 't': u8) return false;
	// Make sure `const` is its own token — preceding char must be
	// whitespace, `(`, `,`, or `=`. Otherwise we'd match identifiers
	// like `xconst`.
	if (i == 5) return true;
	const before = bc.data[i - 6];
	return before == ' ': u8 || before == '\t': u8 || before == '\n': u8 ||
	before == '(': u8 ||
	before == ',': u8 ||
	before == '=': u8;
};

// Returns the verbatim source text of a string literal at `loc`,
// preserving the lexical form (backtick raw-string vs `"..."` quoted,
// adjacent concatenated segments) and any escape sequences exactly
// as the user wrote them. Returns void if the location doesn't
// actually point at a string literal start (defensive guard against
// AST/source desynchronization).
//
// Hare's string lexer concatenates ADJACENT string literals
// (e.g. `"foo" "bar"` becomes a single token), so the byte range
// [start, end] may span MULTIPLE delimited segments. We walk the
// entire span and capture every segment verbatim along with the
// whitespace between them.
fn verbatim_string_at(bc: *build_ctx, loc: ast::location) (str | void) = {
	const data = bc.data;
	const start = loc.start.off: size;
	// loc.end.off is the byte offset of the LAST byte of the literal
	// (inclusive); +1 turns it into an exclusive end suitable for
	// slicing.
	const end = loc.end.off: size + 1;
	if (start >= len(data) || end > len(data) || end <= start) {
		return;
	};
	const first = data[start];
	if (first != '`': u8 && first != '"': u8) return;
	// Walk to end of first segment.
	let close = end_first_string_segment(data, start);
	if (close >= len(data)) return;
	// If end loc only covers this one segment, return just it.
	if (close + 1 >= end) {
		return strings::dup(strings::fromutf8(data[start..close + 1])!)!;
	};
	// Concatenated strings — extend through every adjacent segment
	// the AST's loc.end covers.
	let final_close = close;
	let i = close + 1;
	for (i < end) {
		for (i < end &&
		(data[i] == ' ': u8 || data[i] == '\t': u8 ||
		data[i] == '\n': u8); i += 1) void;
		if (i >= end) break;
		const delim = data[i];
		if (delim != '`': u8 && delim != '"': u8) break;
		const nclose = end_first_string_segment(data, i);
		if (nclose >= end) break;
		final_close = nclose;
		i = nclose + 1;
	};
	return strings::dup(strings::fromutf8(data[start..final_close + 1])!)!;
};

// Returns true if `s` is a builtin storage type whose source form
// carries information `hare::unparse` would lose - integer base
// (0x/0o/0b), digit grouping (1_000), explicit suffix (100u8), float
// representation (1.0 vs 1.0f64), or rune escape form ('\n' vs '\x0a').
fn is_numeric_or_rune_storage(s: ast::builtin_type) bool = {
	switch (s) {
	case ast::builtin_type::INT,
	ast::builtin_type::I8,
	ast::builtin_type::I16,
	ast::builtin_type::I32,
	ast::builtin_type::I64,
	ast::builtin_type::SIZE,
	ast::builtin_type::UINT,
	ast::builtin_type::U8,
	ast::builtin_type::U16,
	ast::builtin_type::U32,
	ast::builtin_type::U64,
	ast::builtin_type::UINTPTR,
	ast::builtin_type::F32,
	ast::builtin_type::F64,
	ast::builtin_type::RUNE,
	ast::builtin_type::ICONST,
	ast::builtin_type::FCONST,
	ast::builtin_type::RCONST =>
		return true;
	// Untyped (suffix-less) integer / float / rune literals
	// land here; they're the common case (`0x80`, `1.5`,
	// `'a'` all parse as the *CONST variant unless an
	// explicit suffix or context-required type narrows them).

	case =>
		return false;
	};
};

// Returns true if the source bytes between the opening delimiter
// (`{`, `[`, or `(`) at or after `loc.start.off` and the first
// non-whitespace byte after it contain a `\n`. Mirrors prettier's
// "magic newline" heuristic: if the user wrote the container's
// opening brace on its own line, treat that as an explicit request
// to keep the container expanded across multiple lines even when
// the contents would fit inline.
//
// `open_chars` is the set of byte values that count as the opening
// delimiter (e.g. `['{': u8]` for struct literals). The scan starts
// at `loc.start.off` and walks forward until one of those bytes is
// found; everything before is treated as the type alias / keyword
// prefix. Returns false if no opening delimiter is found within
// `loc`'s range or if the next non-whitespace byte after it is
// reached without seeing a `\n`.
fn source_opens_multiline(
	bc: *build_ctx,
	loc: ast::location,
	open_chars: []u8,
) bool = {
	const data = bc.data;
	const start = loc.start.off: size;
	const end = loc.end.off: size + 1;
	if (start >= len(data) || end > len(data) || end <= start) {
		return false;
	};
	let i = start;
	for (i < end) {
		const b = data[i];
		let is_open = false;
		for (let j = 0z; j < len(open_chars); j += 1) {
			if (b == open_chars[j]) {
				is_open = true;
				break;
			};
		};
		if (is_open) break;
		i += 1;
	};
	if (i >= end) return false;
	i += 1;
	for (i < end) {
		const b = data[i];
		if (b == '\n': u8) return true;
		if (b != ' ': u8 && b != '\t': u8) return false;
		i += 1;
	};
	return false;
};

// Returns the verbatim source bytes covered by `loc`, or void if the
// loc is out of range. Used for non-string literals (numbers, runes)
// where we want to preserve the user's chosen lexical form rather
// than re-emit through `hare::unparse`.
//
// `loc.end.off` is reported INCLUSIVELY for some node kinds (a const
// init at `... = 1;` has start=end pointing at `1`) and EXCLUSIVELY
// for others (a switch case option `case 1 =>` has end one byte
// past the `1`). To avoid pulling stray trailing whitespace into the
// captured token in the latter case, trim any trailing space/tab/
// newline before returning - numbers and runes never legitimately
// end in whitespace.
fn verbatim_token_at(bc: *build_ctx, loc: ast::location) (str | void) = {
	const data = bc.data;
	const start = loc.start.off: size;
	let end = loc.end.off: size + 1;
	if (start >= len(data) || end > len(data) || end <= start) return;
	for (end > start + 1) {
		const b = data[end - 1];
		if (b != ' ': u8 && b != '\t': u8 && b != '\n': u8) break;
		end -= 1;
	};
	return strings::dup(strings::fromutf8(data[start..end])!)!;
};

// Given a byte offset of the opening delimiter of a string literal
// (` or "), returns the offset of the matching closing delimiter.
// Quoted strings honor `\\` escape sequences; raw strings don't.
// Returns `len(data)` if the literal is unterminated (which would
// mean the source is malformed; should not happen on parse-clean
// input).
fn end_first_string_segment(data: []u8, start: size) size = {
	const delim = data[start];
	let i = start + 1;
	for (i < len(data) && data[i] != delim; i += 1) {
		if (delim == '"': u8 && data[i] == '\\': u8 && i + 1 < len(data)) {
			i += 1;
		};
	};
	return i;
};

fn build_array_literal(
	a: *ast::array_literal,
	loc: ast::location,
	bc: *build_ctx,
) doc = {
	const force_break = source_opens_multiline(bc, loc, ['[': u8]);
	let inner: []doc = [];
	append(inner, leading_softline(force_break, ""))!;
	for (let i = 0z; i < len(a.values); i += 1) {
		append(inner, build_expr_doc(a.values[i], bc))!;
		if (i + 1 < len(a.values)) {
			append(inner, text(","))!;
			append(inner, line(" "))!;
		};
	};
	if (a.expand) {
		append(inner, text("..."))!;
	};
	if (len(a.values) > 0 && !a.expand) {
		append(inner, if_broken(","))!;
	};

	let g_items: []doc = [];
	append(g_items, text("["))!;
	append(g_items, nest(1, concat(inner)))!;
	append(g_items, line(""))!;
	append(g_items, text("]"))!;
	return group(g_items);
};

fn build_tuple_literal(
	t: ast::tuple_literal,
	loc: ast::location,
	bc: *build_ctx,
) doc = {
	const force_break = source_opens_multiline(bc, loc, ['(': u8]);
	let inner: []doc = [];
	append(inner, leading_softline(force_break, ""))!;
	for (let i = 0z; i < len(t); i += 1) {
		append(inner, build_expr_doc(t[i], bc))!;
		if (i + 1 < len(t)) {
			append(inner, text(","))!;
			append(inner, line(" "))!;
		};
	};
	if (len(t) > 0) {
		append(inner, if_broken(","))!;
	};

	let g_items: []doc = [];
	append(g_items, text("("))!;
	append(g_items, nest(1, concat(inner)))!;
	append(g_items, line(""))!;
	append(g_items, text(")"))!;
	return group(g_items);
};

// Returns the leading separator inside a container body. When
// `force_break` is true (the source opened the container with a
// trailing newline after `{`/`[`/`(`), emit a `hardline()` so the
// enclosing group renders broken even if the contents would fit.
// Otherwise emit the usual softline. `flat_text` is what the softline
// renders as in flat mode (`""` for `[]`/`()` containers, `" "` for
// `{}` containers per the Hare style guide).
fn leading_softline(force_break: bool, flat_text: str) doc = {
	if (force_break) return hardline();
	return line(flat_text);
};

fn build_struct_literal(
	s: *ast::struct_literal,
	loc: ast::location,
	bc: *build_ctx,
) doc = {
	let outer: []doc = [];
	if (len(s.alias) > 0) {
		append(outer, text(render_ident(s.alias)))!;
	} else {
		append(outer, text("struct"))!;
	};
	append(outer, text(" {"))!;

	// Softline-separated members so a small struct literal can
	// render as `point { x = 1, y = 2 }` on a single line. The
	// trailing autofill / undefined markers (`...`, `@undefined...`)
	// stay attached to the field list with the same softline spacing.
	const force_break = source_opens_multiline(bc, loc, ['{': u8]);
	let inner: []doc = [];
	append(inner, leading_softline(force_break, " "))!;
	for (let i = 0z; i < len(s.fields); i += 1) {
		match (s.fields[i]) {
		case let v: ast::struct_value =>
			append(inner, text(v.name))!;
			match (v._type) {
			case null => void;
			case let t: *ast::_type =>
				append(inner, text(": "))!;
				if (type_has_const_prefix(bc, t.loc)) {
					append(inner, text("const "))!;
				};
				append(inner, build_type_doc(t, bc))!;
			};
			append(inner, text(" = "))!;
			append(inner, build_expr_doc(v.init, bc))!;
		case let nested: *ast::struct_literal =>
			append(inner, build_struct_literal(nested, loc, bc))!;
		// Nested literal: use the parent loc as a stand-in
		// (the AST doesn't expose a per-nested-literal loc
		// here). The magic-newline check will likely return
		// the parent's answer, which is the right default.

		};
		if (i + 1 < len(s.fields)) {
			append(inner, text(","))!;
			append(inner, line(" "))!;
		};
	};
	if (s.undefined) {
		if (len(s.fields) > 0) {
			append(inner, text(","))!;
			append(inner, line(" "))!;
		};
		append(inner, text("@undefined..."))!;
	} else if (s.autofill) {
		if (len(s.fields) > 0) {
			append(inner, text(","))!;
			append(inner, line(" "))!;
		};
		append(inner, text("..."))!;
	} else if (len(s.fields) > 0) {
		append(inner, if_broken(","))!;
	};

	append(outer, nest(1, concat(inner)))!;
	append(outer, line(" "))!;
	append(outer, text("}"))!;
	return group(outer);
};

// ----- Helpers ------------------------------------------------------
// Reuses upstream is_postfix / is_unary / is_cast semantics so we
// emit the same parenthesization unparse does.
fn is_plain(e: *ast::expr) bool = {
	match (e.expr) {
	case ast::literal_expr =>
		return true;
	case ast::access_identifier =>
		return true;
	case =>
		return false;
	};
};

fn is_builtin(e: *ast::expr) bool = {
	if (is_plain(e)) return true;
	match (e.expr) {
	case ast::alloc_expr =>
		return true;
	case ast::assert_expr =>
		return true;
	case ast::variadic_expr =>
		return true;
	case ast::len_expr =>
		return true;
	case ast::align_expr =>
		return true;
	case ast::size_expr =>
		return true;
	case ast::offset_expr =>
		return true;
	case ast::append_expr =>
		return true;
	case ast::insert_expr =>
		return true;
	case =>
		return false;
	};
};

fn is_postfix(e: *ast::expr) bool = {
	if (is_builtin(e)) return true;
	match (e.expr) {
	case ast::call_expr =>
		return true;
	case ast::access_expr =>
		return true;
	case ast::slice_expr =>
		return true;
	case ast::error_assert_expr =>
		return true;
	case ast::propagate_expr =>
		return true;
	case =>
		return false;
	};
};

fn is_unary(e: *ast::expr) bool = {
	if (is_postfix(e)) return true;
	match (e.expr) {
	case ast::compound_expr =>
		return true;
	case ast::match_expr =>
		return true;
	case ast::switch_expr =>
		return true;
	case ast::unarithm_expr =>
		return true;
	case =>
		return false;
	};
};

fn is_cast(e: *ast::expr) bool = {
	return is_unary(e) || e.expr is ast::cast_expr;
};

// Renders a literal (plain / struct) via unparse for the bits whose
// formatting we don't want to re-derive (number suffixes, escape
// sequences, …). The result is always a single line.
fn render_literal(l: ast::literal_expr) str = {
	let buf = memio::dynamic();
	defer match (io::close(&buf)) {
	case => void;
	};
	const wrapper = ast::expr { loc = ast::location { ... }, expr = l };
	match (unparse::expr(&buf, &unparse::syn_nowrap, &wrapper)) {
	case size => void;
	case =>
		return strings::dup("<unparse error>")!;
	};
	return strings::dup(memio::string(&buf)!)!;
};

// Renders an ident as `a::b::c`. Memory: caller must NOT free; the
// returned string is owned by the doc tree and freed with the doc.
fn render_ident(id: ast::ident) str = {
	if (len(id) == 0) return strings::dup("")!;
	if (len(id) == 1) return strings::dup(id[0])!;
	let parts: []str = alloc([], len(id) * 2)!;
	defer free(parts);
	for (let i = 0z; i < len(id); i += 1) {
		append(parts, id[i])!;
		if (i + 1 < len(id)) append(parts, "::")!;
	};
	return strings::concat(parts...)!;
};

// JSON-style escape for a string used inside @symbol("...").
fn escape_str(s: str) str = {
	const result = strings::multireplace(s, (`\`, `\\`), (`"`, `\"`))!;
	return result;
};
