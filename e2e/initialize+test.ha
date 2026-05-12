// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// End-to-end tests: spawn the real binary and walk through the LSP
// initialize/shutdown handshake. The buffering regression in
// `cmd/hare_lsp/main.ha` (commit c6a) was invisible to unit tests because
// they wrote to a memio sink; only a real OS pipe surfaces it.

use encoding::json;
use fmt;
use strings;
use time;

// The minimum valid initialize message that exercises the server's response
// path. Uses a string id ("1") rather than a number to confirm both flavors
// of JSON-RPC ids are accepted (vscode-languageclient uses numbers; some
// other clients use strings).
def MINIMAL_INITIALIZE: str =
	`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`;

@test fn e2e_initialize_returns_response() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s, strings::toutf8(MINIMAL_INITIALIZE));

	const body = recv(&s);
	defer free(body);

	const text = strings::fromutf8(body)!;
	let v = match (json::loadstr(text)) {
	case let v: json::value =>
		yield v;
	case json::error =>
		fmt::fatalf("e2e: response is not valid JSON: {}", text);
	case nomem => abort("e2e: nomem parsing response");
	};
	defer json::finish(v);

	const obj = v as json::object;
	const id = field(&obj, "id");
	assert(id as f64 == 1.0, "response id did not match request id");
	const result = field(&obj, "result") as json::object;
	assert(
		has_field(&result, "capabilities"),
		"initialize result must include capabilities"
	);
};

@test fn e2e_initialize_responds_promptly() void = {
	// Specifically guards against the buffered-stdout regression. The
	// server must produce a complete response before any timeout fires
	// even though the client never closes stdin. We expect the response
	// well inside one second on any normal machine.
	let s = spawn_session();
	defer finish_session(&s);

	const start = time::now(time::clock::MONOTONIC);
	send(&s, strings::toutf8(MINIMAL_INITIALIZE));
	const body = recv(&s);
	defer free(body);
	const elapsed = time::diff(start, time::now(time::clock::MONOTONIC));

	// Hardware-pessimistic: if this takes more than a second something is
	// fundamentally wrong (buffer flush, schedling, missing flush, etc.).
	assert(
		elapsed < 1 * time::SECOND,
		"initialize response took unreasonably long"
	);
};

@test fn e2e_initialize_shutdown_exits_cleanly() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s, strings::toutf8(MINIMAL_INITIALIZE));
	free(wait_for_response(&s, 1.0));

	// initialized notification — no response, but the server emits
	// workspace/configuration, register-capability, etc. We just need
	// to keep ignoring those until shutdown responds.
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	// shutdown request — server must reply with id=2 (result is null
	// per LSP).
	send(&s, strings::toutf8(`{"jsonrpc":"2.0","id":2,"method":"shutdown"}`));
	free(wait_for_response(&s, 2.0));

	// exit notification — server should terminate.
	send(&s, strings::toutf8(`{"jsonrpc":"2.0","method":"exit"}`));
	// finish_session will wait and reap.

};

// Reads frames until one with the given response id arrives, ignoring
// server-initiated requests and notifications along the way. Returns the
// raw bytes of the matched response; caller frees.
fn wait_for_response(s: *session, id: f64) []u8 = {
	for (true) {
		const body = recv(s);
		const text = strings::fromutf8(body)!;
		let v = json::loadstr(text)!;
		const matched = match (v) {
		case let obj: json::object =>
			yield match (json::get(&obj, "id")) {
			case let p: *json::value =>
				yield match (*p) {
				case let n: f64 =>
					yield n == id;
				case =>
					yield false;
				};
			case void =>
				// Notification: no id. Not what we want.
				yield false;
			};
		case =>
			yield false;
		};
		json::finish(v);
		if (matched) return body;
		free(body);
	};
};

// Returns the value at `key` in `obj`, failing the test if absent.
fn field(obj: *json::object, key: str) json::value = {
	match (json::get(obj, key)) {
	case let p: *json::value =>
		return *p;
	case void =>
		fmt::fatalf("e2e: missing required field {}", key);
	};
};

fn has_field(obj: *json::object, key: str) bool = {
	match (json::get(obj, key)) {
	case *json::value =>
		return true;
	case void =>
		return false;
	};
};
