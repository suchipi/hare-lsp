// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Helpers for rendering a function declaration's signature as the strings
// LSP clients expect (label + per-parameter labels). Used at workspace
// indexing time so cross-file `textDocument/signatureHelp` can serve a
// fully populated SignatureInformation without re-parsing the defining
// file. The in-file signatureHelp path also reuses these helpers so the
// label format stays in lockstep.

use hare::ast;
use hare::unparse;
use io;
use memio;
use strings;

// Renders a `decl_func`'s prototype as the same body-stripped string that
// hover and signatureHelp show. Returns void for non-function decls so
// the caller can skip them.
//
// @returns: owned
// @param d: borrowed
export fn render_function_signature(d: *ast::decl) (str | void) = {
	const f = match (d.decl) {
	case let f: ast::decl_func =>
		yield f;
	case =>
		return void;
	};
	let buf = memio::dynamic();
	defer match (io::close(&buf)) {
	case => void;
	};
	let copy = *d;
	copy.docs = "";
	copy.decl = ast::decl_func {
		symbol = f.symbol,
		ident = f.ident,
		prototype = f.prototype,
		body = null,
		attrs = f.attrs,
	};
	match (unparse::decl(&buf, &unparse::syn_nowrap, &copy)) {
	case size => void;
	case =>
		return strings::dup("<unparse error>")!;
	};
	return strings::dup(memio::string(&buf)!)!;
};

// Returns one `"<name>: <type>"` label per parameter so each entry is a
// substring of the full signature label (the LSP spec requires that for
// the editor to find the active-parameter range to highlight). Returns an
// empty slice for non-function decls and for prototypes with no params.
// Caller frees the slice with [[free_param_labels]].
//
// @returns: owned
// @param d: borrowed
export fn collect_param_labels(d: *ast::decl) []str = {
	let out: []str = [];
	const f = match (d.decl) {
	case let f: ast::decl_func =>
		yield f;
	case =>
		return out;
	};
	const proto = match (f.prototype.repr) {
	case let proto: ast::func_type =>
		yield proto;
	case =>
		return out;
	};
	for (let i = 0z; i < len(proto.params); i += 1) {
		append(out, render_param_label(&proto.params[i]))!;
	};
	return out;
};

// Renders one parameter as `"<name>: <type>"`. Substitutes `_` for an
// anonymous parameter so the label is still a non-empty substring.
//
// @returns: owned
// @param p: borrowed
export fn render_param_label(p: *ast::func_param) str = {
	let buf = memio::dynamic();
	defer match (io::close(&buf)) {
	case => void;
	};
	const name = if (len(p.name) > 0) p.name else "_";
	match (memio::concat(&buf, name, ": ")) {
	case size => void;
	case =>
		return strings::dup(name)!;
	};
	match (unparse::_type(&buf, &unparse::syn_nowrap, p._type)) {
	case size => void;
	case => void;
	};
	return strings::dup(memio::string(&buf)!)!;
};

// Frees a slice produced by [[collect_param_labels]].
//
// @param labels: owned
export fn free_param_labels(labels: []str) void = {
	for (let i = 0z; i < len(labels); i += 1) {
		free(labels[i]);
	};
	free(labels);
};
