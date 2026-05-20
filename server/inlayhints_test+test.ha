// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use encoding::json;
use lsp;
use memio;
use strings;

// Unit tests for handle_inlay_hint. The e2e tests in
// e2e/inlayhints+test.ha cover the wire-protocol layer; these
// exercise the handler directly so a regression to the in-process
// path (config gating, label format, kind) fails fast.
fn run_inlay_hints(s: *server, uri: str, req_id: f64) []json::value = {
	const params =
		strings::concat(`{"textDocument":{"uri":"`, uri,
			`"},"range":{"start":{"line":0,"character":0},"end":{"line":1000,"character":0}}}`
		)!;
	defer free(params);
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = req_id,
		method = strings::dup("textDocument/inlayHint")!,
		params = pv,
	};
	defer free(r.method);
	handle_inlay_hint(s, r);

	const v = skip_to_response(s.out: *memio::stream, req_id);
	defer json::finish(v);
	const result = *(json::get(&(v as json::object), "result") as *json::value);
	const arr = result as []json::value;
	let dup_arr: []json::value = [];
	for (let i = 0z; i < len(arr); i += 1) {
		match (json::dup(arr[i])) {
		case let v: json::value =>
			append(dup_arr, v)!;
		case nomem => abort();
		};
	};
	return dup_arr;
};

fn finish_hint_arr(arr: []json::value) void = {
	for (let i = 0z; i < len(arr); i += 1) {
		json::finish(arr[i]);
	};
	free(arr);
};

@test fn inlay_hints_emit_inferred_type_for_let_binding() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	// `let answer = 42` — no declared type, so the hint should be
	// emitted with a type label.
	nav_open(&s, "file:///ih_let.ha", "def answer = 42;\\n");
	const arr = run_inlay_hints(&s, "file:///ih_let.ha", 4000.0);
	defer finish_hint_arr(arr);
	assert(len(arr) >= 1, "let-without-type must emit an inferred-type hint");
	// Every hint must be Type-kind (1) and have a label starting
	// with ": " (the type prefix).
	for (let i = 0z; i < len(arr); i += 1) {
		const it = arr[i] as json::object;
		const kind = *(json::get(&it, "kind") as *json::value) as f64;
		assert(kind == 1.0, "inferred-type hints must use kind=Type(1)");
		const label = *(json::get(&it, "label") as *json::value) as str;
		assert(
			strings::hasprefix(label, ": "),
			"inferred-type hint label must start with `: `"
		);
	};
};

@test fn inlay_hints_skip_let_with_explicit_type() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	// Both bindings have explicit type annotations, so the inferred-
	// type pass must NOT emit hints for them.
	nav_open(&s, "file:///ih_typed.ha",
		"def answer: int = 42;\\nlet g: int = 99;\\n");
	const arr = run_inlay_hints(&s, "file:///ih_typed.ha", 4001.0);
	defer finish_hint_arr(arr);
	// Filter to only inferred-type hints. The pass should produce
	// none for explicitly-typed bindings.
	let typed_hints = 0z;
	for (let i = 0z; i < len(arr); i += 1) {
		const it = arr[i] as json::object;
		const kind = *(json::get(&it, "kind") as *json::value) as f64;
		if (kind == 1.0) typed_hints += 1;
	};
	assert(
		typed_hints == 0,
		"explicit type annotations must suppress inferred-type hints"
	);
};

@test fn inlay_hints_disabled_returns_empty_array() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	// Disabling both inlay-hint configs short-circuits the handler.
	s.config.inlay_hints_parameter_names = false;
	s.config.inlay_hints_inferred_types = false;
	nav_open(&s, "file:///ih_off.ha",
		"def answer = 42;\\nfn helper(name: str) void = void;\\nfn caller() void = helper(\\\"x\\\");\\n"
	);
	const arr = run_inlay_hints(&s, "file:///ih_off.ha", 4002.0);
	defer finish_hint_arr(arr);
	assert(
		len(arr) == 0,
		"disabled inlay hints must produce an empty array, not a default-populated one"
	);
};

fn count_param_hints(arr: []json::value) size = {
	let n = 0z;
	for (let i = 0z; i < len(arr); i += 1) {
		const it = arr[i] as json::object;
		const kind = *(json::get(&it, "kind") as *json::value) as f64;
		if (kind == 2.0) n += 1;
	};
	return n;
};

// Regression: identifier-shaped tokens inside line comments must not be
// treated as call sites. Without the token_skip_noncode pass, the
// `helper(` in the comment text would resolve to the real `helper`
// function and emit a spurious parameter hint.
@test fn inlay_hints_skip_call_in_line_comment() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///ih_line_comment.ha",
		"fn helper(name: str) void = void;\\n// helper(fake) is just a comment\\nfn caller() void = helper(\\\"real\\\");\\n"
	);
	const arr = run_inlay_hints(&s, "file:///ih_line_comment.ha", 4010.0);
	defer finish_hint_arr(arr);
	assert(
		count_param_hints(arr) == 1,
		"exactly one parameter hint for the real call - the in-comment call must not emit"
	);
};

// Same as the line-comment case but the spurious match is inside a
// block comment.
@test fn inlay_hints_skip_call_in_block_comment() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///ih_block_comment.ha",
		"fn helper(name: str) void = void;\\nfn caller() void = { /* helper(fake) */ helper(\\\"real\\\"); };\\n"
	);
	const arr = run_inlay_hints(&s, "file:///ih_block_comment.ha", 4011.0);
	defer finish_hint_arr(arr);
	assert(
		count_param_hints(arr) == 1,
		"exactly one parameter hint for the real call - the in-comment call must not emit"
	);
};

// String content can contain text that looks like a call site. Without
// noncode skipping, the scanner would resolve `helper` inside the
// string literal and emit a parameter hint pointing at characters
// inside the string.
@test fn inlay_hints_skip_call_in_string_literal() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///ih_string.ha",
		"fn helper(name: str) void = void;\\nconst note: str = \\\"helper(fake)\\\";\\nfn caller() void = helper(\\\"real\\\");\\n"
	);
	const arr = run_inlay_hints(&s, "file:///ih_string.ha", 4012.0);
	defer finish_hint_arr(arr);
	assert(
		count_param_hints(arr) == 1,
		"exactly one parameter hint for the real call - the in-string call must not emit"
	);
};

// Raw strings (backtick form) have different escaping rules from
// double-quoted strings but must also be opaque to the call-site
// scanner.
@test fn inlay_hints_skip_call_in_raw_string() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///ih_raw.ha",
		"fn helper(name: str) void = void;\\nconst note: str = `helper(fake)`;\\nfn caller() void = helper(\\\"real\\\");\\n"
	);
	const arr = run_inlay_hints(&s, "file:///ih_raw.ha", 4013.0);
	defer finish_hint_arr(arr);
	assert(
		count_param_hints(arr) == 1,
		"exactly one parameter hint for the real call - the in-raw-string call must not emit"
	);
};

// A `,` inside a string argument must NOT be counted as an argument
// separator. With the bug, walk_arg_starts would count the in-string
// comma as a separator and emit the second hint at the wrong column.
@test fn inlay_hints_comma_inside_string_not_counted() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///ih_arg_comma.ha",
		"fn helper(name: str, count: int) void = void;\\nfn caller() void = helper(\\\"a, b\\\", 5);\\n"
	);
	const arr = run_inlay_hints(&s, "file:///ih_arg_comma.ha", 4014.0);
	defer finish_hint_arr(arr);
	// The `count:` hint must land at the column of `5` (col 34 of
	// line 1), not somewhere inside the string. With the bug it would
	// land at col 30 (the `b` of "a, b").
	let saw_name = false;
	let saw_count_at_5 = false;
	for (let i = 0z; i < len(arr); i += 1) {
		const it = arr[i] as json::object;
		const kind = *(json::get(&it, "kind") as *json::value) as f64;
		if (kind != 2.0) continue;
		const label = *(json::get(&it, "label") as *json::value) as str;
		const pos = *(json::get(&it, "position") as *json::value) as json::object;
		const line = *(json::get(&pos, "line") as *json::value) as f64;
		const ch = *(json::get(&pos, "character") as *json::value) as f64;
		if (label == "name:" && line == 1.0 && ch == 26.0) saw_name = true;
		if (label == "count:" && line == 1.0 && ch == 34.0) {
			saw_count_at_5 = true;
		};
	};
	assert(
		saw_name,
		"first-arg hint must land at the opening quote of the string"
	);
	assert(
		saw_count_at_5,
		"second-arg hint must land at `5`, not inside the string literal"
	);
};

// A `)` inside a block comment in the argument list must not be
// treated as the end of the call - the call continues to the real
// closing paren.
@test fn inlay_hints_close_paren_in_comment_not_treated_as_end() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///ih_paren_in_comment.ha",
		"fn helper(name: str, count: int) void = void;\\nfn caller() void = helper(\\\"a\\\" /* end ) */, 5);\\n"
	);
	const arr = run_inlay_hints(&s, "file:///ih_paren_in_comment.ha", 4015.0);
	defer finish_hint_arr(arr);
	let saw_count = false;
	for (let i = 0z; i < len(arr); i += 1) {
		const it = arr[i] as json::object;
		const kind = *(json::get(&it, "kind") as *json::value) as f64;
		if (kind != 2.0) continue;
		const label = *(json::get(&it, "label") as *json::value) as str;
		if (label == "count:") saw_count = true;
	};
	assert(
		saw_count,
		"fake `)` inside a block comment must not prematurely end the call"
	);
};

// A `)` inside a raw-string argument must not be treated as the end
// of the call.
@test fn inlay_hints_close_paren_in_raw_string_not_treated_as_end() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///ih_paren_in_raw.ha",
		"fn helper(name: str, count: int) void = void;\\nfn caller() void = helper(`a)b`, 5);\\n"
	);
	const arr = run_inlay_hints(&s, "file:///ih_paren_in_raw.ha", 4016.0);
	defer finish_hint_arr(arr);
	let saw_name = false;
	let saw_count = false;
	for (let i = 0z; i < len(arr); i += 1) {
		const it = arr[i] as json::object;
		const kind = *(json::get(&it, "kind") as *json::value) as f64;
		if (kind != 2.0) continue;
		const label = *(json::get(&it, "label") as *json::value) as str;
		if (label == "name:") saw_name = true;
		if (label == "count:") saw_count = true;
	};
	assert(saw_name, "first-arg hint must be emitted for the raw-string arg");
	assert(
		saw_count,
		"second-arg hint must still be emitted despite raw-string `)` content"
	);
};

// Sanity: the parameter-name scanner should emit hints for a plain
// call site. This guards against a regression that disables the pass
// entirely (which all the negative tests above would silently accept).
@test fn inlay_hints_emit_param_hint_for_real_call() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///ih_plain.ha",
		"fn helper(name: str) void = void;\\nfn caller() void = helper(\\\"real\\\");\\n"
	);
	const arr = run_inlay_hints(&s, "file:///ih_plain.ha", 4017.0);
	defer finish_hint_arr(arr);
	let saw_name = false;
	for (let i = 0z; i < len(arr); i += 1) {
		const it = arr[i] as json::object;
		const kind = *(json::get(&it, "kind") as *json::value) as f64;
		if (kind != 2.0) continue;
		const label = *(json::get(&it, "label") as *json::value) as str;
		const pos = *(json::get(&it, "position") as *json::value) as json::object;
		const line = *(json::get(&pos, "line") as *json::value) as f64;
		const ch = *(json::get(&pos, "character") as *json::value) as f64;
		if (label == "name:" && line == 1.0 && ch == 26.0) saw_name = true;
	};
	assert(saw_name, "real call must emit a `name:` hint at the arg position");
};
