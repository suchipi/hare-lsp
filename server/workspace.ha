// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Workspace folder tracking. Per LSP spec the server can:
//   - Receive workspace folders during `initialize` (workspaceFolders field).
//   - Pull the current set with the workspace/workspaceFolders request.
//   - Listen for workspace/didChangeWorkspaceFolders notifications.
//
// Folders are addressed by URI; a `name` string is provided for display.
// Later steps build per-folder module-graph indexes off this list.

use analysis;
use encoding::json;
use lsp;
use strings;

// A workspace folder.
export type workspace_folder = struct {
	uri: str,
	name: str,
};

// Replaces the server's workspace folder list. Takes ownership of the slice
// elements' strings — caller transfers them in. The previous list is freed.
export fn set_workspace_folders(
	s: *server,
	folders: []workspace_folder,
) void = {
	for (let i = 0z; i < len(s.workspace_folders); i += 1) {
		free(s.workspace_folders[i].uri);
		free(s.workspace_folders[i].name);
	};
	free(s.workspace_folders);
	s.workspace_folders = folders;
};

// Returns true if a folder with the given URI is currently known.
export fn has_workspace_folder(s: *server, uri: str) bool = {
	for (let i = 0z; i < len(s.workspace_folders); i += 1) {
		if (s.workspace_folders[i].uri == uri) return true;
	};
	return false;
};

// Decodes the `workspaceFolders` array from initialize params, returning a
// freshly-allocated slice the caller takes ownership of.
//
// Accepts either an array of {uri, name} objects, or null/missing. A `rootUri`
// fallback is handled by the caller (initialize) to keep this function
// focused on the array shape.
export fn decode_workspace_folders(v: json::value) []workspace_folder = {
	const arr = match (v) {
	case let a: []json::value =>
		yield a;
	case =>
		return [];
	};
	let out: []workspace_folder = alloc([], len(arr))!;
	for (let i = 0z; i < len(arr); i += 1) {
		const o = match (arr[i]) {
		case let o: json::object =>
			yield o;
		case =>
			continue;
		};
		const uri = match (json::get(&o, "uri")) {
		case let p: *json::value =>
			yield match (*p) {
			case let s: str =>
				yield strings::dup(s)!;
			case =>
				continue;
			};
		case =>
			continue;
		};
		const name = match (json::get(&o, "name")) {
		case let p: *json::value =>
			yield match (*p) {
			case let s: str =>
				yield strings::dup(s)!;
			case =>
				yield strings::dup("")!;
			};
		case =>
			yield strings::dup("")!;
		};
		append(out, workspace_folder { uri = uri, name = name })!;
	};
	return out;
};

// Sends a workspace/workspaceFolders request to the client. Returns the
// outgoing request id, or void on transport failure. The eventual response
// is processed by [[apply_workspace_folders_response]].
export fn request_workspace_folders(s: *server) (i64 | void) = {
	const id = next_outgoing_id(s);
	if (!send_request(s, id, "workspace/workspaceFolders", json::_null)) {
		return void;
	};
	pending_remember(s, id, "workspace/workspaceFolders");
	return id;
};

// Applies the result payload from a workspace/workspaceFolders response. The
// payload is either a json array of folder objects or null.
export fn apply_workspace_folders_response(
	s: *server,
	result: json::value,
) void = {
	const folders = decode_workspace_folders(result);
	set_workspace_folders(s, folders);
};

// Handles a workspace/didChangeWorkspaceFolders notification. The event has
// `added` and `removed` arrays. Removed folders have their indexed
// entries dropped; added folders are immediately scanned and indexed
// so workspace-wide features see the new content.
export fn handle_did_change_workspace_folders(
	s: *server,
	n: lsp::notification,
) void = {
	const params = match (n.params) {
	case let v: json::value =>
		yield v;
	case void =>
		return;
	};
	const obj = match (params) {
	case let o: json::object =>
		yield o;
	case =>
		return;
	};
	const event = match (json::get(&obj, "event")) {
	case let p: *json::value =>
		yield match (*p) {
		case let o: json::object =>
			yield o;
		case =>
			return;
		};
	case =>
		return;
	};

	// Apply removals first.
	let removed_paths: []str = [];
	defer {
		for (let i = 0z; i < len(removed_paths); i += 1) {
			free(removed_paths[i]);
		};
		free(removed_paths);
	};
	match (json::get(&event, "removed")) {
	case let p: *json::value =>
		match (*p) {
		case let arr: []json::value =>
			for (let i = 0z; i < len(arr); i += 1) {
				match (arr[i]) {
				case let o: json::object =>
					match (json::get(&o, "uri")) {
					case let pv: *json::value =>
						match (*pv) {
						case let uri: str =>
							append(removed_paths, uri_to_dir_path(uri))!;
							remove_workspace_folder(s, uri);
						case => void;
						};
					case => void;
					};
				case => void;
				};
			};
		case => void;
		};
	case => void;
	};
	// Drop index entries for any removed folder.
	for (let i = 0z; i < len(removed_paths); i += 1) {
		drop_index_entries_under(s, removed_paths[i]);
		file_parse_cache_drop_under(&s.file_parse_cache, removed_paths[i]);
	};

	// Then additions.
	match (json::get(&event, "added")) {
	case let p: *json::value =>
		const new = decode_workspace_folders(*p);
		let roots: []str = [];
		defer {
			for (let j = 0z; j < len(roots); j += 1) free(roots[j]);
			free(roots);
		};
		for (let i = 0z; i < len(new); i += 1) {
			append(s.workspace_folders, new[i])!;
			append(roots, uri_to_dir_path(new[i].uri))!;
		};
		free(new);
		if (len(roots) > 0) {
			start_index_job(s, roots, &s.workspace_index, "Indexing workspace",
				"hare-lsp: indexed");
		};
	case => void;
	};
};

// Strips the "file://" scheme and percent-decodes to yield a
// directory path. Workspace folder URIs use this scheme exclusively
// in practice.
fn uri_to_dir_path(uri: str) str = lsp::uri_decode_path(uri);

// Drops every workspace_index entry whose path is under `root_dir`.
// Used when a workspace folder is removed.
fn drop_index_entries_under(s: *server, root_dir: str) void = {
	// Build a prefix that matches "root_dir/" so we don't drop entries
	// from sibling directories that happen to share a name prefix.
	const prefix = strings::concat(root_dir, "/")!;
	defer free(prefix);
	// Snapshot the paths we need to drop, because drop_file mutates
	// the entries slice while we iterate.
	let paths_to_drop: []str = [];
	defer {
		for (let i = 0z; i < len(paths_to_drop); i += 1) {
			free(paths_to_drop[i]);
		};
		free(paths_to_drop);
	};
	for (let i = 0z; i < len(s.workspace_index.entries); i += 1) {
		const p = s.workspace_index.entries[i].path;
		if (strings::hasprefix(p, prefix) || p == root_dir) {
			let already = false;
			for (let j = 0z; j < len(paths_to_drop); j += 1) {
				if (paths_to_drop[j] == p) {
					already = true;
					break;
				};
			};
			if (!already) {
				append(paths_to_drop, strings::dup(p)!)!;
			};
		};
	};
	for (let i = 0z; i < len(paths_to_drop); i += 1) {
		analysis::drop_file(&s.workspace_index, paths_to_drop[i]);
	};
};

fn remove_workspace_folder(s: *server, uri: str) void = {
	for (let i = 0z; i < len(s.workspace_folders); i += 1) {
		if (s.workspace_folders[i].uri == uri) {
			free(s.workspace_folders[i].uri);
			free(s.workspace_folders[i].name);
			delete(s.workspace_folders[i]);
			return;
		};
	};
};
