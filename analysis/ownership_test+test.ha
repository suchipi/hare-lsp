// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Unit tests for the Layer-1 annotation parser and the Layer-2 stdlib
// table lookup.

use strings;

@test fn ownership_annotation_returns_owned() void = {
	let f = annotations_from_docs(" @returns: owned\n", true);
	defer finish_ownership_fact(&f);
	assert(f.kind == ownership::OWNED);
	assert(f.source == ownership_source::ANNOTATION);
	assert(f.detail == "annotation");
};

@test fn ownership_annotation_returns_borrowed() void = {
	let f = annotations_from_docs(" @returns: borrowed\n", true);
	defer finish_ownership_fact(&f);
	assert(f.kind == ownership::BORROWED);
	assert(f.source == ownership_source::ANNOTATION);
	assert(f.detail == "annotation");
};

@test fn ownership_annotation_returns_borrowed_from() void = {
	let f = annotations_from_docs(" Trims things.\n @returns: borrowed from in\n",
		true);
	defer finish_ownership_fact(&f);
	assert(f.kind == ownership::BORROWED);
	assert(f.source == ownership_source::ANNOTATION);
	assert(f.detail == "annotation: borrowed from `in`");
};

@test fn ownership_annotation_bare_owned_ignored_on_function() void = {
	let f = annotations_from_docs(" @owned\n", true);
	defer finish_ownership_fact(&f);
	assert(f.kind == ownership::UNKNOWN);
	assert(f.source == ownership_source::NONE);
};

@test fn ownership_annotation_bare_borrowed_ignored_on_function() void = {
	let f = annotations_from_docs(" @borrowed\n", true);
	defer finish_ownership_fact(&f);
	assert(f.kind == ownership::UNKNOWN);
	assert(f.source == ownership_source::NONE);
};

@test fn ownership_annotation_bare_owned_on_global() void = {
	let f = annotations_from_docs(" @owned\n", false);
	defer finish_ownership_fact(&f);
	assert(f.kind == ownership::OWNED);
	assert(f.source == ownership_source::ANNOTATION);
};

@test fn ownership_annotation_bare_borrowed_on_global() void = {
	let f = annotations_from_docs(" @borrowed\n", false);
	defer finish_ownership_fact(&f);
	assert(f.kind == ownership::BORROWED);
	assert(f.source == ownership_source::ANNOTATION);
};

@test fn ownership_annotation_returns_owned_overrides_global_rules() void = {
	// On a function decl, only @returns: tags work; bare on the
	// function would be ignored.
	let f = annotations_from_docs(" @returns: owned\n @owned\n", true);
	defer finish_ownership_fact(&f);
	assert(f.kind == ownership::OWNED);
	assert(f.source == ownership_source::ANNOTATION);
};

@test fn ownership_annotation_no_tag_returns_empty() void = {
	let f = annotations_from_docs(" Just some prose.\n", true);
	defer finish_ownership_fact(&f);
	assert(f.kind == ownership::UNKNOWN);
	assert(f.source == ownership_source::NONE);
	assert(f.detail == "");
};

@test fn ownership_annotation_empty_docs_returns_empty() void = {
	let f = annotations_from_docs("", true);
	defer finish_ownership_fact(&f);
	assert(f.kind == ownership::UNKNOWN);
	assert(f.source == ownership_source::NONE);
};

@test fn ownership_param_annotation_basic() void = {
	const names: []str = ["in", "out", "n"];
	const result = param_annotations_from_docs(
		" Tokenizes the input.\n @param in: borrowed\n @param out: owned\n", names);
	const kinds = result.0;
	defer free(kinds);
	const details = result.1;
	defer {
		for (let i = 0z; i < len(details); i += 1) free(details[i]);
		free(details);
	};
	assert(len(kinds) == 3);
	assert(kinds[0] == ownership::BORROWED);
	assert(kinds[1] == ownership::OWNED);
	assert(kinds[2] == ownership::UNKNOWN);
	assert(details[0] == "annotation");
	assert(details[1] == "annotation");
	assert(details[2] == "");
};

@test fn ownership_param_annotation_no_tags() void = {
	const names: []str = ["a", "b"];
	const result = param_annotations_from_docs(" Just prose.\n", names);
	const kinds = result.0;
	defer free(kinds);
	const details = result.1;
	defer {
		for (let i = 0z; i < len(details); i += 1) free(details[i]);
		free(details);
	};
	assert(len(kinds) == 2);
	assert(kinds[0] == ownership::UNKNOWN);
	assert(kinds[1] == ownership::UNKNOWN);
};

@test fn ownership_stdlib_lookup_strings_dup() void = {
	const f = match (lookup_stdlib_fact("strings", "dup")) {
	case let f: ownership_fact =>
		yield f;
	case void => abort("expected strings::dup to be in the table");
	};
	let f_mut = f;
	defer finish_ownership_fact(&f_mut);
	assert(f_mut.kind == ownership::OWNED);
	assert(f_mut.source == ownership_source::DOC_COMMENT);
	assert(strings::contains(f_mut.detail, "free"));
};

@test fn ownership_stdlib_lookup_strings_trim_borrowed() void = {
	const f = match (lookup_stdlib_fact("strings", "trim")) {
	case let f: ownership_fact =>
		yield f;
	case void => abort("expected strings::trim to be in the table");
	};
	let f_mut = f;
	defer finish_ownership_fact(&f_mut);
	assert(f_mut.kind == ownership::BORROWED);
	assert(f_mut.source == ownership_source::DOC_COMMENT);
	assert(strings::contains(f_mut.detail, "borrowed from"));
};

@test fn ownership_stdlib_lookup_miss() void = {
	match (lookup_stdlib_fact("nonexistent_module", "nonexistent_fn")) {
	case ownership_fact => abort("expected miss");
	case void => void;
	};
};
