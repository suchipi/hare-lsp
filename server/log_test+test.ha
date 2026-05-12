// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

@test fn parse_log_level_accepts_canonical_names() void = {
	assert(parse_log_level("debug") as log_level == log_level::DEBUG);
	assert(parse_log_level("info") as log_level == log_level::INFO);
	assert(parse_log_level("warn") as log_level == log_level::WARN);
	assert(parse_log_level("error") as log_level == log_level::ERROR);
};

@test fn parse_log_level_is_case_insensitive() void = {
	assert(parse_log_level("DEBUG") as log_level == log_level::DEBUG);
	assert(parse_log_level("Info") as log_level == log_level::INFO);
	assert(parse_log_level("WARN") as log_level == log_level::WARN);
	assert(parse_log_level("Error") as log_level == log_level::ERROR);
};

@test fn parse_log_level_accepts_warning_alias() void = {
	assert(parse_log_level("warning") as log_level == log_level::WARN);
	assert(parse_log_level("WARNING") as log_level == log_level::WARN);
};

@test fn parse_log_level_rejects_unknown() void = {
	assert(parse_log_level("trace") is void);
	assert(parse_log_level("fatal") is void);
	assert(parse_log_level("") is void);
};

@test fn level_enabled_respects_threshold() void = {
	// At INFO threshold, INFO/WARN/ERROR pass; DEBUG drops.
	assert(!level_enabled(log_level::INFO, log_level::DEBUG));
	assert(level_enabled(log_level::INFO, log_level::INFO));
	assert(level_enabled(log_level::INFO, log_level::WARN));
	assert(level_enabled(log_level::INFO, log_level::ERROR));

	// At ERROR threshold, only ERROR passes.
	assert(!level_enabled(log_level::ERROR, log_level::DEBUG));
	assert(!level_enabled(log_level::ERROR, log_level::INFO));
	assert(!level_enabled(log_level::ERROR, log_level::WARN));
	assert(level_enabled(log_level::ERROR, log_level::ERROR));

	// At DEBUG threshold, everything passes.
	assert(level_enabled(log_level::DEBUG, log_level::DEBUG));
	assert(level_enabled(log_level::DEBUG, log_level::INFO));
	assert(level_enabled(log_level::DEBUG, log_level::WARN));
	assert(level_enabled(log_level::DEBUG, log_level::ERROR));
};
