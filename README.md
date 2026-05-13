# hare-lsp

A Language Server Protocol implementation for the [Hare programming language](https://harelang.org/), written in Hare itself. Targets Hare v0.26.0 and LSP 3.17.

**Status:** Young but powerful. Written with LLM assistance; please file issues.

## Features

- **Diagnostics** (push and pull): an in-process recovering parser produces diagnostics on every change. On save, `hare build` adds type-check errors. Toggle build via `diagnostics.enableBuild`.
- **Navigation**: hover, definition, type-definition, declaration, implementation, references, document highlight, prepare-rename + rename, document & workspace symbols, document links (target resolution for workspace imports; stdlib imports resolve only when `HAREPATH` overlaps a workspace folder), call hierarchy, type hierarchy.
- **Editing**: completion, signature help, formatting (full / range / on-type with reindent), code actions (organize imports), code lens (run test, N references), inlay hints (parameter names + inferred types; best-effort, currently literals and declared types), semantic tokens (full + range + delta), folding ranges, selection ranges.
- **Workspace**: multi-root workspace folders, configuration pull, file watchers, will/did create/rename/delete, executeCommand (`hare-lsp.runTest`, `hare-lsp.runModule`).
- **Window**: showMessage, showMessageRequest, logMessage, showDocument, work-done progress.
- **Lifecycle**: initialize, initialized, shutdown, exit, $/cancelRequest, $/setTrace, $/logTrace, dynamic capability registration.

## Installation

### Dependencies

- Hare v0.26.0 on `$PATH` (override with the `hare.path` setting).
- [hare-json](https://git.sr.ht/~sircmpwn/hare-json) installed at `/usr/local/src/hare/third-party/encoding/json/`. Install with:
  ```sh
  d=$(mktemp -d) && git clone https://git.sr.ht/~sircmpwn/hare-json "$d/hare-json"
  sudo make -C "$d/hare-json" install
  ```

### Build

```sh
make                # builds ./hare-lsp and ./harefmt
sudo make install   # installs both to /usr/local/bin/
```

After installing, run `hare-lsp --doctor` to verify your environment
(checks `hare` on `$PATH`, HAREPATH entries, hare-json, and any
`HARE_LSP_LOG_DIR` you've set).

### Test

```sh
make test
```

For a full feature matrix - including what's supported, what's not, and
known limitations - see [docs/features.md](docs/features.md).

## Editor setup

Per-editor setup recipes live under [docs/editors/](docs/editors/):

- [Neovim](docs/editors/neovim.md) - built-in `vim.lsp.start`, nvim-lspconfig, or the drop-in plugin at [editors/nvim/](editors/nvim/) (with `:checkhealth hare-lsp`).
- [Helix](docs/editors/helix.md) - `languages.toml` snippet.
- [Emacs](docs/editors/emacs.md) - eglot and lsp-mode.
- [Zed](docs/editors/zed.md) - settings.json wiring (third-party extension required for the Hare language).

### VSCode

The repo ships an in-tree extension under [editors/vscode](editors/vscode/). Install it:

```sh
make vscode-install
```

This runs `npm install`, packages the extension as a `.vsix`, and installs it via the `code` CLI. See [editors/vscode/README.md](editors/vscode/README.md) for development details.

## Configuration

Settings are read from the `hare` namespace.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `path` | string | `"hare"` | Path to the `hare` binary. |
| `harepath` | string | `""` | Colon-separated module search path (overrides `$HAREPATH`). Empty falls back to environment. |
| `tags` | string[] | `[]` | Build tags (`-T <tag>`). |
| `diagnostics.debounceMs` | number | `300` | Minimum ms between the last `didChange` and the next parse-diagnostics refresh. |
| `diagnostics.enableBuild` | boolean | `true` | Whether to run `hare build` on save. |
| `diagnostics.buildTimeoutMs` | number | `60000` | Max wall-clock ms to wait for `hare build` (or `hare test` / `hare run`) before SIGTERM. `0` disables the timeout. |
| `format.indentStyle` | `"tab"`/`"space"` | `"tab"` | Tab vs space indent in formatting output. |
| `format.indentWidth` | number | `8` | Number of spaces per indent level when `indentStyle = space`. |
| `format.trimFinalNewlines` | boolean | `true` | Trim trailing whitespace at file end. |
| `format.insertFinalNewline` | boolean | `true` | Ensure a trailing newline. |
| `inlayHints.parameterNames` | boolean | `true` | Show parameter-name hints at call sites. |
| `inlayHints.inferredTypes` | boolean | `true` | Show inferred-type hints on `let`/`const`. |
| `inlayHints.inferredTypesMaxDepth` | number | `3` | Max recursion depth for inferred-type hints; follows call return types, identifier bindings, and type aliases. Hard-capped at 16. |
| `limits.maxOpenDocuments` | number | `1024` | Cap on open documents. |
| `limits.maxTotalBufferBytes` | number | `268435456` | Cap on summed open-buffer bytes (256 MiB). |
| `limits.maxPendingRequests` | number | `4096` | Cap on in-flight server-initiated requests. |
| `limits.maxCancelledIds` | number | `256` | Cap on cancelled request ids retained. |
| `limits.maxDiagnosticsPerFile` | number | `1000` | Cap on diagnostics published per file. Excess collapses into a single trailing diagnostic. |
| `limits.maxWorkspaceIndexEntries` | number | `1000000` | Cap on workspace-index entries (also the absolute hard ceiling). |

The canonical JSON Schema for these settings is checked in at [editors/vscode/schemas/hare-settings.schema.json](editors/vscode/schemas/hare-settings.schema.json). Editor integrations and external tooling should treat that document as the source of truth.

### Server environment

| Variable | Description |
| --- | --- |
| `HARE_LSP_LOG_DIR` | Absolute directory to tee the wire-protocol stream into `hare-lsp-{in,out,err}.log`. Useful for diagnosing handshake or framing issues. |
| `HARE_LSP_LOG_LEVEL` | Minimum stderr-log severity. One of `debug`, `info`, `warn`, `error`. Defaults to `info`. |

## `harefmt`: standalone formatter CLI

`make` also builds `./harefmt`, a thin CLI wrapping the same comment-preserving formatter the LSP uses for `textDocument/formatting`. Use it from the shell or CI to format `*.ha` files outside an editor.

Hare's style guide mandates tab indentation, so `harefmt` always emits tabs at column 0 and has no `--indent-*` knobs. Output is opinionated and idempotent.

### Usage

Exactly one mode flag is required:

```sh
harefmt --write <path>...     # format files in place
harefmt --check <path>...     # exit 1 if any file would change; prints offenders
harefmt --stdout <path>       # write the formatted result to stdout
harefmt --stdout -            # read from stdin, write to stdout
```

Directory arguments are walked recursively for `*.ha` files. Symlinked directories are skipped by default (cycle-safe); symlinked regular files are followed by default (treated as the file they point to). Both can be overridden:

```sh
harefmt --write --follow-dir-symlinks src/
harefmt --check --no-follow-file-symlinks src/
```

Exit codes follow the gofmt / prettier convention: `0` = clean, `1` = at least one file would change (in `--check`) or at least one parse error, `2` = CLI usage error.

### Ignore files

`harefmt` honours two ignore files at each directory level along the walk:

- `.harefmtignore`: same syntax as `.gitignore`. Use this for paths you want skipped from formatting but kept in version control.
- `.gitignore`: read by default so vendored / generated `*.ha` files in your repo are automatically excluded.

Both files are walked upward from each path you pass on the command line, stopping at the first `.git/` ancestor (or filesystem root if no git repo is found). Closer (more nested) ignore files override more distant ones; within a single file, the last matching pattern wins.

Disable one or both:

```sh
harefmt --check --no-gitignore .          # ignore .gitignore, honour .harefmtignore
harefmt --check --no-ignore .             # ignore .harefmtignore, honour .gitignore
harefmt --check --no-ignore --no-gitignore .
```

Negation works the standard gitignore way:

```
# .harefmtignore
*.gen.ha
!keep.gen.ha
```

**Caveat (standard gitignore behaviour):** once a directory is excluded, files inside it can no longer be re-included via a `!` pattern. The walker prunes excluded directories before descending, so `vendor/` followed by `!vendor/important.ha` will NOT visit `important.ha`. Git itself behaves the same way. If you need to re-include something under an excluded directory, un-exclude the directory first and exclude only its specific contents.

### Standalone `gitignore` module

The gitignore-style pattern parser and matcher used by `harefmt` lives in its own top-level Hare module at [`gitignore/`](gitignore/) (see [`gitignore/pattern.ha`](gitignore/pattern.ha) and [`gitignore/match.ha`](gitignore/match.ha)). It has no dependency on the rest of the project (just stdlib's `strings` and `fnmatch`) and exposes parsing, single-pattern matching, ordered-list evaluation (last-match-wins), and layered evaluation (outer-first for nested ignore files). Anyone who wants the same matching semantics in another Hare project can vendor the directory unchanged.

## Known limitations

These features work but have caveats worth knowing before relying on them:

- **References & rename are partly textual.** When the cursor resolves to a local binding (`let` / `const` / `def` / `for` / `match` / function parameter), the search is bounded to that binding's lexical scope, so shadowing works correctly. For top-level decls the workspace is still scanned textually: comments, strings, and char literals are skipped, but two unrelated top-level identifiers with the same name in different modules are indistinguishable. Renaming a top-level symbol may rewrite same-named decls elsewhere.
- **Formatting requires a parseable file.** Full / range formatting only runs when the document parses cleanly. If there are syntax errors, on-type re-indent still fires (it operates on whitespace only and never rewrites tokens), but full/range formatting returns no edits. Save the file in a parseable state to format.
- **Workspace indexing is synchronous.** When a workspace folder is added (via `workspace/didChangeWorkspaceFolders` or the initial `initialize` scan) the server walks every `*.ha` file under the new root on the message-handling thread. For very large workspaces (tens of thousands of files) this blocks the dispatch loop, including `$/cancelRequest`. Smaller workspaces are unaffected. Background indexing with progress reporting is planned but not yet implemented.
- **Resource caps.** The server refuses to grow past hard caps on open documents (1024), total open-buffer bytes (256 MiB), per-file diagnostics (1000; further parse errors are summarised in a single trailing diagnostic), in-flight server requests (4096), and workspace-index entries (1,000,000). Hitting any cap is logged via `window/logMessage`.
- **Type hierarchy is name-based.** `typeHierarchy/supertypes` and `subtypes` match by short identifier name across the workspace. Two unrelated types with the same short name in different modules will appear linked.
- **Inlay-hint types are best-effort.** Inferred types resolve literals, declared types, and simple expressions; complex inference (generic instantiations, deeply chained calls) may show no hint rather than a wrong one.
- **`workspace/symbol` and document links** resolve stdlib imports only when `HAREPATH` overlaps a workspace folder.

## License

MPL-2.0, same as Hare itself.
