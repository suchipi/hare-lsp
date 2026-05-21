// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

import * as assert from "node:assert";
import * as vscode from "vscode";
import { openAndWaitForServer } from "./helpers";

type AnySymbol = vscode.DocumentSymbol | vscode.SymbolInformation;

function symbolNames(symbols: AnySymbol[]): string[] {
  const names: string[] = [];
  const walk = (xs: AnySymbol[]) => {
    for (const s of xs) {
      names.push(s.name);
      if ("children" in s && s.children) walk(s.children);
    }
  };
  walk(symbols);
  return names;
}

suite("document symbols", () => {
  test("vscode.executeDocumentSymbolProvider returns top-level decls", async () => {
    const doc = await openAndWaitForServer("symbols.ha");

    const symbols = await vscode.commands.executeCommand<AnySymbol[]>(
      "vscode.executeDocumentSymbolProvider",
      doc.uri,
    );

    assert.ok(Array.isArray(symbols),
      "expected an array of symbols, got: " + typeof symbols);

    const names = symbolNames(symbols);
    for (const want of ["alpha", "beta", "gamma"]) {
      assert.ok(names.includes(want),
        `expected \`${want}\` in document symbols, got: ` + JSON.stringify(names));
    }
  });
});
