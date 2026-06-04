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
//
// The callee is then resolved the same way hover/definition resolve names:
// a bare name hits the open file's index first; a qualified name
// (`io::readall`) or an unresolved bare name falls through to
// workspace_lookup_aware, which searches the workspace index and the
// lazily-built stdlib/third-party index. That's what makes signature help
// fire for stdlib calls like `io::readall(`.

use analysis;
use encoding::json;
use hare::ast;
use lsp;
use strings;

// @param s: borrowed
export fn handle_signature_help(s: *server, r: lsp::request) void = {
	const (uri, pos) = match (parse_text_document_position(r.params)) {
	case let v: (str, lsp::position) =>
		yield v;
	case void =>
		send_null_result(s, r.id);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document =>
		yield p;
	case null =>
		send_null_result(s, r.id);
		return;
	};
	const data = analysis::bytes(&doc.buf);
	const off = analysis::position_to_byte(data, doc.buf.line_index,
		position_encoding(s),
		analysis::position {
			line = pos.line,
			character = pos.character,
		});
	const ctx = match (find_call_context(data, off)) {
	case let c: call_context =>
		yield c;
	case void =>
		send_null_result(s, r.id);
		return;
	};
	defer free(ctx.callee_name);

	const cache = parse_of(doc);

	// A qualified call like `io::readall(...)` names a symbol in another
	// module; the open file's own index never holds it, and a local symbol
	// that happens to share the short name must not shadow it. So only the
	// bare-name case consults the local file index first.
	// qualifier_prefix_at returns "" for a bare name.
	const qualifier = analysis::qualifier_prefix_at(data, ctx.callee_start);
	defer free(qualifier);
	if (len(qualifier) == 0) {
		match (find_decl_by_name(&cache.pr.subunit, ctx.callee_name)) {
		case let i: size =>
			send_local_signature(s, r.id, doc, ctx, &cache.pr.subunit.decls[i]);
			return;
		case void => void;
		};
	};

	// Either the call is qualified, or it's a bare name not declared in the
	// open file. Resolve module-aware against the workspace index and — for
	// stdlib/third-party modules like `io` — the lazily-built stdlib index.
	// workspace_lookup_aware (navigation.ha) drives the on-demand indexing,
	// so `io::readall(` works even when the user has never navigated into
	// `io` before. This is the same resolver hover and go-to-definition use.
	match (workspace_lookup_aware(s, doc, data, ctx.callee_start,
		ctx.callee_name)) {
	case let e: *analysis::workspace_entry =>
		if (e.kind != analysis::symbol_kind::FUNCTION) {
			send_null_result(s, r.id);
			return;
		};
		send_entry_signature(s, r.id, ctx, e);
	case void =>
		send_null_result(s, r.id);
	};
};

// Renders and sends signature help for a function declared in the open
// document. Reuses render_decl_signature (shared with hover) so the popup
// matches the hover surface — neither should dump the function body into the
// editor — and collect_param_labels so each parameter label is a substring
// of the signature label (required for the client to highlight the active
// argument).
//
// @param s: borrowed
// @param id: borrowed
// @param doc: borrowed
// @param d: borrowed
fn send_local_signature(
	s: *server,
	id: lsp::id,
	doc: *document,
	ctx: call_context,
	d: *ast::decl,
) void = {
	const sig = render_decl_signature(s, doc, d);
	defer free(sig);

	let info = json::newobject();
	json::set(&info, "label", sig: json::value)!;

	// Each parameter label is `"<name>: <type>"` so it matches a
	// substring of the signature label — that's how the LSP client
	// figures out which range to highlight for the active parameter.
	let param_labels = analysis::collect_param_labels(d);
	defer analysis::free_param_labels(param_labels);
	let params_arr: []json::value = [];
	for (let i = 0z; i < len(param_labels); i += 1) {
		let p = json::newobject();
		json::set(&p, "label", param_labels[i]: json::value)!;
		append(params_arr, p: json::value)!;
	};
	json::put(&info, "parameters", params_arr: json::value)!;

	let signatures: []json::value = [];
	append(signatures, info: json::value)!;
	let result = json::newobject();
	json::put(&result, "signatures", signatures: json::value)!;
	json::put(&result, "activeSignature", 0: f64)!;
	const active = if (ctx.active_param < len(param_labels)) ctx.active_param
		else 0z;
	json::put(&result, "activeParameter", active: u64: f64)!;
	const v: json::value = result;
	defer json::finish(v);
	match (lsp::encode_response_result(s.out, id, v)) {
	case size => void;
	case => void;
	};
};

// Builds and sends a SignatureHelp from a resolved workspace/stdlib entry.
// Indexing renders the signature label and per-parameter labels at index
// time and caches them on the workspace_entry. That keeps the cross-module
// popup in lockstep with the in-open-document popup so LSP clients can match
// each parameter label as a substring of the signature label and highlight
// the active argument.
//
// @param s: borrowed
// @param id: borrowed
// @param e: borrowed
fn send_entry_signature(
	s: *server,
	id: lsp::id,
	ctx: call_context,
	e: *analysis::workspace_entry,
) void = {
	const label = if (len(e.signature) > 0) e.signature else e.full_name;
	let info = json::newobject();
	json::set(&info, "label", label: json::value)!;
	let params_arr: []json::value = [];
	for (let j = 0z; j < len(e.param_labels); j += 1) {
		let p = json::newobject();
		json::set(&p, "label", e.param_labels[j]: json::value)!;
		append(params_arr, p: json::value)!;
	};
	json::put(&info, "parameters", params_arr: json::value)!;
	let signatures: []json::value = [];
	append(signatures, info: json::value)!;
	let result = json::newobject();
	json::put(&result, "signatures", signatures: json::value)!;
	json::put(&result, "activeSignature", 0: f64)!;
	const active = if (ctx.active_param < len(e.param_labels)) ctx.active_param
		else 0z;
	json::put(&result, "activeParameter", active: u64: f64)!;
	const v: json::value = result;
	defer json::finish(v);
	match (lsp::encode_response_result(s.out, id, v)) {
	case size => void;
	case => void;
	};
};

type call_context = struct {
	// @owned
	callee_name: str,
	// Byte offset of the first byte of callee_name in the buffer. Lets
	// the resolver read the module qualifier (the `io` in `io::readall`)
	// so qualified calls resolve against the right stdlib module.
	callee_start: size,
	active_param: size,
};

// Scans forward from the start of the buffer to `off`, tracking paren
// depth and remembering the most recent enclosing '(' (the one whose
// closing ')' has not yet been seen at the cursor). Skips strings,
// runes, raw strings, and line/block comments so commas inside them
// don't get counted as argument separators.
//
// Implementation note: walking forward (rather than backward from the
// cursor as a naïve version would) is necessary to make string/comment
// skipping correct — the lexer state at position `i` depends on what
// came before.
//
// @param data: borrowed
// @returns: owned
fn find_call_context(data: []u8, off: size) (call_context | void) = {
	const limit = if (off > len(data)) len(data) else off;
	// A stack of (open_paren_offset, active_param_count) — one entry per
	// currently-unmatched '('. The top of the stack is the enclosing
	// call.
	let stack: [](size, size) = [];
	defer free(stack);
	let i = 0z;
	for (i < limit) {
		const after = analysis::token_skip_noncode(data, i, limit);
		if (after > i) {
			i = after;
			continue;
		};
		switch (data[i]) {
		case '(': u8 =>
			append(stack, (i, 0z))!;
		case ')': u8 =>
			if (len(stack) > 0) {
				delete(stack[len(stack) - 1]);
			};
		case ',': u8 =>
			if (len(stack) > 0) {
				stack[len(stack) - 1].1 += 1;
			};
		case => void;
		};
		i += 1;
	};
	if (len(stack) == 0) return void;
	const (open_at, active) = stack[len(stack) - 1];
	// The callee name ends just before open_at, possibly preceded by
	// spaces.
	let e = open_at;
	for (e > 0 && (data[e - 1] == ' ': u8 || data[e - 1] == '\t': u8);
			e -= 1) void;
	let ns = e;
	for (ns > 0; ns -= 1) {
		const cb = data[ns - 1];
		if (!analysis::is_ident_byte(cb)) break;
	};
	if (ns == e) return void;
	const name = strings::dup(strings::fromutf8(data[ns..e])!)!;
	return call_context {
		callee_name = name,
		callee_start = ns,
		active_param = active,
	};
};
