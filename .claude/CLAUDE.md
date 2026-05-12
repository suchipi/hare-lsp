# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Language Server Protocol (LSP 3.17) implementation for the [Hare programming language](https://harelang.org/), written in Hare itself. Targets Hare v0.26.0. The binary is `hare-lsp` and is intended to be spawned by editor clients over stdio.

## Build, test, run

The project is driven entirely by the [Makefile](Makefile). It pins `HAREPATH` to `$(PWD):$(THIRDPARTY):/usr/local/src/hare/stdlib` so that `use lsp;`, `use server;`, etc. resolve to the in-tree modules.

- `make` — builds `./hare-lsp` (checks for `hare-json` at `/usr/local/src/hare/third-party/encoding/json/` first).
- `make test` — builds the binary, then runs unit tests AND the e2e suite. The e2e tests spawn the actual `./hare-lsp` binary over OS pipes; they require the binary to exist, which is why `test` depends on `hare-lsp`.
- `make clean` — removes `./hare-lsp`, `.cache/`, and the VSCode extension build artifacts.
- `make vscode-install` — builds and installs the in-tree VSCode extension at [editors/vscode/](editors/vscode/).

There is no separate lint step; rely on `hare build` errors and `make test`.

### Running a single test

`hare test` accepts a name filter. Tests live alongside source as `*_test+test.ha` (unit) or under [e2e/](e2e/) (e2e). Example:

```sh
HAREPATH="$PWD:/usr/local/src/hare/third-party:/usr/local/src/hare/stdlib" \
  HARECACHE="$PWD/.cache" \
  hare test definition_falls_back_to_workspace_index_for_cross_file
```

For an e2e test, add `e2e` after the test name selector (the e2e suite is its own module).

### Debugging the wire protocol

Set `HARE_LSP_LOG_DIR=/abs/path` in the server's environment to tee every byte read/written/logged to `hare-lsp-{in,out,err}.log` in that directory. The path must be absolute because vscode-languageclient spawns the server with `cwd=/`. See [cmd/hare-lsp/main.ha](cmd/hare-lsp/main.ha) for the wiring.

## Architecture

Five top-level modules form a clean stack. Each is on `HAREPATH` and is imported by name (`use lsp;`, `use analysis;`, etc.).

### `cmd/hare-lsp/` — entry point

[cmd/hare-lsp/main.ha](cmd/hare-lsp/main.ha) wires `os::stdin`/`os::stdout_file` to a `server::server` and runs the loop. Critically, it uses the **unbuffered** stdout handle: vscode-languageclient holds stdin open across requests, so the process never exits to flush a buffered stdout, and responses would sit in the 4 KiB buffer indefinitely. The e2e suite guards against re-introducing that bug.

### `lsp/` — transport + JSON-RPC framing

- [lsp/transport.ha](lsp/transport.ha): reads/writes LSP framed messages (`Content-Length:` header + body). 32 MiB body cap by default.
- [lsp/jsonrpc.ha](lsp/jsonrpc.ha): decodes incoming bodies into `request | notification | response`, encodes outgoing.
- [lsp/codec.ha](lsp/codec.ha): JSON helpers used across the codebase.
- [lsp/types.ha](lsp/types.ha): LSP error codes, ids, trace levels.

This module knows nothing about Hare or features — purely protocol plumbing.

### `analysis/` — Hare-aware analysis

Parser, buffer, indices, type queries. None of this depends on `lsp` or `server`; in principle this module is reusable from anything that needs lightweight Hare analysis.

- [analysis/parser.ha](analysis/parser.ha): a **recovering** parser. The stdlib `hare::parse` stops at the first error; this one keeps going so the LSP can publish multiple diagnostics per file. Resync points: `EXPORT`, `STATIC`, `LET`, `CONST`, `DEF`, `TYPE`, `FN`, `USE`, `ATTR_*`, EOF.
- [analysis/buffer.ha](analysis/buffer.ha): document storage as `[]u8` + a line index rebuilt per edit. Simple by design; can be swapped for a rope later.
- [analysis/index.ha](analysis/index.ha): per-file symbol table built from a subunit. Each `symbol` carries the decl span, name span, doc comment, and (for functions) parameter names.
- [analysis/workspace_index.ha](analysis/workspace_index.ha): flat name → entries table across all `*.ha` under each workspace root.
- [analysis/positions.ha](analysis/positions.ha): translation between LSP positions (UTF-8 / UTF-16 / UTF-32) and byte offsets. The encoding is negotiated at `initialize`.
- [analysis/resolver.ha](analysis/resolver.ha), [analysis/types.ha](analysis/types.ha), [analysis/type_walk.ha](analysis/type_walk.ha): name resolution and best-effort type-of-expression for hover, inlay hints, and type hierarchy.
- [analysis/scope_graph.ha](analysis/scope_graph.ha): lexical scope graph for a parsed file. Lets references/rename bound their search to a binding's scope when the cursor resolves to a local.
- [analysis/token_scan.ha](analysis/token_scan.ha): byte scanner that skips comments, strings, char literals, and raw strings. Used by references/rename's text scan, signature-help comma counting, and the formatter's brace-depth tracker.
- [analysis/loc_fixup.ha](analysis/loc_fixup.ha): the Hare AST reports `loc.off` as a rune index; the LSP needs byte offsets. This module fixes those up.

### `server/` — feature handlers

Owns the `server` struct (state, open documents, indices, pending requests, etc.) and dispatches incoming messages to per-feature files. [server/server.ha](server/server.ha) is the dispatch table: see `handle_request` and `handle_notification` for the full method list. Each LSP feature lives in its own file (`completion.ha`, `hover.ha`, `formatting.ha`, …) with a matching `*_test+test.ha`.

Key flow: `run` loops on `lsp::read` → `lsp::decode` → `dispatch` → `flush_pending_diagnostics`. Diagnostics are debounced (`hare.diagnostics.debounceMs`) and flushed after every message — rapid `didChange` traffic naturally coalesces and a trailing edit publishes once any later message arrives.

Lifecycle is gated in `handle_request`: `PRE_INIT` accepts only `initialize`; `SHUTTING_DOWN`/`EXITED` reject everything except `exit`.

### `hare/parse/` — vendored stdlib overlay

A byte-for-byte copy of `hare::parse` from the Hare stdlib with one fix in `want`: the upstream version aborts the whole process when called with multiple alternatives on a non-matching token ("attempted to unlex more than one token"), which trips on intermediate editing states and would crash the LSP. The vendored copy returns an error instead.

If you need to vendor more stdlib (because it drops detail or aborts on partial input), follow the same pattern: copy to `hare/<module>/`, edit locally, and rely on `HAREPATH` putting `$(PWD)` first.

## Test conventions

- **Unit tests** live next to source as `<name>_test+test.ha`. The `+test` build tag scopes them to `hare test`.
- **E2E tests** under [e2e/](e2e/) spawn `./hare-lsp` and exchange real JSON-RPC over pipes. They exist specifically to catch regressions unit tests can't — for example, the buffered-stdout flush bug. They need the binary built first; `make test` handles that.
- Prefer real `@test fn` cases over one-off probe scripts that drive the server externally.
- Test inputs that READ data must be checked in (inline strings or under a `testdata/` dir). `.tmp/` is fine for test OUTPUT or self-contained scratch (create, read, remove within one test), but never as a shared input. See [.claude/rules/test-fixtures-and-tmp-dir.md](.claude/rules/test-fixtures-and-tmp-dir.md).

## Project-specific rules under `.claude/rules/`

These are enforced; read them before doing nontrivial work:

- [use-repo-tmp-dir.md](.claude/rules/use-repo-tmp-dir.md) — use `.tmp/` in the repo root, never `/tmp`.
- [test-fixtures-and-tmp-dir.md](.claude/rules/test-fixtures-and-tmp-dir.md) — test inputs go in git; only test outputs and self-contained scratch belong in `.tmp/`.
- [no-assumptions-in-answers.md](.claude/rules/no-assumptions-in-answers.md) — every factual claim must be checked, with a source link.
- [understand-before-fixing.md](.claude/rules/understand-before-fixing.md) — read the code, trace execution, find the root cause; no stab-in-the-dark fixes.
- [general-behavioral-guidelines.md](.claude/rules/general-behavioral-guidelines.md) — think before coding, simplicity first, surgical changes, goal-driven execution.
- [no-self-modification.md](.claude/rules/no-self-modification.md) — never edit `CLAUDE.md`, `.claude/rules/`, or `.claude/settings*.json` without explicit permission. Unexpected changes there are likely the user's pending work; ask first.
- [use-approved-tools-only.md](.claude/rules/use-approved-tools-only.md) — use the dedicated `Read`/`Edit`/`Write`/`Glob`/`Grep` tools, not shell equivalents. Unapproved Bash blocks on a permission prompt.

## External dependencies

- Hare v0.26.0 on `$PATH`.
- `hare-json` (encoding::json) installed at `/usr/local/src/hare/third-party/encoding/json/`. The `make check-deps` target fails fast with install instructions if missing.
- Hare stdlib source for reference: `/usr/local/src/hare/stdlib/` (especially `hare/ast`, `hare/unparse`, `hare/parse`, `hare/lex`).
