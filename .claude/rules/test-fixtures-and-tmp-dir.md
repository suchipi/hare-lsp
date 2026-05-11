---
paths:
  - "**/*+test.ha"
  - "e2e/**/*.ha"
---

# Test Fixtures and `.tmp/`

Split test inputs from test outputs:

- **Inputs / fixtures must live in git.** Anything a test READS — sample source files, expected-output text, golden files — must be checked in (inline in the test or under a directory like `server/testdata/`, `e2e/fixtures/`). A fixture under `.tmp/` only works if that exact state already exists, which it won't on a clean checkout or in CI.
- **Outputs can go in `.tmp/`.** It is fine for a test to write a diagnostic dump (e.g. `.tmp/reparse-fail.txt`, intermediate artifacts) for the developer to inspect after a run. `.tmp/` is gitignored but stable within a session — it won't disappear partway through a run.

## Self-contained scratch is OK

A test that writes a fixture into `.tmp/`, reads it back, and removes it within the same run is fine — that's what `.tmp/` is for.

## Don't reuse `.tmp/` paths across tests

When a test writes a scratch file or directory into `.tmp/`, the path must be unique to that test. Two tests using the same `.tmp/foo.ha` will collide if they run in parallel or interleave (one's setup deletes the other's fixture mid-run). Pick a path that names the test, e.g. `.tmp/hare-lsp-nav-crossfile.ha` for `definition_falls_back_to_workspace_index_for_cross_file`, not generic names like `.tmp/test.ha`.

## Examples

- Putting a sample-source string inline in the test or in a checked-in fixture file: yes.
- A test that writes a fixture into `.tmp/<unique-name>`, reads it back, and removes it within the same run: yes.
- A test that depends on a `.tmp/` file it did NOT itself create in this run: no.
- Writing a `.tmp/foo.txt` dump from a failing test branch so you can `cat` it after: yes — useful diagnostic.
- Asserting on the contents of a `.tmp/` file the test itself didn't just write: no.
- Two tests both writing to `.tmp/scratch.ha`: no — pick distinct names.
