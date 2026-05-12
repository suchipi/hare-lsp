// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Regression tests for literal-preservation bugs the formatter has
// historically had:
//
//   - String literals (raw and quoted) being mangled when the source
//     contains a multi-byte UTF-8 sequence above the literal. The
//     AST stores rune offsets; `analysis::parse_recover` translates
//     them to byte offsets, but the formatter previously did its own
//     redundant rune-to-byte conversion that double-shifted the
//     offset and made `verbatim_string_at` slice the wrong bytes.
//
//   - Numeric literals being normalized through `hare::unparse`
//     (0x80 -> 128, 0o755 -> 493, 1_000_000 -> 1000000), losing the
//     base/grouping the user wrote.

use analysis;
use io;
use memio;
use strings;

// Roundtrips `src` through the formatter and returns the rendered
// output, asserting that parsing succeeded.
fn fmt_literals_roundtrip(src: str) str = {
	const data = strings::toutf8(src);
	let pr = analysis::parse_recover(data, "<literals>");
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

@test fn fmt_preserves_raw_string_after_em_dash_comment() void = {
	// Em-dash (U+2014, three UTF-8 bytes) in a comment above a raw
	// string was the trigger for the harefmt corruption pass. With
	// the duplicate rune-to-byte conversion bug, the formatter
	// would slice 2 bytes off the literal's start and fall back to
	// `unparse`, which re-renders the raw string as `"..."` with
	// inner `"` characters left unescaped — truncating the value.
	const src =
		"// dash — here\n"
		"export let a: str = `{\"key\":\"value\"}`;\n";
	const out = fmt_literals_roundtrip(src);
	defer free(out);
	assert(
		strings::contains(out, "`{\"key\":\"value\"}`"),
		"raw string after em-dash must survive verbatim"
	);
};

@test fn fmt_preserves_quoted_escape_after_em_dash() void = {
	// Quoted string with an escape sequence after a multi-byte
	// rune. The escape `\n` (two source chars) must NOT decay to a
	// literal newline character in the output.
	const src = "// em — dash\n"
		"export let nl: str = \"\\n\";\n";
	const out = fmt_literals_roundtrip(src);
	defer free(out);
	assert(
		strings::contains(out, "\"\\n\""),
		`escape "\n" must survive as the two-char escape, not a literal newline`
	);
};

@test fn fmt_preserves_hex_literal() void = {
	const src = "export def MASK: u8 = 0x80;\n";
	const out = fmt_literals_roundtrip(src);
	defer free(out);
	assert(
		strings::contains(out, "0x80"),
		"hex literal must not be normalized to decimal"
	);
};

@test fn fmt_preserves_octal_literal() void = {
	const src = "export def PERM: int = 0o755;\n";
	const out = fmt_literals_roundtrip(src);
	defer free(out);
	assert(
		strings::contains(out, "0o755"),
		"octal literal must not be normalized to decimal"
	);
};

@test fn fmt_preserves_binary_literal() void = {
	const src = "export def BITS: u8 = 0b1010;\n";
	const out = fmt_literals_roundtrip(src);
	defer free(out);
	assert(
		strings::contains(out, "0b1010"),
		"binary literal must not be normalized to decimal"
	);
};

@test fn fmt_preserves_underscore_grouping() void = {
	const src = "export def N: int = 1_000_000;\n";
	const out = fmt_literals_roundtrip(src);
	defer free(out);
	assert(
		strings::contains(out, "1_000_000"),
		"digit grouping must not be stripped"
	);
};

@test fn fmt_preserves_concatenated_strings() void = {
	const src = `export let s: str = "foo" "bar";` "\n";
	const out = fmt_literals_roundtrip(src);
	defer free(out);
	assert(
		strings::contains(out, `"foo" "bar"`),
		"adjacent concatenated string segments must round-trip"
	);
};

@test fn fmt_match_case_aligns_with_match_keyword() void = {
	// Per the Hare style guide, `case` labels should be at the same
	// indent as the `match` / `switch` keyword, NOT nested one tab
	// deeper inside the `{ ... }`.
	const src =
		"export fn f() void = {\n"
		"\tmatch (g()) {\n"
		"\tcase let x: int =>\n"
		"\t\treturn;\n"
		"\tcase void =>\n"
		"\t\treturn;\n"
		"\t};\n"
		"};\n"
		"fn g() (int | void) = void;\n";
	const out = fmt_literals_roundtrip(src);
	defer free(out);
	// `case let x: int =>` must start with one tab (function body
	// indent) - NOT two (function body + extra match nest).
	assert(
		strings::contains(out, "\n\tcase let x: int =>"),
		"match case labels must align with `match` keyword"
	);
	assert(
		!strings::contains(out, "\n\t\tcase let x: int =>"),
		"match case labels must NOT be nested deeper than `match`"
	);
};

@test fn fmt_const_eq_match_keeps_keyword_on_eq_line() void = {
	// Per the Hare style guide, `const x = match (foo) {` should
	// stay on one line; only the cases inside the braces wrap.
	// Earlier behavior wrapped EVERYTHING containing internal
	// hardlines, producing the noisy `const x =\n\tmatch (...) {`.
	const src =
		"export fn f() void = {\n"
		"\tconst v = match (g()) {\n"
		"\tcase let s: str =>\n"
		"\t\treturn;\n"
		"\tcase void =>\n"
		"\t\treturn;\n"
		"\t};\n"
		"};\n"
		"fn g() (str | void) = void;\n";
	const out = fmt_literals_roundtrip(src);
	defer free(out);
	assert(
		strings::contains(out, "const v = match (g()) {"),
		"`const v = match (...) {` must stay on a single line"
	);
	assert(
		!strings::contains(out, "const v =\n\tmatch"),
		"`=` must not be alone at end of line followed by match"
	);
};

@test fn fmt_enum_always_renders_multi_line() void = {
	// Enums are always rendered multi-line, one variant per line
	// with a trailing comma, even when the contents would fit on
	// one line. This makes adding/removing variants a one-line
	// version-control change and avoids accidental reflow churn.
	const src = "type mode = enum { NONE, WRITE, CHECK };\n";
	const out = fmt_literals_roundtrip(src);
	defer free(out);
	assert(
		strings::contains(out, "enum {\n\tNONE,\n\tWRITE,\n\tCHECK,\n}"),
		"short enums must still be expanded one-variant-per-line"
	);
};

@test fn fmt_long_enum_renders_multi_line() void = {
	// A long enum is also multi-line with a trailing comma on the
	// last variant.
	const src =
		"type m = enum { ONEWITHALONGNAME, TWOWITHALONGNAME, "
		"THREEWITHALONGNAME, FOURWITHALONGNAME, FIVEWITHALONGNAME };\n";
	const out = fmt_literals_roundtrip(src);
	defer free(out);
	assert(
		strings::contains(out, "FIVEWITHALONGNAME,\n}"),
		"multi-line enum must end with a trailing comma"
	);
};

@test fn fmt_short_struct_type_renders_single_line() void = {
	const src = "type point = struct { x: int, y: int };\n";
	const out = fmt_literals_roundtrip(src);
	defer free(out);
	assert(
		strings::contains(out, "struct { x: int, y: int }"),
		"short struct types must render as single-line"
	);
};

@test fn fmt_short_struct_literal_renders_single_line() void = {
	const src =
		"type point = struct { x: int, y: int };\n"
		"export fn f() void = {\n"
		"\tlet p = point { x = 1, y = 2 };\n"
		"\tlet _ = p;\n"
		"};\n";
	const out = fmt_literals_roundtrip(src);
	defer free(out);
	assert(
		strings::contains(out, "point { x = 1, y = 2 }"),
		"short struct literals must render as single-line"
	);
};

@test fn fmt_trailing_comment_in_match_case_stays_in_block() void = {
	// `case => abort(); // unreachable` is a common pattern; the
	// comment must NOT escape past the closing `}` of the match
	// (which produced the infamous `};// unreachable` corruption).
	const src =
		"export fn f() int = {\n"
		"\tmatch (g()) {\n"
		"\tcase int =>\n"
		"\t\treturn 1;\n"
		"\tcase => abort();\n"
		"\t};\n"
		"\t// after match\n"
		"\treturn 0;\n"
		"};\n"
		"fn g() (int | void) = void;\n";
	const out = fmt_literals_roundtrip(src);
	defer free(out);
	assert(
		strings::contains(out, "// after match"),
		"comment after match must survive (and stay outside match)"
	);
	assert(
		!strings::contains(out, "};//"),
		"comment must not fuse onto closing `}` (no `};//` substring)"
	);
};

@test fn fmt_struct_field_comments_stay_inside_struct() void = {
	// Doc-style line comments above struct fields must end up
	// inside the struct between the fields, not pushed past the
	// closing `}`.
	const src =
		"export type s = struct {\n"
		"\t// first field\n"
		"\ta: int,\n"
		"\t// second field\n"
		"\tb: int,\n"
		"};\n";
	const out = fmt_literals_roundtrip(src);
	defer free(out);
	const fc_idx = strings::index(out, "// first field");
	const a_idx = strings::index(out, "a: int");
	const close_idx = strings::index(out, "};");
	assert(fc_idx is size, "first-field comment must be present");
	assert(
		a_idx is size && a_idx as size > fc_idx as size,
		"first-field comment must precede `a: int`"
	);
	assert(
		close_idx is size && fc_idx as size < close_idx as size,
		"first-field comment must stay inside the struct's `}`"
	);
};

@test fn fmt_struct_literal_source_multiline_stays_multiline() void = {
	// Magic-newline heuristic (mirrors prettier's JS formatter): when
	// the source put a newline immediately after `{`, treat that as
	// an explicit "expand this" signal and keep the literal expanded
	// even when it would fit inline.
	const src =
		"type point = struct { x: int, y: int };\n"
		"export fn f() void = {\n"
		"\tlet p = point {\n"
		"\t\tx = 1,\n"
		"\t\ty = 2,\n"
		"\t};\n"
		"\tlet _ = p;\n"
		"};\n";
	const out = fmt_literals_roundtrip(src);
	defer free(out);
	assert(
		strings::contains(out, "point {\n\t\tx = 1,\n\t\ty = 2,\n\t};"),
		"source-multiline struct literal must stay multiline"
	);
};

@test fn fmt_array_literal_source_multiline_stays_multiline() void = {
	const src =
		"export fn f() void = {\n"
		"\tconst arr: []int = [\n"
		"\t\t1,\n"
		"\t\t2,\n"
		"\t\t3,\n"
		"\t];\n"
		"\tlet _ = arr;\n"
		"};\n";
	const out = fmt_literals_roundtrip(src);
	defer free(out);
	assert(
		strings::contains(out, "= [\n\t\t1,\n\t\t2,\n\t\t3,\n\t];"),
		"source-multiline array literal must stay multiline"
	);
};

@test fn fmt_call_fits_inline() void = {
	const src =
		"export fn f() void = { g(1, 2, 3); };\n"
		"fn g(a: int, b: int, c: int) void = void;\n";
	const out = fmt_literals_roundtrip(src);
	defer free(out);
	assert(
		strings::contains(out, "g(1, 2, 3);"),
		"short calls must stay on one line"
	);
};

@test fn fmt_call_wraps_with_fill_not_one_per_line() void = {
	// When a call doesn't fit on one line, args should pack greedily
	// onto continuation lines (indented once) rather than each going
	// onto its own line. The trailing `)` lands on its own line at
	// the call's outer indent, so the last arg gets a clean line and
	// `)?;` doesn't push past 80 cols.
	const src =
		"fn h_with_a_longish_name(aa: str, bb: str, cc: str, dd: str,"
		" ee: str, ff: str) void = void;\n"
		"export fn x() void = {\n"
		"\th_with_a_longish_name(\"alpha-one\", \"bravo-two\","
		" \"charlie-three\", \"delta-four\", \"echo-five\","
		" \"foxtrot-six\");\n"
		"};\n";
	const out = fmt_literals_roundtrip(src);
	defer free(out);
	// Must NOT produce one arg per line at the call site.
	assert(
		!strings::contains(
			out, "h_with_a_longish_name(\n\t\t\"alpha-one\",\n"
			"\t\t\"bravo-two\"",
		),
		"fill-mode call must not put every arg on its own line"
	);
	// Must contain at least two args glued together with a comma+
	// space on at least one of the wrapped lines.
	assert(
		strings::contains(out, "\", \""),
		"fill-mode call should pack multiple short args per line"
	);
};

@test fn fmt_struct_type_source_multiline_stays_multiline() void = {
	const src = "type point = struct {\n"
		"\tx: int,\n"
		"\ty: int,\n"
		"};\n";
	const out = fmt_literals_roundtrip(src);
	defer free(out);
	assert(
		strings::contains(out, "struct {\n\tx: int,\n\ty: int,\n};"),
		"source-multiline struct type must stay multiline"
	);
};

@test fn fmt_struct_literal_with_only_autofill_renders_single_line() void = {
	const src =
		"type p = struct { x: int };\n"
		"export fn f() void = {\n"
		"\tlet x: p = p { ... };\n"
		"\tlet _ = x;\n"
		"};\n";
	const out = fmt_literals_roundtrip(src);
	defer free(out);
	assert(
		strings::contains(out, "p { ... }"),
		"`Type { ... }` autofill literal must render single-line"
	);
};

@test fn fmt_const_eq_struct_literal_keeps_brace_on_eq_line() void = {
	const src =
		"type point = struct { x: int, y: int };\n"
		"export fn f() void = {\n"
		"\tconst p = point {\n"
		"\t\tx = 1,\n"
		"\t\ty = 2,\n"
		"\t};\n"
		"\tlet _ = p;\n"
		"};\n";
	const out = fmt_literals_roundtrip(src);
	defer free(out);
	assert(
		strings::contains(out, "const p = point {"),
		"`const p = point {` must stay on a single line"
	);
};

@test fn fmt_switch_case_single_space_before_arrow() void = {
	// Regression for a stray double-space in `case OPTION  =>` that
	// surfaced after Phase 2a removed the extra match-body nest -
	// the loc.end of switch case options is exclusive (one byte
	// past the literal), so verbatim_token_at would otherwise pull
	// the trailing space into the captured token text.
	const src =
		"export fn f() void = {\n"
		"\tswitch (1) {\n"
		"\tcase 1 =>\n"
		"\t\treturn;\n"
		"\tcase 2, 3 =>\n"
		"\t\treturn;\n"
		"\tcase =>\n"
		"\t\treturn;\n"
		"\t};\n"
		"};\n";
	const out = fmt_literals_roundtrip(src);
	defer free(out);
	assert(
		strings::contains(out, "case 1 =>"),
		"single-option case must have exactly one space before `=>`"
	);
	assert(
		!strings::contains(out, "case 1  =>"),
		"single-option case must NOT have a double space before `=>`"
	);
	assert(
		strings::contains(out, "case 2, 3 =>"),
		"multi-option case must have exactly one space before `=>`"
	);
};
