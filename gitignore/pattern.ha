// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// gitignore-style pattern parsing.
//
// This module is intentionally fs-free: it knows how to compile a
// .gitignore (or any gitignore-syntax) line into a `pattern` value, and
// how to test such a value against a path. Callers do their own file
// I/O and walking. Anyone who wants the same matching semantics in
// another Hare project can vendor this module unchanged.
//
// Pattern semantics follow the gitignore(5) manual:
// https://git-scm.com/docs/gitignore
//
//   - A blank or whitespace-only line matches nothing.
//   - A line whose first character is `#` is a comment. `\#foo` escapes
//     the comment so the line is a literal pattern starting with `#`.
//   - A leading `!` negates the pattern. `\!foo` is literal `!foo`.
//   - Trailing whitespace is trimmed unless the final space is escaped
//     with a backslash (`foo\ `).
//   - A leading `/` anchors the pattern to the ignore file's directory.
//     A `/` anywhere except as the trailing character also anchors.
//   - A trailing `/` makes the pattern directory-only.
//   - `*` matches any number of non-`/` characters; `?` matches one
//     non-`/` character; `[abc]` matches a character class. Backslash
//     escapes the next character.
//   - `**` as a whole path component matches zero or more components.
//     `**foo` is not treated as `**`; it collapses to `*foo`.

use bytes;
use strings;

// A single segment of a compiled pattern. When `double_star` is true,
// `text` is empty and the segment matches zero-or-more path components.
// Otherwise `text` is fnmatch'd against exactly one path component.
export type pattern_segment = struct {
	// @owned
	text: str,
	double_star: bool,
};

// A compiled gitignore-style pattern.
export type pattern = struct {
	// Leading `!`: a successful match flips a path from ignored to
	// included rather than ignored.
	negated: bool,
	// Anchored: the pattern is matched against the path starting at
	// component 0. Set when the pattern has a leading `/` or when it
	// contains any internal `/`.
	anchored: bool,
	// Directory-only: pattern was followed by a `/`; matches only when
	// the candidate path refers to a directory.
	dir_only: bool,
	// Compiled segments (split on `/`). For an unanchored pattern with
	// no internal `/` this is a single segment.
	//
	// @owned
	segments: []pattern_segment,
};

// Parse one gitignore-syntax line. Returns void when the line is blank,
// whitespace-only, a comment, or has no usable pattern after escape
// handling. The returned pattern owns its segment strings; free via
// [[pattern_finish]].
//
// @param line: borrowed
export fn parse_pattern(line: str) (pattern | void) = {
	const body = match (preprocess_line(line)) {
	case let s: str =>
		yield s;
	case void =>
		return;
	};
	defer free(body);

	const raw = strings::toutf8(body);

	// Negation marker.
	let negated = false;
	let i = 0z;
	if (len(raw) > 0 && raw[0] == '!': u8) {
		negated = true;
		i = 1;
	};

	// Escape: at the start of the pattern body (after the optional `!`)
	// a backslash before `#` or `!` is a literal-marker only; drop it.
	if (i + 1 < len(raw) && raw[i] == '\\': u8 &&
			(raw[i + 1] == '#': u8 ||
			raw[i + 1] == '!': u8)) {
		i += 1;
	};

	if (i >= len(raw)) return;

	// Anchoring and dir-only.
	let anchored = false;
	let dir_only = false;
	if (raw[i] == '/': u8) {
		anchored = true;
		i += 1;
	};
	let end = len(raw);
	if (end > i && raw[end - 1] == '/': u8) {
		dir_only = true;
		end -= 1;
	};

	if (i >= end) return;

	let core = raw[i..end];
	// Any remaining `/` inside the body is also an anchor signal.
	if (!anchored && bytes::contains(core, '/': u8)) {
		anchored = true;
	};

	let segs: []pattern_segment = [];
	const core_str = strings::fromutf8(core)!;
	let it = strings::tokenize(core_str, "/");
	for (let part => strings::next_token(&it)) {
		if (len(part) == 0) continue;
		const is_dstar = part == "**";
		append(segs, pattern_segment {
			text = if (is_dstar) "" else strings::dup(part)!,
			double_star = is_dstar,
		})!;
	};

	if (len(segs) == 0) {
		free(segs);
		return;
	};

	return pattern {
		negated = negated,
		anchored = anchored,
		dir_only = dir_only,
		segments = segs,
	};
};

// Parse a whole ignore-file contents. Lines are split on `\n`; CRLF is
// tolerated. Caller frees via [[finish_patterns]].
//
// @returns: owned
// @param text: borrowed
export fn parse_patterns(text: []u8) []pattern = {
	let out: []pattern = [];
	const s = strings::fromutf8(text)!;
	let it = strings::tokenize(s, "\n");
	for (let line => strings::next_token(&it)) {
		match (parse_pattern(line)) {
		case let p: pattern =>
			append(out, p)!;
		case void => void;
		};
	};
	return out;
};

// Free a pattern's owned data.
//
// @param p: borrowed
export fn pattern_finish(p: *pattern) void = {
	for (let i = 0z; i < len(p.segments); i += 1) {
		if (!p.segments[i].double_star) {
			free(p.segments[i].text);
		};
	};
	free(p.segments);
};

// Free a slice of patterns produced by [[parse_patterns]].
//
// @param ps: owned
export fn finish_patterns(ps: []pattern) void = {
	for (let i = 0z; i < len(ps); i += 1) {
		pattern_finish(&ps[i]);
	};
	free(ps);
};

// Returns the line body after stripping CR / trailing whitespace and
// rejecting blanks and comments. The result is a freshly-allocated
// owned string (or void). Trailing whitespace is preserved when the
// previous character is an unescaped backslash (`foo\ ` -> `foo `).
//
// @param line: borrowed
fn preprocess_line(line: str) (str | void) = {
	const raw = strings::toutf8(line);
	let end = len(raw);
	// Drop CRs (anywhere; the only place they realistically appear is at
	// the end on CRLF input, but stripping all of them is harmless).
	let buf: []u8 = alloc([], end)!;
	for (let i = 0z; i < end; i += 1) {
		if (raw[i] == '\r': u8) continue;
		append(buf, raw[i])!;
	};
	end = len(buf);

	// Trim trailing whitespace, honouring backslash escapes. We need
	// to count contiguous backslashes before any trailing space: an
	// odd count means the final space is escaped.
	for (end > 0) {
		const b = buf[end - 1];
		if (b != ' ': u8 && b != '\t': u8) break;
		// Look backward for backslashes.
		let bs = 0z;
		let j = end - 1;
		for (j > 0 && buf[j - 1] == '\\': u8) {
			bs += 1;
			j -= 1;
		};
		if (bs % 2 == 1) {
			// Final space is escaped: drop the escaping backslash and
			// keep the space. We only do this for the LAST whitespace
			// run; any whitespace before that is structural and not
			// trimmable anyway.
			buf[end - 2] = buf[end - 1];
			end -= 1;
			break;
		};
		end -= 1;
	};

	if (end == 0) {
		free(buf);
		return;
	};

	// Comment: literal first character must be `#`.
	if (buf[0] == '#': u8) {
		free(buf);
		return;
	};

	const result = strings::dup(strings::fromutf8(buf[..end])!)!;
	free(buf);
	return result;
};
