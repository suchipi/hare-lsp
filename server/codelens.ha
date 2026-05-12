// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Code lens. Two lens kinds:
//   1. "Run test" above each @test function.
//   2. "N references" above each exported function / type.
//
// Resolve fills in the command for the lens based on a `data` carrier
// that the unresolved lens carries.

use analysis;
use bufio;
use encoding::json;
use hare::lex;
use hare::lex::{ltok};
use lsp;
use memio;
use strings;

export fn handle_code_lens(s: *server, r: lsp::request) void = {
	const uri = match (uri_from_cl(r.params)) {
	case let s: str => yield s;
	case void =>
		send_array_cl(s, r.id, []);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document => yield p;
	case null =>
		send_array_cl(s, r.id, []);
		return;
	};
	const data = analysis::bytes(&doc.buf);
	const cache = parse_of(doc);

	let arr: []json::value = [];
	const enc = position_encoding(s);

	// Reference-count lens for each exported decl.
	for (let i = 0z; i < len(cache.idx.symbols); i += 1) {
		const sym = &cache.idx.symbols[i];
		if (!sym.exported) continue;
		let lens = json::newobject();
		const sp = analysis::byte_to_position(data, doc.buf.line_index,
			enc, sym.span.start.off: size);
		const ep = analysis::byte_to_position(data, doc.buf.line_index,
			enc, sym.span.end.off: size);
		json::put(&lens, "range", encode_range_cl(sp, ep))!;
		// Carry a `data` blob so resolve knows what to fill in.
		// We also stash the identifier's own position so the resolve
		// step can hand it to editor.action.showReferences — using the
		// lens range start would land on the `export` keyword (or the
		// type's `let`/`const`), making references match every keyword
		// occurrence instead of the symbol. The analysis index's
		// `name_span` is currently a stub (loc.start..loc.start), so we
		// search the decl's source text for the identifier ourselves.
		const ident_off = find_ident_within(data,
			sym.span.start.off: size,
			sym.span.end.off: size,
			sym.short_name);
		const name_pos = analysis::byte_to_position(data, doc.buf.line_index,
			enc, ident_off);
		let lens_data = json::newobject();
		json::set(&lens_data, "kind", "references": json::value)!;
		json::set(&lens_data, "uri", uri: json::value)!;
		json::set(&lens_data, "name", sym.short_name: json::value)!;
		let name_pos_obj = json::newobject();
		json::put(&name_pos_obj, "line", name_pos.line: f64)!;
		json::put(&name_pos_obj, "character", name_pos.character: f64)!;
		json::put(&lens_data, "namePosition", name_pos_obj)!;
		json::put(&lens, "data", lens_data)!;
		append(arr, lens: json::value)!;
	};

	// Run-test lens: lex the file looking for `@test` attributes and
	// capture the function name that follows so the lens can ask the
	// test runner to filter to just that test.
	const tests = find_tests(data);
	defer {
		for (let i = 0z; i < len(tests); i += 1) {
			free(tests[i].name);
		};
		free(tests);
	};
	for (let i = 0z; i < len(tests); i += 1) {
		const t = tests[i];
		const sp = analysis::byte_to_position(data, doc.buf.line_index, enc, t.off);
		let lens = json::newobject();
		let r_obj = json::newobject();
		let s_obj = json::newobject();
		json::put(&s_obj, "line", sp.line: f64)!;
		json::put(&s_obj, "character", sp.character: f64)!;
		let e_obj = json::newobject();
		json::put(&e_obj, "line", sp.line: f64)!;
		json::put(&e_obj, "character", (sp.character + 5): f64)!;
		json::put(&r_obj, "start", s_obj)!;
		json::put(&r_obj, "end", e_obj)!;
		json::put(&lens, "range", r_obj)!;
		// Eager command (no resolve needed for run-test).
		let cmd = json::newobject();
		const title = if (len(t.name) > 0) {
			yield strings::concat("▶ Run test: ", t.name)!;
		} else {
			yield strings::dup("▶ Run test")!;
		};
		defer free(title);
		json::set(&cmd, "title", title: json::value)!;
		json::set(&cmd, "command", "hare-lsp.runTest": json::value)!;
		let args: []json::value = [];
		append(args, strings::dup(uri)!: json::value)!;
		if (len(t.name) > 0) {
			append(args, strings::dup(t.name)!: json::value)!;
		};
		json::put(&cmd, "arguments", args: json::value)!;
		json::put(&lens, "command", cmd)!;
		append(arr, lens: json::value)!;
	};

	send_array_cl(s, r.id, arr);
};

export fn handle_code_lens_resolve(s: *server, r: lsp::request) void = {
	// For "references" lenses, count occurrences and fill in command.
	const obj = match (params_obj_cl(r.params)) {
	case let o: json::object => yield o;
	case void =>
		echo_back(s, r);
		return;
	};
	const data_field = match (json::get(&obj, "data")) {
	case let p: *json::value =>
		yield match (*p) {
		case let o: json::object => yield o;
		case =>
			echo_back(s, r);
			return;
		};
	case =>
		echo_back(s, r);
		return;
	};
	const kind = match (json::get(&data_field, "kind")) {
	case let p: *json::value =>
		yield match (*p) {
		case let s: str => yield s;
		case =>
			echo_back(s, r);
			return;
		};
	case =>
		echo_back(s, r);
		return;
	};
	if (kind != "references") {
		echo_back(s, r);
		return;
	};
	const name = match (json::get(&data_field, "name")) {
	case let p: *json::value =>
		yield match (*p) {
		case let s: str => yield s;
		case =>
			echo_back(s, r);
			return;
		};
	case =>
		echo_back(s, r);
		return;
	};
	const lens_uri = match (json::get(&data_field, "uri")) {
	case let p: *json::value =>
		yield match (*p) {
		case let s: str => yield s;
		case =>
			echo_back(s, r);
			return;
		};
	case =>
		echo_back(s, r);
		return;
	};

	// Count references across the workspace.
	let count = 0z;
	for (let i = 0z; i < len(s.documents); i += 1) {
		count += count_token_occurrences(analysis::bytes(&s.documents[i].buf), name);
	};

	// Build the command "N references". The client needs uri + position
	// so it can invoke editor.action.showReferences; we pass the lens's
	// own range start.
	let cmd = json::newobject();
	const title = strings::concat(fmt_size_cl(count), " references")!;
	defer free(title);
	json::set(&cmd, "title", title: json::value)!;
	json::set(&cmd, "command", "hare-lsp.showReferences": json::value)!;

	// Echo back the lens with `command` filled in.
	let result_obj = match (json::dup(r.params as json::value)) {
	case let v: json::value => yield v as json::object;
	case nomem =>
		send_error(s, r.id, lsp::INTERNAL_ERROR, "out of memory");
		return;
	};

	// Use the identifier's own position (stashed by handle_code_lens)
	// so showReferences searches for the symbol — not the leading
	// `export` keyword or other tokens that share the decl's start
	// offset.
	match (json::get(&data_field, "namePosition")) {
	case let pp: *json::value =>
		let args: []json::value = [];
		match (json::dup(lens_uri: json::value)) {
		case let v: json::value =>
			append(args, v)!;
		case nomem =>
			send_error(s, r.id, lsp::INTERNAL_ERROR, "out of memory");
			return;
		};
		match (json::dup(*pp)) {
		case let v: json::value =>
			append(args, v)!;
		case nomem =>
			send_error(s, r.id, lsp::INTERNAL_ERROR, "out of memory");
			return;
		};
		json::put(&cmd, "arguments", args: json::value)!;
	case => void;
	};

	// Replace any existing command and add the new one.
	json::put(&result_obj, "command", cmd)!;
	const v: json::value = result_obj;
	defer json::finish(v);
	match (lsp::encode_response_result(s.out, r.id, v)) {
	case size => void;
	case => void;
	};
};

fn count_token_occurrences(data: []u8, name: str) size = {
	const t = strings::toutf8(name);
	let count = 0z;
	let i = 0z;
	for (i + len(t) <= len(data); i += 1) {
		if (i > 0 && is_word_byte_cl(data[i - 1])) continue;
		if (i + len(t) < len(data) && is_word_byte_cl(data[i + len(t)])) continue;
		let ok = true;
		for (let j = 0z; j < len(t); j += 1) {
			if (data[i + j] != t[j]) {
				ok = false;
				break;
			};
		};
		if (ok) {
			count += 1;
			i += len(t) - 1;
		};
	};
	return count;
};

fn is_word_byte_cl(b: u8) bool = {
	if (b >= 'a': u8 && b <= 'z': u8) return true;
	if (b >= 'A': u8 && b <= 'Z': u8) return true;
	if (b >= '0': u8 && b <= '9': u8) return true;
	return b == '_': u8;
};

// A @test attribute paired with the function name immediately
// following it. `name` is empty if the lexer couldn't find an
// identifier after the @test (e.g. malformed source).
type test_marker = struct {
	off: size,
	name: str,
};

fn find_tests(data: []u8) []test_marker = {
	let out: []test_marker = [];
	let src = memio::fixed(data);
	let scan = bufio::newscanner(&src);
	defer bufio::finish(&scan);
	let lexer = lex::init(&scan, "<doc>");
	defer lex::finish(&lexer);
	let pending: (size | void) = void;
	for (true) {
		const tok = match (lex::lex(&lexer)) {
		case let t: lex::token => yield t;
		case lex::error => break;
		};
		if (tok.0 == ltok::EOF) break;
		if (tok.0 == ltok::ATTR_TEST) {
			pending = tok.2.off: size;
			continue;
		};
		// After @test we expect `fn <name>(...) ...`. The first NAME
		// token following the attribute is the function name.
		match (pending) {
		case let off: size =>
			if (tok.0 == ltok::NAME) {
				const n = match (tok.1) {
				case let s: str => yield strings::dup(s)!;
				case => yield strings::dup("")!;
				};
				append(out, test_marker {
					off = off,
					name = n,
				})!;
				pending = void;
			};
		case void => void;
		};
	};
	// If a final @test had no name, still record it without one.
	match (pending) {
	case let off: size =>
		append(out, test_marker {
			off = off,
			name = strings::dup("")!,
		})!;
	case void => void;
	};
	return out;
};

fn echo_back(s: *server, r: lsp::request) void = {
	const v: json::value = match (r.params) {
	case let v: json::value =>
		yield match (json::dup(v)) {
		case let copy: json::value => yield copy;
		case nomem =>
			send_error(s, r.id, lsp::INTERNAL_ERROR, "out of memory");
			return;
		};
	case void => yield json::_null: json::value;
	};
	defer json::finish(v);
	match (lsp::encode_response_result(s.out, r.id, v)) {
	case size => void;
	case => void;
	};
};

fn fmt_size_cl(n: size) str = {
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

fn encode_range_cl(start: analysis::position, end: analysis::position) json::value = {
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

fn uri_from_cl(p: (json::value | void)) (str | void) = {
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
	match (json::get(&td, "uri")) {
	case let p: *json::value =>
		match (*p) {
		case let s: str => return s;
		case => return void;
		};
	case => return void;
	};
};

fn params_obj_cl(p: (json::value | void)) (json::object | void) =
	lsp::params_object(p);

fn send_array_cl(s: *server, id: lsp::id, arr: []json::value) void = {
	const v: json::value = arr;
	defer json::finish(v);
	match (lsp::encode_response_result(s.out, id, v)) {
	case size => void;
	case => void;
	};
};

// Returns the byte offset of `name` within data[span_start..span_end],
// matched as a whole word. Falls back to `span_start` if not found (an
// invariant violation that shouldn't happen for well-formed decls).
fn find_ident_within(data: []u8, span_start: size, span_end: size,
		name: str) size = {
	const target = strings::toutf8(name);
	if (len(target) == 0) return span_start;
	const end = if (span_end > len(data)) len(data) else span_end;
	if (span_start >= end) return span_start;
	for (let i = span_start; i + len(target) <= end; i += 1) {
		let ok = true;
		for (let j = 0z; j < len(target); j += 1) {
			if (data[i + j] != target[j]) {
				ok = false;
				break;
			};
		};
		if (!ok) continue;
		if (i > span_start && is_word_byte_cl(data[i - 1])) continue;
		if (i + len(target) < end &&
				is_word_byte_cl(data[i + len(target)])) continue;
		return i;
	};
	return span_start;
};
