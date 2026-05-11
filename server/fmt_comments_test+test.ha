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

@test fn fmt_blank_lines_detects_single_blank() void = {
	const src = strings::toutf8("a;\n\nb;\n");
	const bl = collect_blank_lines(src);
	defer free(bl);
	assert(len(bl) == 1);
	// "a;\n" ends at offset 3; the second \n is at offset 3, so the
	// recorded offset is 4 (one past the second \n).
	// "a" "; " "\n" "\n" "b" -> offsets 0,1,2,3,4
	assert(bl[0] == 4);
};

@test fn fmt_blank_lines_collapses_multiple_blanks() void = {
	const src = strings::toutf8("a;\n\n\n\nb;\n");
	const bl = collect_blank_lines(src);
	defer free(bl);
	// Four \n in a row → still only one blank-line marker.
	assert(len(bl) == 1);
};

@test fn fmt_blank_lines_ignores_blanks_inside_raw_string() void = {
	const src = strings::toutf8("let s = `\n\nstuff`; let t = 1;\n");
	const bl = collect_blank_lines(src);
	defer free(bl);
	assert(len(bl) == 0);
};

@test fn fmt_blank_between_open_interval() void = {
	const src = strings::toutf8("a;\n\nb;\n");
	const bl = collect_blank_lines(src);
	defer free(bl);
	// Between byte 1 (the ;) and byte 5 (the b after blanks).
	assert(blank_between(bl, 1, 5));
	// Same range but next_start before the blank marker should be false.
	assert(!blank_between(bl, 1, 3));
};

@test fn fmt_blank_between_no_source_blank_returns_false() void = {
	const src = strings::toutf8("a;\nb;\n");
	const bl = collect_blank_lines(src);
	defer free(bl);
	assert(!blank_between(bl, 0, 4));
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
