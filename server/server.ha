// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Core server state and the main message-handling loop.

use analysis;
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

	// Open documents, keyed by URI.
	documents: []document,

	// Workspace-wide symbol index.
	workspace_index: analysis::workspace_index,
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
	documents = [],
	workspace_index = analysis::new_workspace_index(),
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
	for (let i = 0z; i < len(s.documents); i += 1) {
		finish_document(&s.documents[i]);
	};
	free(s.documents);
	analysis::finish_workspace_index(&s.workspace_index);
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
	case "textDocument/willSaveWaitUntil" =>
		handle_will_save_wait_until(s, r);
	case "textDocument/diagnostic" =>
		handle_textdocument_diagnostic(s, r);
	case "workspace/diagnostic" =>
		handle_workspace_diagnostic(s, r);
	case "workspace/symbol" =>
		handle_workspace_symbol(s, r);
	case "workspaceSymbol/resolve" =>
		handle_workspace_symbol_resolve(s, r);
	case "workspace/willCreateFiles" =>
		handle_will_create_files(s, r);
	case "workspace/willRenameFiles" =>
		handle_will_rename_files(s, r);
	case "workspace/willDeleteFiles" =>
		handle_will_delete_files(s, r);
	case "textDocument/hover" =>
		handle_hover(s, r);
	case "textDocument/definition" =>
		handle_definition(s, r);
	case "textDocument/declaration" =>
		handle_declaration(s, r);
	case "textDocument/typeDefinition" =>
		handle_type_definition(s, r);
	case "textDocument/implementation" =>
		handle_implementation(s, r);
	case "textDocument/documentSymbol" =>
		handle_document_symbol(s, r);
	case "textDocument/documentHighlight" =>
		handle_document_highlight(s, r);
	case "textDocument/foldingRange" =>
		handle_folding_range(s, r);
	case "textDocument/selectionRange" =>
		handle_selection_range(s, r);
	case "textDocument/documentLink" =>
		handle_document_link(s, r);
	case "documentLink/resolve" =>
		handle_document_link_resolve(s, r);
	case "textDocument/references" =>
		handle_references(s, r);
	case "textDocument/prepareRename" =>
		handle_prepare_rename(s, r);
	case "textDocument/rename" =>
		handle_rename(s, r);
	case "textDocument/prepareCallHierarchy" =>
		handle_prepare_call_hierarchy(s, r);
	case "callHierarchy/incomingCalls" =>
		handle_incoming_calls(s, r);
	case "callHierarchy/outgoingCalls" =>
		handle_outgoing_calls(s, r);
	case "textDocument/prepareTypeHierarchy" =>
		handle_prepare_type_hierarchy(s, r);
	case "typeHierarchy/supertypes" =>
		handle_supertypes(s, r);
	case "typeHierarchy/subtypes" =>
		handle_subtypes(s, r);
	case "textDocument/completion" =>
		handle_completion(s, r);
	case "completionItem/resolve" =>
		handle_completion_resolve(s, r);
	case "textDocument/signatureHelp" =>
		handle_signature_help(s, r);
	case "textDocument/formatting" =>
		handle_formatting(s, r);
	case "textDocument/rangeFormatting" =>
		handle_range_formatting(s, r);
	case "textDocument/onTypeFormatting" =>
		handle_on_type_formatting(s, r);
	case "textDocument/semanticTokens/full" =>
		handle_semantic_tokens_full(s, r);
	case "textDocument/semanticTokens/full/delta" =>
		handle_semantic_tokens_full_delta(s, r);
	case "textDocument/semanticTokens/range" =>
		handle_semantic_tokens_range(s, r);
	case "textDocument/inlayHint" =>
		handle_inlay_hint(s, r);
	case "inlayHint/resolve" =>
		handle_inlay_hint_resolve(s, r);
	case "textDocument/codeLens" =>
		handle_code_lens(s, r);
	case "codeLens/resolve" =>
		handle_code_lens_resolve(s, r);
	case "textDocument/codeAction" =>
		handle_code_action(s, r);
	case "codeAction/resolve" =>
		handle_code_action_resolve(s, r);
	case "workspace/executeCommand" =>
		handle_execute_command(s, r);
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
			// Ask the client to watch *.ha and *.s files.
			register_file_watchers(s);
			// Build the initial workspace index.
			scan_workspace_folders(s);
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
	case "textDocument/didOpen" =>
		handle_did_open(s, n);
	case "textDocument/didChange" =>
		handle_did_change(s, n);
	case "textDocument/didClose" =>
		handle_did_close(s, n);
	case "textDocument/didSave" =>
		handle_did_save(s, n);
	case "textDocument/willSave" =>
		handle_will_save(s, n);
	case "workspace/didChangeWatchedFiles" =>
		handle_did_change_watched_files(s, n);
	case "workspace/didCreateFiles" =>
		handle_did_create_files(s, n);
	case "workspace/didRenameFiles" =>
		handle_did_rename_files(s, n);
	case "workspace/didDeleteFiles" =>
		handle_did_delete_files(s, n);
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

	// Text document sync: incremental, with willSave/willSaveWaitUntil/save.
	let tds = json::newobject();
	json::put(&tds, "openClose", true: json::value)?;
	// 1 = Full, 2 = Incremental.
	json::put(&tds, "change", 2: f64)?;
	json::put(&tds, "willSave", true: json::value)?;
	json::put(&tds, "willSaveWaitUntil", true: json::value)?;
	let save_opts = json::newobject();
	json::put(&save_opts, "includeText", true: json::value)?;
	json::put(&tds, "save", save_opts)?;
	json::put(&caps, "textDocumentSync", tds)?;

	// Pull diagnostics support.
	let diag_provider = json::newobject();
	json::set(&diag_provider, "identifier", "hare-lsp": json::value)?;
	json::put(&diag_provider, "interFileDependencies", true: json::value)?;
	json::put(&diag_provider, "workspaceDiagnostics", true: json::value)?;
	json::put(&caps, "diagnosticProvider", diag_provider)?;

	// Navigation features.
	json::put(&caps, "hoverProvider", true: json::value)?;
	json::put(&caps, "definitionProvider", true: json::value)?;
	json::put(&caps, "declarationProvider", true: json::value)?;
	json::put(&caps, "typeDefinitionProvider", true: json::value)?;
	json::put(&caps, "implementationProvider", true: json::value)?;
	json::put(&caps, "documentSymbolProvider", true: json::value)?;
	json::put(&caps, "documentHighlightProvider", true: json::value)?;
	json::put(&caps, "foldingRangeProvider", true: json::value)?;
	json::put(&caps, "selectionRangeProvider", true: json::value)?;
	let dl_provider = json::newobject();
	json::put(&dl_provider, "resolveProvider", true: json::value)?;
	json::put(&caps, "documentLinkProvider", dl_provider)?;
	let ws_sym_provider = json::newobject();
	json::put(&ws_sym_provider, "resolveProvider", true: json::value)?;
	json::put(&caps, "workspaceSymbolProvider", ws_sym_provider)?;
	json::put(&caps, "referencesProvider", true: json::value)?;
	let rename_provider = json::newobject();
	json::put(&rename_provider, "prepareProvider", true: json::value)?;
	json::put(&caps, "renameProvider", rename_provider)?;
	json::put(&caps, "callHierarchyProvider", true: json::value)?;
	json::put(&caps, "typeHierarchyProvider", true: json::value)?;
	let comp_provider = json::newobject();
	json::put(&comp_provider, "resolveProvider", true: json::value)?;
	let triggers: []json::value = [];
	append(triggers, strings::dup(":")?: json::value)?;
	append(triggers, strings::dup(".")?: json::value)?;
	json::put(&comp_provider, "triggerCharacters", triggers: json::value)?;
	json::put(&caps, "completionProvider", comp_provider)?;
	let sh_provider = json::newobject();
	let sh_triggers: []json::value = [];
	append(sh_triggers, strings::dup("(")?: json::value)?;
	append(sh_triggers, strings::dup(",")?: json::value)?;
	json::put(&sh_provider, "triggerCharacters", sh_triggers: json::value)?;
	json::put(&caps, "signatureHelpProvider", sh_provider)?;
	json::put(&caps, "documentFormattingProvider", true: json::value)?;
	json::put(&caps, "documentRangeFormattingProvider", true: json::value)?;
	let on_type_fmt = json::newobject();
	json::set(&on_type_fmt, "firstTriggerCharacter", "}": json::value)?;
	let on_type_more: []json::value = [];
	append(on_type_more, strings::dup(";")?: json::value)?;
	json::put(&on_type_fmt, "moreTriggerCharacter", on_type_more: json::value)?;
	json::put(&caps, "documentOnTypeFormattingProvider", on_type_fmt)?;
	let st_provider = json::newobject();
	json::put(&st_provider, "legend", token_legend())?;
	json::put(&st_provider, "full", true: json::value)?;
	json::put(&st_provider, "range", true: json::value)?;
	json::put(&caps, "semanticTokensProvider", st_provider)?;
	let ih_provider = json::newobject();
	json::put(&ih_provider, "resolveProvider", true: json::value)?;
	json::put(&caps, "inlayHintProvider", ih_provider)?;
	let cl_provider = json::newobject();
	json::put(&cl_provider, "resolveProvider", true: json::value)?;
	json::put(&caps, "codeLensProvider", cl_provider)?;
	let ca_provider = json::newobject();
	let ca_kinds: []json::value = [];
	append(ca_kinds, strings::dup("source.organizeImports")?: json::value)?;
	append(ca_kinds, strings::dup("quickfix")?: json::value)?;
	json::put(&ca_provider, "codeActionKinds", ca_kinds: json::value)?;
	json::put(&ca_provider, "resolveProvider", true: json::value)?;
	json::put(&caps, "codeActionProvider", ca_provider)?;
	let xc_provider = json::newobject();
	let xc_cmds: []json::value = [];
	append(xc_cmds, strings::dup("hare-lsp.runTest")?: json::value)?;
	append(xc_cmds, strings::dup("hare-lsp.runModule")?: json::value)?;
	append(xc_cmds, strings::dup("hare-lsp.organizeImports")?: json::value)?;
	append(xc_cmds, strings::dup("hare-lsp.applyAutoImport")?: json::value)?;
	json::put(&xc_provider, "commands", xc_cmds: json::value)?;
	json::put(&caps, "executeCommandProvider", xc_provider)?;

	// Workspace capabilities — we support workspace folders.
	let ws = json::newobject();
	let ws_ok = false;
	defer if (!ws_ok) json::finish(ws);
	let folders_caps = json::newobject();
	json::put(&folders_caps, "supported", true: json::value)?;
	json::put(&folders_caps, "changeNotifications", true: json::value)?;
	json::put(&ws, "workspaceFolders", folders_caps)?;

	// File operation support.
	let file_ops = json::newobject();
	let file_ops_filter = json::newobject();
	let pattern = json::newobject();
	json::set(&pattern, "glob", "**/*.ha": json::value)?;
	json::put(&file_ops_filter, "pattern", pattern)?;
	let filters: []json::value = [];
	append(filters, file_ops_filter: json::value)?;
	let create_caps = json::newobject();
	json::put(&create_caps, "filters", filters: json::value)?;
	json::put(&file_ops, "willCreate", create_caps)?;
	let rename_filter = json::newobject();
	let rename_pattern = json::newobject();
	json::set(&rename_pattern, "glob", "**/*.ha": json::value)?;
	json::put(&rename_filter, "pattern", rename_pattern)?;
	let rename_filters: []json::value = [];
	append(rename_filters, rename_filter: json::value)?;
	let rename_caps = json::newobject();
	json::put(&rename_caps, "filters", rename_filters: json::value)?;
	json::put(&file_ops, "willRename", rename_caps)?;
	let del_filter = json::newobject();
	let del_pattern = json::newobject();
	json::set(&del_pattern, "glob", "**/*.ha": json::value)?;
	json::put(&del_filter, "pattern", del_pattern)?;
	let del_filters: []json::value = [];
	append(del_filters, del_filter: json::value)?;
	let del_caps = json::newobject();
	json::put(&del_caps, "filters", del_filters: json::value)?;
	json::put(&file_ops, "willDelete", del_caps)?;
	json::put(&ws, "fileOperations", file_ops)?;

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
