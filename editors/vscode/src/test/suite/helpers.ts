// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

import * as path from "node:path";
import * as assert from "node:assert";
import * as vscode from "vscode";

// Workspace folder VSCode opened (set by runTest.ts's launchArgs).
export function workspaceRoot(): string {
  const folder = vscode.workspace.workspaceFolders?.[0];
  assert.ok(folder, "VSCode opened with no workspace folder");
  return folder.uri.fsPath;
}

export function fixtureUri(relpath: string): vscode.Uri {
  return vscode.Uri.file(path.join(workspaceRoot(), relpath));
}

// Opens a fixture, confirms its languageId resolves to `hare` (so the
// LSP documentSelector matches), and ensures the extension is active.
// Does NOT wait for any LSP response - each spec polls the specific
// provider it cares about with `waitFor`, because the right "ready"
// signal is provider-specific (a fixture with parse errors might emit
// no document symbols but still answer completion requests).
export async function openAndShow(
  relpath: string,
): Promise<vscode.TextDocument> {
  const ext = vscode.extensions.getExtension("local.hare-lsp");
  assert.ok(ext, "extension `local.hare-lsp` not found in test host");
  const doc = await vscode.workspace.openTextDocument(fixtureUri(relpath));
  assert.strictEqual(doc.languageId, "hare",
    "expected languageId === 'hare' so the LSP documentSelector matches; got: "
    + doc.languageId);
  await vscode.window.showTextDocument(doc);
  if (!ext.isActive) await ext.activate();
  return doc;
}

export async function waitFor(
  predicate: () => Promise<boolean>,
  timeoutMs: number,
  message: string,
): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (await predicate()) return;
    await sleep(50);
  }
  throw new Error("waitFor timed out after " + timeoutMs + "ms: " + message);
}

export function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

// Default per-provider wait budget. Cold-start CI containers can take
// a couple of seconds to spawn hare-lsp and parse the first fixture;
// 20s leaves comfortable headroom.
export const PROVIDER_TIMEOUT_MS = 20000;
