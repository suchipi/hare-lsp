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
