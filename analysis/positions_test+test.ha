// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use strings;

@test fn build_line_index_basic() void = {
	const idx = build_line_index(strings::toutf8("hello\nworld\n!"));
	defer free(idx);
	assert(len(idx) == 3);
	assert(idx[0] == 0);
	assert(idx[1] == 6);
	assert(idx[2] == 12);
};

@test fn build_line_index_empty() void = {
	const idx = build_line_index(strings::toutf8(""));
	defer free(idx);
	assert(len(idx) == 1);
	assert(idx[0] == 0);
};

@test fn build_line_index_trailing_newline() void = {
	const idx = build_line_index(strings::toutf8("a\nb\n"));
	defer free(idx);
	// Lines: "a", "b", and an implicit empty line after the final \n.
	assert(len(idx) == 3);
	assert(idx[0] == 0);
	assert(idx[1] == 2);
	assert(idx[2] == 4);
};

@test fn byte_to_position_ascii_utf8() void = {
	const text = strings::toutf8("hello\nworld");
	const idx = build_line_index(text);
	defer free(idx);
	const p = byte_to_position(text, idx, encoding::UTF8, 7);
	assert(p.line == 1);
	assert(p.character == 1); // 'o' in "world"
};

@test fn byte_to_position_multibyte_utf8() void = {
	// "héllo" — é is 2 bytes (0xC3 0xA9). Total bytes: 6.
	const text = strings::toutf8("héllo");
	const idx = build_line_index(text);
	defer free(idx);
	// Byte offset 3 is right after é.
	const p_utf8 = byte_to_position(text, idx, encoding::UTF8, 3);
	assert(p_utf8.line == 0);
	assert(p_utf8.character == 3); // 3 utf-8 bytes
	const p_utf16 = byte_to_position(text, idx, encoding::UTF16, 3);
	assert(p_utf16.line == 0);
	assert(p_utf16.character == 2); // h + é = 2 utf-16 units
	const p_utf32 = byte_to_position(text, idx, encoding::UTF32, 3);
	assert(p_utf32.line == 0);
	assert(p_utf32.character == 2); // 2 runes
};

@test fn byte_to_position_astral_emoji() void = {
	// 😀 (U+1F600) is 4 bytes UTF-8, 2 UTF-16 units (surrogate pair),
	// 1 UTF-32 unit.
	const text = strings::toutf8("a😀b");
	const idx = build_line_index(text);
	defer free(idx);
	const p_utf8 = byte_to_position(text, idx, encoding::UTF8, 5);
	assert(p_utf8.character == 5); // a (1) + emoji (4) = 5
	const p_utf16 = byte_to_position(text, idx, encoding::UTF16, 5);
	assert(p_utf16.character == 3); // a (1) + emoji (2) = 3
	const p_utf32 = byte_to_position(text, idx, encoding::UTF32, 5);
	assert(p_utf32.character == 2); // a + emoji = 2 runes
};

@test fn position_to_byte_roundtrip_ascii() void = {
	const text = strings::toutf8("foo\nbar\nbaz");
	const idx = build_line_index(text);
	defer free(idx);
	for (let off = 0z; off <= len(text); off += 1) {
		const p = byte_to_position(text, idx, encoding::UTF8, off);
		const back = position_to_byte(text, idx, encoding::UTF8, p);
		assert(back == off);
	};
};

@test fn position_to_byte_roundtrip_utf16() void = {
	const text = strings::toutf8("héllo\nwörld\n😀!");
	const idx = build_line_index(text);
	defer free(idx);
	// Walk every byte that is at a rune boundary.
	for (let off = 0z; off <= len(text); off += 1) {
		// Skip continuation bytes by checking the high bits.
		if (off < len(text) && text[off] & 0xC0 == 0x80) continue;
		const p = byte_to_position(text, idx, encoding::UTF16, off);
		const back = position_to_byte(text, idx, encoding::UTF16, p);
		assert(back == off);
	};
};

@test fn position_to_byte_clamps_out_of_range() void = {
	const text = strings::toutf8("hello");
	const idx = build_line_index(text);
	defer free(idx);
	// Past end of file.
	const p = position { line = 99, character = 0 };
	const off = position_to_byte(text, idx, encoding::UTF8, p);
	assert(off == len(text));
	// Past end of line.
	const p2 = position { line = 0, character = 999 };
	const off2 = position_to_byte(text, idx, encoding::UTF8, p2);
	assert(off2 == 5);
};

@test fn byte_to_position_clamps() void = {
	const text = strings::toutf8("hi");
	const idx = build_line_index(text);
	defer free(idx);
	const p = byte_to_position(text, idx, encoding::UTF8, 999);
	assert(p.line == 0);
	assert(p.character == 2);
};

@test fn crlf_byte_to_position_does_not_count_carriage_return() void = {
	// "ab\r\ncd\r\nef" — three lines separated by CRLF. The '\r' must
	// not be counted as a column character on its own line.
	const text = strings::toutf8("ab\r\ncd\r\nef");
	const idx = build_line_index(text);
	defer free(idx);
	// Offset of 'c' (start of line 1).
	const off_c = strings::index("ab\r\ncd\r\nef", 'c') as size;
	const pc = byte_to_position(text, idx, encoding::UTF8, off_c);
	assert(pc.line == 1);
	assert(pc.character == 0);
	// Position right after "cd" — should be character 2, not 3 (the
	// broken implementation included the \r in the column count).
	const pe = byte_to_position(text, idx, encoding::UTF8, off_c + 2);
	assert(pe.line == 1);
	assert(pe.character == 2);
};

@test fn crlf_position_to_byte_lands_correctly() void = {
	const text = strings::toutf8("ab\r\ncd\r\nef");
	const idx = build_line_index(text);
	defer free(idx);
	// Line 1 starts at offset 4. character 2 → offset 6 (the '\r').
	const off =
		position_to_byte(
			text, idx, encoding::UTF8, position { line = 1, character = 2 },
		);
	assert(off == 6);
};
