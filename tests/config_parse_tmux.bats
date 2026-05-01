#!/usr/bin/env bats
# tests/config_parse_tmux.bats — V1.1 parser additions (Tmux/Layout/Pane).
# Exercises lib/config.sh via cdp-resolve (which calls cdp_config_load_or_die).

load helpers

write_config() {
    printf '%s' "$1" > "$CDP_CONFIG"
}

@test "tmux: minimal valid block (1 pane, 1 run) parses" {
    mkdir -p "$BATS_TEST_TMPDIR/p"
    write_config "Project p
    Path $BATS_TEST_TMPDIR/p
    Tmux dev
        Layout main
        Pane main
            Run echo go
"
    run cdp p dev
    [ "$status" -eq 0 ]
    [[ "$output" == *"CDP_TMUX_SESSION p-dev"* ]]
}

@test "tmux: 3-pane nested layout parses + emits panes in walk order" {
    mkdir -p "$BATS_TEST_TMPDIR/p"
    write_config "Project p
    Path $BATS_TEST_TMPDIR/p
    Tmux dev
        Layout h:[main | v:[test | logs]]
        Pane main
            Run cmd-main
        Pane test
            Run cmd-test
        Pane logs
            Run cmd-logs
"
    run cdp p dev
    [ "$status" -eq 0 ]
    # CDP_TMUX_PANE order must match walk order: main, test, logs
    main_line=$(printf '%s\n' "$output" | grep -n CDP_TMUX_PANE | grep main | cut -d: -f1)
    test_line=$(printf '%s\n' "$output" | grep -n CDP_TMUX_PANE | grep test | cut -d: -f1)
    logs_line=$(printf '%s\n' "$output" | grep -n CDP_TMUX_PANE | grep logs | cut -d: -f1)
    (( main_line < test_line ))
    (( test_line < logs_line ))
}

@test "tmux + macro coexist (different names) both dispatch" {
    mkdir -p "$BATS_TEST_TMPDIR/p"
    write_config "Project p
    Path $BATS_TEST_TMPDIR/p
    Macro deploy
        Run echo deploy
    Tmux dev
        Layout main
        Pane main
            Run echo go
"
    run cdp p deploy
    [ "$status" -eq 0 ]
    [[ "$output" == *"CDP_RUN echo deploy"* ]]
    run cdp p dev
    [ "$status" -eq 0 ]
    [[ "$output" == *"CDP_TMUX_SESSION p-dev"* ]]
}

@test "Macro/Tmux name collision (Macro-then-Tmux) is parse error 65" {
    mkdir -p "$BATS_TEST_TMPDIR/p"
    write_config "Project p
    Path $BATS_TEST_TMPDIR/p
    Macro dev
        Run echo
    Tmux dev
        Layout main
        Pane main
            Run x
"
    run cdp p dev
    [ "$status" -eq 65 ]
    [[ "$output" == *"already used as Macro"* ]]
}

@test "Tmux/Macro name collision (Tmux-then-Macro) is parse error 65" {
    mkdir -p "$BATS_TEST_TMPDIR/p"
    write_config "Project p
    Path $BATS_TEST_TMPDIR/p
    Tmux dev
        Layout main
        Pane main
            Run x
    Macro dev
        Run echo
"
    run cdp p dev
    [ "$status" -eq 65 ]
    [[ "$output" == *"already used as Tmux"* ]]
}

@test "duplicate Tmux name in same project is parse error 65" {
    mkdir -p "$BATS_TEST_TMPDIR/p"
    write_config "Project p
    Path $BATS_TEST_TMPDIR/p
    Tmux dev
        Layout main
        Pane main
            Run x
    Tmux dev
        Layout main
        Pane main
            Run y
"
    run cdp p dev
    [ "$status" -eq 65 ]
    [[ "$output" == *"duplicate tmux name 'dev'"* ]]
}

@test "missing Layout in Tmux block is parse error 65" {
    mkdir -p "$BATS_TEST_TMPDIR/p"
    write_config "Project p
    Path $BATS_TEST_TMPDIR/p
    Tmux dev
        Pane main
            Run x
"
    run cdp p dev
    [ "$status" -eq 65 ]
    [[ "$output" == *"has no Layout"* ]]
}

@test "multiple Layout lines in one Tmux is parse error 65" {
    mkdir -p "$BATS_TEST_TMPDIR/p"
    write_config "Project p
    Path $BATS_TEST_TMPDIR/p
    Tmux dev
        Layout main
        Layout main
        Pane main
            Run x
"
    run cdp p dev
    [ "$status" -eq 65 ]
    [[ "$output" == *"multiple Layout lines"* ]]
}

@test "Pane block with zero Run lines is parse error 65" {
    mkdir -p "$BATS_TEST_TMPDIR/p"
    write_config "Project p
    Path $BATS_TEST_TMPDIR/p
    Tmux dev
        Layout main
        Pane main
"
    run cdp p dev
    [ "$status" -eq 65 ]
    [[ "$output" == *"has no Run"* ]]
}

@test "Layout references undefined pane is parse error 65" {
    mkdir -p "$BATS_TEST_TMPDIR/p"
    write_config "Project p
    Path $BATS_TEST_TMPDIR/p
    Tmux dev
        Layout h:[main|missing]
        Pane main
            Run x
"
    run cdp p dev
    [ "$status" -eq 65 ]
    [[ "$output" == *"references undefined pane 'missing'"* ]]
}

@test "Pane defined but not referenced in Layout is parse error 65" {
    mkdir -p "$BATS_TEST_TMPDIR/p"
    write_config "Project p
    Path $BATS_TEST_TMPDIR/p
    Tmux dev
        Layout main
        Pane main
            Run x
        Pane orphan
            Run y
"
    run cdp p dev
    [ "$status" -eq 65 ]
    [[ "$output" == *"'orphan' defined but not referenced"* ]]
}

@test "Pane referenced more than once in Layout is parse error 65" {
    mkdir -p "$BATS_TEST_TMPDIR/p"
    write_config "Project p
    Path $BATS_TEST_TMPDIR/p
    Tmux dev
        Layout h:[same|same]
        Pane same
            Run x
"
    run cdp p dev
    [ "$status" -eq 65 ]
    [[ "$output" == *"referenced more than once"* ]]
}

@test "Tmux outside Project block is parse error 65" {
    write_config "Tmux orphan
    Layout main
    Pane main
        Run x
"
    run cdp anything
    [ "$status" -eq 65 ]
    [[ "$output" == *"Tmux outside Project block"* ]]
}

@test "Layout outside Tmux block is parse error 65" {
    mkdir -p "$BATS_TEST_TMPDIR/p"
    write_config "Project p
    Path $BATS_TEST_TMPDIR/p
    Layout orphan
"
    run cdp p
    [ "$status" -eq 65 ]
    [[ "$output" == *"Layout outside Tmux block"* ]]
}

@test "Pane outside Tmux block is parse error 65" {
    mkdir -p "$BATS_TEST_TMPDIR/p"
    write_config "Project p
    Path $BATS_TEST_TMPDIR/p
    Pane orphan
        Run x
"
    run cdp p
    [ "$status" -eq 65 ]
    [[ "$output" == *"Pane outside Tmux block"* ]]
}

@test "Tmux name reserved against subcommand is parse error 65" {
    mkdir -p "$BATS_TEST_TMPDIR/p"
    write_config "Project p
    Path $BATS_TEST_TMPDIR/p
    Tmux ls
        Layout main
        Pane main
            Run x
"
    run cdp p
    [ "$status" -eq 65 ]
    [[ "$output" == *"tmux name 'ls' is reserved"* ]]
}
