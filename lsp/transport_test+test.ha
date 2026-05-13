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
	// diag_header captures lines as <line>\n (CR stripped), so build
	// the expected dump by replacing each \r\n with \n.
	const expected = "Content-Type: foo\nX-Trace: deadbeef\n\n";
	assert(bytes::equal(captured, strings::toutf8(expected)));
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
	// On success the captured block is the headers we just consumed,
	// each as <line>\n (CR stripped).
	assert(
		bytes::equal(last_header_bytes(&r), strings::toutf8("Content-Length: 2\n\n"))
	);

	assert(read(&r) is bad_header);
	assert(
		bytes::equal(last_header_bytes(&r), strings::toutf8("Content-Type: foo\n\n"))
	);
};

// Reading two LSP messages back to back where the first message's body
// ends exactly at the boundary between bytes that the bufio scanner
// will fetch in separate underlying reads. This guards against a class
// of stdlib bug where reading multi-byte delimiters could miss a
// delimiter that straddles the read-ahead boundary; the transport
// switched to single-byte LF reads precisely to avoid that.
@test fn read_back_to_back_long_first_message() void = {
	let buf = memio::dynamic();
	defer io::close(&buf)!;
	// Build a first body that's well over the bufio default BUFSZ
	// (4096) so the second message's header has to be fetched in a
	// later read-ahead. A body of ~5000 ASCII bytes is plenty.
	let big: []u8 = [];
	defer free(big);
	append(big, '"': u8)!;
	for (let i = 0z; i < 5000; i += 1) {
		append(big, 'x': u8)!;
	};
	append(big, '"': u8)!;
	write(&buf, big)!;
	write(&buf, strings::toutf8(`{"after":1}`))!;

	let src = memio::fixed(memio::buffer(&buf));
	let scan = bufio::newscanner(&src);
	defer bufio::finish(&scan);
	let r = new_reader(&scan);
	defer finish_reader(&r);

	const first = read(&r) as []u8;
	assert(len(first) == len(big));
	assert(first[0] == '"': u8 && first[len(first) - 1] == '"': u8);

	const second = read(&r) as []u8;
	assert(bytes::equal(second, strings::toutf8(`{"after":1}`)));
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
