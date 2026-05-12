// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use strings;

@test fn parses_clean_program() void = {
	const src = `use io;

export fn main() void = void;
`;
	let r = parse_recover(strings::toutf8(src), "test.ha");
	defer finish_parse_result(&r);
	assert(len(r.errors) == 0);
	assert(len(r.subunit.imports) == 1);
	assert(len(r.subunit.decls) == 1);
};

@test fn empty_buffer_yields_empty_result() void = {
	let r = parse_recover(strings::toutf8(""), "test.ha");
	defer finish_parse_result(&r);
	assert(len(r.errors) == 0);
	assert(len(r.subunit.decls) == 0);
};

@test fn recovers_after_bad_decl_then_continues() void = {
	const src =
		`export fn good1() void = void;

export fn bad( = void;

export fn good2() void = void;
`;
	let r = parse_recover(strings::toutf8(src), "test.ha");
	defer finish_parse_result(&r);
	// At least one error.
	assert(len(r.errors) >= 1);
	// good1 and good2 should both be present.
	assert(len(r.subunit.decls) >= 2);
};

@test fn multiple_errors_reported() void = {
	const src =
		`export fn a( = void;
export fn b( = void;
export fn c() void = void;
`;
	let r = parse_recover(strings::toutf8(src), "test.ha");
	defer finish_parse_result(&r);
	assert(len(r.errors) >= 2);
	// "c" should still parse.
	assert(len(r.subunit.decls) >= 1);
};

@test fn import_error_doesnt_block_decls() void = {
	const src = `use ?bogus?;

export fn ok() void = void;
`;
	let r = parse_recover(strings::toutf8(src), "test.ha");
	defer finish_parse_result(&r);
	assert(len(r.errors) >= 1);
	// Decl after the bad import should be parsed.
	assert(len(r.subunit.decls) >= 1);
};

@test fn error_carries_location() void = {
	const src = `export fn bad( = void;
`;
	let r = parse_recover(strings::toutf8(src), "test.ha");
	defer finish_parse_result(&r);
	assert(len(r.errors) >= 1);
	assert(r.errors[0].location.line >= 1);
	assert(r.errors[0].location.col >= 1);
	assert(len(r.errors[0].message) > 0);
};

@test fn completely_invalid_file() void = {
	const src = `]]] }}}`;
	let r = parse_recover(strings::toutf8(src), "test.ha");
	defer finish_parse_result(&r);
	assert(len(r.errors) >= 1);
	assert(r.completely_failed);
};

// Regression for the stdlib `parse::want` double-unlex abort. Inputs like
// `export <name>` (where the attrs loop falls through and want is then
// called with multiple alternatives — CONST/LET/DEF/TYPE/FN — none of
// which match a NAME) used to crash the process via the stdlib assertion
// "attempted to unlex more than one token". With our vendored hare::parse
// overlay, want recovers cleanly and parse_recover reports an error.
@test fn want_with_alternatives_doesnt_abort() void = {
	const inputs = [
		"export bar;",
		"@test bar;",
		"export @test bar;",
	];
	for (let i = 0z; i < len(inputs); i += 1) {
		let r = parse_recover(strings::toutf8(inputs[i]), "test.ha");
		defer finish_parse_result(&r);
		assert(len(r.errors) >= 1);
	};
};

@test fn many_decls_with_one_error_in_middle() void = {
	const src =
		`export fn a() void = void;
export fn b() void = void;
export fn ?bad?() void = void;
export fn d() void = void;
export fn e() void = void;
`;
	let r = parse_recover(strings::toutf8(src), "test.ha");
	defer finish_parse_result(&r);
	assert(len(r.errors) >= 1);
	// At least 4 of the 5 should parse (a, b, d, e).
	assert(len(r.subunit.decls) >= 4);
};
