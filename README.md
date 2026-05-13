# hare-lsp

A Language Server Protocol implementation for the [Hare programming language](https://harelang.org/), written in Hare itself. Targets Hare v0.26.0 and LSP 3.17.

**Status:** Young but powerful. Should be suitable for daily driver use.

## Features

- **Diagnostics** (push and pull): an in-process recovering parser produces diagnostics on every change. On save, `hare build` adds type-check errors. Toggle build via `diagnostics.enableBuild`.
- **Navigation**: hover, definition, type-definition, declaration, implementation, references, document highlight, prepare-rename + rename, document & workspace symbols, document links, call hierarchy, type hierarchy.
- **Ownership hints on hover**: pointer / slice / `str` values get an `Ownership: owned | borrowed | unknown` line on hover, sourced from user-written `@returns:` / `@param` / `@owned` / `@borrowed` annotations, a committed stdlib lookup table, or built-in expression heuristics (`alloc`, `&x`, string literals). See [docs/ownership-annotations.md](docs/ownership-annotations.md) for the annotation syntax.
- **Editing**: completion, signature help, formatting (also exposed as standalone `harefmt` CLI; see below), code actions (organize imports), code lens (run test, N references), inlay hints (parameter names + inferred types), semantic tokens (full + range + delta), folding ranges, selection ranges.
- **Workspace**: multi-root workspace folders, configuration pull, file watchers, will/did create/rename/delete, executeCommand (`hare-lsp.runTest`, `hare-lsp.runModule`).
- **Window**: showMessage, showMessageRequest, logMessage, showDocument, work-done progress.
- **Lifecycle**: initialize, initialized, shutdown, exit, $/cancelRequest, $/setTrace, $/logTrace, dynamic capability registration.

For a full feature matrix - including what's supported, what's not, and
known limitations - see [docs/features.md](docs/features.md).

## Installation

### Dependencies

- You'll need [Hare](https://harelang.org/) v0.26.0 on `$PATH` (or override with the `hare.path` setting).
  - On macOS, you can use [my updated version of hshq's macOS port](https://github.com/suchipi/harelang).
- [hare-json](https://git.sr.ht/~sircmpwn/hare-json) installed at `/usr/local/src/hare/third-party/encoding/json/`. Install with:
  ```sh
  cd /tmp && git clone https://git.sr.ht/~sircmpwn/hare-json
  sudo make -C "/tmp/hare-json" install
  ```

### Build

```sh
make                  # builds ./hare-lsp and ./harefmt
sudo make install     # installs both to /usr/local/bin/
make vscode-extension # optional; builds the VS Code extension
make vscode-install   # installs the VS Code extension
```

After installing, run `hare-lsp --doctor` to verify your environment
(checks `hare` on `$PATH`, HAREPATH entries, hare-json, and any
`HARE_LSP_LOG_DIR` you've set).

### Test

```sh
make test
```

## Editor setup

Per-editor setup recipes live under [docs/editors/](docs/editors/):

- [Neovim](docs/editors/neovim.md) - built-in `vim.lsp.start`, nvim-lspconfig, or the drop-in plugin at [editors/nvim/](editors/nvim/) (with `:checkhealth hare-lsp`).
- [Helix](docs/editors/helix.md) - `languages.toml` snippet.
- [Emacs](docs/editors/emacs.md) - eglot and lsp-mode.
- [Zed](docs/editors/zed.md) - settings.json wiring (third-party extension required for the Hare language).
- VS Code - see heading below.

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
| `hover.useHtml` | boolean | `true` | Wrap the Ownership line in `<small>` so HTML-aware clients (VSCode) render it as fine print. Disable for editors that don't render HTML in hover markdown (Neovim, Helix, Emacs default renderers). |
| `inlayHints.parameterNames` | boolean | `true` | Show parameter-name hints at call sites. |
| `inlayHints.inferredTypes` | boolean | `true` | Show inferred-type hints on `let`/`const`. |
| `inlayHints.inferredTypesMaxDepth` | number | `10` | Max recursion depth for inferred-type hints; follows call return types, identifier bindings, and type aliases. Alias-chain cycles are guarded by a visited set, so larger values are safe. |
| `limits.maxOpenDocuments` | number | `1024` | Cap on open documents. |
| `limits.maxTotalBufferBytes` | number | `268435456` | Cap on summed open-buffer bytes (256 MiB). |
| `limits.maxPendingRequests` | number | `4096` | Cap on in-flight server-initiated requests. |
| `limits.maxCancelledIds` | number | `256` | Cap on cancelled request ids retained. |
| `limits.maxDiagnosticsPerFile` | number | `1000` | Cap on diagnostics published per file. Excess collapses into a single trailing diagnostic. |
| `limits.maxWorkspaceIndexEntries` | number | `1000000` | Cap on workspace-index entries. Raise it if your workspace has more than ~1M decls. |

The canonical JSON Schema for these settings is checked in at [editors/vscode/schemas/hare-settings.schema.json](editors/vscode/schemas/hare-settings.schema.json). Editor integrations and external tooling should treat that document as the source of truth.

### Server environment

| Variable | Description |
| --- | --- |
| `HARE_LSP_LOG_DIR` | Absolute directory to tee the wire-protocol stream into `hare-lsp-{in,out,err}.log`. Useful for diagnosing handshake or framing issues. |
| `HARE_LSP_LOG_LEVEL` | Minimum stderr-log severity. One of `debug`, `info`, `warn`, `error`. Defaults to `info`. |
| `HARE_LSP_MAX_BODY_BYTES` | Override the LSP transport's max request body size (default 32 MiB). Read at startup because the cap applies before `initialize` arrives. |

## `harefmt`: standalone formatter CLI

`make` also builds `./harefmt`, a thin CLI wrapping the same formatter the LSP uses for `textDocument/formatting`. Use it from the shell or CI to format `*.ha` files outside an editor.

Hare has a strict [style guide](https://harelang.org/documentation/usage/style.html) which `harefmt` tries its best to follow, so there are no formatting style options.

### Usage

Exactly one mode flag is required; `--write`, `--check`, or `--stdout`.

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

- `.gitignore`: read by default so vendored / generated `*.ha` files in your repo are automatically excluded.
- `.harefmtignore`: same syntax as `.gitignore`. Use this for paths you want skipped from formatting but kept in version control.

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

- **References & rename are partly textual.** Discovery is a textual workspace scan (comments, strings, char literals, and raw strings are skipped). The hits are then filtered semantically:
  - Locals (`let` / `const` / `def` / `for` / `match` / function parameter) are bounded to the binding's lexical scope, so shadowing works correctly.
  - Top-level decls re-resolve each candidate against its file's `use` list + workspace index, so unrelated decls sharing a short name in different modules are kept distinct. Hits in files that aren't workspace-indexed (stdlib, third-party off the workspace path) are dropped.
  - **Fallback case:** if the cursor's own symbol can't be resolved against the workspace index (e.g. a buffer outside every workspace folder, or a fresh symbol not yet indexed), the filter is skipped and every textual hit is returned. In that mode a rename can rewrite same-named decls in unrelated modules — preview the edit before applying.
- **Formatting requires a parseable file.** Full / range formatting only runs when the document parses cleanly. On-type re-indent still fires on unparseable files (it operates on whitespace only and never rewrites tokens), but full/range formatting returns no edits. This is intentional: a no-op format on a syntax error is a useful signal that the file doesn't parse.
- **Workspace indexing is chunked, not concurrent.** Hare is single-threaded, so indexing runs cooperatively between LSP messages: each dispatch tick processes a small batch and yields back. The main loop also peeks at stdin with a zero-timeout poll between batches, so background indexing keeps advancing even when the editor is silent. Progress is reported via `$/progress` and the job can be cancelled with `window/workDoneProgress/cancel`. `workspace/symbol` results may carry `isIncomplete: true` while the job is still draining.
- **Resource caps (configurable).** The server refuses to grow past caps on open documents, total open-buffer bytes, per-file diagnostics (excess collapses into a single trailing diagnostic), in-flight server requests, and workspace-index entries. All are tunable via `hare.limits.*` — raise the limit if your project needs it. Defaults are in the [Configuration](#configuration) table. Hitting any cap is logged via `window/logMessage`.
  - **Transport body size is also capped, but configurable.** The LSP transport rejects messages larger than 32 MiB by default. Override via the `HARE_LSP_MAX_BODY_BYTES` environment variable when the client sends very large workspace edits. The cap is read at startup (before `initialize` arrives), which is why it's an env var rather than a setting.
- **Inlay-hint types are best-effort.** Inferred types resolve literals, declared types, function-call return types, and follow type-alias chains up to `hare.inlayHints.inferredTypesMaxDepth` hops (default 10; cycles are guarded by a visited set). Complex inference (deeply chained field accesses, generic-shaped constructs) may show no hint rather than a wrong one.
- **`workspace/symbol` and document links** resolve stdlib imports only when `HAREPATH` overlaps a workspace folder.

## License

MPL-2.0, same as Hare itself.
