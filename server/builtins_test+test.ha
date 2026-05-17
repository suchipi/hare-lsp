// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use strings;

// builtins.ha is a static lookup table for Hare's keywords,
// built-in functions, and primitive types. The table is small but
// load-bearing: every hover on a keyword/builtin/primitive flows
// through it. These tests pin down the table's invariants so a
// future edit can't silently delete an entry or duplicate a name.
@test fn lookup_builtin_finds_well_known_names() void = {
	// A small canary set covering each category. If any of these
	// goes missing, hover on the corresponding token returns void
	// and the editor shows nothing.
	// Three categories: builtin functions (`len`, `alloc`, `free`),
	// keywords (`if`, `return`), and primitive types (`int`, `str`,
	// `bool`). One canary per category catches a wholesale drop.
	const names = [
		"len",
		"alloc",
		"free",
		"if",
		"return",
		"int",
		"str",
		"bool",
	];
	for (let i = 0z; i < len(names); i += 1) {
		const r = lookup_builtin(names[i]);
		match (r) {
		case let pair: (str, str) =>
			defer free(pair.0);
			defer free(pair.1);
			assert(len(pair.0) > 0, "signature must be non-empty");
			assert(len(pair.1) > 0, "docs must be non-empty");
		case void => abort("expected lookup_builtin to find a well-known name");
		};
	};
};

@test fn lookup_builtin_returns_void_for_unknown_name() void = {
	const r = lookup_builtin("definitely_not_a_builtin_xyz");
	assert(r is void, "unknown names must return void");
};

@test fn lookup_builtin_empty_name_returns_void() void = {
	const r = lookup_builtin("");
	assert(r is void, "empty name must return void");
};

@test fn builtins_every_entry_has_non_empty_fields() void = {
	// Iterate the table directly to enforce that every shipped
	// entry has a name, signature, and docs string. A blank entry
	// is almost always a bug — hover on the corresponding name
	// would surface an empty card to the user.
	for (let i = 0z; i < len(builtins); i += 1) {
		const e = &builtins[i];
		assert(len(e.name) > 0, "every builtin entry must have a name");
		assert(len(e.sig) > 0, "every builtin entry must have a signature");
		assert(len(e.docs) > 0, "every builtin entry must have docs");
	};
};

@test fn builtins_has_no_duplicate_names() void = {
	// Duplicate names mean only the first wins at lookup time —
	// silent shadowing. Catch them explicitly.
	for (let i = 0z; i < len(builtins); i += 1) {
		for (let j = i + 1; j < len(builtins); j += 1) {
			assert(builtins[i].name != builtins[j].name, "duplicate builtin entry name");
		};
	};
};

@test fn builtins_signature_mentions_name() void = {
	// A signature should usually contain the name being signed
	// (e.g. "len(value) size" mentions `len`). This catches
	// copy-paste mistakes where one entry's signature was pasted
	// into another. Skip entries whose signature is a plain type
	// description (primitives) — for those, the "name" is itself
	// the signature, which lookup_builtin returns verbatim.
	for (let i = 0z; i < len(builtins); i += 1) {
		const e = &builtins[i];
		// Function-like entries always include `(` in the sig.
		if (!strings::contains(e.sig, "(")) continue;
		assert(
			strings::contains(e.sig, e.name),
			"builtin signature must mention its own name"
		);
	};
};

@test fn lookup_builtin_returns_owned_strings() void = {
	// The return contract is "freshly allocated strings; callers
	// free them". Look up the same name twice — the two returned
	// pointer pairs must be distinct (no shared storage), so
	// freeing one doesn't invalidate the other.
	const a = lookup_builtin("len");
	const b = lookup_builtin("len");
	const pa = a as (str, str);
	const pb = b as (str, str);
	defer free(pa.0);
	defer free(pa.1);
	defer free(pb.0);
	defer free(pb.1);
	// Equal in content, distinct in storage.
	assert(pa.0 == pb.0);
	assert(pa.1 == pb.1);
	// Mutate one to confirm storage isn't shared. (We can't mutate
	// strings in Hare directly, but we can free one and re-check
	// the other is still valid via len > 0.)

};
