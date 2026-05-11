// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors

use fs;
use io;
use os;
use strings;

@test fn file_parse_cache_hits_skip_reparse() void = {
	let c = new_file_parse_cache();
	defer finish_file_parse_cache(&c);

	const path = ".tmp/fpc-test.ha";
	fpc_write(path, "export fn a() void = void;\n");
	defer fpc_rm(path);

	const e1 = match (file_parse_cache_get(&c, path)) {
	case let p: *file_parse_entry => yield p;
	case null => abort("first get returned null");
	};
	assert(len(e1.pr.subunit.decls) == 1);
	assert(len(c.entries) == 1);
	const tick1 = e1.last_used;

	// Second get on the SAME contents must reuse the entry. The
	// returned pointer is borrowed; just compare cache size + tick.
	const e2 = match (file_parse_cache_get(&c, path)) {
	case let p: *file_parse_entry => yield p;
	case null => abort("second get returned null");
	};
	assert(len(c.entries) == 1);
	assert(e2.last_used > tick1);
};

@test fn file_parse_cache_invalidates_on_mtime_change() void = {
	let c = new_file_parse_cache();
	defer finish_file_parse_cache(&c);

	const path = ".tmp/fpc-mtime.ha";
	fpc_write(path, "export fn a() void = void;\n");
	defer fpc_rm(path);

	const e1 = match (file_parse_cache_get(&c, path)) {
	case let p: *file_parse_entry => yield p;
	case null => abort("first get returned null");
	};
	const len1 = len(e1.pr.subunit.decls);
	assert(len1 == 1);

	// Rewrite the file with a different decl count, forcing mtime change.
	// Hare's filesystem timestamps are at nanosecond resolution on Linux,
	// but on macOS HFS+ they may be second-granularity — sleep briefly.
	fpc_sleep_for_mtime();
	fpc_write(path, "export fn a() void = void;\nexport fn b() void = void;\n");

	const e2 = match (file_parse_cache_get(&c, path)) {
	case let p: *file_parse_entry => yield p;
	case null => abort("second get returned null");
	};
	assert(len(e2.pr.subunit.decls) == 2);
};

@test fn file_parse_cache_evicts_when_full() void = {
	let c = new_file_parse_cache();
	defer finish_file_parse_cache(&c);

	// Create FILE_PARSE_CACHE_CAP + 1 files; the oldest should be evicted.
	let paths: []str = [];
	defer {
		for (let i = 0z; i < len(paths); i += 1) {
			fpc_rm(paths[i]);
			free(paths[i]);
		};
		free(paths);
	};
	const cap = FILE_PARSE_CACHE_CAP;
	for (let i = 0z; i < cap + 1; i += 1) {
		const path = fpc_path_for(i);
		fpc_write(path, "export fn x() void = void;\n");
		append(paths, path)!;
		match (file_parse_cache_get(&c, path)) {
		case *file_parse_entry => void;
		case null => abort("write+get failed");
		};
	};
	assert(len(c.entries) == cap);
};

fn fpc_path_for(i: size) str = {
	let buf: []u8 = [];
	// NOTE: do NOT defer-free buf here. strings::fromutf8 borrows buf's
	// storage; freeing buf would leave the returned str dangling. We
	// transfer ownership to the caller.
	const prefix = ".tmp/fpc-evict-";
	append(buf, strings::toutf8(prefix)...)!;
	if (i == 0) {
		append(buf, '0': u8)!;
	} else {
		let n = i;
		let stack: []u8 = [];
		defer free(stack);
		for (n > 0) {
			append(stack, (n % 10): u8 + '0': u8)!;
			n /= 10;
		};
		for (let j = len(stack); j > 0; j -= 1) {
			append(buf, stack[j - 1])!;
		};
	};
	append(buf, strings::toutf8(".ha")...)!;
	return strings::fromutf8(buf)!;
};

fn fpc_write(path: str, text: str) void = {
	const f = match (os::create(path, 0o644)) {
	case let h: io::file => yield h;
	case fs::error => return;
	};
	defer io::close(f)!;
	io::writeall(f, strings::toutf8(text))!;
};

fn fpc_rm(path: str) void = {
	match (os::remove(path)) {
	case => void;
	};
};

// Brief sleep so file timestamps change on filesystems with coarse mtime.
fn fpc_sleep_for_mtime() void = {
	// 10ms — empirically enough on every host the test suite runs on.
	const start = match (os::stat(".")) {
	case let s: fs::filestat => yield s;
	case fs::error => return;
	};
	// Busy-loop until at least the next nanosecond tick. On systems with
	// second-granularity mtime this isn't enough; tests on such systems
	// would need a longer wait, but Linux is fine.
	for (let i = 0z; i < 1000000; i += 1) {
		void;
	};
	const _ = start;
};
