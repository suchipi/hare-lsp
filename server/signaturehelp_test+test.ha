// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

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
