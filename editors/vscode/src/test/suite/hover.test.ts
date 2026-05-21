// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

import * as assert from "node:assert";
import * as vscode from "vscode";
import { fixtureUri, openAndWaitForServer } from "./helpers";

suite("hover", () => {
  test("vscode.executeHoverProvider returns signature + doc comment", async () => {
    const doc = await openAndWaitForServer("hover.ha");

    // `export fn caller() int = answer();` is on line 3 (0-indexed).
    // `answer` starts at character 25.
    const pos = new vscode.Position(3, 25);

    const hovers = await vscode.commands.executeCommand<vscode.Hover[]>(
      "vscode.executeHoverProvider",
      doc.uri,
      pos,
    );

    assert.ok(Array.isArray(hovers) && hovers.length > 0,
      "hover provider returned no hovers");
    const contents = hovers[0].contents
      .map((c) => typeof c === "string" ? c : c.value)
      .join("\n");

    assert.match(contents, /fn answer/,
      "hover should include the signature");
    assert.match(contents, /int/,
      "hover should include the return type");
    // Multi-byte runes in the doc comment must survive the
    // analysis/loc_fixup.ha rune->byte translation. Each byte width is
    // asserted independently.
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
