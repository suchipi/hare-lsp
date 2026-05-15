// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Encode/decode helpers between strongly-typed LSP types and json::value.
//
// Style: encode_X functions ALLOCATE a fresh json::value the caller must pass
// to json::finish. decode_X functions BORROW from the input (no allocations
// for primitives; strings are duplicated only where the result needs to
// outlive the input).

use encoding::json;
use strings;

// --- shared json::object accessors ----------------------------------
//
// These deduplicate the "extract optional X from JSON object" boilerplate
// that otherwise appears as 5+ lines of nested matches in every handler.
//
// Each returns a borrowed view of the input where possible; strings are
// returned as-is from the json::value (no copies).
// Returns the value at obj[key] as a string, or void if the key is
// absent or the value isn't a string.
//
// @returns: borrowed from o
// @param o: borrowed
// @param key: borrowed
export fn json_str(o: *json::object, key: str) (str | void) = {
	const p = match (json::get(o, key)) {
	case let p: *json::value =>
		yield p;
	case void =>
		return void;
	};
	return match (*p) {
	case let s: str =>
		yield s;
	case =>
		yield void;
	};
};

// Returns the value at obj[key] as a number, or void.
//
// @param o: borrowed
// @param key: borrowed
export fn json_num(o: *json::object, key: str) (f64 | void) = {
	const p = match (json::get(o, key)) {
	case let p: *json::value =>
		yield p;
	case void =>
		return void;
	};
	return match (*p) {
	case let f: f64 =>
		yield f;
	case =>
		yield void;
	};
};

// Returns the value at obj[key] as an object, or void.
//
// @returns: borrowed from o
// @param o: borrowed
// @param key: borrowed
export fn json_obj(o: *json::object, key: str) (json::object | void) = {
	const p = match (json::get(o, key)) {
	case let p: *json::value =>
		yield p;
	case void =>
		return void;
	};
	return match (*p) {
	case let oo: json::object =>
		yield oo;
	case =>
		yield void;
	};
};

// Returns the value at obj[key] as an array, or void.
//
// @returns: borrowed from o
// @param o: borrowed
// @param key: borrowed
export fn json_arr(o: *json::object, key: str) ([]json::value | void) = {
	const p = match (json::get(o, key)) {
	case let p: *json::value =>
		yield p;
	case void =>
		return void;
	};
	return match (*p) {
	case let a: []json::value =>
		yield a;
	case =>
		yield void;
	};
};

// Returns the value at obj[key] as a bool, or void.
//
// @param o: borrowed
// @param key: borrowed
export fn json_bool(o: *json::object, key: str) (bool | void) = {
	const p = match (json::get(o, key)) {
	case let p: *json::value =>
		yield p;
	case void =>
		return void;
	};
	return match (*p) {
	case let b: bool =>
		yield b;
	case =>
		yield void;
	};
};

// Unwraps `(json::value | void)` (the typical type of a request's
// `params`) into a json::object, or returns void if it's not an object.
//
// @returns: borrowed from p
// @param p: borrowed
export fn params_object(p: (json::value | void)) (json::object | void) = {
	const v = match (p) {
	case let v: json::value =>
		yield v;
	case void =>
		return void;
	};
	return match (v) {
	case let o: json::object =>
		yield o;
	case =>
		yield void;
	};
};

// --- Position --------------------------------------------------------
// @returns: owned
export fn encode_position(p: position) (json::value | nomem) = {
	let o = json::newobject();
	let ok = false;
	defer if (!ok) json::finish(o);
	json::put(&o, "line", p.line: f64)?;
	json::put(&o, "character", p.character: f64)?;
	ok = true;
	return o;
};

// @param v: borrowed
export fn decode_position(v: json::value) (position | bad_message) = {
	const o = match (v) {
	case let o: json::object =>
		yield o;
	case =>
		return "Position must be an object": bad_message;
	};
	const line = match (json::get(&o, "line")) {
	case let v: *json::value =>
		yield match (*v) {
		case let f: f64 =>
			yield f: u32;
		case =>
			return "Position.line must be a number": bad_message;
		};
	case =>
		return "Position.line is required": bad_message;
	};
	const character = match (json::get(&o, "character")) {
	case let v: *json::value =>
		yield match (*v) {
		case let f: f64 =>
			yield f: u32;
		case =>
			return "Position.character must be a number": bad_message;
		};
	case =>
		return "Position.character is required": bad_message;
	};
	return position { line = line, character = character };
};

// --- Range ------------------------------------------------------------
// @returns: owned
export fn encode_range(r: range) (json::value | nomem) = {
	let o = json::newobject();
	let ok = false;
	defer if (!ok) json::finish(o);
	json::put(&o, "start", encode_position(r.start)?)?;
	json::put(&o, "end", encode_position(r.end)?)?;
	ok = true;
	return o;
};

// @param v: borrowed
export fn decode_range(v: json::value) (range | bad_message) = {
	const o = match (v) {
	case let o: json::object =>
		yield o;
	case =>
		return "Range must be an object": bad_message;
	};
	const start = match (json::get(&o, "start")) {
	case let v: *json::value =>
		yield decode_position(*v)?;
	case =>
		return "Range.start is required": bad_message;
	};
	const end = match (json::get(&o, "end")) {
	case let v: *json::value =>
		yield decode_position(*v)?;
	case =>
		return "Range.end is required": bad_message;
	};
	return range { start = start, end = end };
};

// --- Location ---------------------------------------------------------
// @returns: owned
export fn encode_location(l: location) (json::value | nomem) = {
	let o = json::newobject();
	let ok = false;
	defer if (!ok) json::finish(o);
	json::set(&o, "uri", l.uri: json::value)?;
	json::put(&o, "range", encode_range(l.range)?)?;
	ok = true;
	return o;
};

// --- TextDocumentIdentifier ------------------------------------------
// @returns: owned
// @param v: borrowed
export fn decode_text_document_identifier(
	v: json::value,
) (text_document_identifier | bad_message) = {
	const o = match (v) {
	case let o: json::object =>
		yield o;
	case =>
		return "TextDocumentIdentifier must be an object": bad_message;
	};
	const uri = match (json::get(&o, "uri")) {
	case let v: *json::value =>
		yield match (*v) {
		case let s: str =>
			yield strings::dup(s)!;
		case =>
			return "TextDocumentIdentifier.uri must be a string": bad_message;
		};
	case =>
		return "TextDocumentIdentifier.uri is required": bad_message;
	};
	return text_document_identifier { uri = uri };
};

// --- Diagnostic -------------------------------------------------------
// @returns: owned
export fn encode_diagnostic(d: diagnostic) (json::value | nomem) = {
	let o = json::newobject();
	let ok = false;
	defer if (!ok) json::finish(o);
	json::put(&o, "range", encode_range(d.range)?)?;
	match (d.severity) {
	case void => void;
	case let s: diagnostic_severity =>
		json::put(&o, "severity", s: int: f64)?;
	};
	match (d.code) {
	case void => void;
	case let s: str =>
		json::set(&o, "code", s: json::value)?;
	case let n: i32 =>
		json::put(&o, "code", n: f64)?;
	};
	if (len(d.source) > 0) {
		json::set(&o, "source", d.source: json::value)?;
	};
	json::set(&o, "message", d.message: json::value)?;
	if (len(d.tags) > 0) {
		let tags: []json::value = [];
		let ok2 = false;
		defer if (!ok2) {
			for (let i = 0z; i < len(tags); i += 1) {
				json::finish(tags[i]);
			};
			free(tags);
		};
		for (let i = 0z; i < len(d.tags); i += 1) {
			append(tags, d.tags[i]: int: f64: json::value)?;
		};
		ok2 = true;
		json::put(&o, "tags", tags: json::value)?;
	};
	ok = true;
	return o;
};

// --- URI handling -----------------------------------------------------
// Strips the "file://" scheme prefix from `uri` and percent-decodes the
// rest. Returns a freshly-allocated string the caller owns.
//
// Per RFC 3986 file URIs may contain `%XX` triplets for any byte not in
// the unreserved set — spaces become `%20`, parentheses become `%28`/
// `%29`, non-ASCII bytes are UTF-8-then-percent-encoded. The naïve
// `strings::sub(uri, len("file://"), end)` is wrong for any path that
// passed through a browser, a percent-encoding LSP client (most of
// them), or contains non-ASCII characters.
//
// Invalid `%XX` sequences (non-hex digits, truncated at end of input)
// are passed through verbatim; the caller will get a non-existent path
// and io::open will fail, which is the right failure mode.
//
// @returns: owned
// @param uri: borrowed
export fn uri_decode_path(uri: str) str = {
	const scheme = "file://";
	const rest = if (strings::hasprefix(uri, scheme)) {
		yield strings::sub(uri, len(scheme), strings::end);
	} else {
		yield uri;
	};
	const src = strings::toutf8(rest);
	let out: []u8 = [];
	let i = 0z;
	for (i < len(src)) {
		const b = src[i];
		if (b == '%': u8 && i + 2 < len(src)) {
			const h1 = hex_digit(src[i + 1]);
			const h2 = hex_digit(src[i + 2]);
			if (h1 >= 0 && h2 >= 0) {
				append(out, (h1 << 4 | h2): u8)!;
				i += 3;
				continue;
			};
		};
		append(out, b)!;
		i += 1;
	};
	return strings::fromutf8(out)!;
};

fn hex_digit(b: u8) int = {
	if (b >= '0': u8 && b <= '9': u8) return (b - '0': u8): int;
	if (b >= 'a': u8 && b <= 'f': u8) return (b - 'a': u8 + 10): int;
	if (b >= 'A': u8 && b <= 'F': u8) return (b - 'A': u8 + 10): int;
	return -1;
};

// --- Errors -----------------------------------------------------------
// Errors raised during decoding. Always recoverable; the dispatcher converts
// these into JSON-RPC INVALID_PARAMS error responses.
export type bad_message = !str;
