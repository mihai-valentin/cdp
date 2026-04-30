#!/usr/bin/env bats
# tests/config_parse.bats — exercise lib/config.sh via cdp-resolve / cdp-ls.

load helpers

# Helper: write a config to $CDP_CONFIG.
write_config() {
    printf '%s' "$1" > "$CDP_CONFIG"
}

@test "empty config: ls exits 0 with no output" {
    : > "$CDP_CONFIG"
    run cdp ls
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "one project with one Path parses" {
    mkdir -p "$BATS_TEST_TMPDIR/proj"
    write_config "Project foo
    Path $BATS_TEST_TMPDIR/proj
"
    run cdp foo
    [ "$status" -eq 0 ]
    [ "$output" = "CDP_CD $BATS_TEST_TMPDIR/proj" ]
}

@test "two projects with multi-Run macros parse" {
    mkdir -p "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
    write_config "Project a
    Path $BATS_TEST_TMPDIR/a
    Macro deploy
        Run echo build
        Run echo publish

Project b
    Path $BATS_TEST_TMPDIR/b
    Macro logs
        Run echo tail
"
    run cdp a deploy
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "CDP_CD $BATS_TEST_TMPDIR/a" ]
    [ "${lines[1]}" = "CDP_RUN echo build" ]
    [ "${lines[2]}" = "CDP_RUN echo publish" ]

    run cdp b logs
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "CDP_CD $BATS_TEST_TMPDIR/b" ]
    [ "${lines[1]}" = "CDP_RUN echo tail" ]
}

@test "tilde expansion resolves to \$HOME" {
    mkdir -p "$HOME/.cdp-bats-tilde-test"
    write_config "Project tilde
    Path ~/.cdp-bats-tilde-test
"
    run cdp tilde
    [ "$status" -eq 0 ]
    [ "$output" = "CDP_CD $HOME/.cdp-bats-tilde-test" ]
    rm -rf "$HOME/.cdp-bats-tilde-test"
}

@test "lowercased keywords accepted" {
    mkdir -p "$BATS_TEST_TMPDIR/lower"
    write_config "project lower
    path $BATS_TEST_TMPDIR/lower
    macro hello
        run echo hi
"
    run cdp lower hello
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "CDP_CD $BATS_TEST_TMPDIR/lower" ]
    [ "${lines[1]}" = "CDP_RUN echo hi" ]
}

@test "comments and blank lines are ignored" {
    mkdir -p "$BATS_TEST_TMPDIR/c"
    write_config "# leading comment

Project c
    # interior comment
    Path $BATS_TEST_TMPDIR/c

# trailing comment
"
    run cdp c
    [ "$status" -eq 0 ]
    [ "$output" = "CDP_CD $BATS_TEST_TMPDIR/c" ]
}

@test "parse error: duplicate label" {
    write_config "Project foo
    Path /tmp
Project foo
    Path /var
"
    run cdp ls
    [ "$status" -eq 65 ]
    [[ "$output" == *"duplicate"* ]]
}

@test "parse error: missing Path" {
    write_config "Project nopath
"
    run cdp ls
    [ "$status" -eq 65 ]
    [[ "$output" == *"no Path"* ]]
}

@test "parse error: relative Path" {
    write_config "Project rel
    Path tmp/foo
"
    run cdp ls
    [ "$status" -eq 65 ]
    [[ "$output" == *"absolute"* ]]
}

@test "parse error: Macro outside Project block" {
    write_config "Macro orphan
    Run echo hi
"
    run cdp ls
    [ "$status" -eq 65 ]
    [[ "$output" == *"Macro outside Project"* ]]
}

@test "parse error: Run outside Macro block" {
    write_config "Project p
    Path /tmp
    Run echo hi
"
    run cdp ls
    [ "$status" -eq 65 ]
    [[ "$output" == *"Run outside Macro"* ]]
}

@test "parse error: reserved label 'add'" {
    write_config "Project add
    Path /tmp
"
    run cdp ls
    [ "$status" -eq 65 ]
    [[ "$output" == *"reserved"* ]]
}

@test "parse error: empty Run line" {
    write_config "Project p
    Path /tmp
    Macro m
        Run
"
    run cdp ls
    [ "$status" -eq 65 ]
    [[ "$output" == *"empty Run"* ]]
}

@test "tabs+spaces mixed indentation accepted" {
    mkdir -p "$BATS_TEST_TMPDIR/mixed"
    # First line uses tabs, second uses spaces.
    printf 'Project mixed\n\tPath %s\n    Macro hello\n\t\tRun echo hi\n        Run echo bye\n' \
        "$BATS_TEST_TMPDIR/mixed" > "$CDP_CONFIG"
    run cdp mixed hello
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "CDP_CD $BATS_TEST_TMPDIR/mixed" ]
    [ "${lines[1]}" = "CDP_RUN echo hi" ]
    [ "${lines[2]}" = "CDP_RUN echo bye" ]
}
