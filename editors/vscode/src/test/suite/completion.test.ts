// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

import * as assert from "node:assert";
import * as vscode from "vscode";
import { openAndShow, waitFor, PROVIDER_TIMEOUT_MS } from "./helpers";

suite("completion", () => {
  test("vscode.executeCompletionItemProvider returns struct fields after `.`", async () => {
    const doc = await openAndShow("completion.ha");

    // `\tb.` is on line 2; LSP position right after the `.` is char 3.
    const pos = new vscode.Position(2, 3);

    let list: vscode.CompletionList | undefined;
    await waitFor(
      async () => {
        list = await vscode.commands.executeCommand<vscode.CompletionList>(
          "vscode.executeCompletionItemProvider",
          doc.uri,
          pos,
          ".",
        );
        return list !== undefined && list.items.length > 0;
      },
      PROVIDER_TIMEOUT_MS,
      "completion provider never returned items for completion.ha",
    );

    const byLabel = new Map<string, vscode.CompletionItem>();
    for (const item of list!.items) {
      const label = typeof item.label === "string" ? item.label : item.label.label;
      byLabel.set(label, item);
    }

    assert.ok(byLabel.has("x") && byLabel.has("y"),
      "expected struct fields `x` and `y` in completion items, got labels: "
      + JSON.stringify(Array.from(byLabel.keys())));

    // Struct-field completions must carry CompletionItemKind.Field.
    for (const name of ["x", "y"]) {
      assert.strictEqual(byLabel.get(name)!.kind, vscode.CompletionItemKind.Field,
        `expected kind=Field for \`${name}\`, got kind=`
        + byLabel.get(name)!.kind);
    }
  });
});
