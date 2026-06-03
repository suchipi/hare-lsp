// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Diagnostics: both push (textDocument/publishDiagnostics) and pull
// (textDocument/diagnostic, advertised via diagnosticProvider). Wires the
// recovering parser into the document lifecycle and, when enabled, layers
// `hare build` diagnostics on top of parse diagnostics. Push notifications
// are debounced by hare.diagnostics.debounceMs and flushed by the dispatch
// loop after every message.

use analysis;
use encoding::json;
use fmt;
use io;
use lsp;
use strings;

// Re-runs the recovering parser on the given document and publishes
// diagnostics. Called from didOpen/didChange/didSave (parse-only path).
//
// @param s: borrowed
// @param doc: borrowed
export fn refresh_diagnostics(s: *server, doc: *document) void = {
	let arr = assemble_diagnostics_for_doc(s, doc, []);
	publish_diagnostics(s, doc.uri, doc.version, arr);
};

// Variant that also runs `hare build` for the document's file. Called from
// didSave when config.enable_build_diagnostics is true. Build diagnostics
// can name other files in the same module; we group them by URI and
// publish each group separately.
//
// @param s: borrowed
// @param doc: borrowed
export fn refresh_diagnostics_with_build(s: *server, doc: *document) void = {
	let arr = compute_doc_diagnostics_with_optional_build(s, doc);
	publish_diagnostics(s, doc.uri, doc.version, arr);
};

// Shared between the push (didSave) and pull
// (textDocument/diagnostic, workspace/diagnostic) paths: returns the
// final, capped diagnostic list for `doc.uri`. When
// `enable_build_diagnostics` is true, runs the dep build, publishes
// sibling-URI buckets via the push channel as a side effect, and clears
// stale sibling publishes from previous passes. When false, just
// returns parse + unused (still capped) and clears any lingering
// sibling diagnostics from a prior enabled pass.
//
// @param s: borrowed
// @param doc: borrowed
// @returns: owned
fn compute_doc_diagnostics_with_optional_build(
	s: *server,
	doc: *document,
) []json::value = {
	if (!s.config.enable_build_diagnostics) {
		// User just toggled build diagnostics off — any URIs we
		// published for in previous passes (sibling files in the
		// module, transitive deps) would otherwise linger in the
		// client forever. Clear them once, then drop the tracking
		// set.
		clear_stale_build_uris(s, doc, [doc.uri]);
		return assemble_diagnostics_for_doc(s, doc, []);
	};

	// Walk the saved module's dep graph and run `hare build -t o`
	// per module, leaves first. See server/dep_build.ha for the
	// detailed rationale (handles library modules with no main and
	// cross-module references uniformly, without relying on the
	// project's build system).
	const build_diags = run_dep_build_for_doc(s, doc);
	defer finish_build_diagnostics(build_diags);

	let by_uri = group_build_diagnostics_by_uri(build_diags);
	defer finish_uri_buckets(by_uri);

	let doc_uri_bucket: int = -1;
	for (let i = 0z; i < len(by_uri); i += 1) {
		if (by_uri[i].0 == doc.uri) {
			doc_uri_bucket = i: int;
			break;
		};
	};

	// Build the set of URIs we're about to publish to. doc.uri is
	// always in it (parse diags publish even without a build hit).
	// Used below to clear stale publishes from a previous pass that
	// this pass no longer touches.
	let current_uris: []str = [];
	append(current_uris, strings::dup(doc.uri)!)!;
	for (let i = 0z; i < len(by_uri); i += 1) {
		if (i: int == doc_uri_bucket) continue;
		append(current_uris, strings::dup(by_uri[i].0)!)!;
	};

	// Extract doc.uri's build bucket (ownership transfers out of by_uri).
	let doc_build: []json::value = [];
	if (doc_uri_bucket >= 0) {
		const idx = doc_uri_bucket: size;
		doc_build = by_uri[idx].1;
		by_uri[idx].1 = [];
	};

	// Publish remaining buckets (sibling files in the dep walk).
	publish_sibling_buckets(s, &by_uri, doc_uri_bucket);

	// Clear lingering diagnostics on URIs the previous pass
	// published to but this pass didn't, then remember the new set.
	clear_stale_build_uris(s, doc, current_uris);
	doc.last_build_uris = current_uris;

	return assemble_diagnostics_for_doc(s, doc, doc_build);
};

// Publishes each sibling-URI bucket (every entry except the doc's own
// bucket) as a capped diagnostic list. Hands off ownership of each
// bucket's inner slice; the caller's deferred [[finish_uri_buckets]]
// will see an empty `.1` and skip it.
//
// @param s: borrowed
// @param by_uri: borrowed
fn publish_sibling_buckets(
	s: *server,
	by_uri: *[](str, []json::value),
	doc_uri_bucket: int,
) void = {
	let bu = *by_uri;
	const cap = s.config.limits.max_diagnostics_per_file;
	for (let i = 0z; i < len(bu); i += 1) {
		if (i: int == doc_uri_bucket) continue;
		// Look up version for this URI if it's an open document.
		const other_doc = find_document(s, bu[i].0);
		const ver = match (other_doc) {
		case let p: *document =>
			yield p.version;
		case null =>
			yield 0i64;
		};
		// For an open sibling we can place the truncation marker at
		// the file's EOF; for an unopened one we don't have its
		// content, so fall back to (0, 0).
		const eof_pos = match (other_doc) {
		case let p: *document =>
			yield doc_eof_position(s, p);
		case null =>
			yield lsp::position { line = 0, character = 0 };
		};
		// Hand off ownership of the inner slice into the helper.
		const bucket = bu[i].1;
		bu[i].1 = [];
		let capped = assemble_capped_diagnostics(cap, bucket, [], [], eof_pos);
		publish_diagnostics(s, bu[i].0, ver, capped);
	};
};

// Buckets `build_diags` by file URI. The result is owned: caller must
// pass it to [[finish_uri_buckets]] (or hand off each `.1` slice via
// reassignment, leaving the bucket empty). String keys are owned;
// inner slices contain LSP-shaped diagnostic JSON values.
//
// @returns: owned
// @param build_diags: borrowed
fn group_build_diagnostics_by_uri(
	build_diags: []build_diagnostic,
) [](str, []json::value) = {
	let by_uri: [](str, []json::value) = [];
	for (let i = 0z; i < len(build_diags); i += 1) {
		const uri = path_to_uri(build_diags[i].path);
		defer free(uri);
		const idx = find_or_create_uri_bucket(&by_uri, uri);
		append(by_uri[idx].1, build_diag_to_lsp(build_diags[i]))!;
	};
	return by_uri;
};

// Frees a bucket slice produced by [[group_build_diagnostics_by_uri]].
// In the normal flow callers hand off each `.1` to publish_diagnostics
// and overwrite the bucket with `[]` before this runs; this loop only
// matters if the function aborts mid-publish.
//
// @param by_uri: owned
fn finish_uri_buckets(by_uri: [](str, []json::value)) void = {
	for (let i = 0z; i < len(by_uri); i += 1) {
		free(by_uri[i].0);
		for (let j = 0z; j < len(by_uri[i].1); j += 1) {
			json::finish(by_uri[i].1[j]);
		};
		free(by_uri[i].1);
	};
	free(by_uri);
};

// For every URI in `doc.last_build_uris` not in `keep`, publishes an
// empty diagnostics list so the client drops the stale entries. Then
// frees the old `last_build_uris` and leaves the field empty — the
// caller is responsible for assigning the new tracking set (or
// leaving it empty if no build pass happened).
//
// @param s: borrowed
// @param doc: borrowed
// @param keep: borrowed
fn clear_stale_build_uris(s: *server, doc: *document, keep: []str) void = {
	for (let i = 0z; i < len(doc.last_build_uris); i += 1) {
		const prev = doc.last_build_uris[i];
		if (str_in_uri_slice(keep, prev)) continue;
		publish_diagnostics(s, prev, 0, []);
	};
	strings::freeall(doc.last_build_uris);
	doc.last_build_uris = [];
};

// @param slice: borrowed
// @param needle: borrowed
fn str_in_uri_slice(slice: []str, needle: str) bool = {
	for (let i = 0z; i < len(slice); i += 1) {
		if (slice[i] == needle) return true;
	};
	return false;
};

// @param by_uri: borrowed
// @param uri: borrowed
fn find_or_create_uri_bucket(by_uri: *[](str, []json::value), uri: str) size = {
	let bu = *by_uri;
	for (let i = 0z; i < len(bu); i += 1) {
		if (bu[i].0 == uri) return i;
	};
	append(bu, (strings::dup(uri)!, []: []json::value))!;
	*by_uri = bu;
	return len(bu) - 1;
};

// Returns the uncapped list of parse-error diagnostics for a document.
// No unused-import diagnostics, no truncation marker — the assembler
// applies those concerns after combining with build diagnostics.
//
// @param s: borrowed
// @param doc: borrowed
// @returns: owned
fn raw_parse_diagnostics(s: *server, doc: *document) []json::value = {
	const cache = parse_of(doc);
	const r = &cache.pr;
	let arr: []json::value = [];
	const enc = position_encoding(s);
	const data = analysis::bytes(&doc.buf);
	const idx = doc.buf.line_index;
	for (let i = 0z; i < len(r.errors); i += 1) {
		const e = r.errors[i];
		const start = analysis::byte_to_position(data, idx, enc,
			e.location.off: size);
		const end = analysis::position {
			line = start.line,
			character = start.character + 1,
		};
		let d = json::newobject();
		json::put(&d, "range",
			encode_range(lsp::range {
					start = lsp::position {
						line = start.line,
						character = start.character,
					},
					end = lsp::position {
						line = end.line,
						character = end.character,
					},
				}))!;
		json::put(&d, "severity", severity_for(e.message))!;
		json::set(&d, "source", "hare-lsp/parse": json::value)!;
		json::set(&d, "code", "parse-error": json::value)!;
		json::set(&d, "message", e.message: json::value)!;
		apply_unnecessary_tag_if_match(&d, e.message);
		append(arr, d: json::value)!;
	};
	return arr;
};

// Returns the LSP position at the end of the document's buffer. Used as
// the anchor for synthetic diagnostics (the truncation marker).
//
// @param s: borrowed
// @param doc: borrowed
fn doc_eof_position(s: *server, doc: *document) lsp::position = {
	const enc = position_encoding(s);
	const data = analysis::bytes(&doc.buf);
	const idx = doc.buf.line_index;
	const p = analysis::byte_to_position(data, idx, enc, len(data));
	return lsp::position {
		line = p.line,
		character = p.character,
	};
};

// Combines parse, unused-import and build diagnostics for a doc, then
// caps them as a single set via [[assemble_capped_diagnostics]]. `build`
// is consumed (typically the doc.uri bucket from the dep-build pass; pass
// `[]` for the parse-only path).
//
// @param s: borrowed
// @param doc: borrowed
// @param build: owned
// @returns: owned
fn assemble_diagnostics_for_doc(
	s: *server,
	doc: *document,
	build: []json::value,
) []json::value = {
	const parse = raw_parse_diagnostics(s, doc);
	const unused = unused_import_diagnostics(s, doc);
	const eof_pos = doc_eof_position(s, doc);
	const cap = s.config.limits.max_diagnostics_per_file;
	return assemble_capped_diagnostics(cap, build, unused, parse, eof_pos);
};

// Builds the final, capped diagnostic list from build / unused / parse
// inputs, honouring the priority order build > unused > parse. The
// most-important kinds are kept first; if the cap is tight, parse
// errors get dropped before unused, and unused before build. A single
// trailing "diagnostics-truncated" marker is appended whenever anything
// gets dropped (and itself counts against the cap).
//
// All three input slices are consumed: dropped entries are freed inside
// the helper so callers don't need to track partial ownership.
//
// `cap` of 0 produces an empty list (no marker either).
//
// @param build: owned
// @param unused: owned
// @param parse: owned
// @returns: owned
fn assemble_capped_diagnostics(
	cap: size,
	build: []json::value,
	unused: []json::value,
	parse: []json::value,
	eof_pos: lsp::position,
) []json::value = {
	const total = len(build) + len(unused) + len(parse);

	if (cap == 0) {
		free_diag_slice(build);
		free_diag_slice(unused);
		free_diag_slice(parse);
		return [];
	};

	if (total <= cap) {
		let out: []json::value = [];
		for (let i = 0z; i < len(build); i += 1) {
			append(out, build[i])!;
		};
		free(build);
		for (let i = 0z; i < len(unused); i += 1) {
			append(out, unused[i])!;
		};
		free(unused);
		for (let i = 0z; i < len(parse); i += 1) {
			append(out, parse[i])!;
		};
		free(parse);
		return out;
	};

	// Cap is tight; reserve one slot for the trailing marker.
	const effective = cap - 1;
	let out: []json::value = [];
	let kept: size = 0;

	const take_build = if (len(build) <= effective) {
		yield len(build);
	} else {
		yield effective;
	};
	for (let i = 0z; i < take_build; i += 1) {
		append(out, build[i])!;
	};
	for (let i = take_build; i < len(build); i += 1) {
		json::finish(build[i]);
	};
	free(build);
	kept += take_build;

	let remaining = if (effective > kept) effective - kept else 0z;
	const take_unused = if (len(unused) <= remaining) {
		yield len(unused);
	} else {
		yield remaining;
	};
	for (let i = 0z; i < take_unused; i += 1) {
		append(out, unused[i])!;
	};
	for (let i = take_unused; i < len(unused); i += 1) {
		json::finish(unused[i]);
	};
	free(unused);
	kept += take_unused;

	remaining = if (effective > kept) effective - kept else 0z;
	const take_parse = if (len(parse) <= remaining) {
		yield len(parse);
	} else {
		yield remaining;
	};
	for (let i = 0z; i < take_parse; i += 1) {
		append(out, parse[i])!;
	};
	for (let i = take_parse; i < len(parse); i += 1) {
		json::finish(parse[i]);
	};
	free(parse);
	kept += take_parse;

	const dropped = total - kept;
	append(out, truncation_marker(eof_pos, dropped, kept, total))!;
	return out;
};

// Builds the synthetic trailing diagnostic that signals the cap was hit.
// Anchored at `eof_pos`; uses a neutral source ("hare-lsp") because the
// marker can now stand in for parse, unused or build truncation.
//
// @returns: owned
fn truncation_marker(
	eof_pos: lsp::position,
	dropped: size,
	reported: size,
	total: size,
) json::value = {
	let d = json::newobject();
	json::put(&d, "range",
		encode_range(lsp::range {
				start = lsp::position {
					line = eof_pos.line,
					character = eof_pos.character,
				},
				end = lsp::position {
					line = eof_pos.line,
					character = eof_pos.character,
				},
			}))!;
	json::put(&d, "severity", severity_for("diagnostics truncated"))!;
	json::set(&d, "source", "hare-lsp": json::value)!;
	json::set(&d, "code", "diagnostics-truncated": json::value)!;
	const msg =
		fmt::asprintf("({} more diagnostics not shown; {} of {} reported)", dropped,
			reported, total)!;
	json::set(&d, "message", msg: json::value)!;
	free(msg);
	return d: json::value;
};

// Frees every diagnostic in `arr`, then the slice itself.
//
// @param arr: owned
fn free_diag_slice(arr: []json::value) void = {
	for (let i = 0z; i < len(arr); i += 1) {
		json::finish(arr[i]);
	};
	free(arr);
};

// Maps an error message to an LSP severity level. Parse errors are
// Error (1) by default; messages mentioning "unused" or "unreachable"
// downgrade to Warning (2) so they don't clutter the problems pane at
// error severity.
//
// @param message: borrowed
fn severity_for(message: str) f64 = {
	if (strings::contains(message, "unused")
			|| strings::contains(message, "unreachable")) {
		return 2.0;
	};
	return 1.0;
};

// Emits one Hint-level diagnostic per unused import. The diagnostic
// carries the Unnecessary tag (so editors grey it out) and a `data`
// payload that the code-action handler reads to materialize the
// removal edit. Detection is delegated to codeactions::find_unused_imports;
// they are in the same module so no re-export is needed.
//
// @param s: borrowed
// @param doc: borrowed
// @returns: owned
fn unused_import_diagnostics(s: *server, doc: *document) []json::value = {
	let out: []json::value = [];
	const cache = parse_of(doc);
	const pr = &cache.pr;
	if (len(pr.subunit.imports) == 0) return out;
	const data = analysis::bytes(&doc.buf);
	const unused = find_unused_imports(data, &pr.subunit);
	defer free(unused);
	if (len(unused) == 0) return out;
	const enc = position_encoding(s);
	const line_idx = doc.buf.line_index;
	for (let i = 0z; i < len(unused); i += 1) {
		const idx = unused[i];
		const imp = &pr.subunit.imports[idx];
		const (rm_start, rm_end) = import_removal_range(data, imp);
		const sp = analysis::byte_to_position(data, line_idx, enc, rm_start);
		const ep = analysis::byte_to_position(data, line_idx, enc, rm_end);
		let d = json::newobject();
		json::put(&d, "range",
			encode_range(lsp::range {
					start = lsp::position {
						line = sp.line,
						character = sp.character,
					},
					end = lsp::position {
						line = ep.line,
						character = ep.character,
					},
				}))!;
		json::put(&d, "severity", 4.0: f64)!;
		json::set(&d, "source", "hare-lsp": json::value)!;
		json::set(&d, "code", "unused-import": json::value)!;
		json::set(&d, "message", "unused import": json::value)!;
		let tags: []json::value = [];
		append(tags, DIAG_TAG_UNNECESSARY: json::value)!;
		json::put(&d, "tags", tags: json::value)!;
		let data_obj = json::newobject();
		json::set(&data_obj, "kind", "unused-import": json::value)!;
		json::put(&data_obj, "import_idx", idx: f64)!;
		json::put(&d, "data", data_obj)!;
		append(out, d: json::value)!;
	};
	return out;
};

// LSP DiagnosticTag values.
def DIAG_TAG_UNNECESSARY: f64 = 1.0;

// Attaches a `tags: [Unnecessary]` field to a diagnostic object when
// its message looks like an unused / unreachable / dead-code report.
// Shared between the build path and the parse path so editors grey
// out the span consistently regardless of which producer emitted it.
//
// We don't currently emit `relatedInformation`: doing so well requires
// the producer (parser or compiler) to carry secondary source
// locations alongside each diagnostic, which neither does today. A
// future revision can plumb that through when the structure exists.
//
// @param d: borrowed
// @param message: borrowed
export fn apply_unnecessary_tag_if_match(
	d: *json::object,
	message: str,
) void = {
	if (strings::contains(message, "unused")
			|| strings::contains(message, "unreachable")) {
		let tags: []json::value = [];
		append(tags, DIAG_TAG_UNNECESSARY: json::value)!;
		json::put(d, "tags", tags: json::value)!;
	};
};

// Sends textDocument/publishDiagnostics. `diagnostics` is consumed: ownership
// of the slice and its contents transfers into the wire encoding.
//
// @param s: borrowed
// @param uri: borrowed
// @param diagnostics: owned
export fn publish_diagnostics(
	s: *server,
	uri: str,
	version: i64,
	diagnostics: []json::value,
) void = {
	let params = json::newobject();
	defer json::finish(params);
	json::set(&params, "uri", uri: json::value)!;
	if (version != 0) {
		json::put(&params, "version", version: f64)!;
	};
	json::put(&params, "diagnostics", diagnostics: json::value)!;

	match (lsp::encode_notification(s.out, "textDocument/publishDiagnostics",
		params)) {
	case size => void;
	case let e: io::error =>
		slog_error(s, "publishDiagnostics:", io::strerror(e));
	};
};

// Encodes an lsp::range into a json::value. Local copy to avoid pulling
// documents.ha helpers into here circularly.
//
// @returns: owned
fn encode_range(r: lsp::range) json::value = {
	let o = json::newobject();
	let s_obj = json::newobject();
	json::put(&s_obj, "line", r.start.line: f64)!;
	json::put(&s_obj, "character", r.start.character: f64)!;
	json::put(&o, "start", s_obj)!;
	let e_obj = json::newobject();
	json::put(&e_obj, "line", r.end.line: f64)!;
	json::put(&e_obj, "character", r.end.character: f64)!;
	json::put(&o, "end", e_obj)!;
	return o;
};

// Clears all diagnostics for a URI. Used when a document is closed.
//
// @param s: borrowed
// @param uri: borrowed
export fn clear_diagnostics(s: *server, uri: str) void = {
	publish_diagnostics(s, uri, 0, []);
};

// --- pull-model diagnostics -----------------------------------------
// Handles textDocument/diagnostic. The client wants the current diagnostic
// state for a single document. When `enable_build_diagnostics` is true,
// the dep build runs synchronously and build errors for sibling URIs are
// pushed via publishDiagnostics (textDocument/diagnostic is single-doc
// and can't carry them inline).
//
// @param s: borrowed
export fn handle_textdocument_diagnostic(s: *server, r: lsp::request) void = {
	const obj = match (params_object_diag(r.params)) {
	case let o: json::object =>
		yield o;
	case void =>
		send_to_client(s, r.id, full_report([]));
		return;
	};
	const text_doc = match (object_field_object_diag(&obj, "textDocument")) {
	case let o: json::object =>
		yield o;
	case void =>
		send_to_client(s, r.id, full_report([]));
		return;
	};
	const uri = match (object_string_diag(&text_doc, "uri")) {
	case let s: str =>
		yield s;
	case void =>
		send_to_client(s, r.id, full_report([]));
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document =>
		yield p;
	case null =>
		send_to_client(s, r.id, full_report([]));
		return;
	};
	let diags = compute_doc_diagnostics_with_optional_build(s, doc);
	send_to_client(s, r.id, full_report(diags));
};

// Handles workspace/diagnostic. Returns a "full" report for every open
// document. Scope is intentionally open documents only — pulling
// diagnostics for every file in the workspace on demand would parse
// each one and is rarely what clients actually want.
//
// When `enable_build_diagnostics` is true, this runs the dep build for
// each open doc. Potentially expensive (the push path runs only on
// save), but workspace pulls are rare — clients invoke them after a
// refresh request. Sibling-URI build errors get pushed via
// publishDiagnostics as a side effect.
//
// @param s: borrowed
export fn handle_workspace_diagnostic(s: *server, r: lsp::request) void = {
	let items: []json::value = [];
	for (let i = 0z; i < len(s.documents); i += 1) {
		let diags = compute_doc_diagnostics_with_optional_build(s, &s.documents[i]);
		let report = json::newobject();
		json::set(&report, "kind", "full": json::value)!;
		json::set(&report, "uri", s.documents[i].uri: json::value)!;
		json::put(&report, "version", s.documents[i].version: f64)!;
		json::put(&report, "items", diags: json::value)!;
		append(items, report: json::value)!;
	};
	let result = json::newobject();
	json::put(&result, "items", items: json::value)!;
	send_to_client(s, r.id, result: json::value);
};

// Sends a workspace/diagnostic/refresh request to the client. Used after
// the workspace index changes in a way that may have invalidated previous
// reports.
//
// @param s: borrowed
export fn request_diagnostic_refresh(s: *server) void = {
	const id = next_outgoing_id(s);
	if (!send_request(s, id, "workspace/diagnostic/refresh", json::_null)) {
		return;
	};
	pending_remember(s, id, "workspace/diagnostic/refresh");
};

// Sends a workspace/inlayHint/refresh request to the client. Used after
// a settings change that affects which hints are produced.
//
// @param s: borrowed
export fn request_inlay_hint_refresh(s: *server) void = {
	const id = next_outgoing_id(s);
	if (!send_request(s, id, "workspace/inlayHint/refresh", json::_null)) {
		return;
	};
	pending_remember(s, id, "workspace/inlayHint/refresh");
};

// @param items: owned
// @returns: owned
fn full_report(items: []json::value) json::value = {
	let o = json::newobject();
	json::set(&o, "kind", "full": json::value)!;
	json::put(&o, "items", items: json::value)!;
	return o;
};

// @param s: borrowed
// @param id: borrowed
// @param result: owned
fn send_to_client(s: *server, id: lsp::id, result: json::value) void = {
	defer json::finish(result);
	match (lsp::encode_response_result(s.out, id, result)) {
	case size => void;
	case let e: io::error =>
		slog_error(s, "pull diag response:", io::strerror(e));
	};
};

// Thin aliases over the shared lsp::json_* helpers.
//
// @param p: borrowed
fn params_object_diag(
	p: (json::value | void),
) (json::object | void) = lsp::params_object(p);

// @param o: borrowed
// @param key: borrowed
fn object_field_object_diag(
	o: *json::object,
	key: str,
) (json::object | void) = lsp::json_obj(o, key);

// @param o: borrowed
// @param key: borrowed
// @returns: borrowed from o
fn object_string_diag(
	o: *json::object,
	key: str,
) (str | void) = lsp::json_str(o, key);
