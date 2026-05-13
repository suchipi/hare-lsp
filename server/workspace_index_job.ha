// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Cooperative chunked indexing.
//
// Hare is single-threaded and the LSP loop reads one message at a time, so
// a long synchronous walk of every `*.ha` under a workspace folder (or
// the entire stdlib) blocks all other requests. Instead, we split
// indexing into two phases:
//
//   1. Discovery (synchronous, cheap): walk the directory tree and
//      collect file paths into a [[workspace_index_job]].
//   2. Indexing (chunked): [[drain_index_job]] processes a small batch
//      (default ~50 files) and yields back to the main loop. Progress
//      is reported via `$/progress` and the job can be cancelled with
//      `window/workDoneProgress/cancel`.
//
// Jobs are queued in `server.pending_index_jobs` and drained FIFO so
// workspace and stdlib indexing can coexist without contending for the
// same target index. The main loop drives batches in two situations:
// after every dispatched message (so a busy editor amortizes indexing
// across its traffic), and via `input_ready` between blocking reads (so
// a quiet editor still makes progress while waiting for the next
// message). Small workspaces finish inline inside the original
// triggering handler (see [[INDEX_INLINE_BATCHES]]).

use analysis;
use fmt;

// Per-tick budget. Sized small enough to keep latency under ~100 ms for
// the median file, large enough that overhead per tick (progress
// notification, cancellation check) is amortized.
def INDEX_BATCH_SIZE: size = 50;

// Inline draining inside the triggering handler. Small workspaces (a
// few hundred files at most) finish immediately; anything bigger spills
// into the background queue.
def INDEX_INLINE_BATCHES: size = 4;

// One queued indexing job. Owned by `server.pending_index_jobs`.
export type workspace_index_job = struct {
	paths: []str,
	cursor: size,
	total: size,
	token: progress_token,
	// The index the job populates (workspace or stdlib).
	target: *analysis::workspace_index,
	// Human-readable progress title and completion log message.
	title: str,
	done_msg_prefix: str,
	// Whether the begin/report progress notifications have been sent.
	begin_sent: bool,
	// Set when a workDoneProgress/cancel arrived for this token. We
	// stop processing further files but keep `cursor` at the real
	// count so the end notification reflects how much actually got
	// indexed.
	cancelled: bool,
};

// Enqueues an index job covering every `*.ha` file reachable under any
// of `roots`. Performs the discovery walk synchronously, creates a
// progress token, and pushes the job onto `s.pending_index_jobs`. Drains
// a few batches inline so small workspaces complete before returning.
//
// `target` selects which index gets populated (typically
// `&s.workspace_index` or `&s.stdlib_index`). `title` is shown to the
// user as the progress label; `done_msg_prefix` is the human-readable
// prefix of the completion log line (e.g. "hare-lsp: indexed").
//
// `roots` is not consumed: the caller retains ownership of both the
// slice and its strings. If an existing job is already populating the
// same `target`, the new paths are appended to it instead of creating a
// second job.
export fn start_index_job(
	s: *server,
	roots: []str,
	target: *analysis::workspace_index,
	title: str,
	done_msg_prefix: str,
) void = {
	let paths: []str = [];
	for (let i = 0z; i < len(roots); i += 1) {
		const found = analysis::collect_ha_files(roots[i]);
		for (let j = 0z; j < len(found); j += 1) {
			append(paths, found[j])!;
		};
		free(found);
	};
	if (len(paths) == 0) return;

	// Coalesce: if an existing job targets the same index, extend it.
	for (let i = 0z; i < len(s.pending_index_jobs); i += 1) {
		const job = s.pending_index_jobs[i];
		if (job.target != target) continue;
		for (let j = 0z; j < len(paths); j += 1) {
			append(job.paths, paths[j])!;
		};
		free(paths);
		job.total = len(job.paths);
		drain_index_job_inline(s, INDEX_INLINE_BATCHES);
		return;
	};

	const token = match (progress_create(s)) {
	case let pair: (progress_token, i64) =>
		yield pair.0;
	case void =>
		// Client doesn't support progress or transport failed —
		// just drain everything inline as a fallback.
		drain_paths_no_progress(s, target, paths, done_msg_prefix);
		analysis::free_path_slice(paths);
		return;
	};

	let job =
		alloc(workspace_index_job {
			paths = paths,
			cursor = 0,
			total = len(paths),
			token = token,
			target = target,
			title = title,
			done_msg_prefix = done_msg_prefix,
			begin_sent = false,
			cancelled = false,
		})!;
	append(s.pending_index_jobs, job)!;
	drain_index_job_inline(s, INDEX_INLINE_BATCHES);
};

// Drains one batch of the head job (if any). Called from the main
// dispatch loop between messages. No-op when the queue is empty.
export fn drain_index_job(s: *server) void = {
	if (len(s.pending_index_jobs) == 0) return;
	const job = s.pending_index_jobs[0];
	drain_one_batch(s, job);
	if (job.cancelled || job.cursor >= len(job.paths)) {
		finish_head_job(s);
	};
};

fn drain_index_job_inline(s: *server, max_batches: size) void = {
	for (let i = 0z; i < max_batches; i += 1) {
		if (len(s.pending_index_jobs) == 0) return;
		const job = s.pending_index_jobs[0];
		drain_one_batch(s, job);
		if (job.cancelled || job.cursor >= len(job.paths)) {
			finish_head_job(s);
		};
	};
};

fn drain_one_batch(s: *server, job: *workspace_index_job) void = {
	if (!job.begin_sent) {
		progress_begin(s, job.token, job.title, "", 0, true);
		job.begin_sent = true;
	};
	if (progress_is_cancelled(s, job.token)) {
		job.cancelled = true;
		return;
	};
	const limit = if (job.cursor + INDEX_BATCH_SIZE > len(job.paths))
		len(job.paths)
		else job.cursor + INDEX_BATCH_SIZE;
	for (let i = job.cursor; i < limit; i += 1) {
		const _ = analysis::read_and_index_file(job.target, job.paths[i]);
	};
	job.cursor = limit;
	if (job.cursor < len(job.paths)) {
		const pct = if (job.total > 0) (job.cursor * 100 / job.total): int else -1;
		const msg = fmt::asprintf("{} / {} files", job.cursor, job.total)!;
		defer free(msg);
		progress_report(s, job.token, msg, pct);
	};
};

fn finish_head_job(s: *server) void = {
	if (len(s.pending_index_jobs) == 0) return;
	const job = s.pending_index_jobs[0];
	const suffix = if (job.cancelled) " (cancelled)" else "";
	const msg =
		fmt::asprintf("{} {} file(s){}", job.done_msg_prefix, job.cursor, suffix)!;
	defer free(msg);
	if (job.begin_sent) {
		progress_end(s, job.token, msg);
	};
	log_info(s, msg);
	request_diagnostic_refresh(s);
	analysis::free_path_slice(job.paths);
	free(job.token);
	free(job);
	delete(s.pending_index_jobs[0]);
};

fn drain_paths_no_progress(
	s: *server,
	target: *analysis::workspace_index,
	paths: []str,
	done_msg_prefix: str,
) void = {
	for (let i = 0z; i < len(paths); i += 1) {
		const _ = analysis::read_and_index_file(target, paths[i]);
	};
	const msg = fmt::asprintf("{} {} file(s)", done_msg_prefix, len(paths))!;
	defer free(msg);
	log_info(s, msg);
	request_diagnostic_refresh(s);
};

// Releases all queued jobs at server shutdown. Does not emit progress
// notifications — the transport is going away.
export fn finish_pending_index(s: *server) void = {
	for (let i = 0z; i < len(s.pending_index_jobs); i += 1) {
		const job = s.pending_index_jobs[i];
		analysis::free_path_slice(job.paths);
		free(job.token);
		free(job);
	};
	free(s.pending_index_jobs);
	s.pending_index_jobs = [];
};
