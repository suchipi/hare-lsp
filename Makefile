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

hare-lsp: $(HA_SOURCES)
	mkdir -p .cache
	HAREPATH="$(HAREPATH)" HARECACHE="$(PWD)/.cache" $(HARE) build $(HAREFLAGS) -o hare-lsp ./cmd/hare-lsp

harefmt: $(HA_SOURCES)
	mkdir -p .cache
	HAREPATH="$(HAREPATH)" HARECACHE="$(PWD)/.cache" $(HARE) build $(HAREFLAGS) -o harefmt ./cmd/harefmt

# Unit tests run from any reachable module under HAREPATH. The e2e tests
# (under ./e2e) spawn the actual binary and exchange real LSP messages
# over OS pipes — they catch regressions unit tests can't (e.g. the
# buffered-stdout flush bug), but require the binary to exist first.
test: hare-lsp harefmt
	mkdir -p .cache .tmp
	HAREPATH="$(HAREPATH)" HARECACHE="$(PWD)/.cache" $(HARE) test $(HAREFLAGS)
	HAREPATH="$(HAREPATH)" HARECACHE="$(PWD)/.cache" $(HARE) test $(HAREFLAGS) ./cmd/hare-lsp
	HAREPATH="$(HAREPATH)" HARECACHE="$(PWD)/.cache" $(HARE) test $(HAREFLAGS) ./cmd/harefmt
	HAREPATH="$(HAREPATH)" HARECACHE="$(PWD)/.cache" $(HARE) test $(HAREFLAGS) e2e

clean:
	rm -rf hare-lsp harefmt .cache
	rm -rf editors/vscode/dist editors/vscode/node_modules editors/vscode/*.vsix

# Recovers from a wedged build. Symptoms it addresses:
#  - `make` appears to hang at e.g. "130/133 tasks completed" for many
#    minutes. The usual cause is a previous run leaving stale entries in
#    `.cache/` (orphaned `.tmp` / `.tmp.s` files from a kill -9), or a
#    zombie `./hare-lsp` from a panicked e2e test holding the shell
#    pipeline's stderr pipe open and blocking hare's progress writes.
#  - `make test` finishes producing output but the shell never returns,
#    because a downstream `tee` / `tail` is waiting for EOF on a pipe
#    that an orphaned `./hare-lsp` is still holding.
# Strategy:
#  1. Kill any `./hare-lsp` whose cwd is this workspace. We deliberately
#     limit to this workspace so we don't disturb other conductor
#     workspaces / running LSPs in editors.
#  2. Remove `.cache/` outright. Hare's own locks self-heal on flock
#     release, but stray `.tmp.s` files at the cache root from a killed
#     hare-as.sh have been observed to confuse subsequent builds.
unstuck:
	@echo "[unstuck] killing orphan hare-lsp processes in this workspace..."
	@for pid in $$(pgrep -f '\./hare-lsp$$' 2>/dev/null); do \
		cwd=$$(lsof -p $$pid 2>/dev/null | awk '$$4=="cwd"{print $$NF}'); \
		case "$$cwd" in \
			"$(PWD)") echo "  killing $$pid (cwd=$$cwd)"; kill -TERM $$pid 2>/dev/null; sleep 1; kill -KILL $$pid 2>/dev/null || true ;; \
		esac; \
	done
	@echo "[unstuck] removing .cache/ ..."
	@rm -rf .cache
	@echo "[unstuck] done. retry your build."

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

.PHONY: all check-deps test clean unstuck install uninstall vscode-extension vscode-install vscode-uninstall
