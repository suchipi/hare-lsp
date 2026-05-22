-- SPDX-License-Identifier: MPL-2.0
-- (c) hare-lsp authors
--
-- Asks the server for inlay hints over an inferred-type binding. The
-- fixture mixes 3-byte (中/文) and 4-byte (🎉/🔥) UTF-8 runes on the same
-- line as `let g_x`, so the hint's `position.character` depends on how
-- the server counts code units. We assert under BOTH negotiated
-- position encodings:
--
--   * UTF-16: the LSP default and what vscode-languageclient
--     hardcodes. Surrogate pairs (🎉/🔥) are 2 code units each.
--   * UTF-8:  what nvim's default capabilities elicit from the server
--     (which prefers utf-8 when the client offers it). Each rune
--     counts as its UTF-8 byte width (1/2/3/4).
--
-- Catching both regimes matters because nvim users run UTF-8 in
-- practice; a server bug in the UTF-8 byte path would slip through
-- if we only tested UTF-16.

local lsp = require("helpers.lsp")

local FIXTURE = table.concat({
  "// Π es una constante; abajo, un entero implícito 中文 mezcla.",
  "const PI_NAME: str = \"🎉🔥 中文\"; let g_x = 1;",
  "",
}, "\n")

-- Returns the `int` hint, asserting its line is the multi-decl one
-- and that exactly one matching hint was found in `result`.
local function find_int_hint(result)
  assert(type(result) == "table" and #result > 0,
    "expected at least one inlay hint; got: " .. vim.inspect(result))
  for _, hint in ipairs(result) do
    local label = hint.label
    if type(label) == "table" then
      local parts = {}
      for _, p in ipairs(label) do parts[#parts + 1] = p.value end
      label = table.concat(parts, "")
    end
    if type(label) == "string" and label:find("int") then
      return hint
    end
  end
  error("expected an inferred-type hint containing `int`; got: "
    .. vim.inspect(result))
end

local function request_inlay_hints(bufnr)
  return lsp.request_sync("textDocument/inlayHint", {
    textDocument = lsp.text_document(bufnr),
    range = {
      start = { line = 0, character = 0 },
      ["end"] = { line = 3, character = 0 },
    },
  }, bufnr)
end

describe("inlay hints (utf-16 negotiation)", function()
  local workspace

  before_each(function()
    workspace = lsp.mk_workspace("inlay_hint_utf16", { ["main.ha"] = FIXTURE })
    -- Restrict positionEncodings to utf-16 so the server picks the
    -- UTF-16 byte<->code-unit path. Without this nvim's default offer
    -- (utf-8/utf-16/utf-32) makes the server pick utf-8 instead.
    local caps = vim.lsp.protocol.make_client_capabilities()
    caps.general = caps.general or {}
    caps.general.positionEncodings = { "utf-16" }
    lsp.setup_plugin(workspace, { capabilities = caps })
  end)

  after_each(function()
    lsp.teardown()
    lsp.cleanup_workspace(workspace)
  end)

  it("hint anchors at UTF-16 character 39 (surrogate pairs count as 2)", function()
    local bufnr = lsp.open_and_attach(workspace, "main.ha")
    local int_hint = find_int_hint(request_inlay_hints(bufnr))

    -- Counting UTF-16 code units from the start of line 1:
    --   "const PI_NAME: str = \""        → 22 code units
    --   "🎉" (surrogate pair, +2)        → 24
    --   "🔥" (surrogate pair, +2)        → 26
    --   " 中文" (BMP, +3)                 → 29
    --   "\"; let g_x" (+10)              → 39
    assert(int_hint.position.line == 1,
      "expected hint anchor on line 1 (the multi-decl line), got: "
      .. vim.inspect(int_hint.position))
    assert(int_hint.position.character == 39,
      "expected hint anchor at character 39 (UTF-16 code units), got: "
      .. vim.inspect(int_hint.position))
  end)
end)

describe("inlay hints (utf-8 negotiation, nvim default)", function()
  local workspace

  before_each(function()
    workspace = lsp.mk_workspace("inlay_hint_utf8", { ["main.ha"] = FIXTURE })
    -- No capability override: nvim's default `positionEncodings`
    -- offer is utf-8/utf-16/utf-32 and the server prefers utf-8. This
    -- is the encoding nvim users get in practice, so we test it
    -- directly.
    lsp.setup_plugin(workspace)
  end)

  after_each(function()
    lsp.teardown()
    lsp.cleanup_workspace(workspace)
  end)

  it("hint anchors at UTF-8 byte 47 (each rune counts as its byte width)", function()
    local bufnr = lsp.open_and_attach(workspace, "main.ha")
    local int_hint = find_int_hint(request_inlay_hints(bufnr))

    -- Counting UTF-8 bytes from the start of line 1:
    --   "const PI_NAME: str = \""        → 22 bytes
    --   "🎉" (4-byte UTF-8, +4)          → 26
    --   "🔥" (4-byte UTF-8, +4)          → 30
    --   " " (+1)                         → 31
    --   "中" (3-byte UTF-8, +3)          → 34
    --   "文" (3-byte UTF-8, +3)          → 37
    --   "\"; let g_x" (+10)              → 47
    assert(int_hint.position.line == 1,
      "expected hint anchor on line 1 (the multi-decl line), got: "
      .. vim.inspect(int_hint.position))
    assert(int_hint.position.character == 47,
      "expected hint anchor at byte 47 (UTF-8 byte offset), got: "
      .. vim.inspect(int_hint.position))
  end)
end)
