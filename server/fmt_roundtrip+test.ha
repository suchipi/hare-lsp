// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Empirical cross-check: walk every .ha file under the project root,
// format it through the doc-emitting builders, and assert three
// invariants for the result:
//
//   1. The output reparses without error.
//   2. No `//` comments are lost.
//   3. No formatted line exceeds 80 columns (with tabs counted as one
//      column, matching the pretty-printer's tab convention; the Hare
//      style guide's documented exceptions — long error strings,
//      pre-existing 80+ source lines — are tolerated by NOT failing
//      when the source itself already exceeded 80 columns).
//
// The walk skips `.cache/`, `.tmp/`, and `editors/` (vendor / vscode
// extension code), since those aren't ours to reformat.

use analysis;
use fmt;
use fs;
use io;
use memio;
use os;
use strings;

// Recursively collects every regular file under `root` whose name
// ends in ".ha". Skips dot-directories and `editors/` (vscode
// extension TypeScript / `node_modules`).
fn collect_ha_files(root: str) []str = {
	let out: []str = [];
	walk_dir(root, "", &out);
	return out;
};

fn walk_dir(root: str, rel: str, out: *[]str) void = {
	const path = if (rel ==
	"") strings::dup(root)! else strings::concat(root, "/", rel)!;
	defer free(path);
	const it = match (fs::iter(os::cwd, path)) {
	case let p: *fs::iterator =>
		yield p;
	case fs::error =>
		return;
	};
	defer fs::finish(it);

	for (true) {
		const ent = match (fs::next(it)) {
		case let e: fs::dirent =>
			yield e;
		case done =>
			break;
		case fs::error =>
			break;
		};
		if (ent.name == "." || ent.name == "..") continue;
		// Skip dot-prefixed dirs (.cache, .tmp, .git, .claude, …)
		// and the vscode extension's directory.
		if (strings::hasprefix(ent.name, ".")) continue;
		if (rel == "" && ent.name == "editors") continue;

		const child_rel = if (rel ==
		"") strings::dup(ent.name)! else strings::concat(rel, "/", ent.name)!;
		if (fs::isdir(ent.ftype)) {
			walk_dir(root, child_rel, out);
			free(child_rel);
		} else if (fs::isfile(ent.ftype) && strings::hassuffix(ent.name, ".ha")) {
			let cur = *out;
			append(cur, child_rel)!;
			*out = cur;
		} else {
			free(child_rel);
		};
	};
};

// Reads `path` (relative to `root`) and returns its bytes. Returns
// void on any I/O error.
fn read_file_bytes(root: str, rel: str) ([]u8 | void) = {
	const path = strings::concat(root, "/", rel)!;
	defer free(path);
	const f = match (os::open(path)) {
	case let f: io::file =>
		yield f;
	case fs::error =>
		return;
	};
	defer io::close(f)!;
	match (io::drain(f)) {
	case let b: []u8 =>
		return b;
	case io::error =>
		return;
	};
};

// Counts line-starting `//` outside strings / runes / raw strings.
// Mirrors `collect_comments` semantics — same scanner, just counts.
fn count_comments(data: []u8) size = {
	const cs = collect_comments(data);
	defer finish_comments(cs);
	return len(cs);
};

// Formats `data` through build_subunit_doc + pretty. Returns the
// rendered string (caller frees) or void if parse failed.
//
// Uses `analysis::parse_recover` (not `hare::parse::subunit` directly)
// so that AST `loc.off` values are translated from the lexer's native
// rune indices to byte offsets, matching what `server::format_source`
// passes into `build_subunit_doc`. Without that translation the
// formatter slices the wrong bytes for any literal that follows a
// multi-byte UTF-8 sequence in the source.
fn format_bytes(data: []u8) (str | void) = {
	if (len(data) == 0) return strings::dup("")!;
	let pr = analysis::parse_recover(data, "<roundtrip>");
	defer analysis::finish_parse_result(&pr);
	if (len(pr.errors) > 0) return;

	const cs = collect_comments(data);
	defer finish_comments(cs);
	const bl = collect_blank_lines(data);
	defer free(bl);
	let cursor = comment_cursor { comments = cs, pos = 0 };
	let d = build_subunit_doc(&pr.subunit, &cursor, bl, data);
	defer doc_finish(&d);

	let buf = memio::dynamic();
	defer io::close(&buf)!;
	match (pretty(&buf, &d, 80, 0)) {
	case size => void;
	case io::error =>
		return;
	};
	return strings::dup(memio::string(&buf)!)!;
};

// Returns the maximum line length in `s`. Counts bytes, with tabs as
// one byte each — matches what pretty's column tracker uses.
fn max_line_length(s: str) size = {
	const lines = strings::split(s, "\n")!;
	defer free(lines);
	let max: size = 0;
	for (let i = 0z; i < len(lines); i += 1) {
		if (len(lines[i]) > max) max = len(lines[i]);
	};
	return max;
};

// Returns true iff every formatted line is <= 80 cols, OR the source
// itself already had a line > 80 cols (pre-existing overflow is the
// user's, not the formatter's).
fn line_length_ok(formatted: str, source: []u8) bool = {
	const fmt_max = max_line_length(formatted);
	if (fmt_max <= 80) return true;
	const src_str = strings::fromutf8(source)!;
	const src_max = max_line_length(src_str);
	return src_max >= fmt_max;
};

// Reparses the formatted string and returns void on success, or a
// short human-readable error message on failure.
fn reparse_error(formatted: str) (void | str) = {
	const data = strings::toutf8(formatted);
	if (len(data) == 0) return;
	let pr = analysis::parse_recover(data, "<reparse>");
	defer analysis::finish_parse_result(&pr);
	if (len(pr.errors) > 0) {
		return strings::dup(pr.errors[0].message)!;
	};
};

@test fn fmt_roundtrip_repo_files() void = {
	const root = ".";
	const files = collect_ha_files(root);
	defer strings::freeall(files);

	if (len(files) == 0) {
		// Sandboxed test runner without filesystem access — nothing
		// to verify. Don't fail; the in-process unit and e2e tests
		// already cover the formatter's behavior on synthetic
		// inputs.
		return;
	};

	let formatted_count: size = 0;
	let parse_skipped: size = 0;
	let reparse_failures: []str = [];
	defer strings::freeall(reparse_failures);
	let comment_loss_failures: []str = [];
	defer strings::freeall(comment_loss_failures);
	let line_length_failures: []str = [];
	defer strings::freeall(line_length_failures);
	let worst_overshoot: size = 0;

	for (let i = 0z; i < len(files); i += 1) {
		const data = match (read_file_bytes(root, files[i])) {
		case let b: []u8 =>
			yield b;
		case void =>
			continue;
		};
		defer free(data);

		const formatted = match (format_bytes(data)) {
		case let s: str =>
			yield s;
		case void =>
			parse_skipped += 1;
			continue;
		};
		defer free(formatted);
		formatted_count += 1;

		match (reparse_error(formatted)) {
		case void => void;
		case let err: str =>
			defer free(err);
			const msg = fmt::asprintf("{}: {}", files[i], err)!;
			append(reparse_failures, msg)!;
			const safe_name = strings::replace(files[i], "/", "__")!;
			defer free(safe_name);
			const dump_path = strings::concat(".tmp/reparse-fail-", safe_name)!;
			defer free(dump_path);
			match (os::create(dump_path, 0o644: fs::mode)) {
			case let f: io::file =>
				io::writeall(f, strings::toutf8(formatted))!;
				io::close(f)!;
			// Dump each reparse-failing output to a per-file
			// path under .tmp/reparse-fail/ so we can inspect
			// what we produced. Helps diagnose during
			// development; harmless once the test passes.

			case fs::error => void;
			};
			continue;
		};

		const before = count_comments(data);
		const after = count_comments(strings::toutf8(formatted));
		if (after < before) {
			const msg =
				fmt::asprintf("{} ({} -> {} comments)", files[i], before, after)!;
			append(comment_loss_failures, msg)!;
		};

		if (!line_length_ok(formatted, data)) {
			const fmax = max_line_length(formatted);
			const src_max = max_line_length(strings::fromutf8(data)!);
			const overshoot = fmax - src_max;
			const msg =
				fmt::asprintf(
					"{} (max line {}, source max {}, overshoot {})",
					files[i],
					fmax,
					src_max,
					overshoot,
				)!;
			append(line_length_failures, msg)!;
			// Dump the worst-overshoot file's formatted output
			// to .tmp/overlong-fail.txt so the developer can
			// inspect what produced the long lines. This is
			// purely diagnostic; the assertions below are what
			// drives the test result.
			if (overshoot > worst_overshoot) {
				worst_overshoot = overshoot;
				const dump_path = ".tmp/overlong-fail.txt";
				match (os::create(dump_path, 0o644: fs::mode)) {
				case let f: io::file =>
					io::writeall(f, strings::toutf8(formatted))!;
					io::close(f)!;
				case fs::error => void;
				};
			};
		};
	};

	if (len(reparse_failures) > 0) {
		fmt::errorln("reparse failures:")!;
		for (let i = 0z; i < len(reparse_failures); i += 1) {
			fmt::errorfln("  {}", reparse_failures[i])!;
		};
	};
	if (len(comment_loss_failures) > 0) {
		fmt::errorln("comment-loss failures:")!;
		for (let i = 0z; i < len(comment_loss_failures); i += 1) {
			fmt::errorfln("  {}", comment_loss_failures[i])!;
		};
	};
	if (len(line_length_failures) > 0) {
		fmt::errorln("line-length failures:")!;
		for (let i = 0z; i < len(line_length_failures); i += 1) {
			fmt::errorfln("  {}", line_length_failures[i])!;
		};
	};
	assert(len(reparse_failures) == 0, "every formatted file must reparse");
	assert(
		len(comment_loss_failures) == 0,
		"no comment may be lost during formatting"
	);
	assert(
		len(line_length_failures) == 0,
		"no formatted line may exceed 80 columns unless the source already did"
	);
};
