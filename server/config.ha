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
	//
	// @owned
	hare_path: str,
	// Colon-separated list of directories searched for Hare modules
	// (mirrors the $HAREPATH env var). Empty string means "use $HAREPATH
	// from the environment, falling back to the platform default".
	//
	// @owned
	harepath: str,
	// Build tags passed to `hare build` and module resolution. e.g.
	// ["+linux", "+x86_64"].
	//
	// @owned
	tags: []str,
	// Diagnostics debounce interval in milliseconds. After the last
	// document change, the server waits this long before invoking
	// `hare build` for type-check diagnostics. Defaults to 300.
	diagnostics_debounce_ms: u32,
	// Whether to surface `hare build` (type-check) diagnostics in addition
	// to in-process parse diagnostics. Defaults to true.
	enable_build_diagnostics: bool,
	// Maximum wall-clock milliseconds for the whole didSave build
	// pass — the dep walker may spawn `hare build -t o` once per
	// local module, and this budget is shared across all of them.
	// When the deadline elapses mid-walk, the current subprocess is
	// SIGTERM'd and remaining modules are skipped. Defaults to 60000
	// (60s); set to 0 to disable the deadline (waits indefinitely).
	build_timeout_ms: u32,
	// Whether to wrap the hover Ownership line in `<small>` so HTML-aware
	// clients (VSCode) render it as fine print. Disable for editors that
	// don't render HTML in hover markdown (Neovim, Helix, Emacs default
	// renderers) to avoid showing literal `<small>` tags. Default true.
	hover_use_html: bool,
	// Whether to render inlay hints for parameter names and inferred types.
	inlay_hints_parameter_names: bool,
	inlay_hints_inferred_types: bool,
	// Max recursion depth for inferred-type label rendering. 0 disables
	// inlay-hint inferred types entirely; higher values let the renderer
	// walk further along function-call return types, local-identifier
	// bindings (via `infer_access_expr_type` in navigation.ha — affects
	// hover for local lets too, not just inlay hints), and type aliases.
	// Alias chains are also cycle-guarded by visited-set tracking in
	// [[follow_alias_chain]], so an unbounded value won't loop.
	inlay_hints_inferred_types_max_depth: u32,
	// Configurable resource caps. See [[limits]] / [[default_limits]].
	limits: limits,
};

// Returns the default configuration (used until the client provides values).
export fn default_config() config = config {
	hare_path = strings::dup("hare")!,
	harepath = strings::dup("")!,
	tags = [],
	diagnostics_debounce_ms = 300,
	enable_build_diagnostics = true,
	build_timeout_ms = 60000,
	hover_use_html = true,
	inlay_hints_parameter_names = true,
	inlay_hints_inferred_types = true,
	inlay_hints_inferred_types_max_depth = 10,
	limits = default_limits(),
};

// Releases memory owned by the config.
//
// @param c: borrowed
export fn finish_config(c: *config) void = {
	free(c.hare_path);
	free(c.harepath);
	for (let i = 0z; i < len(c.tags); i += 1) {
		free(c.tags[i]);
	};
	free(c.tags);
};

// Sends a workspace/configuration request to pull the "hare" settings
// section. The eventual response is passed to [[apply_configuration_response]].
// Returns the request id, or void on transport failure.
//
// @param s: borrowed
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
//
// @param s: borrowed
// @param result: borrowed
export fn apply_configuration_response(s: *server, result: json::value) void = {
	const arr = match (result) {
	case let a: []json::value =>
		yield a;
	case =>
		return;
	};
	if (len(arr) == 0) return;
	const old_debounce = s.config.diagnostics_debounce_ms;
	const old_enable_build = s.config.enable_build_diagnostics;
	const old_ih_params = s.config.inlay_hints_parameter_names;
	const old_ih_inferred = s.config.inlay_hints_inferred_types;
	const old_ih_depth = s.config.inlay_hints_inferred_types_max_depth;
	apply_settings(s, arr[0]);
	refresh_after_config_change(s, old_debounce, old_enable_build, old_ih_params,
		old_ih_inferred, old_ih_depth);
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
//
// @param s: borrowed
export fn handle_did_change_configuration(
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
	const settings = match (json::get(&obj, "settings")) {
	case let p: *json::value =>
		yield *p;
	// Fall back to a pull.

	case =>
		request_configuration(s);
		return;
	};
	// Some clients send `null` to signal "re-pull".
	if (settings is json::_null) {
		request_configuration(s);
		return;
	};

	// Snapshot the fields whose change should trigger downstream refresh.
	const old_debounce = s.config.diagnostics_debounce_ms;
	const old_enable_build = s.config.enable_build_diagnostics;
	const old_ih_params = s.config.inlay_hints_parameter_names;
	const old_ih_inferred = s.config.inlay_hints_inferred_types;
	const old_ih_depth = s.config.inlay_hints_inferred_types_max_depth;

	// If it has a "hare" key, drill in; otherwise treat the value itself
	// as the hare section.
	match (settings) {
	case let o: json::object =>
		match (json::get(&o, "hare")) {
		case let p: *json::value =>
			apply_settings(s, *p);
			refresh_after_config_change(s, old_debounce, old_enable_build, old_ih_params,
				old_ih_inferred, old_ih_depth);
			return;
		case => void;
		};
	case => void;
	};
	apply_settings(s, settings);
	refresh_after_config_change(s, old_debounce, old_enable_build, old_ih_params,
		old_ih_inferred, old_ih_depth);
};

// Re-publishes diagnostics and sends inlayHint/refresh when the
// corresponding settings actually changed.
//
// @param s: borrowed
fn refresh_after_config_change(
	s: *server,
	old_debounce: u32,
	old_enable_build: bool,
	old_ih_params: bool,
	old_ih_inferred: bool,
	old_ih_depth: u32,
) void = {
	const diag_changed =
		old_debounce != s.config.diagnostics_debounce_ms ||
		old_enable_build != s.config.enable_build_diagnostics;
	const ih_changed =
		old_ih_params != s.config.inlay_hints_parameter_names ||
		old_ih_inferred != s.config.inlay_hints_inferred_types ||
		old_ih_depth != s.config.inlay_hints_inferred_types_max_depth;

	if (diag_changed) {
		// Republish parse diagnostics for every open doc immediately
		// (bypassing the debounce — the user explicitly asked to
		// change diagnostics behavior).
		for (let i = 0z; i < len(s.documents); i += 1) {
			refresh_diagnostics(s, &s.documents[i]);
		};
	};
	if (ih_changed) {
		request_inlay_hint_refresh(s);
	};
};

// Applies a settings value (the "hare" section) into the server's config.
// Only fields present in the json are updated; absent fields keep their
// existing values.
//
// @param s: borrowed
// @param v: borrowed
export fn apply_settings(s: *server, v: json::value) void = {
	const o = match (v) {
	case let o: json::object =>
		yield o;
	case =>
		return;
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

	match (json::get(&o, "harepath")) {
	case let p: *json::value =>
		match (*p) {
		case let str_val: str =>
			free(s.config.harepath);
			s.config.harepath = strings::dup(str_val)!;
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
			match (json::get(&dobj, "buildTimeoutMs")) {
			case let dp: *json::value =>
				match (*dp) {
				case let f: f64 =>
					if (f >= 0.0) {
						s.config.build_timeout_ms = f: u32;
					};
				case => void;
				};
			case => void;
			};
		case => void;
		};
	case => void;
	};

	// "hover": {"useHtml": bool}
	match (json::get(&o, "hover")) {
	case let p: *json::value =>
		match (*p) {
		case let hobj: json::object =>
			match (json::get(&hobj, "useHtml")) {
			case let hp: *json::value =>
				match (*hp) {
				case let b: bool =>
					s.config.hover_use_html = b;
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
			match (json::get(&iobj, "inferredTypesMaxDepth")) {
			case let ip: *json::value =>
				match (*ip) {
				case let f: f64 =>
					if (f >= 0.0) {
						s.config.inlay_hints_inferred_types_max_depth = f: u32;
					};
				case => void;
				};
			case => void;
			};
		case => void;
		};
	case => void;
	};

	// "limits": { maxTotalBufferBytes, maxDiagnosticsPerFile }
	match (json::get(&o, "limits")) {
	case let p: *json::value =>
		match (*p) {
		case let lobj: json::object =>
			apply_limit_u64(&lobj, "maxTotalBufferBytes",
				&s.config.limits.max_total_buffer_bytes);
			apply_limit_u64(&lobj, "maxDiagnosticsPerFile",
				&s.config.limits.max_diagnostics_per_file);
		case => void;
		};
	case => void;
	};
};

// Reads a positive integer from `lobj[key]` into `*out`. Ignores
// missing keys, non-numeric values, and any value < 1: zero would
// disable core functionality (e.g. no documents can be opened), which
// a misbehaving client shouldn't be able to do via a raw
// didChangeConfiguration payload. Partial settings don't clobber the
// existing value.
//
// @param lobj: borrowed
// @param key: borrowed
// @param out: borrowed
fn apply_limit_u64(lobj: *json::object, key: str, out: *size) void = {
	match (json::get(lobj, key)) {
	case let p: *json::value =>
		match (*p) {
		case let f: f64 =>
			if (f >= 1.0) *out = f: size;
		case => void;
		};
	case => void;
	};
};
