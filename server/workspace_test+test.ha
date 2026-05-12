// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use analysis;
use bufio;
use encoding::json;
use fs;
use io;
use lsp;
use memio;
use os;
use strings;

@test fn decode_workspace_folders_handles_array() void = {
	let v =
		json::loadstr(
			`[{"uri":"file:///a","name":"a"},{"uri":"file:///b","name":"b"}]`,
		)!;
	defer json::finish(v);
	const folders = decode_workspace_folders(v);
	defer {
		for (let i = 0z; i < len(folders); i += 1) {
			free(folders[i].uri);
			free(folders[i].name);
		};
		free(folders);
	};
	assert(len(folders) == 2);
	assert(folders[0].uri == "file:///a");
	assert(folders[0].name == "a");
	assert(folders[1].uri == "file:///b");
};

@test fn decode_workspace_folders_handles_null() void = {
	let v = json::loadstr(`null`)!;
	defer json::finish(v);
	const folders = decode_workspace_folders(v);
	defer free(folders);
	assert(len(folders) == 0);
};

@test fn decode_workspace_folders_skips_malformed_entries() void = {
	// One valid, one with no uri.
	let v = json::loadstr(`[{"uri":"file:///a","name":"a"},{"name":"b"}]`)!;
	defer json::finish(v);
	const folders = decode_workspace_folders(v);
	defer {
		for (let i = 0z; i < len(folders); i += 1) {
			free(folders[i].uri);
			free(folders[i].name);
		};
		free(folders);
	};
	assert(len(folders) == 1);
	assert(folders[0].uri == "file:///a");
};

@test fn did_change_workspace_folders_adds_and_removes() void = {
	let out = memio::dynamic();
	defer io::close(&out)!;
	let in_buf = alloc(memio::fixed([]))!;
	defer free(in_buf);
	let scan = alloc(bufio::newscanner(in_buf))!;
	defer {
		bufio::finish(scan);
		free(scan);
	};
	let s = new(scan, &out);
	defer finish(&s);

	// Start with two folders.
	let init: []workspace_folder = [];
	append(init, workspace_folder {
		uri = strings::dup("file:///a")!,
		name = strings::dup("a")!,
	})!;
	append(init, workspace_folder {
		uri = strings::dup("file:///b")!,
		name = strings::dup("b")!,
	})!;
	set_workspace_folders(&s, init);

	// Build a didChangeWorkspaceFolders notification: remove a, add c.
	const params_str =
		`{"event":{"added":[{"uri":"file:///c","name":"c"}],"removed":[{"uri":"file:///a","name":"a"}]}}`;
	let pv = json::loadstr(params_str)!;
	defer json::finish(pv);
	const n = lsp::notification {
		method = strings::dup("workspace/didChangeWorkspaceFolders")!,
		params = pv,
	};
	defer free(n.method);

	handle_did_change_workspace_folders(&s, n);

	assert(len(s.workspace_folders) == 2);
	assert(!has_workspace_folder(&s, "file:///a"));
	assert(has_workspace_folder(&s, "file:///b"));
	assert(has_workspace_folder(&s, "file:///c"));
};

@test fn register_emits_request_and_records() void = {
	let out = memio::dynamic();
	defer io::close(&out)!;
	let in_buf = alloc(memio::fixed([]))!;
	defer free(in_buf);
	let scan = alloc(bufio::newscanner(in_buf))!;
	defer {
		bufio::finish(scan);
		free(scan);
	};
	let s = new(scan, &out);
	defer finish(&s);

	const reqs: []registration_request = [
		registration_request {
			method = "workspace/didChangeWatchedFiles",
			register_options = void,
		},
	];
	const id = register(&s, reqs);
	assert(id is i64);
	assert(len(s.registrations) == 1);
	assert(s.registrations[0].method == "workspace/didChangeWatchedFiles");
	// Pending request was tracked.
	assert(len(s.pending_requests) == 1);
	assert(s.pending_requests[0].method == "client/registerCapability");
};

@test fn unregister_drops_local_record() void = {
	let out = memio::dynamic();
	defer io::close(&out)!;
	let in_buf = alloc(memio::fixed([]))!;
	defer free(in_buf);
	let scan = alloc(bufio::newscanner(in_buf))!;
	defer {
		bufio::finish(scan);
		free(scan);
	};
	let s = new(scan, &out);
	defer finish(&s);

	const reqs: []registration_request = [
		registration_request {
			method = "workspace/didChangeWatchedFiles",
			register_options = void,
		},
	];
	register(&s, reqs);
	const reg_id = strings::dup(s.registrations[0].id)!;
	defer free(reg_id);

	const ids: []str = [reg_id];
	unregister(&s, ids);

	assert(len(s.registrations) == 0);
};

@test fn initialize_extracts_workspace_folders() void = {
	let out = memio::dynamic();
	defer io::close(&out)!;
	let in_buf = alloc(memio::fixed([]))!;
	defer free(in_buf);
	let scan = alloc(bufio::newscanner(in_buf))!;
	defer {
		bufio::finish(scan);
		free(scan);
	};
	let s = new(scan, &out);
	defer finish(&s);

	const params =
		`{"processId":42,"workspaceFolders":[{"uri":"file:///proj","name":"proj"}],"capabilities":{}}`;
	let pv = json::loadstr(params)!;
	const r = lsp::request {
		id = 1.0,
		method = strings::dup("initialize")!,
		params = pv,
	};
	defer {
		free(r.method);
		json::finish(pv);
	};

	handle_initialize(&s, r);

	assert(len(s.workspace_folders) == 1);
	assert(s.workspace_folders[0].uri == "file:///proj");
	assert(s.client_pid as i32 == 42);
};

@test fn initialize_falls_back_to_rootUri() void = {
	let out = memio::dynamic();
	defer io::close(&out)!;
	let in_buf = alloc(memio::fixed([]))!;
	defer free(in_buf);
	let scan = alloc(bufio::newscanner(in_buf))!;
	defer {
		bufio::finish(scan);
		free(scan);
	};
	let s = new(scan, &out);
	defer finish(&s);

	const params = `{"rootUri":"file:///legacy","capabilities":{}}`;
	let pv = json::loadstr(params)!;
	const r = lsp::request {
		id = 1.0,
		method = strings::dup("initialize")!,
		params = pv,
	};
	defer {
		free(r.method);
		json::finish(pv);
	};

	handle_initialize(&s, r);

	assert(len(s.workspace_folders) == 1);
	assert(s.workspace_folders[0].uri == "file:///legacy");
};

@test fn initialize_picks_utf8_when_offered() void = {
	let out = memio::dynamic();
	defer io::close(&out)!;
	let in_buf = alloc(memio::fixed([]))!;
	defer free(in_buf);
	let scan = alloc(bufio::newscanner(in_buf))!;
	defer {
		bufio::finish(scan);
		free(scan);
	};
	let s = new(scan, &out);
	defer finish(&s);

	const params =
		`{"capabilities":{"general":{"positionEncodings":["utf-16","utf-8"]}}}`;
	let pv = json::loadstr(params)!;
	const r = lsp::request {
		id = 1.0,
		method = strings::dup("initialize")!,
		params = pv,
	};
	defer {
		free(r.method);
		json::finish(pv);
	};
	handle_initialize(&s, r);

	assert(s.negotiated_encoding == analysis::encoding::UTF8);

	// Inspect the wire response — capabilities.positionEncoding should
	// echo "utf-8".
	const data = memio::buffer(&out);
	const text = strings::fromutf8(data)!;
	assert(strings::contains(text, `"positionEncoding":"utf-8"`));
};

@test fn initialize_defaults_to_utf16_when_no_general_caps() void = {
	let out = memio::dynamic();
	defer io::close(&out)!;
	let in_buf = alloc(memio::fixed([]))!;
	defer free(in_buf);
	let scan = alloc(bufio::newscanner(in_buf))!;
	defer {
		bufio::finish(scan);
		free(scan);
	};
	let s = new(scan, &out);
	defer finish(&s);

	const params = `{"capabilities":{}}`;
	let pv = json::loadstr(params)!;
	const r = lsp::request {
		id = 1.0,
		method = strings::dup("initialize")!,
		params = pv,
	};
	defer {
		free(r.method);
		json::finish(pv);
	};
	handle_initialize(&s, r);

	assert(s.negotiated_encoding == analysis::encoding::UTF16);
};

@test fn did_change_workspace_folders_indexes_added_drops_removed() void = {
	let out = memio::dynamic();
	defer io::close(&out)!;
	let in_buf = alloc(memio::fixed([]))!;
	defer free(in_buf);
	let scan = alloc(bufio::newscanner(in_buf))!;
	defer {
		bufio::finish(scan);
		free(scan);
	};
	let s = new(scan, &out);
	defer finish(&s);

	// Set up two folders on disk, each with a .ha file declaring a symbol.
	const dir_x = ".tmp/lspwsfx";
	const dir_y = ".tmp/lspwsfy";
	const path_x = ".tmp/lspwsfx/init.ha";
	const path_y = ".tmp/lspwsfy/init.ha";
	wsfx_mkdir(dir_x);
	wsfx_mkdir(dir_y);
	wsfx_write(path_x, "export fn xfunc() void = void;\n");
	wsfx_write(path_y, "export fn yfunc() void = void;\n");
	defer {
		wsfx_rm(path_x);
		wsfx_rm(path_y);
	};

	// Initialize with folder x.
	let init: []workspace_folder = [];
	append(init, workspace_folder {
		uri = strings::dup("file://.tmp/lspwsfx")!,
		name = strings::dup("x")!,
	})!;
	set_workspace_folders(&s, init);
	const _ = analysis::index_directory(&s.workspace_index, dir_x);
	// xfunc should be in the index.
	assert(len(analysis::lookup_by_short_name(&s.workspace_index, "xfunc")) == 1);
	assert(len(analysis::lookup_by_short_name(&s.workspace_index, "yfunc")) == 0);

	// Send didChangeWorkspaceFolders: add y, remove x.
	const params_str =
		`{"event":{"added":[{"uri":"file://.tmp/lspwsfy","name":"y"}],"removed":[{"uri":"file://.tmp/lspwsfx","name":"x"}]}}`;
	let pv = json::loadstr(params_str)!;
	defer json::finish(pv);
	const n = lsp::notification {
		method = strings::dup("workspace/didChangeWorkspaceFolders")!,
		params = pv,
	};
	defer free(n.method);
	handle_did_change_workspace_folders(&s, n);

	// xfunc should be gone, yfunc should be present.
	assert(len(analysis::lookup_by_short_name(&s.workspace_index, "xfunc")) == 0);
	assert(len(analysis::lookup_by_short_name(&s.workspace_index, "yfunc")) == 1);
};

fn wsfx_mkdir(path: str) void = {
	match (os::mkdir(path, 0o755)) {
	case => void;
	};
};

fn wsfx_write(path: str, text: str) void = {
	const f = match (os::create(path, 0o644)) {
	case let h: io::file =>
		yield h;
	case fs::error =>
		return;
	};
	defer io::close(f)!;
	io::writeall(f, strings::toutf8(text))!;
};

fn wsfx_rm(path: str) void = {
	match (os::remove(path)) {
	case => void;
	};
};

@test fn workspace_symbol_returns_list_shape() void = {
	let out = memio::dynamic();
	defer io::close(&out)!;
	let in_buf = alloc(memio::fixed([]))!;
	defer free(in_buf);
	let scan = alloc(bufio::newscanner(in_buf))!;
	defer {
		bufio::finish(scan);
		free(scan);
	};
	let s = new(scan, &out);
	defer finish(&s);

	// Index one fake entry.
	analysis::index_file(
		&s.workspace_index, "/x/foo.ha",
		strings::toutf8("export fn hello() void = void;\n"),
	);

	const r = lsp::request {
		id = 90.0,
		method = strings::dup("workspace/symbol")!,
		params = json::loadstr(`{"query":""}`)!,
	};
	defer {
		free(r.method);
		json::finish(r.params as json::value);
	};
	handle_workspace_symbol(&s, r);

	// Find the response in the output stream.
	const data = memio::buffer(&out);
	const text = strings::fromutf8(data)!;
	// Reply shape carries isIncomplete + items keys. The actual
	// isIncomplete value may be true when stdlib indexing is still
	// in flight (see [[ensure_full_stdlib_indexed]]), so we only
	// assert the key is present.
	assert(strings::contains(text, `"isIncomplete":`));
	assert(strings::contains(text, `"items":`));
	assert(strings::contains(text, `"hello"`));
};

@test fn cached_parse_or_drop_stale_removes_index_for_missing_file() void = {
	let out = memio::dynamic();
	defer io::close(&out)!;
	let in_buf = alloc(memio::fixed([]))!;
	defer free(in_buf);
	let scan = alloc(bufio::newscanner(in_buf))!;
	defer {
		bufio::finish(scan);
		free(scan);
	};
	let s = new(scan, &out);
	defer finish(&s);

	// Write a real file, index it, then delete it on disk and ask
	// for its parse via cached_parse_or_drop_stale. The handler
	// should return null AND remove the index entry.
	const path = ".tmp/lspstale.ha";
	wsfx_write(path, "export fn ghost() void = void;\n");
	analysis::index_file(
		&s.workspace_index, path, strings::toutf8("export fn ghost() void = void;\n"),
	);
	assert(len(analysis::lookup_by_short_name(&s.workspace_index, "ghost")) == 1);

	wsfx_rm(path);
	const got = cached_parse_or_drop_stale(&s, path);
	assert(got is null);
	// Self-healed.
	assert(len(analysis::lookup_by_short_name(&s.workspace_index, "ghost")) == 0);
};

@test fn workspace_symbol_isincomplete_when_truncated() void = {
	let out = memio::dynamic();
	defer io::close(&out)!;
	let in_buf = alloc(memio::fixed([]))!;
	defer free(in_buf);
	let scan = alloc(bufio::newscanner(in_buf))!;
	defer {
		bufio::finish(scan);
		free(scan);
	};
	let s = new(scan, &out);
	defer finish(&s);

	// Manually inject 250 entries to exceed the 200 cap.
	for (let i = 0z; i < 250; i += 1) {
		append(s.workspace_index.entries, analysis::workspace_entry {
			uri = strings::dup("file:///x.ha")!,
			path = strings::dup("/x.ha")!,
			short_name = strings::dup("s")!,
			full_name = strings::dup("s")!,
			kind = analysis::symbol_kind::FUNCTION,
			start_off = 0,
			end_off = 1,
			docs = strings::dup("")!,
			exported = true,
			module = strings::dup("")!,
			param_names = [],
		})!;
	};

	const r = lsp::request {
		id = 91.0,
		method = strings::dup("workspace/symbol")!,
		params = json::loadstr(`{"query":""}`)!,
	};
	defer {
		free(r.method);
		json::finish(r.params as json::value);
	};
	handle_workspace_symbol(&s, r);

	const data = memio::buffer(&out);
	const text = strings::fromutf8(data)!;
	assert(strings::contains(text, `"isIncomplete":true`));
};
