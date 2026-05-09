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
export fn set_workspace_folders(s: *server, folders: []workspace_folder) void = {
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
	case let a: []json::value => yield a;
	case => return [];
	};
	let out: []workspace_folder = alloc([], len(arr))!;
	for (let i = 0z; i < len(arr); i += 1) {
		const o = match (arr[i]) {
		case let o: json::object => yield o;
		case => continue;
		};
		const uri = match (json::get(&o, "uri")) {
		case let p: *json::value =>
			yield match (*p) {
			case let s: str => yield strings::dup(s)!;
			case => continue;
			};
		case => continue;
		};
		const name = match (json::get(&o, "name")) {
		case let p: *json::value =>
			yield match (*p) {
			case let s: str => yield strings::dup(s)!;
			case => yield strings::dup("")!;
			};
		case => yield strings::dup("")!;
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
export fn apply_workspace_folders_response(s: *server, result: json::value) void = {
	const folders = decode_workspace_folders(result);
	set_workspace_folders(s, folders);
};

// Handles a workspace/didChangeWorkspaceFolders notification. The event has
// `added` and `removed` arrays.
export fn handle_did_change_workspace_folders(s: *server, n: lsp::notification) void = {
	const params = match (n.params) {
	case let v: json::value => yield v;
	case void => return;
	};
	const obj = match (params) {
	case let o: json::object => yield o;
	case => return;
	};
	const event = match (json::get(&obj, "event")) {
	case let p: *json::value =>
		yield match (*p) {
		case let o: json::object => yield o;
		case => return;
		};
	case => return;
	};

	// Apply removals first.
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

	// Then additions.
	match (json::get(&event, "added")) {
	case let p: *json::value =>
		const new = decode_workspace_folders(*p);
		for (let i = 0z; i < len(new); i += 1) {
			append(s.workspace_folders, new[i])!;
		};
		free(new);
	case => void;
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
