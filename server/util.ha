// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Helpers shared across server handlers. Each function here used to live
// as a private per-file copy (parse_pos_sh / parse_pos_th /
// parse_pos_local / ..., decl_ident_sh / decl_ident_ih, encode_range_cl /
// encode_range_th, etc.). Consolidating them here keeps the bodies in
// one place so behaviour can't drift between handlers.

use analysis;
use encoding::json;
use fs;
use hare::ast;
use lsp;
use os;

// Returns the identifier path of a top-level decl, or [] for assert_expr
// (which has no name). Used by handlers that need to compare a decl's
// short name against a target.
//
// @param d: borrowed
// @returns: borrowed from d
fn decl_ident(d: *ast::decl) ast::ident = {
	match (d.decl) {
	case let f: ast::decl_func =>
		return f.ident;
	case let t: ast::decl_type =>
		return t.ident;
	case let g: ast::decl_global =>
		return g.ident;
	case let c: ast::decl_const =>
		return c.ident;
	case ast::assert_expr =>
		return [];
	};
};

// Linear scan over `su.decls` for the first decl whose ident's last
// segment equals `name`. Returns the slice index, or void.
//
// @param su: borrowed
// @param name: borrowed
fn find_decl_by_name(su: *ast::subunit, name: str) (size | void) = {
	for (let i = 0z; i < len(su.decls); i += 1) {
		const id = decl_ident(&su.decls[i]);
		if (len(id) > 0 && id[len(id) - 1] == name) return i;
	};
	return void;
};

// Decodes the `params` of any request shaped like `{textDocument: {uri},
// position}` (definition, references, hover, signatureHelp, ...) into a
// (uri, position) pair. Returns void if any required field is missing or
// has the wrong type.
//
// @returns: uri borrowed from p
// @param p: borrowed
fn parse_text_document_position(
	p: (json::value | void),
) ((str, lsp::position) | void) = {
	const obj = match (lsp::params_object(p)) {
	case let o: json::object =>
		yield o;
	case void =>
		return void;
	};
	const td = match (lsp::json_obj(&obj, "textDocument")) {
	case let o: json::object =>
		yield o;
	case void =>
		return void;
	};
	const uri = match (lsp::json_str(&td, "uri")) {
	case let s: str =>
		yield s;
	case void =>
		return void;
	};
	const pos = match (json::get(&obj, "position")) {
	case let p: *json::value =>
		yield match (lsp::decode_position(*p)) {
		case let pos: lsp::position =>
			yield pos;
		case lsp::bad_message =>
			return void;
		};
	case =>
		return void;
	};
	return (uri, pos);
};

// Decodes the `params` of any request shaped like `{textDocument: {uri}}`
// (formatting, semanticTokens, codeLens, ...) into the URI string.
// Returns void if the URI is missing or has the wrong type.
//
// @returns: borrowed from p
// @param p: borrowed
fn uri_from_textdoc(p: (json::value | void)) (str | void) = {
	const obj = match (lsp::params_object(p)) {
	case let o: json::object =>
		yield o;
	case void =>
		return void;
	};
	const td = match (lsp::json_obj(&obj, "textDocument")) {
	case let o: json::object =>
		yield o;
	case void =>
		return void;
	};
	return lsp::json_str(&td, "uri");
};

// Encodes an `[start, end)` pair as the JSON object form of an LSP range.
// Aborts on OOM (consistent with how handlers build response payloads).
// Used by handlers that assemble the JSON by hand rather than
// constructing an lsp::range first.
//
// @returns: owned
fn encode_range_pos(
	start: analysis::position,
	end: analysis::position,
) json::value = {
	let r = json::newobject();
	let s_obj = json::newobject();
	json::put(&s_obj, "line", start.line: f64)!;
	json::put(&s_obj, "character", start.character: f64)!;
	let e_obj = json::newobject();
	json::put(&e_obj, "line", end.line: f64)!;
	json::put(&e_obj, "character", end.character: f64)!;
	json::put(&r, "start", s_obj)!;
	json::put(&r, "end", e_obj)!;
	return r;
};

// True when `path` exists and is a directory.
//
// @param path: borrowed
fn is_directory(path: str) bool = {
	match (os::stat(path)) {
	case let st: fs::filestat =>
		return fs::isdir(st.mode);
	case fs::error =>
		return false;
	};
};

// Sends an empty JSON array as the result for `id`. Used by handlers
// that exit early when they have nothing to report.
//
// @param s: borrowed
// @param id: borrowed
fn send_empty_array(s: *server, id: lsp::id) void = {
	const empty: []json::value = [];
	send_array_result(s, id, empty);
};
