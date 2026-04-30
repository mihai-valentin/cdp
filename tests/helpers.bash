#!/usr/bin/env bash
# tests/helpers.bash — shared bats setup/teardown and helpers.

setup() {
    # bats >=1.5 provides BATS_TEST_TMPDIR; older versions don't, so we
    # mint our own and own its lifecycle.
    if [[ -z "${BATS_TEST_TMPDIR:-}" ]]; then
        BATS_TEST_TMPDIR="$(mktemp -d)"
        export BATS_TEST_TMPDIR
        export _CDP_HELPER_OWNS_TMPDIR=1
    fi
    export CDP_CONFIG="${BATS_TEST_TMPDIR}/cdp-config"
    # Defensive guard: never let a test write to the user's real config.
    if [[ "$CDP_CONFIG" != "$BATS_TEST_TMPDIR"/* ]]; then
        printf 'FATAL: CDP_CONFIG not under BATS_TEST_TMPDIR\n' >&2
        exit 99
    fi
    # Unset XDG so it cannot leak through.
    unset XDG_CONFIG_HOME

    # Path to the in-repo cdp entry point.
    CDP_BIN="${BATS_TEST_DIRNAME}/../bin/cdp"
}

teardown() {
    if [[ "${_CDP_HELPER_OWNS_TMPDIR:-0}" -eq 1 && -n "${BATS_TEST_TMPDIR:-}" ]]; then
        rm -rf -- "$BATS_TEST_TMPDIR"
    fi
}

# Wrapper so tests can call `cdp ...` without depending on PATH.
cdp() {
    "$CDP_BIN" "$@"
}
