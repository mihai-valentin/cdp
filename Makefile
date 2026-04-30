# cdp — Makefile
# Targets: lint, test, check, install, uninstall, clean, help
# Defaults: PREFIX=$HOME/.local

PREFIX ?= $(HOME)/.local
BINDIR  = $(PREFIX)/bin
LIBEXECDIR = $(PREFIX)/libexec/cdp
LIBDIR  = $(PREFIX)/lib/cdp

SHELL_SCRIPTS = bin/cdp \
                $(wildcard libexec/cdp-*) \
                $(wildcard lib/*.sh) \
                install.sh

.PHONY: help lint test check install uninstall clean

help:
	@echo "cdp — make targets:"
	@echo "  lint      Run shellcheck over bin/, libexec/, lib/, install.sh"
	@echo "  test      Run bats tests under tests/"
	@echo "  check     lint + test"
	@echo "  install   Install to PREFIX (default: $(HOME)/.local)"
	@echo "  uninstall Remove the installed files from PREFIX"
	@echo "  clean     No-op (bash has no build artifacts; stub for parity)"
	@echo "  help      This message"

lint:
	@command -v shellcheck >/dev/null 2>&1 || { \
		echo "make lint: shellcheck not installed" >&2; exit 2; }
	shellcheck --severity=style $(SHELL_SCRIPTS)

test:
	@command -v bats >/dev/null 2>&1 || { \
		echo "make test: bats-core not installed" >&2; exit 2; }
	bats tests/

check: lint test

install:
	@mkdir -p $(BINDIR) $(LIBEXECDIR) $(LIBDIR)
	@install -m 0755 bin/cdp $(BINDIR)/cdp
	@for f in libexec/cdp-*; do \
		install -m 0755 "$$f" $(LIBEXECDIR)/; \
	done
	@for f in lib/*.sh; do \
		install -m 0644 "$$f" $(LIBDIR)/; \
	done
	@# Patch the install-path override so bin/cdp points at the installed libexec/lib.
	@sed -i.bak \
		-e 's|^_CDP_LIBEXEC=.*$$|_CDP_LIBEXEC="$(LIBEXECDIR)"|' \
		-e 's|^_CDP_LIB=.*$$|_CDP_LIB="$(LIBDIR)"|' \
		$(BINDIR)/cdp && rm -f $(BINDIR)/cdp.bak
	@echo "installed cdp -> $(BINDIR)/cdp"
	@echo
	@echo "# Add to your ~/.bashrc or ~/.zshrc:"
	@echo "eval \"\$$($(BINDIR)/cdp init bash)\""

uninstall:
	@rm -f $(BINDIR)/cdp
	@rm -rf $(LIBEXECDIR) $(LIBDIR)
	@echo "uninstalled cdp from $(PREFIX)"

clean:
	@:
