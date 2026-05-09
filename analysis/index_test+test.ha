// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use strings;

@test fn index_collects_function_decls() void = {
	const src = `export fn alpha() void = void;

fn beta() void = void;

@test fn gamma() void = void;
`;
	let r = parse_recover(strings::toutf8(src), "test.ha");
	defer finish_parse_result(&r);

	let idx = build_index(&r.subunit);
	defer finish_index(&idx);
	assert(len(idx.symbols) == 3);
	// First decl is `alpha`, exported.
	assert(idx.symbols[0].kind == symbol_kind::FUNCTION);
	assert(idx.symbols[0].short_name == "alpha");
	assert(idx.symbols[0].exported);
	assert(!idx.symbols[1].exported);
	assert(idx.symbols[2].short_name == "gamma");
};

@test fn index_collects_type_decls() void = {
	const src = `type point = struct { x: int, y: int };
type alias = int;
`;
	let r = parse_recover(strings::toutf8(src), "test.ha");
	defer finish_parse_result(&r);
	let idx = build_index(&r.subunit);
	defer finish_index(&idx);
	assert(len(idx.symbols) == 2);
	assert(idx.symbols[0].kind == symbol_kind::TYPE);
	assert(idx.symbols[0].short_name == "point");
	assert(idx.symbols[1].short_name == "alias");
};

@test fn index_distinguishes_const_vs_global() void = {
	const src = `let counter: int = 0;
const greeting: str = "hi";
def MAX: int = 100;
`;
	let r = parse_recover(strings::toutf8(src), "test.ha");
	defer finish_parse_result(&r);
	let idx = build_index(&r.subunit);
	defer finish_index(&idx);
	assert(len(idx.symbols) == 3);
	assert(idx.symbols[0].kind == symbol_kind::GLOBAL);
	assert(idx.symbols[1].kind == symbol_kind::CONST);
	assert(idx.symbols[2].kind == symbol_kind::DEF);
};

@test fn symbol_at_offset_returns_containing_decl() void = {
	const src = `export fn first() void = void;

export fn second() void = void;
`;
	let r = parse_recover(strings::toutf8(src), "test.ha");
	defer finish_parse_result(&r);
	let idx = build_index(&r.subunit);
	defer finish_index(&idx);
	// Offset 5 (inside "export fn first…") should match `first`.
	const sym = symbol_at(&idx, 5z);
	const s = sym as *symbol;
	assert(s.short_name == "first");
};

@test fn symbol_at_offset_returns_void_for_whitespace() void = {
	const src = `

export fn x() void = void;
`;
	let r = parse_recover(strings::toutf8(src), "test.ha");
	defer finish_parse_result(&r);
	let idx = build_index(&r.subunit);
	defer finish_index(&idx);
	// Offset 0 is on a blank line.
	assert(symbol_at(&idx, 0z) is void);
};

@test fn find_by_short_name_works() void = {
	const src = `fn foo() void = void;
fn bar() void = void;
`;
	let r = parse_recover(strings::toutf8(src), "test.ha");
	defer finish_parse_result(&r);
	let idx = build_index(&r.subunit);
	defer finish_index(&idx);
	assert((find_by_short_name(&idx, "foo") as *symbol).short_name == "foo");
	assert((find_by_short_name(&idx, "bar") as *symbol).short_name == "bar");
	assert(find_by_short_name(&idx, "baz") is void);
};

@test fn ident_at_finds_identifier() void = {
	const text = strings::toutf8("let foo = bar(123);");
	const r1 = ident_at(text, 5z) as (size, size);
	assert(r1.0 == 4 && r1.1 == 7); // "foo"
	const r2 = ident_at(text, 11z) as (size, size);
	assert(r2.0 == 10 && r2.1 == 13); // "bar"
};

@test fn ident_at_skips_punctuation() void = {
	const text = strings::toutf8("a + b");
	assert(ident_at(text, 1z) is void); // space
	assert(ident_at(text, 2z) is void); // +
	const r = ident_at(text, 0z) as (size, size);
	assert(r.0 == 0 && r.1 == 1); // "a"
};

@test fn ident_at_at_end_of_ident() void = {
	const text = strings::toutf8("hello");
	const r = ident_at(text, 5z) as (size, size);
	assert(r.0 == 0 && r.1 == 5);
};

@test fn ident_at_with_underscore_and_digits() void = {
	const text = strings::toutf8("foo_123 bar");
	const r = ident_at(text, 4z) as (size, size);
	assert(r.0 == 0 && r.1 == 7);
};
