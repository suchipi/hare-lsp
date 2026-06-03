// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// e2e check: open a small Hare document and ask for hover on an
// identifier in it. The unit tests cover `handle_hover` directly with a
// synthetic document; this exercises the full sync path (didOpen →
// hover) the way VSCode does, so we catch issues that only manifest
// when the document is sent over the wire.

use encoding::json;
use fmt;
use os;
use strings;

def HOVER_DOC: str =
	`// SPDX-License-Identifier: MPL-2.0
export fn answer() int = 42;

export fn ask() int = answer();
`;

// Hover on `let scan = bufio::newscanner(...)` — no explicit type annotation,
// so the server should infer the type from the callee's return signature.
// Catches the regression where the hover used to read just "let scan", which
// is duplicate of what the user already typed.
@test fn e2e_hover_local_let_infers_call_return_type() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample =
		`use bufio;
use os;
export fn main() void = {
	let scan = bufio::newscanner(os::stdin);
	let _ = scan;
};
`;
	const did_open = build_did_open("file:///infer_call.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Hover on `scan` in `let _ = scan`. Line 4, char 9.
	const hover_req =
		`{"jsonrpc":"2.0","id":500,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///infer_call.ha"},"position":{"line":4,"character":9}}}`;
	send(&s, strings::toutf8(hover_req));

	const body = wait_for_response(&s, 500.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result_obj = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield match (*p) {
		case let o: json::object =>
			yield o;
		case =>
			fmt::fatalf("e2e: hover returned null for inferred-type local. body={}",
				text);
		};
	case void =>
		fmt::fatalf("e2e: hover response missing result: {}", text);
	};
	const contents =
		*(json::get(&result_obj, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;
	// The server should report the inferred type rather than the bare
	// `let scan` form. bufio::newscanner returns `scanner` (unqualified
	// — that's the spelling in the stdlib decl, which is what
	// hare::unparse re-emits).
	assert(
		strings::contains(md, "let scan: scanner"),
		"hover on a `let x = call()` local should render the inferred type"
	);
	// And it should NOT render the source-text fallback when inference
	// succeeded.
	assert(
		!strings::contains(md, "= bufio::newscanner"),
		"inferred type should replace the init-source fallback"
	);
};

// The reported bug: hovering the loop variable of a by-value for-each
// loop (`for (let opt .. cmd.opts)`) echoed the iterable expression
// instead of the element type. With the real stdlib on HAREPATH,
// `getopt::command.opts` is `[](rune, str)`, so `opt` is `(rune, str)`.
// This exercises the full stdlib alias-resolution path the synthetic unit
// tests can't reach.
@test fn e2e_hover_for_each_binding_infers_element_type() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample =
		`use getopt;
use os;
export fn main() void = {
	const cmd = getopt::parse(os::args);
	for (let opt .. cmd.opts) {
		let _ = opt;
	};
};
`;
	const did_open = build_did_open("file:///for_each.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Hover on `opt` in the for-header. Line 4, char 11.
	const hover_req =
		`{"jsonrpc":"2.0","id":520,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///for_each.ha"},"position":{"line":4,"character":11}}}`;
	send(&s, strings::toutf8(hover_req));

	const body = wait_for_response(&s, 520.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result_obj = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield match (*p) {
		case let o: json::object =>
			yield o;
		case =>
			fmt::fatalf("e2e: for-each hover returned null. body={}", text);
		};
	case void =>
		fmt::fatalf("e2e: for-each hover missing result: {}", text);
	};
	const contents =
		*(json::get(&result_obj, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;
	assert(
		strings::contains(md, "let opt: (rune, str)"),
		"for-each loop var should render the iterable's element type"
	);
	// Must not echo the iterable expression nor the loc.end-truncated form.
	assert(
		!strings::contains(md, "cmd.opt"),
		"for-each hover must not echo the iterable expression"
	);
};

// Hovering a tuple-index access (`opt.0`) should resolve to the indexed
// element's type. Here `opt` is `(rune, str)` (an element of
// getopt::command.opts, `[](rune, str)`), so `opt.0` is `rune`. Exercises
// the full stdlib alias-resolution path plus the tuple-member hover handler.
@test fn e2e_hover_on_tuple_member_element_type() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample =
		`use getopt;
use os;
export fn main() void = {
	const cmd = getopt::parse(os::args);
	for (let opt .. cmd.opts) {
		let _ = opt.0;
	};
};
`;
	const did_open = build_did_open("file:///tuple_member.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Hover on the `0` of `opt.0`. Line 5 (0-indexed) is "\t\tlet _ = opt.0;";
	// the `0` is at character 14 (two leading tabs count as one column each).
	const hover_req =
		`{"jsonrpc":"2.0","id":530,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///tuple_member.ha"},"position":{"line":5,"character":14}}}`;
	send(&s, strings::toutf8(hover_req));

	const body = wait_for_response(&s, 530.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result_obj = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield match (*p) {
		case let o: json::object =>
			yield o;
		case =>
			fmt::fatalf("e2e: tuple-member hover returned null. body={}", text);
		};
	case void =>
		fmt::fatalf("e2e: tuple-member hover missing result: {}", text);
	};
	const contents =
		*(json::get(&result_obj, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;
	assert(
		strings::contains(md, "(tuple field 0)"),
		"tuple-index hover should label the element"
	);
	assert(
		strings::contains(md, "rune"),
		"tuple-index hover should render the indexed element's type"
	);
};

// Go-to-definition on a tuple-index access (`opt.0`) jumps to the element's
// type node within the tuple type. Here the tuple `(rune, str)` lives in the
// stdlib getopt module (reached via `cmd.opts` -> the for-each element type),
// so the resolved Location must point into getopt's source at the `rune`
// token. Exercises cross-file tuple definition end-to-end.
@test fn e2e_definition_on_tuple_member_resolves_into_stdlib() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample =
		`use getopt;
use os;
export fn main() void = {
	const cmd = getopt::parse(os::args);
	for (let opt .. cmd.opts) {
		let _ = opt.0;
	};
};
`;
	const did_open = build_did_open("file:///tuple_member_def.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Definition on the `0` of `opt.0`. Line 5, character 14.
	const def_req =
		`{"jsonrpc":"2.0","id":540,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///tuple_member_def.ha"},"position":{"line":5,"character":14}}}`;
	send(&s, strings::toutf8(def_req));

	const body = wait_for_response(&s, 540.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield *p;
	case void =>
		fmt::fatalf("e2e: tuple definition missing result: {}", text);
	};
	const loc = match (result) {
	case let o: json::object =>
		yield o;
	case let arr: []json::value =>
		assert(len(arr) > 0, "definition should return at least one location");
		yield arr[0] as json::object;
	case =>
		fmt::fatalf("e2e: tuple definition returned null. body={}", text);
	};
	const uri_str = *(json::get(&loc, "uri") as *json::value) as str;
	assert(
		strings::contains(uri_str, "/getopt/")
		&& strings::hassuffix(uri_str, ".ha"),
		"tuple definition should resolve into the stdlib getopt module"
	);
};

// Top-level hover should render the signature only — no `= body`. The
// previous behavior dumped the full unparsed decl including the function
// body, which was useless noise for anything bigger than a one-liner.
@test fn e2e_hover_top_level_strips_body() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample =
		`export fn add(a: int, b: int) int = {
	let result = a + b;
	return result;
};
`;
	const did_open = build_did_open("file:///strip_body.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Hover on `add` in the function declaration. Line 0, char 10.
	const hover_req =
		`{"jsonrpc":"2.0","id":800,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///strip_body.ha"},"position":{"line":0,"character":10}}}`;
	send(&s, strings::toutf8(hover_req));

	const body = wait_for_response(&s, 800.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result_obj =
		*(json::get(&obj, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result_obj, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;

	assert(
		strings::contains(md, "fn add(a: int, b: int) int"),
		"hover must include the function signature"
	);
	assert(
		!strings::contains(md, "return result"),
		"hover must not include the function body"
	);
	assert(
		!strings::contains(md, "let result"),
		"hover must not include the function body"
	);
};

// Same idea for global decls: `let foo: T = init` should hover as `let foo: T`.
@test fn e2e_hover_global_strips_init() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample = `export let buffer_size: size = 12345;
`;
	const did_open = build_did_open("file:///strip_init.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Hover on `buffer_size`. Line 0, char 14.
	const hover_req =
		`{"jsonrpc":"2.0","id":810,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///strip_init.ha"},"position":{"line":0,"character":14}}}`;
	send(&s, strings::toutf8(hover_req));

	const body = wait_for_response(&s, 810.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result_obj =
		*(json::get(&obj, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result_obj, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;

	assert(
		strings::contains(md, "export let buffer_size: size"),
		"hover must render the full decl form (export, name, and type)"
	);
	assert(
		!strings::contains(md, "12345"),
		"hover must not include the initializer value"
	);
};

// Hover on a stdlib symbol that lives under a `+platform` tag directory
// (`os::stdout_file` is in os/+darwin/stdfd.ha on Darwin). The module
// indexer must fold the tag dir into the parent module, otherwise the
// lookup would search under module "+darwin" and miss.
@test fn e2e_hover_on_stdlib_tag_dir_symbol() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample =
		`use os;
export fn main() void = {
	let _ = os::stdout_file;
};
`;
	const did_open = build_did_open("file:///tag_hover.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Hover on `stdout_file` in `os::stdout_file`. Line 2, char 13.
	const hover_req =
		`{"jsonrpc":"2.0","id":600,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///tag_hover.ha"},"position":{"line":2,"character":13}}}`;
	send(&s, strings::toutf8(hover_req));

	const body = wait_for_response(&s, 600.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result_obj = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield match (*p) {
		case let o: json::object =>
			yield o;
		case =>
			fmt::fatalf("e2e: os::stdout_file hover returned null. body={}", text);
		};
	case void =>
		fmt::fatalf("e2e: response missing result: {}", text);
	};
	const contents =
		*(json::get(&result_obj, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;
	// The decl in stdlib is `export let stdout_file: io::file = rt::...;`
	// — the hover renderer strips the initializer, leaving the typed
	// binding. Match that whole form so a regression that returned just
	// `stdout_file` (the bare ident) fails.
	assert(
		strings::contains(md, "export let stdout_file: io::file"),
		"hover should render the typed decl for os::stdout_file"
	);
};

// Goto-definition on the same symbol — exercises the same module lookup
// path via handle_definition, so a fix to module_from_path benefits both.
@test fn e2e_definition_on_stdlib_tag_dir_symbol() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample =
		`use os;
export fn main() void = {
	let _ = os::stdout_file;
};
`;
	const did_open = build_did_open("file:///tag_def.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	const def_req =
		`{"jsonrpc":"2.0","id":700,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///tag_def.ha"},"position":{"line":2,"character":13}}}`;
	send(&s, strings::toutf8(def_req));

	const body = wait_for_response(&s, 700.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield *p;
	case void =>
		fmt::fatalf("e2e: definition response missing result: {}", text);
	};
	// Extract the (first) Location and verify its URI points into the
	// stdlib's os module under a platform tag dir (os/+darwin, os/+linux,
	// etc.) at stdfd.ha. Just asserting non-empty would pass even if the
	// server returned a Location pointing at the use site or a wrong file.
	const loc = match (result) {
	case let o: json::object =>
		yield o;
	case let arr: []json::value =>
		assert(len(arr) > 0, "definition should return at least one location");
		yield arr[0] as json::object;
	case =>
		fmt::fatalf("e2e: definition returned null for os::stdout_file. body={}",
			text);
	};
	const uri_str = *(json::get(&loc, "uri") as *json::value) as str;
	assert(
		strings::contains(uri_str, "/os/+")
		&& strings::hassuffix(uri_str, "/stdfd.ha"),
		"definition should resolve to os/<platform-tag>/stdfd.ha"
	);
};

// Hover on a stdlib-qualified call (`bufio::newscanner`). The server lazily
// indexes the imported module from $HAREPATH / default install paths.
@test fn e2e_hover_on_stdlib_qualified_call() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample =
		`use bufio;
export fn main() void = {
	let _ = bufio::newscanner;
};
`;
	const did_open = build_did_open("file:///stdlib_hover.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Hover on `newscanner` in `bufio::newscanner`. Line 2, char 17.
	const hover_req =
		`{"jsonrpc":"2.0","id":400,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///stdlib_hover.ha"},"position":{"line":2,"character":17}}}`;
	send(&s, strings::toutf8(hover_req));

	const body = wait_for_response(&s, 400.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield *p;
	case void =>
		fmt::fatalf("e2e: stdlib hover missing result: {}", text);
	};
	const result_obj = match (result) {
	case let o: json::object =>
		yield o;
	case =>
		fmt::fatalf(
			"e2e: stdlib hover returned null — bufio::newscanner unresolved. body={}",
			text);
	};
	const contents =
		*(json::get(&result_obj, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;
	// Stdlib indexing should yield the rendered signature, not just the
	// bare identifier. Pin the function prototype with its return type so
	// a regression to "value contains the name" fails.
	assert(
		strings::contains(md, "fn newscanner("),
		"hover should render the function signature opening"
	);
	assert(
		strings::contains(md, ") scanner"),
		"hover should render the return type after the parameter list"
	);
};

// A4: a local bound to a stdlib-qualified global (`os::args`, declared
// `[]str`) should infer that global's type rather than echoing the
// `= os::args` source. Exercises the qualified-identifier delegation in
// infer_access_expr_type against the real stdlib (lazy module indexing).
@test fn e2e_hover_binding_init_qualified_global_infers_type() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample =
		`use os;
export fn main() void = {
	let mirror = os::args;
	let _ = mirror;
};
`;
	const did_open = build_did_open("file:///qualified_global.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Hover on `mirror` in `let _ = mirror`. Line 3, char 9.
	const hover_req =
		`{"jsonrpc":"2.0","id":540,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///qualified_global.ha"},"position":{"line":3,"character":9}}}`;
	send(&s, strings::toutf8(hover_req));

	const body = wait_for_response(&s, 540.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result_obj = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield match (*p) {
		case let o: json::object =>
			yield o;
		case =>
			fmt::fatalf("e2e: qualified-global hover returned null. body={}", text);
		};
	case void =>
		fmt::fatalf("e2e: qualified-global hover missing result: {}", text);
	};
	const contents =
		*(json::get(&result_obj, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;
	assert(
		strings::contains(md, "let mirror: []str"),
		"hover on a local bound to os::args should infer `[]str`"
	);
	assert(
		!strings::contains(md, "= os::arg"),
		"inferred type should replace the qualified-init source fallback"
	);
};

// Hover on a local `let` binding inside a function body. Before this was
// supported, the handler only looked at top-level decls and returned null.
// e2e check for struct-member hover. Two things that previously failed:
//  1. Multi-rune field names like `data` — the matching used `loc.end.off`
//     directly (which is the start of the LAST RUNE, not the start of the
//     name), so ASCII single-character fields happened to work and longer
//     names didn't.
//  2. Member access nested inside the `free()` builtin — parsed as an
//     ast::free_expr, not ast::call_expr, which the AST walker silently
//     skipped over.
@test fn e2e_hover_on_struct_member_inside_free_builtin() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample =
		`type buffer = struct {
	data: []u8,
};

export fn finish(b: *buffer) void = {
	free(b.data);
};
`;
	const did_open = build_did_open("file:///sm_free_e2e.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Hover on `data` inside `free(b.data)`. Line 5 (0-indexed):
	// "\tfree(b.data);" — col 8 = 'd', col 9 = 'a', col 11 = 'a' (last rune).
	// Test col 11 specifically to lock in the last-rune behavior.
	const hover_req =
		`{"jsonrpc":"2.0","id":800,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///sm_free_e2e.ha"},"position":{"line":5,"character":11}}}`;
	send(&s, strings::toutf8(hover_req));

	const body = wait_for_response(&s, 800.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield *p;
	case void =>
		fmt::fatalf("e2e: struct-member hover missing result: {}", text);
	};
	const result_obj = match (result) {
	case let o: json::object =>
		yield o;
	case =>
		fmt::fatalf("e2e: struct-member hover returned null inside free(). body={}",
			text);
	};
	const contents =
		*(json::get(&result_obj, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;
	assert(
		strings::contains(md, "(field) data"),
		"hover inside free() should render `(field) data`"
	);
	assert(
		strings::contains(md, "[]u8"),
		"hover inside free() should render the field's type"
	);
};

@test fn e2e_hover_on_local_let_binding() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample =
		`export fn main() void = {
	let scan: int = 42;
	let _ = scan;
};
`;
	const did_open = build_did_open("file:///local_hover.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Hover on `scan` in `let _ = scan`. Line 2 (0-indexed), char 9.
	const hover_req =
		`{"jsonrpc":"2.0","id":200,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///local_hover.ha"},"position":{"line":2,"character":9}}}`;
	send(&s, strings::toutf8(hover_req));

	const body = wait_for_response(&s, 200.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield *p;
	case void =>
		fmt::fatalf("e2e: local hover response missing result: {}", text);
	};
	const result_obj = match (result) {
	case let o: json::object =>
		yield o;
	case =>
		fmt::fatalf("e2e: local hover returned null. body={}", text);
	};
	const contents =
		*(json::get(&result_obj, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;
	assert(
		strings::contains(md, "let scan"),
		"hover on local should render `let scan` binding"
	);
	assert(
		strings::contains(md, "int"),
		"hover on local should render the binding's type"
	);
};

// Hover on a function parameter — same mechanism as local bindings but the
// scope is the function's prototype, not its body.
@test fn e2e_hover_on_function_parameter() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample = `export fn echo(n: int) int = {
	return n;
};
`;
	const did_open = build_did_open("file:///param_hover.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Hover on `n` in `return n`. Line 1, char 8.
	const hover_req =
		`{"jsonrpc":"2.0","id":300,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///param_hover.ha"},"position":{"line":1,"character":8}}}`;
	send(&s, strings::toutf8(hover_req));

	const body = wait_for_response(&s, 300.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = *(json::get(&obj, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;
	assert(
		strings::contains(md, "(parameter) n: int"),
		"hover on a function parameter should render `(parameter) <name>: <type>`"
	);
};

// Reproduces the call-site hover scenario the user reported: hovering on a
// qualified workspace identifier (e.g. `server::new`). The `server` module is
// in this workspace, so the server should resolve it via the workspace
// index. The unit tests only cover unqualified top-level decls in the
// current file, so this fills a gap.
@test fn e2e_hover_on_qualified_workspace_call() void = {
	let s = spawn_session();
	defer finish_session(&s);

	// rootUri matters: workspace indexing scans this folder so qualified
	// lookups resolve.
	do_init_with_workspace(&s, os::getcwd());

	// Open a small file that mirrors the user's actual main.ha shape.
	const sample =
		`use server;
export fn main() void = {
	let _ = server::run;
};
`;
	const did_open = build_did_open("file:///probe_main.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Wait for indexing to settle — `initialized` triggers a workspace
	// scan and the server emits a log notification when done. We pull
	// a few messages so the index is populated before we ask for hover.
	drain_until_indexed(&s);

	// Hover on `run` in `server::run`. Line 2 (0-indexed), `server::run`
	// starts at column 9 ("let _ = "), so `run` starts at column 17.
	const hover_req =
		`{"jsonrpc":"2.0","id":100,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///probe_main.ha"},"position":{"line":2,"character":17}}}`;
	send(&s, strings::toutf8(hover_req));

	const body = wait_for_response(&s, 100.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield *p;
	case void =>
		fmt::fatalf("e2e: hover response has no result: {}", text);
	};
	const result_obj = match (result) {
	case let o: json::object =>
		yield o;
	case =>
		fmt::fatalf(
			"e2e: hover on `server::run` returned null — workspace-qualified hover broken. body={}",
			text);
	};
	// Just confirming the result is an object isn't enough — the bug this
	// test reproduces was about the workspace index resolving to *some*
	// symbol; assert that the rendered hover is actually `server::run`'s
	// signature (declared as `export fn run(s: *server) int` in
	// server/server.ha). A regression that returned a wrong symbol or
	// dropped the signature would still pass an object-shape check.
	const contents =
		*(json::get(&result_obj, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;
	assert(
		strings::contains(md, "fn run(s: *server) int"),
		"hover on `server::run` should render the function's signature"
	);
};

// Same-file regression: hovering on a bare reference to a function whose
// `@test fn` (named after it) lives in the open test buffer must show the
// real implementation from the sibling file, not the local test function.
@test fn e2e_hover_on_test_fn_reference_shows_real_impl() void = {
	const files: [](str, str) = [
		("mymod/impl.ha", "export fn samename(needle: str) int = 0;\n"),
		(
			"mymod/impl+test.ha",
			"@test fn samename() void = {\n\tlet _ = samename(0);\n};\n",
		),
	];
	const root = make_workspace("hover-samefile-test", files);
	defer cleanup_workspace(root);

	let s = spawn_session();
	defer finish_session(&s);
	do_init_with_workspace(&s, root);
	drain_until_indexed_ref(&s);

	const test_uri = strings::concat("file://", root, "/mymod/impl+test.ha")!;
	defer free(test_uri);
	open_doc(&s, test_uri, files[1].1);

	// Line 1: "\tlet _ = samename(0);". After the tab, `let _ = ` is 8
	// cols, so the call `samename` starts at col 9; char 11 lands inside.
	const tmpl =
		`{"jsonrpc":"2.0","id":120,"method":"textDocument/hover","params":{"textDocument":{"uri":"`;
	const req =
		strings::concat(tmpl, test_uri,
			`"},"position":{"line":1,"character":11}}}`)!;
	defer free(req);
	send(&s, strings::toutf8(req));

	const body = wait_for_response(&s, 120.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield *p;
	case void =>
		fmt::fatalf("e2e: hover response has no result: {}", text);
	};
	const result_obj = match (result) {
	case let o: json::object =>
		yield o;
	case =>
		fmt::fatalf(
			"e2e: same-file hover returned null -- workspace fallback regressed. body={}",
			text);
	};
	const contents =
		*(json::get(&result_obj, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;
	assert(
		strings::contains(md, "needle: str"),
		"hover on a test-fn reference should render the real implementation's signature"
	);
};

@test fn e2e_hover_on_identifier() void = {
	// Pinned to spawn_session_with_logs so the log-dir codepath is
	// exercised on every test run. See e2e/README.md.
	let s = spawn_session_with_logs("logs-hover");
	defer finish_session(&s);

	// Initialize. We need to be ready before opening docs.
	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	// didOpen.
	const did_open = build_did_open("file:///hover_test.ha", HOVER_DOC);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Hover on `answer` in the call `answer()` on line 3 (0-indexed),
	// which is `export fn ask() int = answer();`. The call's `answer`
	// starts at column 23.
	const hover_req =
		`{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///hover_test.ha"},"position":{"line":3,"character":24}}}`;
	send(&s, strings::toutf8(hover_req));

	const body = wait_for_response(&s, 2.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);

	const obj = v as json::object;
	const result = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield *p;
	case void =>
		fmt::fatalf("e2e: hover response has no result field: {}", text);
	};
	// LSP allows null when nothing matches. Surface that as a clear
	// failure so the developer can compare against what VSCode receives.
	const result_obj = match (result) {
	case let o: json::object =>
		yield o;
	case =>
		fmt::fatalf(
			"e2e: hover returned null/non-object — server didn't recognize the identifier. Body: {}",
			text);
	};
	const contents = match (json::get(&result_obj, "contents")) {
	case let p: *json::value =>
		yield *p;
	case void =>
		fmt::fatalf("e2e: hover result missing contents: {}", text);
	};
	const c_obj = contents as json::object;
	match (json::get(&c_obj, "value")) {
	case let p: *json::value =>
		const md = *p as str;
		assert(
			strings::contains(md, "answer"),
			"hover markdown should mention the identifier name"
		);
	case void =>
		fmt::fatalf("e2e: hover contents missing value: {}", text);
	};
};

// Ownership line: annotated function -> Layer 1 wins, source = annotation.
@test fn e2e_hover_ownership_annotation_owned() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample =
		`// Make a fresh widget.
//
// @returns: owned
export fn make_widget() *int = alloc(0);
`;
	const did_open = build_did_open("file:///own_anno.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Hover on `make_widget` (line 3, char 12 -> on 'a' of make_widget).
	const hover_req =
		`{"jsonrpc":"2.0","id":900,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///own_anno.ha"},"position":{"line":3,"character":14}}}`;
	send(&s, strings::toutf8(hover_req));

	const body = wait_for_response(&s, 900.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result_obj = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield match (*p) {
		case let o: json::object =>
			yield o;
		case =>
			fmt::fatalf("e2e: ownership-annotation hover returned null. body={}",
				text);
		};
	case void =>
		fmt::fatalf("e2e: ownership hover missing result: {}", text);
	};
	const contents =
		*(json::get(&result_obj, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;
	assert(
		strings::contains(md, "Ownership: owned (annotation)"),
		"hover should include the annotation-sourced ownership line"
	);
};

// Ownership line: local bound to alloc(...) -> Layer 3 heuristic.
@test fn e2e_hover_ownership_local_alloc_heuristic() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample =
		`export fn use_it() void = {
	let x = alloc(0);
	free(x);
};
`;
	const did_open = build_did_open("file:///own_local.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Hover on `x` in `let x = alloc(0);`. Line 1, char 5 (tab + "let " then 'x').
	const hover_req =
		`{"jsonrpc":"2.0","id":910,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///own_local.ha"},"position":{"line":1,"character":5}}}`;
	send(&s, strings::toutf8(hover_req));

	const body = wait_for_response(&s, 910.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result_obj = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield match (*p) {
		case let o: json::object =>
			yield o;
		case =>
			fmt::fatalf("e2e: ownership-local hover returned null. body={}", text);
		};
	case void =>
		fmt::fatalf("e2e: ownership-local hover missing result: {}", text);
	};
	const contents =
		*(json::get(&result_obj, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;
	assert(
		strings::contains(md, "Ownership: owned"),
		"alloc-initialized local should show owned"
	);
	assert(
		strings::contains(md, "heuristic"),
		"the source layer should be the heuristic walker"
	);
};

// The Ownership line goes BELOW the doc comment, not above it: the doc
// comment is generally more relevant than the ownership label, so it
// should read first.
@test fn e2e_hover_ownership_line_below_doc_comment() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample =
		`// Frobnicates the input thoroughly.
//
// @returns: owned
export fn frobnicate() *int = alloc(0);
`;
	const did_open = build_did_open("file:///own_order.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	const hover_req =
		`{"jsonrpc":"2.0","id":930,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///own_order.ha"},"position":{"line":3,"character":14}}}`;
	send(&s, strings::toutf8(hover_req));

	const body = wait_for_response(&s, 930.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result_obj =
		*(json::get(&obj, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result_obj, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;
	const doc_idx = strings::index(md, "Frobnicates");
	const own_idx = strings::index(md, "Ownership:");
	const di = match (doc_idx) {
	case let i: size =>
		yield i;
	case void =>
		fmt::fatalf("e2e: hover missing doc comment text: {}", text);
	};
	const oi = match (own_idx) {
	case let i: size =>
		yield i;
	case void =>
		fmt::fatalf("e2e: hover missing Ownership line: {}", text);
	};
	assert(di < oi, "doc comment must appear before the Ownership line");
};

// When the client sets `hare.hover.useHtml = false`, the Ownership line
// must NOT be wrapped in `<small>` tags. Non-HTML clients (Neovim,
// Helix, Emacs) opt into this to avoid showing literal tags.
@test fn e2e_hover_ownership_html_disabled() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	// Push the setting to the server.
	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","method":"workspace/didChangeConfiguration","params":{"settings":{"hare":{"hover":{"useHtml":false}}}}}`
		));

	const sample = `// @returns: owned
export fn make_widget() *int = alloc(0);
`;
	const did_open = build_did_open("file:///own_nohtml.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	const hover_req =
		`{"jsonrpc":"2.0","id":940,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///own_nohtml.ha"},"position":{"line":1,"character":14}}}`;
	send(&s, strings::toutf8(hover_req));

	const body = wait_for_response(&s, 940.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result_obj =
		*(json::get(&obj, "result") as *json::value) as json::object;
	const contents =
		*(json::get(&result_obj, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;
	assert(
		strings::contains(md, "Ownership: owned (annotation)"),
		"plain Ownership line still shows when HTML is disabled"
	);
	assert(
		!strings::contains(md, "<small>"),
		"hover.useHtml = false must suppress the <small> wrapper"
	);
	assert(
		!strings::contains(md, "</small>"),
		"hover.useHtml = false must suppress the </small> wrapper"
	);
};

// Ownership line: stdlib symbol via the committed Layer-2 lookup table.
// Hovering `strings::dup` should pick up the doc-comment-sourced fact.
@test fn e2e_hover_ownership_stdlib_strings_dup() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample =
		`use strings;
export fn main() void = {
	let _ = strings::dup;
};
`;
	const did_open = build_did_open("file:///own_stdlib.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Hover on `dup` in `strings::dup`. Line 2, char 18.
	const hover_req =
		`{"jsonrpc":"2.0","id":920,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///own_stdlib.ha"},"position":{"line":2,"character":18}}}`;
	send(&s, strings::toutf8(hover_req));

	const body = wait_for_response(&s, 920.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result_obj = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield match (*p) {
		case let o: json::object =>
			yield o;
		case =>
			fmt::fatalf("e2e: stdlib ownership hover returned null. body={}", text);
		};
	case void =>
		fmt::fatalf("e2e: stdlib ownership hover missing result: {}", text);
	};
	const contents =
		*(json::get(&result_obj, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;
	assert(
		strings::contains(md, "Ownership: owned"),
		"strings::dup should be flagged owned via the stdlib table"
	);
	assert(
		strings::contains(md, "doc comment"),
		"source for strings::dup should be the doc-comment table"
	);
};

// The reported bug: hovering the binding name in `case let index: size =>`
// showed the unrelated stdlib function `strings::index` instead of the
// match binding. The case body (mc.exprs) doesn't cover the header, so
// before the fix a hover on the declared name fell through to the
// workspace/stdlib lookup. With the real stdlib on HAREPATH, `index` is
// a genuine reachable function, so this proves we prefer the local
// binding. Mirrors try-hare/main.ha's extname().
@test fn e2e_hover_on_match_case_binding_prefers_local() void = {
	let s = spawn_session();
	defer finish_session(&s);

	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}`
		));
	free(wait_for_response(&s, 1.0));
	send(&s,
		strings::toutf8(`{"jsonrpc":"2.0","method":"initialized","params":{}}`));

	const sample =
		`use strings;
export fn extname(input: str) str = {
	const result = strings::index(input, ".");
	return match (result) {
	case let index: size =>
		yield strings::sub(input, index);
	case void =>
		yield "";
	};
};
`;
	const did_open = build_did_open("file:///extname.ha", sample);
	defer free(did_open);
	send(&s, strings::toutf8(did_open));

	// Hover on the binding name `index` in `case let index: size =>`.
	// Line 4, char 12 (the leading tab counts as one column).
	const hover_req =
		`{"jsonrpc":"2.0","id":930,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///extname.ha"},"position":{"line":4,"character":12}}}`;
	send(&s, strings::toutf8(hover_req));

	const body = wait_for_response(&s, 930.0);
	defer free(body);
	const text = strings::fromutf8(body)!;
	let v = json::loadstr(text)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result_obj = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield match (*p) {
		case let o: json::object =>
			yield o;
		case =>
			fmt::fatalf("e2e: match-binding hover returned null. body={}", text);
		};
	case void =>
		fmt::fatalf("e2e: match-binding hover missing result: {}", text);
	};
	const contents =
		*(json::get(&result_obj, "contents") as *json::value) as json::object;
	const md = *(json::get(&contents, "value") as *json::value) as str;
	assert(
		strings::contains(md, "(match binding) index: size"),
		"hover on the match binding name should resolve to the local binding"
	);
	// Must not fall through to the unrelated stdlib `strings::index`.
	assert(
		!strings::contains(md, "fn index"),
		"match-binding hover must not resolve to the same-named function"
	);
};
