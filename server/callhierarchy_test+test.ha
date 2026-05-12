// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use analysis;
use bufio;
use bytes;
use encoding::json;
use io;
use lsp;
use memio;
use strconv;
use strings;

fn ch_test_server(

) (server, *bufio::scanner, *memio::stream, *memio::stream) = {
	let in_buf = alloc(memio::fixed([]))!;
	let scan = alloc(bufio::newscanner(in_buf))!;
	let out = alloc(memio::dynamic())!;
	let s = new(scan, out);
	return (s, scan, in_buf, out);
};

fn ch_test_cleanup(
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

fn ch_open(s: *server, uri: str, text: str) void = {
	const open =
		strings::concat(
			`{"textDocument":{"uri":"`, uri,
			`","languageId":"hare","version":1,"text":"`, text, `"}}`,
		)!;
	defer free(open);
	let pv = json::loadstr(open)!;
	const n = lsp::notification {
		method = strings::dup("textDocument/didOpen")!,
		params = pv,
	};
	defer {
		free(n.method);
		json::finish(pv);
	};
	handle_did_open(s, n);
};

fn ch_skip_to_response(out: *memio::stream, request_id: f64) json::value = {
	const data = memio::buffer(out);
	let off = 0z;
	for (off < len(data)) {
		const sep = bytes::index(data[off..], strings::toutf8("\r\n\r\n")) as size;
		const headers = strings::fromutf8(data[off..off + sep])!;
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
		const body_start = off + sep + 4;
		const body = data[body_start..body_start + length];
		const v = json::loadstr(strings::fromutf8(body)!)!;
		const obj = v as json::object;
		match (json::get(&obj, "id")) {
		case let p: *json::value =>
			match (*p) {
			case let f: f64 =>
				if (f == request_id) return v;
			case => void;
			};
		case => void;
		};
		json::finish(v);
		off = body_start + length;
	};
	abort("response not found");
};

@test fn prepare_call_hierarchy_returns_function_item() void = {
	let (s, scan, in_buf, out) = ch_test_server();
	defer ch_test_cleanup(&s, scan, in_buf, out);
	ch_open(&s, "file:///x.ha", "fn target() void = void;\\n");

	const params =
		`{"textDocument":{"uri":"file:///x.ha"},"position":{"line":0,"character":4}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 1.0,
		method = strings::dup("textDocument/prepareCallHierarchy")!,
		params = pv,
	};
	defer free(r.method);
	handle_prepare_call_hierarchy(&s, r);
	const v = ch_skip_to_response(out, 1.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	assert(len(result) == 1);
	const item = result[0] as json::object;
	assert(*(json::get(&item, "name") as *json::value) as str == "target");
	assert(*(json::get(&item, "kind") as *json::value) as f64 == 12.0);
};

@test fn incoming_calls_returns_call_sites() void = {
	let (s, scan, in_buf, out) = ch_test_server();
	defer ch_test_cleanup(&s, scan, in_buf, out);
	ch_open(
		&s, "file:///x.ha",
		"fn target() void = void;\\nfn caller() void = target();\\n",
	);

	const params =
		`{"item":{"name":"target","kind":12,"uri":"file:///x.ha","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":24}},"selectionRange":{"start":{"line":0,"character":0},"end":{"line":0,"character":24}}}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 2.0,
		method = strings::dup("callHierarchy/incomingCalls")!,
		params = pv,
	};
	defer free(r.method);
	handle_incoming_calls(&s, r);
	const v = ch_skip_to_response(out, 2.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	// Exactly one calling URI (file:///x.ha) with at least one fromRange.
	assert(len(result) == 1);
	const entry = result[0] as json::object;
	const from_ranges =
		*(json::get(&entry, "fromRanges") as *json::value) as []json::value;
	assert(len(from_ranges) >= 1);
};

// `caller` references `target` once in its body, but workspace_index
// may store duplicate FUNCTION entries (e.g. from re-indexing on file
// events). The cycle/dedupe guard inside handle_outgoing_calls keeps
// the response stable in that case.
@test fn outgoing_calls_dedupes_duplicate_workspace_entries() void = {
	let (s, scan, in_buf, out) = ch_test_server();
	defer ch_test_cleanup(&s, scan, in_buf, out);
	ch_open(
		&s, "file:///dup.ha",
		"fn caller() void = target();\\nfn target() void = void;\\n",
	);

	// Index the same path twice on purpose: simulates a re-index that
	// failed to drop the prior entries before re-adding them.
	const text = "fn caller() void = target();\nfn target() void = void;\n";
	analysis::index_file(&s.workspace_index, "/dup.ha", strings::toutf8(text));
	analysis::index_file(&s.workspace_index, "/dup.ha", strings::toutf8(text));

	const params =
		`{"item":{"name":"caller","kind":12,"uri":"file:///dup.ha","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":28}},"selectionRange":{"start":{"line":0,"character":0},"end":{"line":0,"character":28}}}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 3.0,
		method = strings::dup("callHierarchy/outgoingCalls")!,
		params = pv,
	};
	defer free(r.method);
	handle_outgoing_calls(&s, r);
	const v = ch_skip_to_response(out, 3.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	let count_target = 0;
	for (let i = 0z; i < len(result); i += 1) {
		const entry = result[i] as json::object;
		const to = *(json::get(&entry, "to") as *json::value) as json::object;
		const name = *(json::get(&to, "name") as *json::value) as str;
		if (name == "target") count_target += 1;
	};
	assert(count_target == 1);
};

// Recursive self-call - foo calls foo - must not appear in foo's
// outgoing calls. Otherwise call-hierarchy trees in editors would
// render an infinitely-deep `foo -> foo -> foo -> ...` chain.
@test fn outgoing_calls_skip_self_for_recursion() void = {
	let (s, scan, in_buf, out) = ch_test_server();
	defer ch_test_cleanup(&s, scan, in_buf, out);
	ch_open(&s, "file:///rec.ha", "fn rec() void = rec();\\n");
	const text = "fn rec() void = rec();\n";
	analysis::index_file(&s.workspace_index, "/rec.ha", strings::toutf8(text));

	const params =
		`{"item":{"name":"rec","kind":12,"uri":"file:///rec.ha","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":22}},"selectionRange":{"start":{"line":0,"character":0},"end":{"line":0,"character":22}}}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const r = lsp::request {
		id = 4.0,
		method = strings::dup("callHierarchy/outgoingCalls")!,
		params = pv,
	};
	defer free(r.method);
	handle_outgoing_calls(&s, r);
	const v = ch_skip_to_response(out, 4.0);
	defer json::finish(v);
	const result =
		*(json::get(&(v as json::object), "result") as *json::value) as []json::value;
	for (let i = 0z; i < len(result); i += 1) {
		const entry = result[i] as json::object;
		const to = *(json::get(&entry, "to") as *json::value) as json::object;
		const name = *(json::get(&to, "name") as *json::value) as str;
		const uri = *(json::get(&to, "uri") as *json::value) as str;
		assert(!(name == "rec" && uri == "file:///rec.ha"));
	};
};
