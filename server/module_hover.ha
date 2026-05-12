// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Module-name hover support. When the cursor is on a module name in a
// `use` declaration or on a path qualifier in code, we resolve the module
// to its on-disk directory, look for a `README` next to the .ha files,
// and render its contents as the hover body. The doc-ref linker
// ([[name]] -> command:hare-lsp.openLocation) runs on the README too, so
// references inside it stay clickable.

use fs;
use hare::module;
use io;
use lsp;
use os;
use strings;

// Result of detecting a module-name hover target. `segments` is the
// resolved module path (e.g. ["unix", "poll"]); `display` is the joined
// string used as the hover header (e.g. "unix::poll").
type module_hover_target = struct {
	segments: []str,
	display: str,
};

fn finish_module_hover_target(t: module_hover_target) void = {
	for (let i = 0z; i < len(t.segments); i += 1) {
		free(t.segments[i]);
	};
	free(t.segments);
	free(t.display);
};

// Tries to interpret the byte at `off` as part of a module path. Returns
// the resolved module ident if successful, or void if no module-shaped
// path encloses `off` or if the resolved path doesn't match a real module
// on HAREPATH.
//
// Resolution rules:
//   - Inside a `use` decl: the cursor is unambiguously on a module path;
//     trust the parser-built ident.
//   - Elsewhere: scan the source bytes for a contiguous
//     `ident(::ident)+` run around `off` and resolve only if at least one
//     `::` separator is present (a bare ident in code is more likely a
//     local symbol than a module reference).
//   - On a `::` byte: treat the cursor as if it were on the first
//     segment, regardless of which `::` it is.
//   - Otherwise: the segment under the cursor caps the resolved path
//     (segments[0..=cursor_seg]).
fn detect_module_hover(
	s: *server,
	doc: *document,
	data: []u8,
	off: size,
) (module_hover_target | void) = {
	const cache = parse_of(doc);

	// Use-statement path: walk imports for one whose loc encloses off.
	for (let i = 0z; i < len(cache.pr.subunit.imports); i += 1) {
		const imp = &cache.pr.subunit.imports[i];
		const start = imp.loc.start.off: size;
		const end = imp.loc.end.off: size;
		if (off < start || off > end) continue;
		// Determine which segment (or `::`) is under the cursor.
		const seg_idx = segment_index_at(data, imp.ident, start, off);
		const ident_end = match (seg_idx) {
		case let i: size =>
			yield i + 1;
		case void =>
			yield len(imp.ident);
		};
		return build_target(imp.ident, ident_end);
	};

	// Code-position path: scan for an `ident(::ident)+` run around off.
	const (run_start, run_end) = match (path_run_at(data, off)) {
	case let r: (size, size) =>
		yield r;
	case void =>
		return void;
	};
	const segments = parse_path_segments(data, run_start, run_end);
	defer free_str_slice(segments);
	if (len(segments) < 2) {
		// A bare ident in code isn't treated as a module on its own
		// (it would shadow legit local-symbol hovers). We still allow
		// it if the file imports a same-named module, but that's the
		// caller's job — fall through.
		return void;
	};
	// Find which segment encloses off; on a `::`, anchor to segment 0.
	const seg_under =
		segment_index_in_run(data, run_start, run_end, segments, off);
	const ident_end = match (seg_under) {
	case let i: size =>
		yield i + 1;
	case void =>
		yield len(segments);
	};
	const ident = strs_to_ident(segments[..ident_end]);
	defer free_str_slice(ident);
	// Require the path to actually match a module before claiming this
	// hover. Otherwise `decl1::decl2`-style code (none today, but hypo-
	// thetically) would suppress the existing decl-hover.
	match (find_module(s, ident)) {
	case let pair: (str, module::srcset) =>
		const (_, sset) = pair;
		let owned_set = sset;
		module::finish_srcset(&owned_set);
	case void =>
		return void;
	};
	return build_target(ident, len(ident));
};

fn build_target(ident: []str, take: size) module_hover_target = {
	let segs: []str = [];
	for (let i = 0z; i < take; i += 1) {
		append(segs, strings::dup(ident[i])!)!;
	};
	const display = strings::join("::", segs...)!;
	return module_hover_target {
		segments = segs,
		display = display,
	};
};

// Returns the segment index in `ident` that the byte at `off` lies in,
// based on the source positions of segments inside [start..end]. If `off`
// is on a `::` separator, returns 0 per the user-facing rule that all
// `::` anchor to the first segment. If `off` is before the first segment
// (e.g. on the `use ` keyword), returns void so the caller falls back to
// the full ident.
fn segment_index_at(
	data: []u8,
	ident: []str,
	start: size,
	off: size,
) (size | void) = {
	if (len(ident) == 0) return void;
	// Find the segments by scanning from `start` forward, locating
	// each segment's [byte_start..byte_end] in the source.
	let cursor = start;
	let segs: [](size, size) = [];
	defer free(segs);
	for (let i = 0z; i < len(ident); i += 1) {
		const name = strings::toutf8(ident[i]);
		// Skip non-ident bytes until we find this segment's first
		// character. The lex preserves "use" keyword + whitespace
		// before the path.
		for (cursor < len(data)) {
			if (cursor + len(name) <= len(data) &&
			bytes_equal(data[cursor..cursor + len(name)], name) &&
			(cursor + len(name) == len(data) ||
			!is_ident_byte_local(data[cursor + len(name)])) &&
			(cursor == 0 ||
			!is_ident_byte_local(data[cursor - 1]))) {
				break;
			};
			cursor += 1;
		};
		if (cursor >= len(data)) return void;
		const seg_start = cursor;
		const seg_end = cursor + len(name);
		append(segs, (seg_start, seg_end))!;
		cursor = seg_end;
	};
	// Classify off.
	if (off < segs[0].0) return void;
	for (let i = 0z; i < len(segs); i += 1) {
		if (off >= segs[i].0 && off <= segs[i].1) return i;
	};
	// Between segments: must be on `::`. Anchor to first segment.
	return 0z;
};

// Like segment_index_at but for a code-position path run: segments are
// already extracted, and we know they cover [run_start..run_end] tightly
// with `::` separators between.
fn segment_index_in_run(
	data: []u8,
	run_start: size,
	run_end: size,
	segments: []str,
	off: size,
) (size | void) = {
	let cursor = run_start;
	for (let i = 0z; i < len(segments); i += 1) {
		const seg_len = len(strings::toutf8(segments[i]));
		const seg_start = cursor;
		const seg_end = cursor + seg_len;
		if (off >= seg_start && off <= seg_end) return i;
		cursor = seg_end;
		// Skip the `::`.
		if (cursor < run_end && data[cursor] == ':': u8) {
			if (off == cursor || off == cursor + 1) return 0z;
			cursor += 2;
		};
	};
	return void;
};

// Returns the start/end byte offsets of the longest `ident(::ident)*` run
// that contains `off`. Returns void if `off` isn't inside such a run.
export fn path_run_at(data: []u8, off: size) ((size, size) | void) = {
	if (off > len(data)) return void;
	// Walk left.
	let s = off;
	for (s > 0) {
		const b = data[s - 1];
		if (is_ident_byte_local(b)) {
			s -= 1;
			continue;
		};
		// `::` to the left?
		if (s >= 2 && data[s - 1] == ':': u8 && data[s - 2] == ':': u8) {
			s -= 2;
			continue;
		};
		break;
	};
	// Walk right.
	let e = off;
	for (e < len(data)) {
		const b = data[e];
		if (is_ident_byte_local(b)) {
			e += 1;
			continue;
		};
		if (e + 1 < len(data) && b == ':': u8 && data[e + 1] == ':': u8) {
			e += 2;
			continue;
		};
		break;
	};
	if (s == e) return void;
	// Reject runs that are pure `::` with no ident bytes.
	if (!any_ident_byte(data[s..e])) return void;
	return (s, e);
};

fn any_ident_byte(b: []u8) bool = {
	for (let i = 0z; i < len(b); i += 1) {
		if (is_ident_byte_local(b[i])) return true;
	};
	return false;
};

// Splits the byte run at `start..end` on `::`. Returned slice strings
// borrow from `data` only conceptually; we dup so the caller can free
// them uniformly.
fn parse_path_segments(data: []u8, start: size, end: size) []str = {
	let out: []str = [];
	let i = start;
	let seg_start = i;
	for (i < end) {
		if (i + 1 < end && data[i] == ':': u8 && data[i + 1] == ':': u8) {
			if (i > seg_start) {
				append(out, strings::dup(strings::fromutf8(data[seg_start..i])!)!)!;
			};
			i += 2;
			seg_start = i;
			continue;
		};
		i += 1;
	};
	if (seg_start < end) {
		append(out, strings::dup(strings::fromutf8(data[seg_start..end])!)!)!;
	};
	return out;
};

fn strs_to_ident(s: []str) []str = {
	let out: []str = [];
	for (let i = 0z; i < len(s); i += 1) {
		append(out, strings::dup(s[i])!)!;
	};
	return out;
};

fn free_str_slice(s: []str) void = {
	for (let i = 0z; i < len(s); i += 1) {
		free(s[i]);
	};
	free(s);
};

fn is_ident_byte_local(b: u8) bool = {
	if (b >= 'a': u8 && b <= 'z': u8) return true;
	if (b >= 'A': u8 && b <= 'Z': u8) return true;
	if (b >= '0': u8 && b <= '9': u8) return true;
	return b == '_': u8;
};

// Reads the README file for the module at `dir`, returning its contents
// as a string. Returns void if no README exists or it can't be read.
// Tries `dir/README` first (Hare convention).
fn read_module_readme(dir: str) (str | void) = {
	const path = strings::concat(dir, "/README")!;
	defer free(path);
	const f = match (os::open(path)) {
	case let h: io::file =>
		yield h;
	case fs::error =>
		return void;
	};
	defer lsp::safe_close(f);
	let buf: []u8 = [];
	let chunk: [4096]u8 = [0...];
	for (true) {
		match (io::read(f, chunk[..])) {
		case let n: size =>
			append(buf, chunk[..n]...)!;
		case io::EOF =>
			break;
		case io::error =>
			free(buf);
			return void;
		};
	};
	const s = match (strings::fromutf8(buf)) {
	case let s: str =>
		yield s;
	case =>
		free(buf);
		return void;
	};
	return s;
};

// Top-level: if `off` is on a module-path token, builds and returns the
// hover markdown for that module (signature line "module foo::bar"
// followed by the README, with [[refs]] linkified). Caller frees. Returns
// void if `off` isn't on a module path or the module has no README.
export fn try_module_hover(
	s: *server,
	doc: *document,
	data: []u8,
	off: size,
) (str | void) = {
	const target = match (detect_module_hover(s, doc, data, off)) {
	case let t: module_hover_target =>
		yield t;
	case void =>
		return void;
	};
	defer finish_module_hover_target(target);
	const found = match (find_module(s, target.segments)) {
	case let pair: (str, module::srcset) =>
		yield pair;
	case void =>
		return void;
	};
	const (dir, sset) = found;
	// `dir` is borrowed from module::find's static buffer; don't free.
	let owned_set = sset;
	defer module::finish_srcset(&owned_set);
	const readme = match (read_module_readme(dir)) {
	case let s: str =>
		yield s;
	case void =>
		return void;
	};
	defer free(readme);
	const sig = strings::concat("module ", target.display)!;
	defer free(sig);
	return build_hover_markdown_raw(s, doc, sig, readme);
};
