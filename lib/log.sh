#!/usr/bin/env bash
# lib/log.sh — cdp shared logging helpers.
# Sourced (not executed). cdp_die exits the process; cdp_warn prints and returns.

[[ -n "${_CDP_LOG_SH:-}" ]] && return 0
_CDP_LOG_SH=1

cdp_die() {
    printf 'cdp: %s\n' "$*" >&2
    exit "${CDP_DIE_EXIT:-1}"
}

cdp_warn() {
    printf 'cdp: %s\n' "$*" >&2
}
