-- SPDX-License-Identifier: MPL-2.0
-- (c) hare-lsp authors

local lsp = require("helpers.lsp")

describe("hover", function()
  local workspace

  before_each(function()
    -- Doc comment carries a mix of byte-widths: ç (2-byte UTF-8), ★
    -- (U+2605, 3-byte UTF-8), 🎉 (U+1F389, 4-byte UTF-8 / surrogate
    -- pair in UTF-16). The Hare parser reports loc.off in runes and
    -- analysis/loc_fixup.ha translates to bytes; a regression there
    -- would garble the doc-comment extraction. Each rune is asserted
    -- individually below so a width-specific bug (e.g. 2-byte works,
    -- 3-byte does not) shows up cleanly.
    workspace = lsp.mk_workspace("hover", {
      ["main.ha"] = table.concat({
        "// Façade ★ 中文 🎉 for the deeper computation.",
        "export fn answer() int = 42;",
        "",
        "export fn caller() int = answer();",
        "",
      }, "\n")
    })
    lsp.setup_plugin(workspace)
  end)

  after_each(function()
    lsp.teardown()
    lsp.cleanup_workspace(workspace)
  end)

  it("returns the signature and doc comment for a function reference", function()
    local bufnr = lsp.open_and_attach(workspace, "main.ha")

    -- Cursor on `answer` in the call site `= answer()` on line 4.
    -- `export fn caller() int = answer();` - 'a' at 1-indexed col 26
    -- (0-indexed col 25).
    vim.api.nvim_win_set_cursor(0, { 4, 25 })

    local result = lsp.request_sync(
      "textDocument/hover",
      vim.lsp.util.make_position_params(0, "utf-16"),
      bufnr
    )

    assert(result ~= nil, "hover returned nil")
    assert(result.contents ~= nil, "hover missing `contents`")
    local value = type(result.contents) == "table"
      and result.contents.value
      or result.contents
    assert(type(value) == "string", "hover contents should be a string")

    -- The signature must appear in the hover markdown. A regression that
    -- echoes back just the cursor token would miss `fn answer`, and a
    -- regression that drops the return type would miss `int`.
    assert(value:find("fn answer") ~= nil,
      "hover should include the function signature; got: " .. value)
    assert(value:find("int") ~= nil,
      "hover should include the return type `int`; got: " .. value)

    -- The doc comment text must round-trip intact. If loc_fixup is
    -- wrong, the byte-indexed extraction reads shifted content and
    -- runes come out garbled. Each width is checked independently:
    --   ç → 2-byte UTF-8 (1 UTF-16 unit)
    --   ★ → 3-byte UTF-8 (1 UTF-16 unit)
    --   中文 → 3-byte UTF-8 each
    --   🎉 → 4-byte UTF-8 (UTF-16 surrogate pair, 2 code units)
    assert(value:find("Façade", 1, true) ~= nil,
      "hover should include the 2-byte rune (ç); got: " .. value)
    assert(value:find("★", 1, true) ~= nil,
      "hover should include the 3-byte rune (★); got: " .. value)
    assert(value:find("中文", 1, true) ~= nil,
      "hover should include the 3-byte CJK runes verbatim; got: " .. value)
    assert(value:find("🎉", 1, true) ~= nil,
      "hover should include the 4-byte rune (🎉); got: " .. value)
  end)
end)
