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

@test "init bash emits cdp() function with absolute bin path" {
    : > "$CDP_CONFIG"
    run cdp init bash
    [ "$status" -eq 0 ]
    [[ "$output" == *"cdp() {"* ]]
    # Shim invokes bin/cdp via an absolute path baked at init time.
    [[ "$output" == *"/bin/cdp"* ]]
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

# --- V1.1: tmux dispatch -------------------------------------------------

@test "tmux jump emits CDP_CD then CDP_TMUX_* family in order" {
    mkdir -p "$BATS_TEST_TMPDIR/proj"
    write_config "Project myapp
    Path $BATS_TEST_TMPDIR/proj
    Tmux dev
        Layout h:[main | v:[test | logs]]
        Pane main
            Run pnpm dev
        Pane test
            Run pnpm test --watch
        Pane logs
            Run tail -f log
"
    run cdp myapp dev
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "CDP_CD $BATS_TEST_TMPDIR/proj" ]
    [ "${lines[1]}" = "CDP_TMUX_SESSION myapp-dev" ]
    [ "${lines[2]}" = "CDP_TMUX_LAYOUT h:[main | v:[test | logs]]" ]
    [ "${lines[6]}" = "CDP_TMUX_ATTACH" ]
}

@test "tmux pane records use \\x1f separator" {
    mkdir -p "$BATS_TEST_TMPDIR/proj"
    write_config "Project myapp
    Path $BATS_TEST_TMPDIR/proj
    Tmux dev
        Layout main
        Pane main
            Run echo hi
"
    run cdp myapp dev
    [ "$status" -eq 0 ]
    # Body of the CDP_TMUX_PANE line, after the prefix, must contain \x1f.
    pane_body=$(printf '%s\n' "$output" | grep '^CDP_TMUX_PANE ' | head -1)
    pane_body="${pane_body#CDP_TMUX_PANE }"
    [[ "$pane_body" == "main"$'\x1f'"echo hi" ]]
}

@test "multi-Run pane emits one CDP_TMUX_PANE per Run" {
    mkdir -p "$BATS_TEST_TMPDIR/proj"
    write_config "Project myapp
    Path $BATS_TEST_TMPDIR/proj
    Tmux dev
        Layout main
        Pane main
            Run cmd1
            Run cmd2
            Run cmd3
"
    run cdp myapp dev
    [ "$status" -eq 0 ]
    pane_count=$(printf '%s\n' "$output" | grep -c '^CDP_TMUX_PANE ')
    [ "$pane_count" -eq 3 ]
}

@test "unknown action name reports macro-or-tmux error message" {
    mkdir -p "$BATS_TEST_TMPDIR/proj"
    write_config "Project myapp
    Path $BATS_TEST_TMPDIR/proj
    Macro deploy
        Run echo deploying
"
    run cdp myapp bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a macro or tmux of project 'myapp'"* ]]
}

@test "macro dispatch path unchanged by V1.1 (regression guard)" {
    mkdir -p "$BATS_TEST_TMPDIR/proj"
    write_config "Project myapp
    Path $BATS_TEST_TMPDIR/proj
    Macro deploy
        Run step1
        Run step2
    Tmux dev
        Layout main
        Pane main
            Run x
"
    run cdp myapp deploy
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "CDP_CD $BATS_TEST_TMPDIR/proj" ]
    [ "${lines[1]}" = "CDP_RUN step1" ]
    [ "${lines[2]}" = "CDP_RUN step2" ]
    # No tmux lines must leak into a macro plan.
    ! [[ "$output" == *"CDP_TMUX_"* ]]
}

@test "resolver does NOT shell out to tmux (orchestrator's job)" {
    # The other tmux tests in this file pass without setup_tmux_stub being
    # called — the resolver never invokes tmux itself. Make that intent
    # explicit by asserting tmux was NOT called: route all `tmux` invocations
    # through a sentinel script that fails loudly if it ever runs.
    sentinel_dir="${BATS_TEST_TMPDIR}/sentinel-bin"
    mkdir -p "$sentinel_dir"
    cat > "${sentinel_dir}/tmux" <<'SENTINEL'
#!/usr/bin/env bash
echo 'resolver invoked tmux — that is the orchestrators job' >&2
exit 99
SENTINEL
    chmod +x "${sentinel_dir}/tmux"
    PATH="${sentinel_dir}:${PATH}"

    mkdir -p "$BATS_TEST_TMPDIR/proj"
    write_config "Project myapp
    Path $BATS_TEST_TMPDIR/proj
    Tmux dev
        Layout main
        Pane main
            Run x
"
    run cdp myapp dev
    [ "$status" -eq 0 ]
    [[ "$output" == *"CDP_TMUX_SESSION myapp-dev"* ]]
}
