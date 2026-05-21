-- SPDX-License-Identifier: MPL-2.0
-- (c) hare-lsp authors
--
-- Tests that the editor can apply a WorkspaceEdit returned from
-- textDocument/rename. The Hare-side e2e asserts the server emits the
-- right edit; this asserts the client side applies it correctly to a
-- live buffer.

local lsp = require("helpers.lsp")

describe("rename", function()
  local workspace

  before_each(function()
    -- Leading doc comment mixes 2-byte (ó, á), 3-byte (★, 中文), and
    -- 4-byte (🎉) runes BEFORE the decl and call sites. A byte/rune
    -- slip in the rename's edit math at any width would damage the
    -- comment - the per-rune assertions below catch each case.
    workspace = lsp.mk_workspace("rename_apply", {
      ["main.ha"] = table.concat({
        "// Función auxiliar ★ 中文 🎉 — renombrar para más claridad.",
        "fn old_name() int = 1;",
        "",
        "export fn caller() int = old_name() + old_name();",
        "",
      }, "\n"),
    })
    lsp.setup_plugin(workspace)
  end)

  after_each(function()
    lsp.teardown()
    lsp.cleanup_workspace(workspace)
  end)

  it("applies a workspace edit to the buffer", function()
    local bufnr = lsp.open_and_attach(workspace, "main.ha")

    -- Land on `old_name` in its declaration. The doc comment is line
    -- 1; the decl is line 2. `fn old_name` puts 'o' at 0-indexed col 3.
    vim.api.nvim_win_set_cursor(0, { 2, 3 })

    local params = vim.lsp.util.make_position_params(0, "utf-16")
    params.newName = "new_name"

    local edit = lsp.request_sync("textDocument/rename", params, bufnr)
    assert(edit ~= nil, "rename returned no WorkspaceEdit")

    vim.lsp.util.apply_workspace_edit(edit, "utf-16")

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local joined = table.concat(lines, "\n")
    assert(joined:find("fn new_name%(%)") ~= nil,
      "declaration not renamed: " .. joined)
    -- Exactly 3 occurrences of new_name: the decl + 2 call sites.
    local _, count = joined:gsub("new_name", "")
    assert(count == 3,
      "expected exactly 3 occurrences of new_name (decl + 2 calls), got "
      .. count .. " in: " .. joined)
    assert(joined:find("old_name") == nil,
      "old_name should be gone after rename; got: " .. joined)
    -- Every byte-width of multi-byte rune must come through intact.
    -- A byte-vs-rune slip in the rename's edit math would shift,
    -- truncate, or garble the comment; per-width assertions make a
    -- width-specific bug visible.
    assert(joined:find("Función auxiliar", 1, true) ~= nil,
      "rename damaged 2-byte rune (ó); got: " .. joined)
    assert(joined:find("más claridad", 1, true) ~= nil,
      "rename damaged 2-byte rune (á); got: " .. joined)
    assert(joined:find("★", 1, true) ~= nil,
      "rename damaged 3-byte rune (★); got: " .. joined)
    assert(joined:find("中文", 1, true) ~= nil,
      "rename damaged 3-byte CJK runes; got: " .. joined)
    assert(joined:find("🎉", 1, true) ~= nil,
      "rename damaged 4-byte rune (🎉); got: " .. joined)
  end)
end)
