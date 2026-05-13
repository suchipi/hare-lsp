# Layer 2 — stdlib ownership scan runbook

This is a maintenance task: refresh `analysis/stdlib_ownership_data.ha` so the LSP can show `Ownership: …(doc comment: …)` lines on hover for stdlib symbols.

The runbook is written for a Claude agent arriving cold. A fresh session should be able to do the whole thing from this file alone.

## What you're doing

The LSP shows a one-line ownership indicator on hover. Three layers feed into it:

1. **User annotations** in the decl's own doc comment, parsed at runtime (`@returns: owned`, `@returns: borrowed [from X]`, `@param <name>: …`, plus bare `@owned` / `@borrowed` on non-functions). Lives in `analysis/ownership.ha`.
2. **Pre-scanned stdlib doc-comment facts** — the layer you're about to refresh. The LSP runtime does **no** natural-language matching. Instead it reads a committed lookup table that an LLM agent (you) maintains by reading stdlib docs and classifying each function's return.
3. **Heuristics** on expressions at hover time (e.g. `alloc(...)` → owned, `&x` → borrowed). Lives in `server/hover_ownership.ha`.

Your job here is layer 2 only. Don't touch the other two.

## When to run this

- The Hare stdlib at `/usr/local/src/hare/stdlib/` has been updated (new Hare release, vendored stdlib bump, manual edit).
- The pattern list below has been extended and you want the table to reflect the new patterns.

Don't run this as a routine "make test" or CI step. It's manual, infrequent, and the output is committed.

## Inputs and outputs

- **Input**: `/usr/local/src/hare/stdlib/` on the local machine. This is the same path that `make check-deps` validates; if the directory is missing, stop and tell the user to install the Hare stdlib source first.
- **Output**: overwrite `analysis/stdlib_ownership_data.ha` in this repo. Do not edit it by hand otherwise.

## What to include in the table

Include an entry for a stdlib symbol when **all** of the following are true:

1. The decl is `export fn <name>(...)` — a public function. Skip private functions; users never see them through hover.
2. The function's **return type carries memory ownership semantics**: pointer (`*T`), nullable pointer (`nullable *T`), slice (`[]T`), or `str`. Skip functions returning `int`, `bool`, `size`, plain structs, etc. — there's nothing to own.
3. The doc comment contains a recognizable ownership cue (see "Classification rules" below). If the docs are silent or ambiguous, **omit the entry**. A missing entry shows up as `Ownership: unknown` at the call site, which is the correct outcome — better than a wrong guess.
4. The symbol is reachable from regular user code. Skip the stdlib's `rt::` internals (they're the runtime, not user-facing).

## Classification rules

Read the doc comment as natural language. You don't have to match exact phrases — these are hints, not regex.

**Owned cues** (the caller is responsible for freeing the return value):

- "The caller must free …"
- "The user must free …"
- "must be freed [using …]"
- "must free …"
- "The result must be freed …"
- "The return value is freed by …"
- Anything else that clearly says the caller owns and must clean up.

For owned entries, the `detail` string is `"doc comment: <short paraphrase>"`. Keep the paraphrase tight (≤ 50 chars) and lowercase. Examples:

- `"doc comment: the caller must free the return value"`
- `"doc comment: must free with finish"`
- `"doc comment: the result must be freed after use"`

**Borrowed cues** (the return value is a view into an existing buffer; the caller must not free it):

- "borrowed from <X>"
- "is borrowed"
- "are borrowed from <X>"
- "is a slice borrowed from <X>"
- "Borrows" (as the leading word of a sentence)

For borrowed entries, if a `from <name>` parameter is named, capture the name and write the detail as ``"doc comment: borrowed from `<name>`"``. If there's no named source, write ``"doc comment: borrowed"`` (no trailer needed).

**Skip cases** (no entry):

- The docs say nothing about ownership.
- The docs say something ambiguous ("returns a string" doesn't tell us anything).
- The function returns `void`, `int`, `bool`, etc. (the return type doesn't carry ownership).
- The function has side effects on a passed-in buffer (`append`, `insert` style) — these aren't "ownership of the return value" cases.

## File format

Open the existing `analysis/stdlib_ownership_data.ha` for the format. The exact structure:

```hare
// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// This file is maintained offline by an agent following
// .claude/stdlib-ownership-scan.md. Do not hand-edit individual entries;
// instead re-run the scan and overwrite the whole file.
//
// Each entry maps a (module, short_name) stdlib symbol to an ownership
// classification derived from natural-language cues in its doc comment.
// Entries are sorted by (module, short_name) so successive rewrites
// produce minimal diffs.

// One row of the Layer-2 stdlib ownership table.
export type stdlib_ownership_entry = struct {
	module: str,
	short_name: str,
	kind: ownership,
	detail: str,
};

export const STDLIB_OWNERSHIP_TABLE: [_]stdlib_ownership_entry = [
	stdlib_ownership_entry {
		module = "bufio",
		short_name = "newscanner",
		kind = ownership::OWNED,
		detail = "doc comment: must free with finish",
	},
	// ... more entries ...
];
```

Rules:

- Use tabs for indentation, matching the rest of the codebase.
- Sort entries by `(module, short_name)` ascending. `module` first, then `short_name` within the module.
- Use `ownership::OWNED` or `ownership::BORROWED`. Never `ownership::UNKNOWN` — if you'd write UNKNOWN, omit the entry instead.
- The `module` field is the short module name (the basename of the directory: `strings`, `bufio`, `unix::poll`, etc.). For multi-segment modules use the full `::`-joined path.
- The `short_name` field is the function name without the module prefix.
- Trailing comma after the last entry is fine; the array uses `[_]` so length is inferred.

## How to run the scan

You're the agent. Do this:

1. Confirm `/usr/local/src/hare/stdlib/` exists. If not, stop and tell the user to install it.
2. Read every `*.ha` file under `/usr/local/src/hare/stdlib/`. (Use Glob with `**/*.ha` and Read each.)
3. For each file, find every `export fn` declaration. Look at the doc comment immediately above it.
4. Apply the classification rules above. Decide owned, borrowed, or omit.
5. Verify the return type carries ownership before emitting. If the function returns `int` or `void`, skip even if the docs mention freeing (that's a comment about a parameter or side effect, not the return).
6. Aggregate the entries in memory. Sort by `(module, short_name)`.
7. Rewrite `analysis/stdlib_ownership_data.ha` from scratch with the new entries. Keep the banner and the `stdlib_ownership_entry` type declaration as-is.
8. Run `make` and `make test` from the repo root. The unit tests in `analysis/ownership_test+test.ha` reference the anchor entries (`strings::dup`, `strings::trim`, `bufio::newscanner`, etc.) — they must still pass.
9. Spot-check the diff: did the anchor entries survive? Are there obvious additions or losses you didn't expect?

## Anchor cases — these must end up in the table after every run

If any of these is missing or wrong after your scan, you got something wrong. Re-read the source file and fix.

| Symbol               | kind     | detail                                       |
| -------------------- | -------- | -------------------------------------------- |
| `strings::dup`       | OWNED    | doc comment: the result must be freed after use |
| `strings::concat`    | OWNED    | doc comment: the caller must free the return value |
| `strings::runes`     | OWNED    | doc comment: the caller must free the return value |
| `strings::trim`      | BORROWED | doc comment: borrowed from `in`              |
| `strings::tokenize`  | BORROWED | doc comment: borrowed from `in`              |
| `bufio::newscanner`  | OWNED    | doc comment: must free with finish           |

If the upstream stdlib has reworded these phrases since the anchors were written, update the `detail` field to match the new wording — but the `kind` must not change.

## What not to do

- Don't run the scan on workspace code, `cmd/hare_lsp/`, or third-party paths. This is stdlib-only.
- Don't include entries for non-exported functions, even if their docs mention ownership.
- Don't fabricate entries when the stdlib docs are silent. Omit instead.
- Don't include entries for functions whose return type doesn't carry ownership (int, bool, void, plain structs).
- Don't hand-edit `analysis/stdlib_ownership_data.ha` to patch a single bad classification. Re-run the whole scan so the file stays self-consistent.
- Don't change the structure of `stdlib_ownership_entry` or `STDLIB_OWNERSHIP_TABLE`. That's the LSP runtime's interface; changing it breaks the runtime.

## After the scan

Show the user the diff. If anchors changed or you found a meaningful pattern shift, mention it. Otherwise just confirm "scan complete, N entries, K added since last run, J removed."

Do not commit on the user's behalf unless asked.
