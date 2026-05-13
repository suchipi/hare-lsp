// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use strings;

@test fn parse_blank_returns_void() void = {
	assert(parse_pattern("") is void);
	assert(parse_pattern("   ") is void);
	assert(parse_pattern("\t \t") is void);
};

@test fn parse_comment_returns_void() void = {
	assert(parse_pattern("# nothing here") is void);
	assert(parse_pattern("#foo") is void);
};

@test fn parse_escaped_hash_is_literal() void = {
	const p = parse_pattern("\\#config") as pattern;
	defer pattern_finish(&p);
	assert(!p.negated);
	assert(!p.anchored);
	assert(!p.dir_only);
	assert(len(p.segments) == 1);
	assert(p.segments[0].text == "#config");
};

@test fn parse_negated_pattern() void = {
	const p = parse_pattern("!foo") as pattern;
	defer pattern_finish(&p);
	assert(p.negated);
	assert(!p.anchored);
	assert(len(p.segments) == 1);
	assert(p.segments[0].text == "foo");
};

@test fn parse_escaped_bang_is_literal() void = {
	const p = parse_pattern("\\!important") as pattern;
	defer pattern_finish(&p);
	assert(!p.negated);
	assert(len(p.segments) == 1);
	assert(p.segments[0].text == "!important");
};

@test fn parse_negated_then_escaped_hash() void = {
	const p = parse_pattern("!\\#weird") as pattern;
	defer pattern_finish(&p);
	assert(p.negated);
	assert(len(p.segments) == 1);
	assert(p.segments[0].text == "#weird");
};

@test fn parse_trailing_whitespace_is_stripped() void = {
	const p = parse_pattern("foo   ") as pattern;
	defer pattern_finish(&p);
	assert(p.segments[0].text == "foo");
};

@test fn parse_escaped_trailing_space_is_kept() void = {
	const p = parse_pattern("foo\\ ") as pattern;
	defer pattern_finish(&p);
	assert(p.segments[0].text == "foo ");
};

@test fn parse_crlf_tolerated() void = {
	const p = parse_pattern("foo\r") as pattern;
	defer pattern_finish(&p);
	assert(p.segments[0].text == "foo");
};

@test fn parse_basename_pattern() void = {
	const p = parse_pattern("foo") as pattern;
	defer pattern_finish(&p);
	assert(!p.anchored);
	assert(!p.dir_only);
	assert(len(p.segments) == 1);
	assert(p.segments[0].text == "foo");
};

@test fn parse_leading_slash_anchors() void = {
	const p = parse_pattern("/foo") as pattern;
	defer pattern_finish(&p);
	assert(p.anchored);
	assert(!p.dir_only);
	assert(len(p.segments) == 1);
	assert(p.segments[0].text == "foo");
};

@test fn parse_internal_slash_anchors() void = {
	const p = parse_pattern("foo/bar") as pattern;
	defer pattern_finish(&p);
	assert(p.anchored);
	assert(!p.dir_only);
	assert(len(p.segments) == 2);
	assert(p.segments[0].text == "foo");
	assert(p.segments[1].text == "bar");
};

@test fn parse_trailing_slash_makes_dir_only() void = {
	const p = parse_pattern("foo/") as pattern;
	defer pattern_finish(&p);
	assert(p.dir_only);
	assert(!p.anchored);
	assert(len(p.segments) == 1);
	assert(p.segments[0].text == "foo");
};

@test fn parse_double_star_segment() void = {
	const p = parse_pattern("**/foo") as pattern;
	defer pattern_finish(&p);
	assert(p.anchored);
	assert(len(p.segments) == 2);
	assert(p.segments[0].double_star);
	assert(p.segments[1].text == "foo");
};

@test fn parse_trailing_double_star() void = {
	const p = parse_pattern("foo/**") as pattern;
	defer pattern_finish(&p);
	assert(p.anchored);
	assert(len(p.segments) == 2);
	assert(p.segments[0].text == "foo");
	assert(p.segments[1].double_star);
};

@test fn parse_middle_double_star() void = {
	const p = parse_pattern("a/**/b") as pattern;
	defer pattern_finish(&p);
	assert(p.anchored);
	assert(len(p.segments) == 3);
	assert(p.segments[0].text == "a");
	assert(p.segments[1].double_star);
	assert(p.segments[2].text == "b");
};

@test fn parse_patterns_skips_blanks_and_comments() void = {
	const text = strings::toutf8("# comment\n*.log\n\n  \n!keep.log\n");
	const ps = parse_patterns(text);
	defer finish_patterns(ps);
	assert(len(ps) == 2);
	assert(!ps[0].negated);
	assert(ps[0].segments[0].text == "*.log");
	assert(ps[1].negated);
	assert(ps[1].segments[0].text == "keep.log");
};

@test fn parse_patterns_handles_crlf() void = {
	const text = strings::toutf8("*.log\r\n!keep.log\r\n");
	const ps = parse_patterns(text);
	defer finish_patterns(ps);
	assert(len(ps) == 2);
	assert(ps[0].segments[0].text == "*.log");
	assert(ps[1].segments[0].text == "keep.log");
};
