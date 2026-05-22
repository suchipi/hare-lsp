// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Exercises the publishDiagnostics push path AND vscode-languageclient's
// consumption: the diagnostics must end up in
// vscode.languages.getDiagnostics(uri), not just on the wire. Mirrors
// e2e-nvim/spec/diagnostics_spec.lua.

import * as assert from "node:assert";
import * as vscode from "vscode";
import { openAndShow, waitFor, PROVIDER_TIMEOUT_MS } from "./helpers";

suite("diagnostics", () => {
  test("vscode.languages.getDiagnostics populates after didOpen of a broken file", async () => {
    const doc = await openAndShow("diagnostics.ha");

    let diags: vscode.Diagnostic[] = [];
    await waitFor(
      async () => {
        diags = vscode.languages.getDiagnostics(doc.uri);
        return diags.length > 0;
      },
      PROVIDER_TIMEOUT_MS,
      "no diagnostics arrived for diagnostics.ha",
    );

    const d0 = diags[0];
    assert.strictEqual(d0.severity, vscode.DiagnosticSeverity.Error,
      "expected severity=Error, got: " + d0.severity);
    assert.ok(typeof d0.message === "string" && d0.message.length > 0,
      "diagnostic message must be a non-empty string; got: " + d0.message);
    // The fixture is 4 lines (0=doc comment, 1=open brace, 2=let,
    // 3=blank). The parse error lives between the open brace and EOF.
    assert.ok(d0.range.start.line >= 1 && d0.range.start.line <= 3,
      "diagnostic line must be within the broken body (1..3), got: "
      + d0.range.start.line);
  });
});
