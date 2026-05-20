# hare/parse

Build-time overlay of the stdlib `hare::parse` module.

The Makefile's `hare/parse/.stamp` target copies `$(STDLIB)/hare/parse/*.ha`
into this directory, then applies `parse.ha.patch` and `import.ha.patch`
on top. Only the patches and this README are tracked in git; the
materialized `.ha` files are ignored via the top-level `.gitignore`.
`harefmt` walks the tree under the same `.gitignore`, so the generated
files are also exempt from formatting.

`HAREPATH` has `$(PWD)` before `$(STDLIB)`, so `use hare::parse;` resolves
to this directory and uses our patched copy.

## What we patch

### `parse.ha`'s `want()`

Stdlib uses `mkloc(lexer)` while building the "Unexpected X, was
expecting Y" error message. `mkloc` does an internal `lex + unlex`
cycle, leaving a token in the lexer's single-slot unlex buffer. The
`lex::unlex(lexer, tok)` call further down then aborts with:

    attempted to unlex more than one token

That assertion fires routinely on intermediate editing states (e.g. the
user has just typed `let x =` and is still typing the right-hand side),
so an unmodified stdlib parser crashes the LSP. The patch substitutes
`tok.2` (the failing token's own location). `lex::tokstr` ignores the
location field for the keyword/symbol tokens used in `want`'s
alternatives, so the rendered error is identical.

### `import.ha`'s `imports()` `loc.end`

Stdlib sets each import's `loc.end` via `mkloc(lexer)` after the parse
finishes, which returns the position of the lexer's NEXT real token.
The LSP parses without `COMMENTS` mode, so "next token" can be code
several lines down, across blank lines and `//` comments. The patch
captures the closing `;` token's own location while parsing and uses
that. Without the fix, `textDocument/documentLink` and folding ranges
extend past the `use` statement into the following comment, which VS
Code renders as a cmd-clickable underline navigating into the imported
module.

See `parse.ha.patch` and `import.ha.patch` for the patches themselves;
the headers at the top of each file document the change in detail.

## Refreshing for a new Hare release

Most of the time, just `make clean && make`. If upstream has touched
either of the patched functions, the offending patch will fail to apply
and you'll need to regenerate it:

1. Copy the new upstream file (`$(STDLIB)/hare/parse/<name>.ha`) into a
   scratch dir.
2. Re-apply the fix and the comments described above.
3. `diff -u --label a/<name>.ha --label b/<name>.ha orig new > <name>.ha.patch`.
4. Restore the human-readable header at the top of the patch
   (everything before the first `---` line is documentation and is
   ignored by `patch`).
5. `make clean && make test` to confirm the fix still works end-to-end;
   the e2e suite exercises the original abort path for `want()` and the
   documentLink-overrun path for `imports()`.

If a future stdlib release fixes either bug upstream, delete the
corresponding patch (and tighten this README accordingly). If both bugs
are gone, delete this directory's contents and the Makefile bits that
materialize it.
