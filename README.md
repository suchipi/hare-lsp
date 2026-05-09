# hare-lsp

A Language Server Protocol implementation for the [Hare programming language](https://harelang.org/), written in Hare itself. Targets Hare v0.26.0 and LSP 3.17.

## Features

- **Diagnostics** (push and pull): in-process recovering parser plus `hare build` for type-check errors.
- **Navigation**: hover, definition, type-definition, declaration, implementation, references, document highlight, prepare-rename + rename, document & workspace symbols, document links, call hierarchy, type hierarchy.
- **Editing**: completion, signature help, formatting (full / range / on-type), code actions (organize imports), code lens (run test, N references), inlay hints (parameter names, inferred types), semantic tokens, folding ranges, selection ranges.
- **Workspace**: multi-root workspace folders, configuration pull, file watchers, will/did create/rename/delete, executeCommand (`hare-lsp.runTest`, `hare-lsp.runModule`).
- **Window**: showMessage, showMessageRequest, logMessage, showDocument, work-done progress.
- **Lifecycle**: initialize, initialized, shutdown, exit, $/cancelRequest, $/setTrace, $/logTrace, dynamic capability registration.

## Installation

### Dependencies

- Hare v0.26.0 (`/usr/local/bin/hare`).
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
      root_dir = lspconfig.util.find_git_ancestor,
      settings = {},
    },
  }
end

lspconfig.hare_lsp.setup{}
```

### VSCode

Use the [generic LSP client](https://marketplace.visualstudio.com/items?itemName=mattn.Lsp-Sample) and configure:

```jsonc
{
  "languageServerExample.serverPath": "hare-lsp"
}
```

A dedicated VSCode extension is on the roadmap.

### Helix

```toml
# ~/.config/helix/languages.toml
[language-server.hare-lsp]
command = "hare-lsp"

[[language]]
name = "hare"
language-servers = ["hare-lsp"]
```

### Emacs (eglot)

```elisp
(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               '(hare-mode . ("hare-lsp"))))
```

## Configuration

Settings are read from the `hare` namespace. Defaults are in parentheses.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `path` | string | `"hare"` | Path to the `hare` binary. |
| `tags` | string[] | `[]` | Build tags (`-T <tag>`). |
| `diagnostics.debounceMs` | number | `300` | Reserved for future async build runner. |
| `diagnostics.enableBuild` | boolean | `true` | Whether to run `hare build` on save. |
| `format.indentStyle` | `"tab"`/`"space"` | `"tab"` | Reserved for the formatter. |
| `format.indentWidth` | number | `8` | Reserved for the formatter. |
| `format.trimFinalNewlines` | boolean | `true` | Trim trailing whitespace at file end. |
| `format.insertFinalNewline` | boolean | `true` | Ensure a trailing newline. |
| `inlayHints.parameterNames` | boolean | `true` | Show parameter-name hints at call sites. |
| `inlayHints.inferredTypes` | boolean | `true` | Show inferred-type hints on `let`/`const`. |

## License

MPL-2.0 — same as Hare itself.
