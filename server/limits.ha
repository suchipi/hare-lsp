// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Named resource caps. Each field marks a defensive upper bound that the
// server refuses to cross. The point isn't to handle a malicious client
// gracefully; it's to fail loudly with a recognisable error rather than
// silently grow until the OS kills us.
//
// All defaults are conservative enough to cover real workloads (large
// monorepos, dozens of open buffers, the occasional pathological generated
// file) and small enough that hitting any cap is a strong signal that
// something has gone wrong.
//
// Caps are configurable at runtime via `hare.limits.*` settings (see
// [[apply_settings]]); whatever the user sets is what the server
// enforces, with no additional non-configurable ceiling.
// Runtime-configurable resource caps. Populated from `hare.limits.*`
// settings; defaults via [[default_limits]].
export type limits = struct {
	// Maximum total bytes summed across all open document buffers.
	max_total_buffer_bytes: size,
	// Maximum number of diagnostics published for a single file. A
	// file with thousands of parse errors makes for a useless
	// diagnostic list and a large publishDiagnostics payload; we
	// truncate and append a synthesised "(N more)" diagnostic so the
	// user knows there are more.
	max_diagnostics_per_file: size,
};

// Returns a limits struct with the conservative defaults.
export fn default_limits() limits = limits {
	max_total_buffer_bytes = 256 * 1024 * 1024,
	max_diagnostics_per_file = 1000,
};
