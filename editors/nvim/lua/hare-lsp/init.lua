-- SPDX-License-Identifier: MPL-2.0
-- (c) hare-lsp authors
--
-- Drop-in neovim plugin for the hare-lsp language server.
--
-- Usage:
--   require('hare-lsp').setup({})
--
-- This registers an autocmd that starts the server for every buffer with
-- filetype `hare`. Settings are forwarded via the standard LSP
-- `workspace/configuration` flow; the server pulls them at initialize.

local M = {}

-- Default settings under the `hare` namespace. Mirrors the VSCode
-- extension's schema at editors/vscode/schemas/hare-settings.schema.json
-- so behavior matches across editors.
M.default_settings = {
  hare = {
    path = "hare",
    harepath = "",
    tags = {},
    diagnostics = {
      debounceMs = 300,
      enableBuild = true,
      buildTimeoutMs = 60000,
    },
    format = {
      indentStyle = "tab",
      indentWidth = 8,
      trimFinalNewlines = true,
      insertFinalNewline = true,
    },
    inlayHints = {
      parameterNames = true,
      inferredTypes = true,
    },
  },
}

-- Resolves the workspace root for a given buffer. Walks up looking for
-- `.git` or `Makefile`; falls back to the current working directory.
local function default_root_dir(bufnr)
  local fname = vim.api.nvim_buf_get_name(bufnr)
  if fname == "" then
    return vim.fn.getcwd()
  end
  if vim.fs and vim.fs.root then
    return vim.fs.root(bufnr, { ".git", "Makefile" }) or vim.fn.getcwd()
  end
  -- Fallback for older neovim without vim.fs.root.
  local dir = vim.fn.fnamemodify(fname, ":h")
  while dir and dir ~= "/" and dir ~= "" do
    if vim.fn.isdirectory(dir .. "/.git") == 1
        or vim.fn.filereadable(dir .. "/Makefile") == 1 then
      return dir
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then break end
    dir = parent
  end
  return vim.fn.getcwd()
end

-- Public entry point.
--
-- opts may contain:
--   cmd            : command to start the server (default { "hare-lsp" })
--   settings       : table merged onto M.default_settings
--   init_options   : forwarded as `initializationOptions`
--   root_dir       : function(bufnr) -> string, overrides default
--   on_attach      : function(client, bufnr) called after attach
--   capabilities   : table merged with the default LSP client capabilities
function M.setup(opts)
  opts = opts or {}

  -- Ensure `.ha` files are detected as `hare`. Users who already have
  -- this (via tree-sitter, hare.vim, etc.) won't be affected by a
  -- redundant filetype.add call.
  vim.filetype.add({ extension = { ha = "hare" } })

  local cmd = opts.cmd or { "hare-lsp" }
  local settings = vim.tbl_deep_extend("force", M.default_settings, opts.settings or {})
  local init_options = opts.init_options or {}
  local root_dir = opts.root_dir or default_root_dir

  vim.api.nvim_create_autocmd("FileType", {
    pattern = "hare",
    group = vim.api.nvim_create_augroup("hare-lsp", { clear = true }),
    callback = function(args)
      local root = type(root_dir) == "function" and root_dir(args.buf) or root_dir
      vim.lsp.start({
        name = "hare-lsp",
        cmd = cmd,
        root_dir = root,
        settings = settings,
        init_options = init_options,
        capabilities = opts.capabilities,
        on_attach = opts.on_attach,
      })
    end,
  })
end

return M
