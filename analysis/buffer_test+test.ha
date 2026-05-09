// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use bytes;
use strings;

@test fn from_str_basic() void = {
	let b = from_str("hello\nworld");
	defer finish(&b);
	assert(bytes::equal(bytes(&b), strings::toutf8("hello\nworld")));
	assert(line_count(&b) == 2);
};

@test fn from_str_empty() void = {
	let b = from_str("");
	defer finish(&b);
	assert(len(bytes(&b)) == 0);
	assert(line_count(&b) == 1);
};

@test fn replace_all_resets_line_index() void = {
	let b = from_str("a");
	defer finish(&b);
	replace_all(&b, strings::toutf8("one\ntwo\nthree"));
	assert(as_string(&b) == "one\ntwo\nthree");
	assert(line_count(&b) == 3);
};

@test fn replace_range_same_size() void = {
	let b = from_str("hello world");
	defer finish(&b);
	const delta = replace_range(&b, 6, 11, strings::toutf8("there"));
	assert(delta == 0);
	assert(as_string(&b) == "hello there");
};

@test fn replace_range_growing() void = {
	let b = from_str("foo bar");
	defer finish(&b);
	const delta = replace_range(&b, 4, 7, strings::toutf8("longer-baz"));
	assert(delta == 7);
	assert(as_string(&b) == "foo longer-baz");
};

@test fn replace_range_shrinking() void = {
	let b = from_str("foo bar baz");
	defer finish(&b);
	const delta = replace_range(&b, 4, 7, strings::toutf8("x"));
	assert(delta == -2);
	assert(as_string(&b) == "foo x baz");
};

@test fn replace_range_insert() void = {
	let b = from_str("ac");
	defer finish(&b);
	replace_range(&b, 1, 1, strings::toutf8("b"));
	assert(as_string(&b) == "abc");
};

@test fn replace_range_delete() void = {
	let b = from_str("abcdef");
	defer finish(&b);
	replace_range(&b, 2, 4, strings::toutf8(""));
	assert(as_string(&b) == "abef");
};

@test fn replace_range_clamps() void = {
	let b = from_str("abc");
	defer finish(&b);
	replace_range(&b, 1, 999, strings::toutf8("X"));
	assert(as_string(&b) == "aX");
};

@test fn replace_range_updates_line_index() void = {
	let b = from_str("a\nb\nc");
	defer finish(&b);
	assert(line_count(&b) == 3);
	// Insert two more newlines in the middle.
	replace_range(&b, 2, 2, strings::toutf8("X\nY\n"));
	assert(as_string(&b) == "a\nX\nY\nb\nc");
	assert(line_count(&b) == 5);
};

@test fn replace_range_fuzz_against_string() void = {
	// Apply a series of edits to a buffer and a parallel byte slice;
	// they should agree.
	let b = from_str("");
	defer finish(&b);
	let model: []u8 = [];
	defer free(model);

	const edits: [](size, size, str) = [
		(0z, 0z, "hello"),
		(5z, 5z, " world"),
		(0z, 6z, "HELLO!"),
		(6z, 6z, "\n"),
		(7z, 12z, "World"),
		(12z, 12z, "\n"),
		(12z, 12z, "extra\nlines"),
	];

	for (let i = 0z; i < len(edits); i += 1) {
		const (start, end, txt) = edits[i];
		// Apply to model.
		const newb = strings::toutf8(txt);
		const before = model[..start];
		const after = model[end..];
		let next: []u8 = [];
		append(next, before...)!;
		append(next, newb...)!;
		append(next, after...)!;
		free(model);
		model = next;

		replace_range(&b, start, end, newb);
		assert(bytes::equal(bytes(&b), model));
	};
};

@test fn line_index_stays_consistent_after_edits() void = {
	let b = from_str("");
	defer finish(&b);
	replace_range(&b, 0, 0, strings::toutf8("line1\nline2\nline3"));
	assert(line_count(&b) == 3);

	// Delete all of line2.
	replace_range(&b, 6, 12, strings::toutf8(""));
	assert(as_string(&b) == "line1\nline3");
	assert(line_count(&b) == 2);
};
