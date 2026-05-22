-- SPDX-License-Identifier: MPL-2.0
-- (c) hare-lsp authors
--
-- Exercises the `.` trigger character path that the synthetic Hare-side
-- e2e cannot cover: a real LSP client sets `context.triggerKind=2` and
-- `context.triggerCharacter="."` when the trigger fires.
--
-- Mirrors server/completion_test+test.ha::completion_struct_field_via_function_param,
-- which is the canonical "completion after `.`" shape the server expects.

local lsp = require("helpers.lsp")

describe("completion", function()
  local workspace

  before_each(function()
    -- Leading doc comment carries multi-byte runes (á, ñ). The
    -- completion lookup resolves `b`'s receiver type and enumerates
    -- struct members; if loc_fixup is wrong, the type lookup falls
    -- through and we'd see no items at all.
    workspace = lsp.mk_workspace("completion", {
      ["main.ha"] = table.concat({
        "// Función con parámetro de tipo estructura anónima.",
        "fn main(b: struct { x: int, y: int }) void = {",
        "\tb.",
        "};",
        "",
      }, "\n"),
    })
    lsp.setup_plugin(workspace)
  end)

  after_each(function()
    lsp.teardown()
    lsp.cleanup_workspace(workspace)
  end)

  it("returns struct fields after `.` trigger", function()
    local bufnr = lsp.open_and_attach(workspace, "main.ha")

    -- Without virtualedit, nvim clamps cursor to the last byte of the
    -- line, which would land us ON the dot (char 2) rather than just
    -- past it (char 3). The position past the dot is what a real LSP
    -- client constructs when the trigger fires after the user types
    -- `.` in insert mode, so we set it explicitly. `\tb.` is on LSP
    -- line 2 (after the doc comment and the fn signature).
    local params = {
      textDocument = lsp.text_document(bufnr),
      position = { line = 2, character = 3 },
      context = {
        triggerKind = 2,
        triggerCharacter = ".",
      },
    }

    local result = lsp.request_sync("textDocument/completion", params, bufnr)
    assert(result ~= nil, "completion returned nil")

    local items = result.items or result
    assert(type(items) == "table" and #items > 0,
      "completion must return at least one item; got: " .. vim.inspect(result))

    local by_label = {}
    for _, item in ipairs(items) do
      by_label[item.label] = item
    end
    assert(by_label["x"] and by_label["y"],
      "expected both `x` and `y` in completion items, got labels: "
      .. vim.inspect(vim.tbl_keys(by_label)))

    -- Struct-field completions must carry CompletionItemKind=Field (5).
    -- A regression that returns these as Text (1) or Variable (6) would
    -- render the wrong icon in the editor.
    for _, name in ipairs({ "x", "y" }) do
      assert(by_label[name].kind == 5,
        "expected kind=Field(5) for `" .. name .. "`, got: "
        .. tostring(by_label[name].kind))
    end
  end)
end)
