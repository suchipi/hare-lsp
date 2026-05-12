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

	// Expect a PARSE_ERROR response, OR an EOF (server may close
	// after replying since transport state is unrecoverable).
	const body = recv(&s);
	defer free(body);
	const text = strings::fromutf8(body)!;
	assert(
		strings::contains(text, "too large") ||
		strings::contains(text, "PARSE_ERROR") ||
		strings::contains(text, `"code":-32700`),
		"oversized request must be rejected with a transport error"
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
	// Find that request and reply with the limits override.
	let saw_config_request = false;
	for (let i = 0z; i < 20z && !saw_config_request; i += 1) {
		const body = recv(&s);
		defer free(body);
		const text = strings::fromutf8(body)!;
		if (strings::contains(text, `"method":"workspace/configuration"`)) {
			const id = extract_request_id(text);
			defer free(id);
			const reply =
				fmt::asprintf(
					`{{"jsonrpc":"2.0","id":{},"result":[{{"limits":{{"maxOpenDocuments":2}}}}]}}`,
					id)!;
			defer free(reply);
			send(&s, strings::toutf8(reply));
			saw_config_request = true;
		};
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

	// Read until we see the warning log (or time out).
	let saw_warning = false;
	for (let i = 0z; i < 20z; i += 1) {
		const body = recv(&s);
		defer free(body);
		const text = strings::fromutf8(body)!;
		if (strings::contains(text, "refusing to open") &&
		strings::contains(text, "file:///c.ha")) {
			saw_warning = true;
			break;
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

// Tiny extractor for a JSON-RPC `"id":NNN` integer field from a raw
// message string. Returns the value as a string so it can be
// re-substituted into a response template.
fn extract_request_id(text: str) str = {
	const needle = `"id":`;
	const start = match (strings::index(text, needle)) {
	case let i: size =>
		yield i + len(needle);
	case void =>
		return strings::dup("0")!;
	};
	const tail = strings::sub(text, start, strings::end);
	// IDs are emitted as bare numbers; consume digits.
	const bytes = strings::toutf8(tail);
	let end: size = 0;
	for (end < len(bytes); end += 1) {
		const b = bytes[end];
		if (b < '0': u8 || b > '9': u8) break;
	};
	return strings::dup(strings::sub(tail, 0, end))!;
};
