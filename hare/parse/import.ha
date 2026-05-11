// SPDX-License-Identifier: MPL-2.0
// (c) Hare authors <https://harelang.org>

use hare::ast;
use hare::lex;
use hare::lex::{ltok};

fn name_list(lexer: *lex::lexer) (ast::import_members | error) = {
	let names: []str = [];
	for (true) {
		append(names, want(lexer, ltok::NAME)?.1 as str)!;
		switch (want(lexer, ltok::COMMA, ltok::RBRACE)?.0) {
		case ltok::COMMA =>
			match (try(lexer, ltok::RBRACE)?) {
			case void => void;
			case =>
				return names;
			};
		case ltok::RBRACE =>
			return names;
		case => abort(); // Unreachable
		};
	};
};

// Parses the import list for a sub-unit
export fn imports(lexer: *lex::lexer) ([]ast::import | error) = {
	let imports: []ast::import = [];
	for (true) {
		match (try(lexer, ltok::USE)?) {
		case void => break;
		case => void;
		};

		append(imports, ast::import {
			bindings = void,
			...
		})!;
		let import = &imports[len(imports) - 1];
		import.loc.start = mkloc(lexer);
		let (name, trailing) = ident_trailing(lexer)?;
		import.ident = name;
		// Track the location of the closing `;` so loc.end can be
		// set to it. Stdlib uses `mkloc(lexer)` after the parse
		// finishes, but mkloc returns the position of the
		// lexer's NEXT token — for hare-lsp the document is
		// parsed in non-COMMENTS mode, so the next token is
		// whatever real code comes after the `use`, possibly
		// several lines later. That makes `loc.end` extend
		// across blank lines and intervening comments, which in
		// turn makes textDocument/documentLink emit a link
		// covering the next comment, underlining it as
		// cmd+clickable in VS Code. Capture the closing `;`
		// token's own location instead.
		let semi_loc: lex::location = lex::location { ... };
		const next_tok = want(lexer, ltok::SEMICOLON, ltok::LBRACE,
			ltok::EQUAL, ltok::TIMES)?;
		switch (next_tok.0) {
		case ltok::SEMICOLON =>
			synassert(mkloc(lexer), !trailing,
				"Unexpected trailing :: in ident")?;
			semi_loc = next_tok.2;
		case ltok::LBRACE =>
			synassert(mkloc(lexer), trailing,
				"Expected trailing :: in ident")?;
			import.bindings = name_list(lexer)?;
			semi_loc = want(lexer, ltok::SEMICOLON)?.2;
		case ltok::EQUAL =>
			synassert(mkloc(lexer),
				len(name) == 1 && !trailing,
				"Expected name, not ident")?;
			import.bindings = name[0];
			free(name);
			import.ident = ident(lexer)?;
			semi_loc = want(lexer, ltok::SEMICOLON)?.2;
		case ltok::TIMES =>
			synassert(mkloc(lexer), trailing,
				"Expected trailing :: in ident")?;
			import.bindings = ast::import_wildcard;
			semi_loc = want(lexer, ltok::SEMICOLON)?.2;
		case => abort(); // Unreachable
		};
		import.loc.end = semi_loc;
	};
	return imports;
};
