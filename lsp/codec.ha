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
export fn json_str(o: *json::object, key: str) (str | void) = {
	const p = match (json::get(o, key)) {
	case let p: *json::value => yield p;
	case void => return void;
	};
	return match (*p) {
	case let s: str => yield s;
	case => yield void;
	};
};

// Returns the value at obj[key] as a number, or void.
export fn json_num(o: *json::object, key: str) (f64 | void) = {
	const p = match (json::get(o, key)) {
	case let p: *json::value => yield p;
	case void => return void;
	};
	return match (*p) {
	case let f: f64 => yield f;
	case => yield void;
	};
};

// Returns the value at obj[key] as an object, or void.
export fn json_obj(o: *json::object, key: str) (json::object | void) = {
	const p = match (json::get(o, key)) {
	case let p: *json::value => yield p;
	case void => return void;
	};
	return match (*p) {
	case let oo: json::object => yield oo;
	case => yield void;
	};
};

// Returns the value at obj[key] as an array, or void.
export fn json_arr(o: *json::object, key: str) ([]json::value | void) = {
	const p = match (json::get(o, key)) {
	case let p: *json::value => yield p;
	case void => return void;
	};
	return match (*p) {
	case let a: []json::value => yield a;
	case => yield void;
	};
};

// Returns the value at obj[key] as a bool, or void.
export fn json_bool(o: *json::object, key: str) (bool | void) = {
	const p = match (json::get(o, key)) {
	case let p: *json::value => yield p;
	case void => return void;
	};
	return match (*p) {
	case let b: bool => yield b;
	case => yield void;
	};
};

// Unwraps `(json::value | void)` (the typical type of a request's
// `params`) into a json::object, or returns void if it's not an object.
export fn params_object(p: (json::value | void)) (json::object | void) = {
	const v = match (p) {
	case let v: json::value => yield v;
	case void => return void;
	};
	return match (v) {
	case let o: json::object => yield o;
	case => yield void;
	};
};

// --- Position --------------------------------------------------------

export fn encode_position(p: position) (json::value | nomem) = {
	let o = json::newobject();
	let ok = false;
	defer if (!ok) json::finish(o);
	json::put(&o, "line", p.line: f64)?;
	json::put(&o, "character", p.character: f64)?;
	ok = true;
	return o;
};

export fn decode_position(v: json::value) (position | bad_message) = {
	const o = match (v) {
	case let o: json::object => yield o;
	case => return "Position must be an object": bad_message;
	};
	const line = match (json::get(&o, "line")) {
	case let v: *json::value =>
		yield match (*v) {
		case let f: f64 => yield f: u32;
		case => return "Position.line must be a number": bad_message;
		};
	case => return "Position.line is required": bad_message;
	};
	const character = match (json::get(&o, "character")) {
	case let v: *json::value =>
		yield match (*v) {
		case let f: f64 => yield f: u32;
		case => return "Position.character must be a number": bad_message;
		};
	case => return "Position.character is required": bad_message;
	};
	return position { line = line, character = character };
};

// --- Range ------------------------------------------------------------

export fn encode_range(r: range) (json::value | nomem) = {
	let o = json::newobject();
	let ok = false;
	defer if (!ok) json::finish(o);
	json::put(&o, "start", encode_position(r.start)?)?;
	json::put(&o, "end", encode_position(r.end)?)?;
	ok = true;
	return o;
};

export fn decode_range(v: json::value) (range | bad_message) = {
	const o = match (v) {
	case let o: json::object => yield o;
	case => return "Range must be an object": bad_message;
	};
	const start = match (json::get(&o, "start")) {
	case let v: *json::value => yield decode_position(*v)?;
	case => return "Range.start is required": bad_message;
	};
	const end = match (json::get(&o, "end")) {
	case let v: *json::value => yield decode_position(*v)?;
	case => return "Range.end is required": bad_message;
	};
	return range { start = start, end = end };
};

// --- Location ---------------------------------------------------------

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

export fn decode_text_document_identifier(v: json::value) (text_document_identifier | bad_message) = {
	const o = match (v) {
	case let o: json::object => yield o;
	case => return "TextDocumentIdentifier must be an object": bad_message;
	};
	const uri = match (json::get(&o, "uri")) {
	case let v: *json::value =>
		yield match (*v) {
		case let s: str => yield strings::dup(s)!;
		case => return "TextDocumentIdentifier.uri must be a string": bad_message;
		};
	case => return "TextDocumentIdentifier.uri is required": bad_message;
	};
	return text_document_identifier { uri = uri };
};

// --- Diagnostic -------------------------------------------------------

export fn encode_diagnostic(d: diagnostic) (json::value | nomem) = {
	let o = json::newobject();
	let ok = false;
	defer if (!ok) json::finish(o);
	json::put(&o, "range", encode_range(d.range)?)?;
	match (d.severity) {
	case void => void;
	case let s: diagnostic_severity =>
		json::put(&o, "severity", (s: int): f64)?;
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
			append(tags, (d.tags[i]: int): f64: json::value)?;
		};
		ok2 = true;
		json::put(&o, "tags", tags: json::value)?;
	};
	ok = true;
	return o;
};

// --- Errors -----------------------------------------------------------

// Errors raised during decoding. Always recoverable; the dispatcher converts
// these into JSON-RPC INVALID_PARAMS error responses.
export type bad_message = !str;
