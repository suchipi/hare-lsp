// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use hare::ast;
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

// An incomplete member access (`obj.` with no field name yet) is the most
// common transient edit state - it is exactly what exists the instant
// before requesting completion. The stdlib parser rejects the whole
// function on it, discarding every binding inside; the recovery retry
// blanks the dangling dot so the function (and its bindings) survives,
// while still reporting the access as an error for diagnostics.
@test fn recovers_function_body_with_dangling_dot() void = {
	const src =
		`export fn f(obj: int) void = {
	const keep = 42;
	g(obj.);
};
`;
	let r = parse_recover(strings::toutf8(src), "test.ha");
	defer finish_parse_result(&r);
	// The dangling dot is still surfaced as a diagnostic.
	assert(len(r.errors) >= 1, "incomplete member access must still be reported");
	// ...but the function is recovered rather than discarded.
	assert(
		len(r.subunit.decls) == 1,
		"function should be recovered, not dropped"
	);
};

// The repair must blank ONLY real member-access dots, never dots inside
// string literals (the try-hare file that surfaced this bug has `'.d.ts'`
// help text). token_skip_noncode keeps the repair out of strings; verify
// a string's dots survive intact even when a sibling statement triggers
// the dangling-dot recovery.
@test fn dangling_dot_repair_preserves_string_literals() void = {
	const src =
		`export fn f(obj: int) void = {
	const dotted = "a.b.";
	g(obj.);
};
`;
	let r = parse_recover(strings::toutf8(src), "test.ha");
	defer finish_parse_result(&r);
	assert(len(r.subunit.decls) == 1, "function should be recovered");
	const val = first_string_literal_value(&r.subunit);
	assert(
		val == "a.b.",
		"string literal content must be preserved (dots inside strings are not member accesses)"
	);
};

// Returns the value of the first plain string literal bound by a `let`/
// `const` inside the first function declaration, or "" if none.
//
// @param su: borrowed
fn first_string_literal_value(su: *ast::subunit) str = {
	for (let i = 0z; i < len(su.decls); i += 1) {
		const f = match (su.decls[i].decl) {
		case let f: ast::decl_func =>
			yield f;
		case =>
			continue;
		};
		const body = match (f.body) {
		case let e: *ast::expr =>
			yield e;
		case null =>
			continue;
		};
		const c = match (body.expr) {
		case let c: ast::compound_expr =>
			yield c;
		case =>
			continue;
		};
		for (let j = 0z; j < len(c.exprs); j += 1) {
			const b = match (c.exprs[j].expr) {
			case let b: ast::binding_expr =>
				yield b;
			case =>
				continue;
			};
			if (len(b.bindings) == 0) continue;
			const lit = match (b.bindings[0].init.expr) {
			case let l: ast::literal_expr =>
				yield l;
			case =>
				continue;
			};
			match (lit) {
			case let pl: ast::plain_literal =>
				match (pl.value) {
				case let s: str =>
					return s;
				case => void;
				};
			case => void;
			};
		};
	};
	return "";
};

// Direct coverage for the shared receiver classifier. A single-byte test
// before the dot would wrongly reject identifiers ending in a digit and
// postfix `!`/`?` receivers; the word-walk accepts them while still
// rejecting bare numeric literals. dot_off is the index of the `.`.
@test fn receiver_ends_before_dot_recognizes_digit_idents_and_postfix() void = {
	assert(receiver_ends_before_dot(strings::toutf8("buf."), 3));
	assert(
		receiver_ends_before_dot(strings::toutf8("buf1."), 4),
		"identifier ending in a digit is a receiver"
	);
	assert(receiver_ends_before_dot(strings::toutf8("sha256."), 6));
	assert(
		receiver_ends_before_dot(strings::toutf8("foo()!."), 6),
		"postfix propagate is a receiver"
	);
	assert(
		receiver_ends_before_dot(strings::toutf8("foo()?."), 6),
		"postfix error-assert is a receiver"
	);
	assert(
		receiver_ends_before_dot(strings::toutf8("xs[0]."), 5),
		"index expression is a receiver"
	);
	assert(
		!receiver_ends_before_dot(strings::toutf8("1."), 1),
		"a bare integer is a float literal, not a receiver"
	);
	assert(
		!receiver_ends_before_dot(strings::toutf8("123."), 3),
		"a multi-digit integer is a float literal"
	);
};

// Regression: the dangling-dot repair must recover the function for a
// receiver ending in a digit (`buf1.`). A single-byte digit check used to
// mistake it for a float literal and skip recovery, so hover/go-to-def on
// the function's other bindings broke while the dot was present.
@test fn recovers_dangling_dot_on_digit_ending_receiver() void = {
	const src =
		`export fn f(buf1: int) void = {
	const keep = 42;
	g(buf1.);
};
`;
	let r = parse_recover(strings::toutf8(src), "test.ha");
	defer finish_parse_result(&r);
	assert(
		len(r.subunit.decls) == 1,
		"a dangling access on an identifier ending in a digit must still recover the function"
	);
};

// Regression: same for a postfix `!` (propagate) receiver (`foo()!.`),
// which the single-byte check also failed to recognize.
@test fn recovers_dangling_dot_on_postfix_propagate_receiver() void = {
	const src = `export fn f() void = {
	const keep = 42;
	g(foo()!.);
};
`;
	let r = parse_recover(strings::toutf8(src), "test.ha");
	defer finish_parse_result(&r);
	assert(
		len(r.subunit.decls) == 1,
		"a dangling access on a postfix `!` receiver must still recover the function"
	);
};
