// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use encoding::json;

@test fn parse_compiler_output_single_error() void = {
	const out = "main.ha:2:35: error: Unknown object 'undefined_function'\n\n2 |\tlet x = undefined_function();\n  |                                  ^\n";
	let diags = parse_compiler_output(out, "/work");
	defer finish_build_diagnostics(diags);
	assert(len(diags) == 1);
	assert(diags[0].path == "/work/main.ha");
	assert(diags[0].line == 2);
	assert(diags[0].col == 35);
	assert(diags[0].message == "Unknown object 'undefined_function'");
};

@test fn parse_compiler_output_syntax_error() void = {
	const out = "main.ha:1:16: syntax error: expected name, '_', '...', ')', found '='\n";
	let diags = parse_compiler_output(out, "/x");
	defer finish_build_diagnostics(diags);
	assert(len(diags) == 1);
	assert(diags[0].path == "/x/main.ha");
	assert(diags[0].line == 1);
	assert(diags[0].col == 16);
};

@test fn parse_compiler_output_absolute_path_unchanged() void = {
	const out = "/abs/path/file.ha:5:10: error: oops\n";
	let diags = parse_compiler_output(out, "/work");
	defer finish_build_diagnostics(diags);
	assert(len(diags) == 1);
	assert(diags[0].path == "/abs/path/file.ha");
};

@test fn parse_compiler_output_ignores_caret_lines() void = {
	const out = "main.ha:2:35: error: Unknown thing\n\n2 |\tlet x = undefined_function();\n  |                                  ^\n";
	let diags = parse_compiler_output(out, "/work");
	defer finish_build_diagnostics(diags);
	assert(len(diags) == 1);
};

@test fn parse_compiler_output_multiple_diagnostics() void = {
	const out = "a.ha:1:1: error: first\nb.ha:2:2: syntax error: second\nc.ha:3:3: warning: third\n";
	let diags = parse_compiler_output(out, "/w");
	defer finish_build_diagnostics(diags);
	assert(len(diags) == 3);
	assert(diags[0].message == "first");
	assert(diags[1].message == "second");
	assert(diags[2].message == "third");
};

@test fn path_to_uri_and_back() void = {
	const u = path_to_uri("/abs/path.ha");
	defer free(u);
	assert(u == "file:///abs/path.ha");
	const p = uri_to_path(u);
	defer free(p);
	assert(p == "/abs/path.ha");
};

@test fn uri_to_path_decodes_percent_escapes() void = {
	// Space → %20
	const p1 = uri_to_path("file:///Users/me/My%20Project/foo.ha");
	defer free(p1);
	assert(p1 == "/Users/me/My Project/foo.ha");

	// Parens → %28 / %29
	const p2 = uri_to_path("file:///x/%28paren%29/a.ha");
	defer free(p2);
	assert(p2 == "/x/(paren)/a.ha");

	// Bytes that aren't valid hex are passed through literally — caller
	// gets an io::open failure, which is the right symptom.
	const p3 = uri_to_path("file:///x/%ZZ/a.ha");
	defer free(p3);
	assert(p3 == "/x/%ZZ/a.ha");

	// UTF-8 percent-encoded (ё = C3 ABCD-something... here just verify
	// round-trip of a 2-byte sequence: "ñ" = C3 B1).
	const p4 = uri_to_path("file:///x/%C3%B1.ha");
	defer free(p4);
	assert(p4 == "/x/ñ.ha");
};

@test fn build_diag_to_lsp_translates_range() void = {
	const d = build_diagnostic {
		path = "/x/a.ha",
		line = 5,
		col = 10,
		kind = "error",
		message = "boom",
	};
	let v = build_diag_to_lsp(d);
	defer json::finish(v);
	const o = v as json::object;
	const r = *(json::get(&o, "range") as *json::value) as json::object;
	const start = *(json::get(&r, "start") as *json::value) as json::object;
	assert(*(json::get(&start, "line") as *json::value) as f64 == 4.0);
	assert(*(json::get(&start, "character") as *json::value) as f64 == 9.0);
	const end = *(json::get(&r, "end") as *json::value) as json::object;
	assert(*(json::get(&end, "line") as *json::value) as f64 == 4.0);
	assert(*(json::get(&end, "character") as *json::value) as f64 == 10.0);
	assert(*(json::get(&o, "severity") as *json::value) as f64 == 1.0);
	assert(*(json::get(&o, "source") as *json::value) as str == "hare-lsp/build");
	assert(*(json::get(&o, "code") as *json::value) as str == "error");
	assert(*(json::get(&o, "message") as *json::value) as str == "boom");
};

@test fn build_diag_warning_severity_and_no_tag() void = {
	const d = build_diagnostic {
		path = "/x/a.ha",
		line = 1,
		col = 1,
		kind = "warning",
		message = "be careful",
	};
	let v = build_diag_to_lsp(d);
	defer json::finish(v);
	const o = v as json::object;
	assert(*(json::get(&o, "severity") as *json::value) as f64 == 2.0);
	assert(*(json::get(&o, "code") as *json::value) as str == "warning");
	// No "tags" field for a non-unused-related message.
	match (json::get(&o, "tags")) {
	case *json::value => abort("expected no tags");
	case void => void;
	};
};

@test fn build_diag_unused_message_gets_unnecessary_tag() void = {
	const d = build_diagnostic {
		path = "/x/a.ha",
		line = 1,
		col = 1,
		kind = "warning",
		message = "import is unused",
	};
	let v = build_diag_to_lsp(d);
	defer json::finish(v);
	const o = v as json::object;
	const tags = *(json::get(&o, "tags") as *json::value) as []json::value;
	assert(len(tags) == 1);
	assert(tags[0] as f64 == 1.0);
};

@test fn parse_compiler_output_records_kind() void = {
	const out = "main.ha:1:1: warning: unused import foo\n";
	let diags = parse_compiler_output(out, "/w");
	defer finish_build_diagnostics(diags);
	assert(len(diags) == 1);
	assert(diags[0].kind == "warning");
};
