# Emacs (eglot)

Eglot is built into Emacs 29+. To wire `hare-lsp` in, register the
server program under `eglot-server-programs` for your Hare major mode:

```elisp
(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               '(hare-mode . ("hare-lsp"))))
```

Then `M-x eglot` in a `hare-mode` buffer to start the server.

## Hare major mode

Eglot needs a major mode mapped to `.ha` files. Install one of:

- [hare-mode](https://git.sr.ht/~bbuccianti/hare-mode) (recommended).
- Any custom `define-derived-mode` of your own; eglot only needs the
  symbol to dispatch on.

If you don't want to install hare-mode, define a trivial derived mode of
your own. Eglot dispatches on derived modes, so do NOT register
`prog-mode` directly: that would make eglot try to launch `hare-lsp` in
every prog-mode-derived buffer (python-mode, c-mode, rust-mode, ...).

```elisp
(define-derived-mode hare-mode prog-mode "Hare")
(add-to-list 'auto-mode-alist '("\\.ha\\'" . hare-mode))
(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               '(hare-mode . ("hare-lsp"))))
```

You'll still miss out on font-lock, but eglot will only attach to
`.ha` buffers.

## Settings

Eglot pulls settings via `workspace/configuration`. Configure them via
`eglot-workspace-configuration`:

```elisp
(setq-default eglot-workspace-configuration
              '(:hare
                (:diagnostics (:enableBuild t :debounceMs 300)
                 :format (:indentStyle "tab" :indentWidth 8)
                 :inlayHints (:parameterNames t :inferredTypes t))))
```

The full set of supported keys is documented in the
[main README](../../README.md#configuration).

## lsp-mode (alternative)

If you prefer [lsp-mode](https://emacs-lsp.github.io/lsp-mode/):

```elisp
(with-eval-after-load 'lsp-mode
  (add-to-list 'lsp-language-id-configuration '(hare-mode . "hare"))
  (lsp-register-client
   (make-lsp-client
    :new-connection (lsp-stdio-connection "hare-lsp")
    :activation-fn (lsp-activate-on "hare")
    :server-id 'hare-lsp)))
```
