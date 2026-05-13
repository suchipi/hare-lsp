// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use strings;
use time;

@test fn parent_dir_of_file_absolute_path() void = {
	const d = parent_dir_of_file("/abs/dir/file.ha");
	defer free(d);
	assert(d == "/abs/dir");
};

@test fn parent_dir_of_file_root() void = {
	const d = parent_dir_of_file("/foo.ha");
	defer free(d);
	assert(d == "/");
};

@test fn parent_dir_of_file_no_separator() void = {
	const d = parent_dir_of_file("foo.ha");
	defer free(d);
	assert(d == ".");
};

@test fn parent_dir_of_file_relative_with_segments() void = {
	const d = parent_dir_of_file("rel/dir/file.ha");
	defer free(d);
	assert(d == "rel/dir");
};

@test fn dep_resolver_cache_hit_returns_cached_dir() void = {
	let cache: []cache_entry = [];
	append(cache, cache_entry {
		ident = strings::dup("foo::bar")!,
		dir = strings::dup("/cached/foo/bar")!,
	})!;
	// On a cache hit we never dereference `s`; pass a sentinel.
	let dummy: int = 0;
	let ctx = dep_resolver_ctx {
		s = &dummy: *opaque: *server,
		cache = cache,
	};
	defer finish_dep_resolver_cache(&ctx);

	let ident: []str = [];
	defer free(ident);
	append(ident, "foo")!;
	append(ident, "bar")!;
	const result = dep_resolver_fn(&ctx: *opaque, ident);
	const dir = result as str;
	defer free(dir);
	assert(
		dir == "/cached/foo/bar",
		"cache hit should return the previously-resolved dir verbatim"
	);
};

@test fn dep_resolver_cache_hit_negative_returns_void() void = {
	let cache: []cache_entry = [];
	// Empty `dir` is the cached form of "find_module returned void
	// last time; don't re-scan HAREPATH for this ident".
	append(cache, cache_entry {
		ident = strings::dup("mystery")!,
		dir = strings::dup("")!,
	})!;
	let dummy: int = 0;
	let ctx = dep_resolver_ctx {
		s = &dummy: *opaque: *server,
		cache = cache,
	};
	defer finish_dep_resolver_cache(&ctx);

	let ident: []str = [];
	defer free(ident);
	append(ident, "mystery")!;
	const result = dep_resolver_fn(&ctx: *opaque, ident);
	assert(
		result is void,
		"cache hit on an unresolvable ident should short-circuit to void"
	);
};

@test fn remaining_budget_ms_zero_total_means_no_deadline() void = {
	// total_ms == 0 → return 0 (caller treats this as "no deadline").
	const past = time::add(time::now(time::clock::MONOTONIC),
		-100i64 * time::MILLISECOND);
	assert(remaining_budget_ms(0, past) == 0);
	const future = time::add(time::now(time::clock::MONOTONIC),
		100i64 * time::MILLISECOND);
	assert(remaining_budget_ms(0, future) == 0);
};

@test fn remaining_budget_ms_deadline_in_future_returns_positive() void = {
	const deadline = time::add(time::now(time::clock::MONOTONIC),
		500i64 * time::MILLISECOND);
	const remaining = remaining_budget_ms(60000, deadline);
	// Should be ~500ms; allow a wide margin for slow CI.
	assert(remaining >= 1 && remaining <= 500);
};

@test fn remaining_budget_ms_deadline_in_past_returns_zero() void = {
	const past = time::add(time::now(time::clock::MONOTONIC),
		-100i64 * time::MILLISECOND);
	assert(remaining_budget_ms(60000, past) == 0);
};

@test fn compose_harepath_empty() void = {
	const h = compose_harepath([], []);
	defer free(h);
	assert(h == "");
};

@test fn compose_harepath_folders_only() void = {
	const h = compose_harepath(["/ws"], []);
	defer free(h);
	assert(h == "/ws");
};

@test fn compose_harepath_stdlib_only() void = {
	const h = compose_harepath([], ["/usr/local/src/hare/stdlib"]);
	defer free(h);
	assert(h == "/usr/local/src/hare/stdlib");
};

@test fn compose_harepath_folders_first_then_stdlib() void = {
	const h = compose_harepath(["/ws"],
		["/usr/local/src/hare/stdlib", "/usr/local/src/hare/third-party"]);
	defer free(h);
	assert(h == "/ws:/usr/local/src/hare/stdlib:/usr/local/src/hare/third-party");
};

@test fn compose_harepath_multiple_folders() void = {
	const h = compose_harepath(["/a", "/b"], ["/c"]);
	defer free(h);
	assert(h == "/a:/b:/c");
};

@test fn build_diag_already_in_matches_all_fields() void = {
	let acc: []build_diagnostic = [];
	defer finish_build_diagnostics(acc);
	append(acc, build_diagnostic {
		path = strings::dup("/x.ha")!,
		line = 5,
		col = 10,
		kind = strings::dup("error")!,
		message = strings::dup("boom")!,
	})!;
	const dup = build_diagnostic {
		path = "/x.ha",
		line = 5,
		col = 10,
		kind = "error",
		message = "boom",
	};
	assert(build_diag_already_in(&acc, dup));
};

@test fn build_diag_already_in_misses_on_different_line() void = {
	let acc: []build_diagnostic = [];
	defer finish_build_diagnostics(acc);
	append(acc, build_diagnostic {
		path = strings::dup("/x.ha")!,
		line = 5,
		col = 10,
		kind = strings::dup("error")!,
		message = strings::dup("boom")!,
	})!;
	const other = build_diagnostic {
		path = "/x.ha",
		line = 6,
		col = 10,
		kind = "error",
		message = "boom",
	};
	assert(!build_diag_already_in(&acc, other));
};

@test fn build_diag_already_in_misses_on_different_kind() void = {
	let acc: []build_diagnostic = [];
	defer finish_build_diagnostics(acc);
	append(acc, build_diagnostic {
		path = strings::dup("/x.ha")!,
		line = 5,
		col = 10,
		kind = strings::dup("error")!,
		message = strings::dup("boom")!,
	})!;
	const other = build_diagnostic {
		path = "/x.ha",
		line = 5,
		col = 10,
		kind = "warning",
		message = "boom",
	};
	assert(!build_diag_already_in(&acc, other));
};

@test fn build_diag_already_in_misses_on_different_message() void = {
	let acc: []build_diagnostic = [];
	defer finish_build_diagnostics(acc);
	append(acc, build_diagnostic {
		path = strings::dup("/x.ha")!,
		line = 5,
		col = 10,
		kind = strings::dup("error")!,
		message = strings::dup("boom")!,
	})!;
	const other = build_diagnostic {
		path = "/x.ha",
		line = 5,
		col = 10,
		kind = "error",
		message = "kaboom",
	};
	assert(!build_diag_already_in(&acc, other));
};

@test fn merge_dedup_diags_appends_new() void = {
	let acc: []build_diagnostic = [];
	defer finish_build_diagnostics(acc);
	let incoming: []build_diagnostic = [];
	append(incoming, build_diagnostic {
		path = strings::dup("/x.ha")!,
		line = 5,
		col = 1,
		kind = strings::dup("error")!,
		message = strings::dup("first")!,
	})!;
	append(incoming, build_diagnostic {
		path = strings::dup("/y.ha")!,
		line = 7,
		col = 3,
		kind = strings::dup("error")!,
		message = strings::dup("second")!,
	})!;
	merge_dedup_diags(&acc, incoming);
	assert(len(acc) == 2);
	assert(acc[0].path == "/x.ha");
	assert(acc[1].path == "/y.ha");
};

@test fn merge_dedup_diags_drops_duplicates() void = {
	let acc: []build_diagnostic = [];
	defer finish_build_diagnostics(acc);
	append(acc, build_diagnostic {
		path = strings::dup("/x.ha")!,
		line = 5,
		col = 1,
		kind = strings::dup("error")!,
		message = strings::dup("only")!,
	})!;
	let incoming: []build_diagnostic = [];
	append(incoming, build_diagnostic {
		path = strings::dup("/x.ha")!,
		line = 5,
		col = 1,
		kind = strings::dup("error")!,
		message = strings::dup("only")!,
	})!;
	append(incoming, build_diagnostic {
		path = strings::dup("/x.ha")!,
		line = 5,
		col = 1,
		kind = strings::dup("error")!,
		message = strings::dup("different")!,
	})!;
	merge_dedup_diags(&acc, incoming);
	// First incoming is a duplicate -> dropped. Second is new -> kept.
	assert(len(acc) == 2);
	assert(acc[1].message == "different");
};
