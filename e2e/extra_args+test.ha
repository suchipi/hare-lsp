// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// e2e: configurable extra args + tags forwarding. Verifies that:
//
//   1. `hare.extraArgs.build` lands in the argv of every `hare build`
//      the server spawns from the didSave dep-build pass.
//   2. `hare.tags` is forwarded to `hare test` invoked via the
//      `hare-lsp.runTest` codelens command (the run_hare_command path
//      that used to drop tags entirely).
//
// Implementation: point `hare.path` at a shell shim that appends its
// argv to a per-test records file, then drive both flows and parse
// the records.

use fmt;
use fs;
use io;
use os;
use strings;

@test fn e2e_extra_args_build_and_tags_forwarded() void = {
	const cwd = os::getcwd();
	const root = strings::concat(cwd, "/.tmp/e2e-extra-args")!;
	defer free(root);
	cleanup_workspace(root);
	defer cleanup_workspace(root);

	match (os::mkdirs(root, 0o755: fs::mode)) {
	case void => void;
	case let e: fs::error =>
		fmt::fatalf("e2e: cannot mkdir {}: {}", root, fs::strerror(e));
	};

	// Records and shim live OUTSIDE the workspace root so the dep
	// walker doesn't try to parse `hare-shim.sh` (it scans the root
	// for `*.ha`) and so that cleanup_workspace does not wipe them
	// between assertion and inspection if debugging a failure.
	const records_path = strings::concat(cwd, "/.tmp/e2e-extra-args-records.txt")!;
	defer free(records_path);
	const shim_path = strings::concat(cwd, "/.tmp/e2e-extra-args-shim.sh")!;
	defer free(shim_path);
	// Wipe stale records from prior runs.
	match (os::remove(records_path)) {
	case (void | fs::error) => void;
	};

	// Each invocation prepends `--- invocation ---` and then one line
	// per argv element. The shim exits 0 with empty stderr so the LSP
	// sees a clean build (no diagnostics to parse).
	const shim_body =
		strings::concat("#!/bin/sh\n", "{\n", "  echo '--- invocation ---'\n",
			"  for arg in \"$@\"; do echo \"$arg\"; done\n", "} >> '", records_path,
			"'\n", "exit 0\n")!;
	defer free(shim_body);
	write_test_file(shim_path, shim_body);
	match (os::chmod(shim_path, 0o755: fs::mode)) {
	case void => void;
	case let e: fs::error =>
		fmt::fatalf("e2e: cannot chmod {}: {}", shim_path, fs::strerror(e));
	};

	// Single-file workspace, no `use` declarations - the dep walker
	// emits exactly one `hare build` for this module's directory.
	const main_path = strings::concat(root, "/main.ha")!;
	defer free(main_path);
	const main_body = "export fn main() void = void;\n";
	write_test_file(main_path, main_body);

	let s = spawn_session();
	defer finish_session(&s);
	do_init_with_workspace(&s, root);

	// Point hare.path at the shim and configure both tags and
	// extraArgs.build. The server's outbound workspace/configuration
	// pull request goes unanswered; that's fine, didChangeConfiguration
	// updates the config directly.
	const cfg_msg =
		strings::concat(
			`{"jsonrpc":"2.0","method":"workspace/didChangeConfiguration","params":{"settings":{"hare":{"path":"`,
			shim_path,
			`","tags":["+linux"],"extraArgs":{"build":["-lc","-D","FOO=1"]}}}}}`)!;
	defer free(cfg_msg);
	send(&s, strings::toutf8(cfg_msg));

	drain_until_indexed_ref(&s);

	const main_uri = strings::concat("file://", main_path)!;
	defer free(main_uri);
	open_doc(&s, main_uri, main_body);
	free(wait_for_publish_diagnostics(&s, main_uri));

	// (1) Trigger the build pass.
	const save_msg =
		strings::concat(
			`{"jsonrpc":"2.0","method":"textDocument/didSave","params":{"textDocument":{"uri":"`,
			main_uri, `"}}}`)!;
	defer free(save_msg);
	send(&s, strings::toutf8(save_msg));
	free(wait_for_publish_diagnostics(&s, main_uri));

	// (2) Trigger the test command. `hare-lsp.runTest` takes [uri] and
	// dispatches to run_hare_command(s, "test", cwd, [module_dir]).
	const test_msg =
		strings::concat(
			`{"jsonrpc":"2.0","id":900,"method":"workspace/executeCommand","params":{"command":"hare-lsp.runTest","arguments":["`,
			main_uri, `"]}}`)!;
	defer free(test_msg);
	send(&s, strings::toutf8(test_msg));
	free(wait_for_response(&s, 900.0));

	const records = read_records_text(records_path);
	defer free(records);
	const invocations = parse_invocations(records);
	defer free_invocations(invocations);

	let saw_build = false;
	let saw_test = false;
	for (let i = 0z; i < len(invocations); i += 1) {
		const argv = invocations[i];
		if (len(argv) == 0) continue;
		if (argv[0] == "build") {
			saw_build = true;
			assert(contains_pair(argv, "-t", "o"), "build argv must include `-t o`");
			assert(
				contains_pair(argv, "-o", "/dev/null"),
				"build argv must include `-o /dev/null`"
			);
			assert(
				contains_pair(argv, "-T", "+linux"),
				"build argv must forward the configured tag"
			);
			assert(
				contains_str(argv, "-lc"),
				"build argv must include extraArgs.build[-lc]"
			);
			assert(
				contains_pair(argv, "-D", "FOO=1"),
				"build argv must include extraArgs.build[-D FOO=1]"
			);
			assert(
				argv[len(argv) - 1] == root,
				"build argv must end with the module directory"
			);
		} else if (argv[0] == "test") {
			saw_test = true;
			assert(
				contains_pair(argv, "-T", "+linux"),
				"test argv must forward the configured tag (regression: run_hare_command used to drop tags entirely)"
			);
			assert(
				argv[len(argv) - 1] == root,
				"test argv must end with the module directory"
			);
		};
	};
	assert(saw_build, "expected to record at least one `hare build` invocation");
	assert(saw_test, "expected to record at least one `hare test` invocation");
};

fn read_records_text(path: str) str = {
	const f = match (os::open(path)) {
	case let f: io::file =>
		yield f;
	case let e: fs::error =>
		fmt::fatalf("e2e: cannot open records {}: {}", path, fs::strerror(e));
	};
	defer io::close(f)!;
	const buf = match (io::drain(f)) {
	case let b: []u8 =>
		yield b;
	case let e: io::error =>
		fmt::fatalf("e2e: cannot read records {}: {}", path, io::strerror(e));
	};
	defer free(buf);
	return strings::dup(strings::fromutf8(buf)!)!;
};

// Splits the records text into a list of invocations, each represented
// as the list of argv strings the shim recorded for that call. Both
// outer and inner slices, plus the inner strings, are owned by the
// caller (free via free_invocations).
//
// `strings::tokenize` / `strings::split` treat their delim as a charset,
// so we use `strings::cut` (literal multi-byte delim) to slice between
// invocation markers. Per-line splitting then uses tokenize on a single
// byte (newline), which is the charset case it does handle.
fn parse_invocations(text: str) [][]str = {
	let out: [][]str = [];
	let rest = text;
	// Drop the prefix before the first marker, if any.
	if (strings::contains(rest, "--- invocation ---\n")) {
		const (_, after) = strings::cut(rest, "--- invocation ---\n");
		rest = after;
	};
	for (true) {
		const has_more = strings::contains(rest, "--- invocation ---\n");
		const (block, next_rest) = strings::cut(rest, "--- invocation ---\n");
		let lines: []str = [];
		let line_iter = strings::tokenize(block, "\n");
		for (let line => strings::next_token(&line_iter)) {
			if (len(line) == 0) continue;
			append(lines, strings::dup(line)!)!;
		};
		if (len(lines) > 0) {
			append(out, lines)!;
		} else {
			free(lines);
		};
		if (!has_more) break;
		rest = next_rest;
	};
	return out;
};

fn free_invocations(invs: [][]str) void = {
	for (let i = 0z; i < len(invs); i += 1) {
		for (let j = 0z; j < len(invs[i]); j += 1) {
			free(invs[i][j]);
		};
		free(invs[i]);
	};
	free(invs);
};

fn contains_str(slice: []str, needle: str) bool = {
	for (let i = 0z; i < len(slice); i += 1) {
		if (slice[i] == needle) return true;
	};
	return false;
};

fn contains_pair(slice: []str, a: str, b: str) bool = {
	for (let i = 0z; i + 1 < len(slice); i += 1) {
		if (slice[i] == a && slice[i + 1] == b) return true;
	};
	return false;
};
