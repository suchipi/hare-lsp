// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use analysis;
use bufio;
use encoding::json;
use io;
use lsp;
use memio;
use strings;

fn fw_test_server(

) (server, *bufio::scanner, *memio::stream, *memio::stream) = {
	let in_buf = alloc(memio::fixed([]))!;
	let scan = alloc(bufio::newscanner(in_buf))!;
	let out = alloc(memio::dynamic())!;
	let s = new(scan, out);
	return (s, scan, in_buf, out);
};

fn fw_test_cleanup(
	s: *server,
	scan: *bufio::scanner,
	in_buf: *memio::stream,
	out: *memio::stream,
) void = {
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

	const open =
		`{"textDocument":{"uri":"file:///a.ha","languageId":"hare","version":1,"text":"export fn x() void = void;\n"}}`;
	let pv = json::loadstr(open)!;
	const n = lsp::notification {
		method = strings::dup("textDocument/didOpen")!,
		params = pv,
	};
	defer {
		free(n.method);
		json::finish(pv);
	};
	handle_did_open(&s, n);

	const rn = `{"files":[{"oldUri":"file:///a.ha","newUri":"file:///b.ha"}]}`;
	let rpv = json::loadstr(rn)!;
	const r = lsp::notification {
		method = strings::dup("workspace/didRenameFiles")!,
		params = rpv,
	};
	defer {
		free(r.method);
		json::finish(rpv);
	};
	handle_did_rename_files(&s, r);

	assert(!has_document(&s, "file:///a.ha"));
	assert(has_document(&s, "file:///b.ha"));
};

@test fn did_delete_files_closes_open_document() void = {
	let (s, scan, in_buf, out) = fw_test_server();
	defer fw_test_cleanup(&s, scan, in_buf, out);

	const open =
		`{"textDocument":{"uri":"file:///gone.ha","languageId":"hare","version":1,"text":""}}`;
	let pv = json::loadstr(open)!;
	const n = lsp::notification {
		method = strings::dup("textDocument/didOpen")!,
		params = pv,
	};
	defer {
		free(n.method);
		json::finish(pv);
	};
	handle_did_open(&s, n);
	assert(has_document(&s, "file:///gone.ha"));

	const dl = `{"files":[{"uri":"file:///gone.ha"}]}`;
	let dpv = json::loadstr(dl)!;
	const r = lsp::notification {
		method = strings::dup("workspace/didDeleteFiles")!,
		params = dpv,
	};
	defer {
		free(r.method);
		json::finish(dpv);
	};
	handle_did_delete_files(&s, r);
	assert(!has_document(&s, "file:///gone.ha"));
};

// Regression: workspace/didDeleteFiles must drop workspace_index entries
// for the deleted path. Otherwise textDocument/references,
// workspace/symbol, and the call/type hierarchies keep reporting
// locations in a file the user has already removed. We can't rely on
// the file watcher's didChangeWatchedFiles event arriving - it can
// race with the file ops notification or be missing entirely when the
// client hasn't registered a watcher.
@test fn did_delete_files_drops_workspace_index_entry() void = {
	let (s, scan, in_buf, out) = fw_test_server();
	defer fw_test_cleanup(&s, scan, in_buf, out);

	analysis::index_file(&s.workspace_index,
		"/repo/refs_target.ha",
		strings::toutf8("export fn refs_target() void = void;\n"));
	assert(
		len(analysis::lookup_by_short_name(&s.workspace_index, "refs_target")) == 1
	);

	const dl = `{"files":[{"uri":"file:///repo/refs_target.ha"}]}`;
	let dpv = json::loadstr(dl)!;
	const r = lsp::notification {
		method = strings::dup("workspace/didDeleteFiles")!,
		params = dpv,
	};
	defer {
		free(r.method);
		json::finish(dpv);
	};
	handle_did_delete_files(&s, r);

	assert(
		len(analysis::lookup_by_short_name(&s.workspace_index, "refs_target")) == 0,
		"didDeleteFiles must drop the workspace_index entries"
	);
	for (let i = 0z; i < len(s.workspace_index.indexed_files); i += 1) {
		assert(
			s.workspace_index.indexed_files[i] != "/repo/refs_target.ha",
			"didDeleteFiles must drop the indexed_files path"
		);
	};
};

// Regression: a directory URI with a trailing slash
// (file:///repo/pkg/) decodes to a path ending in '/', which used to
// produce a "//" prefix that prefix-matched no real paths and left
// the index stale.
@test fn did_delete_files_handles_directory_uri_with_trailing_slash() void = {
	let (s, scan, in_buf, out) = fw_test_server();
	defer fw_test_cleanup(&s, scan, in_buf, out);

	analysis::index_file(&s.workspace_index,
		"/repo/pkg/a.ha", strings::toutf8("export fn trail_a() void = void;\n"));

	const dl = `{"files":[{"uri":"file:///repo/pkg/"}]}`;
	let dpv = json::loadstr(dl)!;
	const r = lsp::notification {
		method = strings::dup("workspace/didDeleteFiles")!,
		params = dpv,
	};
	defer {
		free(r.method);
		json::finish(dpv);
	};
	handle_did_delete_files(&s, r);

	assert(
		len(analysis::lookup_by_short_name(&s.workspace_index, "trail_a")) == 0,
		"trailing-slash directory URI must still drop entries under it"
	);
};

// Regression: clients may fold a directory delete into a single
// didDeleteFiles event whose URI names the deleted directory rather
// than each .ha file inside it. Drop every entry under that prefix.
@test fn did_delete_files_drops_entries_under_directory() void = {
	let (s, scan, in_buf, out) = fw_test_server();
	defer fw_test_cleanup(&s, scan, in_buf, out);

	analysis::index_file(&s.workspace_index,
		"/repo/pkg/a.ha", strings::toutf8("export fn pkg_a() void = void;\n"));
	analysis::index_file(&s.workspace_index,
		"/repo/pkg/b.ha", strings::toutf8("export fn pkg_b() void = void;\n"));
	analysis::index_file(&s.workspace_index,
		"/repo/other.ha", strings::toutf8("export fn other() void = void;\n"));

	const dl = `{"files":[{"uri":"file:///repo/pkg"}]}`;
	let dpv = json::loadstr(dl)!;
	const r = lsp::notification {
		method = strings::dup("workspace/didDeleteFiles")!,
		params = dpv,
	};
	defer {
		free(r.method);
		json::finish(dpv);
	};
	handle_did_delete_files(&s, r);

	assert(len(analysis::lookup_by_short_name(&s.workspace_index, "pkg_a")) == 0);
	assert(len(analysis::lookup_by_short_name(&s.workspace_index, "pkg_b")) == 0);
	// Sibling file outside the deleted dir must survive.
	assert(len(analysis::lookup_by_short_name(&s.workspace_index, "other")) == 1);
};

// Regression: the file watcher's glob includes `**/*.s`, so the LSP
// gets workspace/didChangeWatchedFiles events for the `.cache/*.o.tmp.s`
// assembly intermediates the Hare compiler leaves behind. Feeding any
// non-Hare bytes through the parser would crash the server (the bufio
// scanner's unread assertion or a downstream malloc bug). The handler
// must reject those URIs at the boundary.
@test fn workspace_handle_file_event_skips_non_hare() void = {
	// Cache scratch files: nope.
	assert(!is_indexable_path("/repo/.cache/abc.o.tmp.s"));
	assert(!is_indexable_path("/repo/.cache/abc.s"));
	// `.s` anywhere: nope (Hare's source set includes assembly, but we
	// don't index it).
	assert(!is_indexable_path("/repo/foo/bar.s"));
	// `.ha` files inside `.cache/` are also rejected: the compiler may
	// stage intermediates there in future versions.
	assert(!is_indexable_path("/repo/.cache/abc.ha"));
	// Real Hare files: yes.
	assert(is_indexable_path("/repo/foo.ha"));
	assert(is_indexable_path("/repo/server/build.ha"));
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
	defer {
		free(n.method);
		json::finish(pv);
	};
	handle_did_change_watched_files(&s, n);

	// At least one $/logTrace notification should have been emitted.
	const data = memio::buffer(out);
	const text = strings::fromutf8(data)!;
	assert(strings::contains(text, "$/logTrace"));
	assert(strings::contains(text, "watched file changed"));
};
