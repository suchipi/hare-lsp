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
	// @owned
	uri: str,
	// Language id reported by the client (e.g., "hare").
	//
	// @owned
	language_id: str,
	// Monotonically-increasing version reported by the client.
	version: i64,
	// Document text and line index.
	buf: analysis::buffer,
	// Previously-issued semantic tokens for this document, used by
	// /full/delta to emit minimal edits. result_id is empty when no
	// /full has been issued yet.
	// @owned
	prev_tokens: []u32,
	// @owned
	prev_result_id: str,
	// Timestamp of the last buffer-mutating event (didOpen/didChange/
	// didSave). Used by the diagnostics debouncer.
	last_edit_at: time::instant,
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
	//
	// @owned
	parse_cache: nullable *parse_cache_entry,
	// Set of URIs the last build pass for this doc published
	// diagnostics for. On the next pass any URI here that isn't in
	// the new set gets an empty publishDiagnostics so previously-
	// reported errors don't linger in the client after they've been
	// fixed in source.
	//
	// @owned
	last_build_uris: []str,
};

// Owns a parse_result, the matching file_index, and the lexical scope
// graph. Allocated together so callers can borrow all three without
// juggling lifetimes.
export type parse_cache_entry = struct {
	pr: analysis::parse_result,
	idx: analysis::file_index,
	scope: analysis::scope_graph,
};

// @param c: owned
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
//
// @param doc: borrowed
// @returns: borrowed from doc
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

// @param doc: borrowed
fn invalidate_parse_cache(doc: *document) void = {
	finish_parse_cache(doc.parse_cache);
	doc.parse_cache = null;
};

// Looks up a document by URI. Returns nullable so callers can check before
// dereferencing.
//
// @param s: borrowed
// @param uri: borrowed
// @returns: borrowed from s
export fn find_document(s: *server, uri: str) nullable *document = {
	for (let i = 0z; i < len(s.documents); i += 1) {
		if (s.documents[i].uri == uri) {
			return &s.documents[i];
		};
	};
	return null;
};

// Returns true if a document is currently open with the given URI.
//
// @param s: borrowed
// @param uri: borrowed
export fn has_document(s: *server, uri: str) bool = {
	return find_document(s, uri) != null;
};

// Inserts or replaces a document. Used by didOpen.
//
// @param s: borrowed
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

// @param s: borrowed
// @param uri: borrowed
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
//
// @param d: borrowed
export fn finish_document(d: *document) void = {
	free(d.uri);
	free(d.language_id);
	analysis::finish(&d.buf);
	free(d.prev_tokens);
	free(d.prev_result_id);
	finish_parse_cache(d.parse_cache);
	strings::freeall(d.last_build_uris);
};

// --- handlers --------------------------------------------------------
// Handles textDocument/didOpen.
//
// @param s: borrowed
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
		diagnostics_pending = false,
		parse_cache = null,
		last_build_uris = [],
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
	stored.diagnostics_pending = false;
};

// Handles textDocument/didChange. Applies each content change in order.
//
// @param s: borrowed
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
	maybe_flush_diagnostics(s, doc, false);
};

// Publishes diagnostics for `doc` if the configured debounce window since
// the last edit has elapsed. Otherwise leaves diagnostics_pending true
// so a subsequent message (or the main loop's trailing-flush wait) will
// flush. `force` bypasses the debounce check (used by the shutdown path
// so the client receives final state).
//
// @param s: borrowed
// @param doc: borrowed
fn maybe_flush_diagnostics(s: *server, doc: *document, force: bool) void = {
	if (!doc.diagnostics_pending) return;
	if (!force) {
		const debounce_ms = s.config.diagnostics_debounce_ms: i64;
		const now = time::now(time::clock::MONOTONIC);
		const since_edit_ns = time::diff(doc.last_edit_at, now);
		const debounce_ns = debounce_ms * time::MILLISECOND;
		if (since_edit_ns < debounce_ns) {
			return;
		};
	};
	refresh_diagnostics(s, doc);
	doc.diagnostics_pending = false;
};

// Walks every open document and flushes any diagnostics whose debounce
// deadline has passed. Called from the dispatcher between messages so
// rapid keystrokes coalesce but a single trailing edit still publishes
// once the user stops typing and the next message arrives.
//
// @param s: borrowed
export fn flush_pending_diagnostics(s: *server) void = {
	for (let i = 0z; i < len(s.documents); i += 1) {
		maybe_flush_diagnostics(s, &s.documents[i], false);
	};
};

// Like [[flush_pending_diagnostics]] but bypasses the debounce window so
// the client receives the final diagnostic state. Called from the shutdown
// path before the response is written so editors don't display stale
// errors after the server has gone away.
//
// @param s: borrowed
export fn drain_pending_diagnostics(s: *server) void = {
	for (let i = 0z; i < len(s.documents); i += 1) {
		maybe_flush_diagnostics(s, &s.documents[i], true);
	};
};

// Returns the smallest remaining milliseconds until any open document's
// debounce window expires, across all docs with `diagnostics_pending`
// = true. Returns `void` when no doc has anything pending, or `0` when
// at least one deadline has already passed (caller should flush
// immediately). The caller uses the result as a timeout for the
// main-loop poll so the trailing edit publishes even when no further
// LSP message arrives. Multiple pending docs collapse to the soonest
// deadline; later docs catch up on the next loop iteration.
//
// @param s: borrowed
export fn next_trailing_flush_deadline_ms(s: *server) (i64 | void) = {
	const debounce_ms = s.config.diagnostics_debounce_ms: i64;
	const debounce_ns = debounce_ms * time::MILLISECOND;
	const now = time::now(time::clock::MONOTONIC);
	let earliest: (i64 | void) = void;
	for (let i = 0z; i < len(s.documents); i += 1) {
		const doc = &s.documents[i];
		if (!doc.diagnostics_pending) continue;
		const since_edit_ns = time::diff(doc.last_edit_at, now);
		const remaining_ns = debounce_ns - since_edit_ns;
		const remaining_ms: i64 = if (remaining_ns <= 0) {
			yield 0i64;
		} else {
			// Round up so a sub-millisecond remainder still
			// gets a full 1ms wait instead of collapsing to a
			// zero-timeout spin that flushes before the
			// debounce check would accept.
			yield (remaining_ns + time::MILLISECOND - 1) / time::MILLISECOND;
		};
		match (earliest) {
		case void =>
			earliest = remaining_ms;
		case let cur: i64 =>
			if (remaining_ms < cur) earliest = remaining_ms;
		};
	};
	return earliest;
};

// @param s: borrowed
// @param doc: borrowed
// @param change: borrowed
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
//
// @param s: borrowed
export fn position_encoding(s: *server) analysis::encoding = {
	return s.negotiated_encoding;
};

// Handles textDocument/didClose.
//
// @param s: borrowed
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
//
// @param s: borrowed
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
	doc.diagnostics_pending = false;
};

// Handles textDocument/willSave (notification). LSP allows the client to
// notify us right before a save. We currently don't act on this, but
// consuming the notification keeps us consistent with the spec.
//
// @param s: borrowed
export fn handle_will_save(s: *server, n: lsp::notification) void = void;

// @param s: borrowed
// @param id: borrowed
fn send_null_result(s: *server, id: lsp::id) void = {
	const r: json::value = json::_null;
	send_result(s, id, r);
};

// @param s: borrowed
// @param id: borrowed
// @param result: borrowed
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
//
// @param s: borrowed
// @param method: borrowed
// @param uri: borrowed
fn warn_unknown_uri(s: *server, method: str, uri: str) void = {
	const msg = fmt::asprintf("{}: no open document for uri {}", method, uri)!;
	defer free(msg);
	log_warning(s, msg);
};

// Returns true when the server can accept a new (or refreshing) document.
// Enforces the total-buffer-bytes cap. On rejection, warns via
// window/logMessage and leaves the document store untouched.
//
// @param s: borrowed
// @param uri: borrowed
fn check_open_capacity(s: *server, uri: str, incoming_bytes: size) bool = {
	const replacing = has_document(s, uri);
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
//
// @param s: borrowed
// @param uri: borrowed
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
//
// @param p: borrowed
fn params_object(
	p: (json::value | void),
) (json::object | void) = lsp::params_object(p);

// @param o: borrowed
// @param key: borrowed
fn object_field_object(
	o: *json::object,
	key: str,
) (json::object | void) = lsp::json_obj(o, key);

// @param o: borrowed
// @param key: borrowed
fn object_string(o: *json::object, key: str) (str | void) = lsp::json_str(o,
	key);

// @param o: borrowed
// @param key: borrowed
fn object_number(o: *json::object, key: str) (f64 | void) = lsp::json_num(o,
	key);
