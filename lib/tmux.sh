#!/usr/bin/env bash
# lib/tmux.sh — Layout DSL parser for cdp Tmux blocks.
# Tested by tests/tmux_layout.bats.
#
# Sourced (not executed). Public API:
#
#   cdp_tmux_layout_parse <layout-string>
#       Parse and walk a Layout DSL expression. On success, populates two
#       global arrays in the caller's scope:
#           CDP_TMUX_LAYOUT_PANES  (indexed): pane names in tmux walk order
#           CDP_TMUX_LAYOUT_OPS    (indexed): one record per pane:
#               "ROOT"               for the first pane (created via
#                                    `tmux new-session`)
#               "SPLIT <h|v> <i>"    for subsequent panes (created via
#                                    `tmux split-window -<h|v>` against the
#                                    pane at walk-index <i>)
#       On parse error, dies via cdp_die with exit code 65.
#
#   cdp_tmux_layout_pane_set
#       Print one pane name per line from CDP_TMUX_LAYOUT_PANES (used by
#       lib/config.sh to cross-validate Pane definitions vs Layout
#       references).
#
# Walk-order semantics — BFS by slot, NOT depth-first.
# See docs/specs/tmux-layout.md §6.3 for the canonical algorithm.
#
# Worked examples:
#
#   Layout `h:[main | v:[test | logs]]`
#     PANES = (main test logs)
#     OPS   = (ROOT  "SPLIT h 0"  "SPLIT v 1")
#     tmux  : new-session -> pane 0 (main)
#             split-window -h -t 0 -> pane 1 (test, right of main)
#             split-window -v -t 1 -> pane 2 (logs, below test)
#
#   Layout `h:[v:[a | b] | v:[c | d]]`   (a 2x2 grid)
#     PANES = (a c b d)
#     OPS   = (ROOT  "SPLIT h 0"  "SPLIT v 0"  "SPLIT v 1")
#     tmux  : new-session -> pane 0 (a)
#             split-window -h -t 0 -> pane 1 (c, right column top)
#             split-window -v -t 0 -> pane 2 (b, below a in left column)
#             split-window -v -t 1 -> pane 3 (d, below c in right column)
#     A naive depth-first emission (a, b, c, d) would force tmux into an
#     L-shaped partition (impossible). The BFS-by-slot order materializes
#     the outer split's columns BEFORE subdividing either column.

[[ -n "${_CDP_TMUX_SH:-}" ]] && return 0
_CDP_TMUX_SH=1

if [[ -z "${_CDP_LOG_SH:-}" ]]; then
    # shellcheck source=lib/log.sh
    source "${BASH_SOURCE[0]%/*}/log.sh"
fi

# --- Lexer / parser internal state ----------------------------------------

_lt_reset_state() {
    _LT_INPUT="$1"
    _LT_POS=0
    _LT_INPUT_LEN=${#_LT_INPUT}
    _LT_TOK_KIND=""
    _LT_TOK_VAL=""
    _LT_NEXT_ID=0
    _LT_KIND=()
    _LT_NAME=()
    _LT_DIR=()
    _LT_CHILDREN=()
    _LT_LAST_NODE_ID=0
    _LT_LEFTMOST_NAME=""
}

_lt_skip_ws() {
    while (( _LT_POS < _LT_INPUT_LEN )); do
        case "${_LT_INPUT:$_LT_POS:1}" in
            ' '|$'\t') _LT_POS=$((_LT_POS + 1)) ;;
            *) break ;;
        esac
    done
}

_lt_advance() {
    _lt_skip_ws
    if (( _LT_POS >= _LT_INPUT_LEN )); then
        _LT_TOK_KIND=EOF
        _LT_TOK_VAL=""
        return 0
    fi
    local c="${_LT_INPUT:$_LT_POS:1}"
    case "$c" in
        ':') _LT_TOK_KIND=COLON;    _LT_TOK_VAL=":"; _LT_POS=$((_LT_POS + 1)) ;;
        '[') _LT_TOK_KIND=LBRACKET; _LT_TOK_VAL="["; _LT_POS=$((_LT_POS + 1)) ;;
        ']') _LT_TOK_KIND=RBRACKET; _LT_TOK_VAL="]"; _LT_POS=$((_LT_POS + 1)) ;;
        '|') _LT_TOK_KIND=PIPE;     _LT_TOK_VAL="|"; _LT_POS=$((_LT_POS + 1)) ;;
        [a-zA-Z])
            local start=$_LT_POS
            while (( _LT_POS < _LT_INPUT_LEN )); do
                case "${_LT_INPUT:$_LT_POS:1}" in
                    [a-zA-Z0-9_-]) _LT_POS=$((_LT_POS + 1)) ;;
                    *) break ;;
                esac
            done
            _LT_TOK_KIND=IDENT
            _LT_TOK_VAL="${_LT_INPUT:$start:$((_LT_POS - start))}"
            ;;
        *)
            CDP_DIE_EXIT=65 cdp_die "layout malformed: unexpected character '$c' at offset $_LT_POS"
            ;;
    esac
}

# --- AST construction -----------------------------------------------------

_lt_new_leaf() {
    local id=$_LT_NEXT_ID
    _LT_KIND[id]="leaf"
    _LT_NAME[id]="$1"
    _LT_DIR[id]=""
    _LT_CHILDREN[id]=""
    _LT_NEXT_ID=$((_LT_NEXT_ID + 1))
    _LT_LAST_NODE_ID=$id
}

_lt_new_split() {
    local id=$_LT_NEXT_ID
    _LT_KIND[id]="split"
    _LT_NAME[id]=""
    _LT_DIR[id]="$1"
    _LT_CHILDREN[id]="$2"
    _LT_NEXT_ID=$((_LT_NEXT_ID + 1))
    _LT_LAST_NODE_ID=$id
}

# --- Recursive-descent parser --------------------------------------------

_lt_parse_node() {
    if [[ "$_LT_TOK_KIND" != IDENT ]]; then
        CDP_DIE_EXIT=65 cdp_die "layout malformed: expected identifier at offset $_LT_POS"
    fi
    local first_ident="$_LT_TOK_VAL"
    _lt_advance
    if [[ "$_LT_TOK_KIND" != COLON ]]; then
        # Bare identifier — leaf pane reference.
        _lt_new_leaf "$first_ident"
        return 0
    fi
    # It's a split. first_ident must be the direction.
    local dir_lower="${first_ident,,}"
    if [[ "$dir_lower" != "h" && "$dir_lower" != "v" ]]; then
        CDP_DIE_EXIT=65 cdp_die "layout malformed: unknown split direction '$first_ident'; expected h or v"
    fi
    _lt_advance  # consume COLON
    if [[ "$_LT_TOK_KIND" != LBRACKET ]]; then
        CDP_DIE_EXIT=65 cdp_die "layout malformed: expected '[' after '${first_ident}:' at offset $_LT_POS"
    fi
    _lt_advance  # consume LBRACKET
    _lt_parse_node
    local children="$_LT_LAST_NODE_ID"
    local count=1
    while [[ "$_LT_TOK_KIND" == PIPE ]]; do
        _lt_advance  # consume PIPE
        _lt_parse_node
        children="${children} ${_LT_LAST_NODE_ID}"
        count=$((count + 1))
    done
    if [[ "$_LT_TOK_KIND" != RBRACKET ]]; then
        CDP_DIE_EXIT=65 cdp_die "layout malformed: expected '|' or ']' at offset $_LT_POS"
    fi
    _lt_advance  # consume RBRACKET
    if (( count < 2 )); then
        CDP_DIE_EXIT=65 cdp_die "layout malformed: split with one child is meaningless"
    fi
    _lt_new_split "$dir_lower" "$children"
}

# --- Walk: BFS-by-slot ----------------------------------------------------

_lt_leftmost_leaf_name() {
    # Descend the left spine of the subtree rooted at $1; set _LT_LEFTMOST_NAME.
    local id=$1
    while [[ "${_LT_KIND[$id]}" == split ]]; do
        id="${_LT_CHILDREN[$id]%% *}"
    done
    _LT_LEFTMOST_NAME="${_LT_NAME[$id]}"
}

_lt_walk_emit() {
    local root_id=$1
    CDP_TMUX_LAYOUT_PANES=()
    CDP_TMUX_LAYOUT_OPS=()

    _lt_leftmost_leaf_name "$root_id"
    CDP_TMUX_LAYOUT_PANES+=("$_LT_LEFTMOST_NAME")
    CDP_TMUX_LAYOUT_OPS+=("ROOT")

    local -a queue=("${root_id}"$'\t'0)
    local head=0
    while (( head < ${#queue[@]} )); do
        local entry="${queue[$head]}"
        head=$((head + 1))
        local node_id="${entry%%$'\t'*}"
        local my_idx="${entry#*$'\t'}"
        if [[ "${_LT_KIND[$node_id]}" != split ]]; then
            continue
        fi
        local dir="${_LT_DIR[$node_id]}"
        # Children list is space-separated; intentional word-splitting.
        # shellcheck disable=SC2206
        local -a kids=(${_LT_CHILDREN[$node_id]})
        local -a reps=("$my_idx")
        local i
        for (( i=1; i<${#kids[@]}; i++ )); do
            local prev_idx="${reps[$((i - 1))]}"
            _lt_leftmost_leaf_name "${kids[$i]}"
            CDP_TMUX_LAYOUT_PANES+=("$_LT_LEFTMOST_NAME")
            local new_idx=$((${#CDP_TMUX_LAYOUT_PANES[@]} - 1))
            CDP_TMUX_LAYOUT_OPS+=("SPLIT ${dir} ${prev_idx}")
            reps+=("$new_idx")
        done
        for (( i=0; i<${#kids[@]}; i++ )); do
            queue+=("${kids[$i]}"$'\t'"${reps[$i]}")
        done
    done
}

# --- Public API -----------------------------------------------------------

cdp_tmux_layout_parse() {
    local input="$1"
    if [[ -z "$input" ]]; then
        CDP_DIE_EXIT=65 cdp_die "layout malformed: empty"
    fi
    _lt_reset_state "$input"
    _lt_advance
    _lt_parse_node
    if [[ "$_LT_TOK_KIND" != EOF ]]; then
        CDP_DIE_EXIT=65 cdp_die "layout malformed: trailing content at offset $_LT_POS"
    fi
    _lt_walk_emit "$_LT_LAST_NODE_ID"

    declare -A _LT_SEEN=()
    local p
    for p in "${CDP_TMUX_LAYOUT_PANES[@]}"; do
        if [[ -n "${_LT_SEEN[$p]+x}" ]]; then
            CDP_DIE_EXIT=65 cdp_die "pane '$p' referenced more than once in layout"
        fi
        _LT_SEEN[$p]=1
    done

    unset _LT_INPUT _LT_POS _LT_INPUT_LEN _LT_TOK_KIND _LT_TOK_VAL
    unset _LT_NEXT_ID _LT_KIND _LT_NAME _LT_DIR _LT_CHILDREN
    unset _LT_LAST_NODE_ID _LT_LEFTMOST_NAME _LT_SEEN
}

cdp_tmux_layout_pane_set() {
    local p
    for p in "${CDP_TMUX_LAYOUT_PANES[@]}"; do
        printf '%s\n' "$p"
    done
}
