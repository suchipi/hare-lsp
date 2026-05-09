// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Core server state and the main message-handling loop.

use bufio;
use encoding::json;
use fmt;
use io;
use lsp;
use os;
use strings;

// State the server carries across the lifetime of a single client connection.
export type server = struct {
	// Lifecycle state:
	//   PRE_INIT  -> received nothing yet; only `initialize` allowed
	//   INITIALIZING -> initialize handled, waiting for `initialized`
	//   READY     -> normal operation
	//   SHUTTING_DOWN -> shutdown received; only `exit` allowed
	//   EXITED    -> exit received, loop should terminate
	state: server_state,

	// Trace level last requested by client via $/setTrace or initialize params.
	trace: lsp::trace_value,

	// Reader for incoming framed LSP messages.
	reader: lsp::reader,

	// Output handle for outgoing messages (typically os::stdout).
	out: io::handle,

	// Process id reported by the client during initialize, if any. Used to
	// auto-shut-down when the parent dies (per LSP spec).
	client_pid: (i32 | void),

	// Next id we will use for server-initiated requests.
	next_request_id: i64,

	// Counter for progress tokens (the strings rendered into $/progress
	// `token` fields).
	next_progress_token: u64,

	// Pending server-initiated requests awaiting a response from the client.
	// Keyed by request id; carries the method name so handlers can route
	// responses appropriately.
	pending_requests: []pending_request,

	// Active progress tokens that have received a workDoneProgress/cancel
	// notification from the client. Handlers should poll this set.
	cancelled_progress: []str,

	// Set of in-flight client request ids that have been issued $/cancelRequest
	// — handlers should consult this and abort early. Stored as a slice for
	// simplicity; LSP rarely cancels more than a handful at once.
	cancelled_ids: []lsp::id,

	// Active workspace folders, populated from initialize and updated via
	// workspace/didChangeWorkspaceFolders.
	workspace_folders: []workspace_folder,

	// Dynamic capability registrations issued via client/registerCapability.
	registrations: []registration,
	// Counter for synthesizing unique registration ids.
	next_registration_seq: u64,

	// Capabilities advertised by the client during initialize, kept in raw
	// json form so feature handlers can consult them without depending on a
	// parsed struct that grows with the spec.
	client_capabilities: (json::value | void),

	// User-configured server settings.
	config: config,
};

// Tracks an outgoing request the server is waiting on a response for.
export type pending_request = struct {
	id: i64,
	method: str,
};

export type server_state = enum {
	PRE_INIT,
	INITIALIZING,
	READY,
	SHUTTING_DOWN,
	EXITED,
};

// Process exit codes per LSP spec.
export def EXIT_OK: int = 0;
export def EXIT_ERROR: int = 1;

// Constructs a new server bound to the given input scanner and output handle.
// The scanner must outlive the server. Caller is responsible for finishing it.
export fn new(reader_src: *bufio::scanner, out: io::handle) server = server {
	state = server_state::PRE_INIT,
	trace = lsp::trace_value::OFF,
	reader = lsp::new_reader(reader_src),
	out = out,
	client_pid = void,
	next_request_id = 0,
	next_progress_token = 0,
	pending_requests = [],
	cancelled_progress = [],
	cancelled_ids = [],
	workspace_folders = [],
	registrations = [],
	next_registration_seq = 0,
	client_capabilities = void,
	config = default_config(),
};

// Releases resources held by the server. Does not close the underlying I/O
// handles — those are owned by the caller.
export fn finish(s: *server) void = {
	lsp::finish_reader(&s.reader);
	for (let i = 0z; i < len(s.cancelled_ids); i += 1) {
		match (s.cancelled_ids[i]) {
		case let str_id: str =>
			free(str_id);
		case f64 => void;
		};
	};
	free(s.cancelled_ids);
	for (let i = 0z; i < len(s.pending_requests); i += 1) {
		free(s.pending_requests[i].method);
	};
	free(s.pending_requests);
	for (let i = 0z; i < len(s.cancelled_progress); i += 1) {
		free(s.cancelled_progress[i]);
	};
	free(s.cancelled_progress);
	for (let i = 0z; i < len(s.workspace_folders); i += 1) {
		free(s.workspace_folders[i].uri);
		free(s.workspace_folders[i].name);
	};
	free(s.workspace_folders);
	for (let i = 0z; i < len(s.registrations); i += 1) {
		free(s.registrations[i].id);
		free(s.registrations[i].method);
	};
	free(s.registrations);
	match (s.client_capabilities) {
	case void => void;
	case let v: json::value =>
		json::finish(v);
	};
	finish_config(&s.config);
};

// Runs the main message loop until the client sends `exit` (or EOF). Returns
// the appropriate process exit code.
export fn run(s: *server) int = {
	for (s.state != server_state::EXITED) {
		const body = match (lsp::read(&s.reader)) {
		case let b: []u8 =>
			yield b;
		case io::EOF =>
			// Client closed connection without sending exit; per LSP
			// spec this is an error if we hadn't received shutdown.
			if (s.state == server_state::SHUTTING_DOWN) {
				return EXIT_OK;
			};
			log_stderr("client closed connection without exit");
			return EXIT_ERROR;
		case let e: lsp::transport_error =>
			log_stderr_strerror("transport error", lsp::strerror(e));
			return EXIT_ERROR;
		};

		const msg = match (lsp::decode(body)) {
		case let m: lsp::message =>
			yield m;
		case let e: lsp::decode_error =>
			// Structural error in a syntactically-valid JSON message.
			send_error(s, void, lsp::INVALID_REQUEST, e: str);
			continue;
		case let e: json::error =>
			// JSON itself failed to parse.
			send_error(s, void, lsp::PARSE_ERROR, json::strerror(e));
			continue;
		};

		dispatch(s, msg);
		lsp::finish_message(msg);
	};
	return EXIT_OK;
};

// Dispatches a single decoded message. Frees nothing — the caller frees the
// message after dispatch returns.
fn dispatch(s: *server, msg: lsp::message) void = {
	match (msg) {
	case let r: lsp::request =>
		handle_request(s, r);
	case let n: lsp::notification =>
		handle_notification(s, n);
	case let resp: lsp::response =>
		handle_response(s, resp);
	};
};

fn handle_response(s: *server, r: lsp::response) void = {
	const id_num = match (r.id) {
	case let f: f64 => yield f: i64;
	case let s: str =>
		// We never issue string ids ourselves.
		log_stderr("unexpected string-id response from client; ignoring");
		return;
	};
	const idx = pending_index(s, id_num);
	if (idx == -1) {
		log_stderr("response for unknown request id; ignoring");
		return;
	};
	const method = s.pending_requests[idx].method;
	match (r.body) {
	case let v: json::value =>
		switch (method) {
		case "workspace/configuration" =>
			apply_configuration_response(s, v);
		case "workspace/workspaceFolders" =>
			apply_workspace_folders_response(s, v);
		case =>
			// Other server-initiated requests (showMessageRequest,
			// showDocument, registerCapability,
			// workDoneProgress/create) don't currently need
			// further processing on success.
			void;
		};
	case let e: lsp::response_error =>
		fmt::fprintln(os::stderr, "hare-lsp: response error for",
			method, ":", e.message)!;
	};
	// Free and remove the pending entry.
	free(s.pending_requests[idx].method);
	delete(s.pending_requests[idx]);
};

// Returns the index of a pending request with the given id, or -1 if absent.
fn pending_index(s: *server, id: i64) int = {
	for (let i = 0z; i < len(s.pending_requests); i += 1) {
		if (s.pending_requests[i].id == id) return i: int;
	};
	return -1;
};

// Records a server-initiated request as pending. Caller should invoke this
// whenever encode_request succeeds. The method string is duplicated so the
// caller need not retain it.
export fn pending_remember(s: *server, id: i64, method: str) void = {
	append(s.pending_requests, pending_request {
		id = id,
		method = strings::dup(method)!,
	})!;
};

// Reports whether a previously-issued progress token has been cancelled by
// the client.
export fn progress_is_cancelled(s: *server, token: str) bool = {
	for (let i = 0z; i < len(s.cancelled_progress); i += 1) {
		if (s.cancelled_progress[i] == token) return true;
	};
	return false;
};

fn handle_request(s: *server, r: lsp::request) void = {
	// Lifecycle gating. Most methods are only valid in the READY state.
	switch (s.state) {
	case server_state::PRE_INIT =>
		if (r.method != "initialize") {
			send_error(s, r.id, lsp::SERVER_NOT_INITIALIZED,
				"server has not been initialized");
			return;
		};
	case server_state::SHUTTING_DOWN =>
		send_error(s, r.id, lsp::INVALID_REQUEST,
			"server is shutting down");
		return;
	case server_state::EXITED =>
		send_error(s, r.id, lsp::INVALID_REQUEST,
			"server has exited");
		return;
	case => void;
	};

	switch (r.method) {
	case "initialize" =>
		handle_initialize(s, r);
	case "shutdown" =>
		handle_shutdown(s, r);
	case =>
		send_error(s, r.id, lsp::METHOD_NOT_FOUND,
			fmt::asprintf("method not found: {}", r.method)!);
	};
};

fn handle_notification(s: *server, n: lsp::notification) void = {
	switch (n.method) {
	case "initialized" =>
		if (s.state == server_state::INITIALIZING) {
			s.state = server_state::READY;
			// Pull initial settings from the client.
			request_configuration(s);
		};
	case "exit" =>
		s.state = server_state::EXITED;
	case "$/cancelRequest" =>
		handle_cancel_request(s, n);
	case "$/setTrace" =>
		handle_set_trace(s, n);
	case "window/workDoneProgress/cancel" =>
		handle_progress_cancel(s, n);
	case "workspace/didChangeWorkspaceFolders" =>
		handle_did_change_workspace_folders(s, n);
	case "workspace/didChangeConfiguration" =>
		handle_did_change_configuration(s, n);
	case =>
		// Per LSP, unknown notifications are silently ignored.
		void;
	};
};

fn handle_progress_cancel(s: *server, n: lsp::notification) void = {
	const params = match (n.params) {
	case let v: json::value => yield v;
	case void => return;
	};
	const obj = match (params) {
	case let o: json::object => yield o;
	case => return;
	};
	const v = match (json::get(&obj, "token")) {
	case let v: *json::value => yield *v;
	case => return;
	};
	const token = match (v) {
	case let s: str => yield s;
	case => return;
	};
	append(s.cancelled_progress, strings::dup(token)!)!;
};

fn handle_initialize(s: *server, r: lsp::request) void = {
	if (s.state != server_state::PRE_INIT) {
		send_error(s, r.id, lsp::INVALID_REQUEST,
			"initialize received twice");
		return;
	};

	// Extract useful fields from params. The params are owned by the
	// `request` and freed when the message is finished, so anything we
	// want to retain must be deep-copied.
	const params_obj = match (r.params) {
	case let v: json::value =>
		yield match (v) {
		case let o: json::object => yield o: (json::object | void);
		case => yield void;
		};
	case void => yield void;
	};
	match (params_obj) {
	case void => void;
	case let o: json::object =>
		extract_init_param_pid(s, &o);
		extract_init_param_trace(s, &o);
		extract_init_param_capabilities(s, &o);
		extract_init_param_workspace_folders(s, &o);
	};

	const result = match (build_initialize_result()) {
	case let v: json::value => yield v;
	case nomem =>
		send_error(s, r.id, lsp::INTERNAL_ERROR, "out of memory");
		return;
	};
	defer json::finish(result);

	match (lsp::encode_response_result(s.out, r.id, result)) {
	case size => void;
	case let e: io::error =>
		log_stderr_strerror("write initialize response", io::strerror(e));
	};
	s.state = server_state::INITIALIZING;
};

fn build_initialize_result() (json::value | nomem) = {
	let r = json::newobject();
	let ok = false;
	defer if (!ok) json::finish(r);

	let caps = json::newobject();
	let caps_ok = false;
	defer if (!caps_ok) json::finish(caps);

	// Workspace capabilities — we support workspace folders.
	let ws = json::newobject();
	let ws_ok = false;
	defer if (!ws_ok) json::finish(ws);
	let folders_caps = json::newobject();
	json::put(&folders_caps, "supported", true: json::value)?;
	json::put(&folders_caps, "changeNotifications", true: json::value)?;
	json::put(&ws, "workspaceFolders", folders_caps)?;
	ws_ok = true;
	json::put(&caps, "workspace", ws)?;

	caps_ok = true;
	json::put(&r, "capabilities", caps)?;

	let info = json::newobject();
	let info_ok = false;
	defer if (!info_ok) json::finish(info);
	json::set(&info, "name", "hare-lsp": json::value)?;
	json::set(&info, "version", "0.0.1": json::value)?;
	info_ok = true;
	json::put(&r, "serverInfo", info)?;

	ok = true;
	return r;
};

fn extract_init_param_pid(s: *server, o: *json::object) void = {
	match (json::get(o, "processId")) {
	case let p: *json::value =>
		match (*p) {
		case let f: f64 =>
			s.client_pid = f: i32;
		case => void;
		};
	case => void;
	};
};

fn extract_init_param_trace(s: *server, o: *json::object) void = {
	match (json::get(o, "trace")) {
	case let p: *json::value =>
		match (*p) {
		case let str_val: str =>
			s.trace = parse_trace(str_val);
		case => void;
		};
	case => void;
	};
};

fn extract_init_param_capabilities(s: *server, o: *json::object) void = {
	const caps = match (json::get(o, "capabilities")) {
	case let p: *json::value => yield *p;
	case => return;
	};
	// Deep-copy via json::dup so we own the result independently of the
	// request's lifetime.
	const dup = match (json::dup(caps)) {
	case let v: json::value => yield v;
	case nomem => return;
	};
	s.client_capabilities = dup;
};

fn extract_init_param_workspace_folders(s: *server, o: *json::object) void = {
	// Prefer workspaceFolders if present; fall back to rootUri / rootPath
	// for older clients that haven't migrated.
	match (json::get(o, "workspaceFolders")) {
	case let p: *json::value =>
		const folders = decode_workspace_folders(*p);
		set_workspace_folders(s, folders);
		return;
	case => void;
	};
	const root_uri = match (json::get(o, "rootUri")) {
	case let p: *json::value =>
		yield match (*p) {
		case let s: str => yield s;
		case => return;
		};
	case => return;
	};
	let folders: []workspace_folder = alloc([], 1)!;
	append(folders, workspace_folder {
		uri = strings::dup(root_uri)!,
		name = strings::dup("")!,
	})!;
	set_workspace_folders(s, folders);
};

fn handle_shutdown(s: *server, r: lsp::request) void = {
	s.state = server_state::SHUTTING_DOWN;
	const result: json::value = json::_null;
	match (lsp::encode_response_result(s.out, r.id, result)) {
	case size => void;
	case let e: io::error =>
		log_stderr_strerror("write shutdown response", io::strerror(e));
	};
};

fn handle_cancel_request(s: *server, n: lsp::notification) void = {
	const params = match (n.params) {
	case let v: json::value => yield v;
	case void => return;
	};
	const obj = match (params) {
	case let o: json::object => yield o;
	case => return;
	};
	const id_v = match (json::get(&obj, "id")) {
	case let v: *json::value => yield *v;
	case => return;
	};
	const id: lsp::id = match (id_v) {
	case let f: f64 => yield f;
	case let s: str => yield strings::dup(s)!;
	case => return;
	};
	append(s.cancelled_ids, id)!;
};

fn handle_set_trace(s: *server, n: lsp::notification) void = {
	const params = match (n.params) {
	case let v: json::value => yield v;
	case void => return;
	};
	const obj = match (params) {
	case let o: json::object => yield o;
	case => return;
	};
	const v = match (json::get(&obj, "value")) {
	case let v: *json::value => yield *v;
	case => return;
	};
	const str_val = match (v) {
	case let s: str => yield s;
	case => return;
	};
	s.trace = parse_trace(str_val);
};

fn parse_trace(v: str) lsp::trace_value = {
	switch (v) {
	case "off" => return lsp::trace_value::OFF;
	case "messages" => return lsp::trace_value::MESSAGES;
	case "verbose" => return lsp::trace_value::VERBOSE;
	case => return lsp::trace_value::OFF;
	};
};

fn send_error(s: *server, id: (lsp::id | void), code: lsp::error_code, msg: str) void = {
	const err = lsp::response_error {
		code = code,
		message = msg,
		data = void,
	};
	match (lsp::encode_response_error(s.out, id, err)) {
	case size => void;
	case let e: io::error =>
		log_stderr_strerror("write error response", io::strerror(e));
	};
};

// Logs a message to stderr. Used for unrecoverable transport-level errors;
// most user-visible logging goes through window/logMessage (added in step 2).
fn log_stderr(msg: str) void = {
	fmt::fprintln(os::stderr, "hare-lsp:", msg)!;
};

fn log_stderr_strerror(prefix: str, msg: str) void = {
	fmt::fprintln(os::stderr, "hare-lsp:", prefix, ":", msg)!;
};
