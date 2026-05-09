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
  `hare build` integration on save.
- **Navigation**: hover, definition, type-definition, declaration,
  implementation, references, document highlight, prepareRename + rename,
  document & workspace symbols, document links, call hierarchy
  (prepare/incoming/outgoing), type hierarchy (prepare/super/sub).
- **Editing**: completion + completionItem/resolve, signature help,
  formatting (full / range / on-type), code actions
  (source.organizeImports), code lens (run-test, N-references),
  inlay hints (parameter names + inferred types), semantic tokens
  (full/delta/range), folding ranges, selection ranges.
- **Workspace**: workspaceFolders + didChangeWorkspaceFolders,
  configuration + didChangeConfiguration, didChangeWatchedFiles,
  willCreate/Rename/DeleteFiles, didCreate/Rename/DeleteFiles,
  workspace/symbol + workspaceSymbol/resolve, executeCommand
  (`hare-lsp.runTest`, `hare-lsp.runModule`), applyEdit usage in rename.
- **Window**: showMessage, showMessageRequest, logMessage, showDocument,
  workDoneProgress create/cancel, $/progress.
- **Workspace indexing**: walks each root for *.ha and builds a flat
  index of declarations; updates incrementally on watcher events.

Out of scope (not advertised): documentColor, inlineValue, moniker,
linkedEditingRange, telemetry, notebookDocument.

136 unit tests passing.
