// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Structured stderr logging with levels. Distinct from window.ha's
// `log_*` family, which sends `window/logMessage` notifications to the
// client. The functions here go only to stderr — they're for the human
// operating the server (and for the wire-protocol tee enabled by
// HARE_LSP_LOG_DIR), not for the user reading the editor's output panel.
//
// Format: "<RFC3339 UTC> <LEVEL> hare-lsp: <message>". Level filtering
// is governed by `server.log_min_level`, defaulting to INFO and
// overridable via the HARE_LSP_LOG_LEVEL env var.

use ascii;
use fmt;
use io;
use os;
use time;
use time::date;

// Severity for stderr log entries. Ordered from least to most severe;
// see [[level_enabled]] for the threshold check.
export type log_level = enum {
	DEBUG = 0,
	INFO = 1,
	WARN = 2,
	ERROR = 3,
};

// Default minimum level shown when no override is set.
export def DEFAULT_LOG_LEVEL: log_level = log_level::INFO;

// Reads `HARE_LSP_LOG_LEVEL` from the environment and returns the parsed
// level. Unknown values fall back to [[DEFAULT_LOG_LEVEL]] so a typo
// doesn't silence everything.
export fn log_level_from_env() log_level = {
	const v = match (os::getenv("HARE_LSP_LOG_LEVEL")) {
	case let s: str =>
		yield s;
	case void =>
		return DEFAULT_LOG_LEVEL;
	};
	return match (parse_log_level(v)) {
	case let l: log_level =>
		yield l;
	case void =>
		yield DEFAULT_LOG_LEVEL;
	};
};

// Parses a level name. Accepts "debug", "info", "warn"/"warning",
// "error" in any case. Returns void if unrecognized.
//
// @param s: borrowed
export fn parse_log_level(s: str) (log_level | void) = {
	if (ascii::strcasecmp(s, "debug") == 0) return log_level::DEBUG;
	if (ascii::strcasecmp(s, "info") == 0) return log_level::INFO;
	if (ascii::strcasecmp(s, "warn") == 0) return log_level::WARN;
	if (ascii::strcasecmp(s, "warning") == 0) return log_level::WARN;
	if (ascii::strcasecmp(s, "error") == 0) return log_level::ERROR;
	return void;
};

// Reports whether a message at `lvl` should be emitted given the
// configured `min` threshold.
export fn level_enabled(
	min: log_level,
	lvl: log_level,
) bool = lvl: int >= min: int;

// --- emit helpers ----------------------------------------------------
// @param s: borrowed
// @param args: borrowed
export fn slog_debug(s: *server, args: fmt::formattable...) void = log_args(s,
	log_level::DEBUG, args...);

// @param s: borrowed
// @param args: borrowed
export fn slog_info(s: *server, args: fmt::formattable...) void = log_args(s,
	log_level::INFO, args...);

// @param s: borrowed
// @param args: borrowed
export fn slog_warn(s: *server, args: fmt::formattable...) void = log_args(s,
	log_level::WARN, args...);

// @param s: borrowed
// @param args: borrowed
export fn slog_error(s: *server, args: fmt::formattable...) void = log_args(s,
	log_level::ERROR, args...);

// @param s: borrowed
// @param args: borrowed
fn log_args(s: *server, lvl: log_level, args: fmt::formattable...) void = {
	if (!level_enabled(s.log_min_level, lvl)) return;
	write_log_prefix(lvl);
	match (fmt::fprintln(os::stderr, args...)) {
	case size => void;
	case io::error => void;
	// best effort; nothing useful to do on EIO

	};
};

// Writes the "<timestamp> <LEVEL> hare-lsp: " prefix to stderr. On any
// I/O or timestamp-formatting failure the prefix is degraded to a
// placeholder rather than skipped — every log line carries at least the
// level tag so callers can still grep.
fn write_log_prefix(lvl: log_level) void = {
	let d = date::from_instant(date::UTC, time::now(time::clock::REALTIME));
	// The literal "Z" suffix marks UTC; date::format treats non-'%'
	// runes as literals so we can embed it directly in the layout.
	match (date::format(os::stderr, "%Y-%m-%dT%H:%M:%SZ ", &d)) {
	case size => void;
	case io::error => void;
	};
	match (fmt::fprintf(os::stderr, "{} hare-lsp: ", level_name(lvl))) {
	case size => void;
	case io::error => void;
	};
};

fn level_name(lvl: log_level) str = {
	switch (lvl) {
	case log_level::DEBUG =>
		return "DEBUG";
	case log_level::INFO =>
		return "INFO";
	case log_level::WARN =>
		return "WARN";
	case log_level::ERROR =>
		return "ERROR";
	};
};
