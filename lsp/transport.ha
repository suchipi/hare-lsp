// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use bufio;
use encoding::utf8;
use fmt;
use io;
use strconv;
use strings;

// Errors returned by the LSP transport layer.
export type transport_error = !(
	io::error |
	utf8::invalid |
	bad_header |
	content_too_large
);

// The peer sent a malformed Content-Length header or framing block.
export type bad_header = !str;

// The peer sent a Content-Length larger than the configured limit. Limit is
// configurable to defend against memory exhaustion from a malicious client.
export type content_too_large = !size;

// Default cap on a single message body. Can be raised via [[reader_with_limit]]
// for clients that send large workspace edits or full-document syncs.
export def DEFAULT_MAX_BODY: size = 32 * 1024 * 1024; // 32 MiB

export type reader = struct {
	src: *bufio::scanner,
	max_body: size,
	// Reusable buffer for the message body. Grown on demand; never shrunk.
	body_buf: []u8,
	// Captures the raw header bytes read during the most recent [[read]]
	// call (including \r\n delimiters). Cleared at the start of every
	// call; on transport-error return, callers can inspect via
	// [[last_header_bytes]] to see what we did parse before the error.
	diag_header: []u8,
};

// Wraps an [[io::handle]] in a reader that yields LSP message bodies.
//
// The caller retains ownership of the underlying scanner and must call
// [[bufio::finish]] on it after the reader is no longer needed.
export fn new_reader(src: *bufio::scanner) reader = reader {
	src = src,
	max_body = DEFAULT_MAX_BODY,
	body_buf = [],
	diag_header = [],
};

// Like [[new_reader]] but with a custom maximum body size.
export fn new_reader_with_limit(
	src: *bufio::scanner,
	max_body: size,
) reader = reader {
	src = src,
	max_body = max_body,
	body_buf = [],
	diag_header = [],
};

// Frees memory associated with a reader. Does not close the underlying handle.
export fn finish_reader(r: *reader) void = {
	free(r.body_buf);
	free(r.diag_header);
};

// Returns the raw header bytes (including \r\n line endings) captured
// during the most recent [[read]] call. Diagnostic only: useful when a
// transport error returns to dump the partial header block to the log.
export fn last_header_bytes(r: *reader) const []u8 = r.diag_header;

// Reads the next LSP message body from the stream.
//
// On success, returns a slice borrowed from the reader's internal buffer that
// remains valid only until the next call to [[read]] on the same reader.
//
// Per LSP base protocol, the framing is:
//
//   Content-Length: <bytes>\r\n
//   [Content-Type: <type>\r\n]
//   \r\n
//   <body of <bytes> bytes>
//
// Headers other than Content-Length are accepted and ignored. The body itself
// is not parsed here; callers feed it to a JSON parser.
export fn read(r: *reader) ([]u8 | io::EOF | transport_error) = {
	// Reset the diagnostic header capture for this call; the underlying
	// storage is preserved so steady-state usage doesn't churn allocations.
	r.diag_header = r.diag_header[..0];

	let length: (size | void) = void;
	for (true) {
		const line = match (bufio::scan_string(r.src, "\r\n")) {
		case let s: const str =>
			yield s;
		case io::EOF =>
			return io::EOF;
		case let err: io::error =>
			return err;
		case utf8::invalid =>
			return utf8::invalid;
		};

		// Capture the line + delimiter for diagnostics. This runs on
		// every header line, success or failure; on success the buffer
		// is overwritten by the next call.
		append(r.diag_header, strings::toutf8(line)...)?;
		append(r.diag_header, ['\r': u8, '\n': u8]...)?;

		if (len(line) == 0) {
			break; // end of headers
		};

		// Split on the first ':' — header names are ASCII per the spec.
		const idx = match (strings::index(line, ':')) {
		case let i: size =>
			yield i;
		case void =>
			return "header missing ':'": bad_header;
		};
		const name = strings::sub(line, 0, idx);
		const value = strings::trim(strings::sub(line, idx + 1, strings::end));

		if (header_eq(name, "content-length")) {
			match (strconv::stoz(value)) {
			case let n: size =>
				length = n;
			case =>
				return "Content-Length not an unsigned integer": bad_header;
			};
		};
		// Other headers (Content-Type, etc.) are accepted and ignored.

	};

	const n = match (length) {
	case void =>
		return "missing Content-Length header": bad_header;
	case let n: size =>
		yield n;
	};

	if (n > r.max_body) {
		return n: content_too_large;
	};

	if (len(r.body_buf) < n) {
		append(r.body_buf, [0...], n - len(r.body_buf))?;
	};

	let buf = r.body_buf[..n];
	match (io::readall(r.src, buf)?) {
	case size =>
		return buf;
	case io::EOF =>
		return io::EOF;
	};
};

// Closes a handle, ignoring any error. Useful in `defer` cleanup where
// the alternative `io::close(h)!` would abort the process on failure —
// usually for failures we can't do anything about anyway.
export fn safe_close(h: io::handle) void = {
	match (io::close(h)) {
	case void => void;
	case io::error => void;
	};
};

// Writes an LSP message to the given handle.
//
// The body is sent verbatim as the Content-Length-prefixed payload. Returns
// the total number of bytes written (headers + blank line + body).
export fn write(out: io::handle, body: const []u8) (size | io::error) = {
	let total = 0z;
	total += fmt::fprintf(out, "Content-Length: {}\r\n\r\n", len(body))?;
	total += io::writeall(out, body)?;
	return total;
};

// Case-insensitive comparison against a lowercase ASCII literal. The literal
// argument MUST be lowercase ASCII; the input string is compared byte-by-byte
// with ASCII letters folded to lowercase. Non-ASCII bytes are not folded.
fn header_eq(input: str, lower: str) bool = {
	const a = strings::toutf8(input);
	const b = strings::toutf8(lower);
	if (len(a) != len(b)) return false;
	for (let i = 0z; i < len(a); i += 1) {
		let ca = a[i];
		if (ca >= 'A': u8 && ca <= 'Z': u8) {
			ca += 'a': u8 - 'A': u8;
		};
		if (ca != b[i]) return false;
	};
	return true;
};

// Returns a human-readable description of a transport error. The result may be
// statically allocated and is overwritten on subsequent calls.
export fn strerror(err: transport_error) const str = {
	static let buf: [256]u8 = [0...];
	match (err) {
	case let e: io::error =>
		return io::strerror(e);
	case utf8::invalid =>
		return "invalid UTF-8 in LSP message header";
	case let h: bad_header =>
		return fmt::bsprintf(buf, "malformed LSP header: {}", h: str)!;
	case let n: content_too_large =>
		return fmt::bsprintf(buf, "LSP message body too large: {} bytes", n: size)!;
	};
};
