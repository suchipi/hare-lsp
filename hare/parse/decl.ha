// SPDX-License-Identifier: MPL-2.0
// (c) Hare authors <https://harelang.org>

use ascii;
use hare::ast;
use hare::lex;
use hare::lex::{ltok};
use strings;

fn attr_symbol(lexer: *lex::lexer) (str | error) = {
	want(lexer, ltok::LPAREN)?;
	let t = want(lexer, ltok::LIT_STR)?;
	let s = t.1 as str;
	let d = strings::iter(s);
	match (strings::next(&d)) {
	case done => void;
	case let r: rune =>
		synassert(t.2, ascii::isalpha(r) || r == '.'
			|| r == '_', "Invalid symbol")?;
	};
	for (let r => strings::next(&d)) {
		synassert(t.2, ascii::isalnum(r) || r == '$'
			|| r == '.' || r == '_', "Invalid symbol")?;
	};
	want(lexer, ltok::RPAREN)?;
	return s;
};

// Parses a command-line definition
export fn define(lexer: *lex::lexer) (ast::decl_const | error) = {
	const ident = ident(lexer)?;
	const _type: nullable *ast::_type = match (try(lexer, ltok::COLON)?) {
	case lex::token => yield alloc(_type(lexer)?)!;
	case void => yield null;
	};
	want(lexer, ltok::EQUAL)?;
	const init: *ast::expr = alloc(expr(lexer)?)!;
	return ast::decl_const {
		ident = ident,
		_type = _type,
		init = init,
	};
};

fn decl_global(
	lexer: *lex::lexer,
	tok: ltok,
	sym: str,
	threadlocal: bool,
) (ast::decl_global | error) = {
	const ident = ident(lexer)?;
	const _type: nullable *ast::_type =
		match (try(lexer, ltok::COLON)?) {
		case lex::token =>
			yield alloc(_type(lexer)?)!;
		case void =>
			yield null;
		};
	const init: nullable *ast::expr =
		match (try(lexer, ltok::EQUAL)?) {
		case lex::token =>
			yield alloc(initializer(lexer)?)!;
		case void =>
			yield null;
		};
	return ast::decl_global {
		is_const = tok == ltok::CONST,
		is_threadlocal = threadlocal,
		symbol = sym,
		ident = ident,
		_type = _type,
		init = init,
	};
};

fn decl_type(lexer: *lex::lexer) (ast::decl_type | error) = {
	let ident = ident(lexer)?;
	want(lexer, ltok::EQUAL)?;
	let _type = _type(lexer)?;
	return ast::decl_type {
		ident = ident,
		_type = alloc(_type)!,
	};
};

fn decl_func(
	lexer: *lex::lexer,
	sym: str,
	attr: ast::fndecl_attr,
) (ast::decl_func | error) = {
	let ident_loc = mkloc(lexer);
	let ident = ident(lexer)?;
	let proto_start = mkloc(lexer);
	let prototype = prototype(lexer)?;
	let proto_end = lex::prevloc(lexer);

	let tok = want(lexer, ltok::EQUAL, ltok::SEMICOLON)?;
	let body = switch (tok.0) {
	case ltok::EQUAL =>
		for (let param &.. prototype.params) {
			synassert(param.loc.start,
				len(param.name) > 0,
				"Expected parameter name in function declaration")?;
		};
		yield alloc(expr(lexer)?)!;
	case ltok::SEMICOLON =>
		lex::unlex(lexer, tok);
		yield null;
	case => abort(); // unreachable
	};

	return ast::decl_func {
		symbol = sym,
		ident = ident,
		prototype = alloc(ast::_type {
			loc = ast::location {
				start = proto_start,
				end = proto_end,
			},
			repr = prototype,
		})!,
		body = body,
		attrs = attr,
	};
};

// Parses a declaration.
export fn decl(lexer: *lex::lexer) (ast::decl | error) = {
	const start = mkloc(lexer);
	let comment = "";
	if (try(lexer, ltok::STATIC)? is lex::token) {
		comment = lex::comment(lexer);
		let expr = assert_expr(lexer, true)?;
		want(lexer, ltok::SEMICOLON)?;
		return ast::decl {
			exported = false,
			loc = ast::location {
				start = start,
				end = expr.loc.end,
			},
			decl = expr.expr as ast::assert_expr,
			docs = comment,
		};
	};
	let exported = match (try(lexer, ltok::EXPORT)?) {
	case void =>
		yield false;
	case lex::token =>
		comment = lex::comment(lexer);
		yield true;
	};

	const attrs = [
		ltok::ATTR_FINI, ltok::ATTR_INIT, ltok::ATTR_TEST,
		ltok::ATTR_SYMBOL, ltok::ATTR_THREADLOCAL,
	];
	let attr = ast::fndecl_attr::NONE, sym = "", threadlocal = false;
	for (true) match (try(lexer, attrs...)?) {
	case void =>
		break;
	case let t: lex::token =>
		synassert(t.2, t.0 == ltok::ATTR_SYMBOL
				|| t.0 == ltok::ATTR_THREADLOCAL || attr == 0,
			"Only one of @init, @fini, or @test may be provided")?;
		switch (t.0) {
		case ltok::ATTR_FINI =>
			attr = ast::fndecl_attr::FINI;
		case ltok::ATTR_INIT =>
			attr = ast::fndecl_attr::INIT;
		case ltok::ATTR_TEST =>
			attr = ast::fndecl_attr::TEST;
		case ltok::ATTR_SYMBOL =>
			sym = attr_symbol(lexer)?;
		case ltok::ATTR_THREADLOCAL =>
			threadlocal = true;
		case =>
			abort("unreachable");
		};
	};

	const t = want(lexer, ltok::CONST, ltok::LET,
		ltok::DEF, ltok::TYPE, ltok::FN)?;
	if (comment == "") {
		comment = lex::comment(lexer);
	};

	synassert(t.2, !threadlocal || t.0 == ltok::LET || t.0 == ltok::CONST,
		"@threadlocal is only valid on globals")?;
	synassert(t.2, sym == "" || t.0 == ltok::LET
			|| t.0 == ltok::CONST || t.0 == ltok::FN,
		"@symbol is only valid on globals and functions")?;
	synassert(t.2, attr == ast::fndecl_attr::NONE || t.0 == ltok::FN,
		"@init, @fini, and @test are only valid on functions")?;

	let decl = switch (t.0) {
	case ltok::FN =>
		yield decl_func(lexer, sym, attr)?;
	case ltok::TYPE =>
		yield decl_type(lexer)?;
	case ltok::LET, ltok::CONST =>
		yield decl_global(lexer, t.0, sym, threadlocal)?;
	case ltok::DEF =>
		yield define(lexer)?;
	case => abort();
	};
	want(lexer, ltok::SEMICOLON)?;
	return ast::decl {
		exported = exported,
		loc = ast::location {
			start = start,
			end = mkloc(lexer),
		},
		decl = decl,
		docs = comment,
	};
};

// Parses the declarations for a sub-unit.
export fn decls(lexer: *lex::lexer) ([]ast::decl | error) = {
	let decls: []ast::decl = [];
	for (true) {
		if (peek(lexer, ltok::EOF)? is lex::token) break;
		append(decls, decl(lexer)?)!;
	};
	free(lex::comment(lexer));
	return decls;
};
