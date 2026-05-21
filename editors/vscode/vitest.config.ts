// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Limits vitest to the in-source unit specs and excludes the
// @vscode/test-electron e2e suite under src/test/, which is meant to
// run inside a real VSCode host (see src/test/runTest.ts).

import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["src/*.test.ts"],
    exclude: ["src/test/**", "node_modules/**", "out/**", "dist/**"],
  },
});
