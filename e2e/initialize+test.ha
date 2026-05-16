// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// End-to-end tests: spawn the real binary and walk through the LSP
// initialize/shutdown handshake. The buffering regression in
// `cmd/hare_lsp/main.ha` (commit c6a) was invisible to unit tests because
// they wrote to a memio sink; only a real OS pipe surfaces it.

use encoding::json;
use fmt;
use os::exec;
use strings;
use time;

// The minimum valid initialize message that exercises the server's response
// path. Uses a numeric id (1) — vscode-languageclient and most modern clients
// use numbers. String ids are exercised separately by the pre-init gating
// test in lifecycle+test.ha.
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
	const caps = field(&result, "capabilities") as json::object;

	// Capabilities clients gate their feature requests on. Without these
	// advertised, the editor silently disables the corresponding feature,
	// so a regression that produces an empty capabilities object would
	// look healthy on the wire while breaking every IDE interaction.
	assert(
		has_field(&caps, "textDocumentSync"),
		"capabilities must advertise textDocumentSync"
	);
	assert(
		has_field(&caps, "hoverProvider"),
		"capabilities must advertise hoverProvider"
	);
	assert(
		has_field(&caps, "definitionProvider"),
		"capabilities must advertise definitionProvider"
	);
	assert(
		has_field(&caps, "referencesProvider"),
		"capabilities must advertise referencesProvider"
	);
	assert(
		has_field(&caps, "completionProvider"),
		"capabilities must advertise completionProvider"
	);
	assert(
		has_field(&caps, "documentSymbolProvider"),
		"capabilities must advertise documentSymbolProvider"
	);
	assert(
		has_field(&caps, "documentFormattingProvider"),
		"capabilities must advertise documentFormattingProvider"
	);
	assert(
		has_field(&caps, "diagnosticProvider"),
		"capabilities must advertise diagnosticProvider"
	);

	const info = field(&result, "serverInfo") as json::object;
	const name = field(&info, "name") as str;
	assert(name == "hare-lsp", "serverInfo.name must be hare-lsp");
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

	// shutdown request — per LSP spec the server must reply with the
	// request's id and a null result.
	send(&s, strings::toutf8(`{"jsonrpc":"2.0","id":2,"method":"shutdown"}`));
	const body = wait_for_response(&s, 2.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	assert(
		field(&obj, "id") as f64 == 2.0,
		"shutdown response id must match request id"
	);
	match (field(&obj, "result")) {
	case json::_null => void;
	case =>
		fmt::fatalf("shutdown response result must be null, got: {}", text);
	};
	assert(!has_field(&obj, "error"), "shutdown response must not carry an error");

	// exit notification — server should terminate with exit code 0
	// because shutdown was sent first.
	send(&s, strings::toutf8(`{"jsonrpc":"2.0","method":"exit"}`));
	assert_clean_exit(&s, 2 * time::SECOND);
};

// Send a non-`exit` request after `shutdown` and confirm the server
// rejects it per the SHUTTING_DOWN gate (server/server.ha:370-372).
@test fn e2e_initialize_post_shutdown_request_is_rejected() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s, strings::toutf8(MINIMAL_INITIALIZE));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	send(&s, strings::toutf8(`{"jsonrpc":"2.0","id":2,"method":"shutdown"}`));
	free(wait_for_response(&s, 2.0));

	// A request issued after shutdown must come back as INVALID_REQUEST
	// (-32600) rather than be served.
	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///x.ha"},"position":{"line":0,"character":0}}}`
		));
	const body = wait_for_response(&s, 3.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const err = field(&obj, "error") as json::object;
	const code = field(&err, "code") as f64;
	assert(
		code == -32600.0,
		"post-shutdown request must be rejected with InvalidRequest"
	);

	send(&s, strings::toutf8(`{"jsonrpc":"2.0","method":"exit"}`));
};

// Polls `exec::peek` until the child exits or `total` elapses. Fails the
// test if the process is still running at the deadline or if it terminated
// with a non-zero exit status (i.e. exit code != 0 or killed by signal).
fn assert_clean_exit(s: *session, total: time::duration) void = {
	const deadline = time::add(time::now(time::clock::MONOTONIC), total);
	for (true) {
		let st = exec::peek(&s.proc);
		match (st) {
		case let st: exec::status =>
			match (exec::check(&st)) {
			case void =>
				return;
			case !exec::exit_status =>
				const summary = exec::exitstr(exec::exit(&st));
				fmt::fatalf("e2e: server exited uncleanly after `exit`: {}", summary);
			};
		case void => void;
		case exec::error => void;
		// peek errored (e.g. ECHILD) — treat as still running.

		};
		if (time::compare(time::now(time::clock::MONOTONIC), deadline) >= 0) {
			fmt::fatalf("e2e: server did not exit within {} ms of `exit`",
				total / time::MILLISECOND);
		};
		time::sleep(20 * time::MILLISECOND);
	};
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
			// Server-initiated requests share the JSON-RPC `id` field
			// with our client-side request ids but always carry a
			// `method`. The id namespaces are independent per LSP, so
			// gate on the *response* shape (no method, has result/error)
			// to avoid accidentally matching a server request that
			// happens to use the same numeric id.
			yield match (json::get(&obj, "method")) {
			case *json::value =>
				yield false;
			case void =>
				yield match (json::get(&obj, "id")) {
				case let p: *json::value =>
					yield match (*p) {
					case let n: f64 =>
						yield n == id;
					case =>
						yield false;
					};
				case void =>
					yield false;
				};
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
