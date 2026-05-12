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

// Renders to "" in flat mode, `text` in broken mode. Used for the
// trailing-comma-when-wrapped pattern in arg / field / member lists.
// Has flat width 0 (it disappears in flat mode), so it doesn't
// contribute to fit decisions.
export type doc_if_broken = struct { text: str };

export type doc = (doc_text | doc_line | doc_hardline | doc_group |
	doc_nest | doc_concat | doc_comment | doc_if_broken);

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

export fn if_broken(s: str) doc = doc_if_broken { text = strings::dup(s)! };

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
	case let ib: doc_if_broken =>
		free(ib.text);
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
	case doc_if_broken => return true;
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
	case doc_if_broken =>
		return 0z;
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
	let pending_tabs: i32 = 0;
	render(out, d, render_mode::BROKEN, max_col, indent, 0z,
		&cur_col, &written, &pending_tabs)?;
	return written;
};

// `tail_width` is the flat-width of everything that will be rendered
// after `d` and BEFORE the next break in flat mode. Used by
// `doc_group` so its fit decision accounts for trailing text — e.g.
// a group `(args)` followed by `?.0)` knows to break when `(args)`
// fits but `(args)?.0)` doesn't.
fn render(
	out: io::handle,
	d: *doc,
	mode: render_mode,
	max_col: size,
	indent: i32,
	tail_width: size,
	cur_col: *size,
	written: *size,
	pending_tabs: *i32,
) (void | io::error) = {
	match (*d) {
	case let t: doc_text =>
		emit_str(out, t.content, cur_col, written, pending_tabs)?;
	case let l: doc_line =>
		switch (mode) {
		case render_mode::FLAT =>
			emit_str(out, l.flat, cur_col, written, pending_tabs)?;
		case render_mode::BROKEN =>
			emit_break(out, indent, cur_col, written, pending_tabs)?;
		};
	case doc_hardline =>
		emit_break(out, indent, cur_col, written, pending_tabs)?;
	case let g: doc_group =>
		// Decide flat-or-broken based on remaining columns,
		// counting both the group's own flat width AND the
		// `tail_width` of text that will follow on the same line
		// in flat mode.
		const remaining = if (*cur_col >= max_col) 0z
			else max_col - *cur_col;
		const w = sum_flat_width(g.items);
		const total = if (w == WIDTH_INFINITY) WIDTH_INFINITY
			else if (tail_width == WIDTH_INFINITY) WIDTH_INFINITY
			else if (w > WIDTH_INFINITY - tail_width) WIDTH_INFINITY
			else w + tail_width;
		const child_mode = if (total <= remaining && fits_all(g.items))
			render_mode::FLAT
		else
			render_mode::BROKEN;
		render_items(out, g.items, child_mode, max_col, indent,
			tail_width, cur_col, written, pending_tabs)?;
	case let n: doc_nest =>
		render(out, n.inner, mode, max_col, indent + n.delta,
			tail_width, cur_col, written, pending_tabs)?;
	case let c: doc_concat =>
		render_items(out, c.items, mode, max_col, indent,
			tail_width, cur_col, written, pending_tabs)?;
	case let cm: doc_comment =>
		// `cm.text` is the raw text after `//` from the source and
		// includes any leading whitespace the user wrote (typically
		// one space). Emit `//` with no extra space so we don't
		// double up.
		emit_str(out, "//", cur_col, written, pending_tabs)?;
		emit_str(out, cm.text, cur_col, written, pending_tabs)?;
		emit_break(out, indent, cur_col, written, pending_tabs)?;
	case let ib: doc_if_broken =>
		switch (mode) {
		case render_mode::FLAT => void;
		case render_mode::BROKEN =>
			emit_str(out, ib.text, cur_col, written, pending_tabs)?;
		};
	};
};

// Renders a sequence of doc items, threading the right `tail_width`
// for each one — namely, the flat-width of the items that come AFTER
// it in the sequence, up to the first hardline / comment / softline
// (which would break the line anyway).
fn render_items(
	out: io::handle,
	items: []doc,
	mode: render_mode,
	max_col: size,
	indent: i32,
	outer_tail: size,
	cur_col: *size,
	written: *size,
	pending_tabs: *i32,
) (void | io::error) = {
	for (let i = 0z; i < len(items); i += 1) {
		const my_tail = tail_after(items, i + 1, mode, outer_tail);
		render(out, &items[i], mode, max_col, indent, my_tail,
			cur_col, written, pending_tabs)?;
	};
};

// Computes the flat-width of items[from..] up to the first item that
// always breaks the line (hardline, comment, or — when mode is
// BROKEN — a softline). If we can render past every item without
// hitting such a break, `outer_tail` is added on as the tail beyond
// this sequence.
//
// Recurses through nested doc_group / doc_concat / doc_nest so that a
// later sibling containing a deep hardline only contributes the chars
// it would render on the CURRENT line before the break — not
// WIDTH_INFINITY. Without this, a function signature `group` followed
// by a compound-body group (which always contains hardlines) would
// see tail_width = WIDTH_INFINITY, refuse to fit flat, and break the
// short signature across multiple lines.
fn tail_after(
	items: []doc,
	from: size,
	mode: render_mode,
	outer_tail: size,
) size = {
	let total = 0z;
	for (let i = from; i < len(items); i += 1) {
		const (w, broke) = line_lead_width(&items[i], mode);
		total += w;
		if (broke) return total;
	};
	if (outer_tail == WIDTH_INFINITY) return WIDTH_INFINITY;
	if (total > WIDTH_INFINITY - outer_tail) return WIDTH_INFINITY;
	return total + outer_tail;
};

// Returns (width, broke) where `width` is the number of characters
// `d` would render on the current line before the next inevitable
// line break, and `broke` is true if `d` contains such a break. For a
// group whose flat width is finite, the group renders flat and
// contributes its full flat width. For a group with internal
// hardlines (flat = WIDTH_INFINITY), the group renders broken and we
// recurse to find the prefix-on-current-line.
fn line_lead_width(d: *doc, mode: render_mode) (size, bool) = {
	match (*d) {
	case let t: doc_text =>
		return (len(t.content), false);
	case let l: doc_line =>
		switch (mode) {
		case render_mode::FLAT =>
			return (len(l.flat), false);
		case render_mode::BROKEN =>
			return (0z, true);
		};
	case doc_hardline =>
		return (0z, true);
	case doc_comment =>
		return (0z, true);
	case let ib: doc_if_broken =>
		switch (mode) {
		case render_mode::FLAT =>
			return (0z, false);
		case render_mode::BROKEN =>
			return (len(ib.text), false);
		};
	case let g: doc_group =>
		const w = sum_flat_width(g.items);
		const inner_mode = if (w == WIDTH_INFINITY) render_mode::BROKEN
			else render_mode::FLAT;
		return line_lead_items(g.items, inner_mode);
	case let n: doc_nest =>
		return line_lead_width(n.inner, mode);
	case let c: doc_concat =>
		return line_lead_items(c.items, mode);
	};
};

fn line_lead_items(items: []doc, mode: render_mode) (size, bool) = {
	let total = 0z;
	for (let i = 0z; i < len(items); i += 1) {
		const (w, broke) = line_lead_width(&items[i], mode);
		total += w;
		if (broke) return (total, true);
	};
	return (total, false);
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
	pending_tabs: *i32,
) (void | io::error) = {
	if (len(s) == 0) return;
	// Flush any pending indent tabs from a preceding break. If two
	// breaks fire in a row with no emit_str between, the earlier
	// pending tabs are dropped — that's what prevents trailing
	// whitespace on otherwise-blank lines.
	for (let i: i32 = 0; i < *pending_tabs; i += 1) {
		*written += io::writeall(out, strings::toutf8("\t"))?;
	};
	*pending_tabs = 0;
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
	pending_tabs: *i32,
) (void | io::error) = {
	const nl = strings::toutf8("\n");
	*written += io::writeall(out, nl)?;
	// Defer the indent until non-whitespace content arrives. If
	// another emit_break fires before any emit_str, this indent is
	// discarded — keeping blank lines truly blank.
	*pending_tabs = if (indent < 0) 0i32 else indent;
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
