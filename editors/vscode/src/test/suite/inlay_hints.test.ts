// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

import * as assert from "node:assert";
import * as vscode from "vscode";
import { openAndWaitForServer } from "./helpers";

suite("inlay hints", () => {
  test("vscode.executeInlayHintProvider returns an `int` type hint", async () => {
    const doc = await openAndWaitForServer("inlay.ha");

    // The fixture is a single top-level `let g_x = 1;`. Request hints
    // over the whole file.
    const range = new vscode.Range(
      new vscode.Position(0, 0),
      new vscode.Position(2, 0),
    );

    const hints = await vscode.commands.executeCommand<vscode.InlayHint[]>(
      "vscode.executeInlayHintProvider",
      doc.uri,
      range,
    );

    assert.ok(Array.isArray(hints) && hints.length > 0,
      "expected at least one inlay hint; got: " + JSON.stringify(hints));

    const labels = hints.map((h) => typeof h.label === "string"
      ? h.label
      : h.label.map((p) => p.value).join(""));

    assert.ok(labels.some((l) => l.includes("int")),
      "expected an inferred-type hint containing `int`; got labels: "
      + JSON.stringify(labels));
  });
});
