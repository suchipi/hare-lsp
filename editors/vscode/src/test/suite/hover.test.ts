// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

import * as assert from "node:assert";
import * as vscode from "vscode";
import { openAndShow, waitFor, PROVIDER_TIMEOUT_MS } from "./helpers";

suite("hover", () => {
  test("vscode.executeHoverProvider returns signature + doc comment", async () => {
    const doc = await openAndShow("hover.ha");

    // `export fn caller() int = answer();` is on line 3 (0-indexed).
    // `answer` starts at character 25.
    const pos = new vscode.Position(3, 25);

    // Poll until the LSP client is attached and the provider returns a
    // useful hover. The first call after extension activation can
    // return [] before didOpen settles.
    let hovers: vscode.Hover[] = [];
    await waitFor(
      async () => {
        hovers = (await vscode.commands.executeCommand<vscode.Hover[]>(
          "vscode.executeHoverProvider",
          doc.uri,
          pos,
        )) ?? [];
        return hovers.length > 0;
      },
      PROVIDER_TIMEOUT_MS,
      "hover provider never produced a hover for hover.ha",
    );

    const contents = hovers[0].contents
      .map((c) => typeof c === "string" ? c : c.value)
      .join("\n");

    assert.match(contents, /fn answer/,
      "hover should include the signature");
    assert.match(contents, /int/,
      "hover should include the return type");
    // Multi-byte runes in the doc comment must survive end-to-end:
    // analysis/loc_fixup.ha (rune->byte on the server) plus
    // vscode-languageclient's UTF-8 decoding on the wire. Each byte
    // width asserted independently.
    assert.ok(contents.includes("Façade"),
      "hover dropped 2-byte rune (ç); got: " + contents);
    assert.ok(contents.includes("★"),
      "hover dropped 3-byte rune (★); got: " + contents);
    assert.ok(contents.includes("中文"),
      "hover dropped 3-byte CJK runes; got: " + contents);
    assert.ok(contents.includes("🎉"),
      "hover dropped 4-byte rune (🎉); got: " + contents);
  });
});
