# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Language Server Protocol (LSP 3.17) implementation for the [Hare programming language](https://harelang.org/), written in Hare itself. Targets Hare v0.26.0. The binary is `hare-lsp` and is intended to be spawned by editor clients over stdio.

## New to Hare?

If you aren't already fluent in Hare, read [.claude/hare-language-guide.md](hare-language-guide.md) before doing nontrivial work. It covers the language surface (types, error handling, memory management, tagged unions), the stdlib modules this codebase actually uses, and the project-specific landmines agents keep rediscovering (vendored stdlib, rune-vs-byte offsets, append-realloc invalidation, etc.).

## Build, test, run

The project is driven entirely by the [Makefile](Makefile). It pins `HAREPATH` to `$(PWD):$(THIRDPARTY):/usr/local/src/hare/stdlib` so that `use lsp;`, `use server;`, etc. resolve to the in-tree modules.

- `make` — builds `./hare-lsp` (checks for `hare-json` at `/usr/local/src/hare/third-party/encoding/json/` first).
- `make test` — builds the binary, then runs unit tests AND the e2e suite. The e2e tests spawn the actual `./hare-lsp` binary over OS pipes; they require the binary to exist, which is why `test` depends on `hare-lsp`. This target does **not** run the VSCode extension's vitest suite, because users running hare-lsp from non-VSCode editors shouldn't need Node installed.
- `make vscode-test` — runs the VSCode extension's vitest suite (TypeScript-side logic, currently the terminal-output parser that drives the test-status gutter). When you run `make test`, also run `make vscode-test` so the extension tests stay green — they cover code that ships from this repo even though they're gated separately.
- `make vscode-e2e` — runs the `@vscode/test-electron` suite under [editors/vscode/src/test/](editors/vscode/src/test/). Spawns a real VSCode build, loads the in-tree extension, and drives the LanguageClient via `vscode.execute*Provider` commands; covers capability negotiation and client-side response shaping that pure-LSP harnesses cannot. NOT a dependency of `make test`. First run downloads VSCode into `editors/vscode/.vscode-test/`.
- `make nvim-test` — runs the plenary-driven Neovim e2e suite under [e2e-nvim/](e2e-nvim/). Drives the in-tree Neovim plugin against `./hare-lsp` from a real `nvim --headless` session, exercising capability negotiation, client-computed `didChange` diffs, and `WorkspaceEdit` consumption that the synthetic Hare-side e2e cannot. NOT a dependency of `make test`: users running hare-lsp from non-Neovim editors shouldn't need Neovim + plenary installed. CI runs this as a separate gating job. First run lazy-clones plenary into `e2e-nvim/.deps/`.
- `make clean` — removes `./hare-lsp`, `.cache/`, and the VSCode extension build artifacts.
- `make vscode-install` — builds and installs the in-tree VSCode extension at [editors/vscode/](editors/vscode/).

There is no separate lint step; rely on `hare build` errors, `make test`, `make vscode-test`, `make vscode-e2e`, and `make nvim-test`.

Before committing, run `./harefmt --write .` to format Hare files in the repo.

### Running a single test

`hare test` accepts a name filter. Tests live alongside source as `*_test+test.ha` (unit) or under [e2e/](e2e/) (e2e). Example:

```sh
HAREPATH="$PWD:/usr/local/src/hare/third-party:/usr/local/src/hare/stdlib" \
  HARECACHE="$PWD/.cache" \
  hare test definition_falls_back_to_workspace_index_for_cross_file
```

For an e2e test, add `e2e` after the test name selector (the e2e suite is its own module).

### Debugging the wire protocol

Set `HARE_LSP_LOG_DIR=/abs/path` in the server's environment to tee every byte read/written/logged to `hare-lsp-{in,out,err}.log` in that directory. The path must be absolute because vscode-languageclient spawns the server with `cwd=/`. See [cmd/hare_lsp/main.ha](cmd/hare_lsp/main.ha) for the wiring.

## Architecture

Five top-level modules form a clean stack. Each is on `HAREPATH` and is imported by name (`use lsp;`, `use analysis;`, etc.).

### `cmd/hare_lsp/` — entry point

[cmd/hare_lsp/main.ha](cmd/hare_lsp/main.ha) wires `os::stdin`/`os::stdout_file` to a `server::server` and runs the loop. Critically, it uses the **unbuffered** stdout handle: vscode-languageclient holds stdin open across requests, so the process never exits to flush a buffered stdout, and responses would sit in the 4 KiB buffer indefinitely. The e2e suite guards against re-introducing that bug. The directory uses an underscore (not a dash) so that `hare test` auto-discovers the module; the built binary is still named `hare-lsp`.

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
- [analysis/loc_fixup.ha](analysis/loc_fixup.ha): the Hare AST reports `loc.off` as a rune index; the LSP needs byte offsets. This module fixes those up. See "Byte / rune offsets" below — fixup translates the unit but not the *semantic* of `loc.end`, which still points at the start of the last rune of the last token.

### `server/` — feature handlers

Owns the `server` struct (state, open documents, indices, pending requests, etc.) and dispatches incoming messages to per-feature files. [server/server.ha](server/server.ha) is the dispatch table: see `handle_request` and `handle_notification` for the full method list. Each LSP feature lives in its own file (`completion.ha`, `hover.ha`, `formatting.ha`, …) with a matching `*_test+test.ha`.

Key flow: `run` loops on `lsp::read` → `lsp::decode` → `dispatch` → `flush_pending_diagnostics`. Diagnostics are debounced (`hare.diagnostics.debounceMs`) by time since the last edit. The main loop waits up to the remaining debounce window for the next LSP message; if the window expires first, the trailing edit publishes on its own.

Lifecycle is gated in `handle_request`: `PRE_INIT` accepts only `initialize`; `SHUTTING_DOWN`/`EXITED` reject everything except `exit`.

### `hare/parse/` — patched stdlib overlay

A copy of `hare::parse` materialized from `$(STDLIB)/hare/parse/` at build time with two patches applied:

- `parse.ha.patch`: fixes `want()`, which in stdlib aborts the whole process ("attempted to unlex more than one token") on intermediate editing states. The patched copy moves `lex::unlex(lexer, tok)` above the alternatives loop so the mkloc cycles inside the loop don't clash. Newer stdlibs (Alpine's `hare=0.26.0.1-r0`) ship this fix upstream; the build wrapper uses `patch -N` and treats "previously applied" as success so the same patch works against both variants.
- `import.ha.patch`: fixes per-import `loc.end`, which in stdlib points at the lexer's NEXT real token. Without the fix, `textDocument/documentLink` and folding ranges extend past `use` statements into following comments.

Only the patches and [hare/parse/README.md](hare/parse/README.md) are tracked in git; the `.ha` files are generated by the `hare/parse/.stamp` Makefile target and are gitignored (and skipped by `harefmt`, since it walks under `.gitignore`). On a fresh checkout, the first `make` or `make test` runs the bootstrap automatically. See [hare/parse/README.md](hare/parse/README.md) for the refresh procedure when bumping Hare versions.

If you need to vendor more stdlib (because it drops detail or aborts on partial input), follow the same pattern: write a `.patch` against the upstream module, list it in `HARE_PARSE_PATCHES` (or an analogous variable for the new module), and rely on `HAREPATH` putting `$(PWD)` first.

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

## Byte / rune offsets

Mixing up bytes and runes is the single most recurring source of bugs in this codebase. Every position-related field has a unit and a semantic, and getting either wrong silently breaks behavior only on certain inputs (so unit tests with ASCII single-character names won't catch it).

1. **`hare::ast` `loc.off` is a rune index, not a byte offset.** The Hare lexer counts code points, not bytes. [analysis/loc_fixup.ha](analysis/loc_fixup.ha) walks the AST after parsing and translates every `loc.off` to a byte offset. **Do not consume `loc.off` from a freshly-parsed AST without running the fixup.** All `analysis::parse_recover` callers do this; reach for it before doing offset math.
2. **`loc.end.off` points at the start of the LAST CONSUMED RUNE, not the end of the last consumed token.** This comes from [`hare::lex::prevloc`](file:///usr/local/src/hare/stdlib/hare/lex/lex.ha) — see the comment "The location of the previous rune." So for an access expression `b.data`, `loc.end.off` is the byte position of `a` (start of the last rune of `data`), not the end of `data` and not the start of `data`. For single-character names like `b.x` the start-of-last-rune equals the start-of-name, which is why most tests in the repo accidentally pass and the bug stays hidden. When matching against a known name `s`, compare to `loc.end.off == name_start + last_rune_offset(s)` rather than `== name_start` or `== name_end`.
3. **`str` is UTF-8 bytes plus a length.** `len(s)` returns bytes. Iterating runes requires `strings::iter` + `strings::next`. See `analysis/positions.ha` for the conversion utilities. Don't roll your own offset math at the `str`/byte boundary.
4. **LSP positions are negotiated UTF-8 / UTF-16 / UTF-32 code units.** VSCode defaults to UTF-16. Every conversion between LSP positions and byte offsets has to round-trip through `position_to_byte` / `byte_to_position` in [analysis/positions.ha](analysis/positions.ha).

When you write a test that touches offsets, **include at least one identifier longer than one ASCII character** — preferably one with a multi-byte rune. ASCII single-character tests are the failure mode that lets these bugs ship.

## External dependencies

- Hare v0.26.0 on `$PATH`.
- `hare-json` (encoding::json) installed at `/usr/local/src/hare/third-party/encoding/json/`. The `make check-deps` target fails fast with install instructions if missing.
- Hare stdlib source for reference: `/usr/local/src/hare/stdlib/` (especially `hare/ast`, `hare/unparse`, `hare/parse`, `hare/lex`).
