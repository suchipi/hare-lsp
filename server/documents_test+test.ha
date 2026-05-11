// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use analysis;
use bufio;
use encoding::json;
use io;
use lsp;
use memio;
use strings;

fn doc_test_server() (server, *bufio::scanner, *memio::stream, *memio::stream) = {
	let in_buf = alloc(memio::fixed([]))!;
	let scan = alloc(bufio::newscanner(in_buf))!;
	let out = alloc(memio::dynamic())!;
	let s = new(scan, out);
	return (s, scan, in_buf, out);
};

fn doc_test_cleanup(s: *server, scan: *bufio::scanner, in_buf: *memio::stream, out: *memio::stream) void = {
	finish(s);
	bufio::finish(scan);
	free(scan);
	free(in_buf);
	io::close(out)!;
	free(out);
};

fn make_notification(method: str, params_json: str) (lsp::notification, json::value) = {
	let pv = json::loadstr(params_json)!;
	const n = lsp::notification {
		method = strings::dup(method)!,
		params = pv,
	};
	return (n, pv);
};

fn finish_notification(n: lsp::notification, pv: json::value) void = {
	free(n.method);
	json::finish(pv);
};

@test fn did_open_creates_document() void = {
	let (s, scan, in_buf, out) = doc_test_server();
	defer doc_test_cleanup(&s, scan, in_buf, out);

	const params = `{"textDocument":{"uri":"file:///x.ha","languageId":"hare","version":1,"text":"export fn main() void = void;"}}`;
	const (n, pv) = make_notification("textDocument/didOpen", params);
	defer finish_notification(n, pv);

	handle_did_open(&s, n);
	const doc = match (find_document(&s, "file:///x.ha")) {
	case let p: *document => yield p;
	case null => abort("expected document");
	};
	assert(doc.version == 1);
	assert(doc.language_id == "hare");
	assert(analysis::as_string(&doc.buf) == "export fn main() void = void;");
};

@test fn did_change_full_replaces_buffer() void = {
	let (s, scan, in_buf, out) = doc_test_server();
	defer doc_test_cleanup(&s, scan, in_buf, out);

	const open = `{"textDocument":{"uri":"file:///x.ha","languageId":"hare","version":1,"text":"old"}}`;
	const (n1, pv1) = make_notification("textDocument/didOpen", open);
	defer finish_notification(n1, pv1);
	handle_did_open(&s, n1);

	const change = `{"textDocument":{"uri":"file:///x.ha","version":2},"contentChanges":[{"text":"new content"}]}`;
	const (n2, pv2) = make_notification("textDocument/didChange", change);
	defer finish_notification(n2, pv2);
	handle_did_change(&s, n2);

	const doc = find_document(&s, "file:///x.ha") as *document;
	assert(doc.version == 2);
	assert(analysis::as_string(&doc.buf) == "new content");
};

@test fn did_change_range_edit() void = {
	let (s, scan, in_buf, out) = doc_test_server();
	defer doc_test_cleanup(&s, scan, in_buf, out);

	const open = `{"textDocument":{"uri":"file:///x.ha","languageId":"hare","version":1,"text":"hello world"}}`;
	const (n1, pv1) = make_notification("textDocument/didOpen", open);
	defer finish_notification(n1, pv1);
	handle_did_open(&s, n1);

	// Replace "world" (line 0, chars 6..11) with "there".
	const change = `{"textDocument":{"uri":"file:///x.ha","version":2},"contentChanges":[{"range":{"start":{"line":0,"character":6},"end":{"line":0,"character":11}},"text":"there"}]}`;
	const (n2, pv2) = make_notification("textDocument/didChange", change);
	defer finish_notification(n2, pv2);
	handle_did_change(&s, n2);

	const doc = find_document(&s, "file:///x.ha") as *document;
	assert(analysis::as_string(&doc.buf) == "hello there");
};

@test fn did_change_multiple_edits_apply_in_order() void = {
	let (s, scan, in_buf, out) = doc_test_server();
	defer doc_test_cleanup(&s, scan, in_buf, out);

	const open = `{"textDocument":{"uri":"file:///x.ha","languageId":"hare","version":1,"text":"abcdef"}}`;
	const (n1, pv1) = make_notification("textDocument/didOpen", open);
	defer finish_notification(n1, pv1);
	handle_did_open(&s, n1);

	// Two edits: insert "X" at 0, then insert "Y" at end.
	// After first edit: "Xabcdef" (len 7), so end-after-edit-1 is char 7.
	const change = `{"textDocument":{"uri":"file:///x.ha","version":2},"contentChanges":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"text":"X"},{"range":{"start":{"line":0,"character":7},"end":{"line":0,"character":7}},"text":"Y"}]}`;
	const (n2, pv2) = make_notification("textDocument/didChange", change);
	defer finish_notification(n2, pv2);
	handle_did_change(&s, n2);

	const doc = find_document(&s, "file:///x.ha") as *document;
	assert(analysis::as_string(&doc.buf) == "XabcdefY");
};

@test fn did_close_removes_document() void = {
	let (s, scan, in_buf, out) = doc_test_server();
	defer doc_test_cleanup(&s, scan, in_buf, out);

	const open = `{"textDocument":{"uri":"file:///x.ha","languageId":"hare","version":1,"text":"x"}}`;
	const (n1, pv1) = make_notification("textDocument/didOpen", open);
	defer finish_notification(n1, pv1);
	handle_did_open(&s, n1);
	assert(has_document(&s, "file:///x.ha"));

	const close = `{"textDocument":{"uri":"file:///x.ha"}}`;
	const (n2, pv2) = make_notification("textDocument/didClose", close);
	defer finish_notification(n2, pv2);
	handle_did_close(&s, n2);
	assert(!has_document(&s, "file:///x.ha"));
};

@test fn did_save_with_text_replaces_buffer() void = {
	let (s, scan, in_buf, out) = doc_test_server();
	defer doc_test_cleanup(&s, scan, in_buf, out);

	const open = `{"textDocument":{"uri":"file:///x.ha","languageId":"hare","version":1,"text":"old"}}`;
	const (n1, pv1) = make_notification("textDocument/didOpen", open);
	defer finish_notification(n1, pv1);
	handle_did_open(&s, n1);

	const save = `{"textDocument":{"uri":"file:///x.ha"},"text":"saved"}`;
	const (n2, pv2) = make_notification("textDocument/didSave", save);
	defer finish_notification(n2, pv2);
	handle_did_save(&s, n2);

	const doc = find_document(&s, "file:///x.ha") as *document;
	assert(analysis::as_string(&doc.buf) == "saved");
};

@test fn did_change_unknown_uri_dropped() void = {
	let (s, scan, in_buf, out) = doc_test_server();
	defer doc_test_cleanup(&s, scan, in_buf, out);

	const change = `{"textDocument":{"uri":"file:///nope.ha","version":1},"contentChanges":[{"text":"x"}]}`;
	const (n, pv) = make_notification("textDocument/didChange", change);
	defer finish_notification(n, pv);
	handle_did_change(&s, n);
	// No document should be created.
	assert(!has_document(&s, "file:///nope.ha"));
};

@test fn did_open_replaces_existing_document() void = {
	let (s, scan, in_buf, out) = doc_test_server();
	defer doc_test_cleanup(&s, scan, in_buf, out);

	const open1 = `{"textDocument":{"uri":"file:///x.ha","languageId":"hare","version":1,"text":"first"}}`;
	const (n1, pv1) = make_notification("textDocument/didOpen", open1);
	defer finish_notification(n1, pv1);
	handle_did_open(&s, n1);

	const open2 = `{"textDocument":{"uri":"file:///x.ha","languageId":"hare","version":2,"text":"second"}}`;
	const (n2, pv2) = make_notification("textDocument/didOpen", open2);
	defer finish_notification(n2, pv2);
	handle_did_open(&s, n2);

	const doc = find_document(&s, "file:///x.ha") as *document;
	assert(doc.version == 2);
	assert(analysis::as_string(&doc.buf) == "second");
	assert(len(s.documents) == 1);
};

@test fn parse_cache_reuses_until_buffer_mutates() void = {
	let (s, scan, in_buf, out) = doc_test_server();
	defer doc_test_cleanup(&s, scan, in_buf, out);

	const open = `{"textDocument":{"uri":"file:///x.ha","languageId":"hare","version":1,"text":"fn a() void = void;\n"}}`;
	const (n, pv) = make_notification("textDocument/didOpen", open);
	defer finish_notification(n, pv);
	handle_did_open(&s, n);

	const doc = find_document(&s, "file:///x.ha") as *document;
	// After didOpen, parse_cache should already be populated (refresh
	// diagnostics built it).
	assert(doc.parse_cache is *parse_cache_entry);

	// Multiple parse_of calls without mutation reuse the same entry —
	// confirm by snapshotting the address and asserting it's unchanged.
	const c1 = parse_of(doc);
	const c1_addr = c1: uintptr;
	const c2 = parse_of(doc);
	assert(c2: uintptr == c1_addr);
	const c3 = parse_of(doc);
	assert(c3: uintptr == c1_addr);

	// A buffer-replacing edit invalidates the cache.
	const change = `{"textDocument":{"uri":"file:///x.ha","version":2},"contentChanges":[{"text":"fn b() void = void;\n"}]}`;
	const (cn, cpv) = make_notification("textDocument/didChange", change);
	defer finish_notification(cn, cpv);
	handle_did_change(&s, cn);

	// After the edit, the cache should reflect the new buffer. The
	// pointer address may or may not be reused by the allocator, but
	// the indexed symbol name should now be "b", not "a".
	const c4 = parse_of(doc);
	assert(len(c4.idx.symbols) >= 1);
	assert(c4.idx.symbols[0].short_name == "b");
};
