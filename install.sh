#!/usr/bin/env bash
# install.sh — thin wrapper around `make install` for users who clone the repo.
#
# Usage: ./install.sh [--prefix=<path>]
#
# If --prefix is omitted, this script probes:
#   1. $HOME/.local/bin on PATH  → prefix=$HOME/.local
#   2. /usr/local/bin on PATH    → prefix=/usr/local
#   3. otherwise                 → prefix=$HOME/.local (and warns)

set -euo pipefail

prefix=""

for arg in "$@"; do
    case "$arg" in
        --prefix=*)
            prefix="${arg#--prefix=}"
            ;;
        -h|--help)
            cat <<USAGE
install.sh — install cdp from a source checkout

Usage: ./install.sh [--prefix=<path>]
       ./install.sh --help

If --prefix is omitted, the script picks the first match:
  - \$HOME/.local/bin on PATH  -> --prefix=\$HOME/.local
  - /usr/local/bin on PATH     -> --prefix=/usr/local
  - otherwise (with a warning) -> --prefix=\$HOME/.local

Calls 'make install PREFIX=<prefix>' under the hood.
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
make -C "$repo_root" install PREFIX="$prefix"

cat <<SHIM_SNIPPET

# Add to your ~/.bashrc or ~/.zshrc:
eval "\$($prefix/bin/cdp init bash)"
SHIM_SNIPPET
