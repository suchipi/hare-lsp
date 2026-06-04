// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Unit tests for match case-arm type completion. These reuse the
// completion test harness (comp_test_server / comp_open / run_completion /
// item_labels) defined in completion_test+test.ha. The cross-module
// qualification + auto-import path is exercised end-to-end against the real
// stdlib `io::error` in e2e/completion+test.ha; here we keep everything in
// a single open document so resolution never touches disk.

use encoding::json;
use strings;

// Returns the first item whose label matches, or void.
fn mc_item_with_label(
	items: []json::value,
	label: str,
) (json::object | void) = {
	for (let i = 0z; i < len(items); i += 1) {
		const it = items[i] as json::object;
		const l = *(json::get(&it, "label") as *json::value) as str;
		if (l == label) return it;
	};
	return void;
};

@test fn completion_match_case_offers_inline_union_variants() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	// Matching over `ab = (int | str | void)`: the cursor right after
	// `case ` must offer each member type plus the union alias itself, and
	// nothing else (the position is exclusive).
	comp_open(&s, "file:///mc1.ha",
		`type ab = (int | str | void);\nfn main(x: ab) void = {\n\tmatch (x) {\n\tcase \n\t};\n};\n`
	);

	// Line 3 = `\tcase `; char 6 sits right after the trailing space.
	const items = run_completion(&s, out, "file:///mc1.ha", 3, 6, 4000.0);
	defer finish_items(items);
	const labels = item_labels(items);
	defer free_labels(labels);

	assert(labels_contains(labels, "int"), "must offer union member `int`");
	assert(labels_contains(labels, "str"), "must offer union member `str`");
	assert(labels_contains(labels, "void"), "must offer union member `void`");
	assert(
		labels_contains(labels, "ab"),
		"must offer the matched union alias itself (whole-subset match)"
	);
	// The binding form stays reachable.
	assert(labels_contains(labels, "let"), "must keep `let` reachable");
	// Exclusive: ordinary value-position keywords must not leak in.
	assert(
		!labels_contains(labels, "for"),
		"match case-arm completion must be exclusive (no `for` keyword)"
	);
	assert(
		!labels_contains(labels, "return"),
		"match case-arm completion must be exclusive (no `return` keyword)"
	);
	// Variant items present as a type/class kind.
	const int_item = match (mc_item_with_label(items, "int")) {
	case let o: json::object =>
		yield o;
	case void => abort("expected `int` item");
	};
	const kind = *(json::get(&int_item, "kind") as *json::value) as f64;
	assert(kind == 7.0, "union variant items must have kind=Class(7)");
	const sort = *(json::get(&int_item, "sortText") as *json::value) as str;
	assert(
		strings::hasprefix(sort, "0-"),
		"union variants must sort above other completion sources"
	);
};

@test fn completion_match_case_filters_by_partial() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	// Typing `case in` must narrow to variants whose name starts with `in`.
	comp_open(&s, "file:///mc2.ha",
		`type ab = (int | str | void);\nfn main(x: ab) void = {\n\tmatch (x) {\n\tcase in\n\t};\n};\n`
	);

	// Line 3 = `\tcase in`; char 8 sits right after `in`.
	const items = run_completion(&s, out, "file:///mc2.ha", 3, 8, 4001.0);
	defer finish_items(items);
	const labels = item_labels(items);
	defer free_labels(labels);

	assert(labels_contains(labels, "int"), "`int` matches the `in` prefix");
	assert(!labels_contains(labels, "str"), "`str` must be filtered out");
	assert(!labels_contains(labels, "void"), "`void` must be filtered out");
	assert(
		!labels_contains(labels, "let"),
		"`let` must be filtered out by the `in` prefix"
	);
};

@test fn completion_match_case_let_binding_form() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	// The binding form `case let e: <type>` is also a type position; the
	// union variants must be offered after the colon.
	comp_open(&s, "file:///mc3.ha",
		`type ab = (int | str | void);\nfn main(x: ab) void = {\n\tmatch (x) {\n\tcase let e: \n\t};\n};\n`
	);

	// Line 3 = `\tcase let e: `; char 13 sits right after the space.
	const items = run_completion(&s, out, "file:///mc3.ha", 3, 13, 4002.0);
	defer finish_items(items);
	const labels = item_labels(items);
	defer free_labels(labels);

	assert(labels_contains(labels, "int"), "binding form must offer `int`");
	assert(labels_contains(labels, "str"), "binding form must offer `str`");
	assert(labels_contains(labels, "void"), "binding form must offer `void`");
};

@test fn completion_match_case_recurses_nested_unions() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	// `group = (...inner | cc)` where `inner = (aa | bb)`. Matching over
	// `group` must offer the named unions (`group`, `inner`) for
	// whole-subset matching AND recurse into their members (`aa`, `bb`,
	// `cc`). Everything lives in one module so the names stay bare.
	comp_open(&s, "file:///mc4.ha",
		`type aa = !void;\ntype bb = !void;\ntype cc = !void;\ntype inner = (aa | bb);\ntype group = (...inner | cc);\nfn handle(g: group) void = {\n\tmatch (g) {\n\tcase \n\t};\n};\n`
	);

	// Line 7 = `\tcase `; char 6 sits right after the trailing space.
	const items = run_completion(&s, out, "file:///mc4.ha", 7, 6, 4003.0);
	defer finish_items(items);
	const labels = item_labels(items);
	defer free_labels(labels);

	assert(
		labels_contains(labels, "group"),
		"must offer the top-level named union `group`"
	);
	assert(
		labels_contains(labels, "inner"),
		"must offer the nested named union `inner` (whole-subset match)"
	);
	assert(labels_contains(labels, "aa"), "must recurse to member `aa`");
	assert(labels_contains(labels, "bb"), "must recurse to member `bb`");
	assert(labels_contains(labels, "cc"), "must offer member `cc`");
};

@test fn completion_match_case_does_not_fire_in_switch() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	// `switch` also uses `case`, but its arms are value expressions, not
	// types. The match-case path must not take over; ordinary completion
	// (which offers value-position keywords like `for`) runs instead.
	comp_open(&s, "file:///mc5.ha",
		`fn main(x: int) void = {\n\tswitch (x) {\n\tcase \n\t};\n};\n`);

	// Line 2 = `\tcase `; char 6 sits right after the trailing space.
	const items = run_completion(&s, out, "file:///mc5.ha", 2, 6, 4004.0);
	defer finish_items(items);
	const labels = item_labels(items);
	defer free_labels(labels);

	assert(
		labels_contains(labels, "for"),
		"switch case-arm must fall through to ordinary completion (offers `for`)"
	);
};

@test fn completion_match_case_match_nested_in_builtin() void = {
	let (s, scan, in_buf, out) = comp_test_server();
	defer comp_test_cleanup(&s, scan, in_buf, out);
	// The match is the argument of an `alloc(...)` builtin (binding -> alloc
	// -> match). The sentinel-finding walker must descend through `alloc`,
	// one of the forms the earlier non-exhaustive version omitted, to reach
	// the match and still offer its variants.
	comp_open(&s, "file:///mc6.ha",
		`type ab = (int | str | void);\nfn main(x: ab) void = {\n\tlet p = alloc(match (x) {\n\tcase \n\t});\n};\n`
	);

	// Line 3 = `\tcase `; char 6 sits right after the trailing space.
	const items = run_completion(&s, out, "file:///mc6.ha", 3, 6, 4005.0);
	defer finish_items(items);
	const labels = item_labels(items);
	defer free_labels(labels);

	assert(
		labels_contains(labels, "int"),
		"a match nested inside alloc(...) must still resolve its union variants"
	);
	assert(labels_contains(labels, "str"), "must offer `str`");
	assert(labels_contains(labels, "void"), "must offer `void`");
};
