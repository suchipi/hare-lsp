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

// Opens a document and waits for the language client to attach to it.
// `executeXProvider` commands only return useful results once the
// extension has been activated and the client is ready; otherwise the
// command resolves with `undefined` / `null`.
export async function openAndWaitForServer(
  relpath: string,
): Promise<vscode.TextDocument> {
  const ext = vscode.extensions.getExtension("local.hare-lsp");
  assert.ok(ext, "extension `local.hare-lsp` not found in test host");

  const doc = await vscode.workspace.openTextDocument(fixtureUri(relpath));
  assert.strictEqual(doc.languageId, "hare",
    "expected document languageId === 'hare' (so the LSP documentSelector "
    + "matches); got: " + doc.languageId);
  await vscode.window.showTextDocument(doc);

  if (!ext.isActive) {
    await ext.activate();
  }
  // Even after activate() resolves, the LanguageClient has to send
  // didOpen and the server has to parse the document before
  // executeDocumentSymbolProvider returns a meaningful array. We
  // accept any defined result here - empty `[]` still proves a
  // provider is registered (and some fixtures intentionally contain
  // parse errors, so a non-empty array isn't a usable signal). The
  // individual tests below retry their own provider calls so a
  // brief race after didOpen settles itself.
  await waitFor(
    async () => {
      const symbols = await vscode.commands.executeCommand<
        vscode.DocumentSymbol[] | vscode.SymbolInformation[] | undefined
      >("vscode.executeDocumentSymbolProvider", doc.uri);
      return symbols !== undefined;
    },
    20000,
    "no document symbol provider responded for " + relpath,
  );
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
