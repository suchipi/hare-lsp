# Helix

Helix already ships a built-in `hare` language definition. You only need
to register `hare-lsp` as its language server.

Edit `~/.config/helix/languages.toml`:

```toml
[language-server.hare-lsp]
command = "hare-lsp"

[[language]]
name = "hare"
scope = "source.hare"
file-types = ["ha"]
language-servers = ["hare-lsp"]
```

Verify with:

```
hx --health hare
```

## Settings

Helix forwards settings under the language-server config table via
`workspace/configuration`. To override defaults:

```toml
[language-server.hare-lsp.config.hare]
diagnostics.enableBuild = true
diagnostics.debounceMs  = 300
format.indentStyle      = "tab"
format.indentWidth      = 8
inlayHints.parameterNames = true
inlayHints.inferredTypes  = true
```

The complete settings tree is documented in the main
[README](../../README.md#configuration).

## Notes

- Helix uses LSP positions in UTF-16 by default; the server negotiates
  this at `initialize` and replies in the matching encoding.
- Inlay hints are rendered inline if you have
  `editor.inline-diagnostics.cursor-line = "hint"` (or similar) in your
  helix config; see the Helix docs for the current option name.
