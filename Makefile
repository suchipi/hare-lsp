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

.PHONY: all check-deps test clean install uninstall vscode-extension vscode-install
