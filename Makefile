.POSIX:
.SUFFIXES:

HARE = hare
HAREFLAGS =

DESTDIR =
PREFIX = /usr/local
BINDIR = $(PREFIX)/bin

THIRDPARTY = /usr/local/src/hare/third-party
JSON_DIR = $(THIRDPARTY)/encoding/json

# Project root must be on HAREPATH so `use lsp;` etc. resolve to ./lsp/.
HAREPATH = $(PWD):$(THIRDPARTY):/usr/local/src/hare/stdlib

all: check-deps hare-lsp

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

hare-lsp: $(shell find cmd lsp server analysis -name '*.ha' 2>/dev/null)
	mkdir -p .cache
	HAREPATH="$(HAREPATH)" $(HARE) build $(HAREFLAGS) -o hare-lsp ./cmd/hare-lsp

test:
	mkdir -p .cache
	HAREPATH="$(HAREPATH)" $(HARE) test $(HAREFLAGS)

clean:
	rm -rf hare-lsp .cache

install: hare-lsp
	mkdir -p "$(DESTDIR)$(BINDIR)"
	install -m755 hare-lsp "$(DESTDIR)$(BINDIR)/hare-lsp"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/hare-lsp"

.PHONY: all check-deps test clean install uninstall
