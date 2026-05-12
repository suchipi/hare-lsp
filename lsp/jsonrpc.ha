// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// JSON-RPC 2.0 message decoding and encoding for LSP. The LSP base protocol is
// JSON-RPC 2.0 with Content-Length-prefixed framing (see transport.ha).

use encoding::json;
use fmt;
use io;
use memio;
use strings;

// Standard JSON-RPC 2.0 / LSP error codes. Negative values are reserved by the
// JSON-RPC and LSP specs.
export type error_code = int;

export def PARSE_ERROR: error_code = -32700;

export def INVALID_REQUEST: error_code = -32600;

export def METHOD_NOT_FOUND: error_code = -32601;

export def INVALID_PARAMS: error_code = -32602;

export def INTERNAL_ERROR: error_code = -32603;

// LSP-specific error codes (JSON-RPC reserves the -32000..-32099 range for
// implementation-defined server errors; LSP uses several of them).
export def SERVER_NOT_INITIALIZED: error_code = -32002;

export def UNKNOWN_ERROR_CODE: error_code = -32001;

// Reasons reported via responseError.code per LSP 3.17.
export def REQUEST_FAILED: error_code = -32803;

export def SERVER_CANCELLED: error_code = -32802;

export def CONTENT_MODIFIED: error_code = -32801;

export def REQUEST_CANCELLED: error_code = -32800;

// A request id is either a number or a string per JSON-RPC. We retain the
// original shape to echo back exactly.
export type id = (f64 | str);

// A decoded JSON-RPC message. The variant carries which kind of message this
// is. Borrowed: the underlying [[json::value]] is owned by the caller and must
// outlive this message.
export type message = (request | notification | response);

// A request from peer to us. Expects a response keyed by [[id]].
export type request = struct {
	id: id,
	method: str,
	// May be void if the request had no params, an object, or an array.
	params: (json::value | void),
};

// A one-way notification from peer to us.
export type notification = struct {
	method: str,
	params: (json::value | void),
};

// A response from the peer to a server-initiated request we sent. Either
// result is set (success) or error is set, never both.
export type response = struct {
	id: id,
	body: (json::value | response_error),
};

// A JSON-RPC response error.
export type response_error = struct {
	code: error_code,
	message: str,
	// May be void; carries arbitrary structured data per JSON-RPC.
	data: (json::value | void),
};

// Errors arising from message decoding. These are recoverable; a server should
// reply with an INVALID_REQUEST error and continue processing further messages.
export type decode_error = !str;

// Decodes a JSON-RPC 2.0 message body (raw UTF-8 bytes) into a [[message]].
//
// The caller takes ownership of any allocated json::value embedded in the
// returned message variants and must call [[finish_message]] when done.
export fn decode(body: const []u8) (message | decode_error | json::error) = {
	const v = match (json::load(&fixed_reader(body))) {
	case let v: json::value =>
		yield v;
	case let e: json::error =>
		return e;
	case nomem =>
		return "out of memory parsing JSON": decode_error;
	};

	// Wrap so we destroy v on any error path below.
	let owned = true;
	defer if (owned) json::finish(v);

	const obj = match (v) {
	case let o: json::object =>
		yield o;
	case =>
		return "JSON-RPC message must be an object": decode_error;
	};

	const jsonrpc = match (obj_get(&obj, "jsonrpc")) {
	case let s: str =>
		yield s;
	case =>
		return `missing or non-string "jsonrpc" field`: decode_error;
	};
	if (jsonrpc != "2.0") {
		return `"jsonrpc" must equal "2.0"`: decode_error;
	};

	const has_method = obj_has(&obj, "method");
	const has_id = obj_has(&obj, "id");

	if (has_method) {
		const method = match (obj_get(&obj, "method")) {
		case let s: str =>
			yield s;
		case =>
			return `"method" must be a string`: decode_error;
		};
		const params = match (obj_take_owned(&obj, "params")) {
		case let v: json::value =>
			yield v: (json::value | void);
		case void =>
			yield void;
		};
		if (has_id) {
			const id = match (decode_id(&obj)) {
			case let i: id =>
				yield i;
			case let e: decode_error =>
				return e;
			};
			owned = false;
			return request {
				id = id,
				method = strings::dup(method)!,
				params = params,
			};
		} else {
			owned = false;
			return notification {
				method = strings::dup(method)!,
				params = params,
			};
		};
	};

	if (!has_id) {
		return `message must have "method" or "id"`: decode_error;
	};

	// Response.
	const id = match (decode_id(&obj)) {
	case let i: id =>
		yield i;
	case let e: decode_error =>
		return e;
	};
	const has_result = obj_has(&obj, "result");
	const has_error = obj_has(&obj, "error");
	if (has_result == has_error) {
		return `response must have exactly one of "result" or "error"`: decode_error;
	};
	if (has_result) {
		const result: json::value = match (obj_take_owned(&obj, "result")) {
		case let v: json::value =>
			yield v;
		case void =>
			yield json::_null: json::value;
		};
		owned = false;
		return response {
			id = id,
			body = result,
		};
	};
	const err_obj = match (obj_get(&obj, "error")) {
	case let o: json::object =>
		yield o;
	case =>
		return `"error" must be an object`: decode_error;
	};
	const code = match (obj_get(&err_obj, "code")) {
	case let f: f64 =>
		yield f: int: error_code;
	case =>
		return `error.code must be a number`: decode_error;
	};
	const msg = match (obj_get(&err_obj, "message")) {
	case let s: str =>
		yield s;
	case =>
		return `error.message must be a string`: decode_error;
	};
	const data = match (obj_take_owned(&err_obj, "data")) {
	case let v: json::value =>
		yield v: (json::value | void);
	case void =>
		yield void;
	};
	owned = false;
	return response {
		id = id,
		body = response_error {
			code = code,
			message = strings::dup(msg)!,
			data = data,
		},
	};
};

fn decode_id(obj: *json::object) (id | decode_error) = {
	match (obj_get(obj, "id")) {
	case let f: f64 =>
		return f;
	case let s: str =>
		return strings::dup(s)!: id;
	case =>
		return `"id" must be a number or string`: decode_error;
	};
};

// Frees memory associated with a decoded message. This frees the strings
// allocated for method/id and any embedded params/result/data values.
export fn finish_message(m: message) void = {
	match (m) {
	case let r: request =>
		free(r.method);
		free_id(r.id);
		match (r.params) {
		case let v: json::value =>
			json::finish(v);
		case void => void;
		};
	case let n: notification =>
		free(n.method);
		match (n.params) {
		case let v: json::value =>
			json::finish(v);
		case void => void;
		};
	case let r: response =>
		free_id(r.id);
		match (r.body) {
		case let v: json::value =>
			json::finish(v);
		case let e: response_error =>
			free(e.message);
			match (e.data) {
			case let v: json::value =>
				json::finish(v);
			case void => void;
			};
		};
	};
};

fn free_id(i: id) void = {
	match (i) {
	case f64 => void;
	case let s: str =>
		free(s);
	};
};

// Encodes and frames a successful response. Returns total bytes written
// (headers + blank line + body).
export fn encode_response_result(
	out: io::handle,
	id: id,
	result: json::value,
) (size | io::error) = {
	let buf = memio::dynamic();
	defer safe_close(&buf);
	fmt::fprint(&buf, `{"jsonrpc":"2.0","id":`)?;
	encode_id(&buf, id)?;
	fmt::fprint(&buf, `,"result":`)?;
	json::dump(&buf, result)?;
	fmt::fprint(&buf, `}`)?;
	return write(out, memio::buffer(&buf));
};

// Encodes and frames an error response.
export fn encode_response_error(
	out: io::handle,
	msg_id: (id | void),
	err: response_error,
) (size | io::error) = {
	let buf = memio::dynamic();
	defer safe_close(&buf);
	fmt::fprint(&buf, `{"jsonrpc":"2.0","id":`)?;
	match (msg_id) {
	case void =>
		fmt::fprint(&buf, "null")?;
	case let i: id =>
		encode_id(&buf, i)?;
	};
	fmt::fprintf(&buf, `,"error":{{"code":{},"message":`, err.code: int)?;
	json::dump(&buf, err.message: json::value)?;
	match (err.data) {
	case void => void;
	case let d: json::value =>
		fmt::fprint(&buf, `,"data":`)?;
		json::dump(&buf, d)?;
	};
	fmt::fprint(&buf, `}}`)?;
	return write(out, memio::buffer(&buf));
};

// Encodes and frames a notification.
export fn encode_notification(
	out: io::handle,
	method: str,
	params: (json::value | void),
) (size | io::error) = {
	let buf = memio::dynamic();
	defer safe_close(&buf);
	fmt::fprint(&buf, `{"jsonrpc":"2.0","method":`)?;
	json::dump(&buf, method: json::value)?;
	match (params) {
	case void => void;
	case let v: json::value =>
		fmt::fprint(&buf, `,"params":`)?;
		json::dump(&buf, v)?;
	};
	fmt::fprint(&buf, `}`)?;
	return write(out, memio::buffer(&buf));
};

// Encodes and frames a server-initiated request to the client.
export fn encode_request(
	out: io::handle,
	id: id,
	method: str,
	params: (json::value | void),
) (size | io::error) = {
	let buf = memio::dynamic();
	defer safe_close(&buf);
	fmt::fprint(&buf, `{"jsonrpc":"2.0","id":`)?;
	encode_id(&buf, id)?;
	fmt::fprint(&buf, `,"method":`)?;
	json::dump(&buf, method: json::value)?;
	match (params) {
	case void => void;
	case let v: json::value =>
		fmt::fprint(&buf, `,"params":`)?;
		json::dump(&buf, v)?;
	};
	fmt::fprint(&buf, `}`)?;
	return write(out, memio::buffer(&buf));
};

fn encode_id(out: io::handle, i: id) (size | io::error) = {
	match (i) {
	case let f: f64 =>
		return json::dump(out, f);
	case let s: str =>
		return json::dump(out, s: json::value);
	};
};

// --- helpers ---------------------------------------------------------
fn obj_has(o: *json::object, key: str) bool = {
	return json::get(o, key) is *json::value;
};

// Returns the value at key as a borrowed reference inside the json variant.
// The variant is the "narrowest" interpretation; callers `match` to extract.
// Returns void if the key is absent.
fn obj_get(o: *json::object, key: str) (json::value | void) = {
	match (json::get(o, key)) {
	case let v: *json::value =>
		return *v;
	case void =>
		return void;
	};
};

// Removes a key from the object, returning ownership of the value to the
// caller. Returns void if the key is absent. The caller is responsible for
// passing the value to [[json::finish]] when done.
fn obj_take_owned(o: *json::object, key: str) (json::value | void) = {
	return json::take(o, key);
};

// Wraps a byte slice as an io::handle for json::load.
type fixed = struct {
	stream: io::stream,
	src: const []u8,
	off: size,
};

const fixed_vtable = io::vtable {
	reader = &fixed_read,
	...
};

fn fixed_reader(src: const []u8) fixed = fixed {
	stream = &fixed_vtable,
	src = src,
	off = 0,
};

fn fixed_read(s: *io::stream, buf: []u8) (size | io::EOF | io::error) = {
	let f = s: *fixed;
	if (f.off >= len(f.src)) return io::EOF;
	const n = if (len(buf) > len(f.src) - f.off) len(f.src) - f.off else len(buf);
	buf[..n] = f.src[f.off..f.off + n];
	f.off += n;
	return n;
};
