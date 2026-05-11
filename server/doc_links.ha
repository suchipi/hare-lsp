// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Resolves `[[name]]` and `[[mod::name]]` references inside doc comments
// into clickable markdown links for hover output. Resolution mirrors
// `workspace_lookup_aware`: local file first, then workspace by import,
// then stdlib. Unresolved refs render as plain inline code so the user
// still sees the original text.

use analysis;
use encoding::json;
use lsp;
use memio;
use strings;

// Rewrites `[[name]]` / `[[mod::name]]` occurrences in `text` into
// markdown links (when resolvable against the open `doc`'s scope) or
// inline code (when not). The result is freshly allocated.
export fn render_doc_refs(s: *server, doc: *document, text: str) str = {
	let buf = memio::dynamic();
	defer lsp::safe_close(&buf);
	let i = 0z;
	const bytes = strings::toutf8(text);
	for (i < len(bytes)) {
		const open = find_ref_open(bytes, i);
		match (open) {
		case void =>
			append_bytes(&buf, bytes[i..]);
			break;
		case let start: size =>
			append_bytes(&buf, bytes[i..start]);
			const close = find_ref_close(bytes, start + 2);
			match (close) {
			case void =>
				// Unterminated `[[`; emit verbatim and stop.
				append_bytes(&buf, bytes[start..]);
				i = len(bytes);
			case let end: size =>
				const ref = strings::fromutf8(bytes[start + 2..end])!;
				const rendered = render_one_ref(s, doc, ref);
				defer free(rendered);
				memio::concat(&buf, rendered)!;
				i = end + 2;
			};
		};
	};
	return strings::dup(memio::string(&buf)!)!;
};

fn append_bytes(buf: *memio::stream, b: []u8) void = {
	memio::concat(buf, strings::fromutf8(b)!)!;
};

// Returns the byte offset of the next `[[` at or after `from`, or void.
fn find_ref_open(bytes: []u8, from: size) (size | void) = {
	let i = from;
	for (i + 1 < len(bytes); i += 1) {
		if (bytes[i] == '[': u8 && bytes[i + 1] == '[': u8) return i;
	};
	return void;
};

// Returns the byte offset of the matching `]]` at or after `from`, or void.
fn find_ref_close(bytes: []u8, from: size) (size | void) = {
	let i = from;
	for (i + 1 < len(bytes); i += 1) {
		if (bytes[i] == ']': u8 && bytes[i + 1] == ']': u8) return i;
	};
	return void;
};

// Renders a single ref body (the text between `[[` and `]]`). On a
// resolution hit, returns a markdown link with a `command:` URI that the
// VSCode extension turns into a goto-location jump. On a miss, returns
// the ref as inline code so it stays visible.
fn render_one_ref(s: *server, doc: *document, ref: str) str = {
	const trimmed = strings::trim(ref);
	if (len(trimmed) == 0) {
		return strings::concat("[[", ref, "]]")!;
	};
	const target = resolve_ref(s, doc, trimmed);
	match (target) {
	case void =>
		return strings::concat("`", trimmed, "`")!;
	case let t: ref_target =>
		defer free_ref_target(t);
		return format_ref_link(trimmed, t);
	};
};

// A resolved doc-ref target. `uri` is a file:// URI; `line` and `character`
// are zero-based and use the server's negotiated position encoding.
type ref_target = struct {
	uri: str,
	line: u32,
	character: u32,
};

fn free_ref_target(t: ref_target) void = {
	free(t.uri);
};

// Resolves a `[[...]]` body into a target location, or void. Mirrors
// `workspace_lookup_aware` but operates on the textual ref instead of an
// in-document byte offset. Accepts bare names (`finish`) and module-
// qualified ones (`bufio::scanner`, `unix::poll::pollfd`).
fn resolve_ref(s: *server, doc: *document, ref: str) (ref_target | void) = {
	const segments = split_qualified(ref);
	defer free(segments);
	if (len(segments) == 0) return void;
	const name = segments[len(segments) - 1];

	// Bare name: try the open file first, then workspace, then stdlib.
	if (len(segments) == 1) {
		const cache = parse_of(doc);
		match (analysis::find_by_short_name(&cache.idx, name)) {
		case let p: *analysis::symbol =>
			return target_for_local(s, doc, p);
		case void => void;
		};
		const imports = collect_imported_module_names(&cache.pr.subunit);
		defer free_str_slice_nav(imports);
		match (analysis::find_in_imports(&s.workspace_index, imports, name)) {
		case let e: *analysis::workspace_entry =>
			return target_for_entry(s, e);
		case void => void;
		};
		const full_imports = collect_imported_module_paths(&cache.pr.subunit);
		defer free_str_slice_nav(full_imports);
		for (let i = 0z; i < len(full_imports); i += 1) {
			const _ = ensure_stdlib_module_indexed(s, full_imports[i]);
		};
		match (analysis::find_in_imports(&s.stdlib_index, imports, name)) {
		case let e: *analysis::workspace_entry =>
			return target_for_entry(s, e);
		case void => void;
		};
		match (analysis::find_first_by_short_name(&s.workspace_index, name)) {
		case let e: *analysis::workspace_entry =>
			return target_for_entry(s, e);
		case void => void;
		};
		match (analysis::find_first_by_short_name(&s.stdlib_index, name)) {
		case let e: *analysis::workspace_entry =>
			return target_for_entry(s, e);
		case void => return void;
		};
	};

	// Qualified: the segment immediately before `name` is the module
	// short-name we expect to find it in. For multi-segment qualifiers
	// like `unix::poll::pollfd`, the join "unix::poll" is what
	// stdlib indexing uses; the bare "poll" is what workspace
	// `find_in_module` keys on.
	const qualifier_short = segments[len(segments) - 2];
	match (analysis::find_in_module(&s.workspace_index, qualifier_short, name)) {
	case let e: *analysis::workspace_entry =>
		return target_for_entry(s, e);
	case void => void;
	};
	const full_module = if (len(segments) >= 2) {
		yield join_segments(segments[..len(segments) - 1]);
	} else {
		yield strings::dup(qualifier_short)!;
	};
	defer free(full_module);
	if (ensure_stdlib_module_indexed(s, full_module)) {
		match (analysis::find_in_module(&s.stdlib_index, qualifier_short, name)) {
		case let e: *analysis::workspace_entry =>
			return target_for_entry(s, e);
		case void => return void;
		};
	};
	return void;
};

// Splits `a::b::c` into `[a, b, c]`. Empty segments are dropped. Caller
// frees the slice (entries are borrowed from `s` via strings::split, so
// no per-element free needed).
fn split_qualified(s: str) []str = {
	const raw = strings::split(s, "::")!;
	defer free(raw);
	let out: []str = [];
	for (let i = 0z; i < len(raw); i += 1) {
		if (len(raw[i]) > 0) append(out, raw[i])!;
	};
	return out;
};

fn join_segments(segs: []str) str = strings::join("::", segs...)!;

fn target_for_local(s: *server, doc: *document, sym: *analysis::symbol) (ref_target | void) = {
	const data = analysis::bytes(&doc.buf);
	const enc = position_encoding(s);
	const pos = analysis::byte_to_position(data, doc.buf.line_index, enc,
		sym.span.start.off: size);
	return ref_target {
		uri = strings::dup(doc.uri)!,
		line = pos.line,
		character = pos.character,
	};
};

fn target_for_entry(s: *server, e: *analysis::workspace_entry) (ref_target | void) = {
	const fpe = match (cached_parse_or_drop_stale(s, e.path)) {
	case let p: *file_parse_entry => yield p;
	case null => return void;
	};
	const line_index = analysis::build_line_index(fpe.text);
	defer free(line_index);
	const enc = position_encoding(s);
	const pos = analysis::byte_to_position(fpe.text, line_index, enc,
		e.start_off: size);
	return ref_target {
		uri = strings::dup(e.uri)!,
		line = pos.line,
		character = pos.character,
	};
};

// Builds the markdown link `[label](command:hare-lsp.openLocation?<args>)`.
// `args` is a JSON array `[uri, {line, character}]` percent-encoded so it
// survives transit as part of a URI.
fn format_ref_link(label: str, t: ref_target) str = {
	let args: []json::value = [];
	let pos = json::newobject();
	json::put(&pos, "line", t.line: f64)!;
	json::put(&pos, "character", t.character: f64)!;
	// Dup the URI: json::finish frees every string it owns, but
	// `t.uri` is owned by the caller via free_ref_target.
	append(args, strings::dup(t.uri)!: json::value)!;
	append(args, pos: json::value)!;
	const v: json::value = args;
	defer json::finish(v);
	const args_json = json::dumpstr(v);
	defer free(args_json);
	const encoded = percent_encode_uri_component(args_json);
	defer free(encoded);
	return strings::concat("[", label,
		"](command:hare-lsp.openLocation?", encoded, ")")!;
};

// Percent-encodes `s` for use inside a URI's query/path component.
// Conservatively encodes everything that isn't an ASCII unreserved
// character (alphanumeric, `-`, `_`, `.`, `~`). Caller frees.
fn percent_encode_uri_component(s: str) str = {
	const bytes = strings::toutf8(s);
	let out: []u8 = [];
	for (let i = 0z; i < len(bytes); i += 1) {
		const b = bytes[i];
		if (is_unreserved(b)) {
			append(out, b)!;
			continue;
		};
		append(out, '%': u8)!;
		append(out, hex_nibble(b >> 4))!;
		append(out, hex_nibble(b & 0xF))!;
	};
	return strings::fromutf8(out)!;
};

fn is_unreserved(b: u8) bool = {
	if (b >= 'a': u8 && b <= 'z': u8) return true;
	if (b >= 'A': u8 && b <= 'Z': u8) return true;
	if (b >= '0': u8 && b <= '9': u8) return true;
	return b == '-': u8 || b == '_': u8
		|| b == '.': u8 || b == '~': u8;
};

fn hex_nibble(n: u8) u8 = {
	if (n < 10) return '0': u8 + n;
	return 'A': u8 + (n - 10);
};
