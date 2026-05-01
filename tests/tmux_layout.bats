#!/usr/bin/env bats
# tests/tmux_layout.bats — Layout DSL parser (lib/tmux.sh).

load helpers

# Run cdp_tmux_layout_parse against the given input and either:
#   - assert PANES + OPS match expectations (semicolon-separated for OPS), or
#   - assert it dies with rc 65 and stderr containing a substring.
#
# Helper invoked via `bash -c ...` so we get a clean subshell each call;
# this avoids parser-internal globals leaking between cases.

parse_ok() {
    local layout="$1" expect_panes="$2" expect_ops="$3"
    run bash -c "
        set -uo pipefail
        source ${BATS_TEST_DIRNAME}/../lib/tmux.sh
        cdp_tmux_layout_parse '$layout'
        printf 'PANES:%s\n' \"\${CDP_TMUX_LAYOUT_PANES[*]}\"
        printf 'OPS:'
        sep=''
        for op in \"\${CDP_TMUX_LAYOUT_OPS[@]}\"; do
            printf '%s%s' \"\$sep\" \"\$op\"
            sep=';'
        done
        printf '\n'
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"PANES:${expect_panes}"* ]]
    [[ "$output" == *"OPS:${expect_ops}"* ]]
}

parse_err() {
    local layout="$1" expect_substr="$2"
    run bash -c "
        set -uo pipefail
        source ${BATS_TEST_DIRNAME}/../lib/tmux.sh
        cdp_tmux_layout_parse '$layout'
    "
    [ "$status" -eq 65 ]
    [[ "$output" == *"$expect_substr"* ]]
}

@test "single-pane bare layout" {
    parse_ok "main" "main" "ROOT"
}

@test "two-pane horizontal split" {
    parse_ok "h:[a|b]" "a b" "ROOT;SPLIT h 0"
}

@test "two-pane vertical split" {
    parse_ok "v:[a|b]" "a b" "ROOT;SPLIT v 0"
}

@test "three-pane horizontal split" {
    parse_ok "h:[a|b|c]" "a b c" "ROOT;SPLIT h 0;SPLIT h 1"
}

@test "three-pane vertical split" {
    parse_ok "v:[a|b|c]" "a b c" "ROOT;SPLIT v 0;SPLIT v 1"
}

@test "main + nested vertical (h:[main|v:[test|logs]])" {
    parse_ok "h:[main|v:[test|logs]]" "main test logs" "ROOT;SPLIT h 0;SPLIT v 1"
}

@test "2x2 grid (h:[v:[a|b]|v:[c|d]]) — BFS-by-slot order" {
    parse_ok "h:[v:[a|b]|v:[c|d]]" "a c b d" "ROOT;SPLIT h 0;SPLIT v 0;SPLIT v 1"
}

@test "header + 3 columns (v:[hdr|h:[nav|body|aside]])" {
    parse_ok "v:[hdr|h:[nav|body|aside]]" "hdr nav body aside" "ROOT;SPLIT v 0;SPLIT h 1;SPLIT h 2"
}

@test "whitespace tolerant around tokens" {
    parse_ok "  h:[ a |  v:[ b | c ] ]  " "a b c" "ROOT;SPLIT h 0;SPLIT v 1"
}

@test "uppercase direction H is accepted" {
    parse_ok "H:[a|b]" "a b" "ROOT;SPLIT h 0"
}

@test "identifier with hyphen is accepted" {
    parse_ok "h:[main-app|side-bar]" "main-app side-bar" "ROOT;SPLIT h 0"
}

@test "tabs around tokens are accepted" {
    parse_ok $'h:[\ta\t|\tb\t]' "a b" "ROOT;SPLIT h 0"
}

@test "empty layout is rejected" {
    parse_err "" "layout malformed: empty"
}

@test "single-child split is rejected" {
    parse_err "h:[a]" "split with one child"
}

@test "unknown split direction is rejected" {
    parse_err "x:[a|b]" "unknown split direction 'x'"
}

@test "missing leading direction is rejected" {
    parse_err "[a|b]" "expected identifier"
}

@test "double pipe is rejected" {
    parse_err "h:[a||b]" "expected identifier"
}

@test "missing bracket after direction is rejected" {
    parse_err "h:a|b" "expected '['"
}

@test "trailing junk after layout is rejected" {
    parse_err "h:[a|b]extra" "trailing content"
}

@test "internal newline is rejected" {
    parse_err $'h:[a|\nb]' "unexpected character"
}

@test "leading digit in identifier is rejected" {
    parse_err "h:[1a|b]" "unexpected character '1'"
}

@test "duplicate pane reference is rejected" {
    parse_err "h:[same|same]" "referenced more than once"
}

@test "missing closing bracket is rejected" {
    parse_err "h:[a|b" "expected '|' or ']'"
}

@test "bare colon with no direction is rejected" {
    parse_err ":[a|b]" "expected identifier"
}
