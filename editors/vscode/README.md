# Hare LSP — VSCode extension

Adds Hare language support to VSCode by wrapping the [hare-lsp](../../) language server.

## Install (from source)

You need [Node.js](https://nodejs.org/) 18+ and `vsce`.

```sh
cd editors/vscode
npm install
npm run package        # produces hare-lsp-0.0.1.vsix
code --install-extension hare-lsp-0.0.1.vsix
```

Or, from the repo root:

```sh
make vscode-install
```

The extension expects `hare-lsp` on `$PATH`. Override with the
`hare-lsp.path` setting if your binary lives elsewhere.

## Settings

All `hare.*` settings declared in [package.json](./package.json) are
forwarded to the server via the standard `workspace/configuration`
flow. See the project README for what each one does.

## Development

```sh
npm install
npm run watch          # incremental TypeScript compile
```

Open this folder in VSCode and press F5 to launch a development host.

## License

MPL-2.0 — same as the language server and Hare itself.
