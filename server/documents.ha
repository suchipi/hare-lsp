// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Open document store and text-sync handlers. Documents are keyed by URI.
//
// We advertise TextDocumentSyncKind.Incremental, which means client edits
// arrive as a list of TextDocumentContentChangeEvents — each either a full
// replacement (range absent) or a range edit. We apply these to the buffer
// using analysis::buffer.

use analysis;
use encoding::json;
use fmt;
use io;
use lsp;
use strings;
use time;

// An open document.
export type document = struct {
	uri: str,
	// Language id reported by the client (e.g., "hare").
	language_id: str,
	// Monotonically-increasing version reported by the client.
	version: i64,
	// Document text and line index.
	buf: analysis::buffer,
	// Previously-issued semantic tokens for this document, used by
	// /full/delta to emit minimal edits. result_id is empty when no
	// /full has been issued yet.
	prev_tokens: []u32,
	prev_result_id: str,
	// Timestamp of the last buffer-mutating event (didOpen/didChange/
	// didSave). Used by the diagnostics debouncer.
	last_edit_at: time::instant,
	// Timestamp of the last published parse-diagnostics for this doc.
	last_publish_at: time::instant,
	// True when the doc has had a buffer mutation that hasn't yet been
	// followed by a publishDiagnostics call (because the debounce
	// suppressed it). Cleared whenever we actually publish.
	diagnostics_pending: bool,
	// Cached parse + index of the current buffer contents. Null when
	// the buffer has been mutated since the last parse. Acquire via
	// [[parse_of]] which lazy-fills on demand.
	//
	// Concurrency: unsynchronized; safe today because the dispatcher
	// runs in a single thread. Any future background work that
	// observes documents needs to lock or copy this pointer before
	// the next mutation can free the underlying entry.
	parse_cache: nullable *parse_cache_entry,
};

// Owns a parse_result, the matching file_index, and the lexical scope
// graph. Allocated together so callers can borrow all three without
// juggling lifetimes.
export type parse_cache_entry = struct {
	pr: analysis::parse_result,
	idx: analysis::file_index,
	scope: analysis::scope_graph,
};

fn finish_parse_cache(c: nullable *parse_cache_entry) void = {
	match (c) {
	case null => void;
	case let p: *parse_cache_entry =>
		analysis::finish_scope_graph(&p.scope);
		analysis::finish_index(&p.idx);
		analysis::finish_parse_result(&p.pr);
		free(p);
	};
};

// Returns a borrowed pointer to the document's cached parse + index +
// scope graph, building them on demand. The returned pointer is
// invalidated on the next call to [[invalidate_parse_cache]] (any buffer
// mutation).
export fn parse_of(doc: *document) *parse_cache_entry = {
	match (doc.parse_cache) {
	case let p: *parse_cache_entry =>
		return p;
	case null => void;
	};
	let entry =
		alloc(parse_cache_entry {
			pr = analysis::parse_recover(analysis::bytes(&doc.buf), doc.uri),
			idx = analysis::file_index { symbols = [] },
			scope = analysis::scope_graph {
				root = null: *analysis::scope_node,
				nodes = [],
			},
		})!;
	entry.idx = analysis::build_index(&entry.pr.subunit);
	entry.scope = analysis::build_scope_graph(&entry.pr.subunit);
	doc.parse_cache = entry;
	return entry;
};

fn invalidate_parse_cache(doc: *document) void = {
	finish_parse_cache(doc.parse_cache);
	doc.parse_cache = null;
};

// Looks up a document by URI. Returns nullable so callers can check before
// dereferencing.
export fn find_document(s: *server, uri: str) nullable *document = {
	for (let i = 0z; i < len(s.documents); i += 1) {
		if (s.documents[i].uri == uri) {
			return &s.documents[i];
		};
	};
	return null;
};

// Returns true if a document is currently open with the given URI.
export fn has_document(s: *server, uri: str) bool = {
	return find_document(s, uri) != null;
};

// Inserts or replaces a document. Used by didOpen.
fn upsert_document(s: *server, doc: document) void = {
	for (let i = 0z; i < len(s.documents); i += 1) {
		if (s.documents[i].uri == doc.uri) {
			finish_document(&s.documents[i]);
			s.documents[i] = doc;
			return;
		};
	};
	append(s.documents, doc)!;
};

fn remove_document(s: *server, uri: str) void = {
	for (let i = 0z; i < len(s.documents); i += 1) {
		if (s.documents[i].uri == uri) {
			finish_document(&s.documents[i]);
			delete(s.documents[i]);
			return;
		};
	};
};

// Releases memory for a single document.
export fn finish_document(d: *document) void = {
	free(d.uri);
	free(d.language_id);
	analysis::finish(&d.buf);
	free(d.prev_tokens);
	free(d.prev_result_id);
	finish_parse_cache(d.parse_cache);
};

// --- handlers --------------------------------------------------------
// Handles textDocument/didOpen.
export fn handle_did_open(s: *server, n: lsp::notification) void = {
	const obj = match (params_object(n.params)) {
	case let o: json::object =>
		yield o;
	case void =>
		warn_invalid_notification(s, "textDocument/didOpen",
			"missing or non-object params");
		return;
	};
	const text_doc = match (object_field_object(&obj, "textDocument")) {
	case let o: json::object =>
		yield o;
	case void =>
		warn_invalid_notification(s, "textDocument/didOpen",
			"missing or non-object 'textDocument'");
		return;
	};
	const uri = match (object_string(&text_doc, "uri")) {
	case let s: str =>
		yield s;
	case void =>
		warn_invalid_notification(s, "textDocument/didOpen",
			"missing or non-string 'textDocument.uri'");
		return;
	};
	const text = match (object_string(&text_doc, "text")) {
	case let s: str =>
		yield s;
	case void =>
		warn_invalid_notification(s, "textDocument/didOpen",
			"missing or non-string 'textDocument.text'");
		return;
	};
	const lang = match (object_string(&text_doc, "languageId")) {
	case let s: str =>
		yield s;
	case void =>
		yield "";
	};
	const version: i64 = match (object_number(&text_doc, "version")) {
	case let f: f64 =>
		yield f: i64;
	case void =>
		yield 0i64;
	};

	if (!check_open_capacity(s, uri, len(text))) {
		return;
	};

	const now = time::now(time::clock::MONOTONIC);
	const doc = document {
		uri = strings::dup(uri)!,
		language_id = strings::dup(lang)!,
		version = version,
		buf = analysis::from_str(text),
		prev_tokens = [],
		prev_result_id = strings::dup("")!,
		last_edit_at = now,
		last_publish_at = time::INSTANT_ZERO,
		diagnostics_pending = false,
		parse_cache = null,
	};
	upsert_document(s, doc);
	const stored = match (find_document(s, uri)) {
	case let p: *document =>
		yield p;
	case null =>
		return;
	};
	// didOpen always publishes immediately so the editor sees an initial
	// diagnostic state.
	refresh_diagnostics(s, stored);
	stored.last_publish_at = time::now(time::clock::MONOTONIC);
	stored.diagnostics_pending = false;
};

// Handles textDocument/didChange. Applies each content change in order.
export fn handle_did_change(s: *server, n: lsp::notification) void = {
	const obj = match (params_object(n.params)) {
	case let o: json::object =>
		yield o;
	case void =>
		warn_invalid_notification(s, "textDocument/didChange",
			"missing or non-object params");
		return;
	};
	const text_doc = match (object_field_object(&obj, "textDocument")) {
	case let o: json::object =>
		yield o;
	case void =>
		warn_invalid_notification(s, "textDocument/didChange",
			"missing or non-object 'textDocument'");
		return;
	};
	const uri = match (object_string(&text_doc, "uri")) {
	case let s: str =>
		yield s;
	case void =>
		warn_invalid_notification(s, "textDocument/didChange",
			"missing or non-string 'textDocument.uri'");
		return;
	};
	const version: i64 = match (object_number(&text_doc, "version")) {
	case let f: f64 =>
		yield f: i64;
	case void =>
		yield 0i64;
	};

	const doc = match (find_document(s, uri)) {
	case let p: *document =>
		yield p;
	case null =>
		warn_unknown_uri(s, "textDocument/didChange", uri);
		return;
	};
	// LSP requires versions to be monotonically increasing. A regression
	// usually means the client has a bug or got out of sync; warn and
	// keep the older version so subsequent edits still target the same
	// buffer state the client thinks it has.
	if (version != 0 && version < doc.version) {
		const msg =
			fmt::asprintf(
				"textDocument/didChange: version regression for {} ({} < {}); ignoring stale change",
				uri, version, doc.version)!;
		defer free(msg);
		log_warning(s, msg);
		return;
	};
	doc.version = version;
	// Any text edit invalidates the cached semantic tokens.
	free(doc.prev_tokens);
	doc.prev_tokens = [];
	free(doc.prev_result_id);
	doc.prev_result_id = strings::dup("")!;

	const changes = match (json::get(&obj, "contentChanges")) {
	case let p: *json::value =>
		yield match (*p) {
		case let a: []json::value =>
			yield a;
		case =>
			warn_invalid_notification(s, "textDocument/didChange",
				"'contentChanges' must be an array");
			return;
		};
	case =>
		warn_invalid_notification(s, "textDocument/didChange",
			"missing 'contentChanges'");
		return;
	};

	for (let i = 0z; i < len(changes); i += 1) {
		apply_content_change(s, doc, changes[i]);
	};
	if (!check_buffer_capacity(s, doc.uri)) {
		// Drop the document entirely if it has blown past the cap so
		// the server doesn't keep churning on a runaway buffer.
		remove_document(s, doc.uri);
		return;
	};
	doc.last_edit_at = time::now(time::clock::MONOTONIC);
	doc.diagnostics_pending = true;
	maybe_flush_diagnostics(s, doc);
};

// Publishes diagnostics for `doc` if the configured debounce window since
// the last publish has elapsed. Otherwise leaves diagnostics_pending true
// so a subsequent message will flush.
fn maybe_flush_diagnostics(s: *server, doc: *document) void = {
	if (!doc.diagnostics_pending) return;
	const debounce_ms = s.config.diagnostics_debounce_ms: i64;
	const now = time::now(time::clock::MONOTONIC);
	const since_publish_ns = time::diff(doc.last_publish_at, now);
	const debounce_ns = debounce_ms * time::MILLISECOND;
	if (since_publish_ns < debounce_ns) {
		return;
	};
	refresh_diagnostics(s, doc);
	doc.last_publish_at = now;
	doc.diagnostics_pending = false;
};

// Walks every open document and flushes any diagnostics whose debounce
// deadline has passed. Called from the dispatcher between messages so
// rapid keystrokes coalesce but a single trailing edit still publishes
// once the user stops typing and the next message arrives.
export fn flush_pending_diagnostics(s: *server) void = {
	for (let i = 0z; i < len(s.documents); i += 1) {
		maybe_flush_diagnostics(s, &s.documents[i]);
	};
};

fn apply_content_change(
	s: *server,
	doc: *document,
	change: json::value,
) void = {
	const obj = match (change) {
	case let o: json::object =>
		yield o;
	case =>
		return;
	};
	const text = match (object_string(&obj, "text")) {
	case let t: str =>
		yield t;
	case void =>
		return;
	};
	const range_p = json::get(&obj, "range");
	if (range_p is void) {
		// Full document sync.
		analysis::replace_all(&doc.buf, strings::toutf8(text));
		invalidate_parse_cache(doc);
		return;
	};
	const range = match (lsp::decode_range(*(range_p as *json::value))) {
	case let r: lsp::range =>
		yield r;
	case lsp::bad_message =>
		return;
	};
	const enc = position_encoding(s);
	const start_byte = analysis::position_to_byte(analysis::bytes(&doc.buf),
		doc.buf.line_index, enc,
		analysis::position {
			line = range.start.line,
			character = range.start.character,
		});
	const end_byte = analysis::position_to_byte(analysis::bytes(&doc.buf),
		doc.buf.line_index, enc,
		analysis::position {
			line = range.end.line,
			character = range.end.character,
		});
	analysis::replace_range(&doc.buf, start_byte, end_byte, strings::toutf8(text));
	invalidate_parse_cache(doc);
};

// Returns the position encoding negotiated at initialize.
export fn position_encoding(s: *server) analysis::encoding = {
	return s.negotiated_encoding;
};

// Handles textDocument/didClose.
export fn handle_did_close(s: *server, n: lsp::notification) void = {
	const obj = match (params_object(n.params)) {
	case let o: json::object =>
		yield o;
	case void =>
		warn_invalid_notification(s, "textDocument/didClose",
			"missing or non-object params");
		return;
	};
	const text_doc = match (object_field_object(&obj, "textDocument")) {
	case let o: json::object =>
		yield o;
	case void =>
		warn_invalid_notification(s, "textDocument/didClose",
			"missing or non-object 'textDocument'");
		return;
	};
	const uri = match (object_string(&text_doc, "uri")) {
	case let s: str =>
		yield s;
	case void =>
		warn_invalid_notification(s, "textDocument/didClose",
			"missing or non-string 'textDocument.uri'");
		return;
	};
	if (!has_document(s, uri)) {
		warn_unknown_uri(s, "textDocument/didClose", uri);
		return;
	};
	clear_diagnostics(s, uri);
	remove_document(s, uri);
};

// Handles textDocument/didSave. If the client included `text` (we requested
// it), use that as authoritative.
export fn handle_did_save(s: *server, n: lsp::notification) void = {
	const obj = match (params_object(n.params)) {
	case let o: json::object =>
		yield o;
	case void =>
		warn_invalid_notification(s, "textDocument/didSave",
			"missing or non-object params");
		return;
	};
	const text_doc = match (object_field_object(&obj, "textDocument")) {
	case let o: json::object =>
		yield o;
	case void =>
		warn_invalid_notification(s, "textDocument/didSave",
			"missing or non-object 'textDocument'");
		return;
	};
	const uri = match (object_string(&text_doc, "uri")) {
	case let s: str =>
		yield s;
	case void =>
		warn_invalid_notification(s, "textDocument/didSave",
			"missing or non-string 'textDocument.uri'");
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document =>
		yield p;
	case null =>
		warn_unknown_uri(s, "textDocument/didSave", uri);
		return;
	};

	match (object_string(&obj, "text")) {
	case let txt: str =>
		analysis::replace_all(&doc.buf, strings::toutf8(txt));
		invalidate_parse_cache(doc);
	case void => void;
	};
	// Save bypasses the debounce: we want fresh diagnostics now.
	refresh_diagnostics_with_build(s, doc);
	doc.last_publish_at = time::now(time::clock::MONOTONIC);
	doc.diagnostics_pending = false;
};

// Handles textDocument/willSave (notification). LSP allows the client to
// notify us right before a save. We currently don't act on this, but
// consuming the notification keeps us consistent with the spec.
export fn handle_will_save(s: *server, n: lsp::notification) void = void;

// Handles textDocument/willSaveWaitUntil (request). Returns text edits to
// apply before saving — currently trim trailing whitespace and ensure final
// newline per config.
export fn handle_will_save_wait_until(s: *server, r: lsp::request) void = {
	const obj = match (params_object(r.params)) {
	case let o: json::object =>
		yield o;
	case void =>
		reject_invalid_request(s, r.id, r.method, "missing or non-object params");
		return;
	};
	const text_doc = match (object_field_object(&obj, "textDocument")) {
	case let o: json::object =>
		yield o;
	case void =>
		reject_invalid_request(s, r.id, r.method,
			"missing or non-object 'textDocument'");
		return;
	};
	const uri = match (object_string(&text_doc, "uri")) {
	case let s: str =>
		yield s;
	case void =>
		reject_invalid_request(s, r.id, r.method,
			"missing or non-string 'textDocument.uri'");
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document =>
		yield p;
	case null =>
		// Unknown URI for a request: per spec this is an error, but
		// returning an empty edit list is friendlier to clients that
		// race a close + save.
		send_null_result(s, r.id);
		return;
	};

	let edits = compute_will_save_edits(s, doc);
	defer free_text_edits(edits);

	let arr: []json::value = [];
	let arr_owned = true;
	defer if (arr_owned) {
		for (let i = 0z; i < len(arr); i += 1) {
			json::finish(arr[i]);
		};
		free(arr);
	};

	for (let i = 0z; i < len(edits); i += 1) {
		let o = json::newobject();
		json::put(&o, "range", encode_text_edit_range(edits[i].range))!;
		json::set(&o, "newText", edits[i].new_text: json::value)!;
		append(arr, o: json::value)!;
	};

	const result: json::value = arr;
	arr_owned = false;
	send_result(s, r.id, result);
	json::finish(result);
};

// Internal text edit shape. Owned strings; pass to free_text_edits when done.
type text_edit = struct {
	range: lsp::range,
	new_text: str,
};

fn free_text_edits(edits: []text_edit) void = {
	for (let i = 0z; i < len(edits); i += 1) {
		free(edits[i].new_text);
	};
	free(edits);
};

fn compute_will_save_edits(s: *server, doc: *document) []text_edit = {
	let edits: []text_edit = [];
	const data = analysis::bytes(&doc.buf);

	if (!s.config.format_trim_final_newlines &&
			!s.config.format_insert_final_newline) {
		return edits;
	};

	// Find the first index past which only whitespace remains.
	let end = len(data);
	for (end > 0; end -= 1) {
		const c = data[end - 1];
		if (c != ' ': u8 && c != '\t': u8 && c != '\n': u8 && c != '\r': u8) {
			break;
		};
	};
	const want_nl = s.config.format_insert_final_newline;
	let target: str = "";
	if (want_nl && len(data) > 0) {
		target = "\n";
	};
	// Construct the edit only if it would change something.
	const has_trailing_ws = end < len(data);
	const trailing_is_lone_nl =
		has_trailing_ws && len(data) - end == 1 && data[end] == '\n': u8;
	const needs_change = if (s.config.format_trim_final_newlines) {
		yield has_trailing_ws && !(want_nl && trailing_is_lone_nl);
	} else if (want_nl) {
		// Only ensure final newline.
		yield len(data) > 0 && data[len(data) - 1] != '\n': u8;
	} else {
		yield false;
	};
	if (!needs_change) return edits;

	const enc = position_encoding(s);
	const start_byte = if (s.config.format_trim_final_newlines) end else len(data);
	const start_pos = analysis::byte_to_position(data, doc.buf.line_index, enc,
		start_byte);
	const end_pos = analysis::byte_to_position(data, doc.buf.line_index, enc,
		len(data));
	append(edits, text_edit {
		range = lsp::range {
			start = lsp::position {
				line = start_pos.line,
				character = start_pos.character,
			},
			end = lsp::position {
				line = end_pos.line,
				character = end_pos.character,
			},
		},
		new_text = strings::dup(target)!,
	})!;
	return edits;
};

fn encode_text_edit_range(r: lsp::range) json::value = {
	let o = json::newobject();
	json::put(&o, "start", encode_pos(r.start))!;
	json::put(&o, "end", encode_pos(r.end))!;
	return o;
};

fn encode_pos(p: lsp::position) json::value = {
	let o = json::newobject();
	json::put(&o, "line", p.line: f64)!;
	json::put(&o, "character", p.character: f64)!;
	return o;
};

fn send_null_result(s: *server, id: lsp::id) void = {
	const r: json::value = json::_null;
	send_result(s, id, r);
};

fn send_result(s: *server, id: lsp::id, result: json::value) void = {
	match (lsp::encode_response_result(s.out, id, result)) {
	case size => void;
	case let e: io::error =>
		slog_error(s, "send_result:", io::strerror(e));
	};
};

// --- capacity / validation helpers -----------------------------------
// Emits a window/logMessage(Warning) noting that a notification arrived
// for a URI the server doesn't have open. Per LSP spec
// didChange/didClose for an unopened document is a client error.
fn warn_unknown_uri(s: *server, method: str, uri: str) void = {
	const msg = fmt::asprintf("{}: no open document for uri {}", method, uri)!;
	defer free(msg);
	log_warning(s, msg);
};

// Returns true when the server can accept a new (or refreshing) document.
// Enforces [[MAX_OPEN_DOCUMENTS]] and [[MAX_TOTAL_BUFFER_BYTES]]. On
// rejection, warns via window/logMessage and leaves the document store
// untouched.
fn check_open_capacity(s: *server, uri: str, incoming_bytes: size) bool = {
	const replacing = has_document(s, uri);
	if (!replacing && len(s.documents) >= s.config.limits.max_open_documents) {
		const msg =
			fmt::asprintf(
				"textDocument/didOpen: refusing to open {} (already {} documents open; cap {})",
				uri, len(s.documents), s.config.limits.max_open_documents)!;
		defer free(msg);
		log_warning(s, msg);
		return false;
	};
	let total: size = incoming_bytes;
	for (let i = 0z; i < len(s.documents); i += 1) {
		if (replacing && s.documents[i].uri == uri) continue;
		total += len(analysis::bytes(&s.documents[i].buf));
	};
	if (total > s.config.limits.max_total_buffer_bytes) {
		const msg =
			fmt::asprintf(
				"textDocument/didOpen: refusing to open {} ({} bytes would exceed total cap of {} bytes)",
				uri, incoming_bytes, s.config.limits.max_total_buffer_bytes)!;
		defer free(msg);
		log_warning(s, msg);
		return false;
	};
	return true;
};

// After applying didChange edits we recheck total buffer size. Returns
// false when the cap has been exceeded; on false the caller should
// abandon the document so we don't keep churning on a runaway buffer.
fn check_buffer_capacity(s: *server, uri: str) bool = {
	let total: size = 0;
	for (let i = 0z; i < len(s.documents); i += 1) {
		total += len(analysis::bytes(&s.documents[i].buf));
	};
	if (total > s.config.limits.max_total_buffer_bytes) {
		const msg =
			fmt::asprintf(
				"textDocument/didChange: total buffer size {} exceeds cap {}; dropping {}",
				total, s.config.limits.max_total_buffer_bytes, uri)!;
		defer free(msg);
		log_warning(s, msg);
		return false;
	};
	return true;
};

// --- json helpers ----------------------------------------------------
// Thin aliases over the shared lsp::json_* helpers so this file's call
// sites stay unchanged.
fn params_object(
	p: (json::value | void),
) (json::object | void) = lsp::params_object(p);

fn object_field_object(
	o: *json::object,
	key: str,
) (json::object | void) = lsp::json_obj(o, key);

fn object_string(o: *json::object, key: str) (str | void) = lsp::json_str(o,
	key);

fn object_number(o: *json::object, key: str) (f64 | void) = lsp::json_num(o,
	key);
