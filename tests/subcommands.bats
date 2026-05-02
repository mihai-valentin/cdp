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

@test "edit invokes \$EDITOR on the resolved config path" {
    : > "$CDP_CONFIG"
    fake_editor="${BATS_TEST_TMPDIR}/fake-editor"
    log="${BATS_TEST_TMPDIR}/editor.log"
    cat > "$fake_editor" <<EDITOR
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$log"
EDITOR
    chmod +x "$fake_editor"
    EDITOR="$fake_editor" run cdp edit
    [ "$status" -eq 0 ]
    [ "$(cat "$log")" = "$CDP_CONFIG" ]
}

@test "edit prefers \$VISUAL over \$EDITOR" {
    : > "$CDP_CONFIG"
    visual_editor="${BATS_TEST_TMPDIR}/visual"
    fallback_editor="${BATS_TEST_TMPDIR}/editor"
    log="${BATS_TEST_TMPDIR}/which.log"
    cat > "$visual_editor" <<EDITOR
#!/usr/bin/env bash
echo visual > "$log"
EDITOR
    cat > "$fallback_editor" <<EDITOR
#!/usr/bin/env bash
echo editor > "$log"
EDITOR
    chmod +x "$visual_editor" "$fallback_editor"
    VISUAL="$visual_editor" EDITOR="$fallback_editor" run cdp edit
    [ "$status" -eq 0 ]
    [ "$(cat "$log")" = "visual" ]
}

@test "edit creates the parent directory when config is missing" {
    nested="${BATS_TEST_TMPDIR}/nested/dir/cdp-config"
    CDP_CONFIG="$nested"
    fake_editor="${BATS_TEST_TMPDIR}/touch-editor"
    cat > "$fake_editor" <<'EDITOR'
#!/usr/bin/env bash
: > "$1"
EDITOR
    chmod +x "$fake_editor"
    [ ! -e "$nested" ]
    EDITOR="$fake_editor" CDP_CONFIG="$nested" run cdp edit
    [ "$status" -eq 0 ]
    [ -d "$(dirname "$nested")" ]
    [ -f "$nested" ]
}

@test "edit with arguments exits 64" {
    : > "$CDP_CONFIG"
    EDITOR=true run cdp edit unexpected
    [ "$status" -eq 64 ]
    [[ "$output" == *"takes no arguments"* ]]
}

@test "edit falls back to vi when no editor env vars are set" {
    : > "$CDP_CONFIG"
    # We can't actually exec vi in bats, but we can confirm the shim picks
    # `vi` as the command — exec'ing a known-missing PATH so vi-the-binary
    # fails with the expected "not found" error rather than something else.
    log="${BATS_TEST_TMPDIR}/vi-probe"
    fake_bin="${BATS_TEST_TMPDIR}/fake-bin"
    mkdir -p "$fake_bin"
    cat > "${fake_bin}/vi" <<EDITOR
#!/usr/bin/env bash
printf 'invoked-vi:%s\n' "\$1" > "$log"
EDITOR
    chmod +x "${fake_bin}/vi"
    PATH="${fake_bin}:${PATH}" run env -u VISUAL -u EDITOR "$CDP_BIN" edit
    [ "$status" -eq 0 ]
    [ "$(cat "$log")" = "invoked-vi:$CDP_CONFIG" ]
}

@test "add with reserved label 'edit' exits 64" {
    mkdir -p "$BATS_TEST_TMPDIR/p"
    run cdp add edit "$BATS_TEST_TMPDIR/p"
    [ "$status" -eq 64 ]
    [[ "$output" == *"reserved"* ]]
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
