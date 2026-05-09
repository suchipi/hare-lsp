// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use bufio;
use io;
use lsp;
use memio;
use strings;

fn hard_test_server() (server, *bufio::scanner, *memio::stream, *memio::stream) = {
	let in_buf = alloc(memio::fixed([]))!;
	let scan = alloc(bufio::newscanner(in_buf))!;
	let out = alloc(memio::dynamic())!;
	let s = new(scan, out);
	return (s, scan, in_buf, out);
};

fn hard_test_cleanup(s: *server, scan: *bufio::scanner, in_buf: *memio::stream, out: *memio::stream) void = {
	finish(s);
	bufio::finish(scan);
	free(scan);
	free(in_buf);
	io::close(out)!;
	free(out);
};

@test fn is_cancelled_reports_after_cancel_request() void = {
	let (s, scan, in_buf, out) = hard_test_server();
	defer hard_test_cleanup(&s, scan, in_buf, out);
	const id: lsp::id = 42.0;
	assert(!is_cancelled(&s, id));
	append(s.cancelled_ids, id)!;
	assert(is_cancelled(&s, id));
};

@test fn clear_cancellation_drops_record() void = {
	let (s, scan, in_buf, out) = hard_test_server();
	defer hard_test_cleanup(&s, scan, in_buf, out);
	append(s.cancelled_ids, 1.0: lsp::id)!;
	append(s.cancelled_ids, 2.0: lsp::id)!;
	assert(len(s.cancelled_ids) == 2);
	clear_cancellation(&s, 1.0: lsp::id);
	assert(len(s.cancelled_ids) == 1);
	assert(is_cancelled(&s, 2.0: lsp::id));
};

@test fn is_cancelled_handles_string_ids() void = {
	let (s, scan, in_buf, out) = hard_test_server();
	defer hard_test_cleanup(&s, scan, in_buf, out);
	append(s.cancelled_ids, strings::dup("abc")!: lsp::id)!;
	assert(is_cancelled(&s, "abc": lsp::id));
	assert(!is_cancelled(&s, "xyz": lsp::id));
};
