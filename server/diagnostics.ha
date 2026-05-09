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
// diagnostics. Called from didOpen/didChange/didSave.
export fn refresh_diagnostics(s: *server, doc: *document) void = {
	let r = analysis::parse_recover(analysis::bytes(&doc.buf), doc.uri);
	defer analysis::finish_parse_result(&r);

	let arr: []json::value = [];
	let arr_owned = true;
	defer if (arr_owned) {
		for (let i = 0z; i < len(arr); i += 1) {
			json::finish(arr[i]);
		};
		free(arr);
	};

	const enc = position_encoding(s);
	const data = analysis::bytes(&doc.buf);
	const idx = doc.buf.line_index;

	for (let i = 0z; i < len(r.errors); i += 1) {
		const e = r.errors[i];
		const start = analysis::byte_to_position(data, idx, enc,
			e.location.off: size);
		// Heuristic end: same column as start; the lexer doesn't always
		// report a span. The end will be widened when the diagnostic
		// covers a known token range; for now we point to a 1-char span.
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
		// Severity 1 = Error.
		json::put(&d, "severity", 1: f64)!;
		json::set(&d, "source", "hare-lsp/parse": json::value)!;
		json::set(&d, "message", e.message: json::value)!;
		append(arr, d: json::value)!;
	};

	publish_diagnostics(s, doc.uri, doc.version, arr);
	arr_owned = false;
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
