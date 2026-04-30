#!/usr/bin/env bash
# lib/config.sh — cdp config-file parser.
# Tested by tests/config_parse.bats.
#
# Sourced (not executed). Populates four global arrays in the caller's scope:
#   CDP_PROJECTS  (assoc): label -> 1
#   CDP_PATHS     (assoc): label -> absolute path
#   CDP_MACROS    (assoc): "label\x1fmacro" -> 1
#   CDP_RUNS_<label>_<macro> (indexed): Run command lines, in source order.
#     Hyphens in identifiers are mapped to underscores for the array-name
#     portion only (bash identifiers cannot contain hyphens).

[[ -n "${_CDP_CONFIG_SH:-}" ]] && return 0
_CDP_CONFIG_SH=1

# log helpers (cdp_die, cdp_warn).
if [[ -z "${_CDP_LOG_SH:-}" ]]; then
    # shellcheck source=lib/log.sh
    source "${BASH_SOURCE[0]%/*}/log.sh"
fi

# Reserved subcommand list — labels and macro names that are forbidden.
_cdp_is_reserved() {
    case "$1" in
        add|rm|ls|init|help|version|--help|--version|-h|-v) return 0 ;;
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

    # Save and enable nocasematch for keyword case-insensitivity.
    local _had_nocase=0
    shopt -q nocasematch && _had_nocase=1
    shopt -s nocasematch

    local lineno=0
    local _proj="" _macro=""
    local line line_trimmed first value arr_name key

    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"
        # Trim leading whitespace.
        line_trimmed="${line#"${line%%[![:space:]]*}"}"

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
            Project)
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
                CDP_PROJECTS["$_proj"]=1
                ;;
            Path)
                if [[ -z "$_proj" ]]; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: Path outside Project block"
                fi
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
                if [[ "$value" != /* ]]; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: Path must be absolute: '${value}'"
                fi
                if [[ -n "${CDP_PATHS[$_proj]+x}" ]]; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: multiple Path lines for project '${_proj}'"
                fi
                CDP_PATHS["$_proj"]="$value"
                ;;
            Macro)
                if [[ -z "$_proj" ]]; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: Macro outside Project block"
                fi
                if [[ -z "$value" ]]; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: Macro requires a name"
                fi
                if ! [[ "$value" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: invalid macro name: '${value}'"
                fi
                if _cdp_is_reserved "$value"; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: macro name '${value}' is reserved"
                fi
                key="${_proj}"$'\x1f'"${value}"
                if [[ -n "${CDP_MACROS[$key]+x}" ]]; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: duplicate macro name '${value}' in project '${_proj}'"
                fi
                _macro="$value"
                CDP_MACROS["$key"]=1
                arr_name="CDP_RUNS_${_proj//-/_}_${_macro//-/_}"
                # Eval is required because the array name is dynamic.
                # shellcheck disable=SC2294
                eval "declare -ga ${arr_name}=()"
                ;;
            Run)
                if [[ -z "$_macro" ]]; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: Run outside Macro block"
                fi
                if [[ -z "$value" ]]; then
                    CDP_DIE_EXIT=65 cdp_die "config:${lineno}: empty Run line"
                fi
                arr_name="CDP_RUNS_${_proj//-/_}_${_macro//-/_}"
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

    # Validate every project has a Path.
    local label
    for label in "${!CDP_PROJECTS[@]}"; do
        if [[ -z "${CDP_PATHS[$label]+x}" ]]; then
            CDP_DIE_EXIT=65 cdp_die "config: project '${label}' has no Path"
        fi
    done
}
