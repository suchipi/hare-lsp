// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Node-side entry for the @vscode/test-electron suite. Downloads a
// matching VSCode build (cached under .vscode-test/), prepares a
// scratch workspace with the Hare fixtures the specs read, and spawns
// VSCode with the in-tree extension loaded.
//
// The path to ./hare-lsp is forwarded via workspace settings (rather
// than the extension's HARE_LSP_BIN convention) because the LanguageClient
// reads `hare-lsp.path` from the configuration scope tied to the
// workspace folder, which is set on the launch_args below.

import * as fs from "node:fs";
import * as path from "node:path";
import { runTests } from "@vscode/test-electron";

async function main(): Promise<void> {
  const extensionDir = path.resolve(__dirname, "..", "..");
  // .../editors/vscode → up two → repo root
  const repoRoot = path.resolve(extensionDir, "..", "..");
  const hareLspBin = process.env.HARE_LSP_BIN
    ?? path.join(repoRoot, "hare-lsp");

  if (!fs.existsSync(hareLspBin)) {
    throw new Error(
      `hare-lsp binary not found at ${hareLspBin}; build it with `
      + `\`make hare-lsp\` first.`,
    );
  }

  const workspaceDir = path.join(repoRoot, ".tmp", "e2e-vscode-workspace");
  fs.rmSync(workspaceDir, { recursive: true, force: true });
  fs.mkdirSync(workspaceDir, { recursive: true });
  writeFixtures(workspaceDir);

  // Workspace settings pin hare-lsp.path to the built binary so the
  // extension spawns the right server regardless of $PATH.
  const settingsDir = path.join(workspaceDir, ".vscode");
  fs.mkdirSync(settingsDir, { recursive: true });
  fs.writeFileSync(
    path.join(settingsDir, "settings.json"),
    JSON.stringify({
      "hare-lsp.path": hareLspBin,
      "hare.diagnostics.enableBuild": false,
    }, null, 2),
  );

  const extensionTestsPath = path.join(__dirname, "suite", "index");

  // Use a per-suite user-data-dir so we don't pollute the user's real
  // VSCode profile (and so concurrent test runs don't collide on the
  // shared lockfile).
  const userDataDir = path.join(repoRoot, ".tmp", "e2e-vscode-userdata");
  fs.rmSync(userDataDir, { recursive: true, force: true });
  fs.mkdirSync(userDataDir, { recursive: true });

  await runTests({
    extensionDevelopmentPath: extensionDir,
    extensionTestsPath,
    launchArgs: [
      workspaceDir,
      "--disable-extensions",
      "--disable-workspace-trust",
      "--user-data-dir", userDataDir,
    ],
  });
}

function writeFixtures(workspaceDir: string): void {
  // Each spec reads exactly one of these. Inlined here so the whole
  // test surface is visible in one place.
  const files: Record<string, string> = {
    "hover.ha": [
      "// Façade ★ 中文 🎉 for the deeper computation.",
      "export fn answer() int = 42;",
      "",
      "export fn caller() int = answer();",
      "",
    ].join("\n"),
    "definition/a.ha": [
      "// Devuelve un número entero.",
      "export fn shared_helper() int = 7;",
      "",
    ].join("\n"),
    "definition/b.ha": [
      "// Llama a shared_helper desde otro módulo (π puede aparecer aquí).",
      "export fn caller() int = shared_helper();",
      "",
    ].join("\n"),
    "completion.ha": [
      "// Función con parámetro de tipo estructura anónima.",
      "fn main(b: struct { x: int, y: int }) void = {",
      "\tb.",
      "};",
      "",
    ].join("\n"),
    "symbols.ha": [
      "export fn alpha() int = 1;",
      "export fn beta() int = 2;",
      "export type gamma = struct { x: int };",
      "",
    ].join("\n"),
    "inlay.ha": [
      "// Π es una constante; abajo, un entero implícito 中文 mezcla.",
      "const PI_NAME: str = \"🎉🔥 中文\"; let g_x = 1;",
      "",
    ].join("\n"),
    "diagnostics.ha": [
      "// Función rota ★ 中文 🎉 — un café antes de cerrar la llave.",
      "export fn main() void = {",
      "\tlet x = 1;",
      "",
    ].join("\n"),
    "rename.ha": [
      "// Función auxiliar ★ 中文 🎉 — renombrar para más claridad.",
      "fn old_name() int = 1;",
      "",
      "export fn caller() int = old_name() + old_name();",
      "",
    ].join("\n"),
    // In its own module dir so `hare build` sees only this file (the
    // loose root fixtures would otherwise collide as one module). Parse-
    // clean but type-broken: the println error isn't handled, so
    // `hare build` reports "Cannot ignore error here". The build-
    // diagnostics spec opens this, then fixes it with `!` to prove the
    // diagnostic clears. enableBuild is off in the shared workspace
    // settings, so that spec turns it on for itself and restores it.
    "buildfix/main.ha": [
      "use fmt;",
      "",
      "export fn main() void = {",
      "\tfmt::println(\"yeah\");",
      "};",
      "",
    ].join("\n"),
  };
  for (const [rel, contents] of Object.entries(files)) {
    const full = path.join(workspaceDir, rel);
    fs.mkdirSync(path.dirname(full), { recursive: true });
    fs.writeFileSync(full, contents, "utf-8");
  }
}

main().catch((err: unknown) => {
  console.error("test runner failed:", err);
  process.exit(1);
});
