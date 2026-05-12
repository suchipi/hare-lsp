// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use strings;

fn one_pattern(line: str) pattern = {
	return parse_pattern(line) as pattern;
};

@test fn basename_pattern_matches_any_depth() void = {
	const p = one_pattern("foo");
	defer pattern_finish(&p);
	assert(pattern_matches(&p, "foo", false));
	assert(pattern_matches(&p, "a/foo", false));
	assert(pattern_matches(&p, "a/b/foo", false));
	assert(!pattern_matches(&p, "bar", false));
	assert(!pattern_matches(&p, "foobar", false));
};

@test fn anchored_pattern_only_matches_root() void = {
	const p = one_pattern("/foo");
	defer pattern_finish(&p);
	assert(pattern_matches(&p, "foo", false));
	assert(!pattern_matches(&p, "a/foo", false));
};

@test fn internal_slash_anchors_implicitly() void = {
	const p = one_pattern("foo/bar");
	defer pattern_finish(&p);
	assert(pattern_matches(&p, "foo/bar", false));
	assert(!pattern_matches(&p, "x/foo/bar", false));
};

@test fn dir_only_pattern_rejects_files() void = {
	const p = one_pattern("foo/");
	defer pattern_finish(&p);
	assert(pattern_matches(&p, "foo", true));
	assert(pattern_matches(&p, "a/foo", true));
	assert(!pattern_matches(&p, "foo", false));
};

@test fn glob_star_matches_within_segment() void = {
	const p = one_pattern("*.ha");
	defer pattern_finish(&p);
	assert(pattern_matches(&p, "main.ha", false));
	assert(pattern_matches(&p, "sub/dir/main.ha", false));
	assert(!pattern_matches(&p, "main.txt", false));
};

@test fn double_star_prefix_matches_any_depth() void = {
	const p = one_pattern("**/foo");
	defer pattern_finish(&p);
	assert(pattern_matches(&p, "foo", false));
	assert(pattern_matches(&p, "a/foo", false));
	assert(pattern_matches(&p, "a/b/c/foo", false));
};

@test fn double_star_trailing_matches_inside() void = {
	const p = one_pattern("foo/**");
	defer pattern_finish(&p);
	assert(pattern_matches(&p, "foo/a", false));
	assert(pattern_matches(&p, "foo/a/b", false));
	// `foo/**` matches everything under foo; `foo` alone with zero
	// trailing components is allowed per gitignore semantics because
	// `**` matches zero or more segments.
	assert(pattern_matches(&p, "foo", true));
	assert(!pattern_matches(&p, "bar/a", false));
};

@test fn double_star_middle_matches_any_intermediate_depth() void = {
	const p = one_pattern("a/**/b");
	defer pattern_finish(&p);
	assert(pattern_matches(&p, "a/b", false));
	assert(pattern_matches(&p, "a/x/b", false));
	assert(pattern_matches(&p, "a/x/y/b", false));
	assert(!pattern_matches(&p, "b", false));
	assert(!pattern_matches(&p, "z/a/b", false));
};

@test fn evaluate_simple_ignore() void = {
	const ps = parse_patterns(strings::toutf8("*.log"));
	defer finish_patterns(ps);
	assert(evaluate(ps, "a.log", false));
	assert(!evaluate(ps, "a.ha", false));
};

@test fn evaluate_negation_unignores() void = {
	const ps = parse_patterns(strings::toutf8("*.log\n!keep.log"));
	defer finish_patterns(ps);
	assert(evaluate(ps, "noise.log", false));
	assert(!evaluate(ps, "keep.log", false));
};

@test fn evaluate_negation_is_no_op_when_not_yet_ignored() void = {
	const ps = parse_patterns(strings::toutf8("!only_a_negation"));
	defer finish_patterns(ps);
	// Negation without a prior ignore leaves the state at "not ignored".
	assert(!evaluate(ps, "only_a_negation", false));
	assert(!evaluate(ps, "anything", false));
};

@test fn evaluate_last_match_wins() void = {
	const ps = parse_patterns(strings::toutf8("foo\n!foo\nfoo"));
	defer finish_patterns(ps);
	assert(evaluate(ps, "foo", false));
};

@test fn evaluate_layers_basic() void = {
	const outer_ps = parse_patterns(strings::toutf8("*.tmp.ha"));
	defer finish_patterns(outer_ps);
	const inner_ps = parse_patterns(strings::toutf8("!keep.tmp.ha"));
	defer finish_patterns(inner_ps);
	let stack: []layer = [];
	defer free(stack);
	append(stack, layer { dir = "/root", patterns = outer_ps })!;
	append(stack, layer { dir = "/root/sub", patterns = inner_ps })!;
	assert(evaluate_layers(stack, "/root/sub/noise.tmp.ha", false));
	assert(!evaluate_layers(stack, "/root/sub/keep.tmp.ha", false));
};

@test fn evaluate_layers_inner_does_not_apply_above() void = {
	// An inner layer's patterns shouldn't affect paths that aren't
	// under that layer's directory.
	const outer_ps = parse_patterns(strings::toutf8("*.log"));
	defer finish_patterns(outer_ps);
	const inner_ps = parse_patterns(strings::toutf8("!keep.log"));
	defer finish_patterns(inner_ps);
	let stack: []layer = [];
	defer free(stack);
	append(stack, layer { dir = "/root", patterns = outer_ps })!;
	append(stack, layer { dir = "/root/sub", patterns = inner_ps })!;
	// A path under /root (not /root/sub) should NOT pick up the inner
	// "!keep.log" rule.
	assert(evaluate_layers(stack, "/root/keep.log", false));
};

@test fn evaluate_layers_skips_unrelated_dirs() void = {
	const ps = parse_patterns(strings::toutf8("*.log"));
	defer finish_patterns(ps);
	let stack: []layer = [];
	defer free(stack);
	append(stack, layer { dir = "/elsewhere", patterns = ps })!;
	// Path is not under /elsewhere; the layer contributes nothing.
	assert(!evaluate_layers(stack, "/root/a.log", false));
};
