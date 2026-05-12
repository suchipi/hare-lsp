// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Position mapping between Hare's byte-oriented `lex::location` and LSP's
// (line, character) positions, where `character` is a code-unit offset whose
// encoding is negotiated at initialize (UTF-8, UTF-16, or UTF-32).
//
// We default to UTF-16 since that's the LSP default; the negotiated encoding
// is stored in the server config and threaded through.

use encoding::utf8;

// Position encoding negotiated with the client.
export type encoding = enum {
	UTF8,
	UTF16,
	UTF32,
};

// LSP Position. line/character are 0-based; character is in `encoding` units.
export type position = struct {
	line: u32,
	character: u32,
};

// Builds a line index: a slice where line_index[i] is the byte offset of the
// start of line i. The result has len(text)/avg_line_len + 1 entries; line 0
// always starts at offset 0.
export fn build_line_index(text: []u8) []size = {
	let idx: []size = [];
	append(idx, 0z)!;
	for (let i = 0z; i < len(text); i += 1) {
		if (text[i] == '\n') {
			append(idx, i + 1)!;
		};
	};
	return idx;
};

// Converts a byte offset into an LSP Position using the given encoding.
//
// The line index must be sorted ascending and start with 0. text must be the
// same buffer the line_index was computed against. CRLF line endings are
// handled: the `\r` immediately preceding a `\n` is excluded from the
// column count so positions on CRLF files match positions on LF files.
export fn byte_to_position(
	text: []u8,
	line_index: []size,
	enc: encoding,
	off: size,
) position = {
	const line = line_for_offset(line_index, off);
	const line_start = line_index[line];
	const line_end = line_content_end(text, line_index, line);
	const clamped = if (off > line_end) line_end else off;
	const char = column_units(text[line_start..clamped], enc);
	return position {
		line = line: u32,
		character = char: u32,
	};
};

// Converts an LSP Position to a byte offset within text. Out-of-range
// positions are clamped to the end of the line / end of file.
export fn position_to_byte(
	text: []u8,
	line_index: []size,
	enc: encoding,
	pos: position,
) size = {
	const line = pos.line: size;
	if (line >= len(line_index)) return len(text);
	const line_start = line_index[line];
	const line_end = line_content_end(text, line_index, line);
	return units_to_byte(text[line_start..line_end], enc,
		pos.character: size) + line_start;
};

// Returns the byte offset where the content of `line` ends, excluding
// any trailing `\r` and `\n`. For the final line in a CRLF buffer that
// doesn't end with a newline, returns len(text).
fn line_content_end(text: []u8, line_index: []size, line: size) size = {
	let end = if (line + 1 < len(line_index)) {
		yield line_index[line + 1] - 1; // exclude the '\n'
	} else {
		yield len(text);
	};
	if (end > 0 && end <= len(text) && end - 1 < len(text) &&
			text[end - 1] == '\r': u8) {
		end -= 1;
	};
	return end;
};

// Returns the line containing the given byte offset (0-based). Uses binary
// search on the line index.
fn line_for_offset(line_index: []size, off: size) size = {
	if (len(line_index) == 0) return 0;
	// Find largest i such that line_index[i] <= off.
	let lo = 0z;
	let hi = len(line_index);
	for (lo + 1 < hi) {
		const mid = (lo + hi) / 2;
		if (line_index[mid] <= off) {
			lo = mid;
		} else {
			hi = mid;
		};
	};
	return lo;
};

// Counts code units in `bytes` (a single line's content, no trailing newline)
// according to the given encoding.
fn column_units(bytes: []u8, enc: encoding) size = {
	switch (enc) {
	case encoding::UTF8 =>
		return len(bytes);
	case encoding::UTF32 =>
		return count_runes(bytes);
	case encoding::UTF16 =>
		return count_utf16_units(bytes);
	};
};

// Returns the byte offset within `bytes` at which `units` code units have
// been consumed (clamped to len(bytes)).
fn units_to_byte(bytes: []u8, enc: encoding, units: size) size = {
	switch (enc) {
	case encoding::UTF8 =>
		return if (units > len(bytes)) len(bytes) else units;
	case encoding::UTF32 =>
		return runes_to_byte(bytes, units);
	case encoding::UTF16 =>
		return utf16_units_to_byte(bytes, units);
	};
};

fn count_runes(bytes: []u8) size = {
	let n = 0z;
	let i = 0z;
	for (i < len(bytes)) {
		const sz = match (utf8::utf8sz(bytes[i])) {
		case let s: size =>
			yield s;
		case utf8::invalid =>
			i += 1;
			n += 1;
			continue;
		};
		i += sz;
		n += 1;
	};
	return n;
};

fn runes_to_byte(bytes: []u8, units: size) size = {
	let n = 0z;
	let i = 0z;
	for (i < len(bytes) && n < units) {
		const sz = match (utf8::utf8sz(bytes[i])) {
		case let s: size =>
			yield s;
		case utf8::invalid =>
			i += 1;
			n += 1;
			continue;
		};
		if (i + sz > len(bytes)) break;
		i += sz;
		n += 1;
	};
	return i;
};

// Counts UTF-16 code units corresponding to the UTF-8 byte slice. Code points
// above 0xFFFF require a surrogate pair (2 code units).
fn count_utf16_units(bytes: []u8) size = {
	let n = 0z;
	let dec = utf8::decode(bytes);
	for (true) {
		match (utf8::next(&dec)) {
		case let r: rune =>
			n += if (r: u32 > 0xFFFF) 2z else 1z;
		case done =>
			return n;
		case utf8::invalid =>
			// Skip one byte and count it as one unit so we make
			// forward progress on malformed input.
			n += 1;
			const pos = utf8::position(&dec);
			if (pos < len(bytes)) {
				dec = utf8::decode(bytes[pos + 1..]);
			} else {
				return n;
			};
		case utf8::more =>
			return n;
		};
	};
};

fn utf16_units_to_byte(bytes: []u8, units: size) size = {
	let n = 0z;
	let consumed = 0z;
	let dec = utf8::decode(bytes);
	for (n < units) {
		match (utf8::next(&dec)) {
		case let r: rune =>
			const ru = if (r: u32 > 0xFFFF) 2z else 1z;
			if (n + ru > units) {
				// Stopping mid-surrogate-pair: treat as before the
				// rune.
				return consumed;
			};
			n += ru;
			consumed = utf8::position(&dec);
		case done =>
			return consumed;
		case utf8::invalid =>
			n += 1;
			consumed += 1;
			const pos = utf8::position(&dec);
			if (pos < len(bytes)) {
				dec = utf8::decode(bytes[pos + 1..]);
			} else {
				return consumed;
			};
		case utf8::more =>
			return consumed;
		};
	};
	return consumed;
};
