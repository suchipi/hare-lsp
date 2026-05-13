// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Document buffer with an incrementally-maintained line index. The current
// implementation backs storage with []u8 plus a fully-rebuilt line index per
// edit. For the LSP traffic profile (a few keystrokes per second) this is
// well under the 1 ms budget for files up to several MB and has the virtue of
// staying boringly simple. The interface allows a swap to a rope if needed.

use strings;

// A document buffer.
export type buffer = struct {
	// Raw bytes; valid UTF-8 if the client sent valid UTF-8.
	data: []u8,
	// Byte offset of the start of each line. Always begins with 0.
	line_index: []size,
};

// Constructs a buffer from initial text. Takes a copy.
export fn from_str(text: str) buffer = {
	const bytes_in = strings::toutf8(text);
	let data: []u8 = alloc([], len(bytes_in))!;
	append(data, bytes_in...)!;
	return buffer {
		data = data,
		line_index = build_line_index(data),
	};
};

// Constructs a buffer from a borrowed byte slice. Takes a copy.
export fn from_bytes(text: []u8) buffer = {
	let data: []u8 = alloc([], len(text))!;
	append(data, text...)!;
	return buffer {
		data = data,
		line_index = build_line_index(data),
	};
};

// Releases memory associated with a buffer.
export fn finish(b: *buffer) void = {
	free(b.data);
	free(b.line_index);
};

// Returns the buffer's contents as a borrowed byte slice. Valid until the
// next mutation.
export fn bytes(b: *buffer) []u8 = b.data;

// Returns the buffer's contents as a borrowed string. Caller must not use
// the result after the next mutation.
export fn as_string(b: *buffer) str = strings::fromutf8(b.data)!;

// Replaces the buffer's contents wholesale. Used for full document sync and
// for didSave with includeText.
export fn replace_all(b: *buffer, text: []u8) void = {
	free(b.data);
	free(b.line_index);
	let data: []u8 = alloc([], len(text))!;
	append(data, text...)!;
	b.data = data;
	b.line_index = build_line_index(b.data);
};

// Replaces the byte range [start..end) (0-based, half-open) with new_text.
// Returns the difference in length: new_text_len - (end - start).
//
// If start > end or end > len(buffer), the range is clamped.
export fn replace_range(
	b: *buffer,
	start: size,
	end: size,
	new_text: []u8,
) ssize = {
	let s = if (start > len(b.data)) len(b.data) else start;
	let e = if (end > len(b.data)) len(b.data) else end;
	if (s > e) s = e;

	const old_len = e - s;
	const delta = len(new_text): ssize - old_len: ssize;

	if (delta == 0) {
		// Same-size replacement: just overwrite in place.
		b.data[s..e] = new_text[..];
	} else if (delta > 0) {
		// Growing: append zeros, then shift right, then write new bytes.
		const grow = delta: size;
		append(b.data, [0...], grow)!;
		// Shift the suffix right by `grow` bytes.
		// Source range [e..old_len_total]; destination [e+grow..new_total].
		const new_total = len(b.data);
		const old_total = new_total - grow;
		// Iterate from right to left to avoid overwriting.
		let i = old_total;
		for (i > e; i -= 1) {
			b.data[i + grow - 1] = b.data[i - 1];
		};
		b.data[s..s + len(new_text)] = new_text[..];
	} else {
		// Shrinking: write new bytes, then shift suffix left, then trim.
		const shrink = -delta: size;
		b.data[s..s + len(new_text)] = new_text[..];
		// Shift suffix [e..total] left by shrink.
		const total = len(b.data);
		for (let i = e; i < total; i += 1) {
			b.data[i - shrink] = b.data[i];
		};
		delete(b.data[total - shrink..total]);
	};

	free(b.line_index);
	b.line_index = build_line_index(b.data);
	return delta;
};

// Signed size for delta returns.
export type ssize = i64;

// Returns the number of lines in the buffer.
export fn line_count(b: *buffer) size = len(b.line_index);
