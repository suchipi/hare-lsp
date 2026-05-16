// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use bufio;
use io;
use memio;
use strings;

fn stdlib_module_test_server(

) (server, *bufio::scanner, *memio::stream, *memio::stream) = {
	let in_buf = alloc(memio::fixed([]))!;
	let scan = alloc(bufio::newscanner(in_buf))!;
	let out = alloc(memio::dynamic())!;
	let s = new(scan, out, void);
	free(s.config.harepath);
	s.config.harepath = strings::dup("/r")!;
	return (s, scan, in_buf, out);
};

fn stdlib_module_test_cleanup(
	s: *server,
	scan: *bufio::scanner,
	in_buf: *memio::stream,
	out: *memio::stream,
) void = {
	finish(s);
	bufio::finish(scan);
	free(scan);
	free(in_buf);
	io::close(out)!;
	free(out);
};

@test fn stdlib_qualified_module_shallow_module() void = {
	let (s, scan, in_buf, out) = stdlib_module_test_server();
	defer stdlib_module_test_cleanup(&s, scan, in_buf, out);
	const got = stdlib_qualified_module(&s, "/r/bufio/scanner.ha");
	defer free(got);
	assert(got == "bufio", "single-segment stdlib module should round-trip as-is");
};

@test fn stdlib_qualified_module_nested_module() void = {
	let (s, scan, in_buf, out) = stdlib_module_test_server();
	defer stdlib_module_test_cleanup(&s, scan, in_buf, out);
	const got = stdlib_qualified_module(&s, "/r/encoding/json/loader.ha");
	defer free(got);
	assert(got == "encoding::json", "nested directories must be joined with '::'");
};

@test fn stdlib_qualified_module_peels_tag_dir() void = {
	let (s, scan, in_buf, out) = stdlib_module_test_server();
	defer stdlib_module_test_cleanup(&s, scan, in_buf, out);
	const linux_only = stdlib_qualified_module(&s, "/r/os/+linux/exec.ha");
	defer free(linux_only);
	assert(
		linux_only == "os",
		"+tag dirs belong to the parent module, not their own module"
	);
	const nested_tag = stdlib_qualified_module(&s, "/r/unix/poll/+linux/poll.ha");
	defer free(nested_tag);
	assert(
		nested_tag == "unix::poll",
		"+tag dirs nested under a multi-segment module should still peel"
	);
};

@test fn stdlib_qualified_module_strips_third_party_root() void = {
	let (s, scan, in_buf, out) = stdlib_module_test_server();
	defer stdlib_module_test_cleanup(&s, scan, in_buf, out);
	// Multi-root harepath: stdlib first, third-party second — same as
	// the default install layout. The helper must match the third-party
	// root just like it matches the stdlib root.
	free(s.config.harepath);
	s.config.harepath = strings::dup("/r/stdlib:/r/third-party")!;

	const stdlib_path = stdlib_qualified_module(&s, "/r/stdlib/bufio/scanner.ha");
	defer free(stdlib_path);
	assert(stdlib_path == "bufio");

	const tp_path = stdlib_qualified_module(&s,
		"/r/third-party/encoding/json/loader.ha");
	defer free(tp_path);
	assert(
		tp_path == "encoding::json",
		"third-party modules must be qualified the same way as stdlib"
	);
};

@test fn stdlib_qualified_module_respects_path_component_boundary() void = {
	let (s, scan, in_buf, out) = stdlib_module_test_server();
	defer stdlib_module_test_cleanup(&s, scan, in_buf, out);
	// HAREPATH with two roots that share a prefix: `/foo` is a literal
	// substring of `/foo-bar`. Naive hasprefix would pick `/foo` first
	// for paths under `/foo-bar`, leaving a leading `-bar` segment.
	free(s.config.harepath);
	s.config.harepath = strings::dup("/foo:/foo-bar")!;

	// File under /foo: qualifies normally.
	const under_foo = stdlib_qualified_module(&s, "/foo/bufio/scanner.ha");
	defer free(under_foo);
	assert(under_foo == "bufio");

	// File under /foo-bar: must NOT match /foo (no '/' boundary at
	// position 4 of the path). Must fall through to /foo-bar.
	const under_foo_bar =
		stdlib_qualified_module(&s, "/foo-bar/encoding/json/loader.ha");
	defer free(under_foo_bar);
	assert(
		under_foo_bar == "encoding::json",
		"overlapping HAREPATH roots must not silently misattribute files"
	);
};

@test fn stdlib_qualified_module_unknown_root_falls_back() void = {
	let (s, scan, in_buf, out) = stdlib_module_test_server();
	defer stdlib_module_test_cleanup(&s, scan, in_buf, out);
	// Path is not under /r — fallback should return the leaf directory.
	const got = stdlib_qualified_module(&s, "/elsewhere/foo/bar.ha");
	defer free(got);
	assert(got == "foo", "fallback returns the leaf directory module name");
};
