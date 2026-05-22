-- SPDX-License-Identifier: MPL-2.0
-- (c) hare-lsp authors
--
-- Verifies that nvim's LSP client sends textDocument/didSave on :write
-- with the negotiated includeText payload, and that the server's
-- handle_did_save consumes it (it bypasses the diagnostic debounce).
--
-- Note: nvim's built-in LSP client does NOT send textDocument/willSave
-- even when the server advertises `willSave: true` (grep nvim source
-- as of 0.12 - only didSave is wired). So this spec covers didSave
-- only.

local lsp = require("helpers.lsp")

describe("did_save", function()
  local workspace
  local did_save

  before_each(function()
    workspace = lsp.mk_workspace("did_save", {
      ["main.ha"] = table.concat({
        "export fn main() void = void;",
        "",
      }, "\n"),
    })
    lsp.setup_plugin(workspace)
    -- Subscribe BEFORE the buffer is opened so the client's didSave
    -- fire is captured. Recorder disposes in after_each.
    did_save = lsp.notify_recorder("textDocument/didSave")
  end)

  after_each(function()
    did_save.dispose()
    lsp.teardown()
    lsp.cleanup_workspace(workspace)
  end)

  it("sends didSave on `:write` and re-publishes diagnostics", function()
    local bufnr = lsp.open_and_attach(workspace, "main.ha")

    -- Wait for the clean state to settle (the server publishes an empty
    -- diagnostics array shortly after didOpen; if we don't wait we'd
    -- race the next assertion). Predicate-based so we don't sleep
    -- longer than needed.
    local cleared = vim.wait(2000, function()
      return #vim.diagnostic.get(bufnr) == 0
    end, 50)
    assert(cleared, "clean buffer never reached zero diagnostics; got: "
      .. vim.inspect(vim.diagnostic.get(bufnr)))

    -- Replace contents with a broken version, prefixed by a doc
    -- comment mixing 2-byte (ó, é), 3-byte (中文, ★), and 4-byte
    -- (🎉) runes. nvim's LSP client streams this as a didChange in
    -- UTF-16 units; the subsequent save's `text` payload must
    -- preserve every rune verbatim regardless of byte width.
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "// Función rota ★ 中文 🎉 — un café antes de cerrar la llave.",
      "export fn main() void = {",
      "\tlet x = 1;",
      "",
    })

    -- Real save. :write fires BufWritePost; nvim's LSP client hooks
    -- that autocmd and notifies textDocument/didSave.
    vim.cmd("silent write")

    -- didSave waits one event-loop tick after BufWritePost in some nvim
    -- builds; loop on a predicate rather than asserting immediately.
    local sent = vim.wait(2000, function() return did_save.saw() end, 25)
    assert(sent, "client did not send textDocument/didSave on :write")

    -- The didSave params must include the updated buffer text, because
    -- the server's textDocumentSync.save.includeText capability is on.
    local params = did_save.last_params()
    assert(type(params) == "table" and type(params.text) == "string",
      "didSave params should include `text` (includeText=true); got: "
      .. vim.inspect(params))
    assert(params.text:find("let x = 1") ~= nil,
      "didSave text should reflect the new buffer content; got: "
      .. tostring(params.text))
    -- Every byte-width of multi-byte rune must round-trip the
    -- BufWritePost / wire encoding intact. Checked individually so a
    -- width-specific bug (only 2-byte works, etc.) is visible.
    assert(params.text:find("Función", 1, true) ~= nil,
      "didSave text dropped 2-byte rune (ó); got: " .. tostring(params.text))
    assert(params.text:find("café", 1, true) ~= nil,
      "didSave text dropped 2-byte rune (é); got: " .. tostring(params.text))
    assert(params.text:find("★", 1, true) ~= nil,
      "didSave text dropped 3-byte rune (★); got: " .. tostring(params.text))
    assert(params.text:find("中文", 1, true) ~= nil,
      "didSave text dropped 3-byte CJK runes; got: " .. tostring(params.text))
    assert(params.text:find("🎉", 1, true) ~= nil,
      "didSave text dropped 4-byte rune (🎉); got: " .. tostring(params.text))

    -- The server consumes didSave by re-publishing diagnostics
    -- (bypassing the 300ms debounce). The broken file should now
    -- produce at least one diagnostic in vim.diagnostic.get.
    local ok, diags = lsp.wait_for_diagnostics(bufnr, function(d)
      return #d > 0
    end)
    assert(ok, "diagnostics did not re-publish after save; got: "
      .. vim.inspect(diags))
  end)
end)
