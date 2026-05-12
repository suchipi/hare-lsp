.POSIX:
.SUFFIXES:

HARE = hare
HAREFLAGS =

DESTDIR =
PREFIX = /usr/local
BINDIR = $(PREFIX)/bin

# Hare's install prefix varies: distro packages (e.g. Alpine's `hare`) lay
# files down under /usr/src/hare, while a source build defaults to
# /usr/local/src/hare. Prefer /usr/src when present; fall back to
# /usr/local. Either can be overridden via the environment or command line.
THIRDPARTY ?= $(if $(wildcard /usr/src/hare/third-party),/usr/src/hare/third-party,/usr/local/src/hare/third-party)
STDLIB ?= $(if $(wildcard /usr/src/hare/stdlib),/usr/src/hare/stdlib,/usr/local/src/hare/stdlib)
JSON_DIR = $(THIRDPARTY)/encoding/json

# Project root must be on HAREPATH so `use lsp;` etc. resolve to ./lsp/.
HAREPATH = $(PWD):$(THIRDPARTY):$(STDLIB)

all: check-deps hare-lsp harefmt

check-deps:
	@if [ ! -f "$(JSON_DIR)/load.ha" ]; then \
		echo "ERROR: encoding::json (hare-json) not found at $(JSON_DIR)"; \
		echo ""; \
		echo "Install it with:"; \
		echo "  git clone https://git.sr.ht/~sircmpwn/hare-json /tmp/hare-json"; \
		echo "  sudo make -C /tmp/hare-json install"; \
		echo ""; \
		exit 1; \
	fi

# Sources: `gitignore/` is the standalone (vendorable) pattern matcher
# used by harefmt, and `format` etc. are imported by both binaries via
# HAREPATH.
HA_SOURCES = $(shell find cmd lsp server analysis hare gitignore -name '*.ha' 2>/dev/null)

# Test sources are everything the production binaries see, plus the
# `+test` files under e2e/. The e2e module is auto-discovered by
# `hare test` (no path), so its sources affect .tmp/all-tests.
HA_TEST_SOURCES = $(HA_SOURCES) $(shell find e2e -name '*.ha' 2>/dev/null)

hare-lsp: $(HA_SOURCES)
	mkdir -p .cache
	HAREPATH="$(HAREPATH)" HARECACHE="$(PWD)/.cache" $(HARE) build $(HAREFLAGS) -o hare-lsp ./cmd/hare_lsp

harefmt: $(HA_SOURCES)
	mkdir -p .cache
	HAREPATH="$(HAREPATH)" HARECACHE="$(PWD)/.cache" $(HARE) build $(HAREFLAGS) -o harefmt ./cmd/harefmt

# `hare test -o <path>` builds a self-contained test binary that takes
# glob patterns over `module::test_name` as arguments and only runs the
# matching tests. Building once and dispatching from several parallel
# shards lets the e2e suite (98 tests * ~600ms each, since every test
# spawns a fresh ./hare-lsp process) finish in roughly the time of the
# slowest shard rather than the full sum.
#
# .tmp/all-tests covers every auto-discovered module: analysis, server,
# lsp, gitignore, e2e, cmd::harefmt, and cmd::hare_lsp.
.tmp/all-tests: $(HA_TEST_SOURCES)
	mkdir -p .cache .tmp
	HAREPATH="$(HAREPATH)" HARECACHE="$(PWD)/.cache" $(HARE) test $(HAREFLAGS) -o $@

# Sharded parallel test runner. The non-e2e suites finish in a handful
# of seconds combined; the e2e suite is split into six alphabetical
# buckets that run side-by-side with it. Each shard captures output to
# its own log file so the final concatenated dump is readable rather
# than interleaved, and the wait loop collects exit codes from every
# shard before exiting non-zero on any failure.
#
# The e2e tests guard against regressions unit tests can't catch (e.g.
# the buffered-stdout flush bug), so ./hare-lsp must exist before this
# runs.
test: hare-lsp harefmt .tmp/all-tests
	@mkdir -p .cache .tmp
	@rm -f .tmp/test-shard-*.log
	@( .tmp/all-tests 'analysis::*' 'cmd::*' 'gitignore::*' 'lsp::*' 'server::*' > .tmp/test-shard-1-non-e2e.log  2>&1 ) & p1=$$!; \
		( .tmp/all-tests 'e2e::e2e_c*'                                  > .tmp/test-shard-2-e2e-c.log   2>&1 ) & p2=$$!; \
		( .tmp/all-tests 'e2e::e2e_d*'                                  > .tmp/test-shard-3-e2e-d.log   2>&1 ) & p3=$$!; \
		( .tmp/all-tests 'e2e::e2e_[e-h]*'                              > .tmp/test-shard-4-e2e-eh.log  2>&1 ) & p4=$$!; \
		( .tmp/all-tests 'e2e::e2e_[i-p]*'                              > .tmp/test-shard-5-e2e-ip.log  2>&1 ) & p5=$$!; \
		( .tmp/all-tests 'e2e::e2e_[r-s]*'                              > .tmp/test-shard-6-e2e-rs.log  2>&1 ) & p6=$$!; \
		( .tmp/all-tests 'e2e::e2e_[t-z]*'                              > .tmp/test-shard-7-e2e-tz.log  2>&1 ) & p7=$$!; \
		fail=0; \
		for pid in $$p1 $$p2 $$p3 $$p4 $$p5 $$p6 $$p7; do \
			wait $$pid || fail=1; \
		done; \
		cat .tmp/test-shard-*.log; \
		exit $$fail

clean:
	rm -rf hare-lsp harefmt .cache
	rm -rf editors/vscode/dist editors/vscode/node_modules editors/vscode/*.vsix
	rm -f .tmp/all-tests .tmp/test-shard-*.log

install: hare-lsp harefmt
	mkdir -p "$(DESTDIR)$(BINDIR)"
	install -m755 hare-lsp "$(DESTDIR)$(BINDIR)/hare-lsp"
	install -m755 harefmt "$(DESTDIR)$(BINDIR)/harefmt"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/hare-lsp"
	rm -f "$(DESTDIR)$(BINDIR)/harefmt"

# --- VSCode extension ------------------------------------------------

VSCODE_DIR = editors/vscode

vscode-extension:
	cd $(VSCODE_DIR) && npm install && npm run package

vscode-install: vscode-extension
	cd $(VSCODE_DIR) && code --install-extension hare-lsp-*.vsix

vscode-uninstall:
	code --uninstall-extension local.hare-lsp

.PHONY: all check-deps test clean install uninstall vscode-extension vscode-install vscode-uninstall
