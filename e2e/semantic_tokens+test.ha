// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// e2e: semantic tokens (full, full/delta, range).

use encoding::json;
use strings;

@test fn e2e_semantic_tokens_full_returns_data() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `export fn main() void = void;
`;
	open_doc(&s, "file:///st.ha", sample);

	const req =
		`{"jsonrpc":"2.0","id":2100,"method":"textDocument/semanticTokens/full","params":{"textDocument":{"uri":"file:///st.ha"}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 2100.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = *(json::get(&obj, "result") as *json::value) as json::object;
	// resultId is the key the client carries into /full/delta later.
	const _ = *(json::get(&result, "resultId") as *json::value) as str;
	const data = *(json::get(&result, "data") as *json::value) as []json::value;
	// LSP encodes 5 u32s per token (deltaLine, deltaStart, length, type, mods).
	assert(
		len(data) > 0 && len(data) % 5 == 0,
		"semantic tokens data must be a multiple of 5 elements"
	);
	// Pin down the first token so a regression that mis-classifies
	// `export` (or shifts its position) fails here. Token legend
	// position 6 is `keyword`.
	const delta_line = data[0] as f64;
	const delta_start = data[1] as f64;
	const length = data[2] as f64;
	const ttype = data[3] as f64;
	assert(delta_line == 0.0, "first token starts on line 0");
	assert(delta_start == 0.0, "first token starts at column 0");
	assert(length == 6.0, "first token spans `export` (6 chars)");
	assert(ttype == 6.0, "first token is a keyword (legend index 6)");
};

@test fn e2e_semantic_tokens_range_returns_data() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `export fn main() void = void;
`;
	open_doc(&s, "file:///str.ha", sample);

	const req =
		`{"jsonrpc":"2.0","id":2101,"method":"textDocument/semanticTokens/range","params":{"textDocument":{"uri":"file:///str.ha"},"range":{"start":{"line":0,"character":0},"end":{"line":1,"character":0}}}}`;
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 2101.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = *(json::get(&obj, "result") as *json::value) as json::object;
	const data = *(json::get(&result, "data") as *json::value) as []json::value;
	assert(
		len(data) > 0 && len(data) % 5 == 0,
		"range semantic tokens data must be a multiple of 5 elements"
	);
	// Pin the first token like the /full test so a classify_token
	// regression — emitting kind=0/`namespace` for `export` — fails.
	const ttype = data[3] as f64;
	assert(
		ttype == 6.0,
		"first token from /range is `export`, a keyword (legend index 6)"
	);
};

@test fn e2e_semantic_tokens_full_delta_returns_edits_or_full() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `export fn main() void = void;
`;
	open_doc(&s, "file:///std.ha", sample);

	// First request a full snapshot to learn its resultId.
	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":2102,"method":"textDocument/semanticTokens/full","params":{"textDocument":{"uri":"file:///std.ha"}}}`
		));
	const body1 = wait_for_response(&s, 2102.0);
	defer free(body1);
	let v1 = json::loadstr(strings::fromutf8(body1)!)!;
	defer json::finish(v1);
	const obj1 = v1 as json::object;
	const result1 = *(json::get(&obj1, "result") as *json::value) as json::object;
	const prev_id = *(json::get(&result1, "resultId") as *json::value) as str;

	// Now ask for delta against the same content. The diff should be
	// empty, so `edits` is an empty array.
	const delta_msg =
		strings::concat(
			`{"jsonrpc":"2.0","id":2103,"method":"textDocument/semanticTokens/full/delta","params":{"textDocument":{"uri":"file:///std.ha"},"previousResultId":"`,
			prev_id, `"}}`)!;
	defer free(delta_msg);
	send(&s, strings::toutf8(delta_msg));

	const body2 = wait_for_response(&s, 2103.0);
	defer free(body2);
	const text2 = strings::fromutf8(body2)!;
	let v2 = json::loadstr(text2)!;
	defer json::finish(v2);
	const obj2 = v2 as json::object;
	const result2 = *(json::get(&obj2, "result") as *json::value) as json::object;
	// Either an edits array (delta path) or a `data` array (server gave
	// up on diff and returned full). Both are valid per spec.
	const is_delta = json::get(&result2, "edits") is *json::value;
	const is_full = json::get(&result2, "data") is *json::value;
	assert(
		is_delta || is_full,
		"semantic tokens delta must produce either edits or a full snapshot"
	);
	// The document hasn't changed between the /full and /full/delta
	// calls, so the delta path should emit an empty `edits` array.
	// Without this, a regression that always re-encodes the full data
	// (defeating the purpose of delta) would still pass the
	// either-or check above.
	if (is_delta) {
		const edits =
			*(json::get(&result2, "edits") as *json::value) as []json::value;
		assert(
			len(edits) == 0,
			"unchanged content must produce no edits in delta response"
		);
	};
};
