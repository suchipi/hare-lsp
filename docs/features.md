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
- Find references: scope-aware for locals; textual workspace scan for
  top-level decls - see [Known limitations](#known-limitations).
- Document highlight: yes.
- Document symbols: yes (hierarchical).
- Workspace symbols: yes, with `resolveProvider: true`.
- Document links: yes (resolves `use foo::bar;` imports to file URIs
  when the target module is inside a workspace folder or on a
  workspace-overlapped `HAREPATH`).
- Folding ranges: yes.
- Selection ranges: yes.
- Call hierarchy: yes (`prepareCallHierarchy`, `incomingCalls`,
  `outgoingCalls`).
- Type hierarchy: yes (`prepareTypeHierarchy`, `supertypes`, `subtypes`).
  Name-based - see limitations.

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
  the binding's lexical scope); top-level decls still fall back to a
  workspace-wide textual scan - see limitations.
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
| `hare.format.insertFinalNewline` | `true` | Ensure trailing newline. |
| `hare.inlayHints.parameterNames` | `true` | Param-name hints at call sites. |
| `hare.inlayHints.inferredTypes` | `true` | Inferred-type hints on `let` / `const`. |

## Environment

| Variable | Description |
| --- | --- |
| `HARE_LSP_LOG_DIR` | Absolute directory to tee `hare-lsp-{in,out,err}.log` into. |
| `HARE_LSP_LOG_LEVEL` | Minimum stderr log severity (`debug`/`info`/`warn`/`error`, default `info`). |

## CLI

- `hare-lsp` (no args): run the LSP server over stdio.
- `hare-lsp --doctor`: print a dependency checklist (`hare` on
  `$PATH`, `hare version`, HAREPATH entries, hare-json install path,
  `HARE_LSP_LOG_DIR` sanity). Exit 0 on success, 1 on failure.
- `hare-lsp --version`: print the server version.
- `hare-lsp --help`: usage.

## Known limitations

- **References & rename are partly textual.** When the cursor resolves
  to a local binding (`let` / `const` / `def` / `for` / `match` /
  function parameter), the search is bounded to that binding's lexical
  scope, so shadowing works correctly. For top-level decls the
  workspace is still scanned textually: comments, strings, and char
  literals are skipped, but two unrelated top-level identifiers with
  the same name in different modules are indistinguishable. Renaming a
  top-level symbol may rewrite same-named decls elsewhere.
- **Formatting requires a parseable file.** Full / range formatting
  only runs when the document parses cleanly. On-type re-indent still
  fires on unparseable files (it operates on whitespace only).
- **Workspace indexing is synchronous.** When a workspace folder is
  added, the server walks every `*.ha` file under the new root on the
  message-handling thread. For very large workspaces this blocks the
  dispatch loop. Background indexing with progress is on the roadmap.
- **Resource caps.** The server refuses to grow past hard caps: 1024
  open documents, 256 MiB of open-buffer bytes, 1000 diagnostics per
  file, 4096 in-flight server requests, and 1,000,000 workspace-index
  entries. Hitting any cap is logged via `window/logMessage`.
- **Type hierarchy is name-based.** `typeHierarchy/supertypes` and
  `subtypes` match by short identifier name across the workspace. Two
  unrelated types with the same short name in different modules will
  appear linked.
- **Inlay-hint types are best-effort.** Inferred types resolve literals,
  declared types, and simple expressions; complex inference (generic
  instantiations, deeply chained calls) may show no hint rather than a
  wrong one.
- **`workspace/symbol` and document links** resolve stdlib imports only
  when `HAREPATH` overlaps a workspace folder.
- **Body size limit.** The transport rejects LSP messages larger than
  32 MiB by default.
