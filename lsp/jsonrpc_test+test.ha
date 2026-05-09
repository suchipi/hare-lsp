// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use bytes;
use encoding::json;
use io;
use memio;
use strings;

@test fn decode_request_with_number_id() void = {
	const body = `{"jsonrpc":"2.0","id":42,"method":"hover","params":{"x":1}}`;
	const m = decode(strings::toutf8(body)) as message;
	defer finish_message(m);
	const r = m as request;
	assert(r.id as f64 == 42.0);
	assert(r.method == "hover");
	const p = r.params as json::value;
	const o = p as json::object;
	const x = json::get(&o, "x") as *json::value;
	assert(*x as f64 == 1.0);
};

@test fn decode_request_with_string_id() void = {
	const body = `{"jsonrpc":"2.0","id":"abc","method":"foo"}`;
	const m = decode(strings::toutf8(body)) as message;
	defer finish_message(m);
	const r = m as request;
	assert(r.id as str == "abc");
	assert(r.method == "foo");
	assert(r.params is void);
};

@test fn decode_notification() void = {
	const body = `{"jsonrpc":"2.0","method":"didChange","params":{}}`;
	const m = decode(strings::toutf8(body)) as message;
	defer finish_message(m);
	const n = m as notification;
	assert(n.method == "didChange");
	assert(n.params is json::value);
};

@test fn decode_response_result() void = {
	const body = `{"jsonrpc":"2.0","id":7,"result":{"ok":true}}`;
	const m = decode(strings::toutf8(body)) as message;
	defer finish_message(m);
	const r = m as response;
	assert(r.id as f64 == 7.0);
	const v = r.body as json::value;
	const o = v as json::object;
	const ok = json::get(&o, "ok") as *json::value;
	assert(*ok as bool);
};

@test fn decode_response_error() void = {
	const body = `{"jsonrpc":"2.0","id":7,"error":{"code":-32601,"message":"nope"}}`;
	const m = decode(strings::toutf8(body)) as message;
	defer finish_message(m);
	const r = m as response;
	const e = r.body as response_error;
	assert(e.code == -32601);
	assert(e.message == "nope");
};

@test fn decode_rejects_missing_jsonrpc() void = {
	const body = `{"id":1,"method":"foo"}`;
	assert(decode(strings::toutf8(body)) is decode_error);
};

@test fn decode_rejects_wrong_version() void = {
	const body = `{"jsonrpc":"1.0","id":1,"method":"foo"}`;
	assert(decode(strings::toutf8(body)) is decode_error);
};

@test fn decode_rejects_response_with_both_result_and_error() void = {
	const body = `{"jsonrpc":"2.0","id":1,"result":1,"error":{"code":1,"message":""}}`;
	assert(decode(strings::toutf8(body)) is decode_error);
};

@test fn decode_rejects_array_at_top_level() void = {
	const body = `[1,2,3]`;
	assert(decode(strings::toutf8(body)) is decode_error);
};

@test fn encode_response_result_roundtrip() void = {
	let buf = memio::dynamic();
	defer io::close(&buf)!;
	encode_response_result(&buf, 1.0, true: json::value)!;
	const out = memio::buffer(&buf);
	// Skip the framing to isolate the body for round-trip via decode().
	const idx = bytes::index(out, strings::toutf8("\r\n\r\n")) as size;
	const body = out[idx + 4..];
	const m = decode(body) as message;
	defer finish_message(m);
	const r = m as response;
	assert(r.id as f64 == 1.0);
	assert(r.body as json::value as bool);
};

@test fn encode_response_error_roundtrip() void = {
	let buf = memio::dynamic();
	defer io::close(&buf)!;
	const err = response_error {
		code = -32601,
		message = "method not found",
		data = void,
	};
	encode_response_error(&buf, 5.0, err)!;
	const out = memio::buffer(&buf);
	const idx = bytes::index(out, strings::toutf8("\r\n\r\n")) as size;
	const body = out[idx + 4..];
	const m = decode(body) as message;
	defer finish_message(m);
	const r = m as response;
	const e = r.body as response_error;
	assert(e.code == -32601);
	assert(e.message == "method not found");
};

@test fn encode_notification_emits_framing() void = {
	let buf = memio::dynamic();
	defer io::close(&buf)!;
	encode_notification(&buf, "window/logMessage", void)!;
	const out = strings::fromutf8(memio::buffer(&buf))!;
	assert(strings::hasprefix(out, "Content-Length: "));
	assert(strings::contains(out, `"method":"window/logMessage"`));
};
