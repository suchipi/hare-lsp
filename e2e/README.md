# e2e tests

End-to-end tests for hare-lsp. Each test spawns the real `./hare-lsp` binary
over OS pipes, exchanges framed JSON-RPC messages, and tears the process down.
The harness exists to catch regressions unit tests can't reach — most notably
anything tied to the real `os::stdout` (a buffered handle that historically
caused the server to silently sit on its `initialize` response while clients
timed out).

## Running

```sh
make hare-lsp          # build the binary the tests need
make test              # runs unit + e2e in parallel shards
```

To run a single e2e test:

```sh
HAREPATH="$PWD:/usr/local/src/hare/third-party:/usr/local/src/hare/stdlib" \
  HARECACHE="$PWD/.cache" \
  hare test e2e_initialize_returns_response e2e
```

The trailing `e2e` after the test name is the module — the e2e suite lives in
its own Hare module so the build tag scopes test code to test builds.

## Adding a new test

Drop a new `@test fn e2e_<feature>_<scenario>()` into the file that owns the
feature (or add a new `<feature>+test.ha` file). The minimum shape:

```hare
@test fn e2e_my_feature_does_thing() void = {
    let s = spawn_session();
    defer finish_session(&s);
    do_init(&s);

    open_doc(&s, "file:///x.ha", "export fn main() void = void;\n");

    const id = next_id(&s);
    const req = make_request("textDocument/myFeature", id,
        `{"textDocument":{"uri":"file:///x.ha"}}`);
    defer free(req);
    send(&s, strings::toutf8(req));

    const body = wait_for_response(&s, id);
    defer free(body);
    const v = json::loadstr(strings::fromutf8(body)!)!;
    defer json::finish(v);
    const obj = v as json::object;
    const result = field_object(&obj, "result");
    // assert against the result here
};
```

## Harness helpers

All cross-test helpers live in [harness+test.ha](harness+test.ha). If you need
a helper in more than one file, move it there rather than copying it locally.

### Session lifecycle

- `spawn_session() session` — fresh server process with pipes wired up. By
  default no log dir is set; setting `E2E_LOG_DIR=<basedir>` in the test
  runner's environment opts every session in to per-session log dirs under
  `<basedir>/session-<n>/`.
- `spawn_session_with_env([(key, value), ...]) session` — same, but with
  extra env vars applied to the child (e.g. `HARE_LSP_MAX_BODY_BYTES`).
- `spawn_session_with_logs(label) session` — always tees this session's
  wire traffic into `.tmp/e2e-logs/<label>/{in,out,err}.log`, regardless
  of `E2E_LOG_DIR`. A small hand-picked set of tests use this so the
  log-dir codepath is exercised on every `make test` run (see "Opted-in
  log-capture tests" below). The `label` must be unique among the
  opted-in set so parallel shards don't collide.
- `finish_session(*session) void` — closes pipes, SIGTERM then SIGKILL the
  child if needed. Always `defer` this immediately after spawning.
- `assert_clean_exit(*session, duration) void` — poll-waits for the child
  to exit and fails the test if it didn't exit cleanly within the deadline.

### Wire framing

- `send(*session, []u8) void` — writes a framed LSP message.
- `recv(*session) []u8` — reads a framed message; fatals on timeout
  (default 5 s). Caller frees.
- `recv_with_deadline(*session, duration) ([]u8 | void)` — soft variant.
  Returns void on timeout, used by tests that need to assert silence.
- `expect_no_message(*session, duration) void` — drains and fatals if a
  message arrives within the window. Use for cancellation, debounce, or
  shutdown-quiet-period tests.

### Request building

- `next_id(*session) f64` — allocates the next per-session JSON-RPC id.
- `make_request(method, id, params_json) str` / `make_notification(method,
  params_json) str` — splice params into a framed request body. Caller
  frees. `params_json` is spliced as-is (must already be valid JSON).
- `build_did_open(uri, body) str` — builds a `textDocument/didOpen`
  notification body. Caller frees.

### Lifecycle helpers

- `do_init(*session) void` — minimal `initialize` + `initialized`.
- `do_init_with_workspace(*session, root_path) void` — initialize with
  `rootUri` and `workspaceFolders[0].uri` set to `file://<root>`. Use this
  for tests that rely on the workspace index.
- `open_doc(*session, uri, body) void` — convenience around `build_did_open`
  + `send`.

### Response waiters

- `wait_for_response(*session, id) []u8` — reads frames until the response
  with the given id arrives, ignoring everything else. Caller frees.
- `wait_for_publish_diagnostics(*session, uri) []u8` — reads until a
  `textDocument/publishDiagnostics` for `uri` arrives. Caller frees.
- `parse_publish_diagnostics([]u8) (json::value, []json::value)` — splits
  the parsed root from the borrowed diagnostics slice. Caller calls
  `json::finish(root)` when done; the diagnostics slice becomes invalid
  at that point.
- `drain_until_indexed(*session) void` / `drain_until_indexed_ref(*session)
  void` — drain log messages until the server announces "indexed N file(s)".
  The first variant fatals on timeout; the second tolerates silence and
  silently returns. Both are typically called after `do_init_with_workspace`;
  pick the silent variant when the test is willing to proceed even if the
  index never finishes within the recv budget (e.g. a small fixture where
  the indexing notification might race with the first feature request).

### JSON inspection

Prefer the typed `field_*` helpers over inline `*(json::get(...) as ...)`
pipelines — a regression that drops a field or changes its type surfaces
as a helpful "field `x` is not an object" rather than as a generic panic.

- `field(obj, key) json::value` / `has_field(obj, key) bool` — base form.
- `field_object(obj, key) json::object`
- `field_array(obj, key) []json::value`
- `field_string(obj, key) str`
- `field_number(obj, key) f64`

### Workspace setup

- `make_workspace(label, [(relative_path, body), ...]) str` — creates a
  workspace under `.tmp/e2e-<label>/`, writes the files (creating
  subdirectories as needed), returns the absolute root. Caller defers
  `cleanup_workspace`.
- `cleanup_workspace(root) void` — `rmdirall`, tolerant of a missing dir.
- `write_test_file(path, body) void` — single-file write, fatals on
  I/O error. Used by `make_workspace`; reach for it directly when you
  need to drop a file outside the make_workspace shape (e.g.
  didChangeWatchedFiles fixtures).

## Conventions

### Process isolation

Every `@test fn` gets its own server process. Don't share sessions between
tests; spawn fresh each time. The harness's stderr → /dev/null redirect
defends against orphan-pipe deadlocks when a test panics — keep that
property intact.

### Unique `.tmp/` labels

Per [.claude/rules/test-fixtures-and-tmp-dir.md](../.claude/rules/test-fixtures-and-tmp-dir.md):

- Fixtures the test READS (inline strings, golden files) must live in git.
- `.tmp/<label>` paths the test WRITES must be unique to that test so
  parallel shards don't collide. `make_workspace("crossmod-refs", ...)`
  not `make_workspace("crossmod", ...)`.

### Capturing output

Per the "no tail in pipeline" rule: when running tests, write full output
to a file first, then `tail` the file. `make test` does this — never pipe
test output through `| tail` directly, since an orphaned `./hare-lsp` from
a panicked test can hold a downstream pipe open and wedge the shell.

### Failure diagnostics

When `E2E_LOG_DIR=<basedir>` is set in the runner's environment, every
session tees its wire traffic to `<basedir>/session-<n>/`:

```
<basedir>/session-12/hare-lsp-in.log   # bytes the client sent
<basedir>/session-12/hare-lsp-out.log  # bytes the server replied with
<basedir>/session-12/hare-lsp-err.log  # server's stderr (slog_*)
```

The session counter is per-process; if your runner forks multiple test
processes (e.g. the `make test` shard layout), pin each to its own
`E2E_LOG_DIR` or accept that two shards will overwrite each other's
`session-1/` etc. `make clean` clears `.tmp/`.

For single-test debugging without setting `E2E_LOG_DIR`, edit the test
to call `spawn_session_with_logs("debug-<your-label>")` temporarily.
Revert before committing — only the hand-picked subset below should ship
pinned to the log-dir helper.

### Opted-in log-capture tests

These tests always use `spawn_session_with_logs(label)` so the log-dir
codepath is exercised on every full test run. Each label is unique to its
test, so the directories don't collide even when shards run in parallel:

| Test                                            | Label                  |
|-------------------------------------------------|------------------------|
| `e2e_codelens_references_anchored_at_name`      | `logs-codelens`        |
| `e2e_did_change_full_replaces_document`         | `logs-did-change`      |
| `e2e_hover_on_identifier`                       | `logs-hover`           |
| `e2e_initialize_returns_response`               | `logs-init`            |
| `e2e_references_finds_call_site_and_decl`       | `logs-refs`            |
| `e2e_workspace_symbol_finds_open_decl`          | `logs-workspace-symbol`|

One representative test per parallel shard (c, d, e-h, i-p, r-s, t-z) so
each shard touches `HARE_LSP_LOG_DIR` at least once. If you add to the
list, pick a unique `logs-<feature>` label and update this table.

### Byte / rune offsets

Mixing up byte and rune offsets is the most recurring source of bugs in
this codebase — see the "Byte / rune offsets" section in the project
[CLAUDE.md](../.claude/CLAUDE.md). When writing a test that touches
offsets, include at least one identifier longer than a single ASCII
character (preferably a multi-byte rune); single-char names mask the bug
class.
