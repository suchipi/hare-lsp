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
// [[apply_settings]]); the analysis-side
// `analysis::MAX_INDEX_ENTRIES` is a hard ceiling the configurable
// value cannot exceed.

// Runtime-configurable resource caps. Populated from `hare.limits.*`
// settings; defaults via [[default_limits]].
export type limits = struct {
	// Maximum number of documents the server will keep open at once.
	// Real editors rarely exceed a few dozen; the default leaves
	// orders of magnitude of headroom while bounding the per-message
	// scan cost in find_document.
	max_open_documents: size,

	// Maximum total bytes summed across all open document buffers.
	max_total_buffer_bytes: size,

	// Maximum number of in-flight server-initiated requests awaiting a
	// response. A misbehaving client that never replies could
	// otherwise grow the pending_requests slice without bound.
	max_pending_requests: size,

	// Maximum number of cancelled-but-not-yet-cleared request ids. A
	// client that cancels phantom ids (or whose handler completed
	// before the cancel arrived) would otherwise grow s.cancelled_ids
	// forever, with O(n) scan per message.
	max_cancelled_ids: size,

	// Maximum number of diagnostics published for a single file. A
	// file with thousands of parse errors makes for a useless
	// diagnostic list and a large publishDiagnostics payload; we
	// truncate and append a synthesised "(N more)" diagnostic so the
	// user knows there are more.
	max_diagnostics_per_file: size,

	// Maximum number of workspace_index entries. Each entry is roughly
	// a hundred bytes plus owned strings; the default is enough for
	// several hundred thousand-file repositories and well short of
	// memory pressure.
	max_workspace_index_entries: size,
};

// Returns a limits struct with the conservative defaults.
export fn default_limits() limits = limits {
	max_open_documents = 1024,
	max_total_buffer_bytes = 256 * 1024 * 1024,
	max_pending_requests = 4096,
	max_cancelled_ids = 256,
	max_diagnostics_per_file = 1000,
	max_workspace_index_entries = 1_000_000,
};
