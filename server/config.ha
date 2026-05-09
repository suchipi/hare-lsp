// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Configuration: settings the user supplies via the LSP client. We pull these
// at startup with `workspace/configuration`, and refresh on
// `workspace/didChangeConfiguration`.
//
// All fields are optional; defaults are populated by [[default_config]] and
// [[apply_settings]] only overwrites fields the client actually provided.

use encoding::json;
use lsp;
use strings;

// Server-side configuration. Fields here are derived from per-workspace
// settings under the "hare" namespace.
export type config = struct {
	// Path to the `hare` binary. Defaults to the value found in PATH.
	hare_path: str,

	// Build tags passed to `hare build` and module resolution. e.g.
	// ["+linux", "+x86_64"].
	tags: []str,

	// Diagnostics debounce interval in milliseconds. After the last
	// document change, the server waits this long before invoking
	// `hare build` for type-check diagnostics. Defaults to 300.
	diagnostics_debounce_ms: u32,

	// Whether to surface `hare build` (type-check) diagnostics in addition
	// to in-process parse diagnostics. Defaults to true.
	enable_build_diagnostics: bool,

	// Format options.
	format_indent_style: indent_style,
	format_indent_width: u32,
	format_trim_final_newlines: bool,
	format_insert_final_newline: bool,

	// Whether to render inlay hints for parameter names and inferred types.
	inlay_hints_parameter_names: bool,
	inlay_hints_inferred_types: bool,
};

// Indent style for formatter output.
export type indent_style = enum {
	TAB,
	SPACE,
};

// Returns the default configuration (used until the client provides values).
export fn default_config() config = config {
	hare_path = strings::dup("hare")!,
	tags = [],
	diagnostics_debounce_ms = 300,
	enable_build_diagnostics = true,
	format_indent_style = indent_style::TAB,
	format_indent_width = 8,
	format_trim_final_newlines = true,
	format_insert_final_newline = true,
	inlay_hints_parameter_names = true,
	inlay_hints_inferred_types = true,
};

// Releases memory owned by the config.
export fn finish_config(c: *config) void = {
	free(c.hare_path);
	for (let i = 0z; i < len(c.tags); i += 1) {
		free(c.tags[i]);
	};
	free(c.tags);
};

// Sends a workspace/configuration request to pull the "hare" settings
// section. The eventual response is passed to [[apply_configuration_response]].
// Returns the request id, or void on transport failure.
export fn request_configuration(s: *server) (i64 | void) = {
	const id = next_outgoing_id(s);
	let params = json::newobject();
	defer json::finish(params);

	let items: []json::value = [];
	let ok = false;
	defer if (!ok) {
		for (let i = 0z; i < len(items); i += 1) {
			json::finish(items[i]);
		};
		free(items);
	};

	let item = json::newobject();
	json::set(&item, "section", "hare": json::value)!;
	append(items, item: json::value)!;

	json::put(&params, "items", items: json::value)!;
	ok = true;

	if (!send_request(s, id, "workspace/configuration", params)) {
		return void;
	};
	pending_remember(s, id, "workspace/configuration");
	return id;
};

// Applies a workspace/configuration response. The result is an array of
// settings objects matching the items requested. We requested one item under
// section "hare", so we expect a single-element array.
export fn apply_configuration_response(s: *server, result: json::value) void = {
	const arr = match (result) {
	case let a: []json::value => yield a;
	case => return;
	};
	if (len(arr) == 0) return;
	apply_settings(s, arr[0]);
};

// Handles the workspace/didChangeConfiguration notification.
//
// Per the LSP spec, the `settings` field of params contains the new settings,
// but its shape depends on the client. We accept either:
//   - The settings already-namespaced (`{"hare": {...}}`), or
//   - The "hare" section's contents directly.
//
// If the field is null (e.g. some clients send `{"settings":null}` then expect
// the server to re-pull), we issue a fresh workspace/configuration request.
export fn handle_did_change_configuration(s: *server, n: lsp::notification) void = {
	const params = match (n.params) {
	case let v: json::value => yield v;
	case void => return;
	};
	const obj = match (params) {
	case let o: json::object => yield o;
	case => return;
	};
	const settings = match (json::get(&obj, "settings")) {
	case let p: *json::value => yield *p;
	case =>
		// Fall back to a pull.
		request_configuration(s);
		return;
	};
	// Some clients send `null` to signal "re-pull".
	if (settings is json::_null) {
		request_configuration(s);
		return;
	};
	// If it has a "hare" key, drill in; otherwise treat the value itself
	// as the hare section.
	match (settings) {
	case let o: json::object =>
		match (json::get(&o, "hare")) {
		case let p: *json::value =>
			apply_settings(s, *p);
			return;
		case => void;
		};
	case => void;
	};
	apply_settings(s, settings);
};

// Applies a settings value (the "hare" section) into the server's config.
// Only fields present in the json are updated; absent fields keep their
// existing values.
export fn apply_settings(s: *server, v: json::value) void = {
	const o = match (v) {
	case let o: json::object => yield o;
	case => return;
	};

	match (json::get(&o, "path")) {
	case let p: *json::value =>
		match (*p) {
		case let str_val: str =>
			free(s.config.hare_path);
			s.config.hare_path = strings::dup(str_val)!;
		case => void;
		};
	case => void;
	};

	match (json::get(&o, "tags")) {
	case let p: *json::value =>
		match (*p) {
		case let arr: []json::value =>
			for (let i = 0z; i < len(s.config.tags); i += 1) {
				free(s.config.tags[i]);
			};
			free(s.config.tags);
			s.config.tags = [];
			for (let i = 0z; i < len(arr); i += 1) {
				match (arr[i]) {
				case let s2: str =>
					append(s.config.tags, strings::dup(s2)!)!;
				case => void;
				};
			};
		case => void;
		};
	case => void;
	};

	// "diagnostics": {"debounceMs": N, "enableBuild": bool}
	match (json::get(&o, "diagnostics")) {
	case let p: *json::value =>
		match (*p) {
		case let dobj: json::object =>
			match (json::get(&dobj, "debounceMs")) {
			case let dp: *json::value =>
				match (*dp) {
				case let f: f64 =>
					if (f >= 0.0) {
						s.config.diagnostics_debounce_ms = f: u32;
					};
				case => void;
				};
			case => void;
			};
			match (json::get(&dobj, "enableBuild")) {
			case let dp: *json::value =>
				match (*dp) {
				case let b: bool =>
					s.config.enable_build_diagnostics = b;
				case => void;
				};
			case => void;
			};
		case => void;
		};
	case => void;
	};

	// "format": {"indentStyle": "tab"|"space", "indentWidth": N,
	//   "trimFinalNewlines": bool, "insertFinalNewline": bool}
	match (json::get(&o, "format")) {
	case let p: *json::value =>
		match (*p) {
		case let fobj: json::object =>
			match (json::get(&fobj, "indentStyle")) {
			case let fp: *json::value =>
				match (*fp) {
				case let str_val: str =>
					switch (str_val) {
					case "tab" =>
						s.config.format_indent_style = indent_style::TAB;
					case "space" =>
						s.config.format_indent_style = indent_style::SPACE;
					case => void;
					};
				case => void;
				};
			case => void;
			};
			match (json::get(&fobj, "indentWidth")) {
			case let fp: *json::value =>
				match (*fp) {
				case let f: f64 =>
					if (f > 0.0) {
						s.config.format_indent_width = f: u32;
					};
				case => void;
				};
			case => void;
			};
			match (json::get(&fobj, "trimFinalNewlines")) {
			case let fp: *json::value =>
				match (*fp) {
				case let b: bool =>
					s.config.format_trim_final_newlines = b;
				case => void;
				};
			case => void;
			};
			match (json::get(&fobj, "insertFinalNewline")) {
			case let fp: *json::value =>
				match (*fp) {
				case let b: bool =>
					s.config.format_insert_final_newline = b;
				case => void;
				};
			case => void;
			};
		case => void;
		};
	case => void;
	};

	// "inlayHints": {"parameterNames": bool, "inferredTypes": bool}
	match (json::get(&o, "inlayHints")) {
	case let p: *json::value =>
		match (*p) {
		case let iobj: json::object =>
			match (json::get(&iobj, "parameterNames")) {
			case let ip: *json::value =>
				match (*ip) {
				case let b: bool =>
					s.config.inlay_hints_parameter_names = b;
				case => void;
				};
			case => void;
			};
			match (json::get(&iobj, "inferredTypes")) {
			case let ip: *json::value =>
				match (*ip) {
				case let b: bool =>
					s.config.inlay_hints_inferred_types = b;
				case => void;
				};
			case => void;
			};
		case => void;
		};
	case => void;
	};
};
