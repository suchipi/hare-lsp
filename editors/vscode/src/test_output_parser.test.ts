// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

import * as path from "node:path";
import { describe, expect, it } from "vitest";

import {
  ParsedFailure,
  TEST_DECL_RE,
  TestStatus,
  createTestOutputParser,
  stripCommentsAndStrings,
} from "./test_output_parser";

interface Capture {
  results: Array<{ name: string; status: TestStatus }>;
  failures: ParsedFailure[];
}

function feed(
  chunks: string[],
  opts: { cwd?: string; stripAnsi?: boolean } = {},
): Capture {
  const cap: Capture = { results: [], failures: [] };
  const parser = createTestOutputParser({
    cwd: opts.cwd ?? "/repo",
    stripAnsi: opts.stripAnsi ?? false,
    onResult: (name, status) => cap.results.push({ name, status }),
    onFailure: (failure) => cap.failures.push(failure),
  });
  for (const c of chunks) parser(c);
  return cap;
}

describe("createTestOutputParser - single-module bare names", () => {
  // Captured from `hare test ./` inside a module directory.
  const fixture =
    "Running 1/54 tests:\n" +
    "\n" +
    "workspace_lookup_for_subunit_picks_imported_module...PASS in 0.001088000s\n" +
    "\n" +
    "1 passed; 0 failed; 1 completed in 0.001088000s\n";

  it("parses a bare PASS line", () => {
    const cap = feed([fixture]);
    expect(cap.results).toEqual([
      {
        name: "workspace_lookup_for_subunit_picks_imported_module",
        status: "passed",
      },
    ]);
    expect(cap.failures).toEqual([]);
  });
});

describe("createTestOutputParser - multi-module module::name names", () => {
  // Captured from `make test` (which runs `.tmp/all-tests`); the
  // compiler prefixes each test name with its module path. This was
  // the format the merged PR failed to recognize, leaving the gutter
  // empty on every `make test` run.
  const fixture =
    "Running 362/461 tests:\n" +
    "\n" +
    "analysis::build_line_index_basic..................................................PASS in 0.000023000s\n" +
    "analysis::workspace_lookup_for_subunit_picks_imported_module......................PASS in 0.000136000s\n" +
    "cmd::hare_lsp::parse_harepath_empty...............................................PASS in 0.000035000s\n" +
    "cmd::harefmt::walk_visits_ha_files................................................PASS in 0.001007000s\n" +
    "server::completion_includes_keywords..............................................PASS in 0.003112000s\n";

  it("strips the module:: prefix and captures the bare test name", () => {
    const cap = feed([fixture]);
    expect(cap.results.map((r) => r.name)).toEqual([
      "build_line_index_basic",
      "workspace_lookup_for_subunit_picks_imported_module",
      "parse_harepath_empty",
      "walk_visits_ha_files",
      "completion_includes_keywords",
    ]);
    expect(cap.results.every((r) => r.status === "passed")).toBe(true);
  });

  it("handles nested module paths (cmd::hare_lsp::name)", () => {
    const cap = feed([
      "cmd::hare_lsp::path_is_absolute_cases.............................................PASS in 0.000007000s\n",
    ]);
    expect(cap.results).toEqual([
      { name: "path_is_absolute_cases", status: "passed" },
    ]);
  });
});

describe("createTestOutputParser - PASS / FAIL / SKIP recognition", () => {
  // Captured from a real failing test injected under .tmp/.
  const failFixture =
    "Running 2/2 tests:\n" +
    "\n" +
    "scratch_intentional_failure_for_fixture_capture...FAIL in 0.000089000s\n" +
    "scratch_intentional_pass_for_fixture_capture......PASS in 0.000005000s\n" +
    "\n" +
    "Failures:\n" +
    "scratch_intentional_failure_for_fixture_capture: .tmp/scratch/test_fail+test.ha:2:15: intentional failure for fixture capture\n" +
    "\n" +
    "1 passed; 1 failed; 2 completed in 0.000094000s\n";

  it("captures PASS and FAIL results and the failure-section entry", () => {
    const cap = feed([failFixture], { cwd: "/repo" });
    expect(cap.results).toEqual([
      {
        name: "scratch_intentional_failure_for_fixture_capture",
        status: "failed",
      },
      {
        name: "scratch_intentional_pass_for_fixture_capture",
        status: "passed",
      },
    ]);
    expect(cap.failures).toHaveLength(1);
    const f = cap.failures[0];
    expect(f.testName).toBe(
      "scratch_intentional_failure_for_fixture_capture",
    );
    expect(f.absPath).toBe(
      path.resolve("/repo", ".tmp/scratch/test_fail+test.ha"),
    );
    expect(f.line).toBe(2);
    expect(f.col).toBe(15);
    expect(f.message).toBe("intentional failure for fixture capture");
  });

  it("captures a SKIP result", () => {
    const cap = feed([
      "some_test_that_is_skipped.....SKIP in 0.000001000s\n",
    ]);
    expect(cap.results).toEqual([
      { name: "some_test_that_is_skipped", status: "skipped" },
    ]);
  });

  it("preserves an absolute failure path", () => {
    const cap = feed(
      [
        "mod::failing: /abs/path/file.ha:42:7: boom\n",
      ],
      { cwd: "/repo" },
    );
    expect(cap.failures).toEqual([
      {
        testName: "failing",
        absPath: "/abs/path/file.ha",
        line: 42,
        col: 7,
        message: "boom",
      },
    ]);
  });
});

describe("createTestOutputParser - chunk boundaries", () => {
  it("buffers across mid-line chunk splits", () => {
    const cap = feed([
      "analysis::build_li",
      "ne_index_basic..........",
      "...PASS in 0.000023000s\nanalysis::next_test......",
      "PASS in 0.000010000s\n",
    ]);
    expect(cap.results).toEqual([
      { name: "build_line_index_basic", status: "passed" },
      { name: "next_test", status: "passed" },
    ]);
  });

  it("handles CRLF line endings", () => {
    const cap = feed(["mod::t......PASS in 0.000005000s\r\n"]);
    expect(cap.results).toEqual([{ name: "t", status: "passed" }]);
  });

  it("does not emit until a newline arrives", () => {
    const cap = feed(["mod::t......PASS in 0.000005000s"]);
    expect(cap.results).toEqual([]);
  });
});

describe("createTestOutputParser - ANSI handling", () => {
  // The shell-integration path captures from a real terminal; the
  // runner colorizes the status word. The parser must strip those
  // escapes before applying the result regex.
  it("strips ANSI escapes when stripAnsi is enabled", () => {
    const ansi =
      "analysis::build_line_index_basic.......\x1b[32mPASS\x1b[0m in 0.000023000s\n";
    const cap = feed([ansi], { stripAnsi: true });
    expect(cap.results).toEqual([
      { name: "build_line_index_basic", status: "passed" },
    ]);
  });

  it("strips OSC 633 shell-integration sequences", () => {
    // VSCode's shell integration injects OSC 633 (BEL-terminated)
    // sequences around each command. They must not break parsing
    // when they end up in the middle of a chunk.
    const osc = "\x1b]633;C\x07";
    const cap = feed(
      [
        osc + "mod::t......PASS in 0.000005000s\n" + osc,
      ],
      { stripAnsi: true },
    );
    expect(cap.results).toEqual([{ name: "t", status: "passed" }]);
  });

  it("keeps ANSI in lines when stripAnsi is disabled (no false match)", () => {
    const ansi =
      "mod::t......\x1b[32mPASS\x1b[0m in 0.000005000s\n";
    const cap = feed([ansi], { stripAnsi: false });
    expect(cap.results).toEqual([]);
  });
});

describe("createTestOutputParser - non-matching lines", () => {
  it("ignores prelude, summary, and backtrace lines", () => {
    const cap = feed([
      "Running 1/1 tests:\n",
      "\n",
      "mod::t......PASS in 0.000005000s\n",
      "\n",
      "1 passed; 0 failed; 1 completed in 0.000005000s\n",
      "0x0000aaaaf12345 some backtrace line\n",
      "  at fn foo (/path/to/foo.ha:3:1)\n",
    ]);
    expect(cap.results).toEqual([{ name: "t", status: "passed" }]);
    expect(cap.failures).toEqual([]);
  });
});

describe("stripCommentsAndStrings", () => {
  it("masks line comments without changing length", () => {
    const src = "// @test fn fake_one\n@test fn real_one() void = {};\n";
    const out = stripCommentsAndStrings(src);
    expect(out).toHaveLength(src.length);
    // The real decl is preserved.
    expect(out).toContain("@test fn real_one");
    // The commented-out decl's @test marker is wiped out.
    expect(out.slice(0, src.indexOf("\n"))).toBe(" ".repeat(20));
  });

  it("masks double-quoted string contents but preserves newlines", () => {
    const src = 'let s = "@test fn fake";\n@test fn real() void = {};\n';
    const out = stripCommentsAndStrings(src);
    expect(out).toHaveLength(src.length);
    expect(out).toContain("@test fn real");
    // The fake decl inside the string is wiped.
    expect(out.slice(0, src.indexOf("\n"))).not.toContain("@test");
  });

  it("prevents TEST_DECL_RE from matching commented or stringified decls", () => {
    const src =
      "// @test fn commented_out\n" +
      'let s = "@test fn in_string";\n' +
      "@test fn real_test() void = {};\n";
    const cleaned = stripCommentsAndStrings(src);
    TEST_DECL_RE.lastIndex = 0;
    const matches: string[] = [];
    let m: RegExpExecArray | null;
    while ((m = TEST_DECL_RE.exec(cleaned)) !== null) {
      matches.push(m[1]);
    }
    expect(matches).toEqual(["real_test"]);
  });
});
