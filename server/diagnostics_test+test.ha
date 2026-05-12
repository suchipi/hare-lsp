// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use bufio;
use bytes;
use encoding::json;
use io;
use lsp;
use memio;
use strconv;
use strings;

fn diag_test_server(

) (server, *bufio::scanner, *memio::stream, *memio::stream) = {
	let in_buf = alloc(memio::fixed([]))!;
	let scan = alloc(bufio::newscanner(in_buf))!;
	let out = alloc(memio::dynamic())!;
	let s = new(scan, out);
	return (s, scan, in_buf, out);
};

fn diag_test_cleanup(
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

// Reads the next LSP-framed message from `data`, returning the parsed body
// and the offset just past it. Aborts if the data isn't well-framed.
fn next_msg(data: []u8) (json::value, size) = {
	const sep = bytes::index(data, strings::toutf8("\r\n\r\n")) as size;
	const headers = strings::fromutf8(data[..sep])!;
	let length: size = 0;
	const lines = strings::split(headers, "\r\n")!;
	defer free(lines);
	for (let i = 0z; i < len(lines); i += 1) {
		const idx = strings::index(lines[i], ':') as size;
		const name = strings::sub(lines[i], 0, idx);
		const value = strings::trim(strings::sub(lines[i], idx + 1, strings::end));
		if (name == "Content-Length") {
			length = strconv::stoz(value)!;
		};
	};
	const body_start = sep + 4;
	const body = data[body_start..body_start + length];
	const v = json::loadstr(strings::fromutf8(body)!)!;
	return (v, body_start + length);
};

@test fn open_clean_file_publishes_empty_diagnostics() void = {
	let (s, scan, in_buf, out) = diag_test_server();
	defer diag_test_cleanup(&s, scan, in_buf, out);

	const open =
		`{"textDocument":{"uri":"file:///x.ha","languageId":"hare","version":1,"text":"export fn main() void = void;"}}`;
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

	const data = memio::buffer(out);
	const (v, _) = next_msg(data);
	defer json::finish(v);
	const o = v as json::object;
	assert(
		*(json::get(
			&o, "method",
		) as *json::value) as str == "textDocument/publishDiagnostics"
	);
	const params = *(json::get(&o, "params") as *json::value) as json::object;
	const diags =
		*(json::get(&params, "diagnostics") as *json::value) as []json::value;
	assert(len(diags) == 0);
};

@test fn open_broken_file_publishes_diagnostic() void = {
	let (s, scan, in_buf, out) = diag_test_server();
	defer diag_test_cleanup(&s, scan, in_buf, out);

	const open =
		`{"textDocument":{"uri":"file:///x.ha","languageId":"hare","version":1,"text":"export fn bad( = void;\n"}}`;
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

	const data = memio::buffer(out);
	const (v, _) = next_msg(data);
	defer json::finish(v);
	const params =
		*(json::get(&(v as json::object), "params") as *json::value) as json::object;
	const diags =
		*(json::get(&params, "diagnostics") as *json::value) as []json::value;
	assert(len(diags) >= 1);
	const d0 = diags[0] as json::object;
	assert(*(json::get(&d0, "severity") as *json::value) as f64 == 1.0);
	const src = *(json::get(&d0, "source") as *json::value) as str;
	assert(src == "hare-lsp/parse");
};

@test fn debounce_suppresses_rapid_changes() void = {
	let (s, scan, in_buf, out) = diag_test_server();
	defer diag_test_cleanup(&s, scan, in_buf, out);
	// Set a very large debounce so rapid changes coalesce.
	s.config.diagnostics_debounce_ms = 60000;

	// Open + change. The didOpen always publishes; the didChange is
	// inside the debounce window so it should NOT.
	const open =
		`{"textDocument":{"uri":"file:///x.ha","languageId":"hare","version":1,"text":"fn a() void = void;\n"}}`;
	let pv1 = json::loadstr(open)!;
	const n1 = lsp::notification {
		method = strings::dup("textDocument/didOpen")!,
		params = pv1,
	};
	defer {
		free(n1.method);
		json::finish(pv1);
	};
	handle_did_open(&s, n1);

	const change =
		`{"textDocument":{"uri":"file:///x.ha","version":2},"contentChanges":[{"text":"fn bad( = void;\n"}]}`;
	let pv2 = json::loadstr(change)!;
	const n2 = lsp::notification {
		method = strings::dup("textDocument/didChange")!,
		params = pv2,
	};
	defer {
		free(n2.method);
		json::finish(pv2);
	};
	handle_did_change(&s, n2);

	// Count publishDiagnostics notifications: should be exactly 1
	// (the didOpen).
	const data = memio::buffer(out);
	let off = 0z;
	let publishes = 0z;
	for (off < len(data)) {
		const (v, n) = next_msg(data[off..]);
		defer json::finish(v);
		const obj = v as json::object;
		match (json::get(&obj, "method")) {
		case let p: *json::value =>
			match (*p) {
			case let m: str =>
				if (m == "textDocument/publishDiagnostics") {
					publishes += 1;
				};
			case => void;
			};
		case => void;
		};
		off += n;
	};
	assert(publishes == 1);
	// And the document is marked as having pending diagnostics.
	const doc = match (find_document(&s, "file:///x.ha")) {
	case let p: *document =>
		yield p;
	case null => abort("doc missing");
	};
	assert(doc.diagnostics_pending);
};

@test fn changing_to_broken_publishes_diagnostic() void = {
	let (s, scan, in_buf, out) = diag_test_server();
	defer diag_test_cleanup(&s, scan, in_buf, out);
	// Disable debounce so didChange publishes immediately.
	s.config.diagnostics_debounce_ms = 0;

	// Open a clean file.
	const open =
		`{"textDocument":{"uri":"file:///x.ha","languageId":"hare","version":1,"text":"export fn main() void = void;\n"}}`;
	let pv1 = json::loadstr(open)!;
	const n1 = lsp::notification {
		method = strings::dup("textDocument/didOpen")!,
		params = pv1,
	};
	defer {
		free(n1.method);
		json::finish(pv1);
	};
	handle_did_open(&s, n1);

	// Replace it with broken code.
	const change =
		`{"textDocument":{"uri":"file:///x.ha","version":2},"contentChanges":[{"text":"export fn bad( = void;\n"}]}`;
	let pv2 = json::loadstr(change)!;
	const n2 = lsp::notification {
		method = strings::dup("textDocument/didChange")!,
		params = pv2,
	};
	defer {
		free(n2.method);
		json::finish(pv2);
	};
	handle_did_change(&s, n2);

	// Walk through the messages: first didOpen's diagnostics (empty), then
	// didChange's diagnostics (non-empty).
	const data = memio::buffer(out);
	const (v1, off1) = next_msg(data);
	defer json::finish(v1);
	const p1 =
		*(json::get(&(v1 as json::object), "params") as *json::value) as json::object;
	const d1 = *(json::get(&p1, "diagnostics") as *json::value) as []json::value;
	assert(len(d1) == 0);

	const (v2, _) = next_msg(data[off1..]);
	defer json::finish(v2);
	const p2 =
		*(json::get(&(v2 as json::object), "params") as *json::value) as json::object;
	const d2 = *(json::get(&p2, "diagnostics") as *json::value) as []json::value;
	assert(len(d2) >= 1);
};

@test fn unused_import_emits_hint_diagnostic_with_data() void = {
	let (s, scan, in_buf, out) = diag_test_server();
	defer diag_test_cleanup(&s, scan, in_buf, out);

	// One unused import, no parse errors. Should emit exactly one
	// diagnostic: the unused-import hint.
	const open =
		`{"textDocument":{"uri":"file:///ui.ha","languageId":"hare","version":1,"text":"use foo;\nfn x() void = void;\n"}}`;
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

	const data = memio::buffer(out);
	const (v, _) = next_msg(data);
	defer json::finish(v);
	const params =
		*(json::get(&(v as json::object), "params") as *json::value) as json::object;
	const diags =
		*(json::get(&params, "diagnostics") as *json::value) as []json::value;
	assert(len(diags) == 1);
	const d0 = diags[0] as json::object;
	const code = *(json::get(&d0, "code") as *json::value) as str;
	assert(code == "unused-import");
	const severity = *(json::get(&d0, "severity") as *json::value) as f64;
	assert(severity == 4.0);
	const tags = *(json::get(&d0, "tags") as *json::value) as []json::value;
	assert(len(tags) == 1);
	assert(tags[0] as f64 == 1.0);
	const data_obj = *(json::get(&d0, "data") as *json::value) as json::object;
	const kind = *(json::get(&data_obj, "kind") as *json::value) as str;
	assert(kind == "unused-import");
	const import_idx =
		*(json::get(&data_obj, "import_idx") as *json::value) as f64;
	assert(import_idx == 0.0);
};

@test fn close_clears_diagnostics() void = {
	let (s, scan, in_buf, out) = diag_test_server();
	defer diag_test_cleanup(&s, scan, in_buf, out);

	const open =
		`{"textDocument":{"uri":"file:///x.ha","languageId":"hare","version":1,"text":"export fn bad( = void;\n"}}`;
	let pv1 = json::loadstr(open)!;
	const n1 = lsp::notification {
		method = strings::dup("textDocument/didOpen")!,
		params = pv1,
	};
	defer {
		free(n1.method);
		json::finish(pv1);
	};
	handle_did_open(&s, n1);

	const close = `{"textDocument":{"uri":"file:///x.ha"}}`;
	let pv2 = json::loadstr(close)!;
	const n2 = lsp::notification {
		method = strings::dup("textDocument/didClose")!,
		params = pv2,
	};
	defer {
		free(n2.method);
		json::finish(pv2);
	};
	handle_did_close(&s, n2);

	// Two messages emitted: open diagnostics, then close (empty diagnostics).
	const data = memio::buffer(out);
	const (v1, off1) = next_msg(data);
	defer json::finish(v1);
	// Skip past it.
	const (v2, _) = next_msg(data[off1..]);
	defer json::finish(v2);
	const p2 =
		*(json::get(&(v2 as json::object), "params") as *json::value) as json::object;
	const d2 = *(json::get(&p2, "diagnostics") as *json::value) as []json::value;
	assert(len(d2) == 0);
};
