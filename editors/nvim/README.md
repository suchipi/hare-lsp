# hare-lsp.nvim

A drop-in neovim plugin for the [hare-lsp](https://git.sr.ht/~sircmpwn/hare-lsp)
language server. Registers `hare-lsp` with neovim's built-in LSP client and
ships a `:checkhealth hare-lsp` provider.

Requires neovim 0.10+ (uses `vim.lsp.start` and `vim.fs.root`).

## Install

The plugin is a regular Lua plugin living under
[editors/nvim](.) in the hare-lsp repo. Install it with whichever package
manager you use, or by extending the runtimepath manually.

### Manual (runtimepath)

```lua
vim.opt.runtimepath:append("/path/to/hare-lsp/editors/nvim")
require("hare-lsp").setup({})
```

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  dir = "/path/to/hare-lsp/editors/nvim",
  -- or, once published:
  -- "your-org/hare-lsp.nvim",
  ft = "hare",
  config = function()
    require("hare-lsp").setup({})
  end,
}
```

### [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use({
  "/path/to/hare-lsp/editors/nvim",
  ft = "hare",
  config = function() require("hare-lsp").setup({}) end,
})
```

### [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug '/path/to/hare-lsp/editors/nvim'
```

```lua
require("hare-lsp").setup({})
```

## Configuration

`setup()` accepts:

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `cmd` | `string[]` | `{ "hare-lsp" }` | Command to spawn the server. |
| `settings` | `table` | see source | Merged onto the default `hare.*` settings. |
| `init_options` | `table` | `{}` | Sent as `initializationOptions`. |
| `root_dir` | `function(bufnr) -> string` | `.git`/`Makefile` walk | Workspace root resolver. |
| `on_attach` | `function(client, bufnr)` | `nil` | Attach hook. |
| `capabilities` | `table` | `nil` | Extra LSP client capabilities. |

The full set of `hare.*` settings is documented in the
[main README](../../README.md#configuration). The defaults exposed here
mirror those values.

Example:

```lua
require("hare-lsp").setup({
  settings = {
    hare = {
      diagnostics = { enableBuild = false },
      format = { indentStyle = "space", indentWidth = 4 },
    },
  },
  on_attach = function(client, bufnr)
    vim.keymap.set("n", "K", vim.lsp.buf.hover, { buffer = bufnr })
    vim.keymap.set("n", "gd", vim.lsp.buf.definition, { buffer = bufnr })
  end,
})
```

## Health check

After installing, run:

```
:checkhealth hare-lsp
```

This verifies that `hare-lsp` and `hare` are on `$PATH`, that `HAREPATH`
resolves to existing directories, and that `HARE_LSP_LOG_DIR` (if set) is
writable.

## See also

- [docs/editors/neovim.md](../../docs/editors/neovim.md): three alternative
  setups (built-in `vim.lsp.start`, nvim-lspconfig, this plugin).
- [main README](../../README.md#features): full feature list.
