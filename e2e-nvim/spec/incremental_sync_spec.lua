-- SPDX-License-Identifier: MPL-2.0
-- (c) hare-lsp authors
--
-- Inserts text into a live buffer via nvim_buf_set_text so that
-- vscode-languageclient's analog (nvim's built-in LSP client) sends a
-- proper incremental textDocument/didChange diff to the server. Then
-- hovers the new identifier - if the server saw the right diff, hover
-- resolves; if it didn't, hover returns null.

local lsp = require("helpers.lsp")

describe("incremental sync", function()
  local workspace

  before_each(function()
    workspace = lsp.mk_workspace("incremental_sync", {
      ["main.ha"] = table.concat({
        "export fn main() void = void;",
        "",
      }, "\n"),
    })
    lsp.setup_plugin(workspace)
  end)

  after_each(function()
    lsp.teardown()
    lsp.cleanup_workspace(workspace)
  end)

  it("server sees a function added via buf_set_lines", function()
    local bufnr = lsp.open_and_attach(workspace, "main.ha")

    -- Insert a new function above the existing one, prefixed by a doc
    -- comment with multi-byte runes (Ü, ä). nvim's LSP client
    -- computes a TextDocumentContentChangeEvent in UTF-16 code units
    -- from this; if the column count is wrong on the multi-byte line,
    -- the server reconstructs a corrupted buffer and the later hover
    -- fails.
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, {
      "// Übergänge zwischen Zuständen.",
      "export fn added_after_open() int = 99;",
      "",
    })

    -- Hover the inserted identifier. After insertion the file looks
    -- like:
    --   line 0: // Übergänge zwischen Zuständen.
    --   line 1: export fn added_after_open() int = 99;
    -- Cursor on nvim line 2 (1-indexed) col 14 (0-indexed) lands
    -- mid-identifier in `added_after_open`.
    local resolved
    local ok = vim.wait(5000, function()
      vim.api.nvim_win_set_cursor(0, { 2, 14 })
      local params = vim.lsp.util.make_position_params(0, "utf-16")
      local results = vim.lsp.buf_request_sync(
        bufnr, "textDocument/hover", params, 2000
      )
      if not results then return false end
      for _, r in pairs(results) do
        if r.result and r.result.contents then
          local value = type(r.result.contents) == "table"
            and r.result.contents.value
            or r.result.contents
          if type(value) == "string" and value:find("added_after_open") then
            resolved = value
            return true
          end
        end
      end
      return false
    end, 100)

    assert(ok,
      "server never resolved hover on the inserted identifier; "
      .. "incremental didChange likely missing or wrong. last: "
      .. tostring(resolved))
  end)
end)
