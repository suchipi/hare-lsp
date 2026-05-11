// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use bufio;
use os;
use server;

export fn main() void = {
	let scan = bufio::newscanner(os::stdin);
	defer bufio::finish(&scan);

	// Use the unbuffered stdout handle: vscode-languageclient and other
	// clients keep stdin open across requests, so the process never exits
	// to flush a buffered stdout — the response would sit in the 4 KiB
	// buffer indefinitely and the client would time out the handshake.
	// The e2e suite under e2e/ guards against re-introducing this bug.
	let s = server::new(&scan, os::stdout_file);
	defer server::finish(&s);

	const code = server::run(&s);
	if (code != 0) {
		os::exit(code);
	};
};
