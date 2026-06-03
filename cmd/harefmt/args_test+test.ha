// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Unit tests for harefmt's argument parsing, focused on the
// --tab-width option added to drive the formatter's tab width.

use server;

@test fn parse_args_tab_width_defaults_to_8() void = {
	const c = parse_args(["--write", "foo.ha"]) as cli;
	defer free(c.paths);
	assert(c.tab_width == server::DEFAULT_TAB_WIDTH);
};

@test fn parse_args_tab_width_explicit_value() void = {
	const c = parse_args(["--write", "--tab-width", "4", "foo.ha"]) as cli;
	defer free(c.paths);
	assert(c.tab_width == 4z);
	assert(len(c.paths) == 1);
	assert(c.paths[0] == "foo.ha");
};

@test fn parse_args_tab_width_rejects_non_numeric() void = {
	assert(parse_args(["--write", "--tab-width", "huit", "x.ha"]) is cli_error);
};

@test fn parse_args_tab_width_rejects_zero() void = {
	assert(parse_args(["--write", "--tab-width", "0", "x.ha"]) is cli_error);
};

@test fn parse_args_tab_width_requires_a_value() void = {
	assert(parse_args(["--write", "--tab-width"]) is cli_error);
};
