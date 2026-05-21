-- SPDX-License-Identifier: MPL-2.0
-- (c) hare-lsp authors
--
-- Test helpers for the plenary e2e suite. The pattern mirrors
-- e2e/harness+test.ha: each spec creates its own scratch workspace
-- under `.tmp/e2e-nvim-<label>/`, starts the in-tree hare-lsp plugin
-- against that root, opens a fixture buffer, and asserts on LSP
-- responses. Specs MUST call `M.teardown()` in `after_each` so the
-- client process exits between tests.

local M = {}

local function script_dir()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(source, ":h")
end

M.repo_root = vim.fn.fnamemodify(script_dir(), ":h:h")

-- Path to the ./hare-lsp binary that all specs share. Mirrors the
-- existing Hare e2e harness's HARE_LSP_BIN convention so that
-- `make nvim-test` and ad-hoc invocations both work.
function M.bin_path()
  return vim.env.HARE_LSP_BIN or (M.repo_root .. "/hare-lsp")
end

-- Default wait timeouts. Generous enough for cold-cache CI containers.
M.ATTACH_TIMEOUT_MS = 10000
M.DIAGNOSTICS_TIMEOUT_MS = 5000
M.REQUEST_TIMEOUT_MS = 5000

-- Per-spec workspace under `.tmp/e2e-nvim-<label>/`. `files` is a
-- table of `{ [relpath] = contents }`. Returns the absolute path to
-- the new workspace root.
function M.mk_workspace(label, files)
  local dir = M.repo_root .. "/.tmp/e2e-nvim-" .. label
  vim.fn.delete(dir, "rf")
  vim.fn.mkdir(dir, "p")
  for relpath, contents in pairs(files or {}) do
    local full = dir .. "/" .. relpath
    vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
    local fd = assert(io.open(full, "wb"))
    fd:write(contents)
    fd:close()
  end
  return dir
end

function M.cleanup_workspace(dir)
  if dir and dir ~= "" then
    vim.fn.delete(dir, "rf")
  end
end

-- Sets up the in-tree hare-lsp plugin scoped to a given workspace
-- root. Subsequent calls clear the previous augroup (the plugin uses
-- `{ clear = true }` on its augroup), so this is safe to call
-- per-spec.
function M.setup_plugin(root_dir, extra_opts)
  local opts = vim.tbl_deep_extend("force", {
    cmd = { M.bin_path() },
    root_dir = root_dir,
  }, extra_opts or {})
  require("hare-lsp").setup(opts)
end

-- Opens a file under the workspace, waits for the LSP to attach.
-- Returns (bufnr, client_id).
function M.open_and_attach(workspace_dir, relpath)
  local full = workspace_dir .. "/" .. relpath
  vim.cmd("edit " .. vim.fn.fnameescape(full))
  local bufnr = vim.api.nvim_get_current_buf()
  local client = M.wait_for_attach(bufnr)
  return bufnr, client
end

function M.wait_for_attach(bufnr, timeout_ms)
  timeout_ms = timeout_ms or M.ATTACH_TIMEOUT_MS
  local ok = vim.wait(timeout_ms, function()
    return #vim.lsp.get_clients({ bufnr = bufnr, name = "hare-lsp" }) > 0
  end, 50)
  assert(ok, "hare-lsp did not attach to buffer within " .. timeout_ms .. "ms")
  local clients = vim.lsp.get_clients({ bufnr = bufnr, name = "hare-lsp" })
  return clients[1]
end

function M.wait_for_diagnostics(bufnr, predicate, timeout_ms)
  timeout_ms = timeout_ms or M.DIAGNOSTICS_TIMEOUT_MS
  predicate = predicate or function(d) return #d > 0 end
  local last
  local ok = vim.wait(timeout_ms, function()
    last = vim.diagnostic.get(bufnr)
    return predicate(last)
  end, 50)
  return ok, last or {}
end

-- Synchronous LSP request; asserts a response came back and returns
-- the first client's result (and any error). For the single-client
-- case this is all we ever want.
function M.request_sync(method, params, bufnr, timeout_ms)
  timeout_ms = timeout_ms or M.REQUEST_TIMEOUT_MS
  local results, err = vim.lsp.buf_request_sync(bufnr, method, params, timeout_ms)
  assert(results ~= nil, method .. " timed out after " .. timeout_ms .. "ms (err=" .. tostring(err) .. ")")
  for _, r in pairs(results) do
    if r.error then
      error(method .. " error: " .. vim.inspect(r.error))
    end
    return r.result, r
  end
  return nil, nil
end

function M.text_document(bufnr)
  return { uri = vim.uri_from_bufnr(bufnr) }
end

-- Returns a recorder that captures outgoing LSP notifications matching
-- `method`. nvim fires an `LspNotify` autocmd for each client.notify
-- call (see runtime/lua/vim/lsp/client.lua:Client:notify), so we hook
-- that to observe what the client actually sent. Call
-- `recorder.dispose()` in `after_each` to detach.
function M.notify_recorder(method)
  local seen = 0
  local last_params
  local autocmd_id = vim.api.nvim_create_autocmd("LspNotify", {
    callback = function(args)
      if args.data and args.data.method == method then
        seen = seen + 1
        last_params = args.data.params
      end
    end,
  })
  return {
    saw = function() return seen > 0 end,
    count = function() return seen end,
    last_params = function() return last_params end,
    dispose = function() vim.api.nvim_del_autocmd(autocmd_id) end,
  }
end

-- Stops every attached hare-lsp client and closes all buffers. Call
-- in `after_each` to give each spec a clean slate.
function M.teardown()
  for _, client in ipairs(vim.lsp.get_clients({ name = "hare-lsp" })) do
    client:stop(true)
  end
  vim.wait(2000, function()
    return #vim.lsp.get_clients({ name = "hare-lsp" }) == 0
  end, 50)
  vim.cmd("silent! %bwipeout!")
end

return M
