// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use bytes;
use hare::ast;
use strings;

// All AST locations start out as RUNE indices (per `hare::lex`) and
// `parse_recover` runs `fixup_parse_result` to translate them to
// byte offsets. These tests pin down the post-fixup contract that
// downstream features (byte_to_position, source slicing, navigation
// handlers) rely on.
//
// Note: `strings::index` returns a RUNE index, not a byte index.
// We use `bytes::index(strings::toutf8(src), strings::toutf8(needle))`
// to get byte offsets, which is what AST locations should match.
fn byte_index(src: str, needle: str) size = {
	const src_bytes = strings::toutf8(src);
	const needle_bytes = strings::toutf8(needle);
	return bytes::index(src_bytes, needle_bytes) as size;
};

@test fn build_rune_to_byte_table_ascii() void = {
	const data = strings::toutf8("abcd");
	const tbl = build_rune_to_byte_table(data);
	defer free(tbl);
	// 4 runes + the past-the-end sentinel = 5 entries.
	assert(len(tbl) == 5);
	assert(tbl[0] == 0z);
	assert(tbl[1] == 1z);
	assert(tbl[2] == 2z);
	assert(tbl[3] == 3z);
	assert(tbl[4] == 4z);
};

@test fn build_rune_to_byte_table_multibyte() void = {
	// `é` is 2 bytes (U+00E9), `日` is 3 bytes (U+65E5).
	// Expected rune-index -> byte-offset mapping:
	//   rune 0 -> byte 0 (start of 'a')
	//   rune 1 -> byte 1 (start of 'é')
	//   rune 2 -> byte 3 (start of '日')
	//   rune 3 -> byte 6 (start of 'c')
	//   rune 4 -> byte 7 (past-the-end sentinel)
	const data = strings::toutf8("aé日c");
	const tbl = build_rune_to_byte_table(data);
	defer free(tbl);
	assert(len(tbl) == 5);
	assert(tbl[0] == 0z);
	assert(tbl[1] == 1z);
	assert(tbl[2] == 3z);
	assert(tbl[3] == 6z);
	assert(tbl[4] == 7z);
};

@test fn build_rune_to_byte_table_four_byte_rune() void = {
	// `🦀` (U+1F980) is a 4-byte UTF-8 sequence.
	const data = strings::toutf8("a🦀b");
	const tbl = build_rune_to_byte_table(data);
	defer free(tbl);
	assert(len(tbl) == 4);
	assert(tbl[0] == 0z); // 'a'
	assert(tbl[1] == 1z); // '🦀'
	assert(tbl[2] == 5z); // 'b'
	assert(tbl[3] == 6z); // past-the-end
};

@test fn fixup_ascii_decl_start_is_byte_offset() void = {
	// With no multi-byte runes, rune offsets == byte offsets so
	// fixup is an identity. Verify the decl's reported start byte
	// matches the literal byte position of `fn` in the source.
	const src_str = "fn alpha() void = void;\n";
	const src = strings::toutf8(src_str);
	let r = parse_recover(src, "test.ha");
	defer finish_parse_result(&r);
	assert(len(r.subunit.decls) == 1);
	const d = &r.subunit.decls[0];
	assert(d.loc.start.off == 0);
	assert(src[d.loc.start.off: size] == 'f': u8);
	// loc.end.off must be inside the source bounds.
	assert(d.loc.end.off: size <= len(src));
};

@test fn fixup_translates_decl_start_past_multibyte_comment() void = {
	// A comment with multi-byte UTF-8 runes ABOVE a decl. Without
	// fixup, the decl's `loc.start.off` would be the rune count
	// (smaller than the byte count) so source slicing using that
	// offset would point at the wrong byte. With fixup, the offset
	// is a byte offset and bytes[off] is the first byte of `fn`.
	const src_str = "// 横座標 helper\nfn helper() void = void;\n";
	const src = strings::toutf8(src_str);
	let r = parse_recover(src, "test.ha");
	defer finish_parse_result(&r);
	assert(len(r.subunit.decls) == 1);
	const d = &r.subunit.decls[0];
	const expected_start = byte_index(src_str, "fn helper");
	assert(
		d.loc.start.off: size == expected_start,
		"decl start must be a BYTE offset, not a rune count"
	);
	assert(src[d.loc.start.off: size] == 'f': u8);
	assert(src[d.loc.start.off: size + 1] == 'n': u8);
};

@test fn fixup_translates_decl_start_past_multibyte_string_literal() void = {
	// A string literal with multi-byte runes inside a previous
	// decl's body. The literal advances the lexer's rune counter
	// but isn't a top-level node, so without fixup the drift
	// accumulates and `beta`'s reported start drifts left.
	const src_str = "fn alpha() str = \"日本語\";\nfn beta() void = void;\n";
	const src = strings::toutf8(src_str);
	let r = parse_recover(src, "test.ha");
	defer finish_parse_result(&r);
	assert(len(r.subunit.decls) == 2);
	const beta = &r.subunit.decls[1];
	const expected_start = byte_index(src_str, "fn beta");
	assert(beta.loc.start.off: size == expected_start);
	assert(src[expected_start] == 'f': u8);
	assert(src[expected_start + 1] == 'n': u8);
};

@test fn fixup_loc_end_points_at_start_of_last_rune() void = {
	// Per CLAUDE.md and hare::lex::prevloc, `loc.end.off` for an
	// expression points at the START of the LAST RUNE of the last
	// consumed token. Walk into a function body's `b.data` access
	// expression to verify: for `data` (4 ASCII runes), loc.end.off
	// should be at byte (start_of_data + 3) — the byte of the
	// trailing 'a', not the start of "data" and not the byte past
	// the end. Single-char field names like `x` mask the bug
	// because start-of-last-rune == start-of-name.
	const src_str = "fn f(b: struct { data: int }) int = b.data;\n";
	const src = strings::toutf8(src_str);
	let r = parse_recover(src, "test.ha");
	defer finish_parse_result(&r);
	assert(len(r.subunit.decls) == 1);
	const d = &r.subunit.decls[0];
	match (d.decl) {
	case let f: ast::decl_func =>
		match (f.body) {
		case let e: *ast::expr =>
			const b_data_start = byte_index(src_str, "b.data");
			const expected_end = b_data_start + 5; // start of last rune ('a') of `data`
			assert(
				e.loc.end.off: size == expected_end,
				"loc.end.off must point at the START of the LAST rune of `data`"
			);
			assert(src[e.loc.end.off: size] == 'a': u8);
		case null => abort("body missing");
		};
	case => abort("not a function decl");
	};
};

@test fn fixup_walks_function_decl() void = {
	// Exercise fixup_decl -> decl_func path with a multi-byte rune
	// in the doc comment. Verifies the function's loc.start.off is
	// a byte offset.
	const src_str = "// é fn\nfn helper() void = void;\n";
	const src = strings::toutf8(src_str);
	let r = parse_recover(src, "test.ha");
	defer finish_parse_result(&r);
	assert(len(r.errors) == 0);
	assert(len(r.subunit.decls) == 1);
	const d = &r.subunit.decls[0];
	const expected = byte_index(src_str, "fn helper");
	assert(d.loc.start.off: size == expected);
	assert(src[d.loc.start.off: size] == 'f': u8);
};

@test fn fixup_walks_type_decl() void = {
	const src_str = "// 日 alias\ntype alpha = int;\n";
	const src = strings::toutf8(src_str);
	let r = parse_recover(src, "test.ha");
	defer finish_parse_result(&r);
	assert(len(r.errors) == 0);
	assert(len(r.subunit.decls) == 1);
	const d = &r.subunit.decls[0];
	const expected = byte_index(src_str, "type alpha");
	assert(d.loc.start.off: size == expected);
	assert(src[d.loc.start.off: size] == 't': u8);
};

@test fn fixup_walks_global_decl() void = {
	const src_str = "// 本 global\nlet g: int = 1;\n";
	const src = strings::toutf8(src_str);
	let r = parse_recover(src, "test.ha");
	defer finish_parse_result(&r);
	assert(len(r.errors) == 0);
	assert(len(r.subunit.decls) == 1);
	const d = &r.subunit.decls[0];
	const expected = byte_index(src_str, "let g");
	assert(d.loc.start.off: size == expected);
	assert(src[d.loc.start.off: size] == 'l': u8);
};

@test fn fixup_walks_const_decl() void = {
	const src_str = "// 語 c\ndef c: int = 2;\n";
	const src = strings::toutf8(src_str);
	let r = parse_recover(src, "test.ha");
	defer finish_parse_result(&r);
	assert(len(r.errors) == 0);
	assert(len(r.subunit.decls) == 1);
	const d = &r.subunit.decls[0];
	const expected = byte_index(src_str, "def c");
	assert(d.loc.start.off: size == expected);
	assert(src[d.loc.start.off: size] == 'd': u8);
};

@test fn fixup_walks_imports() void = {
	// Imports are walked separately from decls in fixup_parse_result.
	// In hare::ast the import's loc.start.off points at the start
	// of the IDENTIFIER (not the `use` keyword), so we look up the
	// identifier directly. The multi-byte comment exercises the
	// rune→byte translation path.
	const src_str = "// 日本語\nuse io;\nuse strings;\n";
	const src = strings::toutf8(src_str);
	let r = parse_recover(src, "test.ha");
	defer finish_parse_result(&r);
	assert(len(r.subunit.imports) == 2);
	const first = &r.subunit.imports[0];
	const expected_start = byte_index(src_str, "io;");
	assert(
		first.loc.start.off: size == expected_start,
		"import loc.start.off must be the BYTE offset of the identifier"
	);
	assert(src[expected_start] == 'i': u8);
};

@test fn fixup_mixed_decls_all_get_byte_offsets() void = {
	// One import + four decl kinds in one file, with multi-byte
	// runes scattered between them so any unfixed offset drifts
	// across at least one node and lands on the wrong byte.
	const src_str =
		"use io;\n// 日 t\ntype alpha = int;\n// 本 g\nlet g: int = 1;\n// 語 c\ndef c: int = 2;\n// é fn\nfn helper() void = void;\n";
	const src = strings::toutf8(src_str);
	let r = parse_recover(src, "test.ha");
	defer finish_parse_result(&r);
	assert(len(r.errors) == 0);
	assert(len(r.subunit.imports) == 1);
	assert(len(r.subunit.decls) == 4);
	// For each decl, loc.start.off must be the BYTE offset where
	// the decl's leading keyword lives.
	const expected = [
		byte_index(src_str, "type alpha"),
		byte_index(src_str, "let g"),
		byte_index(src_str, "def c"),
		byte_index(src_str, "fn helper"),
	];
	for (let i = 0z; i < len(r.subunit.decls); i += 1) {
		const d = &r.subunit.decls[i];
		assert(
			d.loc.start.off: size == expected[i],
			"every decl's loc.start.off must be a byte offset post-fixup"
		);
	};
};
