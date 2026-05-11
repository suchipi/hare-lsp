// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Hardening helpers. Cancellation checks, structured logging, and
// defensive validators that other handlers consult.

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
