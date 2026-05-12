// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Named resource caps. Each constant marks a defensive upper bound that the
// server refuses to cross. The point isn't to handle a malicious client
// gracefully; it's to fail loudly with a recognisable error rather than
// silently grow until the OS kills us.
//
// All values are conservative enough to cover real workloads (large
// monorepos, dozens of open buffers, the occasional pathological generated
// file) and small enough that hitting any cap is a strong signal that
// something has gone wrong.

// Maximum number of documents the server will keep open at once. Real
// editors rarely exceed a few dozen; 1024 leaves orders of magnitude of
// headroom while bounding the per-message scan cost in find_document.
export def MAX_OPEN_DOCUMENTS: size = 1024;

// Maximum total bytes summed across all open document buffers.
export def MAX_TOTAL_BUFFER_BYTES: size = 256 * 1024 * 1024; // 256 MiB

// Maximum number of in-flight server-initiated requests awaiting a
// response. A misbehaving client that never replies could otherwise grow
// the pending_requests slice without bound.
export def MAX_PENDING_REQUESTS: size = 4096;

// Maximum number of cancelled-but-not-yet-cleared request ids. A client
// that cancels phantom ids (or whose handler completed before the cancel
// arrived) would otherwise grow s.cancelled_ids forever, with O(n) scan
// per message.
export def MAX_CANCELLED_IDS: size = 256;

// Maximum number of diagnostics published for a single file. A file with
// thousands of parse errors makes for a useless diagnostic list and a
// large publishDiagnostics payload; we truncate and append a synthesised
// "(N more)" diagnostic so the user knows there are more.
export def MAX_DIAGNOSTICS_PER_FILE: size = 1000;

// Maximum number of workspace_index entries. Each entry is roughly a
// hundred bytes plus owned strings; a million is enough for several
// hundred thousand-file repositories and well short of memory pressure.
export def MAX_WORKSPACE_INDEX_ENTRIES: size = 1_000_000;
