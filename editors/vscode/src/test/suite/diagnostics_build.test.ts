// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Regression for the reported bug: a `hare build` diagnostic ("Cannot
// ignore error here") that the user fixed and saved kept showing in
// VSCode. This is a client-side rendering issue a pure-LSP harness can't
// catch: the server advertises pull diagnostics, vscode-languageclient
// pulls on didChange (against the pre-save, still-broken file on disk)
// but not on didSave, and renders its pull-diagnostic collection unioned
// with the push one. Nothing re-pulled after the save fixed the disk, so
// the stale pull entry stuck. The fix has the server request a diagnostic
// refresh after a save-triggered build; this spec proves the diagnostic
// actually clears in vscode.languages.getDiagnostics().

import * as assert from "node:assert";
import * as vscode from "vscode";
import { openAndShow, sleep, waitFor, PROVIDER_TIMEOUT_MS } from "./helpers";

suite("diagnostics (build)", () => {
  test("build error clears after the fix is saved", async function () {
    // Opens a file, runs `hare build` twice (open + post-save re-pull),
    // and includes a deliberate settle window; give it ample headroom.
    this.timeout(90000);

    // The shared workspace runs with build diagnostics off so the other
    // specs see only parse results. Turn them on for this spec, then
    // restore in `finally` so test order can't leak the setting.
    const config = vscode.workspace.getConfiguration("hare");
    await config.update(
      "diagnostics.enableBuild",
      true,
      vscode.ConfigurationTarget.Workspace,
    );
    // Let the didChangeConfiguration round-trip to the server before we
    // open the file, so the open-time pull already has build enabled.
    await sleep(1000);

    try {
      const doc = await openAndShow("buildfix/main.ha");

      // The unhandled-error build diagnostic must surface (via the pull
      // the client issues on open).
      await waitFor(
        async () =>
          vscode.languages
            .getDiagnostics(doc.uri)
            .some((d) => /ignore error/i.test(d.message)),
        PROVIDER_TIMEOUT_MS,
        "build error did not appear for buildfix/main.ha",
      );

      // Fix it in the buffer (add `!`) but do NOT save yet, then give the
      // on-change pull time to re-run against the still-broken on-disk
      // file. This pins the bug's state: the pull-diagnostic collection
      // holds a build error derived from stale disk while the buffer is
      // already correct.
      const fixed = [
        "use fmt;",
        "",
        "export fn main() void = {",
        "\tfmt::println(\"yeah\")!;",
        "};",
        "",
      ].join("\n");
      const edit = new vscode.WorkspaceEdit();
      edit.replace(
        doc.uri,
        new vscode.Range(
          doc.positionAt(0),
          doc.positionAt(doc.getText().length),
        ),
        fixed,
      );
      assert.ok(await vscode.workspace.applyEdit(edit), "applyEdit failed");
      await sleep(2000);

      // Save: the on-disk file now matches the fixed buffer. Because the
      // client doesn't re-pull on save by default, the diagnostic only
      // clears if the server asks it to re-pull - which is the fix.
      assert.ok(await doc.save(), "doc.save() failed");

      await waitFor(
        async () => vscode.languages.getDiagnostics(doc.uri).length === 0,
        PROVIDER_TIMEOUT_MS,
        "build error did not clear after fixing and saving",
      );
    } finally {
      await config.update(
        "diagnostics.enableBuild",
        false,
        vscode.ConfigurationTarget.Workspace,
      );
    }
  });
});
