-- SPDX-License-Identifier: MPL-2.0
-- (c) hare-lsp authors
--
-- :checkhealth hare-lsp provider.
--
-- Verifies the environment hare-lsp needs to run: the server binary
-- itself, the `hare` toolchain it shells out to, and a usable
-- HAREPATH for module resolution.

local M = {}

local health = vim.health or require("health")
local h_start = health.start or health.report_start
local h_ok = health.ok or health.report_ok
local h_warn = health.warn or health.report_warn
local h_error = health.error or health.report_error
local h_info = health.info or health.report_info

local DEFAULT_STDLIB = "/usr/local/src/hare/stdlib"
local DEFAULT_THIRDPARTY = "/usr/local/src/hare/third-party"

local function is_dir(path)
  return path ~= "" and vim.fn.isdirectory(path) == 1
end

local function trim(s)
  return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function check_server_binary()
  if vim.fn.executable("hare-lsp") == 1 then
    local path = trim(vim.fn.exepath("hare-lsp"))
    h_ok(string.format("`hare-lsp` found at %s", path))
  else
    h_error(
      "`hare-lsp` not found on $PATH",
      { "Build with `make` in the hare-lsp repo and `sudo make install`, "
        .. "or set `cmd` in setup() to an absolute path." }
    )
  end
end

local function check_hare_binary()
  if vim.fn.executable("hare") == 1 then
    local path = trim(vim.fn.exepath("hare"))
    local version = trim(vim.fn.system({ "hare", "version" }))
    if vim.v.shell_error == 0 and version ~= "" then
      h_ok(string.format("`hare` found at %s (%s)", path, version))
    else
      h_warn(string.format("`hare` found at %s but `hare version` failed", path))
    end
  else
    h_error(
      "`hare` not found on $PATH",
      { "Install Hare from https://harelang.org/. The language server "
        .. "shells out to `hare build` for type-check diagnostics." }
    )
  end
end

local function check_harepath()
  local harepath = vim.env.HAREPATH or ""
  local entries = {}
  if harepath ~= "" then
    for entry in string.gmatch(harepath, "[^:]+") do
      table.insert(entries, entry)
    end
  end

  if #entries == 0 then
    if is_dir(DEFAULT_STDLIB) then
      h_ok(string.format("HAREPATH unset; default stdlib %s exists", DEFAULT_STDLIB))
    else
      h_warn(
        "HAREPATH unset and default stdlib " .. DEFAULT_STDLIB .. " not found",
        { "Set HAREPATH or point `hare.harepath` in setup() at your stdlib." }
      )
    end
    if not is_dir(DEFAULT_THIRDPARTY) then
      h_info("Optional third-party path " .. DEFAULT_THIRDPARTY .. " not found")
    end
    return
  end

  local any_ok = false
  for _, entry in ipairs(entries) do
    if is_dir(entry) then
      h_ok(string.format("HAREPATH entry exists: %s", entry))
      any_ok = true
    else
      h_warn(string.format("HAREPATH entry does not exist: %s", entry))
    end
  end
  if not any_ok then
    h_error("No HAREPATH entry resolves to an existing directory")
  end
end

local function check_log_dir()
  local log_dir = vim.env.HARE_LSP_LOG_DIR
  if not log_dir or log_dir == "" then
    h_info("HARE_LSP_LOG_DIR unset (wire-protocol logging disabled)")
    return
  end
  if not vim.startswith(log_dir, "/") then
    h_warn(
      "HARE_LSP_LOG_DIR is not absolute: " .. log_dir,
      { "The server is often spawned with cwd=/; use an absolute path." }
    )
    return
  end
  if not is_dir(log_dir) then
    h_warn("HARE_LSP_LOG_DIR does not exist: " .. log_dir)
    return
  end
  if vim.fn.filewritable(log_dir) ~= 2 then
    h_warn("HARE_LSP_LOG_DIR is not writable: " .. log_dir)
    return
  end
  h_ok("HARE_LSP_LOG_DIR writable: " .. log_dir)
end

function M.check()
  h_start("hare-lsp: dependencies")
  check_server_binary()
  check_hare_binary()

  h_start("hare-lsp: module path")
  check_harepath()

  h_start("hare-lsp: optional environment")
  check_log_dir()
end

return M
