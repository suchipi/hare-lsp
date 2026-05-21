-- SPDX-License-Identifier: MPL-2.0
-- (c) hare-lsp authors
--
-- Exercises the publishDiagnostics push path AND the client-side
-- consumption: diagnostics must end up in `vim.diagnostic.get(bufnr)`,
-- not just on the wire.

local lsp = require("helpers.lsp")

describe("diagnostics", function()
  local workspace

  before_each(function()
    -- Doc comment carries multi-byte runes (ó, á, ú) BEFORE the broken
    -- body. The diagnostic range must point at the right LSP position
    -- (per-line UTF-16 column count, not byte count). If the server
    -- mis-counts code units, the diagnostic ends up on the wrong line.
    workspace = lsp.mk_workspace("diagnostics", {
      ["broken.ha"] = table.concat({
        "// Función rota: falta la llave de cierre.",
        "export fn main() void = {",
        "\tlet x = 1;",
        "",
      }, "\n"),
    })
    lsp.setup_plugin(workspace)
  end)

  after_each(function()
    lsp.teardown()
    lsp.cleanup_workspace(workspace)
  end)

  it("populates vim.diagnostic.get after didOpen of a broken file", function()
    local bufnr = lsp.open_and_attach(workspace, "broken.ha")

    local ok, diags = lsp.wait_for_diagnostics(bufnr, function(d)
      return #d > 0
    end)

    assert(ok, "no diagnostics arrived within timeout; got: "
      .. vim.inspect(diags))

    local d0 = diags[1]
    -- Parse error => severity 1 (Error) per LSP. nvim's vim.diagnostic
    -- uses 1=ERROR / 2=WARN / 3=INFO / 4=HINT (same numbering as LSP
    -- DiagnosticSeverity).
    assert(d0.severity == vim.diagnostic.severity.ERROR,
      "expected severity=ERROR, got: " .. vim.inspect(d0))
    assert(type(d0.message) == "string" and #d0.message > 0,
      "diagnostic message must be a non-empty string; got: "
      .. vim.inspect(d0))
    -- The fixture is 4 lines (0=doc comment, 1=open brace, 2=let,
    -- 3=blank). The parse error lives between the open brace and EOF.
    -- nvim's vim.diagnostic uses 0-based line numbers in `lnum`.
    assert(d0.lnum >= 1 and d0.lnum <= 3,
      "diagnostic line must be within the broken body (1..3), got: "
      .. tostring(d0.lnum))
  end)
end)
