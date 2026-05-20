// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// e2e: resource caps. The body-size cap is set before `initialize` via
// the HARE_LSP_MAX_BODY_BYTES env var.

use encoding::json;
use fmt;
use strings;

// A `HARE_LSP_MAX_BODY_BYTES` of 1024 must reject a request body
// larger than that. The transport responds with a JSON-RPC error
// (PARSE_ERROR / content-too-large) and the server exits.
@test fn e2e_limits_body_size_env_var_enforced() void = {
	let s = spawn_session_with_env([
			("HARE_LSP_MAX_BODY_BYTES", "1024"),
		]);
	defer finish_session(&s);

	// Build a request body well over 1024 bytes (a giant document
	// `text` field), enough to trip the cap even on small frames.
	let buf: []u8 = [];
	defer free(buf);
	const prefix = strings::toutf8(
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{},"_pad":"`
	);
	append(buf, prefix...)!;
	for (let i = 0z; i < 2048z; i += 1) {
		append(buf, 'A': u8)!;
	};
	const suffix = strings::toutf8(`"}}`);
	append(buf, suffix...)!;

	send(&s, buf);

	// The server must reply with a structured JSON-RPC error envelope
	// before tearing down the transport. The id is null (we never got
	// far enough to parse the request), the code is PARSE_ERROR
	// (-32700), and the message is a non-empty string describing why
	// the body was rejected.
	const body = recv(&s);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	assert(
		field(&obj, "jsonrpc") as str == "2.0",
		"oversized-request response must have jsonrpc 2.0"
	);
	match (field(&obj, "id")) {
	case json::_null => void;
	case =>
		fmt::fatalf("oversized-request response id should be null, got: {}", text);
	};
	const err = field(&obj, "error") as json::object;
	assert(
		field(&err, "code") as f64 == -32700.0,
		"oversized request must yield JSON-RPC PARSE_ERROR (-32700)"
	);
	const msg = field(&err, "message") as str;
	assert(len(msg) > 0, "PARSE_ERROR response must include a message");
	// The transport reports oversize bodies with this prose. The
	// substring lives inside error.message so a wire reorder or an
	// extra field elsewhere doesn't accidentally satisfy the check.
	assert(
		strings::contains(msg, "too large"),
		"PARSE_ERROR message must explain the body was too large"
	);
};
