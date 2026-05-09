// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Signature help. Triggered on '(' and ',', returns a SignatureHelp with
// the function's parameters and the active parameter index.
//
// Strategy: walk left from the cursor through the source, tracking paren
// depth; when we close depth to -1, we found the enclosing call's '('.
// The token preceding it is the called function's name. Count commas at
// depth 0 between that '(' and the cursor to find the active parameter.

use analysis;
use encoding::json;
use hare::ast;
use hare::unparse;
use io;
use lsp;
use memio;
use strings;

export fn handle_signature_help(s: *server, r: lsp::request) void = {
	const (uri, pos) = match (parse_pos_sh(r.params)) {
	case let v: (str, lsp::position) => yield v;
	case void =>
		send_null_sh(s, r.id);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document => yield p;
	case null =>
		send_null_sh(s, r.id);
		return;
	};
	const data = analysis::bytes(&doc.buf);
	const off = analysis::position_to_byte(data, doc.buf.line_index,
		position_encoding(s),
		analysis::position { line = pos.line, character = pos.character });
	const ctx = match (find_call_context(data, off)) {
	case let c: call_context => yield c;
	case void =>
		send_null_sh(s, r.id);
		return;
	};
	defer free(ctx.callee_name);

	// Resolve the callee in the file's index, then in the workspace index.
	let pr = analysis::parse_recover(data, uri);
	defer analysis::finish_parse_result(&pr);
	let idx = analysis::build_index(&pr.subunit);
	defer analysis::finish_index(&idx);
	const decl_idx = match (find_decl_by_short_name(&pr.subunit, ctx.callee_name)) {
	case let i: size => yield i;
	case void =>
		// Try workspace.
		send_workspace_signature(s, r.id, ctx);
		return;
	};

	const sig = render_decl_signature_local(&pr.subunit.decls[decl_idx]);
	defer free(sig);

	let signatures: []json::value = [];
	let info = json::newobject();
	json::set(&info, "label", sig: json::value)!;

	// Build a parameters array by walking the decl's prototype.
	let params_arr: []json::value = [];
	const param_count = count_params(&pr.subunit.decls[decl_idx]);
	for (let i = 0z; i < param_count; i += 1) {
		let p = json::newobject();
		const lbl = strings::concat("param ", fmt_size_local(i))!;
		defer free(lbl);
		json::set(&p, "label", lbl: json::value)!;
		append(params_arr, p: json::value)!;
	};
	json::put(&info, "parameters", params_arr: json::value)!;
	append(signatures, info: json::value)!;

	let result = json::newobject();
	json::put(&result, "signatures", signatures: json::value)!;
	json::put(&result, "activeSignature", 0: f64)!;
	const active = if (ctx.active_param < param_count) ctx.active_param else 0z;
	json::put(&result, "activeParameter", (active: u64): f64)!;
	const v: json::value = result;
	defer json::finish(v);
	match (lsp::encode_response_result(s.out, r.id, v)) {
	case size => void;
	case => void;
	};
};

fn send_workspace_signature(s: *server, id: lsp::id, ctx: call_context) void = {
	for (let i = 0z; i < len(s.workspace_index.entries); i += 1) {
		const e = &s.workspace_index.entries[i];
		if (e.kind != analysis::symbol_kind::FUNCTION) continue;
		if (e.short_name != ctx.callee_name) continue;
		// We don't have the AST for workspace files cached, so render
		// the bare name as the label. A future revision will cache
		// signatures alongside the index.
		let info = json::newobject();
		json::set(&info, "label", e.full_name: json::value)!;
		let signatures: []json::value = [];
		append(signatures, info: json::value)!;
		let result = json::newobject();
		json::put(&result, "signatures", signatures: json::value)!;
		json::put(&result, "activeSignature", 0: f64)!;
		json::put(&result, "activeParameter", 0: f64)!;
		const v: json::value = result;
		defer json::finish(v);
		match (lsp::encode_response_result(s.out, id, v)) {
		case size => void;
		case => void;
		};
		return;
	};
	send_null_sh(s, id);
};

type call_context = struct {
	callee_name: str, // owned; caller must free
	active_param: size,
};

// Walks backward from `off` to find the enclosing call expression's '('
// and counts commas to determine the active parameter.
fn find_call_context(data: []u8, off: size) (call_context | void) = {
	let depth: int = 0;
	let active: size = 0;
	let i = off;
	if (i > len(data)) i = len(data);
	for (i > 0; i -= 1) {
		const b = data[i - 1];
		switch (b) {
		case ')': u8, ']': u8, '}': u8 =>
			depth += 1;
		case '(': u8 =>
			if (depth == 0) {
				// Found the enclosing '(' at index i - 1.
				const open_at = i - 1;
				// The callee name ends just before open_at,
				// possibly preceded by spaces.
				let e = open_at;
				for (e > 0 && (data[e - 1] == ' ': u8 || data[e - 1] == '\t': u8); e -= 1) void;
				let s = e;
				for (s > 0; s -= 1) {
					const cb = data[s - 1];
					if (!is_ident_byte_sh(cb)) break;
				};
				if (s == e) return void;
				const name = strings::dup(strings::fromutf8(data[s..e])!)!;
				return call_context {
					callee_name = name,
					active_param = active,
				};
			};
			depth -= 1;
		case '[': u8, '{': u8 =>
			depth -= 1;
		case ',': u8 =>
			if (depth == 0) active += 1;
		case => void;
		};
	};
	return void;
};

fn is_ident_byte_sh(b: u8) bool = {
	if (b >= 'a': u8 && b <= 'z': u8) return true;
	if (b >= 'A': u8 && b <= 'Z': u8) return true;
	if (b >= '0': u8 && b <= '9': u8) return true;
	return b == '_': u8;
};

fn find_decl_by_short_name(su: *ast::subunit, name: str) (size | void) = {
	for (let i = 0z; i < len(su.decls); i += 1) {
		const id = decl_ident_sh(&su.decls[i]);
		if (len(id) > 0 && id[len(id) - 1] == name) return i;
	};
	return void;
};

fn decl_ident_sh(d: *ast::decl) ast::ident = {
	match (d.decl) {
	case let f: ast::decl_func => return f.ident;
	case let t: ast::decl_type => return t.ident;
	case let g: ast::decl_global => return g.ident;
	case let c: ast::decl_const => return c.ident;
	case ast::assert_expr => return [];
	};
};

fn count_params(d: *ast::decl) size = {
	match (d.decl) {
	case let f: ast::decl_func =>
		match (f.prototype.repr) {
		case let proto: ast::func_type =>
			return len(proto.params);
		case => return 0;
		};
	case => return 0;
	};
};

fn render_decl_signature_local(d: *ast::decl) str = {
	let buf = memio::dynamic();
	defer lsp::safe_close(&buf);
	match (unparse::decl(&buf, &unparse::syn_nowrap, d)) {
	case size => void;
	case => return strings::dup("<unparse error>")!;
	};
	return strings::dup(memio::string(&buf)!)!;
};

fn fmt_size_local(n: size) str = {
	if (n == 0) return strings::dup("0")!;
	let buf: [21]u8 = [0...];
	let i = len(buf);
	let v = n;
	for (v > 0; v /= 10) {
		i -= 1;
		buf[i] = ('0': u8) + (v % 10): u8;
	};
	return strings::dup(strings::fromutf8(buf[i..])!)!;
};

fn parse_pos_sh(p: (json::value | void)) ((str, lsp::position) | void) = {
	const v = match (p) {
	case let v: json::value => yield v;
	case void => return void;
	};
	const obj = match (v) {
	case let o: json::object => yield o;
	case => return void;
	};
	const td = match (json::get(&obj, "textDocument")) {
	case let p: *json::value =>
		yield match (*p) {
		case let o: json::object => yield o;
		case => return void;
		};
	case => return void;
	};
	const uri = match (json::get(&td, "uri")) {
	case let p: *json::value =>
		yield match (*p) {
		case let s: str => yield s;
		case => return void;
		};
	case => return void;
	};
	const pos = match (json::get(&obj, "position")) {
	case let p: *json::value =>
		yield match (lsp::decode_position(*p)) {
		case let pos: lsp::position => yield pos;
		case lsp::bad_message => return void;
		};
	case => return void;
	};
	return (uri, pos);
};

fn send_null_sh(s: *server, id: lsp::id) void = {
	const v: json::value = json::_null;
	match (lsp::encode_response_result(s.out, id, v)) {
	case size => void;
	case => void;
	};
};
