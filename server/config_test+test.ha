// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use bufio;
use encoding::json;
use io;
use lsp;
use memio;
use strings;

fn fresh_server() (server, *bufio::scanner, *memio::stream, *memio::stream) = {
	let in_buf = alloc(memio::fixed([]))!;
	let scan = alloc(bufio::newscanner(in_buf))!;
	let out = alloc(memio::dynamic())!;
	let s = new(scan, out);
	return (s, scan, in_buf, out);
};

fn cleanup_server(s: *server, scan: *bufio::scanner, in_buf: *memio::stream, out: *memio::stream) void = {
	finish(s);
	bufio::finish(scan);
	free(scan);
	free(in_buf);
	io::close(out)!;
	free(out);
};

@test fn default_config_values() void = {
	let c = default_config();
	defer finish_config(&c);
	assert(c.hare_path == "hare");
	assert(len(c.tags) == 0);
	assert(c.diagnostics_debounce_ms == 300);
	assert(c.enable_build_diagnostics);
	assert(c.build_timeout_ms == 60000);
	assert(c.format_indent_style == indent_style::TAB);
	assert(c.format_indent_width == 8);
	assert(c.inlay_hints_parameter_names);
	assert(c.inlay_hints_inferred_types);
};

@test fn apply_settings_full_object() void = {
	let (s, scan, in_buf, out) = fresh_server();
	defer cleanup_server(&s, scan, in_buf, out);

	const settings = `{"path":"/opt/hare/bin/hare","tags":["+linux","+x86_64"],"diagnostics":{"debounceMs":500,"enableBuild":false,"buildTimeoutMs":10000},"format":{"indentStyle":"space","indentWidth":4,"trimFinalNewlines":false,"insertFinalNewline":false},"inlayHints":{"parameterNames":false,"inferredTypes":false}}`;
	let v = json::loadstr(settings)!;
	defer json::finish(v);
	apply_settings(&s, v);

	assert(s.config.hare_path == "/opt/hare/bin/hare");
	assert(len(s.config.tags) == 2);
	assert(s.config.tags[0] == "+linux");
	assert(s.config.tags[1] == "+x86_64");
	assert(s.config.diagnostics_debounce_ms == 500);
	assert(!s.config.enable_build_diagnostics);
	assert(s.config.build_timeout_ms == 10000);
	assert(s.config.format_indent_style == indent_style::SPACE);
	assert(s.config.format_indent_width == 4);
	assert(!s.config.format_trim_final_newlines);
	assert(!s.config.format_insert_final_newline);
	assert(!s.config.inlay_hints_parameter_names);
	assert(!s.config.inlay_hints_inferred_types);
};

@test fn apply_settings_partial_keeps_defaults() void = {
	let (s, scan, in_buf, out) = fresh_server();
	defer cleanup_server(&s, scan, in_buf, out);

	const settings = `{"diagnostics":{"debounceMs":1000}}`;
	let v = json::loadstr(settings)!;
	defer json::finish(v);
	apply_settings(&s, v);

	assert(s.config.diagnostics_debounce_ms == 1000);
	// Other fields untouched.
	assert(s.config.hare_path == "hare");
	assert(s.config.format_indent_style == indent_style::TAB);
};

@test fn did_change_configuration_with_namespace() void = {
	let (s, scan, in_buf, out) = fresh_server();
	defer cleanup_server(&s, scan, in_buf, out);

	const params = `{"settings":{"hare":{"path":"/usr/bin/hare"}}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const n = lsp::notification {
		method = strings::dup("workspace/didChangeConfiguration")!,
		params = pv,
	};
	defer free(n.method);

	handle_did_change_configuration(&s, n);
	assert(s.config.hare_path == "/usr/bin/hare");
};

@test fn did_change_configuration_without_namespace() void = {
	let (s, scan, in_buf, out) = fresh_server();
	defer cleanup_server(&s, scan, in_buf, out);

	const params = `{"settings":{"path":"/usr/bin/hare"}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const n = lsp::notification {
		method = strings::dup("workspace/didChangeConfiguration")!,
		params = pv,
	};
	defer free(n.method);

	handle_did_change_configuration(&s, n);
	assert(s.config.hare_path == "/usr/bin/hare");
};

@test fn did_change_configuration_null_triggers_pull() void = {
	let (s, scan, in_buf, out) = fresh_server();
	defer cleanup_server(&s, scan, in_buf, out);

	const params = `{"settings":null}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const n = lsp::notification {
		method = strings::dup("workspace/didChangeConfiguration")!,
		params = pv,
	};
	defer free(n.method);

	handle_did_change_configuration(&s, n);
	// Server should have issued a workspace/configuration request.
	assert(len(s.pending_requests) == 1);
	assert(s.pending_requests[0].method == "workspace/configuration");
};

@test fn request_configuration_emits_correct_request() void = {
	let (s, scan, in_buf, out) = fresh_server();
	defer cleanup_server(&s, scan, in_buf, out);

	const id = request_configuration(&s) as i64;
	assert(id == 0);

	// Inspect the outgoing message.
	const data = memio::buffer(out);
	const sep_idx = bytes_index_of(data, "\r\n\r\n");
	const body = strings::fromutf8(data[sep_idx + 4..])!;
	let v = json::loadstr(body)!;
	defer json::finish(v);
	const o = v as json::object;
	assert(*(json::get(&o, "method") as *json::value) as str == "workspace/configuration");
	const params = *(json::get(&o, "params") as *json::value) as json::object;
	const items = *(json::get(&params, "items") as *json::value) as []json::value;
	assert(len(items) == 1);
	const item = items[0] as json::object;
	assert(*(json::get(&item, "section") as *json::value) as str == "hare");
};

@test fn did_change_configuration_with_enable_build_change_refreshes_diagnostics() void = {
	let (s, scan, in_buf, out) = fresh_server();
	defer cleanup_server(&s, scan, in_buf, out);

	// Open a doc so there's something to refresh.
	const open = `{"textDocument":{"uri":"file:///x.ha","languageId":"hare","version":1,"text":"export fn main() void = void;\n"}}`;
	let opv = json::loadstr(open)!;
	const op = lsp::notification {
		method = strings::dup("textDocument/didOpen")!,
		params = opv,
	};
	defer { free(op.method); json::finish(opv); };
	handle_did_open(&s, op);

	// Snapshot the wire to count publishDiagnostics emissions so far.
	const before_len = len(memio::buffer(out));

	// Flip enableBuild from true to false.
	const params = `{"settings":{"hare":{"diagnostics":{"enableBuild":false}}}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const n = lsp::notification {
		method = strings::dup("workspace/didChangeConfiguration")!,
		params = pv,
	};
	defer free(n.method);
	handle_did_change_configuration(&s, n);

	assert(!s.config.enable_build_diagnostics);
	// After the config change we should have written more to the wire.
	const after_len = len(memio::buffer(out));
	assert(after_len > before_len);
	// And the new bytes include a publishDiagnostics for our open file.
	const new_text = strings::fromutf8(memio::buffer(out)[before_len..])!;
	assert(strings::contains(new_text, "textDocument/publishDiagnostics"));
};

@test fn did_change_configuration_with_inlay_hints_change_emits_refresh() void = {
	let (s, scan, in_buf, out) = fresh_server();
	defer cleanup_server(&s, scan, in_buf, out);

	// Flip parameterNames from true to false.
	const params = `{"settings":{"hare":{"inlayHints":{"parameterNames":false}}}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const n = lsp::notification {
		method = strings::dup("workspace/didChangeConfiguration")!,
		params = pv,
	};
	defer free(n.method);
	handle_did_change_configuration(&s, n);

	assert(!s.config.inlay_hints_parameter_names);
	// Should have sent a workspace/inlayHint/refresh.
	const text = strings::fromutf8(memio::buffer(out))!;
	assert(strings::contains(text, "workspace/inlayHint/refresh"));
};

@test fn did_change_configuration_with_no_change_is_quiet() void = {
	let (s, scan, in_buf, out) = fresh_server();
	defer cleanup_server(&s, scan, in_buf, out);

	const before_len = len(memio::buffer(out));
	// Send the same defaults — no actual change.
	const params = `{"settings":{"hare":{"diagnostics":{"debounceMs":300}}}}`;
	let pv = json::loadstr(params)!;
	defer json::finish(pv);
	const n = lsp::notification {
		method = strings::dup("workspace/didChangeConfiguration")!,
		params = pv,
	};
	defer free(n.method);
	handle_did_change_configuration(&s, n);
	// Wire unchanged: no refreshes needed.
	assert(len(memio::buffer(out)) == before_len);
};

// Helper inlined to avoid pulling bytes:: into the test header.
fn bytes_index_of(data: []u8, needle: str) size = {
	const n = strings::toutf8(needle);
	let i = 0z;
	for (i + len(n) <= len(data); i += 1) {
		let hit = true;
		for (let j = 0z; j < len(n); j += 1) {
			if (data[i + j] != n[j]) {
				hit = false;
				break;
			};
		};
		if (hit) return i;
	};
	return len(data);
};
