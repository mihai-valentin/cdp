#!/usr/bin/env bats
# tests/resolve.bats — resolver dispatch + shim emission.

load helpers

write_config() {
    printf '%s' "$1" > "$CDP_CONFIG"
}

@test "bare jump: stdout is CDP_CD <path>, exit 0" {
    mkdir -p "$BATS_TEST_TMPDIR/proj"
    write_config "Project x
    Path $BATS_TEST_TMPDIR/proj
"
    run cdp x
    [ "$status" -eq 0 ]
    [ "$output" = "CDP_CD $BATS_TEST_TMPDIR/proj" ]
}

@test "jump + macro: CDP_CD then CDP_RUN per Run line" {
    mkdir -p "$BATS_TEST_TMPDIR/proj"
    write_config "Project x
    Path $BATS_TEST_TMPDIR/proj
    Macro m
        Run echo one
        Run echo two
"
    run cdp x m
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "CDP_CD $BATS_TEST_TMPDIR/proj" ]
    [ "${lines[1]}" = "CDP_RUN echo one" ]
    [ "${lines[2]}" = "CDP_RUN echo two" ]
}

@test "unknown label exits 1" {
    : > "$CDP_CONFIG"
    run cdp not-a-thing
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown label"* ]]
}

@test "unknown macro exits 1" {
    mkdir -p "$BATS_TEST_TMPDIR/proj"
    write_config "Project x
    Path $BATS_TEST_TMPDIR/proj
"
    run cdp x bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a macro"* ]]
}

@test "too many positional args exits 64" {
    mkdir -p "$BATS_TEST_TMPDIR/proj"
    write_config "Project x
    Path $BATS_TEST_TMPDIR/proj
"
    run cdp x macro extra
    [ "$status" -eq 64 ]
    [[ "$output" == *"too many"* ]]
}

@test "missing config file exits 2" {
    rm -f "$CDP_CONFIG"
    run cdp anything
    [ "$status" -eq 2 ]
    [[ "$output" == *"config file not found"* ]]
}

@test "project path missing on disk exits 1" {
    write_config "Project gone
    Path $BATS_TEST_TMPDIR/does-not-exist
"
    run cdp gone
    [ "$status" -eq 1 ]
    [[ "$output" == *"path does not exist"* ]]
}

@test "init bash emits cdp() function with absolute resolve path" {
    : > "$CDP_CONFIG"
    run cdp init bash
    [ "$status" -eq 0 ]
    [[ "$output" == *"cdp() {"* ]]
    # Resolve path is absolute and points to libexec/cdp-resolve.
    [[ "$output" == *"/libexec/cdp-resolve"* ]]
}

@test "init zsh emits same shim as bash for V1" {
    : > "$CDP_CONFIG"
    bash_out="$(cdp init bash)"
    zsh_out="$(cdp init zsh)"
    [ "$bash_out" = "$zsh_out" ]
}

@test "init fish exits 64" {
    : > "$CDP_CONFIG"
    run cdp init fish
    [ "$status" -eq 64 ]
}
