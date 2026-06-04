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
//
// Build diagnostics shell out to `hare build`, so this spec needs the
// hare compiler on PATH. The CI vscode-e2e job runs VSCode on the glibc
// ubuntu host, where hare is NOT installed (it lives only in the Alpine
// image used to build the LSP binary; VSCode's Linux build can't run in
// Alpine). So the spec self-skips when no hare compiler is reachable -
// it runs locally, and in CI the same server-side fix is covered by the
// pure-protocol e2e tests in the `server` job (which do run inside
// Alpine): e2e_didsave_requests_diagnostic_refresh_for_pull_clients and
// e2e_didsave_no_refresh_for_push_only_clients.

import { execFileSync } from "node:child_process";
import * as assert from "node:assert";
import * as vscode from "vscode";
import { openAndShow, sleep, waitFor, PROVIDER_TIMEOUT_MS } from "./helpers";

// True when a `hare` compiler can be invoked. The LSP server inherits
// this same PATH, so this is a faithful proxy for "the server can spawn
// `hare build`".
function hareCompilerAvailable(): boolean {
  try {
    execFileSync("hare", ["version"], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

suite("diagnostics (build)", () => {
  test("build error clears after the fix is saved", async function () {
    // A cold `hare build` of a `use fmt` module compiles fmt's whole
    // dependency tree the first time; allow generously for it (the
    // build-appears wait below plus the post-save clear wait).
    this.timeout(180000);

    if (!hareCompilerAvailable()) {
      this.skip();
    }

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
      // the client issues on open). Budget for a cold compile of fmt.
      await waitFor(
        async () =>
          vscode.languages
            .getDiagnostics(doc.uri)
            .some((d) => /ignore error/i.test(d.message)),
        90000,
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
