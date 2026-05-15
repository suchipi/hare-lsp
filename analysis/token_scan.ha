// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Lightweight byte-scanner for Hare source that knows how to skip over
// regions where bytes are NOT real identifier content:
//
//   - line comments (// ... \n)
//   - block comments (/* ... */)
//   - double-quoted strings ("...", with \-escapes)
//   - single-quoted runes ('...', with \-escapes)
//   - backtick raw strings (`...`)
//
// Used by features that need to walk source for identifier matches but
// must not match inside text where an identifier-like word doesn't
// refer to a binding — references, rename, signature-help comma
// counting, and the formatter's brace-depth tracker.
//
// We deliberately avoid hare::lex here: the stdlib lexer can hit a
// double-unlex abort when fed a truncated mid-token buffer, which is
// exactly the situation features like signature-help (cursor between
// tokens) hand it.
// Reasons we might be at a byte that's NOT part of an identifier in
// the source. token_skip_noncode returns the byte index immediately
// after the skipped region, or `i` itself when nothing was skipped.
//
// Given `data` and a start index `i` pointing at a candidate byte:
//
//   - if data[i] starts `//` -> advance past the line break.
//   - if data[i] starts `/*` -> advance past `*/` (or to end).
//   - if data[i] is `"` -> advance past the closing `"`, honoring \-escapes.
//   - if data[i] is `'` -> advance past the closing `'`, honoring \-escapes.
//   - if data[i] is `` ` `` -> advance past the closing `` ` ``.
//   - otherwise -> return i unchanged.
//
// Bounded by `limit` (usually `len(data)`).
//
// @param data: borrowed
export fn token_skip_noncode(data: []u8, i: size, limit: size) size = {
	if (i >= limit) return i;
	const b = data[i];
	switch (b) {
	case '/': u8 =>
		if (i + 1 < limit && data[i + 1] == '/': u8) {
			let j = i + 2;
			for (j < limit && data[j] != '\n': u8; j += 1) void;
			return j;
		};
		if (i + 1 < limit && data[i + 1] == '*': u8) {
			let j = i + 2;
			for (j + 1 < limit; j += 1) {
				if (data[j] == '*': u8 && data[j + 1] == '/': u8) {
					return j + 2;
				};
			};
			return limit;
		};
		return i;
	case '"': u8 =>
		let j = i + 1;
		for (j < limit) {
			if (data[j] == '\\': u8 && j + 1 < limit) {
				j += 2;
				continue;
			};
			if (data[j] == '"': u8) return j + 1;
			j += 1;
		};
		return limit;
	case '\'': u8 =>
		let j = i + 1;
		for (j < limit) {
			if (data[j] == '\\': u8 && j + 1 < limit) {
				j += 2;
				continue;
			};
			if (data[j] == '\'': u8) return j + 1;
			j += 1;
		};
		return limit;
	case '`': u8 =>
		let j = i + 1;
		for (j < limit; j += 1) {
			if (data[j] == '`': u8) return j + 1;
		};
		return limit;
	case =>
		return i;
	};
};
