# hare-lsp

A Language Server Protocol implementation for the [Hare programming language](https://harelang.org/), written in Hare itself. Targets Hare v0.26.0 and LSP 3.17.

**Status:** experimental (v0.0.1) — written with LLM assistance, please file issues.

## Features

- **Diagnostics** (push and pull): an in-process recovering parser produces diagnostics on every change; on save, `hare build` runs and its type-check errors are merged in. The in-process parser is the standalone fallback when `hare build` is disabled or unavailable.
- **Navigation**: hover, definition, type-definition, declaration, implementation, references, document highlight, prepare-rename + rename, document & workspace symbols, document links (with target resolution to module files), call hierarchy, type hierarchy.
- **Editing**: completion, signature help, formatting (full / range / on-type with reindent), code actions (organize imports), code lens (run test, N references), inlay hints (parameter names + inferred types), semantic tokens (full + range + delta), folding ranges, selection ranges.
- **Workspace**: multi-root workspace folders, configuration pull, file watchers, will/did create/rename/delete, executeCommand (`hare-lsp.runTest`, `hare-lsp.runModule`).
- **Window**: showMessage, showMessageRequest, logMessage, showDocument, work-done progress.
- **Lifecycle**: initialize, initialized, shutdown, exit, $/cancelRequest, $/setTrace, $/logTrace, dynamic capability registration.

## Installation

### Dependencies

- Hare v0.26.0 on `$PATH` (override with the `hare.path` setting).
- [hare-json](https://git.sr.ht/~sircmpwn/hare-json) installed at `/usr/local/src/hare/third-party/encoding/json/`. Install with:
  ```sh
  git clone https://git.sr.ht/~sircmpwn/hare-json /tmp/hare-json
  sudo make -C /tmp/hare-json install
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
| `tags` | string[] | `[]` | Build tags (`-T <tag>`). |
| `diagnostics.debounceMs` | number | `300` | Minimum ms between the last `didChange` and the next parse-diagnostics refresh. |
| `diagnostics.enableBuild` | boolean | `true` | Whether to run `hare build` on save. |
| `format.indentStyle` | `"tab"`/`"space"` | `"tab"` | Tab vs space indent in formatting output. |
| `format.indentWidth` | number | `8` | Number of spaces per indent level when `indentStyle = space`. |
| `format.trimFinalNewlines` | boolean | `true` | Trim trailing whitespace at file end. |
| `format.insertFinalNewline` | boolean | `true` | Ensure a trailing newline. |
| `inlayHints.parameterNames` | boolean | `true` | Show parameter-name hints at call sites. |
| `inlayHints.inferredTypes` | boolean | `true` | Show inferred-type hints on `let`/`const`. |

## License

MPL-2.0 — same as Hare itself.
