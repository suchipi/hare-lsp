// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// e2e: configurable resource caps. The body cap is set before
// `initialize` via the HARE_LSP_MAX_BODY_BYTES env var; the
// `hare.limits.maxOpenDocuments` cap arrives through
// `workspace/configuration` and applies to subsequent didOpens.

use encoding::json;
use fmt;
use io;
use os;
use os::exec;
use strings;

// A `HARE_LSP_MAX_BODY_BYTES` of 1024 must reject a request body
// larger than that. The transport responds with a JSON-RPC error
// (PARSE_ERROR / content-too-large) and the server exits.
@test fn e2e_limits_body_size_env_var_enforced() void = {
	let s = spawn_session_with_env("HARE_LSP_MAX_BODY_BYTES", "1024");
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

// `hare.limits.maxOpenDocuments` = 2 must reject the third didOpen
// with a `window/logMessage` warning. The first two succeed silently
// (no response is expected for notifications, but the third should
// generate a log notification).
@test fn e2e_limits_max_open_documents_configurable() void = {
	let s = spawn_session();
	defer finish_session(&s);

	// Initialize advertising support for `workspace/configuration` so
	// the server pulls settings after `initialized`.
	const init =
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{"workspace":{"configuration":true}}}}`;
	send(&s, strings::toutf8(init));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	// After `initialized`, the server issues workspace/configuration.
	// Find that request, verify its shape, and reply with the limits
	// override.
	let saw_config_request = false;
	for (let i = 0z; i < 20z && !saw_config_request; i += 1) {
		const body = recv(&s);
		defer free(body);
		const text = strings::fromutf8(body)!;
		let v = json::loadstr(text)!;
		defer json::finish(v);
		const obj = match (v) {
		case let o: json::object =>
			yield o;
		case =>
			continue;
		};
		const method = match (json::get(&obj, "method")) {
		case let p: *json::value =>
			yield match (*p) {
			case let s: str =>
				yield s;
			case =>
				continue;
			};
		case =>
			continue;
		};
		if (method != "workspace/configuration") continue;
		// Pin the params shape so a regression that emits a malformed
		// configuration request (no items, wrong section) is caught here
		// rather than silently servicing a wrong-section response.
		const params = field(&obj, "params") as json::object;
		const items = field(&params, "items") as []json::value;
		assert(
			len(items) >= 1,
			"workspace/configuration must request at least one item"
		);
		const item0 = items[0] as json::object;
		assert(
			field(&item0, "section") as str == "hare",
			"workspace/configuration must request the 'hare' section"
		);
		const id = field(&obj, "id") as f64;
		const reply =
			fmt::asprintf(
				`{{"jsonrpc":"2.0","id":{},"result":[{{"limits":{{"maxOpenDocuments":2}}}}]}}`,
				id: i64)!;
		defer free(reply);
		send(&s, strings::toutf8(reply));
		saw_config_request = true;
	};
	assert(
		saw_config_request,
		"server must request workspace/configuration after initialized"
	);

	// Open two documents; both should succeed.
	open_doc(&s, "file:///a.ha", "fn a() void = void;\n");
	open_doc(&s, "file:///b.ha", "fn b() void = void;\n");

	// Open a third; this should produce a window/logMessage warning.
	open_doc(&s, "file:///c.ha", "fn c() void = void;\n");

	// Read until we see the refusal warning for c.ha. Along the way,
	// fail if we ever see a refusal for a.ha or b.ha (which would
	// indicate the cap was misapplied — e.g. cap=2 silently treated as
	// cap=0). Drains a generous frame budget so a slow CI doesn't flake.
	let saw_warning = false;
	for (let i = 0z; i < 40z && !saw_warning; i += 1) {
		const body = recv(&s);
		defer free(body);
		const text = strings::fromutf8(body)!;
		let v = json::loadstr(text)!;
		defer json::finish(v);
		const obj = match (v) {
		case let o: json::object =>
			yield o;
		case =>
			continue;
		};
		const method = match (json::get(&obj, "method")) {
		case let p: *json::value =>
			yield match (*p) {
			case let s: str =>
				yield s;
			case =>
				continue;
			};
		case =>
			continue;
		};
		if (method != "window/logMessage") continue;
		const params = field(&obj, "params") as json::object;
		const ty = field(&params, "type") as f64;
		const msg = field(&params, "message") as str;
		// type 2 = Warning per the LSP MessageType enum. A regression
		// that downgraded the severity to Log/Info would silently
		// disappear in editors that filter by warning threshold; pin
		// the value here.
		if (ty != 2.0) continue;
		if (strings::contains(msg, "file:///a.ha") ||
				strings::contains(msg, "file:///b.ha")) {
			fmt::fatalf("e2e: unexpected refusal warning for a/b within cap=2: {}", msg);
		};
		if (strings::contains(msg, "file:///c.ha")) {
			saw_warning = true;
		};
	};
	assert(saw_warning, "third didOpen with cap=2 must produce a refusal warning");
};

// Spawns a session with a single extra environment variable set on the
// child process. Mirrors [[spawn_session]] but threads `key=value`
// through `exec::setenv`.
fn spawn_session_with_env(key: str, value: str) session = {
	const (in_r, in_w) = exec::pipe();
	const (out_r, out_w) = exec::pipe();

	let cmd = match (exec::cmd("./hare-lsp")) {
	case let c: exec::command =>
		yield c;
	case let e: exec::error =>
		fmt::fatalf("e2e: cannot prepare ./hare-lsp: {}", exec::strerror(e));
	case nomem => abort("e2e: out of memory");
	};

	match (exec::setenv(&cmd, key, value)) {
	case void => void;
	case =>
		fmt::fatalf("e2e: setenv {}={} failed", key, value);
	};
	exec::addfile(&cmd, os::stdin_file, in_r)!;
	exec::addfile(&cmd, os::stdout_file, out_w)!;

	const proc = match (exec::start(&cmd)) {
	case let p: exec::process =>
		yield p;
	case let e: exec::error =>
		fmt::fatalf("e2e: cannot start: {}", exec::strerror(e));
	};
	io::close(in_r)!;
	io::close(out_w)!;
	return session {
		proc = proc,
		stdin = in_w,
		stdout = out_r,
		read_buf = [],
	};
};
