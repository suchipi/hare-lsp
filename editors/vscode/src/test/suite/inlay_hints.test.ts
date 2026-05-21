// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// vscode-languageclient hardcodes `positionEncodings: ['utf-16']`
// (see vscode-languageclient/lib/common/client.js: generalCapabilities
// .positionEncodings = ['utf-16']), so positions in responses arrive
// from hare-lsp as UTF-16 code-unit offsets. The fixture has
// 4-byte UTF-8 runes (🎉/🔥, each a surrogate pair = 2 UTF-16 code
// units) and 3-byte UTF-8 runes (中/文) on the same line as `let g_x`,
// which stresses the server's byte<->UTF-16 column math.
//
// The corresponding nvim spec at e2e-nvim/spec/inlay_hint_spec.lua
// covers the analogous assertion under UTF-8 negotiation.

import * as assert from "node:assert";
import * as vscode from "vscode";
import { openAndShow, waitFor, PROVIDER_TIMEOUT_MS } from "./helpers";

suite("inlay hints", () => {
  test("vscode.executeInlayHintProvider anchors at UTF-16-correct char offset", async () => {
    const doc = await openAndShow("inlay.ha");

    // The fixture spans 3 lines (0 = doc comment, 1 = multi-decl line
    // with `let g_x`, 2 = blank). Request hints over the whole file.
    const range = new vscode.Range(
      new vscode.Position(0, 0),
      new vscode.Position(3, 0),
    );

    let hints: vscode.InlayHint[] = [];
    await waitFor(
      async () => {
        hints = (await vscode.commands.executeCommand<vscode.InlayHint[]>(
          "vscode.executeInlayHintProvider",
          doc.uri,
          range,
        )) ?? [];
        return hints.length > 0;
      },
      PROVIDER_TIMEOUT_MS,
      "inlay hint provider never produced hints for inlay.ha",
    );

    const intHint = hints.find((h) => {
      const label = typeof h.label === "string"
        ? h.label
        : h.label.map((p) => p.value).join("");
      return label.includes("int");
    });
    assert.ok(intHint,
      "expected an inferred-type hint containing `int`; got: "
      + JSON.stringify(hints));

    // Counting UTF-16 code units from the start of line 1
    // (`const PI_NAME: str = "🎉🔥 中文"; let g_x = 1;`):
    //   "const PI_NAME: str = \""        → 22
    //   "🎉" (surrogate pair, +2)        → 24
    //   "🔥" (surrogate pair, +2)        → 26
    //   " 中文" (1 + 1 + 1)               → 29
    //   "\"; let g_x" (10)              → 39
    // The hint anchors at character 39 of line 1. A server that
    // mis-counts surrogate pairs as 1 code unit would emit 37; one
    // that returns bytes would emit 47.
    assert.strictEqual(intHint.position.line, 1,
      "expected hint anchor on line 1 (the multi-decl line), got line "
      + intHint.position.line);
    assert.strictEqual(intHint.position.character, 39,
      "expected hint anchor at UTF-16 character 39 (after `g_x`), got "
      + intHint.position.character);
  });
});
