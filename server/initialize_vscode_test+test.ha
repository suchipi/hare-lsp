// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Regression test: feeds the exact `initialize` payload sent by VSCode's
// vscode-languageclient (captured from a real session) into the server and
// verifies the response.

use bufio;
use encoding::json;
use io;
use lsp;
use memio;
use strings;

// The `params` object of the `initialize` request sent by VSCode's
// vscode-languageclient 9.x to our server, captured from a real session.
// Process id and workspace path have been generalized but the capability
// shape is verbatim.
const VSCODE_INITIALIZE_PARAMS: str =
	`{
    "processId": 12345,
    "clientInfo": {
        "name": "Visual Studio Code",
        "version": "1.119.0"
    },
    "locale": "en",
    "rootPath": "/workspace",
    "rootUri": "file:///workspace",
    "capabilities": {
        "workspace": {
            "applyEdit": true,
            "workspaceEdit": {
                "documentChanges": true,
                "resourceOperations": ["create", "rename", "delete"],
                "failureHandling": "textOnlyTransactional",
                "normalizesLineEndings": true,
                "changeAnnotationSupport": {"groupsOnLabel": true}
            },
            "configuration": true,
            "didChangeWatchedFiles": {
                "dynamicRegistration": true,
                "relativePatternSupport": true
            },
            "symbol": {
                "dynamicRegistration": true,
                "symbolKind": {
                    "valueSet": [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26]
                },
                "tagSupport": {"valueSet": [1]},
                "resolveSupport": {"properties": ["location.range"]}
            },
            "codeLens": {"refreshSupport": true},
            "executeCommand": {"dynamicRegistration": true},
            "didChangeConfiguration": {"dynamicRegistration": true},
            "workspaceFolders": true,
            "foldingRange": {"refreshSupport": true},
            "semanticTokens": {"refreshSupport": true},
            "fileOperations": {
                "dynamicRegistration": true,
                "didCreate": true, "didRename": true, "didDelete": true,
                "willCreate": true, "willRename": true, "willDelete": true
            },
            "inlineValue": {"refreshSupport": true},
            "inlayHint": {"refreshSupport": true},
            "diagnostics": {"refreshSupport": true}
        },
        "textDocument": {
            "publishDiagnostics": {
                "relatedInformation": true,
                "versionSupport": false,
                "tagSupport": {"valueSet": [1, 2]},
                "codeDescriptionSupport": true,
                "dataSupport": true
            },
            "synchronization": {
                "dynamicRegistration": true,
                "willSave": true,
                "willSaveWaitUntil": true,
                "didSave": true
            },
            "completion": {
                "dynamicRegistration": true,
                "contextSupport": true,
                "completionItem": {
                    "snippetSupport": true,
                    "commitCharactersSupport": true,
                    "documentationFormat": ["markdown", "plaintext"],
                    "deprecatedSupport": true,
                    "preselectSupport": true,
                    "tagSupport": {"valueSet": [1]},
                    "insertReplaceSupport": true,
                    "resolveSupport": {"properties": ["documentation", "detail", "additionalTextEdits"]},
                    "insertTextModeSupport": {"valueSet": [1, 2]},
                    "labelDetailsSupport": true
                },
                "insertTextMode": 2,
                "completionItemKind": {
                    "valueSet": [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25]
                },
                "completionList": {
                    "itemDefaults": ["commitCharacters", "editRange", "insertTextFormat", "insertTextMode", "data"]
                }
            },
            "hover": {
                "dynamicRegistration": true,
                "contentFormat": ["markdown", "plaintext"]
            },
            "signatureHelp": {
                "dynamicRegistration": true,
                "signatureInformation": {
                    "documentationFormat": ["markdown", "plaintext"],
                    "parameterInformation": {"labelOffsetSupport": true},
                    "activeParameterSupport": true
                },
                "contextSupport": true
            },
            "definition": {"dynamicRegistration": true, "linkSupport": true},
            "references": {"dynamicRegistration": true},
            "documentHighlight": {"dynamicRegistration": true},
            "documentSymbol": {
                "dynamicRegistration": true,
                "symbolKind": {
                    "valueSet": [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26]
                },
                "hierarchicalDocumentSymbolSupport": true,
                "tagSupport": {"valueSet": [1]},
                "labelSupport": true
            },
            "codeAction": {
                "dynamicRegistration": true,
                "isPreferredSupport": true,
                "disabledSupport": true,
                "dataSupport": true,
                "resolveSupport": {"properties": ["edit"]},
                "codeActionLiteralSupport": {
                    "codeActionKind": {
                        "valueSet": ["", "quickfix", "refactor", "refactor.extract", "refactor.inline", "refactor.rewrite", "source", "source.organizeImports"]
                    }
                },
                "honorsChangeAnnotations": true
            },
            "codeLens": {"dynamicRegistration": true},
            "formatting": {"dynamicRegistration": true},
            "rangeFormatting": {"dynamicRegistration": true, "rangesSupport": true},
            "onTypeFormatting": {"dynamicRegistration": true},
            "rename": {
                "dynamicRegistration": true,
                "prepareSupport": true,
                "prepareSupportDefaultBehavior": 1,
                "honorsChangeAnnotations": true
            },
            "documentLink": {"dynamicRegistration": true, "tooltipSupport": true},
            "typeDefinition": {"dynamicRegistration": true, "linkSupport": true},
            "implementation": {"dynamicRegistration": true, "linkSupport": true},
            "colorProvider": {"dynamicRegistration": true},
            "foldingRange": {
                "dynamicRegistration": true,
                "rangeLimit": 5000,
                "lineFoldingOnly": true,
                "foldingRangeKind": {"valueSet": ["comment", "imports", "region"]},
                "foldingRange": {"collapsedText": false}
            },
            "declaration": {"dynamicRegistration": true, "linkSupport": true},
            "selectionRange": {"dynamicRegistration": true},
            "callHierarchy": {"dynamicRegistration": true},
            "semanticTokens": {
                "dynamicRegistration": true,
                "tokenTypes": ["namespace", "type", "class", "enum", "interface", "struct", "typeParameter", "parameter", "variable", "property", "enumMember", "event", "function", "method", "macro", "keyword", "modifier", "comment", "string", "number", "regexp", "operator", "decorator"],
                "tokenModifiers": ["declaration", "definition", "readonly", "static", "deprecated", "abstract", "async", "modification", "documentation", "defaultLibrary"],
                "formats": ["relative"],
                "requests": {"range": true, "full": {"delta": true}},
                "multilineTokenSupport": false,
                "overlappingTokenSupport": false,
                "serverCancelSupport": true,
                "augmentsSyntaxTokens": true
            },
            "linkedEditingRange": {"dynamicRegistration": true},
            "typeHierarchy": {"dynamicRegistration": true},
            "inlineValue": {"dynamicRegistration": true},
            "inlayHint": {
                "dynamicRegistration": true,
                "resolveSupport": {"properties": ["tooltip", "textEdits", "label.tooltip", "label.location", "label.command"]}
            },
            "diagnostic": {"dynamicRegistration": true, "relatedDocumentSupport": false}
        },
        "window": {
            "showMessage": {"messageActionItem": {"additionalPropertiesSupport": true}},
            "showDocument": {"support": true},
            "workDoneProgress": true
        },
        "general": {
            "staleRequestSupport": {
                "cancel": true,
                "retryOnContentModified": ["textDocument/semanticTokens/full", "textDocument/semanticTokens/range", "textDocument/semanticTokens/full/delta"]
            },
            "regularExpressions": {"engine": "ECMAScript", "version": "ES2020"},
            "markdown": {"parser": "marked", "version": "1.1.0"},
            "positionEncodings": ["utf-16"]
        },
        "notebookDocument": {
            "synchronization": {"dynamicRegistration": true, "executionSummarySupport": true}
        }
    },
    "initializationOptions": {
        "hare": {
            "path": "hare",
            "tags": [],
            "diagnostics": {"debounceMs": 300, "enableBuild": true},
            "format": {"indentStyle": "tab", "indentWidth": 8, "trimFinalNewlines": true, "insertFinalNewline": true},
            "inlayHints": {"parameterNames": true, "inferredTypes": true}
        }
    },
    "trace": "verbose",
    "workspaceFolders": [
        {"uri": "file:///workspace", "name": "workspace"}
    ]
}`;

// Calls `handle_initialize` directly with the VSCode params and verifies a
// well-formed initialize response is written to the output sink.
@test fn vscode_initialize_handler() void = {
	let out = memio::dynamic();
	defer io::close(&out)!;
	let in_buf = alloc(memio::fixed([]))!;
	defer free(in_buf);
	let scan = alloc(bufio::newscanner(in_buf))!;
	defer {
		bufio::finish(scan);
		free(scan);
	};
	let s = new(scan, &out, void);
	defer finish(&s);

	let pv = json::loadstr(VSCODE_INITIALIZE_PARAMS)!;
	const r = lsp::request {
		id = 0.0,
		method = strings::dup("initialize")!,
		params = pv,
	};
	defer {
		free(r.method);
		json::finish(pv);
	};

	handle_initialize(&s, r);

	// The handler must have written a framed response to `out`.
	const data = memio::buffer(&out);
	const text = strings::fromutf8(data)!;
	assert(
		strings::hasprefix(text, "Content-Length: "),
		"expected framed response from handle_initialize"
	);
	assert(
		strings::contains(text, `"id":0`),
		"response should echo the request id"
	);
	assert(
		strings::contains(text, `"capabilities"`),
		"response should include capabilities"
	);
	assert(
		strings::contains(text, `"positionEncoding":"utf-16"`),
		"VSCode requests utf-16 only, server must echo it back"
	);
	// State should advance to INITIALIZING after a successful initialize.
	assert(s.state == server_state::INITIALIZING);
	// Workspace folders should have been recorded from the params.
	assert(len(s.workspace_folders) == 1);
	assert(s.workspace_folders[0].uri == "file:///workspace");
};

// Drives the full transport-level path: builds the LSP-framed initialize
// message, feeds it through the scanner, runs the server loop until EOF,
// and verifies a response was emitted before the loop returned.
@test fn vscode_initialize_via_transport() void = {
	// Construct the full JSON-RPC message wrapping the captured params.
	const msg =
		strings::concat(`{"jsonrpc":"2.0","id":0,"method":"initialize","params":`,
			VSCODE_INITIALIZE_PARAMS, `}`)!;
	defer free(msg);
	const body = strings::toutf8(msg);

	// Frame it with the LSP transport header via the same writer the
	// server uses for outbound messages — guarantees the framing matches.
	let framed = memio::dynamic();
	defer io::close(&framed)!;
	lsp::write(&framed, body)!;
	const wire = memio::buffer(&framed);

	// Feed the wire bytes through a scanner into a server.
	let in_buf = alloc(memio::fixed(wire))!;
	defer free(in_buf);
	let scan = alloc(bufio::newscanner(in_buf))!;
	defer {
		bufio::finish(scan);
		free(scan);
	};

	let out = memio::dynamic();
	defer io::close(&out)!;

	let s = new(scan, &out, void);
	defer finish(&s);

	// run() consumes the single framed initialize, dispatches it, then
	// loops back to read and hits EOF. Per current semantics, EOF before
	// shutdown returns EXIT_ERROR — we don't care about the code here,
	// only that the response was emitted.
	const _ = run(&s);

	const data = memio::buffer(&out);
	const text = strings::fromutf8(data)!;
	assert(
		strings::hasprefix(text, "Content-Length: "),
		"transport path must emit a framed response"
	);
	assert(
		strings::contains(text, `"id":0`),
		"transport response should echo the request id"
	);
	assert(
		strings::contains(text, `"capabilities"`),
		"transport response should include capabilities"
	);
	assert(s.state == server_state::INITIALIZING);
};

// Between the `initialize` response and the `initialized` notification the
// server is INITIALIZING. Per LSP spec the client must not send other
// requests in that window; we should reject them with SERVER_NOT_INITIALIZED
// so a racy client gets a clear error instead of partially-built state.
@test fn rejects_request_during_initializing_state() void = {
	let out = memio::dynamic();
	defer io::close(&out)!;
	let in_buf = alloc(memio::fixed([]))!;
	defer free(in_buf);
	let scan = alloc(bufio::newscanner(in_buf))!;
	defer {
		bufio::finish(scan);
		free(scan);
	};
	let s = new(scan, &out, void);
	defer finish(&s);
	// Force the state machine into INITIALIZING without going through
	// handle_initialize so the test stays small.
	s.state = server_state::INITIALIZING;

	const r = lsp::request {
		id = 7.0,
		method = strings::dup("textDocument/hover")!,
		params = void,
	};
	defer free(r.method);
	handle_request(&s, r);

	const text = strings::fromutf8(memio::buffer(&out))!;
	assert(
		strings::contains(text, `"id":7`),
		"error response should echo request id"
	);
	assert(
		strings::contains(text, `"code":-32002`),
		"error code should be SERVER_NOT_INITIALIZED"
	);
	// State must not have advanced.
	assert(s.state == server_state::INITIALIZING);
};

// Notifications received in PRE_INIT or INITIALIZING should be dropped
// silently (per LSP spec) except for `initialized`, `exit`, and the `$/`
// namespace. Verify a didOpen sent before initialize is ignored.
@test fn drops_notification_in_pre_init_state() void = {
	let out = memio::dynamic();
	defer io::close(&out)!;
	let in_buf = alloc(memio::fixed([]))!;
	defer free(in_buf);
	let scan = alloc(bufio::newscanner(in_buf))!;
	defer {
		bufio::finish(scan);
		free(scan);
	};
	let s = new(scan, &out, void);
	defer finish(&s);
	assert(s.state == server_state::PRE_INIT);

	let pv =
		json::loadstr(
			`{"textDocument":{"uri":"file:///x.ha","languageId":"hare","version":1,"text":"export fn main() void = void;"}}`
		)!;
	const n = lsp::notification {
		method = strings::dup("textDocument/didOpen")!,
		params = pv,
	};
	defer {
		free(n.method);
		json::finish(pv);
	};
	handle_notification(&s, n);

	assert(
		len(s.documents) == 0,
		"didOpen should have been dropped because server is in PRE_INIT"
	);
};
