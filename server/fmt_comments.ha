// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Comment collection for the formatter. Hare's AST drops inline `//`
// comments, so we scan the source bytes directly with awareness of
// string / rune / raw-string delimiters to find every `//` line and
// record its byte range. The fmt_build walker consumes this list via
// a `comment_cursor` that advances as nodes are emitted.

use strings;

// A single line comment found in the source.
export type comment_info = struct {
	// Byte offset of the `/` that begins `//`.
	start_off: size,
	// Byte offset of the `\n` ending the line (or len(data) if EOF).
	end_off: size,
	// The 0-based line number containing the comment (counted from
	// `\n`s before start_off).
	line: size,
	// Text AFTER the `//`, with no leading space stripped and no
	// trailing newline. Allocated string; freed by `finish_comments`.
	text: str,
};

// Cursor into a sorted comment list. Builders advance it past byte
// offsets and pop the comments that fall before each position.
export type comment_cursor = struct {
	comments: []comment_info,
	pos: size,
};

// Scans `data` for `//` line comments. The scanner skips string /
// rune literals (including escapes) and raw strings (backticks) so a
// stray `//` inside a string isn't mistaken for a comment.
//
// Returned slice is sorted by start_off. Caller frees via
// finish_comments.
export fn collect_comments(data: []u8) []comment_info = {
	let out: []comment_info = [];
	let line: size = 0;
	let i = 0z;
	for (i < len(data); i += 1) {
		const b = data[i];
		switch (b) {
		case '\n': u8 =>
			line += 1;
		case '"': u8 =>
			i += 1;
			for (i < len(data) && data[i] != '"': u8; i += 1) {
				if (data[i] == '\\': u8 && i + 1 < len(data)) {
					i += 1;
				};
				if (i < len(data) && data[i] == '\n': u8) {
					line += 1;
				};
			};
		case '\'': u8 =>
			i += 1;
			for (i < len(data) && data[i] != '\'': u8; i += 1) {
				if (data[i] == '\\': u8 && i + 1 < len(data)) {
					i += 1;
				};
				if (i < len(data) && data[i] == '\n': u8) {
					line += 1;
				};
			};
		case '`': u8 =>
			i += 1;
			for (i < len(data) && data[i] != '`': u8; i += 1) {
				if (data[i] == '\n': u8) line += 1;
			};
		case '/': u8 =>
			if (i + 1 >= len(data) || data[i + 1] != '/': u8) {
				continue;
			};
			const start = i;
			let end = i + 2;
			for (end < len(data) && data[end] != '\n': u8; end += 1) void;
			const text = strings::dup(
				strings::fromutf8(data[start + 2..end])!)!;
			append(out, comment_info {
				start_off = start,
				end_off = end,
				line = line,
				text = text,
			})!;
			i = end - 1;
		case => void;
		};
	};
	return out;
};

// Frees all memory owned by a comment list.
export fn finish_comments(cs: []comment_info) void = {
	for (let i = 0z; i < len(cs); i += 1) {
		free(cs[i].text);
	};
	free(cs);
};

// Returns a slice (borrowed from the cursor's comment list) of all
// comments whose `start_off < boundary`, and advances the cursor past
// them. Returns an empty slice if none.
export fn pop_before(c: *comment_cursor, boundary: size) []comment_info = {
	const start = c.pos;
	for (c.pos < len(c.comments) &&
			c.comments[c.pos].start_off < boundary; c.pos += 1) void;
	return c.comments[start..c.pos];
};

// Returns (without consuming) the next pending comment, or void.
export fn peek(c: *comment_cursor) (*comment_info | void) = {
	if (c.pos >= len(c.comments)) return;
	return &c.comments[c.pos];
};

// True iff there's a pending comment whose start_off lies in
// [low, high).
export fn has_in_range(c: *comment_cursor, low: size, high: size) bool = {
	for (let i = c.pos; i < len(c.comments); i += 1) {
		const off = c.comments[i].start_off;
		if (off >= high) return false;
		if (off >= low) return true;
	};
	return false;
};
