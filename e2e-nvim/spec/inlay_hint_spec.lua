-- SPDX-License-Identifier: MPL-2.0
-- (c) hare-lsp authors
--
-- Asks the server for inlay hints over an inferred-type binding. The
-- corresponding Hare-side e2e at e2e/inlayhints+test.ha covers the wire
-- format; this version covers the client-side request path that nvim
-- builds when `vim.lsp.inlay_hint` runs.

local lsp = require("helpers.lsp")

describe("inlay hints", function()
  local workspace

  before_each(function()
    -- The let binding is preceded ON THE SAME LINE by a const whose
    -- string literal mixes 4-byte UTF-8 runes (🎉/🔥, each a UTF-16
    -- surrogate pair, 2 code units) and 3-byte UTF-8 runes (中/文, each
    -- a single BMP UTF-16 code unit). This stresses the server's
    -- byte<->UTF-16 column math, which is where surrogate-pair bugs
    -- hide.
    workspace = lsp.mk_workspace("inlay_hint", {
      ["main.ha"] = table.concat({
        "// Π es una constante; abajo, un entero implícito 中文 mezcla.",
        "const PI_NAME: str = \"🎉🔥 中文\"; let g_x = 1;",
        "",
      }, "\n"),
    })
    -- Force UTF-16 negotiation. nvim's default capabilities offer
    -- utf-8/utf-16/utf-32 and the server prefers utf-8, which would
    -- mean position.character is a BYTE offset and surrogate-pair
    -- math never runs. Restricting to utf-16 makes the server use
    -- its byte->UTF-16 path.
    local caps = vim.lsp.protocol.make_client_capabilities()
    caps.general = caps.general or {}
    caps.general.positionEncodings = { "utf-16" }
    lsp.setup_plugin(workspace, { capabilities = caps })
  end)

  after_each(function()
    lsp.teardown()
    lsp.cleanup_workspace(workspace)
  end)

  it("returns a type hint for an inferred-type let binding", function()
    local bufnr = lsp.open_and_attach(workspace, "main.ha")

    local result = lsp.request_sync("textDocument/inlayHint", {
      textDocument = lsp.text_document(bufnr),
      range = {
        start = { line = 0, character = 0 },
        ["end"] = { line = 3, character = 0 },
      },
    }, bufnr)

    assert(type(result) == "table" and #result > 0,
      "expected at least one inlay hint; got: " .. vim.inspect(result))

    local int_hint
    for _, hint in ipairs(result) do
      local label = hint.label
      if type(label) == "table" then
        -- LSP allows label to be an InlayHintLabelPart[].
        local parts = {}
        for _, p in ipairs(label) do parts[#parts + 1] = p.value end
        label = table.concat(parts, "")
      end
      if type(label) == "string" and label:find("int") then
        int_hint = hint
        break
      end
    end
    assert(int_hint ~= nil,
      "expected an inferred-type hint containing `int`; got: "
      .. vim.inspect(result))

    -- The hint must anchor on LSP line 1 (the multi-decl line) right
    -- after `g_x`. Counting UTF-16 code units from the line start:
    --   "const PI_NAME: str = \""        → 22 code units
    --   "🎉" (surrogate pair)             → +2 = 24
    --   "🔥" (surrogate pair)             → +2 = 26
    --   " 中文"                            → +3 = 29
    --   "\"; let g_x"                    → +10 = 39
    -- So the hint anchors at character 39. A server that mis-counts
    -- surrogate pairs as 1 code unit would emit character 37; one
    -- that uses raw bytes would emit even higher.
    assert(int_hint.position.line == 1,
      "expected hint anchor on line 1 (the multi-decl line), got: "
      .. vim.inspect(int_hint.position))
    assert(int_hint.position.character == 39,
      "expected hint anchor at character 39 (after `g_x` in UTF-16 code "
      .. "units), got: " .. vim.inspect(int_hint.position))
  end)
end)
