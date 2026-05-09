// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Call hierarchy: prepare, incomingCalls, outgoingCalls. Built on the
// workspace index plus the same textual reference scan used by
// references. Outgoing calls are detected by looking for known function
// short_names that appear inside the source function's span.

use analysis;
use encoding::json;
use fs;
use io;
use lsp;
use os;
use strings;

// Handles textDocument/prepareCallHierarchy. Returns a single
// CallHierarchyItem for the function decl at the cursor (or null/empty if
// the cursor isn't on a function).
export fn handle_prepare_call_hierarchy(s: *server, r: lsp::request) void = {
	const (uri, pos) = match (parse_pos_local(r.params)) {
	case let v: (str, lsp::position) => yield v;
	case void =>
		send_array_local(s, r.id, []);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document => yield p;
	case null =>
		send_array_local(s, r.id, []);
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
		send_array_local(s, r.id, []);
		return;
	};
	if (sym.kind != analysis::symbol_kind::FUNCTION) {
		send_array_local(s, r.id, []);
		return;
	};
	let arr: []json::value = [];
	append(arr, build_call_hierarchy_item(s, sym, uri, doc))!;
	send_array_local(s, r.id, arr);
};

// Handles callHierarchy/incomingCalls. Returns the call sites where the
// item's name appears as a textual word — same scan logic as references.
export fn handle_incoming_calls(s: *server, r: lsp::request) void = {
	const (item_name, item_uri) = match (parse_call_item(r.params)) {
	case let v: (str, str) => yield v;
	case void =>
		send_array_local(s, r.id, []);
		return;
	};
	defer free(item_name);
	defer free(item_uri);

	// Collect call sites: locations where the name appears.
	let calls: []json::value = [];
	for (let i = 0z; i < len(s.documents); i += 1) {
		const more = scan_calls_in_doc(&s.documents[i], item_name);
		append(calls, more...)!;
		free(more);
	};
	const seen = collect_seen_paths(s);
	defer free(seen);
	for (let i = 0z; i < len(s.workspace_index.indexed_files); i += 1) {
		const path = s.workspace_index.indexed_files[i];
		if (str_in_slice(seen, path)) continue;
		const more = scan_calls_in_file(path, item_name);
		append(calls, more...)!;
		free(more);
	};

	// Group call sites by the URI of the calling file. Then for each
	// caller, build an item describing the *enclosing function* if
	// available; if not, attribute the call to the file as a whole.
	let grouped: [](str, []json::value) = [];
	defer {
		for (let i = 0z; i < len(grouped); i += 1) {
			free(grouped[i].0);
			for (let j = 0z; j < len(grouped[i].1); j += 1) {
				json::finish(grouped[i].1[j]);
			};
			free(grouped[i].1);
		};
		free(grouped);
	};
	for (let i = 0z; i < len(calls); i += 1) {
		const o = calls[i] as json::object;
		const u = *(json::get(&o, "uri") as *json::value) as str;
		const idx = group_index(&grouped, u);
		grouped[idx].1 = append_value(grouped[idx].1, calls[i]);
	};
	free(calls); // values were transferred into grouped

	let arr: []json::value = [];
	for (let i = 0z; i < len(grouped); i += 1) {
		// Build a synthetic CallHierarchyItem for the calling URI: the
		// "from" item. We name it after the file basename so editors
		// have something to display.
		let from = json::newobject();
		const file_name = basename_of(grouped[i].0);
		json::set(&from, "name", file_name: json::value)!;
		json::put(&from, "kind", 2: f64)!; // 2 = Module per LSP SymbolKind
		json::set(&from, "uri", grouped[i].0: json::value)!;
		json::put(&from, "range", zero_range())!;
		json::put(&from, "selectionRange", zero_range())!;

		let from_ranges: []json::value = [];
		for (let j = 0z; j < len(grouped[i].1); j += 1) {
			const o = grouped[i].1[j] as json::object;
			let r = match (json::dup(*(json::get(&o, "range") as *json::value))) {
			case let v: json::value => yield v;
			case nomem => continue;
			};
			append(from_ranges, r)!;
		};

		let entry = json::newobject();
		json::put(&entry, "from", from)!;
		json::put(&entry, "fromRanges", from_ranges: json::value)!;
		append(arr, entry: json::value)!;
	};
	send_array_local(s, r.id, arr);
};

// Handles callHierarchy/outgoingCalls. For each function in the workspace
// whose name appears within the source function's span, emit an entry.
export fn handle_outgoing_calls(s: *server, r: lsp::request) void = {
	const (item_name, item_uri) = match (parse_call_item(r.params)) {
	case let v: (str, str) => yield v;
	case void =>
		send_array_local(s, r.id, []);
		return;
	};
	defer free(item_name);
	defer free(item_uri);

	// Find the source function's span by re-parsing the file.
	const doc = match (find_document(s, item_uri)) {
	case let p: *document => yield p;
	case null =>
		send_array_local(s, r.id, []);
		return;
	};
	const data = analysis::bytes(&doc.buf);
	let pr = analysis::parse_recover(data, item_uri);
	defer analysis::finish_parse_result(&pr);
	let idx = analysis::build_index(&pr.subunit);
	defer analysis::finish_index(&idx);
	const src_sym = match (analysis::find_by_short_name(&idx, item_name)) {
	case let p: *analysis::symbol => yield p;
	case void =>
		send_array_local(s, r.id, []);
		return;
	};
	const start = src_sym.span.start.off: size;
	const end = src_sym.span.end.off: size;
	if (start >= end || end > len(data)) {
		send_array_local(s, r.id, []);
		return;
	};
	const body = data[start..end];

	// For every workspace function entry, if its name appears in body
	// (as a token), record an outgoing call.
	let arr: []json::value = [];
	for (let i = 0z; i < len(s.workspace_index.entries); i += 1) {
		const entry = &s.workspace_index.entries[i];
		if (entry.kind != analysis::symbol_kind::FUNCTION) continue;
		if (entry.short_name == item_name) continue;
		if (!body_contains_token(body, entry.short_name)) continue;

		// Build "to" CallHierarchyItem.
		let to = json::newobject();
		json::set(&to, "name", entry.short_name: json::value)!;
		json::put(&to, "kind", 12: f64)!; // 12 = Function
		json::set(&to, "uri", entry.uri: json::value)!;
		json::put(&to, "range", zero_range())!;
		json::put(&to, "selectionRange", zero_range())!;

		// fromRanges: locations within `data` where the call appears.
		let from_ranges: []json::value = [];
		const t = strings::toutf8(entry.short_name);
		let i = 0z;
		for (i + len(t) <= len(body); i += 1) {
			if (i > 0 && is_word_char(body[i - 1])) continue;
			if (i + len(t) < len(body) && is_word_char(body[i + len(t)])) continue;
			let ok = true;
			for (let j = 0z; j < len(t); j += 1) {
				if (body[i + j] != t[j]) {
					ok = false;
					break;
				};
			};
			if (!ok) continue;
			const abs = start + i;
			const sp = analysis::byte_to_position(data, doc.buf.line_index,
				position_encoding(s), abs);
			const ep = analysis::byte_to_position(data, doc.buf.line_index,
				position_encoding(s), abs + len(t));
			append(from_ranges, encode_range_local(sp, ep))!;
			i += len(t) - 1;
		};

		let outgoing = json::newobject();
		json::put(&outgoing, "to", to)!;
		json::put(&outgoing, "fromRanges", from_ranges: json::value)!;
		append(arr, outgoing: json::value)!;
	};
	send_array_local(s, r.id, arr);
};

fn body_contains_token(body: []u8, name: str) bool = {
	const t = strings::toutf8(name);
	let i = 0z;
	for (i + len(t) <= len(body); i += 1) {
		if (i > 0 && is_word_char(body[i - 1])) continue;
		if (i + len(t) < len(body) && is_word_char(body[i + len(t)])) continue;
		let ok = true;
		for (let j = 0z; j < len(t); j += 1) {
			if (body[i + j] != t[j]) {
				ok = false;
				break;
			};
		};
		if (ok) return true;
	};
	return false;
};

fn is_word_char(b: u8) bool = {
	if (b >= 'a': u8 && b <= 'z': u8) return true;
	if (b >= 'A': u8 && b <= 'Z': u8) return true;
	if (b >= '0': u8 && b <= '9': u8) return true;
	return b == '_': u8;
};

fn build_call_hierarchy_item(
	s: *server, sym: *analysis::symbol, uri: str, doc: *document,
) json::value = {
	let item = json::newobject();
	json::set(&item, "name", sym.short_name: json::value)!;
	json::put(&item, "kind", 12: f64)!; // 12 = Function
	json::set(&item, "uri", uri: json::value)!;
	const enc = position_encoding(s);
	const data = analysis::bytes(&doc.buf);
	const sp = analysis::byte_to_position(data, doc.buf.line_index, enc,
		sym.span.start.off: size);
	const ep = analysis::byte_to_position(data, doc.buf.line_index, enc,
		sym.span.end.off: size);
	json::put(&item, "range", encode_range_local(sp, ep))!;
	json::put(&item, "selectionRange", encode_range_local(sp, ep))!;
	return item;
};

fn parse_call_item(p: (json::value | void)) ((str, str) | void) = {
	const v = match (p) {
	case let v: json::value => yield v;
	case void => return void;
	};
	const obj = match (v) {
	case let o: json::object => yield o;
	case => return void;
	};
	const item = match (json::get(&obj, "item")) {
	case let p: *json::value =>
		yield match (*p) {
		case let o: json::object => yield o;
		case => return void;
		};
	case => return void;
	};
	const name = match (json::get(&item, "name")) {
	case let p: *json::value =>
		yield match (*p) {
		case let s: str => yield strings::dup(s)!;
		case => return void;
		};
	case => return void;
	};
	const uri = match (json::get(&item, "uri")) {
	case let p: *json::value =>
		yield match (*p) {
		case let s: str => yield strings::dup(s)!;
		case => return void;
		};
	case => return void;
	};
	return (name, uri);
};

fn scan_calls_in_doc(doc: *document, name: str) []json::value = {
	const data = analysis::bytes(&doc.buf);
	return scan_calls_static(data, doc.uri, doc.buf.line_index, name);
};

fn scan_calls_in_file(path: str, name: str) []json::value = {
	const f = match (os::open(path)) {
	case let f: io::file => yield f;
	case fs::error => return [];
	};
	defer lsp::safe_close(f);
	let buf: []u8 = [];
	defer free(buf);
	let chunk: [4096]u8 = [0...];
	for (true) {
		match (io::read(f, chunk[..])) {
		case let n: size =>
			append(buf, chunk[..n]...)!;
		case io::EOF =>
			break;
		case io::error =>
			break;
		};
	};
	const idx = analysis::build_line_index(buf);
	defer free(idx);
	const uri = strings::concat("file://", path)!;
	defer free(uri);
	return scan_calls_static(buf, uri, idx, name);
};

fn scan_calls_static(data: []u8, uri: str, line_index: []size, name: str) []json::value = {
	let arr: []json::value = [];
	const t = strings::toutf8(name);
	let i = 0z;
	for (i + len(t) <= len(data); i += 1) {
		if (i > 0 && is_word_char(data[i - 1])) continue;
		if (i + len(t) < len(data) && is_word_char(data[i + len(t)])) continue;
		let ok = true;
		for (let j = 0z; j < len(t); j += 1) {
			if (data[i + j] != t[j]) {
				ok = false;
				break;
			};
		};
		if (!ok) continue;
		// Heuristic: only count this as a call site if followed by '('
		// (possibly after whitespace).
		let k = i + len(t);
		for (k < len(data) && (data[k] == ' ': u8 || data[k] == '\t': u8); k += 1) void;
		if (k >= len(data) || data[k] != '(': u8) continue;
		const start_pos = analysis::byte_to_position(data, line_index,
			analysis::encoding::UTF16, i);
		const end_pos = analysis::byte_to_position(data, line_index,
			analysis::encoding::UTF16, i + len(t));
		let loc = json::newobject();
		json::set(&loc, "uri", uri: json::value)!;
		json::put(&loc, "range", encode_range_local(start_pos, end_pos))!;
		append(arr, loc: json::value)!;
		i += len(t) - 1;
	};
	return arr;
};

fn collect_seen_paths(s: *server) []str = {
	let out: []str = [];
	for (let i = 0z; i < len(s.documents); i += 1) {
		const u = s.documents[i].uri;
		if (strings::hasprefix(u, "file://")) {
			append(out, strings::sub(u, len("file://"), strings::end))!;
		};
	};
	return out;
};

fn str_in_slice(haystack: []str, needle: str) bool = {
	for (let i = 0z; i < len(haystack); i += 1) {
		if (haystack[i] == needle) return true;
	};
	return false;
};

fn append_value(slice: []json::value, v: json::value) []json::value = {
	let out = slice;
	append(out, v)!;
	return out;
};

fn group_index(grouped: *[](str, []json::value), uri: str) size = {
	let g = *grouped;
	for (let i = 0z; i < len(g); i += 1) {
		if (g[i].0 == uri) return i;
	};
	append(g, (strings::dup(uri)!, []: []json::value))!;
	*grouped = g;
	return len(g) - 1;
};

fn basename_of(uri: str) str = {
	const idx = strings::rindex(uri, '/');
	match (idx) {
	case let i: size =>
		return strings::sub(uri, i + 1, strings::end);
	case void =>
		return uri;
	};
};

fn zero_range() json::value = {
	let r = json::newobject();
	let z = json::newobject();
	json::put(&z, "line", 0: f64)!;
	json::put(&z, "character", 0: f64)!;
	let z2 = json::newobject();
	json::put(&z2, "line", 0: f64)!;
	json::put(&z2, "character", 0: f64)!;
	json::put(&r, "start", z)!;
	json::put(&r, "end", z2)!;
	return r;
};

fn encode_range_local(start: analysis::position, end: analysis::position) json::value = {
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

fn parse_pos_local(p: (json::value | void)) ((str, lsp::position) | void) = {
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

fn send_array_local(s: *server, id: lsp::id, arr: []json::value) void = {
	const v: json::value = arr;
	defer json::finish(v);
	match (lsp::encode_response_result(s.out, id, v)) {
	case size => void;
	case => void;
	};
};
