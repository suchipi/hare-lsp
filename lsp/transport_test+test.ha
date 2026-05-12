// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use bufio;
use bytes;
use io;
use memio;
use strings;

@test fn read_single_message() void = {
	const input = "Content-Length: 24\r\n\r\n{\"jsonrpc\":\"2.0\",\"id\":1}";
	let src = memio::fixed(strings::toutf8(input));
	let scan = bufio::newscanner(&src);
	defer bufio::finish(&scan);
	let r = new_reader(&scan);
	defer finish_reader(&r);

	const body = read(&r) as []u8;
	assert(bytes::equal(body, strings::toutf8(`{"jsonrpc":"2.0","id":1}`)));

	// Subsequent read should hit EOF.
	assert(read(&r) is io::EOF);
};

@test fn read_multiple_messages() void = {
	let buf = memio::dynamic();
	defer io::close(&buf)!;
	write(&buf, strings::toutf8(`{"a":1}`))!;
	write(&buf, strings::toutf8(`{"b":2}`))!;
	write(&buf, strings::toutf8(`{"c":3}`))!;
	let src = memio::fixed(memio::buffer(&buf));
	let scan = bufio::newscanner(&src);
	defer bufio::finish(&scan);
	let r = new_reader(&scan);
	defer finish_reader(&r);

	const a = read(&r) as []u8;
	assert(bytes::equal(a, strings::toutf8(`{"a":1}`)));
	const b = read(&r) as []u8;
	assert(bytes::equal(b, strings::toutf8(`{"b":2}`)));
	const c = read(&r) as []u8;
	assert(bytes::equal(c, strings::toutf8(`{"c":3}`)));
	assert(read(&r) is io::EOF);
};

@test fn read_extra_headers_ignored() void = {
	const input =
		"Content-Type: application/vscode-jsonrpc; charset=utf-8\r\nContent-Length: 7\r\nX-Trace: deadbeef\r\n\r\n{\"a\":1}";
	let src = memio::fixed(strings::toutf8(input));
	let scan = bufio::newscanner(&src);
	defer bufio::finish(&scan);
	let r = new_reader(&scan);
	defer finish_reader(&r);

	const body = read(&r) as []u8;
	assert(bytes::equal(body, strings::toutf8(`{"a":1}`)));
};

@test fn read_case_insensitive_header() void = {
	const input = "content-length: 7\r\n\r\n{\"a\":1}";
	let src = memio::fixed(strings::toutf8(input));
	let scan = bufio::newscanner(&src);
	defer bufio::finish(&scan);
	let r = new_reader(&scan);
	defer finish_reader(&r);

	const body = read(&r) as []u8;
	assert(bytes::equal(body, strings::toutf8(`{"a":1}`)));
};

@test fn read_missing_content_length() void = {
	const input = "Content-Type: foo\r\n\r\n{\"a\":1}";
	let src = memio::fixed(strings::toutf8(input));
	let scan = bufio::newscanner(&src);
	defer bufio::finish(&scan);
	let r = new_reader(&scan);
	defer finish_reader(&r);

	assert(read(&r) is bad_header);
};

@test fn read_bad_content_length_value() void = {
	const input = "Content-Length: notanumber\r\n\r\n{}";
	let src = memio::fixed(strings::toutf8(input));
	let scan = bufio::newscanner(&src);
	defer bufio::finish(&scan);
	let r = new_reader(&scan);
	defer finish_reader(&r);

	assert(read(&r) is bad_header);
};

@test fn read_body_too_large() void = {
	const input = "Content-Length: 99999999\r\n\r\n";
	let src = memio::fixed(strings::toutf8(input));
	let scan = bufio::newscanner(&src);
	defer bufio::finish(&scan);
	let r = new_reader_with_limit(&scan, 1024);
	defer finish_reader(&r);

	match (read(&r)) {
	case let n: content_too_large =>
		assert(n: size == 99999999);
	case => abort("expected content_too_large");
	};
};

@test fn read_eof_at_start() void = {
	const input = "";
	let src = memio::fixed(strings::toutf8(input));
	let scan = bufio::newscanner(&src);
	defer bufio::finish(&scan);
	let r = new_reader(&scan);
	defer finish_reader(&r);

	assert(read(&r) is io::EOF);
};

@test fn last_header_bytes_captures_partial_block() void = {
	// A header block with no Content-Length; read() should return
	// bad_header AND leave the captured headers visible.
	const input = "Content-Type: foo\r\nX-Trace: deadbeef\r\n\r\n";
	let src = memio::fixed(strings::toutf8(input));
	let scan = bufio::newscanner(&src);
	defer bufio::finish(&scan);
	let r = new_reader(&scan);
	defer finish_reader(&r);

	assert(read(&r) is bad_header);
	const captured = last_header_bytes(&r);
	assert(bytes::equal(captured, strings::toutf8(input)));
};

@test fn last_header_bytes_resets_between_calls() void = {
	// First read succeeds; second hits bad_header. The capture should
	// reflect only the second call's headers, not be appended.
	const input = "Content-Length: 2\r\n\r\n{}Content-Type: foo\r\n\r\n";
	let src = memio::fixed(strings::toutf8(input));
	let scan = bufio::newscanner(&src);
	defer bufio::finish(&scan);
	let r = new_reader(&scan);
	defer finish_reader(&r);

	const body = read(&r) as []u8;
	assert(bytes::equal(body, strings::toutf8("{}")));
	// On success the captured block is the headers we just consumed.
	assert(
		bytes::equal(
			last_header_bytes(&r), strings::toutf8("Content-Length: 2\r\n\r\n"),
		)
	);

	assert(read(&r) is bad_header);
	assert(
		bytes::equal(
			last_header_bytes(&r), strings::toutf8("Content-Type: foo\r\n\r\n"),
		)
	);
};

@test fn write_emits_framing() void = {
	let buf = memio::dynamic();
	defer io::close(&buf)!;
	const body = strings::toutf8(`{"a":1}`);
	const n = write(&buf, body) as size;
	const expected = "Content-Length: 7\r\n\r\n{\"a\":1}";
	assert(n == len(strings::toutf8(expected)));
	assert(bytes::equal(memio::buffer(&buf), strings::toutf8(expected)));
};
