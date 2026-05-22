// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Exercises rename end-to-end through vscode-languageclient AND
// vscode.workspace.applyEdit. The Hare-side e2e asserts the server
// emits the right WorkspaceEdit; this asserts the editor applies it
// to the live buffer. Mirrors e2e-nvim/spec/rename_apply_spec.lua.

import * as assert from "node:assert";
import * as vscode from "vscode";
import { openAndShow, waitFor, PROVIDER_TIMEOUT_MS } from "./helpers";

suite("rename", () => {
  test("vscode.executeDocumentRenameProvider returns a WorkspaceEdit applyable by VSCode", async () => {
    const doc = await openAndShow("rename.ha");

    // The fixture:
    //   line 0: // Función auxiliar ... más claridad.
    //   line 1: fn old_name() int = 1;
    //   line 2: <blank>
    //   line 3: export fn caller() int = old_name() + old_name();
    // `o` of `old_name` on line 1 is at 0-indexed col 3.
    const pos = new vscode.Position(1, 3);

    let edit: vscode.WorkspaceEdit | undefined;
    await waitFor(
      async () => {
        edit = await vscode.commands.executeCommand<vscode.WorkspaceEdit>(
          "vscode.executeDocumentRenameProvider",
          doc.uri,
          pos,
          "new_name",
        );
        return edit !== undefined && edit.size > 0;
      },
      PROVIDER_TIMEOUT_MS,
      "rename provider never produced a WorkspaceEdit",
    );

    const applied = await vscode.workspace.applyEdit(edit!);
    assert.ok(applied, "vscode.workspace.applyEdit returned false");

    const after = doc.getText();
    assert.match(after, /fn new_name\(\)/,
      "declaration not renamed: " + after);

    const occurrences = (after.match(/new_name/g) ?? []).length;
    assert.strictEqual(occurrences, 3,
      "expected exactly 3 occurrences of new_name (decl + 2 calls), got "
      + occurrences + " in: " + after);
    assert.ok(!after.includes("old_name"),
      "old_name should be gone after rename; got: " + after);

    // Per-byte-width round-trip: the doc-comment runes must survive
    // the splice math on both the server (computing edit ranges) and
    // the client (applying them).
    assert.ok(after.includes("Función auxiliar"),
      "rename damaged 2-byte rune (ó); got: " + after);
    assert.ok(after.includes("★"),
      "rename damaged 3-byte rune (★); got: " + after);
    assert.ok(after.includes("中文"),
      "rename damaged 3-byte CJK runes; got: " + after);
    assert.ok(after.includes("🎉"),
      "rename damaged 4-byte rune (🎉); got: " + after);
  });
});
