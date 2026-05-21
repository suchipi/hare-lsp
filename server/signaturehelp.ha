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
		analysis::position { line = pos.line, character = pos.character });
	const ctx = match (find_call_context(data, off)) {
	case let c: call_context =>
		yield c;
	case void =>
		send_null_result(s, r.id);
		return;
	};
	defer free(ctx.callee_name);

	// Resolve the callee in the file's index, then in the workspace index.
	const cache = parse_of(doc);
	const decl_idx = match (find_decl_by_name(&cache.pr.subunit,
		ctx.callee_name)) {
	case let i: size =>
		yield i;
	case void =>
		// Try workspace.
		send_workspace_signature(s, r.id, ctx);
		return;
	};

	// Body-stripped signature: hover already does this via
	// render_decl_signature in navigation.ha. Reusing it here keeps the
	// two surfaces consistent — neither should dump the function body
	// into the editor's signature popup.
	const sig = render_decl_signature(&cache.pr.subunit.decls[decl_idx]);
	defer free(sig);

	let signatures: []json::value = [];
	let info = json::newobject();
	json::set(&info, "label", sig: json::value)!;

	// Each parameter label is `"<name>: <type>"` so it matches a
	// substring of the signature label — that's how the LSP client
	// figures out which range to highlight for the active parameter.
	// The previous label `"param N"` had no relationship to the
	// signature text and so prevented any highlight from rendering.
	let param_labels = analysis::collect_param_labels(
		&cache.pr.subunit.decls[decl_idx]);
	defer analysis::free_param_labels(param_labels);
	let params_arr: []json::value = [];
	for (let i = 0z; i < len(param_labels); i += 1) {
		let p = json::newobject();
		json::set(&p, "label", param_labels[i]: json::value)!;
		append(params_arr, p: json::value)!;
	};
	json::put(&info, "parameters", params_arr: json::value)!;
	append(signatures, info: json::value)!;

	let result = json::newobject();
	json::put(&result, "signatures", signatures: json::value)!;
	json::put(&result, "activeSignature", 0: f64)!;
	const active = if (ctx.active_param < len(param_labels)) ctx.active_param
		else 0z;
	json::put(&result, "activeParameter", active: u64: f64)!;
	const v: json::value = result;
	defer json::finish(v);
	match (lsp::encode_response_result(s.out, r.id, v)) {
	case size => void;
	case => void;
	};
};

// @param s: borrowed
// @param id: borrowed
fn send_workspace_signature(s: *server, id: lsp::id, ctx: call_context) void = {
	// Indexing renders the signature label and per-parameter labels at
	// index time and caches them on the workspace_entry. That keeps the
	// cross-file popup in lockstep with the in-open-document popup so
	// LSP clients can match each parameter label as a substring of the
	// signature label and highlight the active argument.
	for (let i = 0z; i < len(s.workspace_index.entries); i += 1) {
		const e = &s.workspace_index.entries[i];
		if (e.kind != analysis::symbol_kind::FUNCTION) continue;
		if (e.short_name != ctx.callee_name) continue;
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
		return;
	};
	send_null_result(s, id);
};

type call_context = struct {
	// @owned
	callee_name: str,
	// owned; caller must free
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
	for (e > 0 &&
	(data[e - 1] == ' ': u8 ||
	data[e - 1] == '\t': u8); e -= 1) void;
	let ns = e;
	for (ns > 0; ns -= 1) {
		const cb = data[ns - 1];
		if (!analysis::is_ident_byte(cb)) break;
	};
	if (ns == e) return void;
	const name = strings::dup(strings::fromutf8(data[ns..e])!)!;
	return call_context {
		callee_name = name,
		active_param = active,
	};
};
