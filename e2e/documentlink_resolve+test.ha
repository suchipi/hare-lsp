// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// e2e: documentLink/resolve. The unresolved link from textDocument/documentLink
// carries the import's identifier in `data`; the resolve step fills in a
// `target` URI pointing at the first .ha file of the module.

use encoding::json;
use fmt;
use os;
use strings;

@test fn e2e_documentlink_resolve_fills_in_target() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init(&s);

	const sample = `use strings;

export fn main() void = void;
`;
	open_doc(&s, "file:///dlr.ha", sample);

	// First fetch the bare links.
	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":1400,"method":"textDocument/documentLink","params":{"textDocument":{"uri":"file:///dlr.ha"}}}`
		));
	const links_body = wait_for_response(&s, 1400.0);
	defer free(links_body);
	let links_v = json::loadstr(strings::fromutf8(links_body)!)!;
	defer json::finish(links_v);
	const links_obj = links_v as json::object;
	const arr =
		*(json::get(&links_obj, "result") as *json::value) as []json::value;
	assert(len(arr) == 1, "expected one DocumentLink for `use strings;`");
	const link0 = arr[0] as json::object;

	// The bare link should NOT yet carry a target.
	assert(
		json::get(&link0, "target") is void,
		"unresolved documentLink should not have target"
	);
	// `data` carries the import ident that documentLink/resolve keys
	// off. Assert positively so a missing-data regression fails with a
	// clean message rather than a tagged-union mismatch deeper in the
	// test.
	assert(
		json::get(&link0, "data") is *json::value,
		"unresolved documentLink must carry data for the resolve step"
	);

	// Build a resolve request from the original link.
	const range_v = *(json::get(&link0, "range") as *json::value);
	const data_v = *(json::get(&link0, "data") as *json::value);
	const resolve_msg =
		strings::concat(
			`{"jsonrpc":"2.0","id":1401,"method":"documentLink/resolve","params":{"range":`,
			json::dumpstr(range_v), `,"data":`, json::dumpstr(data_v), `}}`)!;
	defer free(resolve_msg);
	send(&s, strings::toutf8(resolve_msg));

	const resolved_body = wait_for_response(&s, 1401.0);
	defer free(resolved_body);
	const rtext = strings::fromutf8(resolved_body)!;
	let rv = json::loadstr(rtext)!;
	defer json::finish(rv);
	const robj = rv as json::object;
	const result = *(json::get(&robj, "result") as *json::value) as json::object;
	const target = match (json::get(&result, "target")) {
	case let p: *json::value =>
		yield *p as str;
	case void =>
		fmt::fatalf("e2e: resolved link missing target: {}", rtext);
	};
	assert(
		strings::hasprefix(target, "file://"),
		"resolved target should be a file:// URI"
	);
	// Strip scheme to a filesystem path. The resolver always emits an
	// absolute path so we get one leading '/' after the prefix.
	const path = strings::sub(target, len("file://"), strings::end);
	assert(
		strings::hassuffix(path, ".ha"),
		"resolved target should point at a `.ha` file"
	);
	// The second-to-last path segment must be the module name. For
	// `use strings;` that segment is `strings`; a substring scan over
	// the whole path would also accept noise like `/home/strings_x/y.ha`.
	const last_slash = match (strings::rindex(path, '/')) {
	case let i: size =>
		yield i;
	case void =>
		fmt::fatalf("e2e: resolved target has no path separator: {}", target);
	};
	const parent = strings::sub(path, 0, last_slash);
	const parent_slash = match (strings::rindex(parent, '/')) {
	case let i: size =>
		yield i;
	case void =>
		fmt::fatalf("e2e: resolved target has only one path segment: {}", target);
	};
	const module_seg = strings::sub(parent, parent_slash + 1, strings::end);
	assert(
		module_seg == "strings",
		"resolved target's parent directory must be the `strings` module"
	);

	// The resolver promises the file actually exists on disk - a
	// regression that produced a stale or made-up path would break
	// Ctrl-click navigation in the editor.
	const exists = match (os::access(path, os::amode::F_OK)) {
	case let b: bool =>
		yield b;
	case =>
		yield false;
	};
	assert(exists, "resolved target must point at a real file on disk");

	// The `range` from the bare link must be preserved by resolve -
	// it positions the underline in the editor; a regression that
	// dropped or mangled it would visually break Ctrl-click.
	const range_after = *(json::get(&result, "range") as *json::value);
	const before_dump = json::dumpstr(range_v);
	defer free(before_dump);
	const after_dump = json::dumpstr(range_after);
	defer free(after_dump);
	assert(
		before_dump == after_dump,
		"resolved documentLink must preserve the original range"
	);
};
