# Neovim

Three ways to wire `hare-lsp` into neovim, from least to most batteries.

All three require:

- `hare-lsp` on `$PATH` (or an absolute path you can point at).
- A filetype mapping so `.ha` files become `hare`. The plugin in option 3
  does this for you; for options 1-2 add:
  ```lua
  vim.filetype.add({ extension = { ha = "hare" } })
  ```

## 1. Built-in `vim.lsp.start` (no plugins)

Drop this in your `init.lua`:

```lua
vim.filetype.add({ extension = { ha = "hare" } })

vim.api.nvim_create_autocmd("FileType", {
  pattern = "hare",
  callback = function(args)
    vim.lsp.start({
      name = "hare-lsp",
      cmd = { "hare-lsp" },
      root_dir = vim.fs.root(args.buf, { ".git", "Makefile" }) or vim.fn.getcwd(),
      settings = {
        hare = {
          -- Override defaults here. Empty table works too.
          diagnostics = { enableBuild = true, debounceMs = 300 },
          format = { indentStyle = "tab", indentWidth = 8 },
          inlayHints = { parameterNames = true, inferredTypes = true },
        },
      },
    })
  end,
})
```

Neovim's built-in LSP responds to `workspace/configuration` automatically
when `settings` is set, which is the path hare-lsp uses to pull config at
initialize.

## 2. nvim-lspconfig

```lua
local lspconfig = require("lspconfig")
local configs = require("lspconfig.configs")

if not configs.hare_lsp then
  configs.hare_lsp = {
    default_config = {
      cmd = { "hare-lsp" },
      filetypes = { "hare" },
      root_dir = function(fname)
        if vim.fs and vim.fs.root then
          return vim.fs.root(fname, { ".git", "Makefile" })
        end
        return lspconfig.util.find_git_ancestor(fname)
      end,
      settings = {
        hare = {
          diagnostics = { enableBuild = true },
          format = { indentStyle = "tab", indentWidth = 8 },
        },
      },
    },
  }
end

lspconfig.hare_lsp.setup({})
```

## 3. The bundled `hare-lsp.nvim` plugin

The hare-lsp repo ships a small plugin at
[editors/nvim](../../editors/nvim) with a `setup()` and a
`:checkhealth hare-lsp` provider. See its
[README](../../editors/nvim/README.md) for install snippets.

Once the runtimepath includes it:

```lua
require("hare-lsp").setup({
  -- Optional. All keys are optional; defaults match the VSCode extension.
  settings = {
    hare = {
      diagnostics = { enableBuild = false },
    },
  },
  on_attach = function(_, bufnr)
    vim.keymap.set("n", "K",  vim.lsp.buf.hover,      { buffer = bufnr })
    vim.keymap.set("n", "gd", vim.lsp.buf.definition, { buffer = bufnr })
    vim.keymap.set("n", "gr", vim.lsp.buf.references, { buffer = bufnr })
    vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename, { buffer = bufnr })
  end,
})
```

After installing, run `:checkhealth hare-lsp` to verify the environment.

## Settings

The full settings tree (under the `hare` key) is documented in the main
[README](../../README.md#configuration). The same shape works for all
three setups above.

## Troubleshooting

- **No hover/diagnostics?** `:LspInfo` should list `hare-lsp` as
  attached. If not, check `:checkhealth hare-lsp` (or `:messages` if
  you're not using the bundled plugin).
- **`hare build` errors flooding diagnostics?** Set
  `settings.hare.diagnostics.enableBuild = false`.
- **Wire-protocol debugging.** Set
  `vim.env.HARE_LSP_LOG_DIR = "/abs/path"` before `vim.lsp.start` runs;
  the server tees every byte read/written to that directory.
