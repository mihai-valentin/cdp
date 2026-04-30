#!/usr/bin/env bats
# tests/subcommands.bats — add / rm / ls.

load helpers

@test "ls on empty config exits 0 with no stdout" {
    : > "$CDP_CONFIG"
    run cdp ls
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "add then ls round-trip" {
    mkdir -p "$BATS_TEST_TMPDIR/p"
    run cdp add foo "$BATS_TEST_TMPDIR/p"
    [ "$status" -eq 0 ]
    run cdp ls
    [ "$status" -eq 0 ]
    [[ "$output" == "foo	$BATS_TEST_TMPDIR/p	" ]]
}

@test "duplicate add exits 1" {
    mkdir -p "$BATS_TEST_TMPDIR/p"
    cdp add foo "$BATS_TEST_TMPDIR/p"
    run cdp add foo "$BATS_TEST_TMPDIR/p"
    [ "$status" -eq 1 ]
    [[ "$output" == *"already exists"* ]]
}

@test "add with reserved label exits 64" {
    mkdir -p "$BATS_TEST_TMPDIR/p"
    run cdp add add "$BATS_TEST_TMPDIR/p"
    [ "$status" -eq 64 ]
    [[ "$output" == *"reserved"* ]]
}

@test "add with non-existent path exits 1" {
    run cdp add foo "$BATS_TEST_TMPDIR/missing"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a directory"* ]]
}

@test "rm round-trip" {
    mkdir -p "$BATS_TEST_TMPDIR/p"
    cdp add foo "$BATS_TEST_TMPDIR/p"
    run cdp rm foo
    [ "$status" -eq 0 ]
    run cdp ls
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "rm bogus label exits 1" {
    : > "$CDP_CONFIG"
    run cdp rm bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"not found"* ]]
}

@test "ls non-TTY: no header row, just data" {
    mkdir -p "$BATS_TEST_TMPDIR/p"
    cdp add foo "$BATS_TEST_TMPDIR/p"
    run cdp ls
    [ "$status" -eq 0 ]
    # First line should not be the header.
    [[ "${lines[0]}" != "LABEL"* ]]
    [[ "${lines[0]}" == "foo	"* ]]
}

@test "round-trip: 3 adds, rm middle, others remain in file order" {
    mkdir -p "$BATS_TEST_TMPDIR/p"
    cdp add a "$BATS_TEST_TMPDIR/p"
    cdp add b "$BATS_TEST_TMPDIR/p"
    cdp add c "$BATS_TEST_TMPDIR/p"
    cdp rm b
    run cdp ls
    [ "$status" -eq 0 ]
    # ls sorts alphabetically: a, c.
    [ "${lines[0]}" = "a	$BATS_TEST_TMPDIR/p	" ]
    [ "${lines[1]}" = "c	$BATS_TEST_TMPDIR/p	" ]
    # Source-order check: in the config file, a precedes c (b was between).
    grep -n "^Project " "$CDP_CONFIG" | awk -F: '{print $NF}' > "$BATS_TEST_TMPDIR/order"
    [ "$(sed -n 1p "$BATS_TEST_TMPDIR/order")" = "Project a" ]
    [ "$(sed -n 2p "$BATS_TEST_TMPDIR/order")" = "Project c" ]
}

@test "flock-stress: 10 parallel adds all land" {
    mkdir -p "$BATS_TEST_TMPDIR/p"
    : > "$CDP_CONFIG"
    for i in $(seq 1 10); do
        cdp add "p$i" "$BATS_TEST_TMPDIR/p" &
    done
    wait
    run cdp ls
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 10 ]
}
