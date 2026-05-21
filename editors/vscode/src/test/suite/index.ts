// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Mocha runner loaded by VSCode via runTest.ts's `extensionTestsPath`.
// VSCode imports this module from inside the host process, calls
// `run()`, and waits for the promise to settle.

import * as path from "node:path";
import { glob } from "glob";
import Mocha from "mocha";

export async function run(): Promise<void> {
  const mocha = new Mocha({
    ui: "tdd",
    color: true,
    // The first didOpen + indexing wait per spec can take a couple of
    // seconds on a cold checkout; keep the default per-test timeout
    // generous so CI isn't flaky.
    timeout: 30000,
  });

  const testsRoot = __dirname;
  const files = await glob("**/*.test.js", { cwd: testsRoot });
  for (const file of files) {
    mocha.addFile(path.join(testsRoot, file));
  }

  await new Promise<void>((resolve, reject) => {
    try {
      mocha.run((failures) => {
        if (failures > 0) {
          reject(new Error(`${failures} test(s) failed`));
        } else {
          resolve();
        }
      });
    } catch (err) {
      reject(err);
    }
  });
}
