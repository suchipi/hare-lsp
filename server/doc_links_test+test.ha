// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use strings;

// Unit tests for render_doc_refs. The e2e coverage in
// e2e/hover+test.ha exercises the full hover pipeline; these
// tests pin down render_doc_refs's contract in isolation so a
// regression in ref resolution or link formatting fails fast.
@test fn render_doc_refs_passthrough_when_no_refs() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///dr_pt.ha", "export fn target() void = void;\\n");
	const doc = find_document(&s, "file:///dr_pt.ha") as *document;
	const text = "Some prose with no doc references at all.";
	const out_str = render_doc_refs(&s, doc, text);
	defer free(out_str);
	assert(out_str == text, "text without `[[...]]` must pass through unchanged");
};

@test fn render_doc_refs_resolves_local_decl_to_link() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///dr_local.ha",
		"export fn helper() void = void;\\nexport fn caller() void = void;\\n");
	const doc = find_document(&s, "file:///dr_local.ha") as *document;
	const text = "See [[helper]] for the implementation.";
	const out_str = render_doc_refs(&s, doc, text);
	defer free(out_str);
	// A resolved ref must turn into a markdown command-link: the
	// VSCode extension dispatches this URI to a navigation jump.
	assert(
		strings::contains(out_str, "[helper](command:hare-lsp.openLocation?"),
		"local resolution must render a `command:hare-lsp.openLocation` link"
	);
};

@test fn render_doc_refs_unresolved_ref_falls_back_to_inline_code() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///dr_miss.ha", "export fn target() void = void;\\n");
	const doc = find_document(&s, "file:///dr_miss.ha") as *document;
	const text = "See [[no_such_thing]] for details.";
	const out_str = render_doc_refs(&s, doc, text);
	defer free(out_str);
	// Unresolved refs must NOT produce a broken link; the user
	// should still see the original text rendered as inline code.
	assert(
		strings::contains(out_str, "`no_such_thing`"),
		"unresolved refs must fall back to inline code"
	);
	assert(
		!strings::contains(out_str, "command:hare-lsp.openLocation"),
		"unresolved refs must NOT emit a link with a stale target"
	);
};

@test fn render_doc_refs_handles_unterminated_open_bracket() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///dr_unt.ha", "export fn target() void = void;\\n");
	const doc = find_document(&s, "file:///dr_unt.ha") as *document;
	// `[[` without a matching `]]` — must not loop or panic; the
	// implementation emits the remainder verbatim and stops.
	const text = "Trailing [[ that never closes is fine.";
	const out_str = render_doc_refs(&s, doc, text);
	defer free(out_str);
	assert(
		strings::contains(out_str, "[[ that never closes"),
		"unterminated `[[` must pass through unchanged, not consume the rest"
	);
};

@test fn render_doc_refs_empty_ref_passes_through() void = {
	let (s, scan, in_buf, out) = nav_test_server();
	defer nav_test_cleanup(&s, scan, in_buf, out);
	nav_open(&s, "file:///dr_empty.ha", "export fn target() void = void;\\n");
	const doc = find_document(&s, "file:///dr_empty.ha") as *document;
	const text = "An empty ref like [[]] should pass through.";
	const out_str = render_doc_refs(&s, doc, text);
	defer free(out_str);
	assert(
		strings::contains(out_str, "[[]]"),
		"empty `[[]]` must pass through verbatim"
	);
};
