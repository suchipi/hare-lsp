# hare/parse

Vendored overlay of the stdlib `hare::parse` module. Upstream source:
`/usr/local/src/hare/stdlib/hare/parse/` (Hare v0.26.0).

## Why we vendored it

The stdlib `hare::parse::want()` calls `mkloc(lexer)` while building the
"Unexpected X, was expecting Y" error message. `mkloc` does a `lex + unlex`
cycle internally, which leaves a token in the lexer's single-slot unlex
buffer. `want` then calls `lex::unlex(lexer, tok)` to put back the failing
token, and the lexer aborts the whole process with:

    attempted to unlex more than one token

That assertion fires routinely on intermediate editing states (e.g. the user
has typed `let x =` and is still typing the right-hand side), so any LSP that
embeds the unmodified stdlib parser crashes whenever the user pauses mid-edit
on certain inputs. We need the parser to return an `error` here, not abort.

We tried to fix this in stdlib but it would have been a larger change with
upstream coordination cost, so we vendor instead. `HAREPATH` puts the repo
root first, so `use hare::parse;` resolves to this copy.

## What we changed

Only `parse.ha`'s `want()` function. The two `mkloc(lexer)` calls used to
build the error message are replaced with `tok.2` (the failing token's own
location). This keeps the unlex slot clean and yields the same rendered
error text, because `lex::tokstr` ignores the location field for the
keyword/symbol tokens used in `want`'s alternatives.

The header comment in `parse.ha` and the inline comment above the changed
block document the fix in-tree.

All other files in this directory are identical to stdlib in behavior. Some
have whitespace differences from running `harefmt` over the tree; those are
not intentional changes and can be re-synced from upstream at any time.

## Keeping this in sync with upstream

When updating to a new Hare release:

1. Diff each file in this directory against
   `/usr/local/src/hare/stdlib/hare/parse/` for the target version.
2. Re-apply the `want()` fix in `parse.ha` (replace `mkloc(lexer)` with
   `tok.2` in the two spots inside `want`, and keep the explanatory
   comments).
3. Run `make test` to confirm the parser still recovers cleanly on
   intermediate editing states. The e2e suite exercises this path.

If a future stdlib version returns an error from `want` instead of aborting,
delete this overlay and drop the `use hare::parse;` shadowing.

## Related

See [.claude/CLAUDE.md](../../.claude/CLAUDE.md) under "Architecture →
`hare/parse/`" for the short version.
