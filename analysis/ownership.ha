// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Ownership inference data types and Layer-1 (user annotation) parser.
//
// The LSP shows a "borrowed" or "owned" line on hover when it can decide.
// Three layers feed into that decision:
//
//   1. user annotations in the decl's doc comment, parsed at runtime
//      (annotations_from_docs, param_annotations_from_docs in this file).
//   2. stdlib doc-comment facts looked up from a committed table that an
//      offline agent maintains (stdlib_ownership_data.ha; queried via
//      lookup_stdlib_fact below).
//   3. heuristic walks of the expression at the cursor (in server/).
//
// The LSP runtime itself does no natural-language matching. Layer 2's
// data file is regenerated offline by an agent following
// .claude/stdlib-ownership-scan.md.

use strings;

// Ownership classification for a pointer/slice/str value.
export type ownership = enum {
	UNKNOWN,
	OWNED,
	BORROWED,
};

// Which inference layer determined the ownership.
export type ownership_source = enum {
	NONE,
	ANNOTATION,
	DOC_COMMENT,
	HEURISTIC,
};

// A resolved ownership fact plus the trailer to render alongside it.
// Caller owns `detail`.
export type ownership_fact = struct {
	kind: ownership,
	source: ownership_source,
	detail: str,
};

// Returns the no-signal fact.
export fn empty_ownership_fact() ownership_fact = ownership_fact {
	kind = ownership::UNKNOWN,
	source = ownership_source::NONE,
	detail = "",
};

// Releases memory owned by a fact.
export fn finish_ownership_fact(f: *ownership_fact) void = {
	free(f.detail);
	f.detail = "";
};

// Returns a deep copy of the fact (detail is freshly allocated).
export fn dup_ownership_fact(f: ownership_fact) ownership_fact = {
	return ownership_fact {
		kind = f.kind,
		source = f.source,
		detail = strings::dup(f.detail)!,
	};
};

// Scans the decl's docs for Layer-1 user annotations.
//
// On a function (`is_function = true`):
//   `@returns: owned`               -> owned
//   `@returns: borrowed`            -> borrowed
//   `@returns: borrowed from <name>` -> borrowed, named source
//   bare `@owned` / `@borrowed`     -> IGNORED. The user must write
//                                       `@returns:` to disambiguate.
//
// On a non-function (`is_function = false`; global, const, let binding):
//   `@owned` / `@borrowed`          -> applies to the value the decl holds.
//
// Returns `empty_ownership_fact()` if no tag matches. The first matching
// line wins.
export fn annotations_from_docs(docs: str, is_function: bool) ownership_fact = {
	if (len(docs) == 0) return empty_ownership_fact();
	const lines = strings::split(docs, "\n")!;
	defer free(lines);
	for (let i = 0z; i < len(lines); i += 1) {
		const line = trim_leading_space(lines[i]);
		if (is_function) {
			match (parse_returns_tag(line)) {
			case let f: ownership_fact =>
				return f;
			case void => void;
			};
		} else {
			match (parse_bare_owner_tag(line)) {
			case let f: ownership_fact =>
				return f;
			case void => void;
			};
		};
	};
	return empty_ownership_fact();
};

// Returns parallel per-parameter slices: ownership kind and a freshly
// allocated detail string (`"annotation"` when the param had a tag, ""
// otherwise). Both slices have the same length as `names`. Caller frees.
export fn param_annotations_from_docs(
	docs: str,
	names: []str,
) ([]ownership, []str) = {
	let kinds: []ownership = [];
	let details: []str = [];
	for (let i = 0z; i < len(names); i += 1) {
		append(kinds, ownership::UNKNOWN)!;
		append(details, strings::dup("")!)!;
	};
	if (len(docs) == 0) return (kinds, details);
	const lines = strings::split(docs, "\n")!;
	defer free(lines);
	for (let i = 0z; i < len(lines); i += 1) {
		const line = trim_leading_space(lines[i]);
		match (parse_param_tag(line)) {
		case let pt: (str, ownership) =>
			for (let j = 0z; j < len(names); j += 1) {
				if (names[j] == pt.0) {
					kinds[j] = pt.1;
					free(details[j]);
					details[j] = strings::dup("annotation")!;
					break;
				};
			};
		case void => void;
		};
	};
	return (kinds, details);
};

// Composes Layers 1 and 2: tries the decl's user annotations first, falls
// back to the stdlib doc-comment table keyed by (module, short_name).
// Returns `empty_ownership_fact()` when neither layer fires. Caller frees
// the returned fact's `detail`. Used at hover time for symbols resolved
// via `workspace_entry`, which don't carry cached ownership fields.
export fn compute_ownership_for(
	docs: str,
	is_function: bool,
	module: str,
	short_name: str,
) ownership_fact = {
	let fact = annotations_from_docs(docs, is_function);
	if (fact.source != ownership_source::NONE) return fact;
	match (lookup_stdlib_fact(module, short_name)) {
	case let f: ownership_fact =>
		return f;
	case void => void;
	};
	return fact;
};

// Looks up a stdlib symbol's Layer-2 ownership fact, if the offline scan
// found one. Caller frees the returned fact's `detail`.
export fn lookup_stdlib_fact(
	module: str,
	short_name: str,
) (ownership_fact | void) = {
	for (let i = 0z; i < len(STDLIB_OWNERSHIP_TABLE); i += 1) {
		const e = &STDLIB_OWNERSHIP_TABLE[i];
		if (e.module == module && e.short_name == short_name) {
			return ownership_fact {
				kind = e.kind,
				source = ownership_source::DOC_COMMENT,
				detail = strings::dup(e.detail)!,
			};
		};
	};
	return void;
};

// Returns `s` with any leading ASCII whitespace stripped. The returned
// slice is borrowed from `s`; do not free.
fn trim_leading_space(line: str) str = {
	let s = line;
	for (true) {
		if (len(s) == 0) break;
		const b = strings::toutf8(s);
		if (b[0] != ' ': u8 && b[0] != '\t': u8) break;
		s = strings::sub(s, 1, strings::end);
	};
	return s;
};

// Parses `@returns: owned`, `@returns: borrowed`, or
// `@returns: borrowed from <name>`. Returns void on no match.
fn parse_returns_tag(line: str) (ownership_fact | void) = {
	const prefix = "@returns:";
	if (!strings::hasprefix(line, prefix)) return void;
	let rest = strings::sub(line, len(prefix), strings::end);
	rest = trim_leading_space(rest);
	if (strings::hasprefix(rest, "owned")) {
		return ownership_fact {
			kind = ownership::OWNED,
			source = ownership_source::ANNOTATION,
			detail = strings::dup("annotation")!,
		};
	};
	if (strings::hasprefix(rest, "borrowed")) {
		let after = strings::sub(rest, len("borrowed"), strings::end);
		after = trim_leading_space(after);
		if (strings::hasprefix(after, "from")) {
			let tail = strings::sub(after, len("from"), strings::end);
			tail = trim_leading_space(tail);
			const word = first_word(tail);
			defer free(word);
			let buf: str = strings::dup("annotation: borrowed from `")!;
			const a = strings::concat(buf, word)!;
			free(buf);
			const b = strings::concat(a, "`")!;
			free(a);
			return ownership_fact {
				kind = ownership::BORROWED,
				source = ownership_source::ANNOTATION,
				detail = b,
			};
		};
		return ownership_fact {
			kind = ownership::BORROWED,
			source = ownership_source::ANNOTATION,
			detail = strings::dup("annotation")!,
		};
	};
	return void;
};

// Parses bare `@owned` / `@borrowed` lines for non-function decls.
// Trailing whitespace is tolerated.
fn parse_bare_owner_tag(line: str) (ownership_fact | void) = {
	const trimmed = first_word(line);
	defer free(trimmed);
	if (trimmed == "@owned") {
		return ownership_fact {
			kind = ownership::OWNED,
			source = ownership_source::ANNOTATION,
			detail = strings::dup("annotation")!,
		};
	};
	if (trimmed == "@borrowed") {
		return ownership_fact {
			kind = ownership::BORROWED,
			source = ownership_source::ANNOTATION,
			detail = strings::dup("annotation")!,
		};
	};
	return void;
};

// Parses `@param <name>: owned|borrowed`. Returns (name, kind) or void.
// The returned name is borrowed from `line`.
fn parse_param_tag(line: str) ((str, ownership) | void) = {
	const prefix = "@param ";
	if (!strings::hasprefix(line, prefix)) return void;
	let rest = strings::sub(line, len(prefix), strings::end);
	rest = trim_leading_space(rest);
	const colon = match (strings::index(rest, ":")) {
	case let i: size =>
		yield i;
	case void =>
		return void;
	};
	const name_raw = strings::sub(rest, 0, colon);
	const name = trim_trailing_space(name_raw);
	let val = strings::sub(rest, colon + 1, strings::end);
	val = trim_leading_space(val);
	const val_word_owned = first_word(val);
	defer free(val_word_owned);
	if (val_word_owned == "owned") return (name, ownership::OWNED);
	if (val_word_owned == "borrowed") return (name, ownership::BORROWED);
	return void;
};

// Returns the first whitespace/punctuation-bounded word from `s`, freshly
// allocated.
fn first_word(s: str) str = {
	const bytes = strings::toutf8(s);
	let end = 0z;
	for (end < len(bytes); end += 1) {
		const b = bytes[end];
		if (b == ' ': u8 || b == '\t': u8 || b == '\n': u8 || b == '\r': u8 ||
				b == '.': u8 ||
				b == ',': u8 ||
				b == ';': u8 ||
				b == '\'': u8 ||
				b == '"': u8 ||
				b == '`': u8) break;
	};
	return strings::dup(strings::sub(s, 0, end))!;
};

// Returns `s` with trailing ASCII whitespace stripped. Borrowed from `s`.
fn trim_trailing_space(s: str) str = {
	const bytes = strings::toutf8(s);
	let end = len(bytes);
	for (end > 0) {
		const b = bytes[end - 1];
		if (b != ' ': u8 && b != '\t': u8) break;
		end -= 1;
	};
	return strings::sub(s, 0, end);
};
