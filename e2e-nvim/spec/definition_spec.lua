-- SPDX-License-Identifier: MPL-2.0
-- (c) hare-lsp authors

local lsp = require("helpers.lsp")

describe("definition", function()
  local workspace

  before_each(function()
    -- Leading doc comments contain multi-byte runes (ñ, π); the parser
    -- emits rune offsets and analysis/loc_fixup.ha translates to bytes.
    -- A regression there would skew the cross-file lookup, since the
    -- workspace_index keys off byte-correct positions.
    workspace = lsp.mk_workspace("definition", {
      ["a.ha"] = table.concat({
        "// Devuelve un número entero.",
        "export fn shared_helper() int = 7;",
        "",
      }, "\n"),
      ["b.ha"] = table.concat({
        "// Llama a shared_helper desde otro módulo (π puede aparecer aquí).",
        "export fn caller() int = shared_helper();",
        "",
      }, "\n"),
    })
    lsp.setup_plugin(workspace)
  end)

  after_each(function()
    lsp.teardown()
    lsp.cleanup_workspace(workspace)
  end)

  it("jumps from a call site in one file to the definition in another", function()
    local bufnr = lsp.open_and_attach(workspace, "b.ha")

    -- `caller` lives on nvim line 2 (after the line 1 doc comment).
    -- `export fn caller() int = shared_helper();`
    -- 'shared_helper' starts at 1-indexed col 26 (0-indexed 25).
    vim.api.nvim_win_set_cursor(0, { 2, 25 })

    -- Workspace indexing is async; retry until the cross-file lookup
    -- resolves. Each iteration is a fresh request_sync.
    local resolved
    local ok = vim.wait(5000, function()
      local result = lsp.request_sync(
        "textDocument/definition",
        vim.lsp.util.make_position_params(0, "utf-16"),
        bufnr
      )
      if result == nil then return false end
      -- LSP allows Location, Location[], or LocationLink[]. Normalize.
      local loc
      if result.uri then
        loc = { uri = result.uri, range = result.range }
      elseif result[1] then
        local first = result[1]
        if first.uri then
          loc = { uri = first.uri, range = first.range }
        elseif first.targetUri then
          loc = { uri = first.targetUri, range = first.targetSelectionRange or first.targetRange }
        end
      end
      if loc and loc.uri and loc.uri:find("a%.ha$") then
        resolved = loc
        return true
      end
      return false
    end, 100)

    assert(ok,
      "definition did not resolve to a.ha within 5s; last result: "
      .. vim.inspect(resolved))

    -- `shared_helper` lives on LSP line 1 of a.ha (the doc comment is
    -- line 0). hare-lsp returns a Location whose range covers the
    -- whole decl, which is LSP-valid; the spec allows either
    -- decl-span or identifier-span. We only assert the start line,
    -- which catches the "right file, wrong line" regression class
    -- without locking us to one of the two valid range shapes.
    assert(resolved.range ~= nil, "resolved Location must include a range")
    assert(resolved.range.start.line == 1,
      "expected definition on line 1 of a.ha, got: "
      .. vim.inspect(resolved.range))
  end)
end)
