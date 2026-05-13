# Doc-comment ownership annotations

hare-lsp shows a one-line **Ownership** indicator on hover for pointer / slice / `str` values whose ownership the server can decide. The line tells you whether the value is **owned** (you must free it) or **borrowed** (someone else owns it; don't free). When the server has no signal, the line is omitted entirely — silence means "I don't know," not a guess.

This page documents the annotation syntax you can put in your own doc comments so the LSP picks up your intent.

## At a glance

```hare
// A widget. The caller must clean up with widget_free.
//
// @returns: owned
export fn widget_new() *widget = alloc(widget { ... });

// Pulls a token from `in`, leaving the rest for the next call.
//
// @returns: borrowed from in
// @param in: borrowed
export fn token(in: *iterator) str = void;
```

```hare
// A read-only pointer to the in-process logger. Don't free.
//
// @borrowed
export const log: *logger = &default_logger;

// Process-wide scratch buffer. Freed at shutdown.
//
// @owned
let scratch: *buffer = null: *buffer;
```

That's the whole grammar. Details below.

## How the LSP decides

When you hover an identifier whose type carries ownership, the LSP runs three layers and picks the highest-confidence one that fires:

1. **User annotation** — what this page is about. Highest confidence: if you wrote it, the LSP trusts it.
2. **Stdlib doc comment** — a committed lookup table maintained offline that captures phrases like "the caller must free" or "borrowed from `in`" from the Hare stdlib's documentation. Only applies to stdlib symbols; the LSP runtime itself does no natural-language matching.
3. **Heuristic** — built-in rules for expressions: `alloc(...)` returns owned, `&x` borrows local storage, a string literal is borrowed (it lives in static storage), and so on.

If none of those fire, hover renders no Ownership line at all. Silence reads as "I don't know"; the line is reserved for positive answers.

## Annotation syntax

Annotations are plain text on their own line inside a doc comment. The LSP scans line by line; one leading space (the conventional space after `//`) is tolerated.

### On functions

Use **`@returns:`** to describe what the caller gets back. The LSP rejects bare `@owned` / `@borrowed` on functions because it's not obvious whether they'd apply to the return, a parameter, or something else.

```
// @returns: owned
// @returns: borrowed
// @returns: borrowed from <param-name>
```

When you write `borrowed from <name>`, the LSP renders the source in the hover line:

```
Ownership: borrowed (annotation: borrowed from `in`)
```

Use **`@param <name>:`** to describe a single parameter:

```
// @param in: borrowed
// @param out: owned
```

The LSP shows the param's ownership when the user hovers the parameter name inside the function body or signature.

A full example:

```hare
// Reads up to one newline-terminated line from `r`, returning the bytes
// without the trailing '\n'. The returned slice borrows from a scratch
// buffer inside the scanner; it stays valid until the next read call.
//
// @param r: borrowed
// @returns: borrowed from r
export fn scan_line(r: *scanner) ([]u8 | done | error) = void;
```

### On globals, consts, and `let` bindings

There's no return value to confuse things, so the bare form is fine:

```
// @owned
// @borrowed
```

```hare
// Lazily allocated; freed at program exit.
//
// @owned
let cache: *table = null: *table;
```

### On struct fields

Field doc comments accept the same bare `@owned` / `@borrowed` as globals:

```hare
type session = struct {
	// @borrowed
	parent: *root,

	// @owned
	cache: *table,

	id: int,
};
```

Hovering the field shows the line.

## What the hover line looks like

```
Ownership: owned (annotation)
Ownership: borrowed (annotation)
Ownership: borrowed (annotation: borrowed from `in`)
Ownership: owned (doc comment: the caller must free the return value)
Ownership: borrowed (doc comment: borrowed from `in`)
Ownership: owned (heuristic: alloc returns owned memory)
Ownership: borrowed (heuristic: address-of borrows local storage)
```

The trailer in parentheses always tells you **which layer decided**:

- `annotation` — you (or someone) wrote a tag.
- `doc comment` — the stdlib docs contained a recognized phrase.
- `heuristic` — the LSP inferred from the expression's structure.

That trailer is the confidence signal. `(annotation)` and `(doc comment: …)` are explicit human intent. `(heuristic: …)` is the LSP guessing from structural cues; usually right, but not promised.

## When the LSP stays silent

- No layer fired (the docs are silent, the symbol isn't in the stdlib table, no heuristic matched). Silence reads as "I don't know"; the line is reserved for positive answers.
- The hovered subject isn't a value (a module name, a keyword, an attribute).

## Why this exists

Hare has no syntactic marker for ownership. Reading code, you can usually tell whether a `*foo` is something you own or something you've been lent — by reading the function's doc comment and inferring from prose. The hover line surfaces that signal at the cursor so you don't have to scroll to the decl every time. The annotation grammar lets you give the LSP an explicit answer when the prose alone wouldn't be unambiguous.

## Common pitfalls

- **`@owned` on a function is silently dropped.** Use `@returns: owned`.
- **`@returns: borrowed from <name>` requires the named parameter to exist.** If it doesn't, the LSP still shows the line, but the trailer won't help your reader.
- **Don't annotate if you don't know.** Omitting the tag is a legitimate answer — the LSP just stays silent — and is better than a wrong guess.
- **The bare form is fine on fields.** Field doc comments use the same syntax as globals.

## See also

- `analysis/ownership.ha` — the runtime parser. Source of truth for the grammar.
- `.claude/stdlib-ownership-scan.md` — how the Layer 2 stdlib lookup table is maintained (offline, by an agent).
