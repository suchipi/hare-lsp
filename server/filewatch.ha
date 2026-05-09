// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// File watcher and workspace file operations.
//
// We use the LSP dynamic registration mechanism to ask the client to watch
// `**/*.ha` (and `**/*.s`) under each workspace folder, then handle the
// resulting workspace/didChangeWatchedFiles notifications by invalidating
// the workspace index (step 15) and republishing diagnostics.
//
// The will/did-Create/Rename/Delete notifications carry file URIs; we use
// them to (a) update our document store for renamed files that we have open,
// and (b) compute WorkspaceEdit responses to fix `use` import paths when
// modules are moved.

use encoding::json;
use lsp;
use strings;

// Registers the file watcher with the client. Should be called after the
// server has reached the READY state. Returns the registration request id,
// or void on transport failure.
export fn register_file_watchers(s: *server) (i64 | void) = {
	// Build the watcher options:
	//   { watchers: [ { globPattern: "**/*.ha" }, { globPattern: "**/*.s" } ] }
	let opts = json::newobject();
	let opts_owned = true;
	defer if (opts_owned) json::finish(opts);

	let watchers: []json::value = [];
	let watchers_owned = true;
	defer if (watchers_owned) {
		for (let i = 0z; i < len(watchers); i += 1) {
			json::finish(watchers[i]);
		};
		free(watchers);
	};

	let w1 = json::newobject();
	json::set(&w1, "globPattern", "**/*.ha": json::value)!;
	append(watchers, w1: json::value)!;
	let w2 = json::newobject();
	json::set(&w2, "globPattern", "**/*.s": json::value)!;
	append(watchers, w2: json::value)!;

	json::put(&opts, "watchers", watchers: json::value)!;
	watchers_owned = false;

	const reqs: []registration_request = [
		registration_request {
			method = "workspace/didChangeWatchedFiles",
			register_options = opts,
		},
	];
	opts_owned = false;
	return register(s, reqs);
};

// Handles workspace/didChangeWatchedFiles. The notification carries an array
// of {uri, type} where type is 1=Created, 2=Changed, 3=Deleted. For now we
// simply log; in step 15 the workspace index uses these events to refresh
// individual files.
export fn handle_did_change_watched_files(s: *server, n: lsp::notification) void = {
	const params = match (n.params) {
	case let v: json::value => yield v;
	case void => return;
	};
	const obj = match (params) {
	case let o: json::object => yield o;
	case => return;
	};
	const changes = match (json::get(&obj, "changes")) {
	case let p: *json::value =>
		yield match (*p) {
		case let a: []json::value => yield a;
		case => return;
		};
	case => return;
	};

	for (let i = 0z; i < len(changes); i += 1) {
		const change = match (changes[i]) {
		case let o: json::object => yield o;
		case => continue;
		};
		const uri = match (json::get(&change, "uri")) {
		case let p: *json::value =>
			yield match (*p) {
			case let s: str => yield s;
			case => continue;
			};
		case => continue;
		};
		const change_type = match (json::get(&change, "type")) {
		case let p: *json::value =>
			yield match (*p) {
			case let f: f64 => yield f: int;
			case => continue;
			};
		case => continue;
		};
		// 1 = Created, 2 = Changed, 3 = Deleted.
		log_trace(s, fmt_watcher_event(uri, change_type), "");
		workspace_handle_file_event(s, uri, change_type);
	};
};

fn fmt_watcher_event(uri: str, kind: int) str = {
	const kind_str = switch (kind) {
	case 1 => yield "created";
	case 2 => yield "changed";
	case 3 => yield "deleted";
	case => yield "unknown";
	};
	return strings::concat("watched file ", kind_str, ": ", uri)!;
};

// --- file ops -------------------------------------------------------

// workspace/willCreateFiles request. Per spec, returns a WorkspaceEdit (or
// null) to apply before the file is created. We don't need to mutate
// existing files when a new .ha file is created, so we always return null.
export fn handle_will_create_files(s: *server, r: lsp::request) void = {
	send_workspace_edit_or_null(s, r.id, void);
};

// workspace/didCreateFiles notification. Trigger a workspace re-index for
// the affected modules (lands in step 15); for now we accept silently.
export fn handle_did_create_files(s: *server, n: lsp::notification) void = void;

// workspace/willRenameFiles request. Returns a WorkspaceEdit that updates
// any `use` import paths whose target was moved. The renames array contains
// {oldUri, newUri} entries. For files that aren't part of a module path,
// the empty edit is fine. Full implementation lives next to the workspace
// index in step 15; for now we return null.
export fn handle_will_rename_files(s: *server, r: lsp::request) void = {
	send_workspace_edit_or_null(s, r.id, void);
};

// workspace/didRenameFiles notification. Update the document store for any
// open documents whose URI changed.
export fn handle_did_rename_files(s: *server, n: lsp::notification) void = {
	const params = match (n.params) {
	case let v: json::value => yield v;
	case void => return;
	};
	const obj = match (params) {
	case let o: json::object => yield o;
	case => return;
	};
	const renames = match (json::get(&obj, "files")) {
	case let p: *json::value =>
		yield match (*p) {
		case let a: []json::value => yield a;
		case => return;
		};
	case => return;
	};
	for (let i = 0z; i < len(renames); i += 1) {
		const rn = match (renames[i]) {
		case let o: json::object => yield o;
		case => continue;
		};
		const old_uri = match (json::get(&rn, "oldUri")) {
		case let p: *json::value =>
			yield match (*p) {
			case let s: str => yield s;
			case => continue;
			};
		case => continue;
		};
		const new_uri = match (json::get(&rn, "newUri")) {
		case let p: *json::value =>
			yield match (*p) {
			case let s: str => yield s;
			case => continue;
			};
		case => continue;
		};
		rename_open_document(s, old_uri, new_uri);
	};
};

fn rename_open_document(s: *server, old_uri: str, new_uri: str) void = {
	for (let i = 0z; i < len(s.documents); i += 1) {
		if (s.documents[i].uri == old_uri) {
			free(s.documents[i].uri);
			s.documents[i].uri = strings::dup(new_uri)!;
			return;
		};
	};
};

// workspace/willDeleteFiles request. Returns a WorkspaceEdit with
// modifications to dependent files. We return null for now; step 15 will
// surface broken-import diagnostics on the affected modules.
export fn handle_will_delete_files(s: *server, r: lsp::request) void = {
	send_workspace_edit_or_null(s, r.id, void);
};

// workspace/didDeleteFiles notification. Close any open documents matching
// the deleted URIs.
export fn handle_did_delete_files(s: *server, n: lsp::notification) void = {
	const params = match (n.params) {
	case let v: json::value => yield v;
	case void => return;
	};
	const obj = match (params) {
	case let o: json::object => yield o;
	case => return;
	};
	const dels = match (json::get(&obj, "files")) {
	case let p: *json::value =>
		yield match (*p) {
		case let a: []json::value => yield a;
		case => return;
		};
	case => return;
	};
	for (let i = 0z; i < len(dels); i += 1) {
		const item = match (dels[i]) {
		case let o: json::object => yield o;
		case => continue;
		};
		const uri = match (json::get(&item, "uri")) {
		case let p: *json::value =>
			yield match (*p) {
			case let s: str => yield s;
			case => continue;
			};
		case => continue;
		};
		// If we have it open, close it.
		for (let j = 0z; j < len(s.documents); j += 1) {
			if (s.documents[j].uri == uri) {
				clear_diagnostics(s, uri);
				finish_document(&s.documents[j]);
				delete(s.documents[j]);
				break;
			};
		};
	};
};

fn send_workspace_edit_or_null(s: *server, id: lsp::id, edit: (json::value | void)) void = {
	const result: json::value = match (edit) {
	case void => yield json::_null;
	case let v: json::value => yield v;
	};
	send_result_local(s, id, result);
	match (edit) {
	case void => void;
	case let v: json::value =>
		json::finish(v);
	};
};

fn send_result_local(s: *server, id: lsp::id, result: json::value) void = {
	match (lsp::encode_response_result(s.out, id, result)) {
	case size => void;
	case => void;
	};
};
