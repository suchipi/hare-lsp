// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use analysis;
use encoding::json;
use lsp;
use strings;

@test fn sig_help_counts_args_in_simple_call() void = {
	// f(a, b|, c) — cursor at | should be active param 1.
	const text = "f(a, b, c)";
	const off = strings::index(text, 'b') as size + 1;
	const ctx = find_call_context(strings::toutf8(text), off) as call_context;
	defer free(ctx.callee_name);
	assert(ctx.callee_name == "f");
	assert(ctx.active_param == 1);
};

@test fn sig_help_ignores_commas_in_strings() void = {
	// f("a,b", |here) — commas inside the string don't bump active.
	const text = `f("a,b", c)`;
	// Position cursor right after the comma that follows the string.
	const off = strings::index(text, ' ') as size + 1;
	const ctx = find_call_context(strings::toutf8(text), off) as call_context;
	defer free(ctx.callee_name);
	assert(ctx.callee_name == "f");
	assert(ctx.active_param == 1);
};

@test fn sig_help_ignores_commas_in_runes() void = {
	// f(',', |here) — char literal comma must not count.
	const text = "f(',', c)";
	const off = strings::index(text, ' ') as size + 1;
	const ctx = find_call_context(strings::toutf8(text), off) as call_context;
	defer free(ctx.callee_name);
	assert(ctx.callee_name == "f");
	assert(ctx.active_param == 1);
};

@test fn sig_help_ignores_commas_in_nested_calls() void = {
	// f(g(a, b), |here) — the commas inside g(...) belong to g, not f.
	const text = "f(g(a, b), c)";
	const bytes = strings::toutf8(text);
	// Search for the SECOND space which precedes 'c' (after ')').
	let count = 0z;
	let i = 0z;
	for (i < len(bytes); i += 1) {
		if (bytes[i] == ' ': u8) {
			count += 1;
			if (count == 2) break;
		};
	};
	const ctx = find_call_context(bytes, i + 1) as call_context;
	defer free(ctx.callee_name);
	assert(ctx.callee_name == "f");
	assert(ctx.active_param == 1);
};

@test fn sig_help_handles_raw_strings() void = {
	// f(`a,b`, |c).
	const text = "f(`a,b`, c)";
	const off = strings::index(text, ' ') as size + 1;
	const ctx = find_call_context(strings::toutf8(text), off) as call_context;
	defer free(ctx.callee_name);
	assert(ctx.callee_name == "f");
	assert(ctx.active_param == 1);
};

@test fn sig_help_handles_line_comment() void = {
	// First-arg line: `f(a, // foo, bar
	//         b|, c)` — cursor on next line after 'b'.
	const text = "f(a, // foo, bar\n         b, c)";
	const bytes = strings::toutf8(text);
	let i = 0z;
	for (i < len(bytes); i += 1) {
		if (bytes[i] == 'b': u8) break;
	};
	const ctx = find_call_context(bytes, i + 1) as call_context;
	defer free(ctx.callee_name);
	assert(ctx.callee_name == "f");
	// Two commas before 'b' but one is inside the // comment; active should be 1.
	assert(ctx.active_param == 1);
};

@test fn sig_help_handles_block_comment() void = {
	// f(a, /* x, y */ b|, c).
	const text = "f(a, /* x, y */ b, c)";
	const bytes = strings::toutf8(text);
	let i = 0z;
	for (i < len(bytes); i += 1) {
		if (bytes[i] == 'b': u8) break;
	};
	const ctx = find_call_context(bytes, i + 1) as call_context;
	defer free(ctx.callee_name);
	assert(ctx.callee_name == "f");
	assert(ctx.active_param == 1);
};

@test fn sig_help_outside_any_call_returns_void() void = {
	const text = "x = 1 + 2";
	match (find_call_context(strings::toutf8(text), len(text))) {
	case call_context => abort("expected void");
	case void => void;
	};
};

@test fn sig_help_reports_callee_start_for_qualified_call() void = {
	// io::readall(|) — find_call_context must report a callee_start that
	// points at the `r` of `readall`, so the resolver can recover the `io`
	// module via qualifier_prefix_at. The old code only returned the bare
	// name (`readall`) and dropped the qualifier, which is why qualified
	// stdlib calls never resolved.
	const text = "io::readall()";
	const bytes = strings::toutf8(text);
	const off = strings::index(text, '(') as size + 1;
	const ctx = find_call_context(bytes, off) as call_context;
	defer free(ctx.callee_name);
	assert(ctx.callee_name == "readall");
	assert(
		bytes[ctx.callee_start] == 'r': u8,
		"callee_start should point at the first byte of the callee name"
	);
	const qualifier = analysis::qualifier_prefix_at(bytes, ctx.callee_start);
	defer free(qualifier);
	assert(
		qualifier == "io",
		"callee_start must let qualifier_prefix_at recover the module qualifier"
	);
};

// A qualified stdlib call (`io::readall(...)`) must produce signature help.
// `readall` lives in the stdlib `io` module, which populates s.stdlib_index
// (NOT the workspace index). The old handler consulted only the open file
// and the workspace index, so qualified stdlib calls returned null -- the
// reported bug. We seed s.stdlib_index the way ensure_stdlib_module_indexed
// would after walking the real tree, and mark `io` already-indexed so the
// lookup never touches the filesystem.
@test fn sig_help_resolves_qualified_stdlib_call() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	analysis::index_file(&s.stdlib_index, "/usr/local/src/hare/stdlib/io/util.ha",
		strings::toutf8(
			"export fn readall(in: handle, buf: []u8) (size | EOF | error) = void;\n")
	);
	append(s.indexed_stdlib_modules, strings::dup("io")!)!;

	const src = `use io; export fn main() void = { let _ = io::readall(buf); };`;
	nav_open(&s, "file:///sig_stdlib.ha", src);

	// Cursor just inside the call, on the first argument.
	const needle = `io::readall(`;
	const col = find_col(src, needle) + len(needle): u32;
	const params = pos_params("file:///sig_stdlib.ha", 0, col);
	defer free(params);
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 1920.0,
		method = strings::dup("textDocument/signatureHelp")!,
		params = pv,
	};
	defer free(r.method);
	handle_signature_help(&s, r);

	const v = skip_to_response(out, 1920.0);
	defer json::finish(v);
	const o = v as json::object;
	const result_obj = match (*(json::get(&o, "result") as *json::value)) {
	case let ro: json::object =>
		yield ro;
	case => abort(
		"stdlib-qualified signatureHelp returned null; the stdlib index was not consulted"
	);
	};
	const sigs =
		*(json::get(&result_obj, "signatures") as *json::value) as []json::value;
	assert(len(sigs) == 1, "expected exactly one SignatureInformation");
	const sig = sigs[0] as json::object;
	const label = *(json::get(&sig, "label") as *json::value) as str;
	assert(
		strings::contains(label, "fn readall(in: handle, buf: []u8)"),
		"label should render the stdlib prototype with parameter types"
	);
	assert(
		!strings::contains(label, "= void"),
		"label must strip the function body on the stdlib path too"
	);
	const ps = *(json::get(&sig, "parameters") as *json::value) as []json::value;
	assert(len(ps) == 2, "should carry both stdlib parameter labels");
	const p0 = ps[0] as json::object;
	assert(
		*(json::get(&p0, "label") as *json::value) as str == "in: handle",
		"parameter[0] label should be `in: handle`"
	);
	const p1 = ps[1] as json::object;
	assert(
		*(json::get(&p1, "label") as *json::value) as str == "buf: []u8",
		"parameter[1] label should be `buf: []u8`"
	);
	const active =
		*(json::get(&result_obj, "activeParameter") as *json::value) as f64;
	assert(active == 0.0, "activeParameter should be 0 on the first argument");
};

// Cross-file: the called function lives in a workspace file that isn't
// open. handle_signature_help should fall back to the workspace_index,
// where index_file has cached the rendered signature label and the
// per-parameter labels, and emit a fully populated SignatureInformation
// with an activeParameter computed from the cursor's argument position.
@test fn sig_help_workspace_fallback_uses_cached_signature() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);

	// Pretend `compute_total` lives in another file in the workspace.
	// Indexing renders + caches its signature; the in-open-doc lookup
	// will miss, exercising the workspace fallback.
	analysis::index_file(&s.workspace_index, "/repo/util.ha",
		strings::toutf8(
			"export fn compute_total(name: str, count: int) int = count;\n"));

	// Caller file: a single line that calls compute_total with the
	// cursor between the comma and the closing paren.
	const src = `export fn main() void = { let _ = compute_total(\"x\", ); };`;
	nav_open(&s, "file:///caller.ha", src);

	// Position the cursor right after the comma + space inside the call.
	// `compute_total("x", ` is the substring; the cursor lands on the
	// character just past it. find_col handles single-line sources.
	const col =
		find_col(src, `compute_total("x", `) + len(`compute_total("x", `): u32;
	const params = pos_params("file:///caller.ha", 0, col);
	defer free(params);
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 1900.0,
		method = strings::dup("textDocument/signatureHelp")!,
		params = pv,
	};
	defer free(r.method);
	handle_signature_help(&s, r);

	const v = skip_to_response(out, 1900.0);
	defer json::finish(v);
	const o = v as json::object;
	const result_obj = *(json::get(&o, "result") as *json::value) as json::object;
	const sigs =
		*(json::get(&result_obj, "signatures") as *json::value) as []json::value;
	assert(
		len(sigs) == 1,
		"workspace fallback should return exactly one SignatureInformation"
	);
	const sig = sigs[0] as json::object;
	const label = *(json::get(&sig, "label") as *json::value) as str;
	assert(
		strings::contains(label, "fn compute_total(name: str, count: int) int"),
		"workspace fallback should render the full cached signature label, not just the bare name"
	);
	assert(
		!strings::contains(label, "= count"),
		"workspace fallback must strip the function body from the label"
	);
	const ps = *(json::get(&sig, "parameters") as *json::value) as []json::value;
	assert(len(ps) == 2, "workspace fallback should carry both parameter labels");
	const p0 = ps[0] as json::object;
	assert(
		*(json::get(&p0, "label") as *json::value) as str == "name: str",
		"parameter[0] label should be `name: str`"
	);
	const p1 = ps[1] as json::object;
	assert(
		*(json::get(&p1, "label") as *json::value) as str == "count: int",
		"parameter[1] label should be `count: int`"
	);
	const active =
		*(json::get(&result_obj, "activeParameter") as *json::value) as f64;
	assert(
		active == 1.0,
		"activeParameter should be 1 when the cursor is past the first comma"
	);
};
