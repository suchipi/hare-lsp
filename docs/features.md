# hare-lsp features

This is the source-of-truth feature matrix for hare-lsp. Each entry
corresponds to a capability advertised in the `initialize` response (see
[server/server.ha](../server/server.ha) `build_initialize_result`).

Targets LSP 3.17 and Hare v0.26.0.

## Lifecycle

- `initialize` / `initialized`: yes. Negotiates `positionEncoding`
  (UTF-8 / UTF-16 / UTF-32; falls back to UTF-16 if the client offers
  none). Echoes `serverInfo { name, version }`.
- `shutdown` / `exit`: yes.
- `$/cancelRequest`: yes; in-flight requests honor cancellation.
- `$/setTrace`, `$/logTrace`: yes.
- Dynamic capability registration: yes (used for `workspace/didChangeConfiguration`).

## Text document sync

- Open / close: yes (`openClose: true`).
- Incremental updates: yes (`change: 2`).
- `willSave`, `willSaveWaitUntil`: yes.
- `didSave` with `includeText: true`: yes.

## Diagnostics

- Push diagnostics on every edit, debounced by `hare.diagnostics.debounceMs`
  (default 300 ms).
- Pull diagnostics: yes (`textDocument/diagnostic` and `workspace/diagnostic`).
- Parse errors come from an in-tree recovering parser, so a single file
  can publish multiple parse diagnostics at once.
- On save, `hare build` adds type-check errors. Disable with
  `hare.diagnostics.enableBuild = false`. Build wall-clock budget is
  governed by `hare.diagnostics.buildTimeoutMs` (default 60 s; `0`
  disables).
- Per-file diagnostics are capped at 1000; further parse errors collapse
  into one trailing diagnostic.
- Severity defaults to `Error`; messages containing "unused" or
  "unreachable" downgrade to `Warning`. Build `warning` lines are
  `Warning`.
- Unused imports emit a `Hint`-level diagnostic with the `Unnecessary`
  tag (greyed out by editors) and code `unused-import`. A `quickfix`
  code action attached to that diagnostic removes the import line.

## Navigation

- Hover: yes, with doc-comment rendering.
- Goto definition: yes.
- Goto declaration: yes.
- Goto type definition: yes.
- Goto implementation: aliased to type definition (Hare has no
  inheritance, so this is the closest sensible mapping).
- Find references: scope-aware for locals; module-aware for top-level
  decls (textual workspace scan re-resolves each hit against its
  file's `use` list + workspace index to filter out same-named
  unrelated decls).
- Document highlight: yes.
- Document symbols: yes (hierarchical).
- Workspace symbols: yes, with `resolveProvider: true`.
- Document links: yes (resolves `use foo::bar;` imports to file URIs
  for modules under any workspace folder or on `HAREPATH`).
- Folding ranges: yes.
- Selection ranges: yes.
- Call hierarchy: yes (`prepareCallHierarchy`, `incomingCalls`,
  `outgoingCalls`).
- Type hierarchy: yes (`prepareTypeHierarchy`, `supertypes`, `subtypes`).
  Module-aware: each referenced type ident is re-resolved against the
  containing file's `use` list, so two unrelated types sharing a short
  name in different modules are kept distinct.

## Editing

- Completion: yes, with `resolveProvider: true` and trigger characters
  `:` and `.`. Completing a workspace symbol whose module isn't yet
  imported sets `additionalTextEdits` to insert the corresponding
  `use <module>;` line, so accepting the completion auto-imports.
- Signature help: yes, with trigger characters `(` and `,`.
- Document formatting: yes (full).
- Document range formatting: yes.
- Document on-type formatting: yes, with first trigger `}` and
  additional triggers `;`. On-type does whitespace-only reindent and
  always fires, even on unparseable files.
- Rename: yes, with `prepareProvider: true`. Scope-aware for locals
  (let/const/def/for/match/func-param bindings restrict the search to
  the binding's lexical scope); top-level decls use the same
  module-aware filter as Find references, so a rename only rewrites
  identifiers that re-resolve to the cursor's symbol.
- Code actions: yes, with `resolveProvider: true`. Supported kinds:
  `source.organizeImports`, `quickfix`.
- Code lenses: yes, with `resolveProvider: true`. Currently emits
  "run test" lenses for `@test` functions and "N references" counts.
- Inlay hints: yes, with `resolveProvider: true`. Two flavors:
  parameter-name hints at call sites (`hare.inlayHints.parameterNames`,
  default on) and inferred-type hints on `let` / `const`
  (`hare.inlayHints.inferredTypes`, default on).
- Semantic tokens: yes, with `full`, `range`, and `delta` (range +
  delta are advertised independently from the legend).

## Commands

`workspace/executeCommand` advertises:

- `hare-lsp.runTest`: runs `hare test <name>` and streams output via
  `window/logMessage`.
- `hare-lsp.runModule`: runs `hare run <module>`.
- `hare-lsp.organizeImports`: removes unused imports.
- `hare-lsp.applyAutoImport`: server-side handler stub for clients that
  prefer commands over `WorkspaceEdit`s on completion accept.

## Workspace

- Multiple workspace folders: yes. `didChangeWorkspaceFolders` is
  honored.
- Configuration pull (`workspace/configuration`): yes. Settings live
  under the `hare` namespace; defaults apply if the client doesn't
  respond.
- File watchers (`workspace/didChangeWatchedFiles`): yes. The server
  registers `**/*.ha` patterns dynamically when the client supports
  registration.
- `willCreate` / `willRename` / `willDelete` file operations: yes (each
  filtered to `**/*.ha`).
- Workspace diagnostics: yes (pull).

## Window

- `window/showMessage`: yes.
- `window/showMessageRequest`: yes.
- `window/logMessage`: yes.
- `window/showDocument`: yes.
- Work-done progress: yes (`$/progress`).

## Configuration

Settings are read from the `hare` namespace; the canonical schema is
[editors/vscode/schemas/hare-settings.schema.json](../editors/vscode/schemas/hare-settings.schema.json).

Highlights:

| Key | Default | Notes |
| --- | --- | --- |
| `hare.path` | `"hare"` | Path to the `hare` binary. |
| `hare.harepath` | `""` | Colon-separated module search path overriding `$HAREPATH`. |
| `hare.tags` | `[]` | Build tags (`-T <tag>`). |
| `hare.diagnostics.debounceMs` | `300` | Parse-diagnostics debounce. |
| `hare.diagnostics.enableBuild` | `true` | Run `hare build` on save. |
| `hare.diagnostics.buildTimeoutMs` | `60000` | Build wall-clock cap; `0` disables. |
| `hare.format.indentStyle` | `"tab"` | Tab vs space indent. |
| `hare.format.indentWidth` | `8` | Spaces per indent when `indentStyle = space`. |
| `hare.format.trimFinalNewlines` | `true` | Trim trailing whitespace at file end. |
| `hare.format.insertFinalNewline` | `true` | Ensure trailing newline. |
| `hare.inlayHints.parameterNames` | `true` | Param-name hints at call sites. |
| `hare.inlayHints.inferredTypes` | `true` | Inferred-type hints on `let` / `const`. |
| `hare.inlayHints.inferredTypesMaxDepth` | `10` | Max recursion depth for inferred-type hints; follows call return types and type aliases. Cycles are guarded by a visited set, so larger values are safe. |
| `hare.limits.maxOpenDocuments` | `1024` | Cap on open documents. |
| `hare.limits.maxTotalBufferBytes` | `268435456` | Cap on summed open-buffer bytes (256 MiB). |
| `hare.limits.maxPendingRequests` | `4096` | Cap on in-flight server-initiated requests. |
| `hare.limits.maxCancelledIds` | `256` | Cap on cancelled request ids retained. |
| `hare.limits.maxDiagnosticsPerFile` | `1000` | Cap on diagnostics published per file. |
| `hare.limits.maxWorkspaceIndexEntries` | `1000000` | Cap on workspace-index entries. Raise it if your workspace has more than ~1M decls. |

## Environment

| Variable | Description |
| --- | --- |
| `HARE_LSP_LOG_DIR` | Absolute directory to tee `hare-lsp-{in,out,err}.log` into. |
| `HARE_LSP_LOG_LEVEL` | Minimum stderr log severity (`debug`/`info`/`warn`/`error`, default `info`). |
| `HARE_LSP_MAX_BODY_BYTES` | Override the LSP transport's max request body size (default 32 MiB). Read at startup because the cap applies before `initialize` arrives. |

## CLI

- `hare-lsp` (no args): run the LSP server over stdio.
- `hare-lsp --doctor`: print a dependency checklist (`hare` on
  `$PATH`, `hare version`, HAREPATH entries, hare-json install path,
  `HARE_LSP_LOG_DIR` sanity). Exit 0 on success, 1 on failure.
- `hare-lsp --version`: print the server version.
- `hare-lsp --help`: usage.

## Known limitations

- **References & rename: locals are scope-aware; top-level decls are
  module-aware via a re-resolve filter.** When the cursor resolves to
  a local binding (`let` / `const` / `def` / `for` / `match` / function
  parameter), the search is bounded to that binding's lexical scope.
  For top-level decls the workspace is still scanned textually
  (skipping comments, strings, and char literals), but every candidate
  hit is then re-resolved against its own file's `use` list +
  workspace index, so two unrelated top-level identifiers sharing a
  short name in different modules are kept distinct. Textual hits in
  unindexed files (stdlib, third-party that isn't on a workspace path)
  are dropped, since they can't be authoritatively matched against a
  workspace entry.
- **Formatting requires a parseable file.** Full / range formatting
  only runs when the document parses cleanly. On-type re-indent still
  fires on unparseable files (it operates on whitespace only). This is
  intentional: a no-op format on a syntax error is a useful signal
  that the file doesn't parse.
- **Workspace indexing is chunked, not concurrent.** Hare is
  single-threaded, so indexing runs cooperatively between LSP
  messages: each dispatch tick processes a small batch and yields
  back. Progress is reported via `$/progress` and the job can be
  cancelled with `window/workDoneProgress/cancel`. Caveat: a fully
  idle editor (sending no messages) won't drive the job forward;
  typing or a pull-diagnostics request unblocks it. Results from
  `workspace/symbol` may carry `isIncomplete: true` while the job is
  still draining.
- **Inlay-hint types are best-effort.** Inferred types resolve
  literals, declared types, function-call return types, and follow
  type-alias chains up to `hare.inlayHints.inferredTypesMaxDepth`
  hops (default 10; cycles are guarded by a visited set, so larger
  values are safe). Complex inference (deeply chained field accesses,
  generic-shaped constructs) may show no hint rather
  than a wrong one. Only top-level `let` / `const` decls are scanned
  today; bindings inside function bodies aren't covered yet.
- **Body size limit.** The LSP transport rejects messages larger than
  32 MiB by default. Override via the `HARE_LSP_MAX_BODY_BYTES`
  environment variable when the client sends very large workspace
  edits. The cap must be set before `initialize` arrives, which is
  why it's an env var rather than a setting.
- **Resource caps are configurable.** All caps (open documents, total
  buffer bytes, in-flight requests, cancelled ids, diagnostics per
  file, workspace-index entries) are tunable via `hare.limits.*` with
  no additional non-configurable ceiling — raise a limit if your
  workload needs it. Lowering a cap below current usage applies
  prospectively; the server does not proactively evict.
