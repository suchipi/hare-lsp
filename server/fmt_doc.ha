// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Pretty-printer IR ("doc") and renderer for the comment-preserving
// formatter. Implements the standard Wadler-style fit-or-break
// algorithm: each `group` tries to render its contents in flat mode
// (single line, softlines render as their flat text); if the flat
// rendering would exceed the configured max column, the group falls
// back to broken mode (softlines render as a newline + indent).
//
// The IR is intentionally minimal — Hare's formatting rules are
// expressed at the higher level (fmt_build.ha) by composing these
// primitives. This module knows nothing about Hare syntax.

use io;
use memio;
use strings;

// Doc variants.
//
// Strings on `doc_text`, `doc_line.flat`, and `doc_comment.text` are
// OWNED by the doc and freed via `finish`. Use `text()`, `line()`, and
// `comment()` constructors to allocate-and-dup.

// Literal text that always renders the same.
export type doc_text = struct { content: str };

// Softline: renders as `flat` in flat mode and as `\n` + indent in
// broken mode. Common choices for `flat`: " " for "space when flat",
// "" for "nothing when flat".
export type doc_line = struct { flat: str };

// Hard line: always renders as a newline + indent. Forces any
// enclosing group into broken mode.
export type doc_hardline = struct { tag: u8 };

// A group: renders all contents in flat mode if width fits, broken
// otherwise. Groups can nest — each is decided independently based on
// the remaining columns at its render position.
export type doc_group = struct { items: []doc };

// Increase the indent by `delta` levels while rendering `inner`.
export type doc_nest = struct { delta: i32, inner: *doc };

// Sequence concatenation. Unlike `doc_group`, it never changes mode.
export type doc_concat = struct { items: []doc };

// A line comment, e.g. "foo bar" rendered as "// foo bar". Always
// forces enclosing groups into broken mode (because trailing tokens
// after a comment must move to the next line).
export type doc_comment = struct { text: str };

export type doc = (doc_text | doc_line | doc_hardline | doc_group |
	doc_nest | doc_concat | doc_comment);

// Constructors. Each dup's any input strings so the caller doesn't
// have to worry about ownership.

export fn text(s: str) doc = doc_text { content = strings::dup(s)! };

export fn line(flat: str) doc = doc_line { flat = strings::dup(flat)! };

export fn hardline() doc = doc_hardline { tag = 0 };

export fn group(items: []doc) doc = doc_group { items = items };

export fn nest(delta: i32, inner: doc) doc = doc_nest {
	delta = delta,
	inner = alloc(inner)!,
};

export fn concat(items: []doc) doc = doc_concat { items = items };

export fn comment(text: str) doc = doc_comment { text = strings::dup(text)! };

// Frees all memory owned by `d` (recursively).
export fn doc_finish(d: *doc) void = {
	match (*d) {
	case let t: doc_text =>
		free(t.content);
	case let l: doc_line =>
		free(l.flat);
	case doc_hardline => void;
	case let g: doc_group =>
		for (let i = 0z; i < len(g.items); i += 1) {
			doc_finish(&g.items[i]);
		};
		free(g.items);
	case let n: doc_nest =>
		doc_finish(n.inner);
		free(n.inner);
	case let c: doc_concat =>
		for (let i = 0z; i < len(c.items); i += 1) {
			doc_finish(&c.items[i]);
		};
		free(c.items);
	case let cm: doc_comment =>
		free(cm.text);
	};
};

// Render mode selected by an enclosing group.
type render_mode = enum { FLAT, BROKEN };

// Returns true if `d` can be rendered flat at all — i.e. it contains
// no doc_hardline or doc_comment, both of which always force a break.
fn fits_flat(d: *doc) bool = {
	match (*d) {
	case doc_text => return true;
	case doc_line => return true;
	case doc_hardline => return false;
	case doc_comment => return false;
	case let g: doc_group =>
		for (let i = 0z; i < len(g.items); i += 1) {
			if (!fits_flat(&g.items[i])) return false;
		};
		return true;
	case let n: doc_nest =>
		return fits_flat(n.inner);
	case let c: doc_concat =>
		for (let i = 0z; i < len(c.items); i += 1) {
			if (!fits_flat(&c.items[i])) return false;
		};
		return true;
	};
};

// Flat width of `d` (assuming flat mode throughout). Used by groups
// to decide whether to break. Returns SIZE_MAX if any subdoc forces a
// break (hardline / comment).
const WIDTH_INFINITY: size = ~0z; // size's max value

fn flat_width(d: *doc) size = {
	match (*d) {
	case let t: doc_text =>
		return len(t.content);
	case let l: doc_line =>
		return len(l.flat);
	case doc_hardline =>
		return WIDTH_INFINITY;
	case doc_comment =>
		return WIDTH_INFINITY;
	case let g: doc_group =>
		return sum_flat_width(g.items);
	case let n: doc_nest =>
		return flat_width(n.inner);
	case let c: doc_concat =>
		return sum_flat_width(c.items);
	};
};

fn sum_flat_width(items: []doc) size = {
	let total = 0z;
	for (let i = 0z; i < len(items); i += 1) {
		const w = flat_width(&items[i]);
		if (w == WIDTH_INFINITY) return WIDTH_INFINITY;
		// Saturating add — refuse to overflow.
		if (total > WIDTH_INFINITY - w) return WIDTH_INFINITY;
		total += w;
	};
	return total;
};

// Renders `d` to `out`. `max_col` is the soft column limit; `indent`
// is the starting indent level (one indent unit = one tab character
// emitted; tab-vs-space expansion happens in apply_indent_style
// after the pretty-printer returns).
export fn pretty(
	out: io::handle,
	d: *doc,
	max_col: size,
	indent: i32,
) (size | io::error) = {
	let cur_col = 0z;
	let written = 0z;
	render(out, d, render_mode::BROKEN, max_col, indent, &cur_col, &written)?;
	return written;
};

fn render(
	out: io::handle,
	d: *doc,
	mode: render_mode,
	max_col: size,
	indent: i32,
	cur_col: *size,
	written: *size,
) (void | io::error) = {
	match (*d) {
	case let t: doc_text =>
		emit_str(out, t.content, cur_col, written)?;
	case let l: doc_line =>
		switch (mode) {
		case render_mode::FLAT =>
			emit_str(out, l.flat, cur_col, written)?;
		case render_mode::BROKEN =>
			emit_break(out, indent, cur_col, written)?;
		};
	case doc_hardline =>
		emit_break(out, indent, cur_col, written)?;
	case let g: doc_group =>
		// Decide flat-or-broken based on remaining columns.
		const remaining = if (*cur_col >= max_col) 0z
			else max_col - *cur_col;
		const w = sum_flat_width(g.items);
		const child_mode = if (w <= remaining && fits_all(g.items))
			render_mode::FLAT
		else
			render_mode::BROKEN;
		for (let i = 0z; i < len(g.items); i += 1) {
			render(out, &g.items[i], child_mode, max_col, indent,
				cur_col, written)?;
		};
	case let n: doc_nest =>
		render(out, n.inner, mode, max_col, indent + n.delta,
			cur_col, written)?;
	case let c: doc_concat =>
		for (let i = 0z; i < len(c.items); i += 1) {
			render(out, &c.items[i], mode, max_col, indent,
				cur_col, written)?;
		};
	case let cm: doc_comment =>
		// Comments always start with "// " and end at a hard break.
		emit_str(out, "// ", cur_col, written)?;
		emit_str(out, cm.text, cur_col, written)?;
		emit_break(out, indent, cur_col, written)?;
	};
};

fn fits_all(items: []doc) bool = {
	for (let i = 0z; i < len(items); i += 1) {
		if (!fits_flat(&items[i])) return false;
	};
	return true;
};

fn emit_str(
	out: io::handle,
	s: str,
	cur_col: *size,
	written: *size,
) (void | io::error) = {
	const bytes = strings::toutf8(s);
	const n = io::writeall(out, bytes)?;
	*written += n;
	// Track column position. Newlines in raw text (allowed in
	// doc_text for embedded raw strings, etc.) reset the column.
	for (let i = 0z; i < len(bytes); i += 1) {
		if (bytes[i] == '\n': u8) {
			*cur_col = 0z;
		} else {
			*cur_col += 1;
		};
	};
};

fn emit_break(
	out: io::handle,
	indent: i32,
	cur_col: *size,
	written: *size,
) (void | io::error) = {
	const nl = strings::toutf8("\n");
	*written += io::writeall(out, nl)?;
	for (let i: i32 = 0; i < indent; i += 1) {
		*written += io::writeall(out, strings::toutf8("\t"))?;
	};
	*cur_col = if (indent < 0) 0z else indent: size;
};

// Convenience: pretty-print to a freshly-allocated string. Caller
// frees.
export fn pretty_str(d: *doc, max_col: size, indent: i32) (str | io::error) = {
	let buf = memio::dynamic();
	defer io::close(&buf)!;
	pretty(&buf, d, max_col, indent)?;
	return strings::dup(memio::string(&buf)!)!;
};
