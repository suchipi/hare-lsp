// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// LSP 3.17 types and helper constructors. This module exposes the
// strongly-typed shapes that handlers exchange. Encode/decode against
// json::value happens in codec.ha.

// LSP Position. Both fields are 0-based. The character offset is in the units
// negotiated during initialize (default UTF-16 code units).
export type position = struct {
	line: u32,
	character: u32,
};

// LSP Range. end is exclusive.
export type range = struct {
	start: position,
	end: position,
};

// LSP Location: a (uri, range) pair pointing into a text document.
export type location = struct {
	uri: str,
	range: range,
};

// LSP LocationLink: a richer location used by go-to-definition variants. The
// origin_selection_range is optional; void means "no preview range".
export type location_link = struct {
	origin_selection_range: (range | void),
	target_uri: str,
	target_range: range,
	target_selection_range: range,
};

// LSP TextDocumentIdentifier.
export type text_document_identifier = struct {
	uri: str,
};

// LSP VersionedTextDocumentIdentifier.
export type versioned_text_document_identifier = struct {
	uri: str,
	version: i32,
};

// LSP TextEdit.
export type text_edit = struct {
	range: range,
	new_text: str,
};

// Position-encoding kinds negotiated at initialize.
export type position_encoding = enum {
	UTF8,
	UTF16,
	UTF32,
};

// Diagnostic severity per LSP spec.
export type diagnostic_severity = enum int {
	ERROR = 1,
	WARNING = 2,
	INFORMATION = 3,
	HINT = 4,
};

// Diagnostic tag per LSP spec.
export type diagnostic_tag = enum int {
	UNNECESSARY = 1,
	DEPRECATED = 2,
};

// LSP Diagnostic. source/code may be empty strings to omit.
export type diagnostic = struct {
	range: range,
	severity: (diagnostic_severity | void),
	code: (str | i32 | void),
	source: str,
	message: str,
	tags: []diagnostic_tag,
};

// LSP MessageType (for window/showMessage and window/logMessage).
export type message_type = enum int {
	ERROR = 1,
	WARNING = 2,
	INFO = 3,
	LOG = 4,
	DEBUG = 5,
};

// LSP TraceValue.
export type trace_value = enum {
	OFF,
	MESSAGES,
	VERBOSE,
};
