// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

import * as assert from "node:assert";
import * as vscode from "vscode";
import { openAndShow, waitFor, PROVIDER_TIMEOUT_MS } from "./helpers";

type AnySymbol = vscode.DocumentSymbol | vscode.SymbolInformation;

function flatten(symbols: AnySymbol[]): AnySymbol[] {
  const out: AnySymbol[] = [];
  const walk = (xs: AnySymbol[]) => {
    for (const s of xs) {
      out.push(s);
      if ("children" in s && s.children) walk(s.children);
    }
  };
  walk(symbols);
  return out;
}

suite("document symbols", () => {
  test("vscode.executeDocumentSymbolProvider returns top-level decls with correct kinds", async () => {
    const doc = await openAndShow("symbols.ha");

    let flat: AnySymbol[] = [];
    await waitFor(
      async () => {
        const symbols = (await vscode.commands.executeCommand<AnySymbol[]>(
          "vscode.executeDocumentSymbolProvider",
          doc.uri,
        )) ?? [];
        flat = flatten(symbols);
        return flat.some((s) => s.name === "alpha");
      },
      PROVIDER_TIMEOUT_MS,
      "document symbols never populated for symbols.ha",
    );

    const byName = new Map<string, AnySymbol>();
    for (const s of flat) byName.set(s.name, s);

    for (const want of ["alpha", "beta", "gamma"]) {
      assert.ok(byName.has(want),
        `expected \`${want}\` in document symbols, got: `
        + JSON.stringify(Array.from(byName.keys())));
    }

    // `fn alpha`, `fn beta` -> Function; `type gamma = struct {...}` ->
    // Struct (Hare types are reported as Struct when the alias is for
    // a struct literal). Catches a regression that would otherwise
    // render everything as the generic `Variable` icon.
    assert.strictEqual(byName.get("alpha")!.kind, vscode.SymbolKind.Function,
      "expected `alpha` kind=Function, got: " + byName.get("alpha")!.kind);
    assert.strictEqual(byName.get("beta")!.kind, vscode.SymbolKind.Function,
      "expected `beta` kind=Function, got: " + byName.get("beta")!.kind);
    assert.strictEqual(byName.get("gamma")!.kind, vscode.SymbolKind.Struct,
      "expected `gamma` kind=Struct, got: " + byName.get("gamma")!.kind);
  });
});
