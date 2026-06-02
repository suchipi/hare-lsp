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

The bootstrap shells out to the standard `patch` utility, so building
this repo requires `patch` on `$PATH` (Alpine: `apk add patch`; Debian
ships it in `patch`; macOS bundles it in the Command Line Tools).

## What we patch

### `parse.ha`'s `want()`

Stdlib uses `mkloc(lexer)` while building the "Unexpected X, was
expecting Y" error message. `mkloc` does an internal `lex + unlex`
cycle, leaving a token in the lexer's single-slot unlex buffer. The
`lex::unlex(lexer, tok)` call further down then aborts with:

    attempted to unlex more than one token

That assertion fires routinely on intermediate editing states (e.g. the
user has just typed `let x =` and is still typing the right-hand side),
so an unmodified stdlib parser crashes the LSP. The patch moves the
`lex::unlex(lexer, tok)` call up above the alternatives loop, which
primes the unlex slot with `tok` before any `mkloc` call. Subsequent
`mkloc` invocations then lex `tok` back out of the slot, unlex it
again, and leave the slot holding `tok` - no clash.

Newer stdlib distributions (e.g. Alpine's `hare=0.26.0.1-r0`) carry
the same fix upstream. The build wrapper applies the patch with
`patch -N` and treats "previously applied" output as success, so the
same `parse.ha.patch` works against both the buggy and the
already-fixed upstream variant.

### `import.ha`'s `imports()` `loc.end`

Stdlib sets each import's `loc.end` via `mkloc(lexer)` after the parse
finishes, which returns the position of the lexer's NEXT real token.
The LSP parses without `COMMENTS` mode, so "next token" can be code
several lines down, across blank lines and `//` comments. The patch
instead sets `loc.end` to `lex::prevloc(lexer)` (the location of the
last consumed rune) right after each closing `;`, reading lexer state
the same way the stdlib's `loc_from()` computes every other end
location. Without the fix, `textDocument/documentLink` and folding
ranges extend past the `use` statement into the following comment, which
VS Code renders as a cmd-clickable underline navigating into the
imported module.

An earlier version of the patch instead copied the matched `;` token's
own location field (`want(...)?.2`) into a local. That read correctly
on the local toolchain but produced layout-dependent garbage on Alpine's
`hare=0.26.0.1-r0` (musl) - `loc.end` sometimes landed on the next token
instead of the `;`, breaking the unused-import quickfix range check.
Reading `lex::prevloc` from lexer state is robust across toolchains, so
verify this patch on the Alpine CI image (musl), not just locally.

See `parse.ha.patch` and `import.ha.patch` for the patches themselves;
the headers at the top of each file document the change in detail.

## Refreshing for a new Hare release

Most of the time, just `make clean && make`. The recipe tolerates the
"already applied upstream" case automatically, so a stdlib bump that
includes one of these fixes won't break the build - it just skips the
relevant patch.

If upstream has touched a patched function in a way that's neither the
original buggy form nor the form our patch produces, the patch will
fail to apply and you'll need to regenerate it:

1. Copy the new upstream file (`$(STDLIB)/hare/parse/<name>.ha`) into a
   scratch dir.
2. Re-apply the fix described above.
3. `diff -u --label a/<name>.ha --label b/<name>.ha orig new > <name>.ha.patch`.
4. Restore the human-readable header at the top of the patch
   (everything before the first `---` line is documentation and is
   ignored by `patch`).
5. `make clean && make test` to confirm the fix still works end-to-end;
   the e2e suite exercises the original abort path for `want()` and the
   documentLink-overrun path for `imports()`.

If a future stdlib release fixes both bugs upstream, the build will
skip both patches silently and the `.ha` files in this directory will
be byte-identical to `$(STDLIB)/hare/parse/`. At that point you can
delete the patches, this README, and the Makefile bits that
materialize the directory.
