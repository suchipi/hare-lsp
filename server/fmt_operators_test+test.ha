// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Regression tests for parentheses around binary operators. The
// formatter strips unnecessary parens based on precedence, but for
// non-associative operators (`-`, `/`, `%`, `<<`, `>>`) the right
// operand at equal precedence still needs its own parens, because
// `a - (b - 1)` and `a - b - 1` parse to different expressions.

use analysis;
use io;
use memio;
use strings;

fn fmt_operators_roundtrip(src: str) str = {
	const data = strings::toutf8(src);
	let pr = analysis::parse_recover(data, "<operators>");
	defer analysis::finish_parse_result(&pr);
	assert(len(pr.errors) == 0, "test source must parse cleanly");

	const cs = collect_comments(data);
	defer finish_comments(cs);
	const bl = collect_blank_lines(data);
	defer free(bl);
	let cursor = comment_cursor { comments = cs, pos = 0 };
	let d = build_subunit_doc(&pr.subunit, &cursor, bl, data);
	defer doc_finish(&d);

	let buf = memio::dynamic();
	defer io::close(&buf)!;
	pretty(&buf, &d, 80, 0)!;
	return strings::dup(memio::string(&buf)!)!;
};

@test fn fmt_preserves_parens_around_right_minus() void = {
	// `a - (b - 1)` must NOT format to `a - b - 1`; the latter parses
	// as `(a - b) - 1` and differs in the result by 2.
	const src = "export fn f(a: int, b: int) int = a - (b - 1);\n";
	const out = fmt_operators_roundtrip(src);
	defer free(out);
	assert(
		strings::contains(out, "a - (b - 1)"),
		"parens around right operand of `-` must survive"
	);
};

@test fn fmt_preserves_parens_around_right_plus_under_minus() void = {
	// `a - (b + 1)` must NOT collapse to `a - b + 1`. PLUS shares the
	// MINUS precedence level so the formatter would previously drop
	// the parens; the inner addition would then be evaluated AFTER the
	// outer subtraction is split, changing the result.
	const src = "export fn f(a: int, b: int) int = a - (b + 1);\n";
	const out = fmt_operators_roundtrip(src);
	defer free(out);
	assert(
		strings::contains(out, "a - (b + 1)"),
		"parens around right `+` operand under `-` must survive"
	);
};

@test fn fmt_preserves_parens_around_right_div() void = {
	const src = "export fn f(a: int, b: int, c: int) int = a / (b / c);\n";
	const out = fmt_operators_roundtrip(src);
	defer free(out);
	assert(
		strings::contains(out, "a / (b / c)"),
		"parens around right operand of `/` must survive"
	);
};

@test fn fmt_preserves_parens_around_right_shift() void = {
	const src = "export fn f(a: u32, b: u32, c: u32) u32 = a << (b << c);\n";
	const out = fmt_operators_roundtrip(src);
	defer free(out);
	assert(
		strings::contains(out, "a << (b << c)"),
		"parens around right operand of `<<` must survive"
	);
};

@test fn fmt_drops_parens_around_right_plus() void = {
	// `a + (b + c)` is identical to `a + b + c` for integer arithmetic
	// (including unsigned wraparound), so dropping the parens is fine
	// and keeps the source compact.
	const src = "export fn f(a: int, b: int, c: int) int = a + (b + c);\n";
	const out = fmt_operators_roundtrip(src);
	defer free(out);
	assert(
		strings::contains(out, "a + b + c"),
		"associative `+` should still flatten"
	);
};

@test fn fmt_drops_parens_around_right_times() void = {
	const src = "export fn f(a: int, b: int, c: int) int = a * (b * c);\n";
	const out = fmt_operators_roundtrip(src);
	defer free(out);
	assert(
		strings::contains(out, "a * b * c"),
		"associative `*` should still flatten"
	);
};
