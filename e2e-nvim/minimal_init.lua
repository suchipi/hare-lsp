-- SPDX-License-Identifier: MPL-2.0
-- (c) hare-lsp authors
--
-- Minimal Neovim init for the plenary e2e suite. Adds plenary and the
-- in-tree `editors/nvim` plugin to the runtimepath, registers the
-- `hare` filetype, and otherwise leaves the editor untouched. Each
-- spec calls `require("hare-lsp").setup(...)` itself so that the
-- workspace root is scoped to that spec's fixture directory.

local function script_dir()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(source, ":h")
end

local here = script_dir()
local repo_root = vim.fn.fnamemodify(here, ":h")

-- Plenary is auto-cloned by `make nvim-test` into e2e-nvim/.deps/.
local plenary_path = here .. "/.deps/plenary.nvim"
if vim.fn.isdirectory(plenary_path) ~= 1 then
  io.stderr:write(
    "plenary.nvim not found at " .. plenary_path .. "\n"
      .. "run `make nvim-test` (which clones it) instead of invoking nvim directly.\n"
  )
  vim.cmd("cquit 1")
end

vim.opt.runtimepath:prepend(plenary_path)
vim.opt.runtimepath:prepend(repo_root .. "/editors/nvim")
-- Adds e2e-nvim/lua/ to the lua require path so specs can
-- `require("helpers.lsp")`.
vim.opt.runtimepath:prepend(here)

vim.opt.swapfile = false
vim.opt.shada = ""
vim.opt.shortmess:append("I")

vim.filetype.add({ extension = { ha = "hare" } })

require("plenary.busted")
