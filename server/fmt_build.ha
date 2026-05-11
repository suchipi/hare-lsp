// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// AST -> doc builder for the comment-preserving formatter.
//
// Scope of this first cut: preserve comments at the places where they
// actually appear in real Hare code — file header, between imports,
// before declarations, between statements inside a function body. The
// inner content of each statement/decl is rendered via the upstream
// hare::unparse module, which gives us behavior parity for everything
// the existing formatter produces today (operator spacing, type
// rendering, literal canonicalization, …) at the cost of not wrapping
// long lines. That parity is what passes the existing test suite.
//
// Multi-line "prettier-style" wrapping per the Hare style guide is a
// follow-up; the doc IR (server/fmt_doc.ha) already supports it via
// `group` / `line` and can be plumbed through incrementally without
// reworking this module's structure.

use hare::ast;
use hare::unparse;
use io;
use memio;
use strings;

// Builds the doc for an entire compilation subunit (a single .ha
// file), interleaving the comments from `c` at the right positions.
// `data_len` is the size of the source bytes; used as the boundary
// for trailing comments after the last decl.
export fn build_subunit_doc(
	su: *ast::subunit,
	c: *comment_cursor,
	data_len: size,
) doc = {
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

	push_comments_before(&items, c, first_off);

	// Imports.
	for (let i = 0z; i < len(su.imports); i += 1) {
		const imp_off = su.imports[i].loc.start.off: size;
		push_comments_before(&items, c, imp_off);
		append(items, text(render_import_str(&su.imports[i])))!;
		append(items, hardline())!;
	};

	// Blank line between imports and decls.
	if (len(su.imports) > 0 && len(su.decls) > 0) {
		append(items, hardline())!;
	};

	// Decls.
	for (let i = 0z; i < len(su.decls); i += 1) {
		const decl_off = su.decls[i].loc.start.off: size;
		push_comments_before(&items, c, decl_off);
		append(items, build_decl_doc(&su.decls[i], c))!;
		append(items, hardline())!;
		if (i + 1 < len(su.decls)) {
			// Blank line between top-level decls.
			append(items, hardline())!;
		};
	};

	// Trailing comments (after the last decl).
	push_comments_before(&items, c, data_len);

	return concat(items);
};

// Builds a doc for a run of consecutive top-level decls (used by
// range formatting). Leading comments before each decl and trailing
// comments inside fn bodies are preserved exactly as in
// build_subunit_doc, but file-header and trailing-EOF comments are
// not emitted — they're outside the range.
//
// `first` and `last` are indices into su.decls[] (both inclusive).
// `c` should be positioned so its cursor points at the first comment
// AT OR AFTER the first decl's start_off (callers can advance it
// with pop_before before calling).
export fn build_decls_range_doc(
	su: *ast::subunit,
	first: size,
	last: size,
	c: *comment_cursor,
) doc = {
	let items: []doc = [];
	for (let i = first; i <= last; i += 1) {
		const decl_off = su.decls[i].loc.start.off: size;
		push_comments_before(&items, c, decl_off);
		append(items, build_decl_doc(&su.decls[i], c))!;
		append(items, hardline())!;
		if (i < last) append(items, hardline())!;
	};
	// Trailing comments INSIDE the last decl's byte range (between
	// its body end and the next decl) are caught above. Comments
	// after the last decl's end belong to whatever comes after, so
	// we leave them in the cursor.
	return concat(items);
};

// Builds the doc for a single top-level decl, recursing into function
// bodies to interleave comments between statements.
export fn build_decl_doc(d: *ast::decl, c: *comment_cursor) doc = {
	match (d.decl) {
	case let f: ast::decl_func =>
		match (f.body) {
		case let body: *ast::expr =>
			return build_decl_func_with_body(d, f, body, c);
		case null =>
			// Forward declaration; let unparse handle it.
			return text(render_decl_str_no_docs(d));
		};
	case =>
		return text(render_decl_str_no_docs(d));
	};
};

// Builds a function declaration with a visible body. The signature is
// rendered via `hare::unparse` (with the body field nulled out so the
// upstream renderer skips it), then we emit the `= { ... }` body
// ourselves so we can splice comments between statements.
fn build_decl_func_with_body(
	d: *ast::decl,
	f: ast::decl_func,
	body: *ast::expr,
	c: *comment_cursor,
) doc = {
	let items: []doc = [];

	// Render `[export] [@attrs] fn name(params) ret` by using a
	// shallow copy of the decl with body=null and docs="". unparse
	// emits a trailing `;` which we strip off.
	const sig_with_semi = render_signature_str(d, f);
	defer free(sig_with_semi);
	const sig = strings::trimsuffix(sig_with_semi, ";");
	append(items, text(sig))!;
	append(items, text(" = "))!;

	// Body. If the body is a compound, format it line-by-line with
	// comment splicing. Otherwise it's a single-expression body
	// (`fn foo() void = bar();`) and unparse handles it fine.
	match (body.expr) {
	case let cmp: ast::compound_expr =>
		append(items, build_compound_body(body, &cmp, c))!;
	case =>
		append(items, text(render_expr_str(body)))!;
	};

	append(items, text(";"))!;
	return concat(items);
};

// Builds a compound expression body `{ stmt1; stmt2; ... }` with
// comments spliced between statements. `body_loc.end.off` bounds the
// region within which a comment counts as "inside this body."
fn build_compound_body(
	body: *ast::expr,
	cmp: *ast::compound_expr,
	c: *comment_cursor,
) doc = {
	let outer: []doc = [];
	append(outer, text("{"))!;

	let inner: []doc = [];
	for (let i = 0z; i < len(cmp.exprs); i += 1) {
		const stmt = cmp.exprs[i];
		const stmt_off = stmt.loc.start.off: size;
		// hardline first to move to the next line at indent + 1.
		append(inner, hardline())!;
		push_comments_before(&inner, c, stmt_off);
		append(inner, text(render_expr_str(stmt)))!;
		append(inner, text(";"))!;
	};
	// Trailing comments inside the body (between last stmt and `}`).
	const body_end = body.loc.end.off: size;
	push_comments_before(&inner, c, body_end);

	append(outer, nest(1, concat(inner)))!;
	append(outer, hardline())!;
	append(outer, text("}"))!;
	return concat(outer);
};

// Appends each pending comment whose start_off < `boundary` to
// `items` as a doc_comment.
fn push_comments_before(
	items: *[]doc,
	c: *comment_cursor,
	boundary: size,
) void = {
	const cs = pop_before(c, boundary);
	for (let i = 0z; i < len(cs); i += 1) {
		let cur = *items;
		append(cur, comment(cs[i].text))!;
		*items = cur;
	};
};

// Renders `*d` via unparse::decl with `docs` cleared (so attached doc
// comments are emitted only by our comment cursor, not by unparse).
fn render_decl_str_no_docs(d: *ast::decl) str = {
	let copy = *d;
	copy.docs = "";
	return unparse_decl_to_str(&copy);
};

// Renders the signature of a function decl by feeding unparse a copy
// with `body = null` and `docs = ""`. The returned string ends with
// `;` which the caller is expected to strip.
fn render_signature_str(d: *ast::decl, f: ast::decl_func) str = {
	let copy = *d;
	copy.docs = "";
	copy.decl = ast::decl_func {
		symbol = f.symbol,
		ident = f.ident,
		prototype = f.prototype,
		body = null,
		attrs = f.attrs,
	};
	return unparse_decl_to_str(&copy);
};

fn unparse_decl_to_str(d: *ast::decl) str = {
	let buf = memio::dynamic();
	defer match (io::close(&buf)) {
	case => void;
	};
	match (unparse::decl(&buf, &unparse::syn_nowrap, d)) {
	case size => void;
	case => return strings::dup("<unparse error>")!;
	};
	return strings::dup(memio::string(&buf)!)!;
};

fn render_expr_str(e: *ast::expr) str = {
	let buf = memio::dynamic();
	defer match (io::close(&buf)) {
	case => void;
	};
	match (unparse::expr(&buf, &unparse::syn_nowrap, e)) {
	case size => void;
	case => return strings::dup("<unparse error>")!;
	};
	return strings::dup(memio::string(&buf)!)!;
};

fn render_import_str(im: *ast::import) str = {
	let buf = memio::dynamic();
	defer match (io::close(&buf)) {
	case => void;
	};
	match (unparse::import(&buf, &unparse::syn_nowrap, im)) {
	case size => void;
	case => return strings::dup("<unparse error>")!;
	};
	return strings::dup(memio::string(&buf)!)!;
};
