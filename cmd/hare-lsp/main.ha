// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use bufio;
use os;
use server;

export fn main() void = {
	let scan = bufio::newscanner(os::stdin);
	defer bufio::finish(&scan);

	let s = server::new(&scan, os::stdout);
	defer server::finish(&s);

	const code = server::run(&s);
	if (code != 0) {
		os::exit(code);
	};
};
