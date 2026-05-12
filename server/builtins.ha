// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Documentation for Hare's built-in functions, language keywords, and
// primitive types. None of these names ever appear in a symbol index
// because they are reserved by the grammar; hover/completion features
// look them up here instead.

use strings;

// Returns the rendered signature and prose docs for `name` if it is a
// Hare built-in function, language keyword, or primitive type, or void
// otherwise. Both strings are freshly allocated; callers free them.
export fn lookup_builtin(name: str) ((str, str) | void) = {
	for (let i = 0z; i < len(builtins); i += 1) {
		if (builtins[i].name == name) {
			return (strings::dup(builtins[i].sig)!, strings::dup(builtins[i].docs)!);
		};
	};
	return void;
};

type builtin_entry = struct {
	name: str,
	sig: str,
	docs: str,
};

const builtins: [_]builtin_entry = [
	builtin_entry {
		name = "len",
		sig = "len(value) size",
		docs = "**Built-in.** Returns the length of a slice, array, "
			"or string in units of its element type. For strings "
			"the length is the number of bytes in the UTF-8 "
			"encoding, not the number of runes. `len` is a "
			"compile-time constant when applied to a value of "
			"fixed-length array type.",
	},
	builtin_entry {
		name = "alloc",
		sig = "alloc(initializer) *type\n"
			"alloc(initializer, capacity: size) []type",
		docs = "**Built-in.** Allocates memory on the heap.\n\n"
			"- `alloc(value)` allocates a single object "
			"initialised to `value` and returns a pointer to it "
			"(`*T` for type `T`).\n"
			"- `alloc([elems...], cap)` and `alloc(value, len)` "
			"allocate a slice of capacity `cap` (or length `len`) "
			"and return `[]T`.\n\n"
			"Returns a nullable pointer or slice when allocation "
			"can fail; otherwise propagates `nomem` errors per "
			"the function's effect signature. Free the result "
			"with `free` once you're done with it.",
	},
	builtin_entry {
		name = "free",
		sig = "free(object)",
		docs = "**Built-in.** Releases memory previously obtained "
			"from `alloc`, `append`, or `insert`. Accepts a "
			"pointer, slice, or string value. Passing `null` is a "
			"no-op. After `free`, the value must not be read or "
			"written; doing so is undefined behaviour.",
	},
	builtin_entry {
		name = "append",
		sig = "append(slice, items...)\n"
			"append(slice, items..., capacity: size)",
		docs = "**Built-in.** Extends a slice by appending one or "
			"more items, growing its backing allocation if "
			"needed. The first argument must be an assignable "
			"slice expression; it is updated in place.\n\n"
			"Variants:\n\n"
			"- `append(slice, item)` appends a single value.\n"
			"- `append(slice, other...)` spreads another slice's "
			"elements.\n"
			"- `append(slice, item, n)` appends `n` copies of "
			"`item`.\n\n"
			"May reallocate, invalidating any pointers into the "
			"slice's previous storage.",
	},
	builtin_entry {
		name = "insert",
		sig = "insert(slice[index], items...)",
		docs = "**Built-in.** Inserts one or more items into a "
			"slice at `index`, shifting the existing elements at "
			"and after that position toward the end. Accepts the "
			"same forms as `append` (single value, spread, or "
			"repeat-count). May reallocate the slice's backing "
			"storage.",
	},
	builtin_entry {
		name = "delete",
		sig = "delete(slice[index])\n"
			"delete(slice[start..end])",
		docs = "**Built-in.** Removes a single element or a range "
			"from a slice, shifting the remaining elements toward "
			"the front and shrinking the slice's length. Does "
			"not reallocate; the backing capacity is preserved. "
			"The slice expression must be assignable.",
	},
	builtin_entry {
		name = "abort",
		sig = "abort() never\nabort(reason: str) never",
		docs = "**Built-in.** Terminates the program immediately "
			"with a runtime error, printing `reason` (when "
			"provided) along with the source location of the "
			"call. Has type `never`, so callers don't need to "
			"provide a value after it. Use it for unrecoverable "
			"invariant violations; use `os::exit` for normal "
			"termination.",
	},
	builtin_entry {
		name = "assert",
		sig = "assert(condition: bool)\n"
			"assert(condition: bool, reason: str)",
		docs = "**Built-in.** If `condition` is false, aborts the "
			"program with `reason` (or a default message) and "
			"the source location of the call. Assertions are "
			"always evaluated at runtime; the compiler may "
			"additionally evaluate them at compile time when "
			"both operands are constant, in which case a false "
			"assertion is a compile-time error. Use "
			"`static assert` to force the compile-time form.",
	},
	builtin_entry {
		name = "offset",
		sig = "offset(struct_or_union.field) size",
		docs = "**Built-in.** Returns the byte offset of `field` "
			"within its containing struct or union type. The "
			"argument is a field selector expression, not a "
			"value; the expression is not evaluated. Evaluates "
			"to a compile-time constant.",
	},
	builtin_entry {
		name = "vastart",
		sig = "vastart() valist",
		docs = "**Built-in.** Inside a variadic function declared "
			"with C-style `...`, initialises and returns a "
			"`valist` cursor positioned at the first variadic "
			"argument. Pair every `vastart` with a matching "
			"`vaend` to release it.",
	},
	builtin_entry {
		name = "vaarg",
		sig = "vaarg(ap: valist, type) type",
		docs = "**Built-in.** Reads the next variadic argument "
			"from `ap` as the given type and advances the "
			"cursor. The caller must know the actual argument "
			"type at each position; reading the wrong type is "
			"undefined behaviour. Used inside C-style variadic "
			"(`...`) functions; Hare-style variadics (`type...`) "
			"use a regular slice instead.",
	},
	builtin_entry {
		name = "vaend",
		sig = "vaend(ap: valist)",
		docs = "**Built-in.** Releases a `valist` previously "
			"initialised by `vastart`. Must be called on every "
			"code path that returns from a variadic function "
			"after `vastart`.",
	},
	builtin_entry {
		name = "let",
		sig = "let name: type = value;\n"
			"let name = value;",
		docs = "**Keyword.** Declares a mutable binding. The type "
			"is inferred when omitted. At file scope, `let` "
			"declares a global; inside a function it declares a "
			"local that lives until its enclosing scope ends. "
			"Prefix with `static` to give a function-local "
			"binding static storage duration.",
	},
	builtin_entry {
		name = "const",
		sig = "const name: type = value;\n"
			"const name = value;",
		docs = "**Keyword.** Declares an immutable binding. Like "
			"`let` but the value cannot be reassigned. The "
			"storage still exists at runtime; for purely "
			"compile-time symbolic values, use `def` instead.",
	},
	builtin_entry {
		name = "def",
		sig = "def NAME: type = value;",
		docs = "**Keyword.** Declares a compile-time constant. "
			"`def`s have no runtime storage and may appear in "
			"contexts that require a constant expression (array "
			"lengths, case labels, other `def`s). Allowed at file "
			"scope only.",
	},
	builtin_entry {
		name = "static",
		sig = "static let name: type = value;\n"
			"static const name: type = value;\n"
			"static abort(...) | static assert(...) | "
			"static append(...) | static insert(...) | "
			"static delete(...)",
		docs = "**Keyword.** As a binding modifier, gives a "
			"function-local `let`/`const` static storage duration "
			"(the value persists across calls). As an expression "
			"modifier on `abort`/`assert`/`append`/`insert`/"
			"`delete`, requests the compile-time form: `static "
			"assert` becomes a compile-time check, and the slice "
			"builtins operate on constant slices without "
			"allocation.",
	},
	builtin_entry {
		name = "fn",
		sig = "fn name(arg: type, ...) returntype = body;\n"
			"export fn name(...) type = body;",
		docs = "**Keyword.** Declares a function. The body is a "
			"single expression (typically a block `{ ... }`). "
			"Functions are not exported by default; prefix with "
			"`export` to make them visible to other modules. Add "
			"`@init`, `@fini`, `@test`, or `@symbol` attributes "
			"before the name as needed.",
	},
	builtin_entry {
		name = "type",
		sig = "type name = underlying;\n"
			"type a = ta, b = tb, ...;",
		docs = "**Keyword.** Declares one or more type aliases at "
			"file scope. The alias is a distinct name for the "
			"same underlying type; values are assignable in both "
			"directions, but the alias participates in tagged "
			"unions and method-like dispatch separately from the "
			"underlying type.",
	},
	builtin_entry {
		name = "struct",
		sig = "struct { field: type, ... }\n"
			"struct @packed { ... }",
		docs = "**Keyword.** A composite type whose fields are "
			"laid out sequentially in memory. Field order is "
			"significant. Annotate with `@packed` to remove "
			"padding between fields, or embed an unnamed struct "
			"to flatten its fields into the outer struct.",
	},
	builtin_entry {
		name = "union",
		sig = "union { field: type, ... }",
		docs = "**Keyword.** A composite type whose fields share "
			"the same storage. The active field is not tracked; "
			"reading a field other than the one most recently "
			"written is undefined behaviour. For a discriminated "
			"alternative, use a tagged union (`(a | b | ...)`).",
	},
	builtin_entry {
		name = "enum",
		sig = "enum underlying { NAME, NAME = value, ... }",
		docs = "**Keyword.** Declares an enumerated type backed by "
			"an integer or `rune` type. Each name is a distinct "
			"value of the enum; explicit values may be assigned, "
			"otherwise each value is the previous one plus 1 "
			"(starting at 0).",
	},
	builtin_entry {
		name = "export",
		sig = "export fn ... | export type ... | export let ... | "
			"export const ... | export def ...",
		docs = "**Keyword.** Marks a declaration as visible "
			"outside its module. Without `export`, declarations "
			"are private to the module they're defined in. Only "
			"file-scope declarations can be exported.",
	},
	builtin_entry {
		name = "use",
		sig = "use module;\n"
			"use module = other::module;\n"
			"use module::{member, ...};",
		docs = "**Keyword.** Imports another module. The bare form "
			"binds the module under its last path segment "
			"(`use bufio;` makes `bufio::...` available). The "
			"alias form rebinds the name; the member form pulls "
			"selected items into the current namespace.",
	},
	builtin_entry {
		name = "if",
		sig = "if (condition) then-expr\n"
			"if (condition) then-expr else else-expr",
		docs = "**Keyword.** Conditional expression. The condition "
			"must be a `bool`. `if` is an expression: when an "
			"`else` branch is present, both branches contribute "
			"to the result type. Without `else`, the result type "
			"is `void`.",
	},
	builtin_entry {
		name = "else",
		sig = "if (cond) a else b\n"
			"for (cond) body else fallback",
		docs = "**Keyword.** The alternative branch of an `if` "
			"expression, or the fallback branch of a `for` loop "
			"that runs when the loop completes without `break`.",
	},
	builtin_entry {
		name = "for",
		sig = "for (init; cond; afterthought) body\n"
			"for (cond) body\n"
			"for (let x .. iterable) body\n"
			"for (let x => iterable) body",
		docs = "**Keyword.** A loop expression. Supports the "
			"C-style three-clause form, a single condition form, "
			"and iterator forms `..` (by value) and `=>` (by "
			"pointer). Combine with `break`, `continue`, "
			"`:label`, and an optional `else` fallback.",
	},
	builtin_entry {
		name = "match",
		sig = "match (value) {\n"
			"case let v: T => ...;\n"
			"case => default;\n"
			"};",
		docs = "**Keyword.** Pattern-matches on a value of "
			"tagged-union or nullable-pointer type. Each `case` "
			"matches one variant; `case let name: T => ...` "
			"binds the matched value to `name`. An empty `case` "
			"is the default. Exhaustive matches don't need a "
			"default.",
	},
	builtin_entry {
		name = "switch",
		sig = "switch (value) {\n"
			"case CONST, CONST => ...;\n"
			"case => default;\n"
			"};",
		docs = "**Keyword.** Selects a branch based on equality "
			"with constant case labels. Unlike `match`, `switch` "
			"operates on the value itself, not its type, and "
			"each case label must be a compile-time constant.",
	},
	builtin_entry {
		name = "case",
		sig = "case PATTERN => expression;\n"
			"case => default-expression;",
		docs = "**Keyword.** A single arm of a `match` or "
			"`switch`. Cases run in order; the first match wins "
			"and execution does not fall through. Use `=>` to "
			"separate the pattern from the body.",
	},
	builtin_entry {
		name = "break",
		sig = "break;\nbreak :label;",
		docs = "**Keyword.** Exits the innermost enclosing `for` "
			"loop. With a `:label` suffix, exits the loop bearing "
			"that label. Skips any `else` fallback attached to "
			"the loop.",
	},
	builtin_entry {
		name = "continue",
		sig = "continue;\ncontinue :label;",
		docs = "**Keyword.** Jumps to the next iteration of the "
			"innermost enclosing `for` loop. With a `:label` "
			"suffix, continues the labelled loop instead.",
	},
	builtin_entry {
		name = "return",
		sig = "return;\nreturn value;",
		docs = "**Keyword.** Exits the enclosing function with an "
			"optional return value. Pending `defer`red "
			"expressions run, in reverse order, before control "
			"leaves the function.",
	},
	builtin_entry {
		name = "defer",
		sig = "defer expression;",
		docs = "**Keyword.** Schedules `expression` to run when "
			"control leaves the enclosing scope, whether by "
			"reaching the end, returning, or unwinding past an "
			"error. Deferred expressions run in reverse order of "
			"declaration (LIFO). Use `defer` to pair allocations "
			"with `free`, opens with `close`, and so on.",
	},
	builtin_entry {
		name = "yield",
		sig = "yield;\nyield value;\nyield :label, value;",
		docs = "**Keyword.** Produces a value from the enclosing "
			"compound expression (`{ ... }`). With a `:label`, "
			"yields from the matching labelled block. Used to "
			"give a block an explicit result value.",
	},
	builtin_entry {
		name = "done",
		sig = "done",
		docs = "**Keyword.** Marker error used by iterators (such "
			"as `bufio::scan_*` or `strings::tokenize`) to signal "
			"normal completion. As a type, `done` is a "
			"zero-sized error variant.",
	},
	builtin_entry {
		name = "as",
		sig = "value as type",
		docs = "**Keyword.** Type assertion on a tagged union or "
			"nullable pointer. Asserts the runtime tag is "
			"`type` and yields the underlying value of that "
			"type. If the assertion fails the program aborts. "
			"Combine with `is` to guard the assertion.",
	},
	builtin_entry {
		name = "is",
		sig = "value is type",
		docs = "**Keyword.** Returns `true` if the tagged union "
			"or nullable pointer `value` currently holds a value "
			"of `type`. Pair with `as` to safely narrow.",
	},
	builtin_entry {
		name = "align",
		sig = "type align(N)",
		docs = "**Keyword.** Specifies the alignment, in bytes, "
			"of a struct, union, or named type. `N` must be a "
			"power of two. Used to satisfy alignment constraints "
			"of foreign ABIs or hardware.",
	},
	builtin_entry {
		name = "nullable",
		sig = "nullable *type",
		docs = "**Keyword.** Marks a pointer type as allowed to "
			"be `null`. Without `nullable`, pointer values are "
			"guaranteed non-null and may be dereferenced without "
			"a null check. A nullable pointer must be narrowed "
			"(with `match` or comparison to `null`) before "
			"dereferencing.",
	},
	builtin_entry {
		name = "nomem",
		sig = "fn name(...) type = body;  // with !nomem effect\n"
			"!nomem",
		docs = "**Keyword.** Effect marker for the out-of-memory "
			"error. A function whose effect signature includes "
			"`nomem` may fail to allocate; one without it is "
			"guaranteed not to attempt allocation that can fail.",
	},
	builtin_entry {
		name = "opaque",
		sig = "type name = opaque;",
		docs = "**Keyword.** Declares a type whose representation "
			"is not visible to other modules. Only the defining "
			"module knows the underlying type and can construct, "
			"inspect, or copy values of it. Useful for "
			"information-hiding around foreign or platform "
			"types.",
	},
	builtin_entry {
		name = "valist",
		sig = "valist",
		docs = "**Keyword.** The cursor type used to walk a "
			"C-style variadic argument list. Initialised by "
			"`vastart`, advanced by `vaarg`, and released by "
			"`vaend`. Hare-style variadics (`type...`) use a "
			"regular slice instead.",
	},
	builtin_entry {
		name = "true",
		sig = "true: bool",
		docs = "**Keyword.** The boolean truth value.",
	},
	builtin_entry {
		name = "false",
		sig = "false: bool",
		docs = "**Keyword.** The boolean falsehood value.",
	},
	builtin_entry {
		name = "null",
		sig = "null",
		docs = "**Keyword.** The null pointer value. May only be "
			"assigned to or compared with `nullable` pointer "
			"types.",
	},
	builtin_entry {
		name = "bool",
		sig = "bool",
		docs = "**Primitive type.** A boolean value: either "
			"`true` or `false`. The representation is "
			"implementation-defined but storage is at least one "
			"byte.",
	},
	builtin_entry {
		name = "int",
		sig = "int",
		docs = "**Primitive type.** The platform's natural signed "
			"integer. At least 32 bits wide; the exact width is "
			"platform-dependent. Use `i32`/`i64` when you need a "
			"specific size.",
	},
	builtin_entry {
		name = "uint",
		sig = "uint",
		docs = "**Primitive type.** The platform's natural "
			"unsigned integer. At least 32 bits wide; the exact "
			"width is platform-dependent. Use `u32`/`u64` when "
			"you need a specific size.",
	},
	builtin_entry {
		name = "size",
		sig = "size",
		docs = "**Primitive type.** Unsigned integer wide enough "
			"to hold the size of any object in memory. The "
			"result type of `len` and the type of slice indices.",
	},
	builtin_entry {
		name = "uintptr",
		sig = "uintptr",
		docs = "**Primitive type.** Unsigned integer wide enough "
			"to hold any pointer value. Use when manipulating "
			"pointer-sized integers (FFI, low-level bit "
			"twiddling); prefer `*T` or `size` otherwise.",
	},
	builtin_entry {
		name = "i8",
		sig = "i8",
		docs = "**Primitive type.** Signed 8-bit integer.",
	},
	builtin_entry {
		name = "i16",
		sig = "i16",
		docs = "**Primitive type.** Signed 16-bit integer.",
	},
	builtin_entry {
		name = "i32",
		sig = "i32",
		docs = "**Primitive type.** Signed 32-bit integer.",
	},
	builtin_entry {
		name = "i64",
		sig = "i64",
		docs = "**Primitive type.** Signed 64-bit integer.",
	},
	builtin_entry {
		name = "u8",
		sig = "u8",
		docs = "**Primitive type.** Unsigned 8-bit integer. The "
			"element type of byte slices (`[]u8`), Hare's "
			"standard representation for binary data.",
	},
	builtin_entry {
		name = "u16",
		sig = "u16",
		docs = "**Primitive type.** Unsigned 16-bit integer.",
	},
	builtin_entry {
		name = "u32",
		sig = "u32",
		docs = "**Primitive type.** Unsigned 32-bit integer.",
	},
	builtin_entry {
		name = "u64",
		sig = "u64",
		docs = "**Primitive type.** Unsigned 64-bit integer.",
	},
	builtin_entry {
		name = "f32",
		sig = "f32",
		docs = "**Primitive type.** IEEE 754 binary32 "
			"(single-precision) floating point.",
	},
	builtin_entry {
		name = "f64",
		sig = "f64",
		docs = "**Primitive type.** IEEE 754 binary64 "
			"(double-precision) floating point.",
	},
	builtin_entry {
		name = "rune",
		sig = "rune",
		docs = "**Primitive type.** A single Unicode scalar "
			"value. 32 bits wide. Strings (`str`) are stored as "
			"UTF-8 bytes; iterating runes requires decoding.",
	},
	builtin_entry {
		name = "str",
		sig = "str",
		docs = "**Primitive type.** A UTF-8 encoded string. "
			"Internally a length plus a pointer to bytes; values "
			"are immutable and may be heap-allocated. Convert to "
			"`[]u8` with `strings::toutf8` to manipulate the raw "
			"bytes.",
	},
	builtin_entry {
		name = "void",
		sig = "void",
		docs = "**Primitive type.** The zero-sized type. The "
			"result type of expressions that yield no value, and "
			"a frequent member of tagged unions to indicate "
			"\"nothing here.\"",
	},
	builtin_entry {
		name = "never",
		sig = "never",
		docs = "**Primitive type.** The empty type, inhabited by "
			"no values. The return type of functions that never "
			"return (e.g. `abort`). Implicitly convertible to "
			"every other type, so a `never`-typed expression may "
			"appear wherever any value is expected.",
	},
	builtin_entry {
		name = "@test",
		sig = "@test fn name() void = body;",
		docs = "**Attribute.** Marks a function as a test case. "
			"`@test` functions are only compiled into the binary "
			"when building with `hare test`, and are then "
			"discovered and run by the test harness. Use "
			"`assert` inside the body to express expectations.",
	},
	builtin_entry {
		name = "@init",
		sig = "@init fn name() void = body;",
		docs = "**Attribute.** Schedules a function to run once "
			"before `main`. Useful for one-time initialisation "
			"of module-level state. The relative order of "
			"`@init` functions across modules is unspecified, so "
			"they must not depend on one another.",
	},
	builtin_entry {
		name = "@fini",
		sig = "@fini fn name() void = body;",
		docs = "**Attribute.** Schedules a function to run once "
			"after `main` returns, in reverse order of `@init`. "
			"Useful for releasing module-level resources. Does "
			"not run on `abort` or `os::exit`.",
	},
	builtin_entry {
		name = "@packed",
		sig = "struct @packed { ... }",
		docs = "**Attribute.** Removes padding between struct "
			"fields so the layout matches the source order with "
			"no gaps. Useful for binary formats and FFI. May "
			"produce misaligned fields, which can be slower or "
			"unsafe to access on some architectures.",
	},
	builtin_entry {
		name = "@symbol",
		sig = `@symbol("external_name") fn name(...) ...;`,
		docs = "**Attribute.** Overrides the linker symbol for a "
			"function or variable. Use to interoperate with "
			"foreign code that expects a specific name, or to "
			"export Hare-defined symbols under a non-default "
			"identifier.",
	},
	builtin_entry {
		name = "@threadlocal",
		sig = "@threadlocal let name: type = value;",
		docs = "**Attribute.** Gives a global binding "
			"thread-local storage: each thread sees its own "
			"independent copy. Only allowed on file-scope "
			"declarations.",
	},
	builtin_entry {
		name = "@undefined",
		sig = "let name: type = @undefined;",
		docs = "**Attribute.** Initialises a binding (or a "
			"position in a tuple/array literal) without giving "
			"it a definite value. Reading the value before "
			"writing it is undefined behaviour. Use sparingly, "
			"only when the cost of zeroing matters and the code "
			"provably writes before reading.",
	},
];
// --- declaration keywords -----------------------------------
// --- control flow keywords ---------------------------------
// --- type-related operators --------------------------------
// --- constants ---------------------------------------------
// --- primitive types ---------------------------------------
// --- attributes --------------------------------------------
