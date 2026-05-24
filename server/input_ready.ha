// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Non-blocking "is the next lsp::read going to make progress?" check, used
// by the main loop to drive workspace-index batches while the client is
// silent. See [[run]] in server.ha.

use bufio;
use io;
use time;
use unix::poll;

// Returns true if the next [[lsp::read]] call can make progress without
// blocking on I/O. Checks the scanner's read-ahead buffer first; only if
// that's empty does it poll the underlying fd with a zero-timeout so the
// check itself never blocks.
//
// When `s.poll_fd` is `void` (no pollable fd, e.g. tests using memio
// handles), returns true so the caller falls straight through to the
// blocking [[lsp::read]] - matching the pre-poll behavior.
//
// `POLLHUP`/`POLLERR` count toward the readiness signal, so a peer
// disconnect or fd error also causes the caller to exit the drain loop
// and let [[lsp::read]] surface the EOF or transport error through the
// normal path.
//
// @param s: borrowed
fn input_ready(s: *server) bool = {
	if (len(bufio::scan_buffer(s.reader.src)) > 0) return true;
	const fd = match (s.poll_fd) {
	case let f: io::file =>
		yield f;
	case void =>
		return true;
	};
	let fds: [1]poll::pollfd = [
		poll::pollfd {
			fd = fd,
			events = poll::event::POLLIN,
			revents = 0,
		},
	];
	match (poll::poll(fds, poll::NONBLOCK)) {
	case let n: uint =>
		return n > 0;
	case poll::error =>
		return true;
	};
};

// Like [[input_ready]] but waits up to `timeout_ms` for the next
// [[lsp::read]] to make progress. Used by the main loop to bound how
// long it blocks when a trailing-flush debounce window is pending so
// the publish fires even if no further LSP message arrives. Returns
// true if input becomes ready within the window, false on timeout.
//
// `POLLHUP`/`POLLERR` count as readiness for the same reason as in
// [[input_ready]]: let the caller fall through to [[lsp::read]] which
// surfaces the EOF or transport error through the normal path.
//
// When `s.poll_fd` is `void` (memio-backed tests), returns true
// immediately so the caller falls straight through to the blocking
// [[lsp::read]] - preserves current test behavior.
//
// @param s: borrowed
fn input_ready_within(s: *server, timeout_ms: i64) bool = {
	if (len(bufio::scan_buffer(s.reader.src)) > 0) return true;
	const fd = match (s.poll_fd) {
	case let f: io::file =>
		yield f;
	case void =>
		return true;
	};
	let fds: [1]poll::pollfd = [
		poll::pollfd {
			fd = fd,
			events = poll::event::POLLIN,
			revents = 0,
		},
	];
	const timeout: time::duration = if (timeout_ms <= 0) {
		yield poll::NONBLOCK;
	} else {
		yield timeout_ms * time::MILLISECOND;
	};
	match (poll::poll(fds, timeout)) {
	case let n: uint =>
		return n > 0;
	case poll::error =>
		return true;
	};
};
