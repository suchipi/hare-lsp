// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Hover documentation for Hare's operators and a few related syntactic
// markers (slice/range `..`, variadic `...`, case arrow `=>`). The
// cursor lands on a punctuation byte the lexer would tokenise as an
// operator; we locate the operator, classify its role from the
// surrounding source (binary vs prefix vs postfix vs type-context),
// and render the entry matching that role.
//
// Operator precedence is reported as a 1-14 number, monotonically
// increasing with how tightly the operator binds. The ladder, lowest
// (1) to highest (14):
//
//   1   assignment (=, +=, ..., <<=, &&=, etc.)
//   2   ||
//   3   ^^
//   4   &&
//   5   == !=
//   6   < <= > >=
//   7   |
//   8   ^
//   9   &  (bitwise AND)
//   10  << >>
//   11  + -  (binary)
//   12  * / %
//   13  unary prefix: -  ~  !  *(deref)  &(addr-of)
//   14  postfix: ?  !(error-assert)
//
// Hare's parser uses 0-10 for binary operators only; see
// /usr/local/src/hare/stdlib/hare/parse/expr.ha. The ladder above
// renumbers to 1-12 in the same order and adds 13 / 14 for unary and
// postfix tiers so every operator gets a single comparable number.

use analysis;
use encoding::json;
use lsp;
use strings;

// Tries to send a hover response for an operator under the cursor.
// Returns true if a response was sent.
export fn try_send_operator_hover(
	s: *server, r: lsp::request, doc: *document, data: []u8, off: size,
) bool = {
	const found = match (operator_at(data, off)) {
	case let v: (size, size, str) => yield v;
	case void => return false;
	};
	const role = classify_op_role(data, found.0, found.2);
	const (sig, docs) = match (lookup_operator(found.2, role)) {
	case let v: (str, str) => yield v;
	case void => return false;
	};
	defer free(sig);
	defer free(docs);

	const md = build_hover_markdown(s, doc, sig, docs);
	defer free(md);

	let result = json::newobject();
	let contents = json::newobject();
	json::set(&contents, "kind", "markdown": json::value)!;
	json::set(&contents, "value", md: json::value)!;
	json::put(&result, "contents", contents)!;

	const enc = position_encoding(s);
	const start_pos = analysis::byte_to_position(data, doc.buf.line_index,
		enc, found.0);
	const end_pos = analysis::byte_to_position(data, doc.buf.line_index,
		enc, found.1);
	let range = json::newobject();
	let s_obj = json::newobject();
	json::put(&s_obj, "line", start_pos.line: f64)!;
	json::put(&s_obj, "character", start_pos.character: f64)!;
	let e_obj = json::newobject();
	json::put(&e_obj, "line", end_pos.line: f64)!;
	json::put(&e_obj, "character", end_pos.character: f64)!;
	json::put(&range, "start", s_obj)!;
	json::put(&range, "end", e_obj)!;
	json::put(&result, "range", range)!;

	send_with_finish(s, r.id, result: json::value);
	return true;
};

// Locates the operator token covering byte offset `off` in `data`.
// Returns (start, end, op-text). Longer operators win over shorter ones
// (so `||=` resolves before `||`, and `&&` before `&`).
fn operator_at(data: []u8, off: size) ((size, size, str) | void) = {
	let scan = off;
	if (scan >= len(data) || !is_op_byte(data[scan])) {
		// Cursor past the operator (end of file or sitting on the
		// next byte): only back off when that next byte is
		// whitespace, so a click on a distinct adjacent character
		// (e.g. cursor on `,` immediately after `]`) doesn't
		// surface the prior token's tooltip.
		if (scan < len(data)) {
			const b = data[scan];
			if (b != ' ': u8 && b != '\t': u8
					&& b != '\n': u8 && b != '\r': u8) {
				return void;
			};
		};
		if (scan == 0) return void;
		if (!is_op_byte(data[scan - 1])) return void;
		scan = scan - 1;
	};

	// Expand to the contiguous run of operator bytes around `scan`.
	let run_start = scan;
	for (run_start > 0; run_start -= 1) {
		if (!is_op_byte(data[run_start - 1])) break;
	};
	let run_end = scan;
	for (run_end < len(data); run_end += 1) {
		if (!is_op_byte(data[run_end])) break;
	};

	// Within the run, try every substring strictly covering `scan`,
	// longest first. We pivot on `scan` (not the original `off`) so
	// the back-off above behaves: if the cursor sat on whitespace
	// just past a token, scan is the token's last byte and the
	// strict check still matches. Strict bounds (i <= scan < i+n)
	// matter when two op-bytes are adjacent: if scan is on the
	// second byte, the operator that ENDS at scan must not be
	// chosen over the operator that BEGINS at scan.
	const run_len = run_end - run_start;
	for (let n = run_len; n > 0; n -= 1) {
		for (let i = run_start; i + n <= run_end; i += 1) {
			if (scan < i) continue;
			if (scan >= i + n) continue;
			const candidate = strings::fromutf8(data[i..i + n])!;
			if (operator_known(candidate)) {
				return (i, i + n, candidate);
			};
		};
	};
	return void;
};

fn is_op_byte(b: u8) bool = {
	switch (b) {
	case '+': u8, '-': u8, '*': u8, '/': u8, '%': u8,
		'&': u8, '|': u8, '^': u8, '~': u8, '!': u8,
		'<': u8, '>': u8, '=': u8, '?': u8, '.': u8,
		'{': u8, '}': u8, ':': u8, '[': u8, ']': u8,
		'(': u8, ')': u8, ';': u8, ',': u8 =>
		return true;
	case =>
		return false;
	};
};

// Roles tag each operator entry with the syntactic context it
// documents. The classifier picks one based on the bytes around the
// cursor; the lookup then matches that role exactly so the tooltip
// describes only the meaning in use at that position. `ANY` is for
// operators with a single meaning.
type op_role = enum {
	ANY,
	BINARY,
	PREFIX,
	POSTFIX,
	TYPE,
	LABEL,

	// `..` contexts
	SLICE,
	FOR_EACH_VALUE,

	// `=>` contexts
	CASE_ARROW,
	FOR_ITERATOR,

	// `...` contexts
	VARIADIC_PARAM,
	SPREAD,
	ARRAY_EXPAND,
	STRUCT_AUTOFILL,

	// `.` contexts
	FIELD_ACCESS,
	TUPLE_INDEX,

	// `{` / `}` contexts
	FUNC_BODY,
	COMPOUND_BLOCK,
	STRUCT_BODY,
	UNION_BODY,
	ENUM_BODY,
	MATCH_BODY,
	SWITCH_BODY,
	STRUCT_LITERAL,

	// `[` / `]` contexts
	INDEX_SLICE,
	ARRAY_TYPE,
	SLICE_TYPE,
	ARRAY_LITERAL,

	// `(` / `)` contexts
	IF_HEADER,
	FOR_HEADER,
	MATCH_HEADER,
	SWITCH_HEADER,
	CALL,
	PARAM_LIST,
	TYPE_PARENS,
	EXPR_PARENS,

	// `;` contexts
	TERMINATOR,
};

// Returns (sig, docs) for the operator `name` in the given `role`.
// Tries an exact (name, role) match first; falls back to (name, ANY).
// Returns void if no entry matches. Strings are freshly allocated.
fn lookup_operator(name: str, role: op_role) ((str, str) | void) = {
	for (let i = 0z; i < len(operators); i += 1) {
		if (operators[i].name != name) continue;
		if (operators[i].role != role) continue;
		return (strings::dup(operators[i].sig)!,
			strings::dup(operators[i].docs)!);
	};
	for (let i = 0z; i < len(operators); i += 1) {
		if (operators[i].name != name) continue;
		if (operators[i].role == op_role::ANY) {
			return (strings::dup(operators[i].sig)!,
				strings::dup(operators[i].docs)!);
		};
	};
	return void;
};

fn operator_known(name: str) bool = {
	for (let i = 0z; i < len(operators); i += 1) {
		if (operators[i].name == name) return true;
	};
	return false;
};

// Classifies the role of the operator `name` whose first byte is at
// `op_start` based on the bytes immediately preceding it. For
// unambiguous operators returns ANY (the lookup falls through to the
// single registered entry).
fn classify_op_role(data: []u8, op_start: size, name: str) op_role = {
	// `!`: postfix when it follows a value, prefix otherwise.
	if (name == "!") {
		return if (is_value_end_before(data, op_start))
			op_role::POSTFIX else op_role::PREFIX;
	};
	// `&`, `-`: binary when after a value, prefix otherwise.
	if (name == "&" || name == "-") {
		return if (is_value_end_before(data, op_start))
			op_role::BINARY else op_role::PREFIX;
	};
	// `*`: binary after a value; otherwise pointer-to in a type
	// position, dereference in an expression position.
	if (name == "*") {
		if (is_value_end_before(data, op_start)) return op_role::BINARY;
		return if (is_type_position(data, op_start))
			op_role::TYPE else op_role::PREFIX;
	};
	// `|`: tagged union member in a type position, bitwise OR otherwise.
	if (name == "|") {
		return if (is_type_position(data, op_start))
			op_role::TYPE else op_role::BINARY;
	};
	// `:`: label prefix, cast expression, or type annotation.
	if (name == ":") return classify_colon_role(data, op_start);
	// `..`: slice/range vs by-value iterator binding in a `for` header.
	if (name == "..") return classify_double_dot_role(data, op_start);
	// `=>`: match/switch case arrow vs `for` iterator binding.
	if (name == "=>") return classify_arrow_role(data, op_start);
	// `...`: variadic param, spread, array-fill, or struct-autofill.
	if (name == "...") return classify_ellipsis_role(data, op_start);
	// `.`: struct/union field access vs tuple positional access.
	if (name == ".") return classify_dot_role(data, op_start);
	// `{` / `}`: which block-shaped construct.
	if (name == "{") return classify_lbrace_role(data, op_start);
	if (name == "}") return classify_rbrace_role(data, op_start);
	// `[` / `]`: index/slice vs array type vs array literal.
	if (name == "[") return classify_lbracket_role(data, op_start);
	if (name == "]") return classify_rbracket_role(data, op_start);
	// `(` / `)`: control header vs call vs param list vs type/expr parens.
	if (name == "(") return classify_lparen_role(data, op_start);
	if (name == ")") return classify_rparen_role(data, op_start);
	// `;`: general terminator vs separator inside a `for` header.
	if (name == ";") return classify_semicolon_role(data, op_start);
	// `,`: role mirrors the enclosing bracket's role.
	if (name == ",") return classify_comma_role(data, op_start);
	return op_role::ANY;
};

// Holds a bracket position and its kind ('(', '[', or '{').
type bracket_info = struct {
	pos: size,
	kind: u8,
};

// Forward scan from byte 0 to `target`, tracking a stack of open
// brackets while skipping strings/comments via token_skip_noncode.
// Returns the topmost unmatched bracket, or void if none.
fn enclosing_bracket(data: []u8, target: size) (bracket_info | void) = {
	let stack: []bracket_info = [];
	defer free(stack);
	let i = 0z;
	const lim = if (target <= len(data)) target else len(data);
	for (i < lim) {
		const next = analysis::token_skip_noncode(data, i, lim);
		if (next != i) {
			i = next;
			continue;
		};
		const b = data[i];
		if (b == '(': u8 || b == '[': u8 || b == '{': u8) {
			append(stack, bracket_info {
				pos = i, kind = b,
			})!;
		} else if (b == ')': u8 || b == ']': u8 || b == '}': u8) {
			if (len(stack) > 0) {
				stack = stack[..len(stack) - 1];
			};
		};
		i += 1;
	};
	if (len(stack) == 0) return void;
	return stack[len(stack) - 1];
};

// True if the byte/word immediately preceding `pos` (skipping
// whitespace) is the identifier `keyword`, with a non-ident byte
// before it.
fn token_preceded_by_keyword(
	data: []u8, pos: size, keyword: str,
) bool = {
	let i = pos;
	for (i > 0; i -= 1) {
		const b = data[i - 1];
		if (b != ' ': u8 && b != '\t': u8 && b != '\n': u8
				&& b != '\r': u8) break;
	};
	if (i < len(keyword)) return false;
	if (strings::fromutf8(data[i - len(keyword)..i])! != keyword) {
		return false;
	};
	if (i == len(keyword)) return true;
	return !is_ident_byte(data[i - len(keyword) - 1]);
};

// `..` inside `[` is a slice; inside `(...)` after `for` is the
// each-value iterator binding. Default: slice.
fn classify_double_dot_role(data: []u8, op_start: size) op_role = {
	match (enclosing_bracket(data, op_start)) {
	case let b: bracket_info =>
		if (b.kind == '[': u8) return op_role::SLICE;
		if (b.kind == '(': u8
				&& token_preceded_by_keyword(data, b.pos, "for")) {
			return op_role::FOR_EACH_VALUE;
		};
	case void => void;
	};
	return op_role::SLICE;
};

// `=>` inside `(...)` after `for` is the iterator binding; otherwise
// it's a `match`/`switch` case arrow.
fn classify_arrow_role(data: []u8, op_start: size) op_role = {
	match (enclosing_bracket(data, op_start)) {
	case let b: bracket_info =>
		if (b.kind == '(': u8
				&& token_preceded_by_keyword(data, b.pos, "for")) {
			return op_role::FOR_ITERATOR;
		};
	case void => void;
	};
	return op_role::CASE_ARROW;
};

// `...` context. `[...]` is array-fill, `{...}` is struct-autofill,
// `(...)` is either a variadic param (when the `...` immediately
// follows a `name: type` annotation) or a call-site spread.
fn classify_ellipsis_role(data: []u8, op_start: size) op_role = {
	match (enclosing_bracket(data, op_start)) {
	case let b: bracket_info =>
		if (b.kind == '[': u8) return op_role::ARRAY_EXPAND;
		if (b.kind == '{': u8) return op_role::STRUCT_AUTOFILL;
		if (b.kind == '(': u8) {
			return classify_paren_ellipsis(data, op_start);
		};
	case void => void;
	};
	return op_role::SPREAD;
};

// Inside a `(...)`, decide whether `...` is a variadic parameter
// declaration (`name: type...`) or a call-site spread (`value...`).
// Heuristic: walk back across the preceding identifier; if a `:` (with
// possible whitespace) precedes it, this is a type-annotated variadic
// parameter, otherwise a spread.
fn classify_paren_ellipsis(data: []u8, op_start: size) op_role = {
	let i = op_start;
	for (i > 0; i -= 1) {
		const b = data[i - 1];
		if (b != ' ': u8 && b != '\t': u8) break;
	};
	if (i == 0 || !is_ident_byte(data[i - 1])) return op_role::SPREAD;
	for (i > 0; i -= 1) {
		if (!is_ident_byte(data[i - 1])) break;
	};
	for (i > 0; i -= 1) {
		const b = data[i - 1];
		if (b != ' ': u8 && b != '\t': u8) break;
	};
	if (i == 0) return op_role::SPREAD;
	if (data[i - 1] == ':': u8) return op_role::VARIADIC_PARAM;
	return op_role::SPREAD;
};

// `.` followed by a digit is tuple positional access; followed by an
// identifier byte (or anything else) it's a struct/union field access.
fn classify_dot_role(data: []u8, op_start: size) op_role = {
	if (op_start + 1 >= len(data)) return op_role::FIELD_ACCESS;
	const next = data[op_start + 1];
	if (next >= '0': u8 && next <= '9': u8) return op_role::TUPLE_INDEX;
	return op_role::FIELD_ACCESS;
};

// `{` classifier: walks back past whitespace and inspects the
// preceding byte/word to determine which block-shaped construct this
// `{` opens.
fn classify_lbrace_role(data: []u8, brace_pos: size) op_role = {
	let i = brace_pos;
	for (i > 0) {
		i -= 1;
		const b = data[i];
		if (b == ' ': u8 || b == '\t': u8 || b == '\n': u8
				|| b == '\r': u8) continue;
		if (b == '=': u8) {
			if (i > 0 && data[i - 1] == '=': u8) {
				return op_role::COMPOUND_BLOCK;
			};
			return op_role::FUNC_BODY;
		};
		if (b == '>': u8) return op_role::COMPOUND_BLOCK;
		if (b == ';': u8) return op_role::COMPOUND_BLOCK;
		if (b == '{': u8) return op_role::COMPOUND_BLOCK;
		if (b == ',': u8) return op_role::COMPOUND_BLOCK;
		if (b == ')': u8) return classify_lbrace_after_rparen(data, i);
		if (is_ident_byte(b)) {
			let end = i + 1;
			let start = i;
			for (start > 0; start -= 1) {
				if (!is_ident_byte(data[start - 1])) break;
			};
			const word = strings::fromutf8(data[start..end])!;
			switch (word) {
			case "struct" => return op_role::STRUCT_BODY;
			case "union" => return op_role::UNION_BODY;
			case "enum" => return op_role::ENUM_BODY;
			case =>
				let j = start;
				for (j > 0; j -= 1) {
					const bb = data[j - 1];
					if (bb != ' ': u8 && bb != '\t': u8
							&& bb != '\n': u8
							&& bb != '\r': u8) break;
				};
				if (j >= 4) {
					const prev_word = strings::fromutf8(
						data[j - 4..j])!;
					const is_at_start = j == 4
						|| !is_ident_byte(data[j - 5]);
					if (prev_word == "enum" && is_at_start) {
						return op_role::ENUM_BODY;
					};
				};
				return op_role::STRUCT_LITERAL;
			};
		};
		return op_role::COMPOUND_BLOCK;
	};
	return op_role::COMPOUND_BLOCK;
};

// `{` preceded by `)`: find the matching `(` and look at the word
// before it. Only `match` and `switch` have role-specific entries;
// anything else (`if`, `for`, `while`, plain grouped expression) opens
// a compound expression. Function bodies have `=` before the `{`, not
// `)`.
fn classify_lbrace_after_rparen(data: []u8, rparen_pos: size) op_role = {
	let depth = 1;
	let i = rparen_pos;
	for (i > 0) {
		i -= 1;
		const b = data[i];
		if (b == ')': u8) {
			depth += 1;
		} else if (b == '(': u8) {
			depth -= 1;
			if (depth == 0) break;
		};
	};
	if (depth != 0) return op_role::COMPOUND_BLOCK;
	let j = i;
	for (j > 0; j -= 1) {
		const b = data[j - 1];
		if (b != ' ': u8 && b != '\t': u8 && b != '\n': u8
				&& b != '\r': u8) break;
	};
	if (j == 0 || !is_ident_byte(data[j - 1])) return op_role::COMPOUND_BLOCK;
	let end = j;
	let start = j;
	for (start > 0; start -= 1) {
		if (!is_ident_byte(data[start - 1])) break;
	};
	const word = strings::fromutf8(data[start..end])!;
	switch (word) {
	case "match" => return op_role::MATCH_BODY;
	case "switch" => return op_role::SWITCH_BODY;
	case =>
		return op_role::COMPOUND_BLOCK;
	};
};

// `}` classifier: walks back to find the matching `{`, then runs the
// `{` classifier so the close brace's tooltip mirrors the open's.
fn classify_rbrace_role(data: []u8, rbrace_pos: size) op_role = {
	let depth = 1;
	let i = rbrace_pos;
	for (i > 0) {
		i -= 1;
		const b = data[i];
		if (b == '}': u8) {
			depth += 1;
		} else if (b == '{': u8) {
			depth -= 1;
			if (depth == 0) {
				return classify_lbrace_role(data, i);
			};
		};
	};
	return op_role::COMPOUND_BLOCK;
};

// `[` classifier: index/slice if the bracket follows a value (so it
// reads as `value[...]`); slice type when the bracket sits in a type
// position with an empty body (`[]T`); array type for length-bearing
// forms (`[N]T`, `[*]T`, `[_]T`); array literal otherwise.
fn classify_lbracket_role(data: []u8, bracket_pos: size) op_role = {
	if (is_value_end_before(data, bracket_pos)) {
		return op_role::INDEX_SLICE;
	};
	if (is_type_position(data, bracket_pos)) {
		if (is_empty_bracket_pair(data, bracket_pos)) {
			return op_role::SLICE_TYPE;
		};
		return op_role::ARRAY_TYPE;
	};
	return op_role::ARRAY_LITERAL;
};

// True when `[` at `bracket_pos` is immediately closed by `]` (no
// content between, possibly with internal whitespace). Used to
// distinguish the slice type `[]T` from length-bearing array types
// like `[N]T`.
fn is_empty_bracket_pair(data: []u8, bracket_pos: size) bool = {
	let i = bracket_pos + 1;
	for (i < len(data); i += 1) {
		const b = data[i];
		if (b == ']': u8) return true;
		if (b != ' ': u8 && b != '\t': u8 && b != '\n': u8
				&& b != '\r': u8) return false;
	};
	return false;
};

// `]` classifier: walks back to find the matching `[`, then runs the
// `[` classifier so the close bracket mirrors the open's role.
fn classify_rbracket_role(data: []u8, rbracket_pos: size) op_role = {
	let depth = 1;
	let i = rbracket_pos;
	for (i > 0) {
		i -= 1;
		const b = data[i];
		if (b == ']': u8) {
			depth += 1;
		} else if (b == '[': u8) {
			depth -= 1;
			if (depth == 0) {
				return classify_lbracket_role(data, i);
			};
		};
	};
	return op_role::INDEX_SLICE;
};

// `(` classifier: walks back over whitespace and inspects the
// preceding byte/word to decide what the parens are for. Order matters:
// keyword headers win over CALL when the previous identifier is a
// control-flow keyword; PARAM_LIST wins over CALL when the previous
// identifier is itself preceded by `fn`.
fn classify_lparen_role(data: []u8, paren_pos: size) op_role = {
	let i = paren_pos;
	for (i > 0; i -= 1) {
		const b = data[i - 1];
		if (b != ' ': u8 && b != '\t': u8 && b != '\n': u8
				&& b != '\r': u8) break;
	};
	if (i == 0) {
		// Start of file, weird; treat as expression parens.
		return op_role::EXPR_PARENS;
	};
	const prev = data[i - 1];
	if (is_ident_byte(prev)) {
		let end = i;
		let start = i;
		for (start > 0; start -= 1) {
			if (!is_ident_byte(data[start - 1])) break;
		};
		const word = strings::fromutf8(data[start..end])!;
		switch (word) {
		case "if" => return op_role::IF_HEADER;
		case "for" => return op_role::FOR_HEADER;
		case "match" => return op_role::MATCH_HEADER;
		case "switch" => return op_role::SWITCH_HEADER;
		case =>
			// Identifier - distinguish CALL from PARAM_LIST by
			// looking for a `fn` keyword two tokens back.
			let j = start;
			for (j > 0; j -= 1) {
				const bb = data[j - 1];
				if (bb != ' ': u8 && bb != '\t': u8
						&& bb != '\n': u8
						&& bb != '\r': u8) break;
			};
			if (j >= 2) {
				const prev_word = strings::fromutf8(
					data[j - 2..j])!;
				const at_start = j == 2
					|| !is_ident_byte(data[j - 3]);
				if (prev_word == "fn" && at_start) {
					return op_role::PARAM_LIST;
				};
			};
			return op_role::CALL;
		};
	};
	if (is_value_end_byte(prev)) return op_role::CALL;
	if (is_type_position(data, paren_pos)) return op_role::TYPE_PARENS;
	return op_role::EXPR_PARENS;
};

// `)` classifier: walks back to the matching `(` and runs the `(`
// classifier so the close paren's tooltip mirrors the open's role.
fn classify_rparen_role(data: []u8, rparen_pos: size) op_role = {
	let depth = 1;
	let i = rparen_pos;
	for (i > 0) {
		i -= 1;
		const b = data[i];
		if (b == ')': u8) {
			depth += 1;
		} else if (b == '(': u8) {
			depth -= 1;
			if (depth == 0) {
				return classify_lparen_role(data, i);
			};
		};
	};
	return op_role::EXPR_PARENS;
};

// `;` classifier: separator inside a `for (...)` header gets the
// FOR_HEADER role; otherwise general statement/decl terminator.
fn classify_semicolon_role(data: []u8, semi_pos: size) op_role = {
	match (enclosing_bracket(data, semi_pos)) {
	case let b: bracket_info =>
		if (b.kind == '(': u8
				&& token_preceded_by_keyword(data, b.pos, "for")) {
			return op_role::FOR_HEADER;
		};
	case void => void;
	};
	return op_role::TERMINATOR;
};

// `,` classifier: role mirrors the role of the enclosing bracket (a
// comma in a `(` opened as CALL is a call-arg separator, a comma in
// `[` opened as ARRAY_LITERAL is an array-element separator, and so
// on). With no enclosing bracket, falls back to ANY (used for
// top-level multi-decls like `type a = T1, b = T2;`).
fn classify_comma_role(data: []u8, comma_pos: size) op_role = {
	match (enclosing_bracket(data, comma_pos)) {
	case let b: bracket_info =>
		if (b.kind == '(': u8) {
			return classify_lparen_role(data, b.pos);
		};
		if (b.kind == '[': u8) {
			return classify_lbracket_role(data, b.pos);
		};
		if (b.kind == '{': u8) {
			return classify_lbrace_role(data, b.pos);
		};
	case void => void;
	};
	return op_role::ANY;
};

// Classifies a `:` at `op_start`:
//   LABEL  - `:name` form following a label-introducing context
//            (`for`, `match`, `switch`, `break`, `continue`, `yield`, `{`).
//   BINARY - cast expression: the byte before the colon (skipping
//            whitespace) ends a complex value expression
//            (`)` `]` `}` `?` `!` digit) OR the colon follows
//            `identifier` which is itself preceded by an
//            expression-introducing token (`=`, operator, `return`,
//            `yield`, `defer`, `else`).
//   TYPE   - default; covers `let x: T`, `fn f(p: T)`, struct fields,
//            and `case let v: T`.
fn classify_colon_role(data: []u8, op_start: size) op_role = {
	if (is_label_colon(data, op_start)) return op_role::LABEL;
	if (is_complex_expr_end_before(data, op_start)) return op_role::BINARY;
	return classify_colon_by_ident_context(data, op_start);
};

// True if the colon at `op_start` is a label prefix: it's followed by
// an identifier byte and preceded (after whitespace) by a
// label-introducing keyword or `{`.
fn is_label_colon(data: []u8, op_start: size) bool = {
	if (op_start + 1 >= len(data)) return false;
	if (!is_ident_byte(data[op_start + 1])) return false;
	let i = op_start;
	for (i > 0) {
		i -= 1;
		const b = data[i];
		if (b == ' ': u8 || b == '\t': u8 || b == '\n': u8
				|| b == '\r': u8) continue;
		if (b == '{': u8) return true;
		if (!is_ident_byte(b)) return false;
		let end = i + 1;
		let start = i;
		for (start > 0; start -= 1) {
			if (!is_ident_byte(data[start - 1])) break;
		};
		const word = strings::fromutf8(data[start..end])!;
		switch (word) {
		case "for", "match", "switch",
			"break", "continue", "yield" =>
			return true;
		case =>
			return false;
		};
	};
	return false;
};

// True if the byte immediately preceding `op_start` (skipping spaces
// and tabs) can only end a complex value expression: `)`, `]`, `}`,
// `?`, `!`, or a digit. A bare identifier doesn't qualify because it
// could equally be a binding name.
fn is_complex_expr_end_before(data: []u8, op_start: size) bool = {
	let i = op_start;
	for (i > 0) {
		i -= 1;
		const b = data[i];
		if (b == ' ': u8 || b == '\t': u8) continue;
		if (b == '\n': u8 || b == '\r': u8) return false;
		switch (b) {
		case ')': u8, ']': u8, '}': u8, '?': u8, '!': u8 =>
			return true;
		case =>
			void;
		};
		if (b >= '0': u8 && b <= '9': u8) return true;
		return false;
	};
	return false;
};

// Walks back from `:` over an identifier (the binding name or value
// name) and looks at what precedes it. Resolves the cast-vs-annotation
// ambiguity for `name: T`: returns BINARY when the surrounding context
// is expression-shaped (`= name: T`, `return name: T`, …), TYPE
// otherwise (`let name: T`, struct field, etc.).
fn classify_colon_by_ident_context(data: []u8, op_start: size) op_role = {
	let i = op_start;
	for (i > 0; i -= 1) {
		const b = data[i - 1];
		if (b != ' ': u8 && b != '\t': u8) break;
	};
	if (i == 0 || !is_ident_byte(data[i - 1])) return op_role::TYPE;
	for (i > 0; i -= 1) {
		if (!is_ident_byte(data[i - 1])) break;
	};
	for (i > 0; i -= 1) {
		const b = data[i - 1];
		if (b != ' ': u8 && b != '\t': u8 && b != '\n': u8
				&& b != '\r': u8) break;
	};
	if (i == 0) return op_role::TYPE;
	const b = data[i - 1];
	switch (b) {
	case '=': u8 =>
		if (i >= 2 && data[i - 2] == '=': u8) return op_role::TYPE;
		return op_role::BINARY;
	case '+': u8, '-': u8, '*': u8, '/': u8, '%': u8,
		'^': u8, '~': u8, '<': u8, '>': u8, '?': u8 =>
		return op_role::BINARY;
	case '(': u8, ',': u8, '{': u8 =>
		return op_role::TYPE;
	case =>
		void;
	};
	if (!is_ident_byte(b)) return op_role::TYPE;
	let kw_end = i;
	let kw_start = i;
	for (kw_start > 0; kw_start -= 1) {
		if (!is_ident_byte(data[kw_start - 1])) break;
	};
	const word = strings::fromutf8(data[kw_start..kw_end])!;
	switch (word) {
	case "return", "yield", "defer", "else" =>
		return op_role::BINARY;
	case =>
		return op_role::TYPE;
	};
};

// True if the byte immediately preceding `op_start` (skipping spaces
// and tabs, stopping at newlines) is one that can legally end a value
// expression: a letter, digit, '_', ')', ']', '?', '!'. Keywords that
// introduce an expression or a type (and so cannot end a value) are
// rejected even though they end in identifier bytes.
fn is_value_end_before(data: []u8, op_start: size) bool = {
	let i = op_start;
	for (i > 0) {
		i -= 1;
		const b = data[i];
		if (b == ' ': u8 || b == '\t': u8) continue;
		if (b == '\n': u8 || b == '\r': u8) return false;
		if (!is_value_end_byte(b)) return false;
		if (is_ident_byte(b)) {
			let word_end = i + 1;
			let word_start = i;
			for (word_start > 0; word_start -= 1) {
				if (!is_ident_byte(data[word_start - 1])) break;
			};
			const word = strings::fromutf8(
				data[word_start..word_end])!;
			if (is_keyword_not_value(word)) return false;
		};
		return true;
	};
	return false;
};

// True for Hare keywords that, when they appear immediately before an
// operator, mean the next operator is unary/prefix or in a type
// position — i.e. the previous token does NOT end a value expression.
fn is_keyword_not_value(word: str) bool = {
	switch (word) {
	case "return", "yield", "defer", "else", "case",
		"as", "is", "nullable" =>
		return true;
	case =>
		return false;
	};
};

fn is_value_end_byte(b: u8) bool = {
	if (b >= 'a': u8 && b <= 'z': u8) return true;
	if (b >= 'A': u8 && b <= 'Z': u8) return true;
	if (b >= '0': u8 && b <= '9': u8) return true;
	switch (b) {
	case '_': u8, ')': u8, ']': u8, '?': u8, '!': u8 =>
		return true;
	case =>
		return false;
	};
};

// True if the operator at `op_start` appears in a type position
// (annotation, type alias RHS, `as`/`is` operand, or nested inside
// another type construct). Heuristic: walk back from the operator
// through spaces; if the immediately preceding byte/word is one of `:`,
// `*`, `]`, `as`, `is`, or `=` introducing a `type X =` alias, treat as
// type. Otherwise look at the enclosing `(...)` and apply the same test
// to whatever precedes the open paren.
fn is_type_position(data: []u8, op_start: size) bool = {
	if (prev_token_is_type_marker(data, op_start)) return true;
	const lp = match (enclosing_paren_pos(data, op_start)) {
	case let p: size => yield p;
	case void => return false;
	};
	return prev_token_is_type_marker(data, lp);
};

// Looks at the non-whitespace byte (or word) preceding `pos` and
// reports whether it is a type-context introducer.
fn prev_token_is_type_marker(data: []u8, pos: size) bool = {
	let i = pos;
	for (i > 0) {
		i -= 1;
		const b = data[i];
		if (b == ' ': u8 || b == '\t': u8 || b == '\n': u8
				|| b == '\r': u8) continue;
		switch (b) {
		case ':': u8 => return true;
		case '*': u8 => return true;
		case ']': u8 => return true;
		case '=': u8 =>
			return is_type_alias_eq(data, i);
		case =>
			break;
		};
	};
	if (i == 0) return false;
	// Trailing identifier-shaped token: read it backwards.
	if (!is_ident_byte(data[i])) return false;
	let kw_end = i + 1;
	let kw_start = i;
	for (kw_start > 0; kw_start -= 1) {
		if (!is_ident_byte(data[kw_start - 1])) break;
	};
	const word = strings::fromutf8(data[kw_start..kw_end])!;
	return word == "as" || word == "is" || word == "nullable";
};

fn is_ident_byte(b: u8) bool = {
	if (b >= 'a': u8 && b <= 'z': u8) return true;
	if (b >= 'A': u8 && b <= 'Z': u8) return true;
	if (b >= '0': u8 && b <= '9': u8) return true;
	return b == '_': u8;
};

// Given an `=` at `eq_pos`, returns true if it introduces the RHS of a
// `type IDENT =` declaration. Walks back over whitespace, then an
// identifier, then whitespace, and checks that the next four bytes
// spell `type` with a non-ident byte before them.
fn is_type_alias_eq(data: []u8, eq_pos: size) bool = {
	let i = eq_pos;
	for (i > 0; i -= 1) {
		const b = data[i - 1];
		if (b != ' ': u8 && b != '\t': u8 && b != '\n': u8
				&& b != '\r': u8) break;
	};
	for (i > 0; i -= 1) {
		if (!is_ident_byte(data[i - 1])) break;
	};
	for (i > 0; i -= 1) {
		const b = data[i - 1];
		if (b != ' ': u8 && b != '\t': u8 && b != '\n': u8
				&& b != '\r': u8) break;
	};
	if (i < 4) return false;
	if (strings::fromutf8(data[i - 4..i])! != "type") return false;
	if (i - 4 == 0) return true;
	return !is_ident_byte(data[i - 5]);
};

// Forward scan from byte 0 to `target`, tracking paren depth while
// skipping over strings/comments/runes. Returns the position of the
// most recently opened, still-unclosed `(`, or void if none. Used to
// decide whether an operator is inside type-context parens.
fn enclosing_paren_pos(data: []u8, target: size) (size | void) = {
	let stack: []size = [];
	defer free(stack);
	let i = 0z;
	const lim = if (target <= len(data)) target else len(data);
	for (i < lim) {
		const next = analysis::token_skip_noncode(data, i, lim);
		if (next != i) {
			i = next;
			continue;
		};
		const b = data[i];
		if (b == '(': u8) {
			append(stack, i)!;
		} else if (b == ')': u8) {
			if (len(stack) > 0) {
				stack = stack[..len(stack) - 1];
			};
		};
		i += 1;
	};
	if (len(stack) == 0) return void;
	return stack[len(stack) - 1];
};

type operator_entry = struct {
	name: str,
	role: op_role,
	sig: str,
	docs: str,
};

const operators: [_]operator_entry = [
	// --- logical binary ----------------------------------------

	operator_entry {
		name = "||",
		role = op_role::ANY,
		sig = "a || b",
		docs = "**Precedence: 2** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Logical OR on `bool` operands. "
			"Short-circuits: if `a` is `true`, `b` is not "
			"evaluated. Yields `bool`. Left-associative.",
	},
	operator_entry {
		name = "^^",
		role = op_role::ANY,
		sig = "a ^^ b",
		docs = "**Precedence: 3** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Logical exclusive-or on `bool` "
			"operands. Yields `true` when exactly one operand "
			"is `true`. Both operands are always evaluated. "
			"Left-associative.",
	},
	operator_entry {
		name = "&&",
		role = op_role::ANY,
		sig = "a && b",
		docs = "**Precedence: 4** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Logical AND on `bool` operands. "
			"Short-circuits: if `a` is `false`, `b` is not "
			"evaluated. Yields `bool`. Left-associative.",
	},

	// --- equality / ordering -----------------------------------

	operator_entry {
		name = "==",
		role = op_role::ANY,
		sig = "a == b",
		docs = "**Precedence: 5** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Equality comparison. Defined for "
			"primitives, pointers, and strings (which compare "
			"by content). Yields `bool`. Left-associative.",
	},
	operator_entry {
		name = "!=",
		role = op_role::ANY,
		sig = "a != b",
		docs = "**Precedence: 5** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Inequality comparison. The negation "
			"of `==`. Yields `bool`. Left-associative.",
	},
	operator_entry {
		name = "<",
		role = op_role::ANY,
		sig = "a < b",
		docs = "**Precedence: 6** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Less-than ordering on numeric, "
			"pointer, and string operands. Strings compare "
			"lexicographically by byte. Yields `bool`. "
			"Left-associative.",
	},
	operator_entry {
		name = "<=",
		role = op_role::ANY,
		sig = "a <= b",
		docs = "**Precedence: 6** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Less-than-or-equal ordering. "
			"Yields `bool`. Left-associative.",
	},
	operator_entry {
		name = ">",
		role = op_role::ANY,
		sig = "a > b",
		docs = "**Precedence: 6** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Greater-than ordering. Yields "
			"`bool`. Left-associative.",
	},
	operator_entry {
		name = ">=",
		role = op_role::ANY,
		sig = "a >= b",
		docs = "**Precedence: 6** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Greater-than-or-equal ordering. "
			"Yields `bool`. Left-associative.",
	},

	// --- bitwise -----------------------------------------------

	operator_entry {
		name = "|",
		role = op_role::BINARY,
		sig = "a | b",
		docs = "**Precedence: 7** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Bitwise OR on integer operands. "
			"Left-associative. Note that this is **looser** "
			"than comparison in Hare: `a | b == c` parses as "
			"`a | (b == c)`. C's ordering is the reverse.",
	},
	operator_entry {
		name = "|",
		role = op_role::TYPE,
		sig = "(T | U | ...)",
		docs = "**Tagged-union type separator.** Combines two or "
			"more types into a single tagged union: a value of "
			"the union holds exactly one of the listed types "
			"and carries a runtime tag identifying which. Use "
			"`match` to dispatch on the tag and `is`/`as` to "
			"test or narrow it. Tagged unions are always "
			"written inside parentheses.",
	},
	operator_entry {
		name = "^",
		role = op_role::ANY,
		sig = "a ^ b",
		docs = "**Precedence: 8** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Bitwise exclusive-or on integer "
			"operands. Left-associative.",
	},
	operator_entry {
		name = "&",
		role = op_role::BINARY,
		sig = "a & b",
		docs = "**Precedence: 9** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Bitwise AND on integer operands. "
			"Left-associative. Note that this is **looser** "
			"than comparison in Hare: `a & b == c` parses as "
			"`a & (b == c)`. C's ordering is the reverse.",
	},
	operator_entry {
		name = "&",
		role = op_role::PREFIX,
		sig = "&lvalue",
		docs = "**Precedence: 13** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Address-of. Takes the address of an "
			"lvalue and yields a pointer (`*T`) to it. Binds "
			"tighter than any binary operator.",
	},

	// --- shift -------------------------------------------------

	operator_entry {
		name = "<<",
		role = op_role::ANY,
		sig = "a << b",
		docs = "**Precedence: 10** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Left shift. Shifts the bits of `a` "
			"left by `b` positions; vacated bits are zero. `b` "
			"must be a non-negative integer. Shifting by at "
			"least the bit width of `a` is undefined. "
			"Left-associative.",
	},
	operator_entry {
		name = ">>",
		role = op_role::ANY,
		sig = "a >> b",
		docs = "**Precedence: 10** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Right shift. For unsigned `a` the "
			"shift is logical (fills with zero); for signed "
			"`a` it is arithmetic (preserves the sign bit). "
			"Left-associative.",
	},

	// --- additive ----------------------------------------------

	operator_entry {
		name = "+",
		role = op_role::ANY,
		sig = "a + b",
		docs = "**Precedence: 11** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Addition on numeric operands. Hare "
			"has no unary `+`. Left-associative.",
	},
	operator_entry {
		name = "-",
		role = op_role::BINARY,
		sig = "a - b",
		docs = "**Precedence: 11** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Subtraction on numeric operands. "
			"Left-associative.",
	},
	operator_entry {
		name = "-",
		role = op_role::PREFIX,
		sig = "-a",
		docs = "**Precedence: 13** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Arithmetic negation. Binds tighter "
			"than any binary operator. On signed integers, "
			"negating the minimum representable value is "
			"undefined (the result is not representable).",
	},

	// --- multiplicative ----------------------------------------

	operator_entry {
		name = "*",
		role = op_role::BINARY,
		sig = "a * b",
		docs = "**Precedence: 12** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Multiplication on numeric "
			"operands. Left-associative.",
	},
	operator_entry {
		name = "*",
		role = op_role::PREFIX,
		sig = "*ptr",
		docs = "**Precedence: 13** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Pointer dereference. Yields the "
			"pointee. The pointer type must be non-nullable; "
			"dereferencing a nullable pointer is rejected by "
			"the type checker until it is narrowed. Binds "
			"tighter than any binary operator.",
	},
	operator_entry {
		name = "*",
		role = op_role::TYPE,
		sig = "*T",
		docs = "**Pointer type modifier.** `*T` is the type of "
			"non-nullable pointers to `T`. Combine with the "
			"`nullable` keyword for pointers that may hold "
			"`null`. Address-of (`&value`) produces a value of "
			"this type.",
	},
	operator_entry {
		name = "/",
		role = op_role::ANY,
		sig = "a / b",
		docs = "**Precedence: 12** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Division on numeric operands. "
			"Integer division truncates toward zero; integer "
			"division by zero aborts. Left-associative.",
	},
	operator_entry {
		name = "%",
		role = op_role::ANY,
		sig = "a % b",
		docs = "**Precedence: 12** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Remainder of integer division. The "
			"result has the sign of the dividend (`a`). "
			"Modulo by zero aborts. Not defined for "
			"floating-point operands; use a library routine "
			"such as `math::fmod` for that. Left-associative.",
	},

	// --- unary prefix ------------------------------------------

	operator_entry {
		name = "!",
		role = op_role::PREFIX,
		sig = "!b",
		docs = "**Precedence: 13** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Logical NOT on a `bool` operand. "
			"Binds tighter than any binary operator.",
	},
	operator_entry {
		name = "~",
		role = op_role::ANY,
		sig = "~a",
		docs = "**Precedence: 13** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Bitwise NOT (one's complement) on "
			"integer operands. Binds tighter than any binary "
			"operator.",
	},

	// --- postfix ------------------------------------------------

	operator_entry {
		name = "!",
		role = op_role::POSTFIX,
		sig = "value!",
		docs = "**Precedence: 14** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Error-assert. If `value` is a "
			"tagged union containing one or more error "
			"variants and currently holds an error, aborts; "
			"otherwise yields the non-error component. Binds "
			"tighter than any prefix or binary operator.",
	},
	operator_entry {
		name = "?",
		role = op_role::ANY,
		sig = "value?",
		docs = "**Precedence: 14** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Error-propagation. If `value` is a "
			"tagged union containing error variants and "
			"currently holds an error, returns that error "
			"from the enclosing function (which must have a "
			"matching error-tagged return type); otherwise "
			"yields the non-error component. Binds tighter "
			"than any prefix or binary operator.",
	},

	// --- assignment --------------------------------------------

	operator_entry {
		name = "=",
		role = op_role::ANY,
		sig = "lvalue = expression",
		docs = "**Precedence: 1** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Assignment. Writes `expression` to "
			"`lvalue`. Yields `void`. Right-associative. "
			"Binds looser than every value-producing "
			"operator.",
	},
	operator_entry {
		name = "+=",
		role = op_role::ANY,
		sig = "lvalue += expression",
		docs = "**Precedence: 1** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Compound assignment: `a += b` is "
			"equivalent to `a = a + b` with `a` evaluated "
			"once. Yields `void`.",
	},
	operator_entry {
		name = "-=",
		role = op_role::ANY,
		sig = "lvalue -= expression",
		docs = "**Precedence: 1** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Compound assignment: `a -= b` is "
			"equivalent to `a = a - b` with `a` evaluated "
			"once. Yields `void`.",
	},
	operator_entry {
		name = "*=",
		role = op_role::ANY,
		sig = "lvalue *= expression",
		docs = "**Precedence: 1** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Compound assignment: `a *= b` is "
			"equivalent to `a = a * b` with `a` evaluated "
			"once. Yields `void`.",
	},
	operator_entry {
		name = "/=",
		role = op_role::ANY,
		sig = "lvalue /= expression",
		docs = "**Precedence: 1** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Compound assignment: `a /= b` is "
			"equivalent to `a = a / b` with `a` evaluated "
			"once. Yields `void`.",
	},
	operator_entry {
		name = "%=",
		role = op_role::ANY,
		sig = "lvalue %= expression",
		docs = "**Precedence: 1** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Compound assignment: `a %= b` is "
			"equivalent to `a = a % b` with `a` evaluated "
			"once. Yields `void`.",
	},
	operator_entry {
		name = "&=",
		role = op_role::ANY,
		sig = "lvalue &= expression",
		docs = "**Precedence: 1** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Compound assignment with bitwise "
			"AND: `a &= b` is equivalent to `a = a & b` with "
			"`a` evaluated once. Yields `void`.",
	},
	operator_entry {
		name = "|=",
		role = op_role::ANY,
		sig = "lvalue |= expression",
		docs = "**Precedence: 1** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Compound assignment with bitwise "
			"OR: `a |= b` is equivalent to `a = a | b` with "
			"`a` evaluated once. Yields `void`.",
	},
	operator_entry {
		name = "^=",
		role = op_role::ANY,
		sig = "lvalue ^= expression",
		docs = "**Precedence: 1** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Compound assignment with bitwise "
			"XOR: `a ^= b` is equivalent to `a = a ^ b` with "
			"`a` evaluated once. Yields `void`.",
	},
	operator_entry {
		name = "&&=",
		role = op_role::ANY,
		sig = "lvalue &&= expression",
		docs = "**Precedence: 1** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Compound assignment with logical "
			"AND: `a &&= b` is equivalent to `a = a && b` "
			"with `a` evaluated once. Short-circuits in the "
			"same way as `&&`. Yields `void`.",
	},
	operator_entry {
		name = "||=",
		role = op_role::ANY,
		sig = "lvalue ||= expression",
		docs = "**Precedence: 1** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Compound assignment with logical "
			"OR: `a ||= b` is equivalent to `a = a || b` with "
			"`a` evaluated once. Short-circuits in the same "
			"way as `||`. Yields `void`.",
	},
	operator_entry {
		name = "^^=",
		role = op_role::ANY,
		sig = "lvalue ^^= expression",
		docs = "**Precedence: 1** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Compound assignment with logical "
			"XOR: `a ^^= b` is equivalent to `a = a ^^ b` "
			"with `a` evaluated once. Yields `void`.",
	},
	operator_entry {
		name = "<<=",
		role = op_role::ANY,
		sig = "lvalue <<= expression",
		docs = "**Precedence: 1** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Compound assignment with left "
			"shift: `a <<= b` is equivalent to `a = a << b` "
			"with `a` evaluated once. Yields `void`.",
	},
	operator_entry {
		name = ">>=",
		role = op_role::ANY,
		sig = "lvalue >>= expression",
		docs = "**Precedence: 1** (1 = loosest, 14 = tightest).\n\n"
			"**Operator.** Compound assignment with right "
			"shift: `a >>= b` is equivalent to `a = a >> b` "
			"with `a` evaluated once. Yields `void`.",
	},

	// --- syntactic markers -------------------------------------

	operator_entry {
		name = "..",
		role = op_role::SLICE,
		sig = "slice[start..end]\n"
			"slice[..end]\n"
			"slice[start..]\n"
			"slice[..]",
		docs = "**Slice/range separator.** Inside index brackets "
			"after a sliceable expression, produces a "
			"sub-slice covering the half-open range "
			"`[start, end)`. Either bound may be omitted: an "
			"absent `start` defaults to 0, an absent `end` "
			"defaults to the slice's length.",
	},
	operator_entry {
		name = "..",
		role = op_role::FOR_EACH_VALUE,
		sig = "for (let x .. iter) body",
		docs = "**By-value iterator binding.** In a `for` "
			"header, `let x .. iter` walks `iter` (a slice or "
			"array) and binds each element to `x` by value "
			"for the loop body. Use `&..` to iterate by "
			"pointer, or `=>` for iterator-protocol values.",
	},
	operator_entry {
		name = "...",
		role = op_role::VARIADIC_PARAM,
		sig = "fn f(name: T...) rtype = body",
		docs = "**Variadic parameter declaration.** Marks the "
			"trailing parameter as Hare-style variadic: "
			"callers may pass any number of `T` values and "
			"the callee receives them as a `[]T` slice. For "
			"C-style variadics (no preceding `T`), use the "
			"`vastart` / `vaarg` / `vaend` builtins.",
	},
	operator_entry {
		name = "...",
		role = op_role::SPREAD,
		sig = "f(slice...)",
		docs = "**Call-site spread.** Passes the elements of "
			"`slice` to the callee's variadic parameter "
			"as-is, instead of passing the slice itself as a "
			"single `[]T` value. The callee receives the same "
			"`[]T` view it would for individually-passed "
			"arguments.",
	},
	operator_entry {
		name = "...",
		role = op_role::ARRAY_EXPAND,
		sig = "[v0, v1, ..., vN...]",
		docs = "**Array-literal fill.** Repeats the last "
			"explicit value to fill the remainder of a "
			"fixed-length array. `[0...]` initialises every "
			"element to 0; `[1, 2, 3...]` sets the first "
			"three elements to 1, 2, 3 and the rest to 3.",
	},
	operator_entry {
		name = "...",
		role = op_role::STRUCT_AUTOFILL,
		sig = "Type { field = value, ... }",
		docs = "**Struct-literal autofill.** Inside a struct "
			"literal, the trailing `...` token fills every "
			"unmentioned field with its zero value. Without "
			"`...`, every field must appear in the literal.",
	},
	operator_entry {
		name = "=>",
		role = op_role::CASE_ARROW,
		sig = "case PATTERN => body;",
		docs = "**Case arrow.** Separates a `match` or `switch` "
			"case's pattern from its body. The body is a "
			"single expression (use `{ ... }` for several "
			"statements) and its type contributes to the "
			"surrounding `match`/`switch` result type.",
	},
	operator_entry {
		name = "=>",
		role = op_role::FOR_ITERATOR,
		sig = "for (let x => iter) body",
		docs = "**Iterator-protocol binding.** In a `for` "
			"header, `let x => iter` repeatedly calls "
			"`iter`'s `next`-style function (a function that "
			"returns `(T | done)` from a pointer receiver) "
			"and binds each yielded value to `x` for the "
			"loop body. The loop ends when the call yields "
			"`done`.",
	},

	// --- punctuation -------------------------------------------

	operator_entry {
		name = ".",
		role = op_role::FIELD_ACCESS,
		sig = "value.field",
		docs = "**Field access.** Selects the member named "
			"`field` from a value of struct or union type. "
			"If the value is a pointer to such a type, the "
			"access auto-dereferences: `p.x` is shorthand for "
			"`(*p).x`. The result is an lvalue when the "
			"receiver is.",
	},
	operator_entry {
		name = ".",
		role = op_role::TUPLE_INDEX,
		sig = "tuple.0\n"
			"tuple.1",
		docs = "**Tuple positional access.** Selects the "
			"zero-based positional member of a tuple value. "
			"The index must be a decimal integer literal; "
			"`tup.0` is the first element, `tup.1` the "
			"second, and so on. Yields an lvalue when the "
			"tuple is.",
	},
	operator_entry {
		name = "::",
		role = op_role::ANY,
		sig = "module::name\n"
			"module::submodule::name",
		docs = "**Module path separator.** Joins identifiers "
			"along a module path: `bufio::scanner` names the "
			"`scanner` symbol in module `bufio`. Module paths "
			"are introduced by `use` declarations at the top "
			"of the file.",
	},
	operator_entry {
		name = "{",
		role = op_role::FUNC_BODY,
		sig = "fn name(params) rtype = { body }",
		docs = "**Function body opener.** Begins the function's "
			"single expression body (a compound expression). "
			"The function returns the value the body yields "
			"(by reaching its last expression or an explicit "
			"`yield`), or `void` if it doesn't yield. A "
			"`return value;` statement anywhere inside "
			"exits the function early with that value, "
			"running pending `defer`red expressions on the "
			"way out.",
	},
	operator_entry {
		name = "{",
		role = op_role::COMPOUND_BLOCK,
		sig = "{ expr1; expr2; ... }",
		docs = "**Compound expression opener.** Begins a "
			"sequence of expressions that share a scope and "
			"execute in order. The compound expression "
			"yields the value of its last expression unless "
			"an earlier `yield` produced one. Optionally "
			"prefixed with a `:label` so inner `break` / "
			"`continue` / `yield` can target it.",
	},
	operator_entry {
		name = "{",
		role = op_role::STRUCT_BODY,
		sig = "struct { field: type, ... }\n"
			"struct @packed { field: type, ... }",
		docs = "**Struct type body opener.** Begins the field "
			"list of a `struct` type. Each field is "
			"`name: type` separated by commas; fields are "
			"laid out sequentially. With `@packed`, padding "
			"between fields is removed.",
	},
	operator_entry {
		name = "{",
		role = op_role::UNION_BODY,
		sig = "union { field: type, ... }",
		docs = "**Union type body opener.** Begins the field "
			"list of a `union` type. All fields share the "
			"same storage and the active field is not "
			"tracked at runtime. For a discriminated "
			"alternative, use a tagged union "
			"(`(a | b | ...)`).",
	},
	operator_entry {
		name = "{",
		role = op_role::ENUM_BODY,
		sig = "enum [base_type] { NAME, NAME = value, ... }",
		docs = "**Enum body opener.** Begins the list of "
			"enumerators for an `enum` type. Each entry is a "
			"name optionally followed by `= value`; "
			"unspecified entries take the previous value "
			"plus one (starting at 0).",
	},
	operator_entry {
		name = "{",
		role = op_role::MATCH_BODY,
		sig = "match (value) { case ... => ...; ... }",
		docs = "**Match body opener.** Begins the list of "
			"`case` arms for a `match` expression. Each arm "
			"narrows the tagged-union or nullable-pointer "
			"value to one of its variants; an empty `case` "
			"is the default.",
	},
	operator_entry {
		name = "{",
		role = op_role::SWITCH_BODY,
		sig = "switch (value) { case ... => ...; ... }",
		docs = "**Switch body opener.** Begins the list of "
			"`case` arms for a `switch` expression. Each arm "
			"matches one or more compile-time-constant "
			"values; an empty `case` is the default.",
	},
	operator_entry {
		name = "{",
		role = op_role::STRUCT_LITERAL,
		sig = "Type { field = value, field = value, ... }",
		docs = "**Struct literal opener.** Begins the "
			"field-value list of a struct or union literal "
			"of the named type. Each entry is "
			"`field = expr`; a trailing `...` autofills "
			"unmentioned fields with their zero value.",
	},
	operator_entry {
		name = "}",
		role = op_role::FUNC_BODY,
		sig = "fn name(params) rtype = { body }",
		docs = "**Function body closer.** Closes the function's "
			"body. The value of the last expression (or an "
			"explicit `yield`) becomes the function's "
			"return value; alternatively, an earlier "
			"`return value;` exits the function with that "
			"value. Pending `defer`red expressions run "
			"before control leaves.",
	},
	operator_entry {
		name = "}",
		role = op_role::COMPOUND_BLOCK,
		sig = "{ expr1; expr2; ... }",
		docs = "**Compound expression closer.** Closes a "
			"compound expression and yields its result "
			"value: either an explicit `yield`'s value or "
			"the value of the last expression. Scoped "
			"bindings declared inside go out of scope; "
			"`defer`red expressions run.",
	},
	operator_entry {
		name = "}",
		role = op_role::STRUCT_BODY,
		sig = "struct { field: type, ... }",
		docs = "**Struct type body closer.** Closes the field "
			"list of a `struct` type.",
	},
	operator_entry {
		name = "}",
		role = op_role::UNION_BODY,
		sig = "union { field: type, ... }",
		docs = "**Union type body closer.** Closes the field "
			"list of a `union` type.",
	},
	operator_entry {
		name = "}",
		role = op_role::ENUM_BODY,
		sig = "enum [base_type] { NAME, ... }",
		docs = "**Enum body closer.** Closes the list of "
			"enumerators for an `enum` type.",
	},
	operator_entry {
		name = "}",
		role = op_role::MATCH_BODY,
		sig = "match (value) { case ... }",
		docs = "**Match body closer.** Closes the list of "
			"`case` arms for a `match` expression.",
	},
	operator_entry {
		name = "}",
		role = op_role::SWITCH_BODY,
		sig = "switch (value) { case ... }",
		docs = "**Switch body closer.** Closes the list of "
			"`case` arms for a `switch` expression.",
	},
	operator_entry {
		name = "}",
		role = op_role::STRUCT_LITERAL,
		sig = "Type { field = value, ... }",
		docs = "**Struct literal closer.** Closes the "
			"field-value list of a struct or union literal.",
	},
	operator_entry {
		name = "[",
		role = op_role::INDEX_SLICE,
		sig = "value[index]\n"
			"value[start..end]\n"
			"value[..end]\n"
			"value[start..]\n"
			"value[..]",
		docs = "**Index / slice opener.** Following an "
			"array, slice, or string value, opens an index "
			"or sub-slice selector. A single expression "
			"yields the element at that index (an lvalue if "
			"the receiver is). A `..` between two optional "
			"bounds yields a sub-slice over the half-open "
			"range; absent bounds default to 0 and the "
			"length.",
	},
	operator_entry {
		name = "[",
		role = op_role::ARRAY_TYPE,
		sig = "[N]T          // fixed-length array of N elements\n"
			"[_]T          // length inferred from initializer\n"
			"[*]T          // unbounded array (FFI)",
		docs = "**Array type opener.** Introduces the length "
			"component of an array type. The element type "
			"`T` follows the closing `]`. `[N]T` is a "
			"fixed-length array of `N` elements; `[_]T` "
			"lets the compiler infer `N` from the "
			"initializer; `[*]T` is an unbounded-length "
			"array, used for FFI. For a length-carrying "
			"slice, see the empty-bracket form `[]T`.",
	},
	operator_entry {
		name = "[",
		role = op_role::SLICE_TYPE,
		sig = "[]T",
		docs = "**Slice type opener.** Introduces a slice "
			"type. A `[]T` value is a length-carrying view "
			"over a contiguous run of `T` elements: "
			"internally a pointer + length (+ capacity). "
			"Slices can be sub-sliced with `value[i..j]`, "
			"indexed with `value[i]`, grown with `append`, "
			"and freed with `free`.",
	},
	operator_entry {
		name = "[",
		role = op_role::ARRAY_LITERAL,
		sig = "[v0, v1, v2]\n"
			"[v0, v1, v2...]      // fill remainder with last\n"
			"[0...]                // fill all with 0",
		docs = "**Array literal opener.** Begins a "
			"fixed-length array literal. Entries are "
			"separated by commas; a trailing `...` after "
			"the final entry repeats that entry to fill the "
			"declared length.",
	},
	operator_entry {
		name = "]",
		role = op_role::INDEX_SLICE,
		sig = "value[index]\n"
			"value[start..end]",
		docs = "**Index / slice closer.** Closes an index or "
			"sub-slice selector opened by `[`.",
	},
	operator_entry {
		name = "]",
		role = op_role::ARRAY_TYPE,
		sig = "[N]T   [*]T   [_]T",
		docs = "**Array type closer.** Closes the length "
			"component of an array type. The element type "
			"follows immediately after.",
	},
	operator_entry {
		name = "]",
		role = op_role::SLICE_TYPE,
		sig = "[]T",
		docs = "**Slice type closer.** Closes the empty "
			"`[]` of a slice type. The element type "
			"follows immediately after.",
	},
	operator_entry {
		name = "]",
		role = op_role::ARRAY_LITERAL,
		sig = "[v0, v1, v2]",
		docs = "**Array literal closer.** Closes a "
			"fixed-length array literal opened by `[`.",
	},
	operator_entry {
		name = "(",
		role = op_role::IF_HEADER,
		sig = "if (condition) then-expr\n"
			"if (condition) then-expr else else-expr",
		docs = "**`if` condition opener.** Wraps the boolean "
			"condition of an `if` expression. The condition "
			"must be `bool`. The matching `)` is followed by "
			"the then-branch expression.",
	},
	operator_entry {
		name = "(",
		role = op_role::FOR_HEADER,
		sig = "for (cond) body\n"
			"for (init; cond; afterthought) body\n"
			"for (let x .. iter) body\n"
			"for (let x => iter) body",
		docs = "**`for` header opener.** Wraps the loop's "
			"control header. The C-style three-clause form "
			"uses `;` to separate init/cond/afterthought; "
			"the iterator forms use `..` (by value) or `=>` "
			"(by iterator-protocol value), and `let x &.. "
			"iter` for by-pointer iteration.",
	},
	operator_entry {
		name = "(",
		role = op_role::MATCH_HEADER,
		sig = "match (value) { case ... }",
		docs = "**`match` value opener.** Wraps the value being "
			"pattern-matched. The matching `)` is followed "
			"by the `{ ... }` body containing `case` arms.",
	},
	operator_entry {
		name = "(",
		role = op_role::SWITCH_HEADER,
		sig = "switch (value) { case CONST => ...; ... }",
		docs = "**`switch` value opener.** Wraps the value "
			"being switched on. The matching `)` is followed "
			"by the `{ ... }` body containing `case` arms.",
	},
	operator_entry {
		name = "(",
		role = op_role::CALL,
		sig = "f(arg, arg, ...)",
		docs = "**Call argument list opener.** Begins the "
			"argument list for a function call. Built-ins "
			"like `len`, `alloc`, `assert`, and `align` use "
			"the same syntax. To spread a slice into a "
			"variadic parameter, write `slice...` as the "
			"last argument.",
	},
	operator_entry {
		name = "(",
		role = op_role::PARAM_LIST,
		sig = "fn name(param: type, ...) rtype = body",
		docs = "**Function parameter list opener.** Begins the "
			"parameter list of a function declaration. Each "
			"parameter is `name: type`; a trailing "
			"`name: T...` declares the function as "
			"Hare-style variadic and passes the rest as "
			"`[]T`. A trailing `...` with no preceding type "
			"declares C-style variadics (paired with "
			"`vastart`/`vaarg`/`vaend`).",
	},
	operator_entry {
		name = "(",
		role = op_role::TYPE_PARENS,
		sig = "(int | str | void)   // tagged union\n"
			"(int, str)            // tuple type",
		docs = "**Type-grouping opener.** In a type position, "
			"`(...)` groups multiple types into either a "
			"**tagged union** (members separated by `|`, "
			"holding exactly one of the variants at a time) "
			"or a **tuple type** (members separated by `,`, "
			"holding all of them positionally). Use `match` "
			"or `is`/`as` to dispatch on a tagged union; "
			"`tuple.0`, `tuple.1`, ... to access tuple "
			"members.",
	},
	operator_entry {
		name = "(",
		role = op_role::EXPR_PARENS,
		sig = "(expr)            // grouping\n"
			"(a, b, c)         // tuple value",
		docs = "**Expression-grouping opener.** Wraps a "
			"value expression to override operator "
			"precedence (`(a + b) * c`), or begins a tuple "
			"value when the contents are comma-separated "
			"(`(1, 2)`).",
	},
	operator_entry {
		name = ")",
		role = op_role::IF_HEADER,
		sig = "if (condition) then-expr",
		docs = "**`if` condition closer.** Closes the boolean "
			"condition opened by `(`; the then-branch "
			"expression follows.",
	},
	operator_entry {
		name = ")",
		role = op_role::FOR_HEADER,
		sig = "for (...) body",
		docs = "**`for` header closer.** Closes the loop's "
			"control header; the body expression follows.",
	},
	operator_entry {
		name = ")",
		role = op_role::MATCH_HEADER,
		sig = "match (value) { case ... }",
		docs = "**`match` value closer.** Closes the matched "
			"value; the `{ ... }` body of `case` arms "
			"follows.",
	},
	operator_entry {
		name = ")",
		role = op_role::SWITCH_HEADER,
		sig = "switch (value) { case ... }",
		docs = "**`switch` value closer.** Closes the switched "
			"value; the `{ ... }` body of `case` arms "
			"follows.",
	},
	operator_entry {
		name = ")",
		role = op_role::CALL,
		sig = "f(arg, arg, ...)",
		docs = "**Call argument list closer.** Closes the "
			"argument list of a function call.",
	},
	operator_entry {
		name = ")",
		role = op_role::PARAM_LIST,
		sig = "fn name(param: type, ...) rtype = body",
		docs = "**Function parameter list closer.** Closes the "
			"parameter list of a function declaration; the "
			"return type follows.",
	},
	operator_entry {
		name = ")",
		role = op_role::TYPE_PARENS,
		sig = "(int | str | void)   // tagged union\n"
			"(int, str)            // tuple type",
		docs = "**Type-grouping closer.** Closes a tagged "
			"union or tuple type opened by `(`.",
	},
	operator_entry {
		name = ")",
		role = op_role::EXPR_PARENS,
		sig = "(expr)            // grouping\n"
			"(a, b, c)         // tuple value",
		docs = "**Expression-grouping closer.** Closes a "
			"grouped expression or tuple value opened by "
			"`(`.",
	},
	operator_entry {
		name = ";",
		role = op_role::TERMINATOR,
		sig = "expr;\n"
			"let x = 1;\n"
			"use bufio;",
		docs = "**Statement terminator.** Ends a declaration "
			"(at file scope) or an expression-statement "
			"(inside a compound expression). Compound "
			"expressions yield the value of their last "
			"expression, but trailing `;` after that final "
			"expression is permitted (and required for "
			"`void`-yielding statements).",
	},
	operator_entry {
		name = ";",
		role = op_role::FOR_HEADER,
		sig = "for (init; cond; afterthought) body",
		docs = "**`for` header separator.** Inside a `for` "
			"header's three-clause form, separates the "
			"init clause from the loop condition, and the "
			"condition from the afterthought.",
	},
	operator_entry {
		name = ",",
		role = op_role::CALL,
		sig = "f(arg, arg, arg)",
		docs = "**Argument separator.** Separates arguments in "
			"a function call.",
	},
	operator_entry {
		name = ",",
		role = op_role::PARAM_LIST,
		sig = "fn f(p: T, q: T) rtype = body",
		docs = "**Parameter separator.** Separates parameters "
			"in a function declaration.",
	},
	operator_entry {
		name = ",",
		role = op_role::TYPE_PARENS,
		sig = "(int, str, bool)",
		docs = "**Tuple-type member separator.** Separates "
			"member types of a tuple type. (For tagged "
			"unions, members are separated with `|`, not "
			"`,`.)",
	},
	operator_entry {
		name = ",",
		role = op_role::EXPR_PARENS,
		sig = "(1, 2, 3)",
		docs = "**Tuple value separator.** Separates values "
			"of a tuple value. Access tuple members by "
			"position with `tuple.0`, `tuple.1`, ...",
	},
	operator_entry {
		name = ",",
		role = op_role::FOR_HEADER,
		sig = "for (let a = 0, b = 0; cond; aft) body",
		docs = "**Multi-binding separator.** Inside a `for` "
			"header's init clause, separates additional "
			"bindings declared by the same `let`.",
	},
	operator_entry {
		name = ",",
		role = op_role::ARRAY_LITERAL,
		sig = "[v0, v1, v2]",
		docs = "**Array element separator.** Separates "
			"elements in an array literal.",
	},
	operator_entry {
		name = ",",
		role = op_role::STRUCT_BODY,
		sig = "struct { a: int, b: int }",
		docs = "**Struct field separator.** Separates field "
			"declarations in a `struct` type body.",
	},
	operator_entry {
		name = ",",
		role = op_role::UNION_BODY,
		sig = "union { a: int, b: int }",
		docs = "**Union field separator.** Separates field "
			"declarations in a `union` type body.",
	},
	operator_entry {
		name = ",",
		role = op_role::ENUM_BODY,
		sig = "enum { A, B, C }\n"
			"enum int { A = 1, B = 2 }",
		docs = "**Enum value separator.** Separates "
			"enumerators in an `enum` type body.",
	},
	operator_entry {
		name = ",",
		role = op_role::STRUCT_LITERAL,
		sig = "Type { a = 1, b = 2 }",
		docs = "**Struct field-init separator.** Separates "
			"field-value initializers in a struct or union "
			"literal.",
	},
	operator_entry {
		name = ",",
		role = op_role::MATCH_BODY,
		sig = "case A, B => body;",
		docs = "**Match case-pattern separator.** Inside a "
			"`match` body, separates type or value patterns "
			"in a single `case` arm so the same body runs "
			"for any of them.",
	},
	operator_entry {
		name = ",",
		role = op_role::SWITCH_BODY,
		sig = "case CONST_A, CONST_B => body;",
		docs = "**Switch case-pattern separator.** Inside a "
			"`switch` body, separates compile-time-constant "
			"values in a single `case` arm so the same body "
			"runs for any of them.",
	},
	operator_entry {
		name = ",",
		role = op_role::ANY,
		sig = "type a = T1, b = T2;\n"
			"let a = 1, b = 2;",
		docs = "**Multi-declaration separator.** Separates "
			"additional bindings declared by the same `let`, "
			"`const`, `def`, or `type` keyword.",
	},
	operator_entry {
		name = ":",
		role = op_role::TYPE,
		sig = "let name: type = value\n"
			"fn f(p: type) rtype = body\n"
			"struct { field: type }\n"
			"case let v: type => body",
		docs = "**Type annotation.** Attaches a type to a `let`, "
			"`const`, or `def` binding; a function parameter; "
			"a `struct` or `union` field; an `enum`'s "
			"underlying integer type; or a `case let name: "
			"type =>` match-case binding.",
	},
	operator_entry {
		name = ":",
		role = op_role::BINARY,
		sig = "value: type",
		docs = "**Cast expression.** Converts `value` to `type`. "
			"Yields a value of `type`. Used for numeric "
			"conversions and pointer-type adjustments. The "
			"compiler rejects conversions that cannot be "
			"performed losslessly at runtime.",
	},
	operator_entry {
		name = ":",
		role = op_role::LABEL,
		sig = "for :name (cond) body\n"
			"break :name\n"
			"continue :name\n"
			"yield :name, value",
		docs = "**Label prefix.** Names a `for` loop, `match`, "
			"`switch`, or compound expression so it can be "
			"targeted by `break :name`, `continue :name`, or "
			"`yield :name, value` from inside a nested "
			"construct.",
	},
];
