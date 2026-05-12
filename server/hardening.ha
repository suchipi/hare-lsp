// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Hardening helpers. Cancellation checks, structured logging, and
// defensive validators that other handlers consult.

use fmt;
use lsp;

// Returns true if the given client request id has been cancelled. Long-
// running handlers should poll this between work units and bail with
// REQUEST_CANCELLED if it returns true.
export fn is_cancelled(s: *server, id: lsp::id) bool = {
	for (let i = 0z; i < len(s.cancelled_ids); i += 1) {
		if (id_eq(s.cancelled_ids[i], id)) return true;
	};
	return false;
};

fn id_eq(a: lsp::id, b: lsp::id) bool = {
	match (a) {
	case let af: f64 =>
		match (b) {
		case let bf: f64 => return af == bf;
		case => return false;
		};
	case let as_: str =>
		match (b) {
		case let bs: str => return as_ == bs;
		case => return false;
		};
	};
};

// Drops a previously-recorded cancellation so the slot can be reused.
// Called by handlers when they detect cancellation and have already
// responded with REQUEST_CANCELLED.
export fn clear_cancellation(s: *server, id: lsp::id) void = {
	let i = 0z;
	for (i < len(s.cancelled_ids)) {
		if (id_eq(s.cancelled_ids[i], id)) {
			match (s.cancelled_ids[i]) {
			case let str_id: str =>
				free(str_id);
			case f64 => void;
			};
			delete(s.cancelled_ids[i]);
		} else {
			i += 1;
		};
	};
};

// Sends a REQUEST_CANCELLED error response. Convenience wrapper.
export fn send_cancelled(s: *server, id: lsp::id) void = {
	const err = lsp::response_error {
		code = lsp::REQUEST_CANCELLED,
		message = "request cancelled",
		data = void,
	};
	match (lsp::encode_response_error(s.out, id, err)) {
	case size => void;
	case => void;
	};
};

// Polled by long-running handlers between work units. Returns true and
// short-circuits the handler (response + cleanup) when the client has
// cancelled the request; returns false otherwise.
export fn check_cancel(s: *server, id: lsp::id) bool = {
	if (!is_cancelled(s, id)) return false;
	send_cancelled(s, id);
	clear_cancellation(s, id);
	return true;
};

// Records a client-requested cancellation. Bounded by [[MAX_CANCELLED_IDS]]:
// when full, the oldest entry is dropped so a client that cancels phantom
// ids cannot grow the slice without bound.
export fn record_cancellation(s: *server, id: lsp::id) void = {
	for (let i = 0z; i < len(s.cancelled_ids); i += 1) {
		if (id_eq(s.cancelled_ids[i], id)) {
			// Already recorded; if id was a fresh string-id
			// allocation, free it to avoid leaking.
			match (id) {
			case let str_id: str =>
				free(str_id);
			case f64 => void;
			};
			return;
		};
	};
	if (len(s.cancelled_ids) >= s.config.limits.max_cancelled_ids) {
		match (s.cancelled_ids[0]) {
		case let str_id: str =>
			free(str_id);
		case f64 => void;
		};
		delete(s.cancelled_ids[0]);
	};
	append(s.cancelled_ids, id)!;
};

// Reports a malformed request: replies with INVALID_PARAMS so the client
// sees a concrete error instead of silence. `detail` is included in the
// human-readable message.
export fn reject_invalid_request(s: *server, id: lsp::id, method: str, detail: str) void = {
	const msg = fmt::asprintf("{}: {}", method, detail)!;
	defer free(msg);
	const err = lsp::response_error {
		code = lsp::INVALID_PARAMS,
		message = msg,
		data = void,
	};
	match (lsp::encode_response_error(s.out, id, err)) {
	case size => void;
	case => void;
	};
};

// Reports a malformed notification by logging to the client (notifications
// have no response channel). Warning level so editors surface it without
// being noisy.
export fn warn_invalid_notification(s: *server, method: str, detail: str) void = {
	const msg = fmt::asprintf("{}: {}", method, detail)!;
	defer free(msg);
	log_warning(s, msg);
};
