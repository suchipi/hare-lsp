# Changelog

## 0.0.1 (initial release)

First release. Implements the full applicable surface of LSP 3.17:

- **Lifecycle**: initialize, initialized, shutdown, exit, $/cancelRequest,
  $/setTrace, $/logTrace, client/registerCapability,
  client/unregisterCapability.
- **Document sync**: didOpen, didChange (incremental), didClose, willSave,
  willSaveWaitUntil, didSave with includeText.
- **Diagnostics**: push (publishDiagnostics) and pull (textDocument/diagnostic,
  workspace/diagnostic, refresh). In-process recovering parser plus
  `hare build` integration on save. Debounced per `hare.diagnostics.debounceMs`.
- **Navigation**: hover, definition, type-definition, declaration,
  implementation, references, document highlight, prepareRename + rename,
  document & workspace symbols, document links (target resolution via
  hare::module::find), call hierarchy (prepare/incoming/outgoing), type
  hierarchy (supertypes walk the underlying _type for named idents;
  subtypes scan all workspace TYPE entries for reverse references).
- **Editing**: completion + completionItem/resolve, signature help,
  formatting (full / range / on-type reindent), code actions
  (source.organizeImports), code lens (run-test, N-references),
  inlay hints (parameter names + inferred types via best-effort
  analysis::type_of_expr_at), semantic tokens (full + range; delta
  with per-document result-id caching + coarse first/last-difference
  diff), folding ranges, selection ranges.
- **Workspace**: workspaceFolders + didChangeWorkspaceFolders,
  configuration + didChangeConfiguration, didChangeWatchedFiles,
  willCreate/Rename/DeleteFiles, didCreate/Rename/DeleteFiles,
  workspace/symbol + workspaceSymbol/resolve, executeCommand
  (`hare-lsp.runTest`, `hare-lsp.runModule`), applyEdit usage in rename.
- **Window**: showMessage, showMessageRequest, logMessage, showDocument,
  workDoneProgress create/cancel, $/progress.
- **Workspace indexing**: walks each root for *.ha and builds a flat
  index of declarations; updates incrementally on watcher events.
- **Configuration**: every `hare.*` key is live: `path`, `tags`,
  `diagnostics.{debounceMs,enableBuild}`, `format.{indentStyle,
  indentWidth,trimFinalNewlines,insertFinalNewline}`, and
  `inlayHints.{parameterNames,inferredTypes}`. No reserved/dormant keys.

In-tree VSCode extension under [editors/vscode/](editors/vscode/) with
its own TextMate grammar, language configuration, and
vscode-languageclient wrapper. Install with `make vscode-install`.

Out of scope (not advertised, not implemented): documentColor,
inlineValue, moniker, linkedEditingRange, telemetry, notebookDocument.
