// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// e2e: drive the bundled neovim plugin (editors/nvim) in a real pseudo-
// terminal, open a `.ha` buffer, and confirm hare-lsp attaches.
//
// This is the only test that exercises the plugin end-to-end. Unit
// tests can't reach it because the plugin is Lua running inside
// neovim. A pty is required because neovim refuses to enter its TUI
// mode if stdin/stdout aren't ttys; without a pty we'd be testing
// `nvim --headless`, which takes a different code path that doesn't
// trigger the `FileType` autocmd our plugin relies on.
//
// The test is skipped (printed as a notice, not a failure) when:
//   - `nvim` is not on $PATH (CI without neovim installed).
//   - The `./hare-lsp` binary isn't where we expect it.

use fmt;
use fs;
use io;
use os;
use os::exec;
use strings;
use time;
use unix::poll;
use unix::signal;
use unix::tty;

// Paths under .tmp/ are unique to this test so concurrent runs of
// other tests don't collide.
def NVIM_INIT_PATH: str = ".tmp/hare-lsp-nvim-pty-init.lua";

def NVIM_BUFFER_PATH: str = ".tmp/hare-lsp-nvim-pty-buffer.ha";

def NVIM_SENTINEL_PATH: str = ".tmp/hare-lsp-nvim-pty-sentinel.txt";

def NVIM_SENTINEL_TMP: str = ".tmp/hare-lsp-nvim-pty-sentinel.tmp";

// The init.lua loaded inside neovim. It:
//   1. Prepends the in-tree plugin directory to runtimepath so
//      `require('hare-lsp')` resolves to editors/nvim/lua/hare-lsp.
//   2. Points the plugin at the in-tree `./hare-lsp` binary so the
//      test doesn't depend on a global install.
//   3. Registers an `LspAttach` autocmd that, on attach, issues a
//      synchronous `textDocument/hover` through the plugin and writes
//      a sentinel reflecting whether the round trip succeeded.
//   4. Sets a deferred fallback that writes "TIMEOUT" and quits if no
//      LspAttach fires within the budget.
//
// Sentinel values:
//   ATTACHED:<client-name>          attach + hover round-trip succeeded
//   HOVER_FAILED:<client>:<reason>  attached but the hover request errored
//   REQUIRE_FAILED:<err>            require('hare-lsp') threw
//   TIMEOUT                         neither attach nor failure within budget
//
// The sentinel is written to a temp path and renamed into place so
// the test never observes a partial file.
const NVIM_INIT_LUA: str =
	`-- hare-lsp e2e pty harness init.lua.
local cwd = vim.fn.getcwd()
vim.opt.runtimepath:prepend(cwd .. "/editors/nvim")

local sentinel = cwd .. "/.tmp/hare-lsp-nvim-pty-sentinel.txt"
local sentinel_tmp = cwd .. "/.tmp/hare-lsp-nvim-pty-sentinel.tmp"
local function write_sentinel(payload)
  local f = io.open(sentinel_tmp, "w")
  if not f then return end
  f:write(payload)
  f:close()
  os.rename(sentinel_tmp, sentinel)
end

local ok, plugin = pcall(require, "hare-lsp")
if not ok then
  write_sentinel("REQUIRE_FAILED:" .. tostring(plugin))
  vim.cmd("qa!")
  return
end

-- Pin root_dir to the buffer's parent directory. The plugin's default
-- walks up looking for .git / Makefile, which under make-test lands
-- on the repo root and pulls every .ha file in the repo into the
-- server's workspace scan. That scan races against the synchronous
-- hover round-trip below, especially when the e2e suite's seven
-- parallel shards have the machine under load. Pinning the root keeps
-- this test independent of the surrounding repo's size.
plugin.setup({
  cmd = { cwd .. "/hare-lsp" },
  root_dir = function(bufnr)
    local fname = vim.api.nvim_buf_get_name(bufnr)
    return vim.fn.fnamemodify(fname, ":h")
  end,
})

vim.api.nvim_create_autocmd("LspAttach", {
  callback = function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)
    local name = client and client.name or "?"
    if name ~= "hare-lsp" then return end
    -- Confirm the plugin can actually round-trip a request. Position
    -- 0:11 lands on "main" in the test buffer; the LSP server has to
    -- be alive and parsing the document for a non-error response.
    -- The timeout is generous (15s) because the server may still be
    -- draining its initial stdlib-indexing batches when the hover
    -- arrives, and a tight 5s budget tripped under parallel-shard
    -- load on CI.
    local params = {
      textDocument = { uri = vim.uri_from_bufnr(args.buf) },
      position = { line = 0, character = 11 },
    }
    local result, err = vim.lsp.buf_request_sync(
      args.buf, "textDocument/hover", params, 15000)
    if err or not result then
      write_sentinel("HOVER_FAILED:" .. name .. ":" .. tostring(err))
      vim.defer_fn(function() vim.cmd("qa!") end, 50)
      return
    end
    local entry = result[args.data.client_id]
    if not entry then
      write_sentinel("HOVER_FAILED:" .. name .. ":no_response_from_client")
      vim.defer_fn(function() vim.cmd("qa!") end, 50)
      return
    end
    -- Newer neovim uses .error, older versions .err; tolerate both.
    local entry_err = entry.error or entry.err
    if entry_err then
      write_sentinel("HOVER_FAILED:" .. name .. ":" .. tostring(entry_err))
      vim.defer_fn(function() vim.cmd("qa!") end, 50)
      return
    end
    write_sentinel("ATTACHED:" .. name)
    vim.defer_fn(function() vim.cmd("qa!") end, 50)
  end,
})

-- Outer fallback. Must outlast the buf_request_sync timeout above so
-- a slow hover lands as HOVER_FAILED rather than TIMEOUT.
vim.defer_fn(function()
  write_sentinel("TIMEOUT")
  vim.cmd("qa!")
end, 25000)
`;

// A trivially-parseable Hare buffer. The exact contents don't matter -
// we only need the file to exist and have the `.ha` extension so the
// plugin's FileType autocmd fires.
const NVIM_BUFFER_HA: str = `export fn main() void = void;
`;

@test fn e2e_neovim_plugin_attaches() void = {
	if (!have_executable("nvim")) {
		fmt::println("[skip] e2e_neovim_plugin_attaches: nvim not on $PATH")!;
		return;
	};
	if (!os::exists("./hare-lsp")) {
		fmt::println("[skip] e2e_neovim_plugin_attaches: ./hare-lsp not built")!;
		return;
	};

	ensure_tmp_dir();

	// Truncate the sentinel from any prior run.
	const _ = os::remove(NVIM_SENTINEL_PATH);
	const _ = os::remove(NVIM_SENTINEL_TMP);

	write_file(NVIM_INIT_PATH, NVIM_INIT_LUA);
	defer {
		const _ = os::remove(NVIM_INIT_PATH);
	};
	write_file(NVIM_BUFFER_PATH, NVIM_BUFFER_HA);
	defer {
		const _ = os::remove(NVIM_BUFFER_PATH);
	};

	const (master, slave) = match (tty::openpty()) {
	case let p: (io::file, io::file) =>
		yield p;
	case let e: fs::error =>
		fmt::fatalf("e2e: openpty failed: {}", fs::strerror(e));
	};
	defer {
		const _ = io::close(master);
	};

	const _ = tty::set_winsize(slave,
		tty::ttysize {
			rows = 24,
			columns = 80,
		});

	let cmd = match (exec::cmd("nvim", "--clean", "-u", NVIM_INIT_PATH,
		NVIM_BUFFER_PATH)) {
	case let c: exec::command =>
		yield c;
	case let e: exec::error =>
		io::close(slave)!;
		fmt::fatalf("e2e: cannot prepare nvim: {}", exec::strerror(e));
	case nomem =>
		io::close(slave)!;
		abort("e2e: nomem preparing nvim command");
	};
	// Force TERM to something simple so nvim doesn't fail on a
	// missing terminfo entry inside an unusual test environment.
	exec::setenv(&cmd, "TERM", "xterm-256color")!;

	exec::addfile(&cmd, os::stdin_file, slave)!;
	exec::addfile(&cmd, os::stdout_file, slave)!;
	exec::addfile(&cmd, os::stderr_file, slave)!;

	const proc = match (exec::start(&cmd)) {
	case let p: exec::process =>
		yield p;
	case let e: exec::error =>
		io::close(slave)!;
		fmt::fatalf("e2e: cannot start nvim: {}", exec::strerror(e));
	};

	// nvim owns the slave now.
	io::close(slave)!;

	// Outer budget covers the lua fallback (25s) plus a small margin
	// so we always observe a sentinel rather than killing nvim mid-
	// write.
	const sentinel = wait_for_sentinel(master, 30 * time::SECOND);

	// Best-effort cleanup. nvim should have exited via `qa!`; if
	// it hasn't, SIGTERM it.
	match (exec::peek(&proc)) {
	case exec::status => void;
	case (void | exec::error) =>
		const _ = exec::sig(proc, signal::sig::TERM);
		time::sleep(200 * time::MILLISECOND);
		match (exec::peek(&proc)) {
		case exec::status => void;
		case (void | exec::error) =>
			const _ = exec::sig(proc, signal::sig::KILL);
			const _ = exec::wait(&proc);
		};
	};
	const _ = os::remove(NVIM_SENTINEL_PATH);
	const _ = os::remove(NVIM_SENTINEL_TMP);

	if (strings::hasprefix(sentinel, "HOVER_FAILED:")) {
		// Attach succeeded but the synchronous hover did not round
		// trip through the plugin. The sentinel carries the underlying
		// error so the failure mode is visible in CI output.
		fmt::fatalf("e2e: hover round trip through plugin failed: {}", sentinel);
	};
	if (!strings::hasprefix(sentinel, "ATTACHED:")) {
		fmt::fatalf("e2e: expected ATTACHED sentinel, got: {}", sentinel);
	};
	// The attached client must be the one our plugin registers.
	const name = strings::sub(sentinel, len("ATTACHED:"), strings::end);
	assert(name == "hare-lsp", "e2e: LspAttach fired for an unexpected client");

	free(sentinel);
};

// Polls the sentinel file every 100ms while opportunistically
// draining the pty master so neovim doesn't stall on a full pipe.
// We use unix::poll with a short timeout instead of a blocking read
// so the loop can re-check the sentinel even if neovim emits no
// terminal output. Fails the test on timeout.
fn wait_for_sentinel(master: io::file, total: time::duration) str = {
	const deadline = time::add(time::now(time::clock::MONOTONIC), total);
	let chunk: [4096]u8 = [0...];

	for (true) {
		const now = time::now(time::clock::MONOTONIC);
		if (time::compare(now, deadline) >= 0) {
			fmt::fatalf("e2e: timed out waiting for nvim sentinel at {}",
				NVIM_SENTINEL_PATH);
		};

		// Drain whatever bytes are queued on the master so neovim
		// keeps making progress. 100ms poll timeout doubles as our
		// sentinel-poll cadence.
		let pfd: [_]poll::pollfd = [
			poll::pollfd {
				fd = master,
				events = poll::event::POLLIN,
				revents = 0,
			},
		];
		const ready = match (poll::poll(pfd, 100 * time::MILLISECOND)) {
		case let n: uint =>
			yield n;
		case poll::error =>
			yield 0u;
		};
		if (ready > 0) {
			match (io::read(master, chunk[..])) {
			case size => void;
			case io::EOF => void;
			case io::error => void;
			};
		};

		match (read_sentinel()) {
		case let s: str =>
			return s;
		case void => void;
		};
	};
};

// Reads the sentinel file if present. Returns void if it doesn't
// exist yet (the file is renamed in atomically by the lua side, so
// we never observe partial content).
fn read_sentinel() (str | void) = {
	const f = match (os::open(NVIM_SENTINEL_PATH)) {
	case let f: io::file =>
		yield f;
	case fs::error =>
		return;
	};
	defer io::close(f)!;
	let buf: [256]u8 = [0...];
	const n = match (io::read(f, buf[..])) {
	case let n: size =>
		yield n;
	case io::EOF =>
		yield 0z;
	case io::error =>
		return;
	};
	const s = match (strings::fromutf8(buf[..n])) {
	case let s: str =>
		yield s;
	case =>
		return;
	};
	const trimmed = strings::trim(s);
	if (len(trimmed) == 0) return;
	return strings::dup(trimmed)!;
};

fn have_executable(name: str) bool = {
	match (exec::lookup(name)) {
	case str =>
		return true;
	case fs::error =>
		return false;
	};
};

fn ensure_tmp_dir() void = {
	match (os::mkdirs(".tmp", 0o755: fs::mode)) {
	case void => void;
	case fs::error => void;
	};
};

fn write_file(path: str, body: str) void = {
	const f = match (os::create(path, 0o644: fs::mode)) {
	case let f: io::file =>
		yield f;
	case let e: fs::error =>
		fmt::fatalf("e2e: cannot create {}: {}", path, fs::strerror(e));
	};
	defer io::close(f)!;
	match (io::writeall(f, strings::toutf8(body))) {
	case size => void;
	case let e: io::error =>
		fmt::fatalf("e2e: cannot write {}: {}", path, io::strerror(e));
	};
};
