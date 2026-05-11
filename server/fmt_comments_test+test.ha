// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use strings;

@test fn fmt_comments_collects_single_line_comment() void = {
	const src = strings::toutf8("fn x() = 1; // hi\n");
	const cs = collect_comments(src);
	defer finish_comments(cs);
	assert(len(cs) == 1);
	assert(cs[0].text == " hi");
	assert(cs[0].line == 0);
};

@test fn fmt_comments_skips_double_slash_inside_string() void = {
	const src = strings::toutf8(`let s = "https://example"; // real`);
	const cs = collect_comments(src);
	defer finish_comments(cs);
	assert(len(cs) == 1);
	assert(cs[0].text == " real");
};

@test fn fmt_comments_skips_double_slash_inside_rune_literal() void = {
	const src = strings::toutf8(`let r = '/'; // real`);
	const cs = collect_comments(src);
	defer finish_comments(cs);
	assert(len(cs) == 1);
	assert(cs[0].text == " real");
};

@test fn fmt_comments_skips_double_slash_inside_raw_string() void = {
	const src = strings::toutf8("let s = `url//thing`; // real\n");
	const cs = collect_comments(src);
	defer finish_comments(cs);
	assert(len(cs) == 1);
	assert(cs[0].text == " real");
};

@test fn fmt_comments_collects_multiple_in_order() void = {
	const src = strings::toutf8("// one\n// two\nfn f() = 0;\n// three\n");
	const cs = collect_comments(src);
	defer finish_comments(cs);
	assert(len(cs) == 3);
	assert(cs[0].text == " one");
	assert(cs[1].text == " two");
	assert(cs[2].text == " three");
	assert(cs[0].line == 0);
	assert(cs[1].line == 1);
	assert(cs[2].line == 3);
};

@test fn fmt_comments_pop_before_advances_cursor() void = {
	const src = strings::toutf8("// a\n// b\nfn f() = 0;\n");
	let cs = collect_comments(src);
	defer finish_comments(cs);
	let c = comment_cursor { comments = cs, pos = 0 };
	// `// a` starts at 0, `// b` starts at 5, fn at 10.
	const before_fn = pop_before(&c, 10);
	assert(len(before_fn) == 2);
	assert(before_fn[0].text == " a");
	assert(before_fn[1].text == " b");
	const rest = pop_before(&c, 100);
	assert(len(rest) == 0);
};
