// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// e2e: hover + struct-field completion around an incomplete member access
// (`media.` with no field name yet) - the exact try-hare scenario that
// surfaced the bug. Drives the real ./hare-lsp over the wire so we catch
// what the synthetic handler-level unit tests can't. `mime::lookup_ext`
// returns `const nullable *mimetype` (resolved from the real stdlib over
// the inherited HAREPATH), and `mimetype` is `struct { mime, exts }` in
// mime/database.ha (a sibling file), so this also exercises cross-file
// type resolution.

use encoding::json;
use os;
use strings;

// A function whose body contains a dangling member access. Line/character
// offsets below are 0-indexed against this exact text:
//   line 3: \tconst media = mime::lookup_ext(output);
//   line 4: \tlet _ = media.;          <- dangling dot at char 14
const INCOMPLETE_SRC =
	`use mime;

export fn check(output: str) void = {
	const media = mime::lookup_ext(output);
	let _ = media.;
};
`;

// Mid-typing: the member access sits inside a call whose `)` has not been
// typed yet. Offsets below are 0-indexed against this exact text:
//   line 4: \tconsume(media.          <- `.` at char 14, cursor at char 15
const MIDTYPE_SRC =
	`use mime;

export fn check(output: str) void = {
	const media = mime::lookup_ext(output);
	consume(media.
};
`;

// Drains workspace-indexing log lines so a following wait_for_response
// doesn't trip over them.
fn drain_indexed(s: *session) void = {
	for (let i = 0z; i < 20z; i += 1) {
		const body = recv(s);
		defer free(body);
		const text = strings::fromutf8(body)!;
		if (strings::contains(text, "indexed")
				&& strings::contains(text, "file(s)")) break;
	};
};

@test fn e2e_hover_through_dangling_member_dot() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init_with_workspace(&s, os::getcwd());

	open_doc(&s, "file:///inc_hover.ha", INCOMPLETE_SRC);
	drain_indexed(&s);

	// Hover on `media` in its declaration (line 3, char 9 - inside the name).
	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":3100,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///inc_hover.ha"},"position":{"line":3,"character":9}}}`
		));
	const body = wait_for_response(&s, 3100.0);
	defer free(body);
	let v = json::loadstr(strings::fromutf8(body)!)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = match (json::get(&obj, "result")) {
	case let p: *json::value =>
		yield match (*p) {
		case let o: json::object =>
			yield o;
		case => abort(
			"hover returned null; the dangling-dot function was not recovered"
		);
		};
	case => abort("hover response had no result");
	};
	const contents = field_object(&result, "contents");
	const value = field_string(&contents, "value");
	assert(
		strings::contains(value, "mimetype"),
		"hover on `media` must resolve to `nullable *mimetype`"
	);
};

@test fn e2e_completion_member_after_dot() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init_with_workspace(&s, os::getcwd());

	open_doc(&s, "file:///inc_comp.ha", INCOMPLETE_SRC);
	drain_indexed(&s);

	// Completion right after the `.` in `media.` (the `.` is at char 14, so
	// the cursor sits at char 15, before the `;`).
	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":3101,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///inc_comp.ha"},"position":{"line":4,"character":15}}}`
		));
	const body = wait_for_response(&s, 3101.0);
	defer free(body);
	let v = json::loadstr(strings::fromutf8(body)!)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = field_object(&obj, "result");
	const items = field_array(&result, "items");
	let saw_mime = false, saw_exts = false;
	for (let i = 0z; i < len(items); i += 1) {
		const it = items[i] as json::object;
		const label = field_string(&it, "label");
		// Member completion is exclusive: keywords/locals must not leak in.
		assert(
			label != "let" && label != "const" && label != "if",
			"member completion must not include keywords"
		);
		if (label == "mime") saw_mime = true;
		if (label == "exts") saw_exts = true;
	};
	assert(
		saw_mime && saw_exts,
		"completion after `media.` must list the mimetype fields `mime` and `exts`"
	);
};

@test fn e2e_completion_member_mid_typing_unbalanced() void = {
	let s = spawn_session();
	defer finish_session(&s);
	do_init_with_workspace(&s, os::getcwd());

	open_doc(&s, "file:///inc_mid.ha", MIDTYPE_SRC);
	drain_indexed(&s);

	// Completion right after the `.` in `consume(media.` (line 4, char 15),
	// while the call's `)` is still missing.
	send(&s,
		strings::toutf8(
			`{"jsonrpc":"2.0","id":3102,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///inc_mid.ha"},"position":{"line":4,"character":15}}}`
		));
	const body = wait_for_response(&s, 3102.0);
	defer free(body);
	let v = json::loadstr(strings::fromutf8(body)!)!;
	defer json::finish(v);
	const obj = v as json::object;
	const result = field_object(&obj, "result");
	const items = field_array(&result, "items");
	let saw_mime = false, saw_exts = false;
	for (let i = 0z; i < len(items); i += 1) {
		const it = items[i] as json::object;
		const label = field_string(&it, "label");
		if (label == "mime") saw_mime = true;
		if (label == "exts") saw_exts = true;
	};
	assert(
		saw_mime && saw_exts,
		"completion after `media.` must list fields even with the call's `)` unclosed"
	);
};
