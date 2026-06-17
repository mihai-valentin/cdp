#!/usr/bin/env bats
# tests/group.bats — V1.4 Group blocks: parsing, macro inheritance, override.

load helpers

write_config() {
    printf '%s' "$1" > "$CDP_CONFIG"
}

# --- parsing -----------------------------------------------------------------

@test "Group block alone parses; no projects → ls is empty" {
    write_config "Group lonely
    Macro hello
        Run echo hi
"
    run cdp ls
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "empty Group (no Macros, no Projects) parses successfully" {
    write_config "Group nothing
"
    run cdp check
    [ "$status" -eq 0 ]
}

@test "Group + nested Project parses; ungrouped Project at column 0 still parses" {
    mkdir -p "$BATS_TEST_TMPDIR/p1" "$BATS_TEST_TMPDIR/p2"
    write_config "Group g1
    Project p1
        Path $BATS_TEST_TMPDIR/p1

Project standalone
    Path $BATS_TEST_TMPDIR/p2
"
    run cdp check
    [ "$status" -eq 0 ]
}

@test "Group label syntax: invalid label exits 65" {
    write_config "Group 1bad
    Macro m
        Run x
"
    run cdp ls
    [ "$status" -eq 65 ]
    [[ "$output" == *"invalid group label"* ]]
}

@test "duplicate Group label exits 65" {
    write_config "Group g
    Macro a
        Run x
Group g
    Macro b
        Run y
"
    run cdp ls
    [ "$status" -eq 65 ]
    [[ "$output" == *"duplicate group label"* ]]
}

@test "Group label that matches a reserved subcommand exits 65" {
    write_config "Group check
"
    run cdp ls
    [ "$status" -eq 65 ]
    [[ "$output" == *"reserved"* ]]
}

@test "Group requires a label (bare 'Group' exits 65)" {
    write_config "Group
"
    run cdp ls
    [ "$status" -eq 65 ]
    [[ "$output" == *"Group requires a label"* ]]
}

@test "duplicate Macro within a Group exits 65" {
    write_config "Group g
    Macro dup
        Run a
    Macro dup
        Run b
"
    run cdp ls
    [ "$status" -eq 65 ]
    [[ "$output" == *"duplicate macro name 'dup' in group 'g'"* ]]
}

# --- forbidden constructs inside Group --------------------------------------

# --- group root Path (V1.5) ---------------------------------------------------

@test "group Path root: member relative Path is joined onto the root" {
    write_config "Group g
    Path /home/user/ws
    Project cdp
        Path cdp
"
    run cdp ls
    [ "$status" -eq 0 ]
    [[ "$output" == "cdp	/home/user/ws/cdp	" ]]
}

@test "group Path root: member absolute Path wins (escapes the root)" {
    write_config "Group g
    Path /home/user/ws
    Project notes
        Path /opt/notes
"
    run cdp ls
    [ "$status" -eq 0 ]
    [[ "$output" == "notes	/opt/notes	" ]]
}

@test "group Path root: member with no Path resolves to the root itself" {
    write_config "Group g
    Path /home/user/ws
    Project root
"
    run cdp ls
    [ "$status" -eq 0 ]
    [[ "$output" == "root	/home/user/ws	" ]]
}

@test "group Path root: nested sub path joins correctly" {
    write_config "Group g
    Path /home/user/ws
    Project deep
        Path a/b/c
"
    run cdp ls
    [ "$status" -eq 0 ]
    [[ "$output" == "deep	/home/user/ws/a/b/c	" ]]
}

@test "group Path root: trailing slash on root is normalized" {
    write_config "Group g
    Path /home/user/ws/
    Project cdp
        Path cdp
"
    run cdp ls
    [ "$status" -eq 0 ]
    [[ "$output" == "cdp	/home/user/ws/cdp	" ]]
}

@test "group Path root: tilde expands in the root" {
    write_config "Group g
    Path ~/ws
    Project cdp
        Path cdp
"
    run cdp ls
    [ "$status" -eq 0 ]
    [[ "$output" == "cdp	$HOME/ws/cdp	" ]]
}

@test "group with no Path root: member relative Path is still an error" {
    write_config "Group g
    Macro m
        Run x
    Project cdp
        Path cdp
"
    run cdp ls
    [ "$status" -eq 65 ]
    [[ "$output" == *"Path must be absolute"* ]]
}

@test "group with no Path root: member with no Path is still an error" {
    write_config "Group g
    Macro m
        Run x
    Project cdp
"
    run cdp ls
    [ "$status" -eq 65 ]
    [[ "$output" == *"has no Path"* ]]
}

@test "group Path root: relative group root is an error" {
    write_config "Group g
    Path ws
    Project cdp
        Path cdp
"
    run cdp ls
    [ "$status" -eq 65 ]
    [[ "$output" == *"Group Path must be absolute"* ]]
}

@test "group Path root: duplicate group Path is an error" {
    write_config "Group g
    Path /a
    Path /b
    Project cdp
        Path cdp
"
    run cdp ls
    [ "$status" -eq 65 ]
    [[ "$output" == *"multiple Path lines for group"* ]]
}

@test "group Path root coexists with inherited macros" {
    write_config "Group g
    Path /home/user/ws
    Macro hello
        Run echo hi
    Project cdp
        Path cdp
"
    run cdp ls
    [ "$status" -eq 0 ]
    [[ "$output" == "cdp	/home/user/ws/cdp	hello:macro@g" ]]
}

@test "Tmux inside a Group block (no Project) exits 65" {
    write_config "Group g
    Tmux dev
        Layout main
        Pane main
            Run x
"
    run cdp ls
    [ "$status" -eq 65 ]
    [[ "$output" == *"Tmux inside Group block"* ]]
}

@test "nested Group (deeper indent) exits 65" {
    write_config "Group outer
    Group inner
        Macro m
            Run x
"
    run cdp ls
    [ "$status" -eq 65 ]
    [[ "$output" == *"nested Group"* ]]
}

# --- macro inheritance ------------------------------------------------------

@test "grouped Project inherits the Group's Macro" {
    mkdir -p "$BATS_TEST_TMPDIR/cdp"
    write_config "Group g
    Macro claude
        Run ../xlnfclaude -c

    Project cdp
        Path $BATS_TEST_TMPDIR/cdp
"
    run cdp cdp claude
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "CDP_CD $BATS_TEST_TMPDIR/cdp" ]
    [ "${lines[1]}" = "CDP_RUN ../xlnfclaude -c" ]
}

@test "Project's own Macro shadows the Group's same-named Macro" {
    mkdir -p "$BATS_TEST_TMPDIR/xlnf"
    write_config "Group g
    Macro claude
        Run ../xlnfclaude -c

    Project xlnf
        Path $BATS_TEST_TMPDIR/xlnf
        Macro claude
            Run ./xlnfclaude -c
"
    run cdp xlnf claude
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "CDP_CD $BATS_TEST_TMPDIR/xlnf" ]
    [ "${lines[1]}" = "CDP_RUN ./xlnfclaude -c" ]
}

@test "ungrouped Project does NOT see Group macros" {
    mkdir -p "$BATS_TEST_TMPDIR/lone"
    write_config "Group g
    Macro claude
        Run ../xlnfclaude -c

Project lone
    Path $BATS_TEST_TMPDIR/lone
"
    run cdp lone claude
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a macro or tmux of project 'lone'"* ]]
}

@test "multiple Projects in one Group all inherit the same Macro" {
    mkdir -p "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b" "$BATS_TEST_TMPDIR/c"
    write_config "Group g
    Macro claude
        Run xlnfclaude -c

    Project a
        Path $BATS_TEST_TMPDIR/a

    Project b
        Path $BATS_TEST_TMPDIR/b

    Project c
        Path $BATS_TEST_TMPDIR/c
"
    for proj in a b c; do
        run cdp "$proj" claude
        [ "$status" -eq 0 ]
        [ "${lines[0]}" = "CDP_CD $BATS_TEST_TMPDIR/$proj" ]
        [ "${lines[1]}" = "CDP_RUN xlnfclaude -c" ]
    done
}

@test "multi-Run group Macro emits one CDP_RUN per Run, in order" {
    mkdir -p "$BATS_TEST_TMPDIR/p"
    write_config "Group g
    Macro deploy
        Run step1
        Run step2
        Run step3

    Project p
        Path $BATS_TEST_TMPDIR/p
"
    run cdp p deploy
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "CDP_CD $BATS_TEST_TMPDIR/p" ]
    [ "${lines[1]}" = "CDP_RUN step1" ]
    [ "${lines[2]}" = "CDP_RUN step2" ]
    [ "${lines[3]}" = "CDP_RUN step3" ]
}

# --- ls annotation ----------------------------------------------------------

@test "ls suffixes inherited macros with @<group>; project-local stays plain" {
    mkdir -p "$BATS_TEST_TMPDIR/cdp" "$BATS_TEST_TMPDIR/xlnf"
    write_config "Group g
    Macro claude
        Run ../xlnfclaude -c

    Project cdp
        Path $BATS_TEST_TMPDIR/cdp

    Project xlnf
        Path $BATS_TEST_TMPDIR/xlnf
        Macro claude
            Run ./xlnfclaude -c
"
    run cdp ls
    [ "$status" -eq 0 ]
    # cdp inherits from g
    [[ "$output" == *"cdp"$'\t'*$'\t'"claude:macro@g"* ]]
    # xlnf shadows; its claude prints plain (no @g)
    [[ "$output" == *"xlnf"$'\t'*$'\t'"claude:macro"* ]]
    [[ "$output" != *"xlnf"$'\t'*$'\t'*"claude:macro@g"* ]]
}

@test "ls for ungrouped Project shows no @group annotation" {
    mkdir -p "$BATS_TEST_TMPDIR/lone"
    write_config "Group g
    Macro claude
        Run xlnfclaude -c

Project lone
    Path $BATS_TEST_TMPDIR/lone
"
    run cdp ls
    [ "$status" -eq 0 ]
    [[ "$output" != *"@g"* ]]
}

# --- Macro/Run state machine outside any block -----------------------------

@test "Macro outside Project AND outside Group exits 65" {
    write_config "Macro orphan
    Run x
"
    run cdp ls
    [ "$status" -eq 65 ]
    [[ "$output" == *"Macro outside Project or Group block"* ]]
}

# --- coexistence with Tmux blocks ------------------------------------------

@test "grouped Project may declare its own Tmux block alongside inherited Macro" {
    mkdir -p "$BATS_TEST_TMPDIR/p"
    write_config "Group g
    Macro claude
        Run xlnfclaude -c

    Project p
        Path $BATS_TEST_TMPDIR/p
        Tmux dev
            Layout main
            Pane main
                Run echo hi
"
    # Inherited macro still resolves.
    run cdp p claude
    [ "$status" -eq 0 ]
    [ "${lines[1]}" = "CDP_RUN xlnfclaude -c" ]

    # Tmux still works.
    run cdp p dev
    [ "$status" -eq 0 ]
    [[ "$output" == *"CDP_TMUX_SESSION p-dev"* ]]
}
