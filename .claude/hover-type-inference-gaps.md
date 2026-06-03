# Hover type-inference gaps (tracking)

Tracking doc for the syntax structures where **type hover falls back** instead of showing a real type. Each row below is a self-contained, parallelizable task: dispatch one agent per row (or per group). Status starts at `TODO`; flip to `DONE` (with the PR #) as they land.

This is the follow-up to the for-each / iterator loop fix (PR #79): that fixed *one* form that hit the fallback. The rows here are the rest.

## Status: RESOLVED

**All rows in Tables A, B, C, and D are DONE** (PR #83). Each table is marked `✅ DONE` below with a note on what landed. Summary of the change:

- **Engine A** (`infer_type_from_init_at`, navigation.ha) gained cases for unary ops, slice, switch, compound block, `size`/`align`/`offset`, `alloc`, and `vaarg`; the access sub-dispatcher (`infer_access_expr_type`) now delegates field/index/tuple/qualified-ident forms to Engine B and renders the result; `infer_call_return_type` resolves indirect calls through a local function-pointer binding; `type_label_for_literal` renders `[N]T`, the named struct alias, and `(T, U, ...)`; `render_decl_signature` infers omitted top-level `def`/`let`/`const` types; and the `is` type-test renders `bool`.
- **Engine B** (`type_of_expr`, struct_member.ha) gained receiver cases for `if`/`else`, `match`, `switch`, compound block, slice, and address-of, and now declines the `is` type-test (which is `bool`, a member-less builtin) instead of resolving members against the target type.
- Each row has unit-test coverage (`server/navigation_test+test.ha`, `server/struct_member_test+test.ha`); the qualified-identifier form (A4) also has an e2e test (`e2e/hover+test.ha`) exercising real stdlib resolution.
- Notable semantics confirmed against harec v0.26.0: every `alloc(...)` yields `(... | nomem)`; compound/match/switch blocks take their value from explicit `yield` statements (plus implicit `yield void` on fall-through), **not** from a bare trailing expression; `size`/`align`/`offset`/`len` are all `size`; `match`/`switch`/compound receivers must be parenthesized to be valid postfix bases.

## Background: the two inference engines

Hover type info comes from two separate best-effort engines. They have **different** fallback behaviors, so a gap shows up differently depending on which engine the cursor hits.

### Engine A — binding-init inference (string-based)

`infer_type_from_init_at` in [server/navigation.ha](server/navigation.ha) (entry: `infer_type_from_init`, navigation.ha:1316). Produces a rendered type **string**. Used for:
- Hover on a local `let`/`const`/`def` binding: `render_local_binding` (navigation.ha:1163).
- Inlay hints for inferred-type bindings: `infer_let_type_deep` (server/inlayhint_types.ha) wraps the same function.

**Fallback when an expression form is unhandled:** `infer_type_from_init_at`'s `case =>` returns `void` (navigation.ha:1371), and `render_local_binding` then **echoes the raw init source text** (navigation.ha:1216-1228). Combined with the `loc.end`-is-last-rune quirk, that echo is often truncated, which is exactly the `let opt = cmd.opt` nonsense from PR #79. Inlay hints just suppress the hint.

Currently handled by Engine A: plain literals, direct named `call`, `cast`, `?`/`!` (propagate / error-assert), `match`, `if`/`else`, `len`, binary arithmetic, and a **single-segment** identifier that resolves to a same-file local binding. Everything else falls back.

### Engine B — receiver type resolution (AST-node-based)

`type_of_expr` in [server/struct_member.ha](server/struct_member.ha) (struct_member.ha:554). Produces a `located_type` (an `ast::_type` node + owning file). Used for:
- Struct/union member hover and go-to-definition: `resolve_struct_member_at` (struct_member.ha:92).
- Member **completion** after `recv.`: completion.ha:846.
- `textDocument/typeDefinition` on a binding (`try_send_type_def_via_binding`, navigation.ha:364).

**Fallback when a receiver form is unhandled:** `type_of_expr`'s `case =>` returns `void` (struct_member.ha:630), so the member hover / completion / type-def **silently produces nothing** (no echo, just a missing result).

Currently handled by Engine B: identifier (local + workspace + stdlib), `.field`, `[i]` index, `.N` tuple, direct named `call`, `cast`, `?`/`!`, and `*p` deref (`unarithm` DEREF only). Everything else returns void.

> These two engines overlap in intent but not code. Engine B already resolves `.field`, `[i]`, `.N`, and qualified idents to real type nodes; the cleanest fix for the matching Engine A rows (A1-A4) is to **call `type_of_expr` and render its result**, rather than re-implement resolution in the string world. See "Shared fix strategy".

## How to pick up a task

1. Read [.claude/rules/understand-before-fixing.md](.claude/rules/understand-before-fixing.md) and the "Byte / rune offsets" section of [.claude/CLAUDE.md](.claude/CLAUDE.md) first.
2. Add the expression case to the named function. For Engine A rows that mirror Engine B, prefer delegating to `type_of_expr` + `render_type_plain` (navigation.ha:1970) over hand-rolling.
3. Write a **unit test** in `server/navigation_test+test.ha` (Engine A) or `server/struct_member_test+test.ha` (Engine B). **Use at least one identifier longer than one ASCII char** (ideally multi-byte) - single-char names mask the `loc.end` rune bug. See the existing `hover_on_for_each_*` and `hover_const_match_init_*` tests for the harness shape.
4. If the form involves resolving through the stdlib, add an e2e test under `e2e/` (per the project's "always write e2e tests" convention).
5. `make test` and `make vscode-test` must stay green. `./harefmt --tab-width 2 --write .` before committing.

## Shared fix strategy (A1-A4, the access forms)

`infer_access_expr_type` (navigation.ha:1417) is where field / index / tuple / qualified-ident inits die. It currently only accepts a 1-segment `access_identifier`:
- non-identifier access variants bail at its inner `case => return void` (navigation.ha:1428-1429);
- multi-segment (qualified) idents bail at `if (len(id) != 1) return void` (navigation.ha:1431).

The whole receiver-resolution machinery already exists in Engine B. The recommended fix for A1-A4 is to route the init `ast::expr` through `type_of_expr(s, doc, su, init, depth)` and render the returned `located_type.t` with `render_type_plain`. That single change can cover all four access forms at once - but they're listed as separate rows so they can be split across agents and tested independently. Whoever takes the first one should consider doing the shared plumbing and leave the rest as thin follow-ups.

---

## Table A — Engine A fallbacks (binding hover + inlay hints) — ✅ DONE

A1-A12 all resolved: access forms (A1-A4) delegate to `type_of_expr`; A5-A12 add the unary/slice/switch/compound/measure/alloc/vaarg/fn-pointer cases to `infer_type_from_init_at`.

User-visible symptom: hovering `let/const/def NAME = <init>` shows the **echoed (often truncated) source** instead of a type; inlay hint is missing.

| ID | Syntax form (`ast` variant) | Example init | Currently shows | Should show | Fix site |
|----|------------------------------|--------------|-----------------|-------------|----------|
| A1 | Struct/union field access (`access_field`) | `let x = cfg.timeout;` | echoes `= cfg.timeou` | field's declared type | `infer_access_expr_type` navigation.ha:1417 (delegate to `member_type_in_type`) |
| A2 | Index access (`access_index`) | `let x = items[idx];` | echoes `= items[idx]` | element type of the collection | `infer_access_expr_type` (delegate to `element_type_in_type` struct_member.ha:641) |
| A3 | Tuple field access (`access_tuple`) | `let x = pair.1;` | echoes `= pair.1` | type of tuple field N | `infer_access_expr_type` (delegate to `tuple_field_type` struct_member.ha:692) |
| A4 | Qualified identifier (`access_identifier`, len > 1) | `let x = os::args;` | echoes `= os::arg` | the referenced global/const/enum type | `infer_access_expr_type` `len(id) != 1` guard navigation.ha:1431 (delegate to `type_of_identifier`) |
| A5 | Unary ops (`unarithm_expr`) | `let p = &node;` / `let v = *p;` / `let n = -x;` / `let b = !flag;` / `let m = ~bits;` | echoes the source | `&x`→`*T`; `*p`→referent; `-x`/`~x`→operand type; `!x`→`bool` | add `unarithm_expr` case to `infer_type_from_init_at` navigation.ha:1333 (deref/operand resolution exists in `type_of_expr` struct_member.ha:613) |
| A6 | Slice expression (`slice_expr`) | `let s = buf[2..8];` | echoes `= buf[2..8]` (or truncated) | `[]T` (slice of element type) | add `slice_expr` case; resolve object type then wrap element type in a slice |
| A7 | Switch expression (`switch_expr`) | `let x = switch (k) { case => ... };` | echoes the source | union of each case's yielded value type | add `switch_expr` case; mirror `infer_match_expr_type` navigation.ha:1552 |
| A8 | Compound / block expression (`compound_expr`) | `let x = { ...; yield v; };` | echoes the source | type of the block's yielded value | add `compound_expr` case; infer from `yield` targeting the block (incl. implicit final-expr yield) |
| A9 | `size()` / `align()` / `offset()` (`size_expr`, `align_expr`, `offset_expr`) | `let n = size(int);` | echoes `= size(int)` | `size` | add the three cases to `infer_type_from_init_at`; all three are unconditionally `size` (cf. the existing `len_expr` case navigation.ha:1365) |
| A10 | Allocation (`alloc_expr`) | `let p = alloc(node);` | echoes `= alloc(node)` | object form → `*T` / `(*T \| nomem)`; slice form → `[]T` / `([]T \| nomem)` | add `alloc_expr` case; needs `alloc_form` + capacity handling - **nontrivial**, confirm exact nomem semantics against stdlib |
| A11 | `vaarg(ap, T)` (`variadic_expr` → `vaarg_expr`) | `let a = vaarg(ap, int);` | echoes the source | the explicit type `T` (`vaarg_expr._type`) | add `variadic_expr` case; **low priority / rare** |
| A12 | Call via local fn-pointer (`call_expr`, indirect callee) | `let y = handler();` where `handler` is a local of fn type | echoes the source | the fn pointer's result type | `infer_call_return_type` navigation.ha:1749 only resolves workspace/stdlib decls; also resolve a local binding whose type is `func_type`. **Edge case** |

## Table B — Engine B fallbacks (member hover / completion receiver) — ✅ DONE

B1-B6 all resolved by adding the receiver cases to `type_of_expr`. Note: `match`/`switch`/compound receivers must be parenthesized (`(match ...).field`) to parse as a postfix base; `block_yield_located_type` represents a match/switch/compound by its first resolvable `yield` value; slice and address-of reuse the object/operand type directly (auto-deref / element-unwrap handle the rest, avoiding synthetic type nodes).

User-visible symptom: hovering `recv.field` or invoking completion after `recv.` produces **nothing** when `recv` is one of these forms. Rarer in practice than Table A (these are receiver expressions, which are usually plain lvalues), but they're the same class of gap.

| ID | Receiver form (`ast` variant) | Example | Currently | Should | Fix site |
|----|-------------------------------|---------|-----------|--------|----------|
| B1 | `if`/`else` expression (`if_expr`) | `(if (c) a else b).field` | no result | resolve via the taken branch's type (true branch, fall back to false) | add `if_expr` case to `type_of_expr` struct_member.ha:562 |
| B2 | `match` expression (`match_expr`) | `match (v) { ... }.field` | no result | resolve via the common case value type | add `match_expr` case to `type_of_expr` |
| B3 | `switch` expression (`switch_expr`) | `switch (k) { ... }.field` | no result | resolve via the common case value type | add `switch_expr` case to `type_of_expr` |
| B4 | Compound / block (`compound_expr`) | `{ ...; yield s; }.field` | no result | resolve via the block's yielded value type | add `compound_expr` case to `type_of_expr` |
| B5 | Slice expression (`slice_expr`) | `xs[a..b][0].field` | no result | `[]T` then element type on the following index | add `slice_expr` case to `type_of_expr` |
| B6 | Address-of (`unarithm_expr` ADDR) | `(&val).field` | no result | pointer type `*T`, auto-deref to `T`'s members | extend the `unarithm_expr` arm in `type_of_expr` struct_member.ha:613 (currently DEREF-only) |

## Table C — Wrong type (not a fallback, but incorrect hover) — ✅ DONE

C1 (is-test → `bool`) fixed in both engines; C2 (omitted top-level type) inferred in `render_decl_signature` for the open document.

These produce a *confident, wrong* answer rather than a fallback. Same overall goal (correct hover types); worth fixing alongside.

| ID | Form | Example | Currently shows | Should show | Fix site |
|----|------|---------|-----------------|-------------|----------|
| C1 | `is` type-test cast (`cast_expr`, `cast_kind::TEST`) | `let b = x is int;` | `int` | `bool` | both cast arms ignore `cast_kind`: `infer_type_from_init_at` navigation.ha:1338-1346 and `type_of_expr` struct_member.ha:603-608. `is` → `bool`; `as`/`:` keep the target type |
| C2 | Top-level `def`/`let`/`const` with omitted type | `def PI = 3.14159;` | `def PI` (no type) | `def PI: f64` (inferred) | `render_decl_signature` navigation.ha:627 never infers; the const/def branch (navigation.ha:632) and global branch (navigation.ha:684) only print a type when one was written. Could call `infer_type_from_init` on the init |

## Table D — Coarse labels (low priority quality gaps) — ✅ DONE

D1-D3 resolved in `type_label_for_literal`: array literals render `[N]T` (`[_]T` for an expanding literal), named struct literals render the alias name, tuple literals render `(T, U, ...)`. Each falls back to the old coarse label when an element/field type can't be inferred.

Handled (no fallback) but imprecise. Listed for completeness; fix only if cheap.

| ID | Form | Currently shows | Could show | Fix site |
|----|------|-----------------|------------|----------|
| D1 | Array literal init | `[_]_` | `[N]T` with real element type | `type_label_for_literal` navigation.ha:1733 |
| D2 | Struct literal init | `struct { ... }` | named alias or real field list | `type_label_for_literal` navigation.ha:1735 |
| D3 | Tuple literal init | `(...)` | `(T, U, ...)` with real element types | `type_label_for_literal` navigation.ha:1737 |

## Suggested order

1. **A1-A4** (access forms) - highest user impact, and one agent can lay the shared `type_of_expr`-delegation plumbing that the others build on.
2. **A5, A6** (unary, slice) - common in real code.
3. **A9, C1** - trivial / small and high-confidence.
4. **A7, A8** (switch, compound) - moderate; reuse the match-inference shape.
5. **C2** - small, distinct code path.
6. **A10** (alloc) - nontrivial, do deliberately.
7. **Table B** rows and **A11/A12** - rarer; batch when the access plumbing exists.
8. **Table D** - optional polish.

## Source map (quick reference)

- Engine A dispatcher: `infer_type_from_init_at` - navigation.ha:1327 (fallback `case =>` at navigation.ha:1371)
- Engine A echo fallback: `render_local_binding` - navigation.ha:1216-1228
- Engine A access sub-dispatcher: `infer_access_expr_type` - navigation.ha:1417
- Engine B dispatcher: `type_of_expr` - struct_member.ha:554 (fallback `case =>` at struct_member.ha:630)
- Reusable resolvers (Engine B): `member_type_in_type` (1425), `element_type_in_type` (641), `tuple_field_type` (692), `deref_pointer_type` (737), `type_of_identifier` (810), all in struct_member.ha
- Renderers: `render_type_plain` (navigation.ha:1970), `render_type_without_errors` (navigation.ha:1920)
- Full `ast::expr` variant list: `/usr/local/src/hare/stdlib/hare/ast/expr.ha:450`
