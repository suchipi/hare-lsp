// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Type hierarchy. Hare doesn't have inheritance; the only structural
// relationships we can surface are:
//
//   - Tagged unions: variants are "sub" of the union, the union is "super"
//     of each variant.
//   - Type aliases: alias -> underlying type as super; underlying -> alias
//     as one possible sub.
//
// Walking and matching the underlying _type repr is non-trivial and lives
// alongside step 27's type analysis. For now, prepareTypeHierarchy returns
// the type decl at the cursor (so editors show the UI), and supertypes /
// subtypes return empty arrays.

use analysis;
use encoding::json;
use lsp;
use strings;

export fn handle_prepare_type_hierarchy(s: *server, r: lsp::request) void = {
	const (uri, pos) = match (parse_pos_th(r.params)) {
	case let v: (str, lsp::position) => yield v;
	case void =>
		send_array_th(s, r.id, []);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document => yield p;
	case null =>
		send_array_th(s, r.id, []);
		return;
	};
	const data = analysis::bytes(&doc.buf);
	const off = analysis::position_to_byte(data, doc.buf.line_index,
		position_encoding(s),
		analysis::position { line = pos.line, character = pos.character });
	let pr = analysis::parse_recover(data, uri);
	defer analysis::finish_parse_result(&pr);
	let idx = analysis::build_index(&pr.subunit);
	defer analysis::finish_index(&idx);
	const sym = match (analysis::symbol_at(&idx, off)) {
	case let p: *analysis::symbol => yield p;
	case void =>
		send_array_th(s, r.id, []);
		return;
	};
	if (sym.kind != analysis::symbol_kind::TYPE) {
		send_array_th(s, r.id, []);
		return;
	};
	let arr: []json::value = [];
	let item = json::newobject();
	json::set(&item, "name", sym.short_name: json::value)!;
	json::put(&item, "kind", 23: f64)!; // 23 = Struct
	json::set(&item, "uri", uri: json::value)!;
	const enc = position_encoding(s);
	const sp = analysis::byte_to_position(data, doc.buf.line_index, enc,
		sym.span.start.off: size);
	const ep = analysis::byte_to_position(data, doc.buf.line_index, enc,
		sym.span.end.off: size);
	json::put(&item, "range", encode_range_th(sp, ep))!;
	json::put(&item, "selectionRange", encode_range_th(sp, ep))!;
	append(arr, item: json::value)!;
	send_array_th(s, r.id, arr);
};

export fn handle_supertypes(s: *server, r: lsp::request) void = {
	send_array_th(s, r.id, []);
};

export fn handle_subtypes(s: *server, r: lsp::request) void = {
	send_array_th(s, r.id, []);
};

fn parse_pos_th(p: (json::value | void)) ((str, lsp::position) | void) = {
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

fn encode_range_th(start: analysis::position, end: analysis::position) json::value = {
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

fn send_array_th(s: *server, id: lsp::id, arr: []json::value) void = {
	const v: json::value = arr;
	defer json::finish(v);
	match (lsp::encode_response_result(s.out, id, v)) {
	case size => void;
	case => void;
	};
};
