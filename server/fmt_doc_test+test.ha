// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use strings;

@test fn fmt_doc_text_renders_verbatim() void = {
	let d = text("hello");
	defer doc_finish(&d);
	const out = pretty_str(&d, 80, 0)!;
	defer free(out);
	assert(out == "hello");
};

@test fn fmt_doc_concat_joins_items() void = {
	let items: []doc = alloc([], 2)!;
	append(items, text("foo"))!;
	append(items, text("bar"))!;
	let d = concat(items);
	defer doc_finish(&d);
	const out = pretty_str(&d, 80, 0)!;
	defer free(out);
	assert(out == "foobar");
};

@test fn fmt_doc_group_fits_flat() void = {
	// `group [ "a" line(" ") "b" ]` rendered with width 80 → "a b"
	let items: []doc = alloc([], 3)!;
	append(items, text("a"))!;
	append(items, line(" "))!;
	append(items, text("b"))!;
	let d = group(items);
	defer doc_finish(&d);
	const out = pretty_str(&d, 80, 0)!;
	defer free(out);
	assert(out == "a b");
};

@test fn fmt_doc_group_breaks_when_too_wide() void = {
	// Same group rendered with width 1 should break.
	let items: []doc = alloc([], 3)!;
	append(items, text("aaa"))!;
	append(items, line(" "))!;
	append(items, text("bbb"))!;
	let d = group(items);
	defer doc_finish(&d);
	const out = pretty_str(&d, 4, 0)!;
	defer free(out);
	// Width is 7 flat ("aaa bbb"), exceeds 4, so break.
	assert(out == "aaa\nbbb");
};

@test fn fmt_doc_nest_indents_inner() void = {
	// nest(1, group [ "a" hardline "b" ]) → "a\n\tb"
	let inner_items: []doc = alloc([], 3)!;
	append(inner_items, text("a"))!;
	append(inner_items, hardline())!;
	append(inner_items, text("b"))!;
	let inner = group(inner_items);
	let d = nest(1, inner);
	defer doc_finish(&d);
	const out = pretty_str(&d, 80, 0)!;
	defer free(out);
	assert(out == "a\n\tb");
};

@test fn fmt_doc_comment_forces_break_and_renders() void = {
	// Caller passes the verbatim post-`//` text, including any
	// leading space they want — `pretty` emits `//` followed by
	// the text without inserting its own space, so the output
	// preserves the source's exact comment spacing.
	let items: []doc = alloc([], 3)!;
	append(items, text("before"))!;
	append(items, comment(" hi"))!;
	append(items, text("after"))!;
	let d = concat(items);
	defer doc_finish(&d);
	const out = pretty_str(&d, 80, 0)!;
	defer free(out);
	assert(strings::contains(out, "// hi"));
	assert(strings::contains(out, "before"));
	assert(strings::contains(out, "after"));
};

@test fn fmt_doc_hardline_breaks_enclosing_group_into_broken_mode() void = {
	// The group has a hardline → it should be broken even though
	// the flat width would fit.
	let items: []doc = alloc([], 3)!;
	append(items, text("a"))!;
	append(items, hardline())!;
	append(items, text("b"))!;
	let d = group(items);
	defer doc_finish(&d);
	const out = pretty_str(&d, 80, 0)!;
	defer free(out);
	assert(out == "a\nb");
};

@test fn fmt_doc_if_broken_disappears_in_flat_renders_in_broken() void = {
	// In flat mode, if_broken(",") emits nothing.
	let flat_items: []doc = alloc([], 4)!;
	append(flat_items, text("("))!;
	append(flat_items, text("x"))!;
	append(flat_items, if_broken(","))!;
	append(flat_items, text(")"))!;
	let flat_d = group(flat_items);
	defer doc_finish(&flat_d);
	const flat_out = pretty_str(&flat_d, 80, 0)!;
	defer free(flat_out);
	assert(flat_out == "(x)");

	// In broken mode (forced via hardline), if_broken(",") emits ",".
	let br_items: []doc = alloc([], 5)!;
	append(br_items, text("("))!;
	append(br_items, hardline())!;
	append(br_items, text("x"))!;
	append(br_items, if_broken(","))!;
	append(br_items, text(")"))!;
	let br_d = group(br_items);
	defer doc_finish(&br_d);
	const br_out = pretty_str(&br_d, 80, 0)!;
	defer free(br_out);
	assert(br_out == "(\nx,)");
};

@test fn fmt_doc_softline_flat_in_flat_mode() void = {
	// In flat mode, line("") emits nothing.
	let items: []doc = alloc([], 3)!;
	append(items, text("("))!;
	append(items, line(""))!;
	append(items, text("x"))!;
	let d = group(items);
	defer doc_finish(&d);
	const out = pretty_str(&d, 80, 0)!;
	defer free(out);
	assert(out == "(x");
};
