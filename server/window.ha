// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Window/* and $/progress helpers. These are the primary substrate for logging
// and progress reporting used by every later feature.
//
// All functions in this module are best-effort: I/O errors writing to the
// client are logged to stderr but never propagated, since the server has no
// useful recovery path for a broken client connection mid-request — the next
// read attempt will surface the EOF and shut us down.

use encoding::json;
use fmt;
use io;
use lsp;

// --- window/logMessage -----------------------------------------------
// Sends a window/logMessage notification. Per LSP spec, type 1=Error, 2=Warning,
// 3=Info, 4=Log, 5=Debug. The client decides how to display it.
export fn log_message(s: *server, kind: lsp::message_type, msg: str) void = {
	const params = match (build_message_params(kind, msg)) {
	case let v: json::value =>
		yield v;
	case nomem =>
		slog_error(s, "window/logMessage: out of memory");
		return;
	};
	defer json::finish(params);
	send_notification(s, "window/logMessage", params);
};

// Convenience wrappers.
export fn log_error(s: *server, msg: str) void =
	log_message(s, lsp::message_type::ERROR, msg);

export fn log_warning(s: *server, msg: str) void =
	log_message(s, lsp::message_type::WARNING, msg);

export fn log_info(s: *server, msg: str) void =
	log_message(s, lsp::message_type::INFO, msg);

export fn log_debug(s: *server, msg: str) void =
	log_message(s, lsp::message_type::DEBUG, msg);

// --- window/showMessage ----------------------------------------------
// Sends a window/showMessage notification. Use sparingly — clients typically
// surface this as a UI toast/popup.
export fn show_message(s: *server, kind: lsp::message_type, msg: str) void = {
	const params = match (build_message_params(kind, msg)) {
	case let v: json::value =>
		yield v;
	case nomem =>
		slog_error(s, "window/showMessage: out of memory");
		return;
	};
	defer json::finish(params);
	send_notification(s, "window/showMessage", params);
};

// --- window/logTrace -------------------------------------------------
// Sends a $/logTrace notification at the requested verbosity. No-op when
// trace is OFF, regardless of the requested verbosity.
//
// `verbose` is included only when the client requested verbose tracing. Pass
// "" for verbose if you have nothing to add.
export fn log_trace(s: *server, message: str, verbose: str) void = {
	if (s.trace == lsp::trace_value::OFF) return;
	let p = json::newobject();
	defer json::finish(p);
	json::set(&p, "message", message: json::value)!;
	if (s.trace == lsp::trace_value::VERBOSE && len(verbose) > 0) {
		json::set(&p, "verbose", verbose: json::value)!;
	};
	send_notification(s, "$/logTrace", p);
};

// --- window/showMessageRequest ---------------------------------------
// Sends a window/showMessageRequest with the given actions. Returns the id of
// the outgoing request so the caller can correlate the eventual response, or
// void if the message could not be sent. The id is also remembered in the
// server's pending-request table.
export fn show_message_request(
	s: *server,
	kind: lsp::message_type,
	message: str,
	actions: []str,
) (i64 | void) = {
	const id = next_outgoing_id(s);
	let params = json::newobject();
	defer json::finish(params);
	json::put(&params, "type", kind: int: f64)!;
	json::set(&params, "message", message: json::value)!;
	if (len(actions) > 0) {
		let arr: []json::value = [];
		let arr_owned = true;
		defer if (arr_owned) {
			for (let i = 0z; i < len(arr); i += 1) {
				json::finish(arr[i]);
			};
			free(arr);
		};
		for (let i = 0z; i < len(actions); i += 1) {
			let item = json::newobject();
			json::set(&item, "title", actions[i]: json::value)!;
			append(arr, item: json::value)!;
		};
		// json::put transfers ownership of `arr` into params.
		json::put(&params, "actions", arr: json::value)!;
		arr_owned = false;
	};
	if (!send_request(s, id, "window/showMessageRequest", params)) {
		return void;
	};
	pending_remember(s, id, "window/showMessageRequest");
	return id;
};

// --- window/showDocument ---------------------------------------------
// Sends a window/showDocument request. Returns the request id or void on
// transport failure.
export fn show_document(
	s: *server,
	uri: str,
	external: bool,
	take_focus: bool,
) (i64 | void) = {
	const id = next_outgoing_id(s);
	let params = json::newobject();
	defer json::finish(params);
	json::set(&params, "uri", uri: json::value)!;
	json::put(&params, "external", external: json::value)!;
	json::put(&params, "takeFocus", take_focus: json::value)!;
	if (!send_request(s, id, "window/showDocument", params)) {
		return void;
	};
	pending_remember(s, id, "window/showDocument");
	return id;
};

// --- window/workDoneProgress/create + $/progress + cancel -----------
// Server-initiated work-done progress. Lifecycle:
//   1. progress_create(token) — request the client allocate a progress reporter
//   2. progress_begin/report/end — emit $/progress notifications
//   3. (optional) handle window/workDoneProgress/cancel from client to abort
//
// The token is a string chosen by the server; we use sequential numeric tokens
// rendered as strings.
export type progress_token = str;

// Reserves a fresh progress token and asks the client to create a progress
// reporter for it. Returns the token (caller must free with [[free]]) and the
// outgoing request id, or void on transport failure.
export fn progress_create(s: *server) ((progress_token, i64) | void) = {
	const token = fmt::asprintf("hare-lsp/{}", s.next_progress_token)!;
	s.next_progress_token += 1;
	const id = next_outgoing_id(s);
	let params = json::newobject();
	defer json::finish(params);
	json::set(&params, "token", token: json::value)!;
	if (!send_request(s, id, "window/workDoneProgress/create", params)) {
		free(token);
		return void;
	};
	pending_remember(s, id, "window/workDoneProgress/create");
	return (token, id);
};

// Begins a progress report. `title` is required; `message` and `percentage`
// are optional (pass "" / -1 to omit). `cancellable` advertises whether the
// client may cancel.
export fn progress_begin(
	s: *server,
	token: progress_token,
	title: str,
	message: str,
	percentage: int,
	cancellable: bool,
) void = {
	let v = json::newobject();
	defer json::finish(v);
	json::set(&v, "kind", "begin": json::value)!;
	json::set(&v, "title", title: json::value)!;
	if (len(message) > 0) {
		json::set(&v, "message", message: json::value)!;
	};
	if (percentage >= 0) {
		json::put(&v, "percentage", percentage: f64)!;
	};
	json::put(&v, "cancellable", cancellable: json::value)!;
	send_progress(s, token, v);
};

// Updates an in-progress report.
export fn progress_report(
	s: *server,
	token: progress_token,
	message: str,
	percentage: int,
) void = {
	let v = json::newobject();
	defer json::finish(v);
	json::set(&v, "kind", "report": json::value)!;
	if (len(message) > 0) {
		json::set(&v, "message", message: json::value)!;
	};
	if (percentage >= 0) {
		json::put(&v, "percentage", percentage: f64)!;
	};
	send_progress(s, token, v);
};

// Marks a progress operation as complete.
export fn progress_end(s: *server, token: progress_token, message: str) void = {
	let v = json::newobject();
	defer json::finish(v);
	json::set(&v, "kind", "end": json::value)!;
	if (len(message) > 0) {
		json::set(&v, "message", message: json::value)!;
	};
	send_progress(s, token, v);
};

fn send_progress(s: *server, token: progress_token, value: json::value) void = {
	let params = json::newobject();
	defer json::finish(params);
	json::set(&params, "token", token: json::value)!;
	// We need to give ownership of `value`'s contents to params, but
	// json::put takes ownership and finish would double-free. Use json::set
	// which dups; the cost is small and these are rare.
	json::set(&params, "value", value)!;
	send_notification(s, "$/progress", params);
};

// --- low-level helpers -----------------------------------------------
fn next_outgoing_id(s: *server) i64 = {
	const id = s.next_request_id;
	s.next_request_id += 1;
	return id;
};

// Sends a server-initiated request. Returns false if the transport write
// failed; the caller should treat this as fatal for that operation but the
// server itself remains running until it next reads from stdin.
fn send_request(s: *server, id: i64, method: str, params: json::value) bool = {
	match (lsp::encode_request(s.out, id: f64, method, params)) {
	case size =>
		return true;
	case let e: io::error =>
		slog_error(s, "send_request:", method, ":", io::strerror(e));
		return false;
	};
};

fn send_notification(s: *server, method: str, params: json::value) void = {
	match (lsp::encode_notification(s.out, method, params)) {
	case size => void;
	case let e: io::error =>
		slog_error(s, "send_notification:", method, ":", io::strerror(e));
	};
};

fn build_message_params(
	kind: lsp::message_type,
	msg: str,
) (json::value | nomem) = {
	let p = json::newobject();
	let ok = false;
	defer if (!ok) json::finish(p);
	json::put(&p, "type", kind: int: f64)?;
	json::set(&p, "message", msg: json::value)?;
	ok = true;
	return p;
};
