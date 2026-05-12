// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Code actions. Provides:
//   - source.organizeImports: sort + dedupe `use` statements.
//   - quickfix: remove a single unused `use` statement (one per detected
//     unused import; only emitted when the request range overlaps the
//     import).
//   - source: remove all unused `use` statements in one batch.
//
// Unused-import detection is textual and conservative: it scans the
// document body (everything after the last `use` statement) for
// path-head identifiers, distinguishing namespace use (name followed by
// `::`) from direct use (member name standalone). A `use foo;` is
// considered unused only when `foo` never appears as the head of a `::`
// path in the body. Wildcard imports (`use foo::*;`) are never flagged
// because the introduced names are not statically knowable.

use analysis;
use encoding::json;
use hare::ast;
use lsp;
use sort;
use sort::cmp;
use strings;

export fn handle_code_action(s: *server, r: lsp::request) void = {
	const obj = match (params_obj_ca(r.params)) {
	case let o: json::object =>
		yield o;
	case void =>
		send_array_ca(s, r.id, []);
		return;
	};
	const uri = match (object_string_ca(&obj, "textDocument", "uri")) {
	case let s: str =>
		yield s;
	case void =>
		send_array_ca(s, r.id, []);
		return;
	};
	const doc = match (find_document(s, uri)) {
	case let p: *document =>
		yield p;
	case null =>
		send_array_ca(s, r.id, []);
		return;
	};

	let arr: []json::value = [];
	add_organize_imports_action(s, doc, uri, &arr);
	// Diagnostic-driven quickfixes run first: when the client echoes
	// our unused-import diagnostic back in context.diagnostics, emit
	// quickfixes keyed off it (so the LSP lightbulb appears on the
	// diagnostic). The set of import indices it covered is then passed
	// to the range-based path so we don't double up.
	let covered: []size = [];
	defer free(covered);
	add_diagnostic_quickfixes(s, doc, uri, &obj, &arr, &covered);
	add_unused_import_actions(s, doc, uri, &obj, &arr, covered);
	send_array_ca(s, r.id, arr);
};

export fn handle_code_action_resolve(s: *server, r: lsp::request) void = {
	// Action data is constructed eagerly above; resolve is a passthrough.
	const v: json::value = match (r.params) {
	case let v: json::value =>
		yield match (json::dup(v)) {
		case let copy: json::value =>
			yield copy;
		case nomem =>
			send_error(s, r.id, lsp::INTERNAL_ERROR, "out of memory");
			return;
		};
	case void =>
		yield json::_null: json::value;
	};
	defer json::finish(v);
	match (lsp::encode_response_result(s.out, r.id, v)) {
	case size => void;
	case => void;
	};
};

fn add_organize_imports_action(
	s: *server,
	doc: *document,
	uri: str,
	arr: *[]json::value,
) void = {
	const data = analysis::bytes(&doc.buf);
	const cache = parse_of(doc);
	const pr = &cache.pr;

	if (len(pr.subunit.imports) == 0) return;

	// Render each import to its `use ...;` source form, preserving the
	// bindings variant (alias / member list / wildcard). Then sort by
	// the rendered text and dedupe equal lines. Sorting by text gives
	// a stable ordering that still respects Hare conventions:
	//   use bar = foo;
	//   use foo;
	//   use foo::*;
	//   use foo::{a, b};
	let lines: []str = [];
	defer {
		for (let i = 0z; i < len(lines); i += 1) {
			free(lines[i]);
		};
		free(lines);
	};
	for (let i = 0z; i < len(pr.subunit.imports); i += 1) {
		const rendered = render_import(&pr.subunit.imports[i]);
		let dup = false;
		for (let j = 0z; j < len(lines); j += 1) {
			if (lines[j] == rendered) {
				dup = true;
				break;
			};
		};
		if (dup) {
			free(rendered);
		} else {
			append(lines, rendered)!;
		};
	};
	if (len(lines) == 0) return;
	sort::sort(lines, size(str), &cmp::strs)!;

	// Build the new import block text.
	let new_text: str = strings::dup("")!;
	defer free(new_text);
	for (let i = 0z; i < len(lines); i += 1) {
		const with_nl = strings::concat(lines[i], "\n")!;
		const next = strings::concat(new_text, with_nl)!;
		free(with_nl);
		free(new_text);
		new_text = next;
	};

	// Compute the original block range from first import start to last
	// import end + 1 (consume trailing newline if present).
	const first = pr.subunit.imports[0];
	const last = pr.subunit.imports[len(pr.subunit.imports) - 1];
	const start_off = first.loc.start.off: size;
	let end_off = last.loc.end.off: size;
	if (end_off < len(data) && data[end_off] == '\n': u8) {
		end_off += 1;
	};
	const enc = position_encoding(s);
	const sp =
		analysis::byte_to_position(data, doc.buf.line_index, enc, start_off);
	const ep = analysis::byte_to_position(data, doc.buf.line_index, enc, end_off);

	// Build the WorkspaceEdit { changes: { uri: [TextEdit] } }
	let edits: []json::value = [];
	let edit = json::newobject();
	let r_obj = json::newobject();
	let s_obj = json::newobject();
	json::put(&s_obj, "line", sp.line: f64)!;
	json::put(&s_obj, "character", sp.character: f64)!;
	let e_obj = json::newobject();
	json::put(&e_obj, "line", ep.line: f64)!;
	json::put(&e_obj, "character", ep.character: f64)!;
	json::put(&r_obj, "start", s_obj)!;
	json::put(&r_obj, "end", e_obj)!;
	json::put(&edit, "range", r_obj)!;
	json::set(&edit, "newText", new_text: json::value)!;
	append(edits, edit: json::value)!;

	let changes = json::newobject();
	json::put(&changes, uri, edits: json::value)!;
	let workspace_edit = json::newobject();
	json::put(&workspace_edit, "changes", changes)!;

	let action = json::newobject();
	json::set(&action, "title", "Organize imports": json::value)!;
	json::set(&action, "kind", "source.organizeImports": json::value)!;
	json::put(&action, "edit", workspace_edit)!;

	let cur = *arr;
	append(cur, action: json::value)!;
	*arr = cur;
};

// Renders a single import back to source form, preserving the bindings
// variant. The returned string is freshly allocated; the caller frees it.
//
//   use foo;            (void bindings)
//   use foo = bar::baz; (import_alias — Hare syntax puts the alias first)
//   use foo::{a, b};    (import_members)
//   use foo::*;         (import_wildcard)
fn render_import(imp: *ast::import) str = {
	let parts: []str = [];
	defer free(parts);
	for (let i = 0z; i < len(imp.ident); i += 1) {
		append(parts, imp.ident[i])!;
	};
	const joined = strings::join("::", parts...)!;
	defer free(joined);

	match (imp.bindings) {
	case void =>
		return strings::concat("use ", joined, ";")!;
	case let alias: ast::import_alias =>
		return strings::concat("use ", alias, " = ", joined, ";")!;
	case let members: ast::import_members =>
		// Sort member list deterministically for organize-imports.
		let members_copy: []str = [];
		defer free(members_copy);
		for (let i = 0z; i < len(members); i += 1) {
			append(members_copy, members[i])!;
		};
		sort::sort(members_copy, size(str), &cmp::strs)!;
		const inner = strings::join(", ", members_copy...)!;
		defer free(inner);
		return strings::concat("use ", joined, "::{", inner, "};")!;
	case ast::import_wildcard =>
		return strings::concat("use ", joined, "::*;")!;
	};
};

fn params_obj_ca(
	p: (json::value | void),
) (json::object | void) = lsp::params_object(p);

fn object_string_ca(o: *json::object, key1: str, key2: str) (str | void) = {
	const sub = match (lsp::json_obj(o, key1)) {
	case let oo: json::object =>
		yield oo;
	case void =>
		return void;
	};
	return lsp::json_str(&sub, key2);
};

fn send_array_ca(s: *server, id: lsp::id, arr: []json::value) void = {
	const v: json::value = arr;
	defer json::finish(v);
	match (lsp::encode_response_result(s.out, id, v)) {
	case size => void;
	case => void;
	};
};

// Per-import quickfixes for unused imports whose source range overlaps
// the request range, plus a single source action that removes them all.
// When no imports are unused, nothing is appended.
//
// `covered` is the set of import indices already emitted as quickfixes
// by [[add_diagnostic_quickfixes]]; we skip those here so the same
// import never produces two duplicate menu entries.
fn add_unused_import_actions(
	s: *server,
	doc: *document,
	uri: str,
	params: *json::object,
	arr: *[]json::value,
	covered: []size,
) void = {
	const data = analysis::bytes(&doc.buf);
	const cache = parse_of(doc);
	const pr = &cache.pr;
	if (len(pr.subunit.imports) == 0) return;

	const unused = find_unused_imports(data, &pr.subunit);
	defer free(unused);
	if (len(unused) == 0) return;

	const req_range = extract_request_range(params);
	const enc = position_encoding(s);

	let cur = *arr;
	defer {
		*arr = cur;
	};

	// Per-import quickfixes only when the request range overlaps the
	// import. Editors invoke code actions at the cursor, so this keeps
	// the menu short when the user isn't near an unused import.
	for (let i = 0z; i < len(unused); i += 1) {
		const idx = unused[i];
		if (size_in_list(covered, idx)) continue;
		const imp = &pr.subunit.imports[idx];
		const (rm_start, rm_end) = import_removal_range(data, imp);
		if (!range_overlaps_unused(
			data, doc.buf.line_index, enc, req_range, rm_start, rm_end,
		)) continue;

		const title = unused_import_title(imp);
		defer free(title);
		const edit =
			build_removal_edit(data, doc.buf.line_index, enc, rm_start, rm_end);

		let edits: []json::value = [];
		append(edits, edit)!;
		const we = build_workspace_edit(uri, edits);
		let action = json::newobject();
		json::set(&action, "title", title: json::value)!;
		json::set(&action, "kind", "quickfix": json::value)!;
		json::put(&action, "edit", we)!;
		append(cur, action: json::value)!;
	};

	// Single source action that removes every unused import at once.
	let batch_edits: []json::value = [];
	for (let i = 0z; i < len(unused); i += 1) {
		const idx = unused[i];
		const imp = &pr.subunit.imports[idx];
		const (rm_start, rm_end) = import_removal_range(data, imp);
		const edit =
			build_removal_edit(data, doc.buf.line_index, enc, rm_start, rm_end);
		append(batch_edits, edit)!;
	};
	const we_batch = build_workspace_edit(uri, batch_edits);
	let batch = json::newobject();
	json::set(&batch, "title", "Remove all unused imports": json::value)!;
	json::set(&batch, "kind", "source.removeUnused": json::value)!;
	json::put(&batch, "edit", we_batch)!;
	append(cur, batch: json::value)!;
};

// Reads context.diagnostics from the codeAction params and emits a
// quickfix for each diagnostic whose `code` is "unused-import" and
// whose `data.import_idx` references a real import. The quickfix
// echoes the originating diagnostic back in its `diagnostics` field
// so the LSP client can correlate it with the lightbulb on the
// offending line. Import indices it emits for are appended to
// `*covered` so [[add_unused_import_actions]] can skip them.
fn add_diagnostic_quickfixes(
	s: *server,
	doc: *document,
	uri: str,
	params: *json::object,
	arr: *[]json::value,
	covered: *[]size,
) void = {
	const ctx = match (json::get(params, "context")) {
	case let p: *json::value =>
		yield match (*p) {
		case let o: json::object =>
			yield o;
		case =>
			return;
		};
	case =>
		return;
	};
	const diags = match (json::get(&ctx, "diagnostics")) {
	case let p: *json::value =>
		yield match (*p) {
		case let a: []json::value =>
			yield a;
		case =>
			return;
		};
	case =>
		return;
	};
	if (len(diags) == 0) return;

	const data = analysis::bytes(&doc.buf);
	const cache = parse_of(doc);
	const pr = &cache.pr;
	if (len(pr.subunit.imports) == 0) return;
	const enc = position_encoding(s);

	let cur = *arr;
	let cov = *covered;
	defer {
		*arr = cur;
		*covered = cov;
	};

	for (let i = 0z; i < len(diags); i += 1) {
		const d_obj = match (diags[i]) {
		case let o: json::object =>
			yield o;
		case =>
			continue;
		};
		const code = match (json::get(&d_obj, "code")) {
		case let p: *json::value =>
			yield match (*p) {
			case let s: str =>
				yield s;
			case =>
				continue;
			};
		case =>
			continue;
		};
		if (code != "unused-import") continue;
		const data_obj = match (json::get(&d_obj, "data")) {
		case let p: *json::value =>
			yield match (*p) {
			case let o: json::object =>
				yield o;
			case =>
				continue;
			};
		case =>
			continue;
		};
		const idx_f = match (json::get(&data_obj, "import_idx")) {
		case let p: *json::value =>
			yield match (*p) {
			case let f: f64 =>
				yield f;
			case =>
				continue;
			};
		case =>
			continue;
		};
		if (idx_f < 0.0) continue;
		const idx = idx_f: size;
		if (idx >= len(pr.subunit.imports)) continue;
		if (size_in_list(cov, idx)) continue;

		const imp = &pr.subunit.imports[idx];
		const (rm_start, rm_end) = import_removal_range(data, imp);
		const title = unused_import_title(imp);
		defer free(title);
		const edit =
			build_removal_edit(data, doc.buf.line_index, enc, rm_start, rm_end);
		let edits: []json::value = [];
		append(edits, edit)!;
		const we = build_workspace_edit(uri, edits);

		let action = json::newobject();
		json::set(&action, "title", title: json::value)!;
		json::set(&action, "kind", "quickfix": json::value)!;
		// Echo the diagnostic so LSP clients can link the action to
		// the lightbulb.
		let diag_arr: []json::value = [];
		const d_copy = match (json::dup(diags[i])) {
		case let v: json::value =>
			yield v;
		case nomem => abort("oom in diag quickfix");
		};
		append(diag_arr, d_copy)!;
		json::put(&action, "diagnostics", diag_arr: json::value)!;
		json::put(&action, "edit", we)!;
		append(cur, action: json::value)!;
		append(cov, idx)!;
	};
};

fn size_in_list(list: []size, v: size) bool = {
	for (let i = 0z; i < len(list); i += 1) {
		if (list[i] == v) return true;
	};
	return false;
};

// Indices into pr.subunit.imports that are wholly unused.
fn find_unused_imports(data: []u8, su: *ast::subunit) []size = {
	let out: []size = [];
	if (len(su.imports) == 0) return out;

	// Scan everything past the last import statement (loc.end is the
	// position of the `;`, so add 1).
	let scan_start = su.imports[len(su.imports) - 1].loc.end.off: size + 1;
	if (scan_start > len(data)) scan_start = len(data);
	let ns_names: []str = [];
	let direct_names: []str = [];
	defer {
		strings_finish_all(ns_names);
		strings_finish_all(direct_names);
	};
	collect_body_path_heads(data, scan_start, &ns_names, &direct_names);

	for (let i = 0z; i < len(su.imports); i += 1) {
		const imp = &su.imports[i];
		match (imp.bindings) {
		case ast::import_wildcard =>
			// `use foo::*;` exposes unknown names; can't decide.
			continue;
		case void =>
			if (len(imp.ident) == 0) continue;
			const name = imp.ident[len(imp.ident) - 1];
			if (str_in_list(ns_names, name)) continue;
			append(out, i)!;
		case let a: ast::import_alias =>
			if (str_in_list(ns_names, a)) continue;
			append(out, i)!;
		case let m: ast::import_members =>
			let all_unused = true;
			for (let j = 0z; j < len(m); j += 1) {
				if (str_in_list(direct_names, m[j])) {
					all_unused = false;
					break;
				};
			};
			if (all_unused) append(out, i)!;
		};
	};
	return out;
};

// Walks `data` from `start`, recording path-head idents into either
// ns_names (when the byte right after the ident is `::`) or direct_names
// (otherwise). A path-head is an ident NOT preceded by `::`, so `foo` in
// `bar::foo` is treated as a continuation and skipped. Comments, string
// literals, char literals, and raw strings are skipped via
// analysis::token_skip_noncode.
fn collect_body_path_heads(
	data: []u8,
	start: size,
	ns_names: *[]str,
	direct_names: *[]str,
) void = {
	let ns = *ns_names;
	let dr = *direct_names;
	defer {
		*ns_names = ns;
		*direct_names = dr;
	};

	let i = start;
	const limit = len(data);
	for (i < limit) {
		const after = analysis::token_skip_noncode(data, i, limit);
		if (after > i) {
			i = after;
			continue;
		};
		const b = data[i];
		if (!analysis::is_ident_byte(b)) {
			i += 1;
			continue;
		};
		if (i > 0 && analysis::is_ident_byte(data[i - 1])) {
			// Mid-ident byte; not a token boundary.
			i += 1;
			continue;
		};
		// Locate the end of this ident.
		let e = i;
		for (e < limit && analysis::is_ident_byte(data[e]); e += 1) void;
		// Skip digit-leading (numeric literals).
		if (b >= '0': u8 && b <= '9': u8) {
			i = e;
			continue;
		};
		// Skip path continuations.
		if (i >= 2 && data[i - 1] == ':': u8 && data[i - 2] == ':': u8) {
			i = e;
			continue;
		};
		const name = strings::fromutf8(data[i..e])!;
		if (e + 1 < limit && data[e] == ':': u8 && data[e + 1] == ':': u8) {
			if (!str_in_list(ns, name)) {
				append(ns, strings::dup(name)!)!;
			};
		} else {
			if (!str_in_list(dr, name)) {
				append(dr, strings::dup(name)!)!;
			};
		};
		i = e;
	};
};

fn str_in_list(list: []str, s: str) bool = {
	for (let i = 0z; i < len(list); i += 1) {
		if (list[i] == s) return true;
	};
	return false;
};

fn strings_finish_all(list: []str) void = {
	for (let i = 0z; i < len(list); i += 1) {
		free(list[i]);
	};
	free(list);
};

// Title to show in the editor's code-action menu. The introduced name
// (last segment for void bindings, alias for aliased imports, full
// member list otherwise) is the most useful piece for users.
fn unused_import_title(imp: *ast::import) str = {
	match (imp.bindings) {
	case void =>
		if (len(imp.ident) == 0) {
			return strings::dup("Remove unused import")!;
		};
		const last = imp.ident[len(imp.ident) - 1];
		return strings::concat("Remove unused import '", last, "'")!;
	case let a: ast::import_alias =>
		return strings::concat("Remove unused import '", a, "'")!;
	case let m: ast::import_members =>
		const joined = strings::join("::", imp.ident...)!;
		defer free(joined);
		const inner = strings::join(", ", m...)!;
		defer free(inner);
		return strings::concat("Remove unused import '", joined, "::{", inner, "}'")!;
	case ast::import_wildcard =>
		return strings::dup("Remove unused import")!;
	};
};

// Returns the byte range [start, end) covering the full `use ...;\n?`
// statement for an import. The AST's `loc` covers only the ident path,
// so we walk back from loc.start over horizontal whitespace to find the
// `use` keyword, and forward from loc.end (which sits at the `;`)
// past the terminating `;` and any single trailing newline. We do not
// cross newlines walking back, so any blank line above the import is
// preserved.
fn import_removal_range(data: []u8, imp: *ast::import) (size, size) = {
	let s = imp.loc.start.off: size;
	for (s > 0; s -= 1) {
		const b = data[s - 1];
		if (b != ' ': u8 && b != '\t': u8) break;
	};
	if (s >= 3 && data[s - 3] == 'u': u8 && data[s - 2] == 's': u8 &&
	data[s - 1] == 'e': u8 &&
	(s == 3 ||
	!analysis::is_ident_byte(data[s - 4]))) {
		s -= 3;
	};
	let e = imp.loc.end.off: size + 1;
	if (e > len(data)) e = len(data);
	if (e < len(data) && data[e] == '\n': u8) {
		e += 1;
	};
	return (s, e);
};

// LSP range from the request params, or void if absent. We use this to
// decide whether to emit per-import quickfixes for a given import.
fn extract_request_range(params: *json::object) (lsp::range | void) = {
	const range_v = match (json::get(params, "range")) {
	case let p: *json::value =>
		yield *p;
	case =>
		return void;
	};
	match (lsp::decode_range(range_v)) {
	case let r: lsp::range =>
		return r;
	case lsp::bad_message =>
		return void;
	};
};

// Returns true when the request range overlaps the import's source
// range, OR when no range was given. For non-empty ranges this is the
// usual half-open overlap (a < end && start < b). For an empty range -
// which is how editors encode a bare cursor position - we treat it as
// the point at `a` and require it to fall in [imp_start, imp_end]; this
// matches user intent ("the cursor is on this line").
fn range_overlaps_unused(
	data: []u8,
	line_index: []size,
	enc: analysis::encoding,
	req: (lsp::range | void),
	imp_start: size,
	imp_end: size,
) bool = {
	const r = match (req) {
	case let r: lsp::range =>
		yield r;
	case void =>
		return true;
	};
	const a =
		analysis::position_to_byte(
			data, line_index, enc,
			analysis::position { line = r.start.line, character = r.start.character },
		);
	const b =
		analysis::position_to_byte(
			data, line_index, enc,
			analysis::position { line = r.end.line, character = r.end.character },
		);
	if (a == b) return a >= imp_start && a <= imp_end;
	return a < imp_end && imp_start < b;
};

// Builds a single TextEdit removing [start..end) by emitting an empty
// replacement at that range. Caller appends the result to a TextEdit[].
fn build_removal_edit(
	data: []u8,
	line_index: []size,
	enc: analysis::encoding,
	start: size,
	end: size,
) json::value = {
	const sp = analysis::byte_to_position(data, line_index, enc, start);
	const ep = analysis::byte_to_position(data, line_index, enc, end);
	let edit = json::newobject();
	let r_obj = json::newobject();
	let s_obj = json::newobject();
	json::put(&s_obj, "line", sp.line: f64)!;
	json::put(&s_obj, "character", sp.character: f64)!;
	let e_obj = json::newobject();
	json::put(&e_obj, "line", ep.line: f64)!;
	json::put(&e_obj, "character", ep.character: f64)!;
	json::put(&r_obj, "start", s_obj)!;
	json::put(&r_obj, "end", e_obj)!;
	json::put(&edit, "range", r_obj)!;
	json::set(&edit, "newText", "": json::value)!;
	return edit: json::value;
};

// Wraps a TextEdit[] in a WorkspaceEdit { changes: { uri: edits } }.
fn build_workspace_edit(uri: str, edits: []json::value) json::value = {
	let changes = json::newobject();
	json::put(&changes, uri, edits: json::value)!;
	let we = json::newobject();
	json::put(&we, "changes", changes)!;
	return we: json::value;
};
