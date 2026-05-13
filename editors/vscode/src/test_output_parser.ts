// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Pure parser/scanner helpers for hare-test output. Kept free of any
// `vscode` import so it can be exercised by plain Node tests; the
// extension layer converts the raw paths emitted here to vscode.Uri.

import * as path from "node:path";

export type TestStatus = "passed" | "failed" | "skipped";

// Hare's test runner prints one line per test as
// `<name>...<PASS|FAIL|SKIP> in <secs>.<ns>s`. When a single test binary
// holds tests from more than one module (the `hare test` no-arg flow,
// or `make test` driving `.tmp/all-tests`), the compiler emits names as
// `<module>::<name>` - sometimes nested for sub-modules like
// `cmd::hare_lsp::foo`. The bare-name path is preserved for the
// single-module flow (in-module `hare test`).
//
// The dot count is at least 3 (the longest name in a batch gets exactly
// 3); we accept 2+ defensively in case future runners tighten the
// padding.
export const TEST_RESULT_RE =
  /^(?:[A-Za-z_][A-Za-z0-9_]*::)*([A-Za-z_][A-Za-z0-9_]*)\.{2,}(PASS|FAIL|SKIP) in \d+\.\d+s\s*$/;

// CSI / OSC escape sequences. Conservative: covers `\x1b[…m`, cursor
// moves, OSC strings terminated by BEL or ST, and bare single-char
// escapes. Good enough for Hare's runner output, which only colorizes
// the status word.
export const ANSI_ESCAPE_RE =
  // eslint-disable-next-line no-control-regex
  /\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-?]*[ -/]*[@-~]|\x1b[@-Z\\-_]/g;

// In the `Failures:` section that follows the per-test lines, each
// failure with a known source location prints as
// `<testname>: <path>:<line>:<col>: <message>`. As with the result
// lines, `<testname>` may carry a `module::` prefix in multi-module
// runs. Backtrace lines (when present) start with hex addresses and
// don't match this shape.
export const TEST_FAILURE_RE =
  /^(?:[A-Za-z_][A-Za-z0-9_]*::)*([A-Za-z_][A-Za-z0-9_]*): ([^:]+):(\d+):(\d+): (.+)$/;

// Matches `@test fn name`, `@test export fn name`, `@test @other fn name`,
// and `@test\nfn name` (attributes on their own line). Whitespace and
// other attributes between `@test` and `fn` are tolerated. Captures the
// function name.
export const TEST_DECL_RE =
  /@test\b[^{}]*?\bfn\s+([A-Za-z_][A-Za-z0-9_]*)/g;

export function parseTestStatus(status: string): TestStatus | undefined {
  if (status === "PASS") return "passed";
  if (status === "FAIL") return "failed";
  if (status === "SKIP") return "skipped";
  return undefined;
}

export interface ParsedFailure {
  testName: string;
  // Absolute filesystem path of the failing assertion. The caller is
  // expected to convert this to a vscode.Uri.
  absPath: string;
  line: number;
  col: number;
  message: string;
}

export interface ParserCallbacks {
  cwd: string;
  onResult: (name: string, status: TestStatus) => void;
  onFailure: (failure: ParsedFailure) => void;
  // Strip ANSI escapes from incoming chunks before line-splitting.
  // Required for the terminal-shell-integration capture path (real
  // pty); not required for the in-extension pty (no colors).
  stripAnsi?: boolean;
}

// Stateful line-buffered parser. Returns a function that should be
// called with each chunk of child stdout/stderr; it invokes `onResult`
// for each per-test status line and `onFailure` for each failure entry
// in the trailing `Failures:` section. Chunks may split anywhere
// (including mid-line); the parser buffers until it sees a newline.
export function createTestOutputParser(
  cb: ParserCallbacks,
): (chunk: string) => void {
  let buf = "";
  return (chunk: string): void => {
    buf += cb.stripAnsi ? chunk.replace(ANSI_ESCAPE_RE, "") : chunk;
    for (;;) {
      const idx = buf.indexOf("\n");
      if (idx < 0) break;
      const line = buf.slice(0, idx).replace(/\r$/, "");
      buf = buf.slice(idx + 1);
      const r = TEST_RESULT_RE.exec(line);
      if (r) {
        const status = parseTestStatus(r[2]);
        if (status) cb.onResult(r[1], status);
        continue;
      }
      const f = TEST_FAILURE_RE.exec(line);
      if (f) {
        const rawPath = f[2];
        const absPath = path.isAbsolute(rawPath)
          ? rawPath
          : path.resolve(cb.cwd, rawPath);
        cb.onFailure({
          testName: f[1],
          absPath,
          line: Number(f[3]),
          col: Number(f[4]),
          message: f[5],
        });
      }
    }
  };
}

// Replaces line-comment bodies and double-quoted string contents with
// spaces so [[TEST_DECL_RE]] can't false-match on `// @test fn fake`
// or on `@test` appearing inside a string literal. Lengths and newline
// positions are preserved so byte offsets and line numbers stay
// consistent with the original text. Strings are terminated at a bare
// newline to bound the damage from an unclosed `"`; Hare string
// literals don't span lines anyway.
export function stripCommentsAndStrings(text: string): string {
  let out = "";
  let i = 0;
  const n = text.length;
  while (i < n) {
    const c = text[i];
    if (c === "/" && text[i + 1] === "/") {
      out += "  ";
      i += 2;
      while (i < n && text[i] !== "\n") {
        out += " ";
        i += 1;
      }
      continue;
    }
    if (c === "\"") {
      out += " ";
      i += 1;
      while (i < n && text[i] !== "\"" && text[i] !== "\n") {
        if (text[i] === "\\" && i + 1 < n && text[i + 1] !== "\n") {
          out += "  ";
          i += 2;
          continue;
        }
        out += " ";
        i += 1;
      }
      if (i < n && text[i] === "\"") {
        out += " ";
        i += 1;
      }
      continue;
    }
    out += c;
    i += 1;
  }
  return out;
}
