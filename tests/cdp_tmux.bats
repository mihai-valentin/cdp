#!/usr/bin/env bats
# tests/cdp_tmux.bats — orchestrator (libexec/cdp-tmux) against a tmux stub.
# The stub at tests/fixtures/bin/tmux logs every invocation; tests inspect
# the log to assert the right tmux commands ran in the right order.

load helpers

cdp_tmux_bin() {
    printf '%s' "${BATS_TEST_DIRNAME}/../libexec/cdp-tmux"
}

# Read the log into BATS variables: $log_lines (count), accessor lines[n].
# Use mapfile so blank lines aren't dropped.
read_log() {
    mapfile -t log_lines < "$CDP_TEST_TMUX_LOG"
}

@test "create-and-attach: 1-pane session" {
    setup_tmux_stub
    "$(cdp_tmux_bin)" sess "main" "main$(printf '\037')echo hi"
    read_log
    [[ "${log_lines[0]}" == "tmux has-session -t sess" ]]
    [[ "${log_lines[1]}" == "tmux new-session -d -s sess -c "* ]]
    [[ "${log_lines[2]}" == "tmux list-panes -t sess:cdp"* ]]
    [[ "${log_lines[3]}" == "tmux send-keys -t sess:cdp.%0 -- echo\\ hi Enter" ]]
    [[ "${log_lines[4]}" == "tmux attach -t sess" ]]
}

@test "create-and-attach: 3-pane h:[a|b|c]" {
    setup_tmux_stub
    "$(cdp_tmux_bin)" sess "h:[a|b|c]" \
        "a$(printf '\037')cmd-a" \
        "b$(printf '\037')cmd-b" \
        "c$(printf '\037')cmd-c"
    read_log
    grep -q '^tmux has-session ' "$CDP_TEST_TMUX_LOG"
    grep -q '^tmux new-session -d -s sess ' "$CDP_TEST_TMUX_LOG"
    # Two horizontal split-windows, in walk order: split %0 then split %1.
    split_lines=$(grep -c '^tmux split-window ' "$CDP_TEST_TMUX_LOG")
    [ "$split_lines" -eq 2 ]
    grep -q '^tmux split-window -t sess:cdp.%0 -h ' "$CDP_TEST_TMUX_LOG"
    grep -q '^tmux split-window -t sess:cdp.%1 -h ' "$CDP_TEST_TMUX_LOG"
    # Three send-keys, one per pane.
    sk_lines=$(grep -c '^tmux send-keys ' "$CDP_TEST_TMUX_LOG")
    [ "$sk_lines" -eq 3 ]
    # Final attach.
    tail -n 1 "$CDP_TEST_TMUX_LOG" | grep -q '^tmux attach -t sess$'
}

@test "create-and-attach: nested h:[main|v:[test|logs]]" {
    setup_tmux_stub
    "$(cdp_tmux_bin)" sess "h:[main|v:[test|logs]]" \
        "main$(printf '\037')pnpm dev" \
        "test$(printf '\037')pnpm test" \
        "logs$(printf '\037')tail -f log"
    # Order: new-session, list-panes, split -h (main->test), split -v (test->logs),
    #        send-keys main, send-keys test, send-keys logs, attach.
    grep -nq '^tmux split-window -t sess:cdp.%0 -h ' "$CDP_TEST_TMUX_LOG"
    grep -nq '^tmux split-window -t sess:cdp.%1 -v ' "$CDP_TEST_TMUX_LOG"
    sk_lines=$(grep -c '^tmux send-keys ' "$CDP_TEST_TMUX_LOG")
    [ "$sk_lines" -eq 3 ]
    tail -n 1 "$CDP_TEST_TMUX_LOG" | grep -q '^tmux attach -t sess$'
}

@test "create-and-attach: 2x2 grid (BFS-by-slot order)" {
    setup_tmux_stub
    "$(cdp_tmux_bin)" sess "h:[v:[a|b]|v:[c|d]]" \
        "a$(printf '\037')A" \
        "b$(printf '\037')B" \
        "c$(printf '\037')C" \
        "d$(printf '\037')D"
    # Walk-order panes: a c b d. Splits in order: -h against %0, -v against %0,
    # -v against %1.
    grep -q '^tmux split-window -t sess:cdp.%0 -h ' "$CDP_TEST_TMUX_LOG"
    grep -q '^tmux split-window -t sess:cdp.%0 -v ' "$CDP_TEST_TMUX_LOG"
    grep -q '^tmux split-window -t sess:cdp.%1 -v ' "$CDP_TEST_TMUX_LOG"
    sk_count=$(grep -c '^tmux send-keys ' "$CDP_TEST_TMUX_LOG")
    [ "$sk_count" -eq 4 ]
}

@test "existing session short-circuits to attach" {
    setup_tmux_stub
    CDP_TEST_HAS_SESSION=1 "$(cdp_tmux_bin)" sess "h:[a|b|c]" \
        "a$(printf '\037')A" \
        "b$(printf '\037')B" \
        "c$(printf '\037')C"
    # Only has-session + attach should appear; NO new-session, NO splits, NO send-keys.
    ! grep -q '^tmux new-session ' "$CDP_TEST_TMUX_LOG"
    ! grep -q '^tmux split-window ' "$CDP_TEST_TMUX_LOG"
    ! grep -q '^tmux send-keys ' "$CDP_TEST_TMUX_LOG"
    grep -q '^tmux has-session -t sess$' "$CDP_TEST_TMUX_LOG"
    grep -q '^tmux attach -t sess$' "$CDP_TEST_TMUX_LOG"
}

@test "inside tmux (\$TMUX set) + existing session uses switch-client" {
    setup_tmux_stub
    TMUX="/tmp/test-socket,1234,0" CDP_TEST_HAS_SESSION=1 \
        "$(cdp_tmux_bin)" sess "main" "main$(printf '\037')x"
    grep -q '^tmux switch-client -t sess$' "$CDP_TEST_TMUX_LOG"
    ! grep -q '^tmux attach ' "$CDP_TEST_TMUX_LOG"
}

@test "inside tmux + foreign socket dies exit 3" {
    setup_tmux_stub
    # Stub returns /tmp/test-socket from display-message; we set $TMUX to a
    # different socket to trigger the foreign-server check.
    run env TMUX="/tmp/different-socket,1234,0" \
        "$(cdp_tmux_bin)" sess "main" "main$(printf '\037')x"
    [ "$status" -eq 3 ]
    [[ "$output" == *"different tmux server"* ]]
}

@test "missing required arguments dies exit 70 (protocol bug)" {
    setup_tmux_stub
    run "$(cdp_tmux_bin)"
    [ "$status" -eq 70 ]
    [[ "$output" == *"missing required arguments"* ]]
}

@test "tmux not on PATH dies exit 3" {
    # Build a private bin dir with everything needed EXCEPT tmux.
    isolate_dir="${BATS_TEST_TMPDIR}/no-tmux-bin"
    mkdir -p "$isolate_dir"
    for util in env bash dirname cd printf cat sed grep mkdir cut head tail mapfile; do
        if path="$(command -v "$util" 2>/dev/null)"; then
            ln -sf "$path" "${isolate_dir}/$(basename "$util")" 2>/dev/null || true
        fi
    done
    # Confirm tmux is NOT in $isolate_dir
    [ ! -e "${isolate_dir}/tmux" ]
    PATH="$isolate_dir" run "$(cdp_tmux_bin)" sess "main" "main$(printf '\037')x"
    [ "$status" -eq 3 ]
    [[ "$output" == *"tmux not found on PATH"* ]]
}

@test "regression: orchestrator runs tmux even when its stdin is a heredoc" {
    # The shell shim wraps cdp-tmux invocations inside `done <<<"$plan"`,
    # which redirects stdin to a here-string. Pre-fix, that caused
    # `tmux attach` to die with "open terminal failed: not a terminal".
    # Verify the orchestrator successfully reaches tmux even when its
    # stdin is non-TTY (a pipe in this test, mimicking the heredoc shape).
    setup_tmux_stub
    printf 'unused\n' | "$(cdp_tmux_bin)" sess "main" "main$(printf '\037')echo hi"
    grep -q '^tmux attach -t sess$' "$CDP_TEST_TMUX_LOG"
}

@test "multiple Run lines per pane batch into multiple send-keys" {
    setup_tmux_stub
    "$(cdp_tmux_bin)" sess "main" \
        "main$(printf '\037')cmd1" \
        "main$(printf '\037')cmd2" \
        "main$(printf '\037')cmd3"
    sk_count=$(grep -c '^tmux send-keys ' "$CDP_TEST_TMUX_LOG")
    [ "$sk_count" -eq 3 ]
    # All three send-keys target the seed pane id %0.
    seed_targets=$(grep -c 'send-keys -t sess:cdp.%0 ' "$CDP_TEST_TMUX_LOG")
    [ "$seed_targets" -eq 3 ]
}
