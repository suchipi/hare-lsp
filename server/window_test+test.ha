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

// Helper: build a server with a memio::dynamic out so tests can inspect what
// it wrote. The reader is bound to an empty fixed buffer.
fn test_server(out: io::handle) (server, *bufio::scanner, *memio::stream) = {
	let in_buf = alloc(memio::fixed([]))!;
	let scan = alloc(bufio::newscanner(in_buf))!;
	let s = new(scan, out);
	return (s, scan, in_buf);
};

fn finish_test_server(
	s: *server,
	scan: *bufio::scanner,
	in_buf: *memio::stream,
) void = {
	finish(s);
	bufio::finish(scan);
	free(scan);
	free(in_buf);
};

// Extracts the JSON body from a framed LSP message starting at `data`.
// Returns the parsed value (caller must finish) and the offset of the next
// message.
fn next_framed(data: []u8) (json::value, size) = {
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

@test fn log_message_emits_window_logMessage() void = {
	let out = memio::dynamic();
	defer io::close(&out)!;
	let (s, scan, in_buf) = test_server(&out);
	defer finish_test_server(&s, scan, in_buf);

	log_info(&s, "hello");

	const (v, _) = next_framed(memio::buffer(&out));
	defer json::finish(v);
	const o = v as json::object;
	assert(
		*(json::get(&o, "method") as *json::value) as str == "window/logMessage"
	);
	const params = *(json::get(&o, "params") as *json::value) as json::object;
	assert(*(json::get(&params, "type") as *json::value) as f64 == 3.0);
	assert(*(json::get(&params, "message") as *json::value) as str == "hello");
};

@test fn show_message_emits_window_showMessage() void = {
	let out = memio::dynamic();
	defer io::close(&out)!;
	let (s, scan, in_buf) = test_server(&out);
	defer finish_test_server(&s, scan, in_buf);

	show_message(&s, lsp::message_type::ERROR, "bad");

	const (v, _) = next_framed(memio::buffer(&out));
	defer json::finish(v);
	const o = v as json::object;
	assert(
		*(json::get(&o, "method") as *json::value) as str == "window/showMessage"
	);
	const params = *(json::get(&o, "params") as *json::value) as json::object;
	assert(*(json::get(&params, "type") as *json::value) as f64 == 1.0);
};

@test fn log_trace_off_when_trace_off() void = {
	let out = memio::dynamic();
	defer io::close(&out)!;
	let (s, scan, in_buf) = test_server(&out);
	defer finish_test_server(&s, scan, in_buf);
	// Default trace is OFF.
	log_trace(&s, "should not appear", "");
	assert(len(memio::buffer(&out)) == 0);
};

@test fn log_trace_on_when_messages() void = {
	let out = memio::dynamic();
	defer io::close(&out)!;
	let (s, scan, in_buf) = test_server(&out);
	defer finish_test_server(&s, scan, in_buf);
	s.trace = lsp::trace_value::MESSAGES;
	log_trace(&s, "tick", "");
	const (v, _) = next_framed(memio::buffer(&out));
	defer json::finish(v);
	const o = v as json::object;
	assert(*(json::get(&o, "method") as *json::value) as str == "$/logTrace");
	const params = *(json::get(&o, "params") as *json::value) as json::object;
	assert(*(json::get(&params, "message") as *json::value) as str == "tick");
	// At MESSAGES level, "verbose" must not be sent.
	assert(json::get(&params, "verbose") is void);
};

@test fn log_trace_verbose_includes_verbose_field() void = {
	let out = memio::dynamic();
	defer io::close(&out)!;
	let (s, scan, in_buf) = test_server(&out);
	defer finish_test_server(&s, scan, in_buf);
	s.trace = lsp::trace_value::VERBOSE;
	log_trace(&s, "tick", "details");
	const (v, _) = next_framed(memio::buffer(&out));
	defer json::finish(v);
	const o = v as json::object;
	const params = *(json::get(&o, "params") as *json::value) as json::object;
	assert(*(json::get(&params, "verbose") as *json::value) as str == "details");
};

@test fn show_message_request_records_pending() void = {
	let out = memio::dynamic();
	defer io::close(&out)!;
	let (s, scan, in_buf) = test_server(&out);
	defer finish_test_server(&s, scan, in_buf);

	const id_v = show_message_request(&s, lsp::message_type::INFO, "pick",
		["A", "B"]);
	const id = id_v as i64;
	assert(id == 0);
	assert(len(s.pending_requests) == 1);
	assert(s.pending_requests[0].id == 0);
	assert(s.pending_requests[0].method == "window/showMessageRequest");

	const (v, _) = next_framed(memio::buffer(&out));
	defer json::finish(v);
	const o = v as json::object;
	assert(
		*(json::get(&o,
			"method") as *json::value) as str == "window/showMessageRequest"
	);
	const params = *(json::get(&o, "params") as *json::value) as json::object;
	const actions =
		*(json::get(&params, "actions") as *json::value) as []json::value;
	assert(len(actions) == 2);
	const a0 = actions[0] as json::object;
	assert(*(json::get(&a0, "title") as *json::value) as str == "A");
};

@test fn progress_lifecycle_emits_create_begin_report_end() void = {
	let out = memio::dynamic();
	defer io::close(&out)!;
	let (s, scan, in_buf) = test_server(&out);
	defer finish_test_server(&s, scan, in_buf);

	const (token, id) = progress_create(&s) as (progress_token, i64);
	defer free(token);
	progress_begin(&s, token, "Indexing", "starting", -1, false);
	progress_report(&s, token, "halfway", 50);
	progress_end(&s, token, "done");

	let off = 0z;
	const data = memio::buffer(&out);

	// Message 1: window/workDoneProgress/create request.
	const (v1, off1) = next_framed(data[off..]);
	defer json::finish(v1);
	off += off1;
	const o1 = v1 as json::object;
	assert(
		*(json::get(&o1,
			"method") as *json::value) as str == "window/workDoneProgress/create"
	);

	// Message 2: $/progress {kind: "begin", title: "Indexing"}
	const (v2, off2) = next_framed(data[off..]);
	defer json::finish(v2);
	off += off2;
	const o2 = v2 as json::object;
	assert(*(json::get(&o2, "method") as *json::value) as str == "$/progress");
	const params2 = *(json::get(&o2, "params") as *json::value) as json::object;
	const value2 = *(json::get(&params2, "value") as *json::value) as json::object;
	assert(*(json::get(&value2, "kind") as *json::value) as str == "begin");

	// Message 3: $/progress {kind: "report", percentage: 50}
	const (v3, off3) = next_framed(data[off..]);
	defer json::finish(v3);
	off += off3;
	const o3 = v3 as json::object;
	const params3 = *(json::get(&o3, "params") as *json::value) as json::object;
	const value3 = *(json::get(&params3, "value") as *json::value) as json::object;
	assert(*(json::get(&value3, "kind") as *json::value) as str == "report");
	assert(*(json::get(&value3, "percentage") as *json::value) as f64 == 50.0);

	// Message 4: $/progress {kind: "end", message: "done"}
	const (v4, off4) = next_framed(data[off..]);
	defer json::finish(v4);
	const o4 = v4 as json::object;
	const params4 = *(json::get(&o4, "params") as *json::value) as json::object;
	const value4 = *(json::get(&params4, "value") as *json::value) as json::object;
	assert(*(json::get(&value4, "kind") as *json::value) as str == "end");
};

@test fn progress_cancel_recorded() void = {
	let out = memio::dynamic();
	defer io::close(&out)!;
	let (s, scan, in_buf) = test_server(&out);
	defer finish_test_server(&s, scan, in_buf);

	// Simulate the client sending a cancel notification.
	const params_str = `{"token":"hare-lsp/0"}`;
	let pv = json::loadstr(params_str)!;
	const n = lsp::notification {
		method = strings::dup("window/workDoneProgress/cancel")!,
		params = pv,
	};
	defer free(n.method);
	defer json::finish(pv);

	handle_progress_cancel(&s, n);

	assert(progress_is_cancelled(&s, "hare-lsp/0"));
	assert(!progress_is_cancelled(&s, "hare-lsp/1"));
};
