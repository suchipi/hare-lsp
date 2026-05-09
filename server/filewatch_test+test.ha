// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use bufio;
use encoding::json;
use io;
use lsp;
use memio;
use strings;

fn fw_test_server() (server, *bufio::scanner, *memio::stream, *memio::stream) = {
	let in_buf = alloc(memio::fixed([]))!;
	let scan = alloc(bufio::newscanner(in_buf))!;
	let out = alloc(memio::dynamic())!;
	let s = new(scan, out);
	return (s, scan, in_buf, out);
};

fn fw_test_cleanup(s: *server, scan: *bufio::scanner, in_buf: *memio::stream, out: *memio::stream) void = {
	finish(s);
	bufio::finish(scan);
	free(scan);
	free(in_buf);
	io::close(out)!;
	free(out);
};

@test fn register_file_watchers_records_pending() void = {
	let (s, scan, in_buf, out) = fw_test_server();
	defer fw_test_cleanup(&s, scan, in_buf, out);

	const id = register_file_watchers(&s);
	assert(id is i64);
	assert(len(s.pending_requests) == 1);
	assert(s.pending_requests[0].method == "client/registerCapability");
	assert(len(s.registrations) == 1);
	assert(s.registrations[0].method == "workspace/didChangeWatchedFiles");
};

@test fn did_rename_files_updates_open_document_uri() void = {
	let (s, scan, in_buf, out) = fw_test_server();
	defer fw_test_cleanup(&s, scan, in_buf, out);

	const open = `{"textDocument":{"uri":"file:///a.ha","languageId":"hare","version":1,"text":"export fn x() void = void;\n"}}`;
	let pv = json::loadstr(open)!;
	const n = lsp::notification {
		method = strings::dup("textDocument/didOpen")!,
		params = pv,
	};
	defer { free(n.method); json::finish(pv); };
	handle_did_open(&s, n);

	const rn = `{"files":[{"oldUri":"file:///a.ha","newUri":"file:///b.ha"}]}`;
	let rpv = json::loadstr(rn)!;
	const r = lsp::notification {
		method = strings::dup("workspace/didRenameFiles")!,
		params = rpv,
	};
	defer { free(r.method); json::finish(rpv); };
	handle_did_rename_files(&s, r);

	assert(!has_document(&s, "file:///a.ha"));
	assert(has_document(&s, "file:///b.ha"));
};

@test fn did_delete_files_closes_open_document() void = {
	let (s, scan, in_buf, out) = fw_test_server();
	defer fw_test_cleanup(&s, scan, in_buf, out);

	const open = `{"textDocument":{"uri":"file:///gone.ha","languageId":"hare","version":1,"text":""}}`;
	let pv = json::loadstr(open)!;
	const n = lsp::notification {
		method = strings::dup("textDocument/didOpen")!,
		params = pv,
	};
	defer { free(n.method); json::finish(pv); };
	handle_did_open(&s, n);
	assert(has_document(&s, "file:///gone.ha"));

	const dl = `{"files":[{"uri":"file:///gone.ha"}]}`;
	let dpv = json::loadstr(dl)!;
	const r = lsp::notification {
		method = strings::dup("workspace/didDeleteFiles")!,
		params = dpv,
	};
	defer { free(r.method); json::finish(dpv); };
	handle_did_delete_files(&s, r);
	assert(!has_document(&s, "file:///gone.ha"));
};

@test fn did_change_watched_files_logs_when_trace_on() void = {
	let (s, scan, in_buf, out) = fw_test_server();
	defer fw_test_cleanup(&s, scan, in_buf, out);
	s.trace = lsp::trace_value::MESSAGES;

	const params = `{"changes":[{"uri":"file:///x.ha","type":2}]}`;
	let pv = json::loadstr(params)!;
	const n = lsp::notification {
		method = strings::dup("workspace/didChangeWatchedFiles")!,
		params = pv,
	};
	defer { free(n.method); json::finish(pv); };
	handle_did_change_watched_files(&s, n);

	// At least one $/logTrace notification should have been emitted.
	const data = memio::buffer(out);
	const text = strings::fromutf8(data)!;
	assert(strings::contains(text, "$/logTrace"));
	assert(strings::contains(text, "watched file changed"));
};
