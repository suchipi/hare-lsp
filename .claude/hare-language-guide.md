# Hare language guide for agents

A primer for agents starting work in this repo who are unfamiliar with Hare. Sources: the [official tutorial](https://harelang.org/tutorials/introduction/), the Hare specification, and the stdlib at `/usr/local/src/hare/stdlib/`. This guide focuses on the parts of Hare that matter for the hare-lsp codebase, plus the gotchas agents keep rediscovering.

If a syntactic detail isn't covered here, the authoritative reference is the stdlib source. Read it directly; it's small and idiomatic.

---

## 1. Orientation: what Hare is

- Systems language: manual memory management, no GC, no runtime to speak of.
- Statically typed, compiled, expression-oriented (most constructs are expressions, including `if`, `match`, `switch`, `for ... yield`).
- Explicit error handling via tagged unions, with two sugar operators (`!`, `?`).
- **No generics.** No traits. No interfaces (the `io::stream` "vtable" pattern is the closest substitute, hand-rolled per type).
- **Targets Hare v0.26.0 in this repo.** Hare evolves; APIs from older versions of the stdlib won't match.
- Source files end in `.ha`. Format with `./harefmt --write .` from the repo root before committing.

A trivial program:

```hare
use fmt;

export fn main() void = {
    fmt::println("Hello, world!")!;
};
```

The trailing `!` is the "this can't fail; abort if it does" operator. `fmt::println` returns `(size | io::error)` and we're ignoring the success size while asserting no I/O error.

---

## 2. Modules and HAREPATH

A module is a directory; every `.ha` file in that directory shares the module's namespace. Imports use `::`-separated paths:

```hare
use fmt;            // resolves to <HAREPATH>/fmt/
use encoding::json; // resolves to <HAREPATH>/encoding/json/
use hare::ast;
```

The compiler walks `HAREPATH` (colon-separated) left to right. **This repo's `Makefile` pins `HAREPATH` to `$(PWD):$(THIRDPARTY):/usr/local/src/hare/stdlib`** so that:

- `use lsp;`, `use server;`, `use analysis;` resolve to top-level dirs in the repo.
- `use hare::parse;` resolves to the **vendored** `hare/parse/` in the repo, **not** the stdlib copy (because `$(PWD)` comes first). This is how local stdlib overrides work — see "Vendoring stdlib" below.

To run a single command outside `make`, replicate the env (see `CLAUDE.md` for the canonical invocation).

### Visibility

- Top-level decls are private by default. Prefix with `export` to make them visible to importers.
- Within a module, all files see each other's private decls — no per-file visibility.

### Build tags

Filenames carry build tags after a `+`:

- `foo+test.ha` — compiled only when `hare test` runs.
- `foo+linux.ha`, `foo+darwin.ha` — OS-specific.
- `foo+x86_64.ha` — architecture-specific.

In this repo, **unit tests live next to the source** as `<name>_test+test.ha`. E2e tests live under `e2e/` and are their own module.

---

## 3. Types

### Primitives

- Integers: `i8 i16 i32 i64 int`, `u8 u16 u32 u64 uint`, `size` / `ssize` (pointer-sized), `uintptr`.
- Floats: `f32`, `f64`.
- Booleans: `bool`, with `true` / `false`.
- Runes: `rune` (a 32-bit Unicode code point).
- Strings: `str` (immutable UTF-8 byte sequence with a length).
- Unit: `void` (the only value of type `void` is also written `void`).
- Bottom: `never` — for expressions that don't return (`abort`, `os::exit`, infinite loops, `return`).
- Literal suffixes pick a type: `10i` (`int`), `10u` (`uint`), `10z` (`size`), `1.5f32`. Untyped numeric literals coerce.

### Arrays and slices

```hare
let a: [4]int = [1, 2, 3, 4];         // fixed-size array
let b: [_]int = [1, 2, 3];            // length inferred
let c: []int = [10, 20, 30];          // slice (ptr + len + cap)
let sub = b[1..3];                    // half-open slice, refers into b
```

- `len(x)` works on arrays, slices, and `str`.
- `append(slice, item)`, `append(slice, items...)`, `insert(slice[i], item)`, `delete(slice[i])`, `delete(slice[i..j])` mutate slices and may **reallocate** (more in the memory section).
- `static append(buf, item)` and friends mutate a slice backed by a fixed array without ever allocating; they error if capacity is exceeded.
- Indexing is bounds-checked at runtime. `*[*]T` is an unbounded pointer-to-array (unsafe, no bounds check).

### Strings

- `str` is **UTF-8 bytes plus a length**, *not* a sequence of runes.
- `len(s)` returns **bytes**, not runes.
- `strings::toutf8(s)` returns a `[]u8` view (borrowed; do not free unless documented).
- `strings::fromutf8(buf)` returns `(str | utf8::invalid)` — a borrowed view over the same bytes.
- To iterate runes, use `strings::iter(s)` + `strings::next(&iter)`.
- **The repo's positions module assumes the LSP can negotiate UTF-8/16/32 offsets.** Mixing byte offsets and rune indices is the source of multiple bugs in git history; look at `analysis/positions.ha` if you're doing offset math.

### Structs and tuples

```hare
type point = struct {
    x: int,
    y: int,
};

let p = point { x = 1, y = 2 };       // named struct literal
let q = struct { x: int = 1, y: int = 2 }; // anonymous struct
let t: (int, str) = (42, "hi");       // tuple
fmt::println(p.x, t.0)!;
```

Use `...` in a struct literal to take defaults for unspecified fields: `point { x = 5, ... }`.

### Enums

```hare
type color = enum { RED, GREEN, BLUE };
type flag = enum u8 { A = 1, B = 2, C = 4 };  // explicit backing type

let c = color::RED;
```

Switch on enum values; `switch` requires exhaustive coverage or a default `case =>`.

### Tagged unions

The workhorse type. Spelled with `|`:

```hare
type result = (int | str | void);
```

Unions are commutative and associative (`(A|B)` == `(B|A)`, `((A|B)|C)` == `(A|B|C)`). Use `...` to flatten:

```hare
type small = (i8 | i16);
type big   = (i32 | i64);
type any   = (...small | ...big);  // (i8|i16|i32|i64)
```

Test and assert:

```hare
let x: (int | str) = 42;
if (x is int) { /* ... */ };
let n = x as int;        // crashes if x is not int
```

The idiomatic destructurer is `match`:

```hare
match (x) {
case let n: int =>
    use_int(n);
case let s: str =>
    use_str(s);
};
```

Each `case` either pins a specific type from the union (`case int =>`), binds it (`case let n: int =>`), pins a specific value (`case errors::nomem =>`), or is the default (`case =>`).

### Pointers

```hare
let i = 10;
let p: *int = &i;
fmt::println(*p)!;
```

- `*T` is non-null by construction. You can't have an uninitialized `*T`.
- `nullable *T` may be null; you must `match` or check `is null` before dereferencing.
- Field access on `*S` auto-derefs: if `p: *point`, then `p.x` is `(*p).x`.
- `(p: uintptr + n: uintptr): *T` is the spelling for pointer arithmetic.

### Type casts and conversions

```hare
let f: f32 = 3.7;
let i = f: int;             // truncates to 3
let x: (int | uint) = 5i;
let n = x as int;           // type assertion on tagged union
let bytes: []u8 = [1, 2, 3];
let s = strings::fromutf8(bytes)!;  // borrowing conversion
```

The `:` suffix is the cast operator. It also performs the "widen this union to a superset" reinterpretation needed when storing a value of type `A` into a slot of type `(A | B)`.

---

## 4. Error handling

Errors are just tagged-union variants — there's no special "exception" mechanism. By convention, error types are declared with a leading `!`:

```hare
type myerr = !void;
type parseerr = !(strconv::invalid | strconv::overflow);
```

The `!` marker is what makes `?` and the auto-flatten-into-a-union behavior work — it tells the compiler "this is an error type."

### The `!` operator (assert no error)

```hare
fmt::println("hi")!;     // abort if println returned an error variant
```

Useful for impossible-failure cases (writing to stdout from a CLI, parsing a string literal you wrote yourself). **Don't** use it on user-facing I/O; abort messages aren't structured.

### The `?` operator (propagate)

```hare
fn read_all(path: str) ([]u8 | fs::error | io::error) = {
    const f = os::open(path)?;          // propagate fs::error
    defer io::close(f)!;
    return io::drain(f)?;               // propagate io::error
};
```

`?` returns early if the value is one of the error variants in the function's return type. The function's return type must include every error variant the `?`-ed expressions can produce, or the program won't compile.

### Memory-allocation errors: `nomem`

`alloc`, `append`, `insert` can fail with `nomem`. The compiler **requires** you handle it — either with `!` (abort), `?` (propagate, adding `nomem` to your return type), or a match. The repo uses `!` in most leaf code and `?` in code paths that already return a union.

### Error-to-string

Each module that defines errors provides a `strerror` function:

```hare
match (op()) {
case let e: fs::error =>
    fmt::fatalf("fs: {}", fs::strerror(e));
};
```

---

## 5. Control flow

### `if` (expression)

```hare
let label = if (count == 1) "item" else "items";
if (ready) { go(); } else if (degraded) { warn(); } else { halt(); };
```

`if` without `else` has type `void`. As an expression, both branches must produce compatible types.

### `for` (the only loop)

```hare
for (let i = 0z; i < 10; i += 1) { /* ... */ };  // C-style
for (cond) { /* ... */ };                         // while-style
for (true) { /* ... */ };                         // infinite

for (let item .. slice) { /* by value (copy) */ };
for (let p &.. slice)   { /* by pointer */ };
for (let x => iter())   { /* iterator returning (T | done) */ };
```

Use `break` / `continue` as expected. To label a loop, prefix the `for` with `:label` and `break :label`.

### `switch` (compare values; exhaustive)

```hare
switch (n) {
case 1, 2, 3 => fmt::println("low")!;
case 4, 5    => fmt::println("mid")!;
case         => fmt::println("other")!;  // default
};
```

### `match` (destructure tagged unions; exhaustive)

See the "Tagged unions" section above. Always exhaustive — if you add a variant to a type, every `match` site is a compile error until you handle it. Lean on this.

### `yield` (extract a value from a block)

`{ ... }` is an expression; `yield x` is how you return a value from it. Used heavily inside `match`/`switch` arms:

```hare
const f = match (os::open(path)) {
case let f: io::file => yield f;
case fs::error       => return -1;
};
```

### `defer` (run at scope exit)

```hare
const f = os::open(path)!;
defer io::close(f)!;   // runs on every exit from this scope
```

- Deferred statements run in LIFO order at the end of the enclosing **block**, not the function.
- Defers run on normal exit, `return`, `break`, `continue`, and error propagation via `?`.
- Defers do **not** run on `abort()` or `os::exit()`.

### `never`-returning expressions

`return`, `break`, `continue`, `abort(...)`, `os::exit(...)` all have type `never`. You can use them in any branch of a `match`/`switch` to avoid producing a value:

```hare
const x = match (op()) {
case let v: int => yield v;
case error      => abort("bad");   // never; no yield needed
};
```

---

## 6. Functions

```hare
fn add(x: int, y: int) int = x + y;             // expression body
fn run(name: str) void = {                       // block body
    fmt::printfln("running {}", name)!;
};

export fn public_api(...) result = { /* ... */ };

// Variadic
fn sum(prefix: str, nums: int...) int = {
    let total = 0;
    for (let n .. nums) total += n;
    return total;
};

let xs: []int = [1, 2, 3];
sum("xs: ", xs...);   // unpack a slice into a variadic

// Default values
fn greet(name: str, greeting: str = "Hello") void = {
    fmt::printfln("{}, {}", greeting, name)!;
};

// Function pointers
let op: *fn(int, int) int = &add;
op(2, 3);
```

There are no methods. There is no UFCS. Free functions and modules are how the codebase is organized.

---

## 7. Memory management

Hare is fully manual: you allocate, you free. The compiler does not insert frees. The leak-checker is your test suite.

### Allocation

```hare
let p: *int = alloc(42)!;            // single value on the heap
defer free(p);

let buf: *[1024]u8 = alloc([0...])!; // fixed-size array on the heap
defer free(buf);

let s: []int = alloc([1, 2, 3])!;    // slice on the heap (len=3, cap=3)
defer free(s);

let s2: []int = alloc([], 64)!;      // empty slice, cap=64
defer free(s2);
append(s2, 7)!;                       // won't realloc until cap exceeded
```

`alloc(expr)` returns `*T` (or `[]T` if `expr` is a slice literal). The `!` is for the `nomem` case.

### Free

- `free(p)` deallocates whatever `alloc` produced.
- Freeing `null`, an empty `str`, or an empty `[]T` is a no-op (don't add guards).
- **Slice helpers**: `strings::freeall([]str)` frees each `str` and the slice. Use the module-provided helper when freeing structured data.

### Append-realloc invalidates pointers

`append(s, x)` may reallocate the slice's backing storage. **Any pointer or slice that aliased the old storage is now dangling.** Plan for this:

```hare
let edits: []edit = [];
append(edits, e1)!;
let first = &edits[0];   // OK now
append(edits, e2)!;      // may realloc — `first` is now dangling
```

A real version of this bug (`json::object` holding an old `[]json::value` pointer that we then appended into) is captured in `memory/feedback_json_object_append_pattern.md` — read it if you're mutating JSON. The general rule: at the moment you call `append`, no other live reference may alias the slice's backing buffer.

### Ownership conventions

The stdlib documents who owns what; copy the convention in your own code:

- "**Borrows**": the function reads but does not free; caller still owns it. E.g., `strings::fromutf8` returns a `str` aliasing the input bytes.
- "**Assumes ownership**": the function (or its return value's eventual freer) becomes responsible. E.g., `io::drain` returns a buffer the caller must free.
- "**Returns a borrow**": the result is valid only until some other operation. E.g., `buffer::as_string` is invalid after the next mutation of the buffer.

When in doubt, read `haredoc <module>` or the source.

### Static and const

- `static let x = ...;` inside a function: process-wide single instance, initialized to a compile-time constant, persists across calls.
- `def NAME: T = ...;` at module scope: a true compile-time constant (substituted, not stored).
- `let` at module scope: a process-wide mutable global initialized at startup.

---

## 8. Attributes

- `@test fn foo() void = { ... };` — compiled only with `hare test`. Use `assert(cond)` or `assert(cond, "message")`.
- `@init fn setup() void = { ... };` — runs once before `main`.
- `@fini fn teardown() void = { ... };` — runs after `main` returns normally.
- `@noreturn` — function never returns (return type `never` is the modern way).
- `@symbol("...")` — set the linker symbol name.

The repo's testing convention: prefer real `@test` functions over external probe scripts. See `memory/feedback_tests_over_probes.md`.

---

## 9. The stdlib modules you'll actually touch

Read the `README` next to each module in `/usr/local/src/hare/stdlib/<module>/` for a one-line description; read the source for the rest.

| Module | What it gives you |
|---|---|
| `fmt` | `print(ln)`, `printf(ln)`, `fprintf(ln)`, `asprintf` (allocates), `bsprintf` (writes into a buffer). Format syntax: `{}`, `{0}`, `{:x}`, `{:-10}`, `{:.2f}`. See README quoted above. |
| `io` | `handle` = `(file | *stream)`. `read`, `write`, `close`, `drain` (read-all), `copy`, `tee`. `*stream` is the "implement your own I/O object" interface. |
| `os` | `args`, `getenv`, `stdin`, `stdout`, `stdout_file` (unbuffered), `stderr`, `open`, `create`, `exit`. The unbuffered `stdout_file` matters for this LSP — see `cmd/hare_lsp/main.ha` for why. |
| `strings` | `toutf8`/`fromutf8`, `concat` (allocs; free with `free`), `join`, `split`, `cut`, `iter`/`next` for runes, `hasprefix`/`hassuffix`/`contains`, `trim`/`ltrim`/`rtrim`, `dup`, `freeall`. |
| `strconv` | `stoi`, `stou`, `stoz`, `itos`, `ftos`. |
| `bufio` | `newscanner`, `scan_line`, `scan_string`, `scan_rune`, `scan_bytes`. Heads-up on `scan_string` with multi-byte delimiters: see `memory/feedback_bufio_multibyte_delim.md`. |
| `memio` | In-memory `io::handle` (`fixed` over a buffer, `dynamic` that grows). The standard way to build a string without `strings::concat` calls. |
| `bytes` | Byte-slice helpers (`index`, `contains`, `equal`). |
| `errors` | Reusable error variants: `nomem`, `noaccess`, `noentry`, `invalid`, `unsupported`, `busy`, `exists`, `cancelled`, etc. Embed these in your own error unions to make them interoperate. |
| `encoding::json` | This repo uses `hare-json` at `/usr/local/src/hare/third-party/encoding/json/`. `json::value` is `(f64 | str | bool | json::object | []json::value | _null)`. `json::get`, `json::put`, `json::take`, `json::finish`. Read `feedback_json_object_append_pattern.md` before mutating a `json::object`. |
| `hare::lex` | Tokenizer over Hare source. Produces `token = (ltok, value, location)`. |
| `hare::parse` | Parser producing `hare::ast` nodes. The stock version aborts on partial input — **this repo vendors a fixed copy under `hare/parse/`** (see Section 11). |
| `hare::ast` | The AST: `subunit`, `decl`, `expr`, `_type`, `import`, `ident`, `loc`. **`loc.off` is a rune offset, not a byte offset.** See `analysis/loc_fixup.ha`. |
| `hare::unparse` | AST -> source text. Use it sparingly and only where the formatter actually wants stdlib behavior; in many cases this project unparses by hand to preserve syntactic detail the stdlib drops. |
| `time` | `instant`, `now`, durations. |

---

## 10. Idioms you'll see repeatedly in this repo

### Construct-and-defer

```hare
const f = os::open(path)?;
defer io::close(f)!;
const data = io::drain(f)?;
defer free(data);
```

### Match-with-yield to assign

```hare
const n = match (strconv::stoz(s)) {
case let v: size => yield v;
case             => yield 0z;
};
```

### Tagged union for "either a result or void"

```hare
fn lookup(name: str) (entry | void) = {
    // ...
    return void;
};

match (lookup(n)) {
case let e: entry => use(e);
case void         => /* not found */ void;
};
```

### `case =>` as the catch-all

```hare
case let e: my_error => handle(e);
case                 => abort("unexpected");
```

### Initializing a slice of strings owned by the value

```hare
let parts: []str = [];
defer strings::freeall(parts);
append(parts, strings::dup("a"))!;     // each str is heap-owned
append(parts, strings::dup("b"))!;
// freeall walks parts and free()s every element, then the slice itself.
```

### Building output with `memio`

```hare
let buf = memio::dynamic();
defer io::close(&buf)!;
fmt::fprintf(&buf, "k = {}", v)!;
const out = strings::dup(memio::string(&buf)!);  // dup if you'll outlive buf
```

---

## 11. Repo-specific landmines

These are documented in detail elsewhere; the summary here saves you a discovery cycle.

- **Vendored stdlib lives under `hare/<module>/`.** The Makefile's `HAREPATH` puts the repo root first, so a file at `hare/parse/parse.ha` shadows `/usr/local/src/hare/stdlib/hare/parse/parse.ha`. We currently vendor `hare/parse/` to fix an abort-on-partial-input bug. If you find a stdlib limitation, vendor only the file(s) you need to change and add a header comment explaining the divergence. See `memory/feedback_vendor_when_stdlib_blocks.md`.
- **`hare::ast` loc offsets are rune indices.** Convert to bytes via `analysis/loc_fixup.ha` before anything LSP-facing.
- **`loc.end.off` is the start of the LAST RUNE of the last consumed token, not the end of that token.** This comes from `hare::lex::prevloc`. For `b.x`, `loc.end.off` of the access_field equals the start of `x` — and *also* equals the end of `x`, because `x` is a single rune. For `b.data` it points at `a` (start of the last rune of `data`), not at `d` and not past `a`. Tests that use single-character names will not catch a mishandling of this. See the "Byte / rune offsets" section of [CLAUDE.md](../CLAUDE.md).
- **Multiple LSP "position" encodings.** UTF-8 / UTF-16 / UTF-32 is negotiated at `initialize`. Use `analysis/positions.ha`; do not roll your own offset math.
- **`bufio::scan_string("\r\n")` is unsafe across read-ahead boundaries.** Use `scan_line` + `strings::rtrim('\r')`. See `memory/feedback_bufio_multibyte_delim.md`.
- **Appending into a `json::value` that lives in a `json::object` is a use-after-free pattern.** Take the value out first, mutate, put it back. See `memory/feedback_json_object_append_pattern.md`.
- **Unbuffered stdout in `cmd/hare_lsp/main.ha` is load-bearing.** Replacing `os::stdout_file` with `os::stdout` will hang vscode-languageclient because responses sit in a 4 KiB buffer that never flushes. The e2e suite catches this.
- **`make test` already runs the e2e suite** — don't run `hare test` and `make test` in sequence; see `memory/feedback_make_test_covers_e2e.md`.

---

## 12. Quick reference: things that are NOT in Hare

If you're coming from another language and reach for one of these, stop:

- No generics (parametric or otherwise). Duplicate or use tagged unions.
- No traits, interfaces, methods, inheritance, mixins.
- No exceptions; only tagged-union error variants.
- No garbage collector; no RAII (use `defer`).
- No async / await; no goroutines. Plain threads exist via `rt::`.
- No macros, no preprocessor (only build tags on filenames).
- No `unsafe { }` block; pointer arithmetic and `*[*]T` indexing are just available.
- No string interpolation; use `fmt::asprintf("...{}...", x)` or `memio`.
- No `null` for non-pointer types; tagged unions express optionality.
- No operator overloading.

---

## 13. Where to look next

- The tutorial: <https://harelang.org/tutorials/introduction/>.
- The specification: <https://harelang.org/specification/> (terse but complete).
- The stdlib source: `/usr/local/src/hare/stdlib/` — small enough to grep; treat it as documentation.
- `haredoc <module>` prints the documentation for a module.
- This repo's `CLAUDE.md` for architecture and build/test commands.
- `.claude/rules/` for project conventions that override or extend this guide.
