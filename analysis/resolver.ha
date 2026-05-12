// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Identifier resolution: given a byte offset in a file, find the
// declaration that the identifier at that offset refers to. Used by
// hover, go-to-definition, references, etc.
//
// This is the per-file resolver. It answers:
//   * "What declaration covers this offset?"  symbol_at(idx, off)
//   * "What identifier text is at this offset?"  ident_at(text, off)
//   * "Does the file declare a symbol named X?"  find_by_short_name
//
// Cross-file resolution lives in server/navigation.ha (which falls back
// to analysis::workspace_index when this file's index has no match).

use ascii;
use strings;

// Returns the (start_byte, end_byte) of the identifier-like token at
// `off`, or void if `off` is not on an identifier character.
//
// Convention: an offset of len(text) is treated as "just past the end" and
// matches if the last byte was an ident byte (so a cursor sitting after
// the final character of a name still hovers over it). Otherwise the
// offset must point AT an ident byte; spaces, punctuation, etc. return
// void even if adjacent bytes are idents.
export fn ident_at(text: []u8, off: size) ((size, size) | void) = {
	if (off >= len(text)) {
		if (off != len(text)) return void;
		if (off == 0) return void;
		if (!is_ident_byte(text[off - 1])) return void;
		// Position is at end of a known ident; rewind by one so the
		// scan logic finds it.
		let s = off - 1;
		for (s > 0; s -= 1) {
			if (!is_ident_byte(text[s - 1])) break;
		};
		return (s, off);
	};
	if (!is_ident_byte(text[off])) return void;
	let s = off;
	for (s > 0; s -= 1) {
		if (!is_ident_byte(text[s - 1])) break;
	};
	let e = off;
	for (e < len(text); e += 1) {
		if (!is_ident_byte(text[e])) break;
	};
	if (s == e) return void;
	return (s, e);
};

export fn is_ident_byte(b: u8) bool = {
	if (ascii::isalnum(b: rune)) return true;
	return b == '_': u8;
};

// Returns the qualifier prefix immediately before the ident starting at
// `ident_start`, or an empty allocated string if the ident is bare. For
// `foo::bar` with the cursor on `bar` (ident_start pointing at the 'b'),
// returns "foo". The "::" must be directly adjacent to ident_start; any
// whitespace between qualifier and "::" yields no qualifier.
//
// The returned string is always freshly allocated; caller frees.
export fn qualifier_prefix_at(data: []u8, ident_start: size) str = {
	if (ident_start < 2) return strings::dup("")!;
	if (data[ident_start - 1] != ':': u8 || data[ident_start - 2] != ':': u8) {
		return strings::dup("")!;
	};
	let q_end = ident_start - 2;
	let q_start = q_end;
	for (q_start > 0; q_start -= 1) {
		if (!is_ident_byte(data[q_start - 1])) break;
	};
	if (q_start == q_end) return strings::dup("")!;
	return strings::dup(strings::fromutf8(data[q_start..q_end])!)!;
};
