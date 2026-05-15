// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Matching and evaluation for compiled gitignore patterns. See
// pattern.ha for the parser and the syntax rules; this file is the
// pure-Hare matcher that callers reach for during a walk.
//
// The single-pattern matcher (`pattern_matches`) tests one compiled
// pattern against a path relative to the ignore file's directory.
//
// `evaluate` runs an ordered list of patterns against a single path
// with last-match-wins semantics: a non-negated match flips the result
// to "ignored", a negated match flips it back. Idle (non-matching)
// patterns leave the running state alone.
//
// `evaluate_layers` is the multi-file equivalent: it composes per-
// directory layers (outermost first) so a closer `.gitignore` can
// override a more distant one without having to merge the patterns
// into a single flat list.

use fnmatch;
use strings;

// True when the compiled pattern matches the given path. `rel_path` is
// the path relative to the directory containing the ignore file. Pass
// `is_dir = true` when the path refers to a directory; `dir_only`
// patterns will not match files.
//
// @param p: borrowed
// @param rel_path: borrowed
export fn pattern_matches(p: *pattern, rel_path: str, is_dir: bool) bool = {
	if (p.dir_only && !is_dir) return false;

	let comps = split_components(rel_path);
	defer free(comps);

	if (p.anchored) {
		return match_segs(p.segments, 0, comps, 0);
	};

	// Unanchored pattern is matched as if implicitly prefixed with `**/`:
	// try each starting component until one fits or we run out.
	for (let start = 0z; start <= len(comps); start += 1) {
		if (match_segs(p.segments, 0, comps, start)) return true;
	};
	return false;
};

// Apply a list of patterns in order to a single path. Returns true if
// the path is ignored after the full sweep. Last match wins: a non-
// negated match marks the path ignored, a negated match unmarks it,
// non-matching patterns leave the state alone.
//
// @param patterns: borrowed
// @param rel_path: borrowed
export fn evaluate(patterns: []pattern, rel_path: str, is_dir: bool) bool = {
	let ignored = false;
	for (let i = 0z; i < len(patterns); i += 1) {
		if (pattern_matches(&patterns[i], rel_path, is_dir)) {
			ignored = !patterns[i].negated;
		};
	};
	return ignored;
};

// A per-directory bundle: the absolute path of the directory containing
// the ignore file, plus the patterns parsed out of it. Both `dir` and
// `patterns` are owned by the layer and released by its destructor (see
// [[cmd/harefmt/walk::finish_layers]]); patterns are typically created
// with [[parse_patterns]] and freed with [[finish_patterns]].
export type layer = struct {
	// @owned
	dir: str,
	// @owned
	patterns: []pattern,
};

// Evaluate a stack of layers against an absolute path. Layers are
// ordered outermost first (root) and innermost last (leaf), so layers
// at the leaf naturally override outer ones via last-match-wins. A
// layer whose `dir` is not an ancestor of `abs_path` is silently
// skipped.
//
// @param stack: borrowed
// @param abs_path: borrowed
export fn evaluate_layers(stack: []layer, abs_path: str, is_dir: bool) bool = {
	let ignored = false;
	for (let i = 0z; i < len(stack); i += 1) {
		const rel = match (relativize(abs_path, stack[i].dir)) {
		case let s: str =>
			yield s;
		case void =>
			continue;
		};
		defer free(rel);
		for (let j = 0z; j < len(stack[i].patterns); j += 1) {
			if (pattern_matches(&stack[i].patterns[j], rel, is_dir)) {
				ignored = !stack[i].patterns[j].negated;
			};
		};
	};
	return ignored;
};

// Returns the components of `p` as a slice of borrowed substrings
// (slices into `p`). Empty components (from `//` or leading/trailing
// slashes) are dropped.
//
// @param p: borrowed
fn split_components(p: str) []str = {
	let out: []str = [];
	if (len(p) == 0) return out;
	let it = strings::tokenize(p, "/");
	for (let part => strings::next_token(&it)) {
		if (len(part) == 0) continue;
		append(out, part)!;
	};
	return out;
};

// @param pat: borrowed
// @param comps: borrowed
fn match_segs(pat: []pattern_segment, pi: size, comps: []str, ci: size) bool = {
	if (pi == len(pat)) return ci == len(comps);
	if (pat[pi].double_star) {
		// `**` matches zero or more components; try each split.
		for (let k = ci; k <= len(comps); k += 1) {
			if (match_segs(pat, pi + 1, comps, k)) return true;
		};
		return false;
	};
	if (ci == len(comps)) return false;
	if (fnmatch::fnmatch(pat[pi].text, comps[ci])) {
		return match_segs(pat, pi + 1, comps, ci + 1);
	};
	return false;
};

// Returns `abs_path` made relative to `dir`. Both must be absolute
// paths with `/` separators. Returns void when `abs_path` is not under
// `dir`. The result is freshly allocated and owned by the caller.
//
// @param abs_path: borrowed
// @param dir: borrowed
fn relativize(abs_path: str, dir: str) (str | void) = {
	if (dir == "/" || dir == "") {
		// Root: drop any leading `/`s from abs_path.
		const bs = strings::toutf8(abs_path);
		let i = 0z;
		for (i < len(bs) && bs[i] == '/': u8) i += 1;
		if (i == len(bs)) return strings::dup("")!;
		return strings::dup(strings::fromutf8(bs[i..])!)!;
	};
	const a = strings::toutf8(abs_path);
	const d = strings::toutf8(dir);
	if (len(a) < len(d)) return;
	for (let i = 0z; i < len(d); i += 1) {
		if (a[i] != d[i]) return;
	};
	if (len(a) == len(d)) return strings::dup("")!;
	if (a[len(d)] != '/': u8) return;
	return strings::dup(strings::fromutf8(a[len(d) + 1..])!)!;
};
