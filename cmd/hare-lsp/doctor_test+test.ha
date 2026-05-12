// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
@test fn parse_harepath_empty() void = {
	const entries = parse_harepath("");
	defer free(entries);
	assert(len(entries) == 0);
};

@test fn parse_harepath_single() void = {
	const entries = parse_harepath("/usr/local/src/hare/stdlib");
	defer free(entries);
	assert(len(entries) == 1);
	assert(entries[0] == "/usr/local/src/hare/stdlib");
};

@test fn parse_harepath_multiple() void = {
	const entries = parse_harepath("/a:/b/c:/usr/local/src/hare/stdlib");
	defer free(entries);
	assert(len(entries) == 3);
	assert(entries[0] == "/a");
	assert(entries[1] == "/b/c");
	assert(entries[2] == "/usr/local/src/hare/stdlib");
};

@test fn parse_harepath_skips_empty_segments() void = {
	// Repeated colons and a leading/trailing colon yield empty
	// segments that we drop.
	const entries = parse_harepath(":/a::/b:");
	defer free(entries);
	assert(len(entries) == 2);
	assert(entries[0] == "/a");
	assert(entries[1] == "/b");
};

@test fn path_is_absolute_cases() void = {
	assert(path_is_absolute("/foo") == true);
	assert(path_is_absolute("/") == true);
	assert(path_is_absolute("foo/bar") == false);
	assert(path_is_absolute("") == false);
	assert(path_is_absolute("./foo") == false);
};
