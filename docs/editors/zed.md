# Zed

Zed doesn't ship Hare grammar or LSP support out of the box. You need a
third-party Zed extension to register the `hare` language and bind
`hare-lsp` to it; this document only shows the minimum configuration
glue assuming such an extension exists (or that you're authoring one).

## Quick wiring (settings.json)

If you already have a `hare` language registered (via a tree-sitter
extension or your own), point Zed at `hare-lsp` in
`~/.config/zed/settings.json`:

```jsonc
{
  "languages": {
    "Hare": {
      "language_servers": ["hare-lsp"]
    }
  },
  "lsp": {
    "hare-lsp": {
      "binary": {
        "path": "hare-lsp",
        "arguments": []
      },
      "settings": {
        "hare": {
          "diagnostics": { "enableBuild": true, "debounceMs": 300 },
          "format": { "indentStyle": "tab", "indentWidth": 8 },
          "inlayHints": { "parameterNames": true, "inferredTypes": true }
        }
      }
    }
  }
}
```

The complete settings tree is documented in the main
[README](../../README.md#configuration).

## Authoring a Zed extension

If no Hare extension exists yet, you'll need to write one. The relevant
Zed APIs:

- `extension.toml` declares the language.
- `languages/hare/config.toml` ties `.ha` files to the language.
- A `language_servers` section in your extension can register `hare-lsp`
  with its binary path, arguments, and initialization options.

See the [Zed extension docs](https://zed.dev/docs/extensions) for the
current schema. Hare grammar lives at
[tree-sitter-hare](https://git.sr.ht/~ecmma/tree-sitter-hare) and can be
referenced from a Zed extension.

## Notes

- Zed currently negotiates UTF-16 position encoding; hare-lsp supports
  this and replies accordingly.
- Inlay hints, formatting, and code actions all work over the standard
  LSP surface; no Zed-specific extension is required for them.
