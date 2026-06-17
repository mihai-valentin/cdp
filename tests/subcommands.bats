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

@test "add with no args adds cwd, label = basename" {
    mkdir -p "$BATS_TEST_TMPDIR/myproj"
    cd "$BATS_TEST_TMPDIR/myproj"
    run cdp add
    [ "$status" -eq 0 ]
    run cdp ls
    [ "$status" -eq 0 ]
    [[ "$output" == "myproj	$BATS_TEST_TMPDIR/myproj	" ]]
}

@test "add . adds cwd, label = basename" {
    mkdir -p "$BATS_TEST_TMPDIR/dotproj"
    cd "$BATS_TEST_TMPDIR/dotproj"
    run cdp add .
    [ "$status" -eq 0 ]
    run cdp ls
    [[ "$output" == "dotproj	$BATS_TEST_TMPDIR/dotproj	" ]]
}

@test "add with single absolute path, label = basename" {
    mkdir -p "$BATS_TEST_TMPDIR/abs"
    run cdp add "$BATS_TEST_TMPDIR/abs"
    [ "$status" -eq 0 ]
    run cdp ls
    [[ "$output" == "abs	$BATS_TEST_TMPDIR/abs	" ]]
}

@test "add with single relative path resolves against cwd" {
    mkdir -p "$BATS_TEST_TMPDIR/parent/child"
    cd "$BATS_TEST_TMPDIR/parent"
    run cdp add ./child
    [ "$status" -eq 0 ]
    run cdp ls
    [[ "$output" == "child	$BATS_TEST_TMPDIR/parent/child	" ]]
}

@test "add fails when derived label is invalid (basename has a dot)" {
    mkdir -p "$BATS_TEST_TMPDIR/has.dot"
    run cdp add "$BATS_TEST_TMPDIR/has.dot"
    [ "$status" -eq 64 ]
    [[ "$output" == *"cannot derive a valid label"* ]]
}

@test "add with 3+ args exits 64" {
    mkdir -p "$BATS_TEST_TMPDIR/p"
    run cdp add a "$BATS_TEST_TMPDIR/p" extra
    [ "$status" -eq 64 ]
    [[ "$output" == *"usage"* ]]
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

@test "check on empty config exits 0 with OK on stderr" {
    : > "$CDP_CONFIG"
    run cdp check
    [ "$status" -eq 0 ]
    [[ "$output" == *"config OK: $CDP_CONFIG"* ]]
    [[ "$output" == *"(0 projects)"* ]]
}

@test "check on a valid multi-project config reports project count" {
    mkdir -p "$BATS_TEST_TMPDIR/p"
    cdp add a "$BATS_TEST_TMPDIR/p"
    cdp add b "$BATS_TEST_TMPDIR/p"
    cdp add c "$BATS_TEST_TMPDIR/p"
    run cdp check
    [ "$status" -eq 0 ]
    [[ "$output" == *"(3 projects)"* ]]
}

@test "check uses singular 'project' for a one-project config" {
    mkdir -p "$BATS_TEST_TMPDIR/p"
    cdp add solo "$BATS_TEST_TMPDIR/p"
    run cdp check
    [ "$status" -eq 0 ]
    [[ "$output" == *"(1 project)"* ]]
    [[ "$output" != *"(1 projects)"* ]]
}

@test "check writes the OK line to stderr (stdout stays silent)" {
    : > "$CDP_CONFIG"
    stdout="${BATS_TEST_TMPDIR}/check.out"
    stderr="${BATS_TEST_TMPDIR}/check.err"
    "$CDP_BIN" check >"$stdout" 2>"$stderr"
    rc=$?
    [ "$rc" -eq 0 ]
    [ ! -s "$stdout" ]
    grep -q 'config OK' "$stderr"
}

@test "check on a missing config exits 2" {
    rm -f "$CDP_CONFIG"
    run cdp check
    [ "$status" -eq 2 ]
    [[ "$output" == *"config file not found"* ]]
}

@test "check on a parse-error config exits 65" {
    cat > "$CDP_CONFIG" <<'CFG'
Project myproject
    Path /tmp/myproject
    Run uh-oh
CFG
    run cdp check
    [ "$status" -eq 65 ]
    [[ "$output" == *"config:3"* ]]
    [[ "$output" == *"Run outside Macro or Pane block"* ]]
}

@test "check on a relative-path config exits 65" {
    cat > "$CDP_CONFIG" <<'CFG'
Project rel
    Path not/absolute
CFG
    run cdp check
    [ "$status" -eq 65 ]
    [[ "$output" == *"Path must be absolute"* ]]
}

@test "check with arguments exits 64" {
    : > "$CDP_CONFIG"
    run cdp check unexpected
    [ "$status" -eq 64 ]
    [[ "$output" == *"takes no arguments"* ]]
}

@test "add with reserved label 'check' exits 64" {
    mkdir -p "$BATS_TEST_TMPDIR/p"
    run cdp add check "$BATS_TEST_TMPDIR/p"
    [ "$status" -eq 64 ]
    [[ "$output" == *"reserved"* ]]
}

@test "Project label 'check' is a parse error (reserved)" {
    cat > "$CDP_CONFIG" <<'CFG'
Project check
    Path /tmp
CFG
    run cdp ls
    [ "$status" -eq 65 ]
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
