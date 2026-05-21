// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

import * as assert from "node:assert";
import * as vscode from "vscode";
import { openAndWaitForServer, waitFor } from "./helpers";

suite("definition", () => {
  test("vscode.executeDefinitionProvider jumps cross-file", async () => {
    const doc = await openAndWaitForServer("definition/b.ha");

    // `export fn caller() int = shared_helper();` is line 1 (after
    // the doc comment on line 0). `shared_helper` starts at col 25.
    const pos = new vscode.Position(1, 25);

    // Workspace indexing of `a.ha` is asynchronous; retry until the
    // cross-file lookup resolves.
    let locations: (vscode.Location | vscode.LocationLink)[] = [];
    await waitFor(
      async () => {
        locations = (await vscode.commands.executeCommand<
          (vscode.Location | vscode.LocationLink)[]
        >("vscode.executeDefinitionProvider", doc.uri, pos)) ?? [];
        if (locations.length === 0) return false;
        const first = locations[0];
        const uri = "targetUri" in first ? first.targetUri : first.uri;
        return uri.fsPath.endsWith("a.ha");
      },
      5000,
      "definition never resolved to a.ha",
    );

    const first = locations[0];
    const uri = "targetUri" in first ? first.targetUri : first.uri;
    const range = "targetRange" in first
      ? (first.targetSelectionRange ?? first.targetRange)
      : first.range;

    assert.ok(uri.fsPath.endsWith("a.ha"),
      "expected definition in a.ha, got: " + uri.fsPath);
    assert.strictEqual(range.start.line, 1,
      "expected definition on line 1 of a.ha (after the doc comment), got line "
      + range.start.line);
  });
});
