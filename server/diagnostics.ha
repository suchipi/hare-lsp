// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Diagnostics: push and (later) pull. This step wires the recovering parser
// into the document lifecycle and emits textDocument/publishDiagnostics.

use analysis;
use encoding::json;
use fmt;
use io;
use lsp;
use os;
use strings;

// Re-runs the recovering parser on the given document and publishes
// diagnostics. Called from didOpen/didChange/didSave (parse-only path).
export fn refresh_diagnostics(s: *server, doc: *document) void = {
	let arr = parse_diagnostics_for_doc(s, doc);
	publish_diagnostics(s, doc.uri, doc.version, arr);
};

// Variant that also runs `hare build` for the document's file. Called from
// didSave when config.enable_build_diagnostics is true. Build diagnostics
// can name other files in the same module; we group them by URI and
// publish each group separately.
export fn refresh_diagnostics_with_build(s: *server, doc: *document) void = {
	let parse_arr = parse_diagnostics_for_doc(s, doc);

	if (!s.config.enable_build_diagnostics) {
		publish_diagnostics(s, doc.uri, doc.version, parse_arr);
		return;
	};

	const file_path = uri_to_path(doc.uri);
	let build_diags = run_build(s.config.hare_path, file_path, s.config.tags);
	defer finish_build_diagnostics(build_diags);

	// Group build diagnostics by URI.
	let by_uri: [](str, []json::value) = [];
	defer {
		for (let i = 0z; i < len(by_uri); i += 1) {
			free(by_uri[i].0);
			// inner json::values are consumed by publish_diagnostics
			// when we iterate below, but in the panic-bypass path
			// we'd need to free them. The normal path zeroes the
			// slice as we publish, so this loop only runs on early
			// abort and is conservative.
			for (let j = 0z; j < len(by_uri[i].1); j += 1) {
				json::finish(by_uri[i].1[j]);
			};
			free(by_uri[i].1);
		};
		free(by_uri);
	};

	for (let i = 0z; i < len(build_diags); i += 1) {
		const uri = path_to_uri(build_diags[i].path);
		defer free(uri);
		const idx = find_or_create_uri_bucket(&by_uri, uri);
		append(by_uri[idx].1, build_diag_to_lsp(build_diags[i]))!;
	};

	// Merge: doc.uri's build diagnostics get appended to its parse
	// diagnostics. Other URIs publish their own list.
	let doc_uri_bucket: int = -1;
	for (let i = 0z; i < len(by_uri); i += 1) {
		if (by_uri[i].0 == doc.uri) {
			doc_uri_bucket = i: int;
			break;
		};
	};

	if (doc_uri_bucket >= 0) {
		let merged = parse_arr;
		const idx = doc_uri_bucket: size;
		for (let i = 0z; i < len(by_uri[idx].1); i += 1) {
			append(merged, by_uri[idx].1[i])!;
		};
		// Take ownership so the deferred bucket free doesn't double-free.
		by_uri[idx].1 = [];
		publish_diagnostics(s, doc.uri, doc.version, merged);
	} else {
		publish_diagnostics(s, doc.uri, doc.version, parse_arr);
	};

	// Publish remaining buckets (other files).
	for (let i = 0z; i < len(by_uri); i += 1) {
		if (i: int == doc_uri_bucket) continue;
		// Look up version for this URI if it's an open document.
		const other_doc = find_document(s, by_uri[i].0);
		const ver = match (other_doc) {
		case let p: *document => yield p.version;
		case null => yield 0i64;
		};
		// Hand off ownership of the inner slice.
		const bucket = by_uri[i].1;
		by_uri[i].1 = [];
		publish_diagnostics(s, by_uri[i].0, ver, bucket);
	};
};

fn find_or_create_uri_bucket(by_uri: *[](str, []json::value), uri: str) size = {
	let bu = *by_uri;
	for (let i = 0z; i < len(bu); i += 1) {
		if (bu[i].0 == uri) return i;
	};
	append(bu, (strings::dup(uri)!, []: []json::value))!;
	*by_uri = bu;
	return len(bu) - 1;
};

// Computes parse-only diagnostics for a document and returns a slice of
// json::value Diagnostic objects. Caller takes ownership.
fn parse_diagnostics_for_doc(s: *server, doc: *document) []json::value = {
	let r = analysis::parse_recover(analysis::bytes(&doc.buf), doc.uri);
	defer analysis::finish_parse_result(&r);

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
		json::put(&d, "range", encode_range(lsp::range {
			start = lsp::position {
				line = start.line,
				character = start.character,
			},
			end = lsp::position {
				line = end.line,
				character = end.character,
			},
		}))!;
		json::put(&d, "severity", 1: f64)!;
		json::set(&d, "source", "hare-lsp/parse": json::value)!;
		json::set(&d, "message", e.message: json::value)!;
		append(arr, d: json::value)!;
	};
	return arr;
};

// Sends textDocument/publishDiagnostics. `diagnostics` is consumed: ownership
// of the slice and its contents transfers into the wire encoding.
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
		fmt::fprintln(os::stderr, "hare-lsp: publishDiagnostics:",
			io::strerror(e))!;
	};
};

// Encodes an lsp::range into a json::value. Local copy to avoid pulling
// documents.ha helpers into here circularly.
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
export fn clear_diagnostics(s: *server, uri: str) void = {
	publish_diagnostics(s, uri, 0, []);
};
