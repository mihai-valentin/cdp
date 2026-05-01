#!/usr/bin/env bash
# install.sh — install cdp from a source checkout without requiring 'make'.
#
# Usage: ./install.sh [--prefix=<path>]
#
# If --prefix is omitted, this script probes:
#   1. $HOME/.local/bin on PATH  -> prefix=$HOME/.local
#   2. /usr/local/bin on PATH    -> prefix=/usr/local
#   3. otherwise                 -> prefix=$HOME/.local (and warns)
#
# Mirrors the layout produced by 'make install':
#   $PREFIX/bin/cdp
#   $PREFIX/libexec/cdp/cdp-*
#   $PREFIX/lib/cdp/*.sh

set -euo pipefail

prefix=""

for arg in "$@"; do
    case "$arg" in
        --prefix=*)
            prefix="${arg#--prefix=}"
            ;;
        -h|--help)
            cat <<USAGE
install.sh — install cdp from a source checkout (no 'make' required)

Usage: ./install.sh [--prefix=<path>]
       ./install.sh --help

If --prefix is omitted, the script picks the first match:
  - \$HOME/.local/bin on PATH  -> --prefix=\$HOME/.local
  - /usr/local/bin on PATH     -> --prefix=/usr/local
  - otherwise (with a warning) -> --prefix=\$HOME/.local
USAGE
            exit 0
            ;;
        *)
            printf 'install.sh: unknown argument: %s\n' "$arg" >&2
            exit 64
            ;;
    esac
done

if [[ -z "$prefix" ]]; then
    case ":${PATH}:" in
        *":${HOME}/.local/bin:"*)
            prefix="${HOME}/.local"
            ;;
        *":/usr/local/bin:"*)
            prefix="/usr/local"
            ;;
        *)
            prefix="${HOME}/.local"
            printf 'install.sh: warning: %s/bin is not on PATH; you will need to add it.\n' \
                "$prefix" >&2
            ;;
    esac
fi

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
bindir="${prefix}/bin"
libexecdir="${prefix}/libexec/cdp"
libdir="${prefix}/lib/cdp"

mkdir -p "$bindir" "$libexecdir" "$libdir"

install -m 0755 "${repo_root}/bin/cdp" "${bindir}/cdp"
for f in "${repo_root}"/libexec/cdp-*; do
    install -m 0755 "$f" "${libexecdir}/"
done
for f in "${repo_root}"/lib/*.sh; do
    install -m 0644 "$f" "${libdir}/"
done

# Patch every entry-point with absolute installed paths (mirrors Makefile).
for f in "${bindir}/cdp" "${libexecdir}"/cdp-*; do
    sed -i.bak \
        -e "s|^_CDP_LIBEXEC=.*\$|_CDP_LIBEXEC=\"\${CDP_LIBEXEC:-${libexecdir}}\"|" \
        -e "s|^_CDP_LIB=.*\$|_CDP_LIB=\"\${CDP_LIB:-${libdir}}\"|" \
        -e "s|^_CDP_BIN=.*\$|_CDP_BIN=\"\${CDP_BIN:-${bindir}/cdp}\"|" \
        -e "s|^_CDP_TMUX=.*\$|_CDP_TMUX=\"\${CDP_TMUX:-${libexecdir}/cdp-tmux}\"|" \
        "$f"
    rm -f "${f}.bak"
done

cat <<DONE
installed cdp -> ${bindir}/cdp
                 ${libexecdir}/
                 ${libdir}/

Next step: enable the shell shim.

  cdp ships as a binary plus a small shell function (the 'shim') that
  has to live inside your interactive shell — a child process cannot
  change its parent shell's working directory, so the shim is what
  actually performs the 'cd' when you run 'cdp <label>'.

  1. Append this line to your shell rc file:

       # ~/.bashrc  (or ~/.zshrc)
       eval "\$(${bindir}/cdp init bash)"

     One-liner:
       echo 'eval "\$(${bindir}/cdp init bash)"' >> ~/.bashrc

  2. Open a new shell (or run: source ~/.bashrc).

  3. Verify: 'type cdp' should report 'cdp is a function'.

Then try:  cdp add myproj /path/to/myproj  &&  cdp myproj
DONE
