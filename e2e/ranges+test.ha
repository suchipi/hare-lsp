// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// e2e: foldingRange and selectionRange.

use encoding::json;
use strings;

@test fn e2e_folding_range_returns_function_body_region() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample =
		`export fn main() void = {
	let x = 1;
	let y = 2;
	let _ = x + y;
};
`;
	open_doc(&s, "file:///fold_fn.ha", sample);

	const req =
		`{"jsonrpc":"2.0","id":1300,"method":"textDocument/foldingRange","params":{"textDocument":{"uri":"file:///fold_fn.ha"}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1300.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	// Exactly one fold (the `main` body); no imports in this fixture so
	// the imports-region branch (server/symbols.ha:178-188) doesn't fire.
	assert(
		len(arr) == 1,
		"single multi-line decl must yield exactly one fold range"
	);
	const fold0 = arr[0] as json::object;
	const start_line = *(json::get(&fold0, "startLine") as *json::value) as f64;
	const end_line = *(json::get(&fold0, "endLine") as *json::value) as f64;
	// `main`'s declaration spans source lines 1..5 (1-indexed). The
	// server emits LSP 0-indexed lines, so {start=0, end=4}.
	assert(
		start_line == 0.0,
		"fold must start at line 0 (the `export fn ... {` line)"
	);
	assert(
		end_line == 4.0,
		"fold must end at line 4 (the `};` line) so the body is collapsible"
	);
	const kind = *(json::get(&fold0, "kind") as *json::value) as str;
	assert(
		kind == "region",
		"a function-body fold must carry FoldingRangeKind=\"region\""
	);
};

@test fn e2e_folding_range_emits_imports_region() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `use io;
use os;
use strings;

export fn main() void = void;
`;
	open_doc(&s, "file:///fold_imp.ha", sample);

	const req =
		`{"jsonrpc":"2.0","id":1301,"method":"textDocument/foldingRange","params":{"textDocument":{"uri":"file:///fold_imp.ha"}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1301.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	// `main` is single-line so no symbol fold; only the imports fold
	// should be emitted.
	assert(
		len(arr) == 1,
		"only the imports region should be folded (main is single-line)"
	);
	const fold0 = arr[0] as json::object;
	const kind = *(json::get(&fold0, "kind") as *json::value) as str;
	assert(kind == "imports", "the lone fold must be the imports region");
	const start_line = *(json::get(&fold0, "startLine") as *json::value) as f64;
	const end_line = *(json::get(&fold0, "endLine") as *json::value) as f64;
	// `use io;`..`use strings;` span source lines 1..3 → LSP 0..2.
	assert(
		start_line == 0.0,
		"imports fold must start at line 0 (the first `use`)"
	);
	assert(end_line == 2.0, "imports fold must end at line 2 (the last `use`)");
};

@test fn e2e_selection_range_returns_nested_ranges() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `export fn main() void = {
	let x = 1;
};
`;
	open_doc(&s, "file:///sel.ha", sample);

	// Position on `x` in the let binding (line 1, char 5).
	const req =
		`{"jsonrpc":"2.0","id":1302,"method":"textDocument/selectionRange","params":{"textDocument":{"uri":"file:///sel.ha"},"positions":[{"line":1,"character":5}]}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 1302.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const arr = *(json::get(&obj, "result") as *json::value) as []json::value;
	assert(
		len(arr) == 1,
		"selectionRange must return one result per requested position"
	);
	const r0 = arr[0] as json::object;

	// Innermost level should be the identifier `x` only: cursor was on
	// `x` (line 1, char 5), and `x` is one character wide. A regression
	// that dropped the ident_at level would fall back to the line range
	// and fail this exact-position check.
	const innermost_range = field(&r0, "range") as json::object;
	const inner_start = field(&innermost_range, "start") as json::object;
	const inner_end = field(&innermost_range, "end") as json::object;
	assert(
		field(&inner_start, "line") as f64 == 1.0 &&
		field(&inner_start, "character") as f64 == 5.0,
		"innermost range must start at the `x` ident (line 1, char 5)"
	);
	assert(
		field(&inner_end, "line") as f64 == 1.0 &&
		field(&inner_end, "character") as f64 == 6.0,
		"innermost range must end after the `x` ident (line 1, char 6)"
	);

	// Walk the `parent` chain outward. We expect at least three levels
	// (ident → line → decl → subunit, deduped if any are equal) and
	// each successive parent must strictly contain the inner level.
	let depth: size = 1;
	let cur = r0;
	let prev_start_line = field(&inner_start, "line") as f64;
	let prev_start_char = field(&inner_start, "character") as f64;
	let prev_end_line = field(&inner_end, "line") as f64;
	let prev_end_char = field(&inner_end, "character") as f64;
	for (true) {
		match (json::get(&cur, "parent")) {
		case let p: *json::value =>
			cur = *p as json::object;
		case void =>
			break;
		};
		depth += 1;
		const r = field(&cur, "range") as json::object;
		const sp = field(&r, "start") as json::object;
		const ep = field(&r, "end") as json::object;
		const sl = field(&sp, "line") as f64;
		const sc = field(&sp, "character") as f64;
		const el = field(&ep, "line") as f64;
		const ec = field(&ep, "character") as f64;
		// Parent must be a superset of the previous range AND strictly
		// wider on at least one side (the dedup pass in
		// server/symbols.ha:290-303 drops equal ranges, so equal here
		// would be a bug).
		const starts_earlier =
			sl < prev_start_line || sl == prev_start_line && sc < prev_start_char;
		const ends_later =
			el > prev_end_line || el == prev_end_line && ec > prev_end_char;
		const not_narrower =
			!(sl > prev_start_line || sl == prev_start_line && sc > prev_start_char) &&
			!(el < prev_end_line || el == prev_end_line && ec < prev_end_char);
		assert(
			not_narrower,
			"parent range must contain the inner range, not be narrower"
		);
		assert(
			starts_earlier || ends_later,
			"parent range must be strictly wider than the inner range"
		);
		prev_start_line = sl;
		prev_start_char = sc;
		prev_end_line = el;
		prev_end_char = ec;
	};
	assert(
		depth >= 3,
		"selectionRange must expose at least 3 nested levels"
		" (ident → enclosing line/decl → subunit)"
	);
	// Outermost level must cover from the start of the document
	// onwards. Subunit range is (0, len(data)) per
	// server/symbols.ha:284, so its LSP range starts at {0, 0}.
	assert(
		prev_start_line == 0.0 && prev_start_char == 0.0,
		"outermost range must begin at the start of the document"
	);
};
