# hare-lsp

A Language Server Protocol implementation for the [Hare programming language](https://harelang.org/), written in Hare itself. Targets Hare v0.26.0 and LSP 3.17.

**Status:** experimental (v0.0.1) — written with LLM assistance, please file issues.

## Features

- **Diagnostics** (push and pull): an in-process recovering parser produces diagnostics on every change. On save, `hare build` adds type-check errors. Toggle build via `diagnostics.enableBuild`.
- **Navigation**: hover, definition, type-definition, declaration, implementation, references, document highlight, prepare-rename + rename, document & workspace symbols, document links (target resolution for workspace imports — stdlib imports resolve only when `HAREPATH` overlaps a workspace folder), call hierarchy, type hierarchy.
- **Editing**: completion, signature help, formatting (full / range / on-type with reindent), code actions (organize imports), code lens (run test, N references), inlay hints (parameter names + inferred types — best-effort: literals and declared types today), semantic tokens (full + range + delta), folding ranges, selection ranges.
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
make
sudo make install   # installs to /usr/local/bin/hare-lsp
```

### Test

```sh
make test
```

## Editor setup

### Neovim (nvim-lspconfig)

```lua
local lspconfig = require('lspconfig')
local configs = require('lspconfig.configs')

if not configs.hare_lsp then
  configs.hare_lsp = {
    default_config = {
      cmd = { 'hare-lsp' },
      filetypes = { 'hare' },
      -- nvim-lspconfig 0.2+: vim.fs.root; older versions:
      -- lspconfig.util.find_git_ancestor.
      root_dir = function(fname)
        if vim.fs and vim.fs.root then
          return vim.fs.root(fname, { '.git' })
        end
        return lspconfig.util.find_git_ancestor(fname)
      end,
      settings = {},
    },
  }
end

lspconfig.hare_lsp.setup{}
```

### VSCode

The repo ships an in-tree extension under [editors/vscode](editors/vscode/). Install it:

```sh
make vscode-install
```

This runs `npm install`, packages the extension as a `.vsix`, and installs it via the `code` CLI. See [editors/vscode/README.md](editors/vscode/README.md) for development details.

### Helix

```toml
# ~/.config/helix/languages.toml
[language-server.hare-lsp]
command = "hare-lsp"

[[language]]
name = "hare"
language-servers = ["hare-lsp"]
```

(Helix has a built-in `hare` language; verify with `hx --health hare`.)

### Emacs (eglot)

```elisp
(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               '(hare-mode . ("hare-lsp"))))
```

(Requires [hare-mode](https://git.sr.ht/~bbuccianti/hare-mode).)

## Configuration

Settings are read from the `hare` namespace. Defaults are in parentheses.

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

The canonical JSON Schema for these settings is checked in at [editors/vscode/schemas/hare-settings.schema.json](editors/vscode/schemas/hare-settings.schema.json). Editor integrations and external tooling should treat that document as the source of truth.

### Server environment

| Variable | Description |
| --- | --- |
| `HARE_LSP_LOG_DIR` | Absolute directory to tee the wire-protocol stream into `hare-lsp-{in,out,err}.log`. Useful for diagnosing handshake or framing issues. |
| `HARE_LSP_LOG_LEVEL` | Minimum stderr-log severity. One of `debug`, `info`, `warn`, `error`. Defaults to `info`. |

## Known limitations

These features work but have caveats worth knowing before relying on them:

- **References & rename are textual.** `textDocument/references` and `textDocument/rename` scan the workspace for ident tokens matching the cursor name. The scan respects comments, strings, and char literals, but it is **not scope-aware**: a `let foo` inside one function and a global `foo` are indistinguishable. Renaming a local that shadows a global will rewrite the global too. This matches what many LSPs (gopls's fallback, rust-analyzer in degraded mode) do; full scope-aware rename is on the roadmap. Workaround: when renaming a shadowing local, pick a unique new name first, then rename freely.
- **Formatting requires a parseable file.** Full / range formatting only runs when the document parses cleanly. If there are syntax errors, on-type re-indent still fires (it operates on whitespace only and never rewrites tokens), but full/range formatting returns no edits. Save the file in a parseable state to format.
- **Workspace indexing is synchronous.** When a workspace folder is added (via `workspace/didChangeWorkspaceFolders` or the initial `initialize` scan) the server walks every `*.ha` file under the new root on the message-handling thread. For very large workspaces (tens of thousands of files) this blocks the dispatch loop, including `$/cancelRequest`. Smaller workspaces are unaffected. Background indexing with progress reporting is planned but not yet implemented.
- **Resource caps.** The server refuses to grow past hard caps on open documents (1024), total open-buffer bytes (256 MiB), per-file diagnostics (1000; further parse errors are summarised in a single trailing diagnostic), in-flight server requests (4096), and workspace-index entries (1,000,000). Hitting any cap is logged via `window/logMessage`.
- **Type hierarchy is name-based.** `typeHierarchy/supertypes` and `subtypes` match by short identifier name across the workspace. Two unrelated types with the same short name in different modules will appear linked.
- **Inlay-hint types are best-effort.** Inferred types resolve literals, declared types, and simple expressions; complex inference (generic instantiations, deeply chained calls) may show no hint rather than a wrong one.
- **`workspace/symbol` and document links** resolve stdlib imports only when `HAREPATH` overlaps a workspace folder.

## License

MPL-2.0 — same as Hare itself.
