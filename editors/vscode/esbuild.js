// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Bundles src/extension.ts into dist/extension.js so the published .vsix
// doesn't ship node_modules. `vsce package` warns about extensions with
// many JS files; bundling collapses everything into one file.

const esbuild = require("esbuild");

const production = process.argv.includes("--production");
const watch = process.argv.includes("--watch");

async function main() {
  const ctx = await esbuild.context({
    entryPoints: ["src/extension.ts"],
    bundle: true,
    format: "cjs",
    minify: production,
    sourcemap: true,
    // Inline source content so the shipped map is self-contained;
    // src/ is excluded from the VSIX via .vscodeignore.
    sourcesContent: true,
    platform: "node",
    // engines.vscode is ^1.82.0 (required by vscode-languageclient ^9).
    // VSCode 1.82 ships Electron 25 / Node 18; we keep targeting node16.14
    // because all language features we use are present there and a lower
    // floor lets the bundle run unchanged on older 1.82+ Electron builds.
    // Bumping the target requires bumping engines.vscode in package.json.
    target: "node16.14",
    outfile: "dist/extension.js",
    external: ["vscode"],
    logLevel: "info",
  });
  if (watch) {
    await ctx.watch();
  } else {
    await ctx.rebuild();
    await ctx.dispose();
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
