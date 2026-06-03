// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use bufio;
use bytes;
use encoding::json;
use fmt;
use io;
use lsp;
use memio;
use strconv;
use strings;
use time;

fn diag_test_server(

) (server, *bufio::scanner, *memio::stream, *memio::stream) = {
	let in_buf = alloc(memio::fixed([]))!;
	let scan = alloc(bufio::newscanner(in_buf))!;
	let out = alloc(memio::dynamic())!;
	let s = new(scan, out, void);
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
		*(json::get(&o,
			"method") as *json::value) as str == "textDocument/publishDiagnostics"
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
		*(json::get(&(v as json::object),
			"params") as *json::value) as json::object;
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

@test fn trailing_flush_deadline_math() void = {
	let (s, scan, in_buf, out) = diag_test_server();
	defer diag_test_cleanup(&s, scan, in_buf, out);
	s.config.diagnostics_debounce_ms = 500;

	// No documents at all: nothing pending.
	assert(next_trailing_flush_deadline_ms(&s) is void);

	// Open a doc. didOpen publishes immediately and clears
	// diagnostics_pending, so still nothing pending.
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
	assert(next_trailing_flush_deadline_ms(&s) is void);

	const doc = match (find_document(&s, "file:///x.ha")) {
	case let p: *document =>
		yield p;
	case null => abort("doc missing");
	};

	// Pretend the last edit just happened: remaining should be very
	// close to the full 500ms window (allow some scheduler slack).
	doc.diagnostics_pending = true;
	doc.last_edit_at = time::now(time::clock::MONOTONIC);
	const remaining = match (next_trailing_flush_deadline_ms(&s)) {
	case let n: i64 =>
		yield n;
	case void => abort("expected pending doc to produce a deadline");
	};
	assert(remaining > 0);
	assert(remaining <= 500);

	// Push last_edit_at far enough into the past that the window has
	// already elapsed: should return 0.
	doc.last_edit_at = time::add(time::now(time::clock::MONOTONIC),
		-2 * time::SECOND);
	const elapsed = match (next_trailing_flush_deadline_ms(&s)) {
	case let n: i64 =>
		yield n;
	case void => abort("expected elapsed doc to produce a deadline");
	};
	assert(elapsed == 0);

	// Clearing the pending flag drops the doc out of the calculation.
	doc.diagnostics_pending = false;
	assert(next_trailing_flush_deadline_ms(&s) is void);
};

@test fn trailing_flush_deadline_picks_soonest_doc() void = {
	let (s, scan, in_buf, out) = diag_test_server();
	defer diag_test_cleanup(&s, scan, in_buf, out);
	s.config.diagnostics_debounce_ms = 1000;

	const open_a =
		`{"textDocument":{"uri":"file:///alpha.ha","languageId":"hare","version":1,"text":"fn a() void = void;\n"}}`;
	let pv_a = json::loadstr(open_a)!;
	const na = lsp::notification {
		method = strings::dup("textDocument/didOpen")!,
		params = pv_a,
	};
	defer {
		free(na.method);
		json::finish(pv_a);
	};
	handle_did_open(&s, na);

	const open_b =
		`{"textDocument":{"uri":"file:///beta.ha","languageId":"hare","version":1,"text":"fn b() void = void;\n"}}`;
	let pv_b = json::loadstr(open_b)!;
	const nb = lsp::notification {
		method = strings::dup("textDocument/didOpen")!,
		params = pv_b,
	};
	defer {
		free(nb.method);
		json::finish(pv_b);
	};
	handle_did_open(&s, nb);

	const doc_a = find_document(&s, "file:///alpha.ha") as *document;
	const doc_b = find_document(&s, "file:///beta.ha") as *document;

	const now = time::now(time::clock::MONOTONIC);
	// alpha was edited 900ms ago (100ms remain), beta was edited
	// 200ms ago (800ms remain). The minimum (100ms) wins.
	doc_a.diagnostics_pending = true;
	doc_a.last_edit_at = time::add(now, -900 * time::MILLISECOND);
	doc_b.diagnostics_pending = true;
	doc_b.last_edit_at = time::add(now, -200 * time::MILLISECOND);

	const earliest = match (next_trailing_flush_deadline_ms(&s)) {
	case let n: i64 =>
		yield n;
	case void => abort("expected pending docs to produce a deadline");
	};
	// Allow scheduler slack: should be well under 200ms.
	assert(earliest >= 0);
	assert(earliest < 200);
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
		*(json::get(&(v1 as json::object),
			"params") as *json::value) as json::object;
	const d1 = *(json::get(&p1, "diagnostics") as *json::value) as []json::value;
	assert(len(d1) == 0);

	const (v2, _) = next_msg(data[off1..]);
	defer json::finish(v2);
	const p2 =
		*(json::get(&(v2 as json::object),
			"params") as *json::value) as json::object;
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
		*(json::get(&(v as json::object),
			"params") as *json::value) as json::object;
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
		*(json::get(&(v2 as json::object),
			"params") as *json::value) as json::object;
	const d2 = *(json::get(&p2, "diagnostics") as *json::value) as []json::value;
	assert(len(d2) == 0);
};

// --- assemble_capped_diagnostics --------------------------------------
// Builds a synthetic diagnostic with the given `code` field so tests can
// tell which input slice each output entry came from.
fn mk_test_diag(code: str) json::value = {
	let d = json::newobject();
	let r = json::newobject();
	let p = json::newobject();
	json::put(&p, "line", 0.0)!;
	json::put(&p, "character", 0.0)!;
	json::put(&r, "start", p)!;
	let p2 = json::newobject();
	json::put(&p2, "line", 0.0)!;
	json::put(&p2, "character", 0.0)!;
	json::put(&r, "end", p2)!;
	json::put(&d, "range", r)!;
	json::put(&d, "severity", 1.0)!;
	json::set(&d, "code", code: json::value)!;
	json::set(&d, "message", code: json::value)!;
	return d: json::value;
};

fn mk_test_diag_slice(code: str, n: size) []json::value = {
	let out: []json::value = [];
	for (let i = 0z; i < n; i += 1) {
		append(out, mk_test_diag(code))!;
	};
	return out;
};

fn diag_code(v: json::value) str = {
	const o = v as json::object;
	return *(json::get(&o, "code") as *json::value) as str;
};

fn finish_diag_slice(arr: []json::value) void = {
	for (let i = 0z; i < len(arr); i += 1) {
		json::finish(arr[i]);
	};
	free(arr);
};

@test fn capped_diags_pass_through_under_cap() void = {
	const build = mk_test_diag_slice("b", 2);
	const unused = mk_test_diag_slice("u", 1);
	const parse = mk_test_diag_slice("p", 3);
	const out = assemble_capped_diagnostics(100, build, unused, parse,
		lsp::position { line = 0, character = 0 });
	defer finish_diag_slice(out);
	// Under-cap path returns everything in priority order: build,
	// then unused, then parse - no truncation marker.
	assert(len(out) == 6);
	assert(diag_code(out[0]) == "b");
	assert(diag_code(out[1]) == "b");
	assert(diag_code(out[2]) == "u");
	assert(diag_code(out[3]) == "p");
	assert(diag_code(out[4]) == "p");
	assert(diag_code(out[5]) == "p");
};

@test fn capped_diags_drops_parse_first() void = {
	// 2 build + 1 unused + 5 parse = 8 total; cap = 5.
	// Effective = 4. Build all kept (2). Unused all kept (1). Parse
	// gets remaining 1 slot. Marker appended in the 5th slot.
	// Dropped = 8 - 4 = 4 (the 4 parse errors that didn't fit).
	const build = mk_test_diag_slice("b", 2);
	const unused = mk_test_diag_slice("u", 1);
	const parse = mk_test_diag_slice("p", 5);
	const out = assemble_capped_diagnostics(5, build, unused, parse,
		lsp::position { line = 7, character = 0 });
	defer finish_diag_slice(out);
	assert(len(out) == 5);
	assert(diag_code(out[0]) == "b");
	assert(diag_code(out[1]) == "b");
	assert(diag_code(out[2]) == "u");
	assert(diag_code(out[3]) == "p");
	assert(diag_code(out[4]) == "diagnostics-truncated");
	const marker = out[4] as json::object;
	const msg = *(json::get(&marker, "message") as *json::value) as str;
	// 4 dropped, 4 of 8 reported.
	const want =
		fmt::asprintf("({} more diagnostics not shown; {} of {} reported)", 4u, 4u,
			8u)!;
	defer free(want);
	assert(msg == want, msg);
};

@test fn capped_diags_drops_unused_then_build_when_tight() void = {
	// 5 build + 3 unused + 2 parse = 10 total; cap = 4.
	// Effective = 3. Build takes 3, unused 0, parse 0. Marker fills
	// slot 4. Dropped = 7.
	const build = mk_test_diag_slice("b", 5);
	const unused = mk_test_diag_slice("u", 3);
	const parse = mk_test_diag_slice("p", 2);
	const out = assemble_capped_diagnostics(4, build, unused, parse,
		lsp::position { line = 0, character = 0 });
	defer finish_diag_slice(out);
	assert(len(out) == 4);
	assert(diag_code(out[0]) == "b");
	assert(diag_code(out[1]) == "b");
	assert(diag_code(out[2]) == "b");
	assert(diag_code(out[3]) == "diagnostics-truncated");
};

@test fn capped_diags_zero_cap_returns_empty() void = {
	const build = mk_test_diag_slice("b", 2);
	const unused = mk_test_diag_slice("u", 1);
	const parse = mk_test_diag_slice("p", 3);
	const out = assemble_capped_diagnostics(0, build, unused, parse,
		lsp::position { line = 0, character = 0 });
	defer finish_diag_slice(out);
	assert(len(out) == 0);
};

@test fn capped_diags_marker_counts_only_truncated() void = {
	// All-parse pathological case: 1000 parse errors, cap = 10. Should
	// keep 9 parse + marker; marker says 991 dropped, 9 of 1000.
	const parse = mk_test_diag_slice("p", 1000);
	const out = assemble_capped_diagnostics(10, [], [], parse,
		lsp::position { line = 0, character = 0 });
	defer finish_diag_slice(out);
	assert(len(out) == 10);
	assert(diag_code(out[9]) == "diagnostics-truncated");
	const marker = out[9] as json::object;
	const msg = *(json::get(&marker, "message") as *json::value) as str;
	const want =
		fmt::asprintf("({} more diagnostics not shown; {} of {} reported)", 991u,
			9u, 1000u)!;
	defer free(want);
	assert(msg == want, msg);
};

// End-to-end via the assembly entry point: open a file with parse and
// unused diagnostics, set a tight cap, and check the published list
// honours the priority order and shape.
@test fn publish_respects_max_diagnostics_per_file_cap() void = {
	let (s, scan, in_buf, out) = diag_test_server();
	defer diag_test_cleanup(&s, scan, in_buf, out);
	// 4 imports + a hard parse error => 1 unused (one used) + 1 parse.
	// Cap = 2: should keep 1 unused + marker, drop the parse error.
	// We'll instead pick a simpler fixture: many parse errors + 1
	// unused import + cap = 3. Unused must survive; parse gets
	// truncated.
	s.config.limits.max_diagnostics_per_file = 3;
	// `use foo;` is unused; the trailing garbage forces multiple
	// parse errors.
	const open =
		`{"textDocument":{"uri":"file:///cap.ha","languageId":"hare","version":1,"text":"use foo;\nexport fn a( = void;\nexport fn b( = void;\nexport fn c( = void;\n"}}`;
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
		*(json::get(&(v as json::object),
			"params") as *json::value) as json::object;
	const diags =
		*(json::get(&params, "diagnostics") as *json::value) as []json::value;
	assert(len(diags) == 3);
	// First entry must be the unused-import diagnostic (build > unused
	// > parse; with no build, unused leads).
	const d0 = diags[0] as json::object;
	assert(*(json::get(&d0, "code") as *json::value) as str == "unused-import");
	// Last entry is the truncation marker.
	const d_last = diags[len(diags) - 1] as json::object;
	assert(
		*(json::get(&d_last,
			"code") as *json::value) as str == "diagnostics-truncated"
	);
};
