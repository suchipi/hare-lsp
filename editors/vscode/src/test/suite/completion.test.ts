// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

import * as assert from "node:assert";
import * as vscode from "vscode";
import { fixtureUri, waitFor } from "./helpers";

suite("completion", () => {
  test("vscode.executeCompletionItemProvider returns struct fields after `.`", async () => {
    // The completion fixture intentionally contains a parse error
    // (dangling `b.` mid-body), so the document-symbol "ready" gate
    // openAndWaitForServer uses can stall: hare-lsp may emit no
    // top-level symbols for this shape. Skip that helper and gate
    // directly on the completion request itself.
    const ext = vscode.extensions.getExtension("local.hare-lsp");
    assert.ok(ext, "extension `local.hare-lsp` not found in test host");
    if (!ext.isActive) await ext.activate();

    const doc = await vscode.workspace.openTextDocument(fixtureUri("completion.ha"));
    assert.strictEqual(doc.languageId, "hare");
    await vscode.window.showTextDocument(doc);

    // `\tb.` is on line 2; LSP position right after the `.` is char 3.
    const pos = new vscode.Position(2, 3);

    // Poll the completion provider directly. Until the LSP client is
    // attached and has processed didOpen, this returns undefined or
    // an empty list. Once ready it returns the struct fields.
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
      20000,
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
