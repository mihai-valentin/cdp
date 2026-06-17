#!/usr/bin/env bash
# lib/config.sh — cdp config-file parser.
# Tested by tests/config_parse.bats, tests/config_parse_tmux.bats and
# tests/group.bats.
#
# Sourced (not executed). Populates these globals in the caller's scope:
#
#   V1 (Project / Path / Macro / Run):
#     CDP_PROJECTS  (assoc): label -> 1
#     CDP_PATHS     (assoc): label -> absolute path
#     CDP_MACROS    (assoc): "label\x1fmacro" -> 1
#     CDP_RUNS_<label>_<macro> (indexed): Run command lines, source order.
#
#   V1.1 (Tmux / Layout / Pane):
#     CDP_TMUX_LAYOUTS         (assoc): "label\x1ftmux"            -> layout DSL string
#     CDP_TMUX_LAYOUT_LINENOS  (assoc): "label\x1ftmux"            -> source lineno of Layout
#     CDP_TMUX_PANES           (assoc): "label\x1ftmux\x1fpane"    -> 1
#     CDP_TMUX_PANE_LINENOS    (assoc): "label\x1ftmux\x1fpane"    -> source lineno of Pane
#     CDP_TMUX_PANE_RUNS_<label>_<tmux>_<pane> (indexed): Run lines, source order.
#
#   Unified action map (V1 macros + V1.1 tmux blocks):
#     CDP_ACTIONS       (assoc): "label\x1fname"  -> "macro" | "tmux"
#     CDP_ACTION_ORDER  (indexed): "label\x1fname" records in source order
#                                   (used by `cdp ls` to preserve config order)
#
#   V1.4 (Group / inherited Macros):
#     CDP_GROUPS         (assoc): group-name -> 1
#     CDP_PROJECT_GROUP  (assoc): label      -> group-name (only for grouped projects)
#     CDP_GROUP_MACROS   (assoc): "group\x1fmacro" -> 1
#     CDP_GROUP_RUNS_<group>_<macro> (indexed): Run lines, source order.
#
#   V1.5 (Group root Path):
#     CDP_GROUP_PATHS    (assoc): group-name -> absolute workspace-root path.
#       When set, a member project's relative Path is joined onto this root
#       (group root + sub path); an absolute member Path wins (escapes the
#       root); a member with no Path resolves to the group root itself. The
#       composition happens at parse time, so CDP_PATHS still holds the final
#       absolute path for every project — downstream consumers are unchanged.
#
#   Hyphens in identifiers are mapped to underscores for the array-name
#   portion only (bash identifier rules); the originals are preserved as
#   keys in the assoc maps.

[[ -n "${_CDP_CONFIG_SH:-}" ]] && return 0
_CDP_CONFIG_SH=1

# log helpers (cdp_die, cdp_warn).
if [[ -z "${_CDP_LOG_SH:-}" ]]; then
    # shellcheck source=lib/log.sh
    source "${BASH_SOURCE[0]%/*}/log.sh"
fi

# Layout DSL parser (cdp_tmux_layout_parse, cdp_tmux_layout_pane_set).
if [[ -z "${_CDP_TMUX_SH:-}" ]]; then
    # shellcheck source=lib/tmux.sh
    source "${BASH_SOURCE[0]%/*}/tmux.sh"
fi

# Reserved subcommand list — labels and macro/tmux/pane names that are forbidden.
_cdp_is_reserved() {
    case "$1" in
        add|rm|ls|init|edit|check|help|version|--help|--version|-h|-v) return 0 ;;
        *) return 1 ;;
    esac
}

# cdp_config_path — emit the resolved config-file path. Does not check existence.
cdp_config_path() {
    if [[ -n "${CDP_CONFIG:-}" ]]; then
        printf '%s\n' "$CDP_CONFIG"
    elif [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
        printf '%s/cdp/config\n' "$XDG_CONFIG_HOME"
    else
        printf '%s/.config/cdp/config\n' "$HOME"
    fi
}

# cdp_config_load_or_die — convenience wrapper: resolve path, check readability,
# parse. Exits 2 if missing or unreadable.
cdp_config_load_or_die() {
    local path
    path="$(cdp_config_path)"
    if [[ ! -e "$path" ]]; then
        # Per spec: name the path the user is most likely meant to create.
        local default_path="${HOME}/.config/cdp/config"
        CDP_DIE_EXIT=2 cdp_die "config file not found at ${default_path}"
    fi
    if [[ ! -r "$path" ]]; then
        CDP_DIE_EXIT=2 cdp_die "config file not readable at ${path}"
    fi
    cdp_config_parse "$path"
}

# cdp_config_parse <file> — parse a config file. See top-of-file docs for the
# arrays it populates.
cdp_config_parse() {
    local file="$1"
    declare -gA CDP_PROJECTS=() CDP_PATHS=() CDP_MACROS=()
    declare -gA CDP_TMUX_LAYOUTS=() CDP_TMUX_LAYOUT_LINENOS=()
    declare -gA CDP_TMUX_PANES=() CDP_TMUX_PANE_LINENOS=()
    declare -gA CDP_ACTIONS=()
    declare -ga CDP_ACTION_ORDER=()
    declare -gA CDP_GROUPS=() CDP_PROJECT_GROUP=() CDP_GROUP_MACROS=()
    declare -gA CDP_GROUP_PATHS=()

    # Save and enable nocasematch for keyword case-insensitivity.
    local _had_nocase=0
    shopt -q nocasematch && _had_nocase=1
    shopt -s nocasematch

    local lineno=0
    local _proj="" _macro="" _tmux="" _pane=""
    local _group="" _group_indent=-1
    local line line_trimmed first value arr_name key gkey
    local leading_ws indent

    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"
        # Compute leading-whitespace byte count (used for Group nesting checks)
        # and the trimmed body in one pass.
        leading_ws="${line%%[![:space:]]*}"
        indent="${#leading_ws}"
        line_trimmed="${line#"$leading_ws"}"

        # Skip blank lines and comments.
        if [[ -z "$line_trimmed" ]] || [[ "${line_trimmed:0:1}" == "#" ]]; then
            continue
        fi

        # Split on first whitespace into <keyword> <value-with-leading-ws>.
        first="${line_trimmed%%[[:space:]]*}"
        if [[ "$first" == "$line_trimmed" ]]; then
            value=""
        else
            value="${line_trimmed#"$first"}"
            # Trim leading whitespace from value.
            value="${value#"${value%%[![:space:]]*}"}"
        fi
        # Trim trailing whitespace from value.
        value="${value%"${value##*[![:space:]]}"}"

        case "$first" in
            Group)
                if [[ -z "$value" ]]; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: Group requires a label"
                fi
                if ! [[ "$value" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: invalid group label: '${value}'"
                fi
                if _cdp_is_reserved "$value"; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: group label '${value}' is reserved"
                fi
                # Nested Group is forbidden — a deeper-indented Group inside an
                # already-open Group has no defined inheritance semantics in V1.4.
                if [[ -n "$_group" && "$indent" -gt "$_group_indent" ]]; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: nested Group not allowed"
                fi
                if [[ -n "${CDP_GROUPS[$value]+x}" ]]; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: duplicate group label: '${value}'"
                fi
                _group="$value"
                _group_indent="$indent"
                _proj=""
                _macro=""
                _tmux=""
                _pane=""
                CDP_GROUPS["$_group"]=1
                ;;
            Project)
                # If we were inside a Group but this Project sits at sibling /
                # outer indent, leave the group before processing.
                if [[ -n "$_group" && "$indent" -le "$_group_indent" ]]; then
                    _group=""
                    _group_indent=-1
                fi
                if [[ -z "$value" ]]; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: Project requires a label"
                fi
                if ! [[ "$value" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: invalid project label: '${value}'"
                fi
                if _cdp_is_reserved "$value"; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: project label '${value}' is reserved"
                fi
                if [[ -n "${CDP_PROJECTS[$value]+x}" ]]; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: duplicate label: '${value}'"
                fi
                _proj="$value"
                _macro=""
                _tmux=""
                _pane=""
                CDP_PROJECTS["$_proj"]=1
                if [[ -n "$_group" ]]; then
                    CDP_PROJECT_GROUP["$_proj"]="$_group"
                fi
                ;;
            Path)
                if [[ -z "$value" ]]; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: Path requires a value"
                fi
                # Tilde expansion. The literal "~/" below is a glob pattern,
                # not a parameter intended for tilde expansion; ${var#~/}
                # would tilde-expand the pattern before stripping, so we
                # slice positionally instead.
                # shellcheck disable=SC2088
                case "$value" in
                    "~")    value="$HOME" ;;
                    "~/"*)  value="$HOME/${value:2}" ;;
                esac
                if [[ -z "$_proj" ]]; then
                    if [[ -n "$_group" ]]; then
                        # V1.5: Path directly under a Group sets the group's
                        # workspace root. Member projects join their relative
                        # Path onto it. Must precede the group's member
                        # Projects (once a Project opens, _proj is set and a
                        # Path line belongs to that project).
                        if [[ "$value" != /* ]]; then
                            CDP_DIE_EXIT=65 cdp_die "config:${lineno}: Group Path must be absolute: '${value}'"
                        fi
                        if [[ -n "${CDP_GROUP_PATHS[$_group]+x}" ]]; then
                            CDP_DIE_EXIT=65 cdp_die "config:${lineno}: multiple Path lines for group '${_group}'"
                        fi
                        # Strip trailing slashes for clean joins (keep "/").
                        while [[ "$value" == */ && "$value" != "/" ]]; do
                            value="${value%/}"
                        done
                        CDP_GROUP_PATHS["$_group"]="$value"
                        continue
                    fi
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: Path outside Project block"
                fi
                # Project-level Path. Inside a group with a root, a relative
                # value is joined onto the root; an absolute value wins
                # (escapes the root). Outside such a group, a relative value
                # remains an error.
                if [[ "$value" != /* ]]; then
                    if [[ -n "$_group" && -n "${CDP_GROUP_PATHS[$_group]+x}" ]]; then
                        value="${CDP_GROUP_PATHS[$_group]}/${value}"
                    else
                        CDP_DIE_EXIT=65 cdp_die "config:${lineno}: Path must be absolute: '${value}'"
                    fi
                fi
                if [[ -n "${CDP_PATHS[$_proj]+x}" ]]; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: multiple Path lines for project '${_proj}'"
                fi
                CDP_PATHS["$_proj"]="$value"
                ;;
            Macro)
                if [[ -z "$value" ]]; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: Macro requires a name"
                fi
                if ! [[ "$value" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: invalid macro name: '${value}'"
                fi
                if _cdp_is_reserved "$value"; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: macro name '${value}' is reserved"
                fi
                if [[ -n "$_proj" ]]; then
                    # Project-level macro (V1 path).
                    key="${_proj}"$'\x1f'"${value}"
                    if [[ "${CDP_ACTIONS[$key]:-}" == "tmux" ]]; then
                        CDP_DIE_EXIT=65 cdp_die "config:${lineno}: name '${value}' already used as Tmux in project '${_proj}'"
                    fi
                    if [[ -n "${CDP_MACROS[$key]+x}" ]]; then
                        CDP_DIE_EXIT=65 cdp_die "config:${lineno}: duplicate macro name '${value}' in project '${_proj}'"
                    fi
                    _macro="$value"
                    _tmux=""
                    _pane=""
                    CDP_MACROS["$key"]=1
                    CDP_ACTIONS["$key"]="macro"
                    CDP_ACTION_ORDER+=("$key")
                    arr_name="CDP_RUNS_${_proj//-/_}_${_macro//-/_}"
                    # Eval is required because the array name is dynamic.
                    # shellcheck disable=SC2294
                    eval "declare -ga ${arr_name}=()"
                elif [[ -n "$_group" ]]; then
                    # Group-level macro (V1.4 inheritance — applies to every
                    # member project unless that project shadows the name).
                    gkey="${_group}"$'\x1f'"${value}"
                    if [[ -n "${CDP_GROUP_MACROS[$gkey]+x}" ]]; then
                        CDP_DIE_EXIT=65 cdp_die "config:${lineno}: duplicate macro name '${value}' in group '${_group}'"
                    fi
                    _macro="$value"
                    _tmux=""
                    _pane=""
                    CDP_GROUP_MACROS["$gkey"]=1
                    arr_name="CDP_GROUP_RUNS_${_group//-/_}_${_macro//-/_}"
                    # shellcheck disable=SC2294
                    eval "declare -ga ${arr_name}=()"
                else
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: Macro outside Project or Group block"
                fi
                ;;
            Tmux)
                if [[ -z "$_proj" ]]; then
                    if [[ -n "$_group" ]]; then
                        CDP_DIE_EXIT=65 cdp_die "config:${lineno}: Tmux inside Group block"
                    fi
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: Tmux outside Project block"
                fi
                if [[ -z "$value" ]]; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: Tmux requires a name"
                fi
                if ! [[ "$value" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: invalid tmux name: '${value}'"
                fi
                if _cdp_is_reserved "$value"; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: tmux name '${value}' is reserved"
                fi
                key="${_proj}"$'\x1f'"${value}"
                if [[ "${CDP_ACTIONS[$key]:-}" == "macro" ]]; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: name '${value}' already used as Macro in project '${_proj}'"
                fi
                if [[ "${CDP_ACTIONS[$key]:-}" == "tmux" ]]; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: duplicate tmux name '${value}' in project '${_proj}'"
                fi
                _tmux="$value"
                _macro=""
                _pane=""
                CDP_ACTIONS["$key"]="tmux"
                CDP_ACTION_ORDER+=("$key")
                ;;
            Layout)
                if [[ -z "$_tmux" ]]; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: Layout outside Tmux block"
                fi
                if [[ -z "$value" ]]; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: Layout requires a value"
                fi
                key="${_proj}"$'\x1f'"${_tmux}"
                if [[ -n "${CDP_TMUX_LAYOUTS[$key]+x}" ]]; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: multiple Layout lines for tmux '${_tmux}' of project '${_proj}'"
                fi
                CDP_TMUX_LAYOUTS["$key"]="$value"
                CDP_TMUX_LAYOUT_LINENOS["$key"]="$lineno"
                _pane=""
                ;;
            Pane)
                if [[ -z "$_tmux" ]]; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: Pane outside Tmux block"
                fi
                if [[ -z "$value" ]]; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: Pane requires a name"
                fi
                if ! [[ "$value" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: invalid pane name: '${value}'"
                fi
                if _cdp_is_reserved "$value"; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: pane name '${value}' is reserved"
                fi
                key="${_proj}"$'\x1f'"${_tmux}"$'\x1f'"${value}"
                if [[ -n "${CDP_TMUX_PANES[$key]+x}" ]]; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: duplicate pane name '${value}' in tmux '${_tmux}' of project '${_proj}'"
                fi
                _pane="$value"
                _macro=""
                CDP_TMUX_PANES["$key"]=1
                CDP_TMUX_PANE_LINENOS["$key"]="$lineno"
                arr_name="CDP_TMUX_PANE_RUNS_${_proj//-/_}_${_tmux//-/_}_${_pane//-/_}"
                # shellcheck disable=SC2294
                eval "declare -ga ${arr_name}=()"
                ;;
            Run)
                if [[ -z "$value" ]]; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: empty Run line"
                fi
                if [[ -n "$_pane" && -n "$_macro" ]]; then
                    # Cannot happen given the state-machine transitions; if it
                    # does, it's a parser-internal bug, not user input.
                    CDP_DIE_EXIT=70 cdp_die "config:${lineno}: parser invariant: both _macro and _pane set"
                fi
                if [[ -n "$_pane" ]]; then
                    arr_name="CDP_TMUX_PANE_RUNS_${_proj//-/_}_${_tmux//-/_}_${_pane//-/_}"
                elif [[ -n "$_macro" ]]; then
                    if [[ -n "$_proj" ]]; then
                        arr_name="CDP_RUNS_${_proj//-/_}_${_macro//-/_}"
                    elif [[ -n "$_group" ]]; then
                        arr_name="CDP_GROUP_RUNS_${_group//-/_}_${_macro//-/_}"
                    else
                        # Unreachable: _macro is only set after a Macro line,
                        # which itself requires _proj or _group.
                        CDP_DIE_EXIT=70 cdp_die "config:${lineno}: parser invariant: _macro set without _proj or _group"
                    fi
                else
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: Run outside Macro or Pane block"
                fi
                # shellcheck disable=SC2294
                eval "${arr_name}+=(\"\$value\")"
                ;;
            *)
                CDP_DIE_EXIT=65 cdp_die "config:${lineno}: unknown keyword: '${first}'"
                ;;
        esac
    done < "$file"

    # Restore nocasematch state.
    if [[ $_had_nocase -eq 0 ]]; then
        shopt -u nocasematch
    fi

    # Validate every project has a Path. A group member with no Path of its
    # own resolves to the group's root path (V1.5).
    local label grp
    for label in "${!CDP_PROJECTS[@]}"; do
        if [[ -z "${CDP_PATHS[$label]+x}" ]]; then
            grp="${CDP_PROJECT_GROUP[$label]:-}"
            if [[ -n "$grp" && -n "${CDP_GROUP_PATHS[$grp]+x}" ]]; then
                CDP_PATHS["$label"]="${CDP_GROUP_PATHS[$grp]}"
            else
                CDP_DIE_EXIT=65 cdp_die "config: project '${label}' has no Path"
            fi
        fi
    done

    _cdp_validate_tmux_blocks
}

# Post-loop structural validation for V1.1 Tmux blocks. Pulled out of
# cdp_config_parse only to keep the read loop readable.
_cdp_validate_tmux_blocks() {
    local action_key proj tmux_name layout layout_lineno
    local pane_key pane_name pane_lineno arr_name run_count
    local -A pane_referenced=()

    for action_key in "${!CDP_ACTIONS[@]}"; do
        [[ "${CDP_ACTIONS[$action_key]}" == "tmux" ]] || continue
        proj="${action_key%%$'\x1f'*}"
        tmux_name="${action_key#*$'\x1f'}"

        # Every Tmux block needs a Layout.
        if [[ -z "${CDP_TMUX_LAYOUTS[$action_key]+x}" ]]; then
            CDP_DIE_EXIT=65 cdp_die "config: tmux '${tmux_name}' of project '${proj}' has no Layout"
        fi
        layout="${CDP_TMUX_LAYOUTS[$action_key]}"
        layout_lineno="${CDP_TMUX_LAYOUT_LINENOS[$action_key]}"

        # Every Tmux block needs at least one Pane.
        local -a panes_in_block=()
        for pane_key in "${!CDP_TMUX_PANES[@]}"; do
            [[ "$pane_key" == "${action_key}"$'\x1f'* ]] || continue
            panes_in_block+=("${pane_key##*$'\x1f'}")
        done
        if (( ${#panes_in_block[@]} == 0 )); then
            CDP_DIE_EXIT=65 cdp_die "config: tmux '${tmux_name}' of project '${proj}' has no Pane"
        fi

        # Each Pane must have at least one Run.
        for pane_name in "${panes_in_block[@]}"; do
            arr_name="CDP_TMUX_PANE_RUNS_${proj//-/_}_${tmux_name//-/_}_${pane_name//-/_}"
            eval "run_count=\${#${arr_name}[@]}"
            if (( run_count == 0 )); then
                pane_lineno="${CDP_TMUX_PANE_LINENOS[${action_key}$'\x1f'${pane_name}]}"
                CDP_DIE_EXIT=65 cdp_die "config:${pane_lineno}: pane '${pane_name}' in tmux '${tmux_name}' of project '${proj}' has no Run"
            fi
        done

        # Layout DSL parse + cross-validation. cdp_tmux_layout_parse dies on
        # error; we first run it in a subshell to detect failure (and grab
        # the message for context-wrapping), then re-run in the current shell
        # to populate CDP_TMUX_LAYOUT_PANES / OPS for the caller.
        local stderr_capture
        if ! stderr_capture="$( (cdp_tmux_layout_parse "$layout") 2>&1 1>/dev/null )"; then
            local detail="${stderr_capture#cdp: }"
            if [[ "$detail" == "layout malformed: "* ]]; then
                CDP_DIE_EXIT=65 cdp_die "config:${layout_lineno}: layout for tmux '${tmux_name}' of project '${proj}' is malformed: ${detail#layout malformed: }"
            else
                CDP_DIE_EXIT=65 cdp_die "config:${layout_lineno}: ${detail}"
            fi
        fi
        cdp_tmux_layout_parse "$layout"
        # cdp_tmux_layout_parse populated CDP_TMUX_LAYOUT_PANES and OPS;
        # we only need the pane-name set here.
        pane_referenced=()
        local p
        for p in "${CDP_TMUX_LAYOUT_PANES[@]}"; do
            pane_referenced["$p"]=1
        done

        # Every layout reference must be a defined Pane.
        for p in "${!pane_referenced[@]}"; do
            if [[ -z "${CDP_TMUX_PANES[${action_key}$'\x1f'${p}]+x}" ]]; then
                CDP_DIE_EXIT=65 cdp_die "config:${layout_lineno}: layout references undefined pane '${p}' in tmux '${tmux_name}' of project '${proj}'"
            fi
        done

        # Every defined Pane must be referenced by the layout.
        for pane_name in "${panes_in_block[@]}"; do
            if [[ -z "${pane_referenced[$pane_name]+x}" ]]; then
                pane_lineno="${CDP_TMUX_PANE_LINENOS[${action_key}$'\x1f'${pane_name}]}"
                CDP_DIE_EXIT=65 cdp_die "config:${pane_lineno}: pane '${pane_name}' defined but not referenced in layout"
            fi
        done
    done
}
