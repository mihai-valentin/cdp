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

# libexec scripts are picked up by the wildcard above; the new cdp-tmux
# entry-point auto-enrolls in lint, install, and uninstall via the same path.

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
	@# Patch every entry-point with absolute installed paths. cdp-init bakes
	@# the absolute path of bin/cdp into the shim, and libexec scripts that
	@# can be invoked directly need correct lib/ paths even without bin/cdp's
	@# env exports.
	@for f in $(BINDIR)/cdp $(LIBEXECDIR)/cdp-*; do \
		sed -i.bak \
			-e 's|^_CDP_LIBEXEC=.*$$|_CDP_LIBEXEC="$${CDP_LIBEXEC:-$(LIBEXECDIR)}"|' \
			-e 's|^_CDP_LIB=.*$$|_CDP_LIB="$${CDP_LIB:-$(LIBDIR)}"|' \
			-e 's|^_CDP_BIN=.*$$|_CDP_BIN="$${CDP_BIN:-$(BINDIR)/cdp}"|' \
			-e 's|^_CDP_TMUX=.*$$|_CDP_TMUX="$${CDP_TMUX:-$(LIBEXECDIR)/cdp-tmux}"|' \
			"$$f" && rm -f "$$f.bak"; \
	done
	@echo "installed cdp -> $(BINDIR)/cdp"
	@echo "                 $(LIBEXECDIR)/"
	@echo "                 $(LIBDIR)/"
	@echo
	@echo "Next step: enable the shell shim."
	@echo
	@echo "  cdp ships as a binary plus a small shell function (the 'shim') that"
	@echo "  has to live inside your interactive shell — a child process cannot"
	@echo "  change its parent shell's working directory, so the shim is what"
	@echo "  actually performs the 'cd' when you run 'cdp <label>'."
	@echo
	@echo "  1. Append this line to your shell rc file:"
	@echo
	@echo "       # ~/.bashrc  (or ~/.zshrc)"
	@echo "       eval \"\$$($(BINDIR)/cdp init bash)\""
	@echo
	@echo "     One-liner:"
	@echo "       echo 'eval \"\$$($(BINDIR)/cdp init bash)\"' >> ~/.bashrc"
	@echo
	@echo "  2. Open a new shell (or run: source ~/.bashrc)."
	@echo
	@echo "  3. Verify: 'type cdp' should report 'cdp is a function'."
	@echo
	@echo "Then try:  cdp add myproj /path/to/myproj  &&  cdp myproj"

uninstall:
	@rm -f $(BINDIR)/cdp
	@rm -rf $(LIBEXECDIR) $(LIBDIR)
	@echo "uninstalled cdp from $(PREFIX)"

clean:
	@:
