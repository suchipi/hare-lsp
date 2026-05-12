// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Inlay hints. We emit two kinds:
//   1. Parameter names at call sites. We resolve the callee from the
//      file's symbol index.
//   2. Inferred types for `let x = expr` — best-effort via
//      analysis::type_of_expr_at: literals and declared types today.
//
// The hint generation is conservative: when in doubt, emit nothing
// rather than render confusing/wrong hints.

use analysis;
use encoding::json;
use hare::ast;
use lsp;
use strings;

export fn handle_inlay_hint(s: *server, r: lsp::request) void = {
	if (!s.config.inlay_hints_parameter_names &&
	!s.config.inlay_hints_inferred_types) {
		send_array_ih(s, r.id, []);
		return;
	};
	const uri = match (uri_from_ih(r.params)) {
	case let s: str =>
		yield s;
	case void =>
		send_array_ih(s, r.id, []);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document =>
		yield p;
	case null =>
		send_array_ih(s, r.id, []);
		return;
	};
	const data = analysis::bytes(&doc.buf);
	const cache = parse_of(doc);

	let arr: []json::value = [];
	if (s.config.inlay_hints_parameter_names) {
		emit_param_hints(s, doc, &cache.pr.subunit, &cache.idx, &arr);
	};
	if (s.config.inlay_hints_inferred_types) {
		emit_inferred_type_hints(s, doc, &cache.pr.subunit, &arr);
	};

	send_array_ih(s, r.id, arr);
};

// Emits ":<type>" hints right after `let x` / `const x` bindings whose
// declared type was omitted. Uses [[infer_let_type_deep]] for richer
// expansion (call return types, alias chains) bounded by
// `hare.inlayHints.inferredTypesMaxDepth`.
fn emit_inferred_type_hints(
	s: *server,
	doc: *document,
	su: *ast::subunit,
	arr: *[]json::value,
) void = {
	const data = analysis::bytes(&doc.buf);
	for (let i = 0z; i < len(su.decls); i += 1) {
		const d = &su.decls[i];
		const init = match (d.decl) {
		case let g: ast::decl_global =>
			if (!(g._type is null)) continue;
			yield match (g.init) {
			case let e: *ast::expr =>
				yield e;
			case null =>
				continue;
			};
		case let c: ast::decl_const =>
			if (!(c._type is null)) continue;
			yield c.init;
		case =>
			continue;
		};
		const off = d.loc.start.off: size;
		const label = match (infer_let_type_deep(s, doc, init)) {
		case let s: str =>
			yield s;
		case void =>
			continue;
		};
		defer free(label);
		// Position the hint at the end of the binding's name. We
		// approximate by walking forward from the start of the decl
		// past keyword + name to the next ':' or '='.
		const insert_off = find_post_name_offset(data, off);
		const enc = position_encoding(s);
		const pos = analysis::byte_to_position(data,
			doc.buf.line_index, enc, insert_off);
		let hint = json::newobject();
		let p_obj = json::newobject();
		json::put(&p_obj, "line", pos.line: f64)!;
		json::put(&p_obj, "character", pos.character: f64)!;
		json::put(&hint, "position", p_obj)!;
		const lbl = strings::concat(": ", label)!;
		defer free(lbl);
		json::set(&hint, "label", lbl: json::value)!;
		json::put(&hint, "kind", 1: f64)!; // 1 = Type
		json::put(&hint, "paddingLeft", true: json::value)!;
		let cur = *arr;
		append(cur, hint: json::value)!;
		*arr = cur;
	};
};

// Skips "let "/"const "/"def " plus the binding name, returning the byte
// offset just past the name.
fn find_post_name_offset(data: []u8, start: size) size = {
	let i = start;
	// Skip a leading keyword (let/const/def/static).
	for (i < len(data) && is_word_byte_ih(data[i]); i += 1) void;
	for (i < len(data) && is_ws(data[i]); i += 1) void;
	// Skip the name.
	for (i < len(data) && is_word_byte_ih(data[i]); i += 1) void;
	return i;
};

fn emit_param_hints(
	s: *server,
	doc: *document,
	su: *ast::subunit,
	idx: *analysis::file_index,
	arr: *[]json::value,
) void = {
	const data = analysis::bytes(&doc.buf);
	let i = 0z;
	for (i < len(data); i += 1) {
		// Look for an identifier followed by '(' at top level. The
		// 'top level' check is approximated by skipping comments and
		// strings, which we can't easily do without a token stream;
		// the hare::lex pass would be more robust. For now use a
		// simple state machine.
		const b = data[i];
		if (!is_word_byte_ih(b)) continue;
		// Find end of identifier.
		let j = i;
		for (j < len(data) && is_word_byte_ih(data[j]); j += 1) void;
		// Must be followed by '('.
		if (j >= len(data) || data[j] != '(': u8) {
			i = j - 1;
			continue;
		};
		// Skip function declarations themselves — the `fn name(` form
		// is not a call site. Without this we'd render parameter hints
		// on top of the parameter declarations.
		if (preceded_by_fn(data, i)) {
			i = j - 1;
			continue;
		};
		const name = strings::fromutf8(data[i..j])!;
		// Resolve.
		const sym = match (analysis::find_by_short_name(idx, name)) {
		case let p: *analysis::symbol =>
			yield p;
		case void =>
			i = j - 1;
			continue;
		};
		if (sym.kind != analysis::symbol_kind::FUNCTION) {
			i = j - 1;
			continue;
		};
		// Find the decl.
		const decl_idx = match (find_decl_idx(su, name)) {
		case let n: size =>
			yield n;
		case void =>
			i = j - 1;
			continue;
		};
		const params = decl_param_names(&su.decls[decl_idx]);
		defer free(params);
		// Walk the argument list.
		let arg_starts = walk_arg_starts(data, j);
		defer free(arg_starts);
		const enc = position_encoding(s);
		const limit = if (len(arg_starts) < len(params)) {
			yield len(arg_starts);
		} else {
			yield len(params);
		};
		for (let k = 0z; k < limit; k += 1) {
			if (len(params[k]) == 0) continue;
			const off = arg_starts[k];
			const pos = analysis::byte_to_position(data, doc.buf.line_index, enc, off);
			let hint = json::newobject();
			let p_obj = json::newobject();
			json::put(&p_obj, "line", pos.line: f64)!;
			json::put(&p_obj, "character", pos.character: f64)!;
			json::put(&hint, "position", p_obj)!;
			const lbl = strings::concat(params[k], ":")!;
			defer free(lbl);
			json::set(&hint, "label", lbl: json::value)!;
			json::put(&hint, "kind", 2: f64)!; // 2 = Parameter
			json::put(&hint, "paddingRight", true: json::value)!;
			let cur = *arr;
			append(cur, hint: json::value)!;
			*arr = cur;
		};
		i = j;
	};
};

fn is_word_byte_ih(b: u8) bool = {
	if (b >= 'a': u8 && b <= 'z': u8) return true;
	if (b >= 'A': u8 && b <= 'Z': u8) return true;
	if (b >= '0': u8 && b <= '9': u8) return true;
	return b == '_': u8;
};

// True when the identifier starting at `i` is preceded (after skipping
// whitespace) by the keyword `fn` standing on its own. Used to skip
// function declaration names so we don't render parameter hints on the
// parameter list of the declaration itself.
fn preceded_by_fn(data: []u8, i: size) bool = {
	if (i < 3) return false; // need at least "fn " before
	let k = i;
	for (k > 0 && is_ws(data[k - 1]); k -= 1) void;
	if (k < 2) return false;
	if (data[k - 1] != 'n': u8 || data[k - 2] != 'f': u8) return false;
	// The `fn` must itself be a standalone word.
	if (k == 2) return true;
	return !is_word_byte_ih(data[k - 3]);
};

fn find_decl_idx(su: *ast::subunit, name: str) (size | void) = {
	for (let i = 0z; i < len(su.decls); i += 1) {
		const id = decl_ident_ih(&su.decls[i]);
		if (len(id) > 0 && id[len(id) - 1] == name) return i;
	};
	return void;
};

fn decl_ident_ih(d: *ast::decl) ast::ident = {
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

fn decl_param_names(d: *ast::decl) []str = {
	let out: []str = [];
	match (d.decl) {
	case let f: ast::decl_func =>
		match (f.prototype.repr) {
		case let proto: ast::func_type =>
			for (let i = 0z; i < len(proto.params); i += 1) {
				append(out, proto.params[i].name)!;
			};
		case => void;
		};
	case => void;
	};
	return out;
};

// Returns the byte offsets of each argument's start within `data`, given
// `paren_at` is the index of the '(' after the callee.
fn walk_arg_starts(data: []u8, paren_at: size) []size = {
	let out: []size = [];
	let i = paren_at + 1;
	let depth: int = 0;
	// Skip whitespace before first arg.
	for (i < len(data) && is_ws(data[i]); i += 1) void;
	if (i >= len(data) || data[i] == ')': u8) return out;
	append(out, i)!;
	for (i < len(data); i += 1) {
		const b = data[i];
		switch (b) {
		case '(': u8, '[': u8, '{': u8 =>
			depth += 1;
		case ')': u8 =>
			if (depth == 0) return out;
			depth -= 1;
		case ']': u8, '}': u8 =>
			depth -= 1;
		case ',': u8 =>
			if (depth == 0) {
				let k = i + 1;
				for (k < len(data) && is_ws(data[k]); k += 1) void;
				if (k < len(data)) {
					append(out, k)!;
				};
			};
		case => void;
		};
	};
	return out;
};

fn is_ws(b: u8) bool = {
	return b == ' ': u8 || b == '\t': u8 || b == '\n': u8 || b == '\r': u8;
};

export fn handle_inlay_hint_resolve(s: *server, r: lsp::request) void = {
	const v: json::value = match (r.params) {
	case let v: json::value =>
		yield match (json::dup(v)) {
		case let copy: json::value =>
			yield copy;
		case nomem =>
			send_error(s, r.id, lsp::INTERNAL_ERROR, "out of memory");
			return;
		};
	case void =>
		yield json::_null: json::value;
	};
	defer json::finish(v);
	match (lsp::encode_response_result(s.out, r.id, v)) {
	case size => void;
	case => void;
	};
};

fn uri_from_ih(p: (json::value | void)) (str | void) = {
	const v = match (p) {
	case let v: json::value =>
		yield v;
	case void =>
		return void;
	};
	const obj = match (v) {
	case let o: json::object =>
		yield o;
	case =>
		return void;
	};
	const td = match (json::get(&obj, "textDocument")) {
	case let p: *json::value =>
		yield match (*p) {
		case let o: json::object =>
			yield o;
		case =>
			return void;
		};
	case =>
		return void;
	};
	match (json::get(&td, "uri")) {
	case let p: *json::value =>
		match (*p) {
		case let s: str =>
			return s;
		case =>
			return void;
		};
	case =>
		return void;
	};
};

fn send_array_ih(s: *server, id: lsp::id, arr: []json::value) void = {
	const v: json::value = arr;
	defer json::finish(v);
	match (lsp::encode_response_result(s.out, id, v)) {
	case size => void;
	case => void;
	};
};
