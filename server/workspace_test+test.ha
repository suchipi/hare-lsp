// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use bufio;
use encoding::json;
use io;
use lsp;
use memio;
use strings;

@test fn decode_workspace_folders_handles_array() void = {
	let v = json::loadstr(`[{"uri":"file:///a","name":"a"},{"uri":"file:///b","name":"b"}]`)!;
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
	defer { bufio::finish(scan); free(scan); };
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
	const params_str = `{"event":{"added":[{"uri":"file:///c","name":"c"}],"removed":[{"uri":"file:///a","name":"a"}]}}`;
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
	defer { bufio::finish(scan); free(scan); };
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
	defer { bufio::finish(scan); free(scan); };
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
	defer { bufio::finish(scan); free(scan); };
	let s = new(scan, &out);
	defer finish(&s);

	const params = `{"processId":42,"workspaceFolders":[{"uri":"file:///proj","name":"proj"}],"capabilities":{}}`;
	let pv = json::loadstr(params)!;
	const r = lsp::request {
		id = 1.0,
		method = strings::dup("initialize")!,
		params = pv,
	};
	defer { free(r.method); json::finish(pv); };

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
	defer { bufio::finish(scan); free(scan); };
	let s = new(scan, &out);
	defer finish(&s);

	const params = `{"rootUri":"file:///legacy","capabilities":{}}`;
	let pv = json::loadstr(params)!;
	const r = lsp::request {
		id = 1.0,
		method = strings::dup("initialize")!,
		params = pv,
	};
	defer { free(r.method); json::finish(pv); };

	handle_initialize(&s, r);

	assert(len(s.workspace_folders) == 1);
	assert(s.workspace_folders[0].uri == "file:///legacy");
};
