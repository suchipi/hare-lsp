// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Best-effort type-of-expression analysis. The goal is not a full type
// checker (the upstream Hare compiler does that) but a hint-producer for
// LSP UI features that benefit from approximate type info.
//
// Strategy:
//   * Plain literals -> their declared `storage` builtin_type.
//   * Declared types on let/const -> render via unparse.
//   * Other expressions -> "unknown".

use hare::ast;
use hare::unparse;
use io;
use memio;
use strings;

// Returns a best-effort type label for the expression at the given byte
// offset within the file, or void if unknown.
export fn type_of_expr_at(text: []u8, su: *ast::subunit, off: size) (str | void) = {
	for (let i = 0z; i < len(su.decls); i += 1) {
		const d = &su.decls[i];
		if (off < d.loc.start.off: size || off > d.loc.end.off: size) continue;
		match (d.decl) {
		case let g: ast::decl_global =>
			match (g._type) {
			case let t: *ast::_type =>
				return render_type(t);
			case null => void;
			};
			match (g.init) {
			case let e: *ast::expr =>
				return type_of_literal(e);
			case null => void;
			};
		case let c: ast::decl_const =>
			match (c._type) {
			case let t: *ast::_type =>
				return render_type(t);
			case null => void;
			};
			return type_of_literal(c.init);
		case => void;
		};
	};
	return void;
};

fn render_type(t: *ast::_type) str = {
	let buf = memio::dynamic();
	defer io::close(&buf)!;
	match (unparse::_type(&buf, &unparse::syn_nowrap, t)) {
	case size => void;
	case => return strings::dup("?")!;
	};
	return strings::dup(memio::string(&buf)!)!;
};

fn type_of_literal(e: *ast::expr) (str | void) = {
	match (e.expr) {
	case let l: ast::literal_expr =>
		match (l) {
		case let p: ast::plain_literal =>
			return strings::dup(unparse::builtin_type(p.storage))!;
		case ast::array_literal =>
			return strings::dup("[_]_")!;
		case ast::struct_literal =>
			return strings::dup("struct { ... }")!;
		case ast::tuple_literal =>
			return strings::dup("(...)")!;
		};
	case => return void;
	};
};
