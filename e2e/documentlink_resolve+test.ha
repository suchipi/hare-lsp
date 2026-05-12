// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// e2e: documentLink/resolve. The unresolved link from textDocument/documentLink
// carries the import's identifier in `data`; the resolve step fills in a
// `target` URI pointing at the first .ha file of the module.

use encoding::json;
use fmt;
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
	send(
		&s,
		strings::toutf8(

			`{"jsonrpc":"2.0","id":1400,"method":"textDocument/documentLink","params":{"textDocument":{"uri":"file:///dlr.ha"}}}`,
		),
	);
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

	// Build a resolve request from the original link.
	const range_v = *(json::get(&link0, "range") as *json::value);
	const data_v = *(json::get(&link0, "data") as *json::value);
	const resolve_msg =
		strings::concat(

			`{"jsonrpc":"2.0","id":1401,"method":"documentLink/resolve","params":{"range":`,
			json::dumpstr(range_v), `,"data":`, json::dumpstr(data_v), `}}`,
		)!;
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
		strings::contains(target, "strings"),
		"resolved target should reference the strings module"
	);
	assert(
		strings::hasprefix(target, "file://"),
		"resolved target should be a file:// URI"
	);
};
