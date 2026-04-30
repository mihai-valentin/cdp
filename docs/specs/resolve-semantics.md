# cdp — Resolution Semantics + Shell-Shim Protocol (V1)

This document is the canonical specification of how `cdp` translates a CLI invocation into a `cd` (and optionally a sequence of post-`cd` commands), and of the protocol between the `cdp` binary and the shell shim function that performs the actual `cd`.

## 1. Why a shim is necessary

A Unix process cannot change the working directory of its parent. When you run a regular binary, it inherits the parent shell's cwd, may `chdir(2)` internally, and on exit the parent shell is unaffected. That is correct OS behavior. It is also why every "smart cd" tool (`zoxide`, `autojump`, `fasd`, `cdp`) ships a tiny shell function that the user **sources** into their interactive shell. The function is the only piece that runs in the parent shell's process and is therefore allowed to mutate its cwd.

`cdp` follows this pattern. The binary's job is to compute the destination path (and, for macros, the list of post-`cd` commands) and emit it to stdout in a parseable plan format. The shim function reads that plan, calls the shell builtin `cd`, and `eval`s any post-`cd` lines so they inherit the new cwd.

## 2. CLI dispatch by argument arity

The reserved subcommand list is:

```
add  rm  ls  init  help  --help  -h  version  --version  -v
```

Note that `help` and `version` (without dashes) are also recognized as aliases of `--help` and `--version`.

### 2.1 Zero arguments

```
cdp
```

Print the help text on stdout and exit `0`.

### 2.2 One argument

```
cdp <a>
```

- If `<a>` is a reserved subcommand, dispatch to `libexec/cdp-<a>` (translating `--help`/`-h` → `cdp-help`, `--version`/`-v` → the version branch).
- Otherwise, treat `<a>` as a project label and invoke the resolver with `<a>` only — bare-jump mode.

### 2.3 Two arguments

```
cdp <a> <b>
```

- If `<a>` is a reserved subcommand that takes one or more arguments (`add` takes two; `rm` takes one; `init` takes one; `ls` takes none), dispatch to `libexec/cdp-<a>` with `<b>...` as its arguments. Subcommand-specific arity is enforced inside each subcommand script.
- Otherwise, `<a>` is a project label and `<b>` is a macro name. The resolver looks up `<a>` and verifies `<b>` is one of its macros.

### 2.4 Three or more arguments

```
cdp <a> <b> <c> ...
```

Only valid when `<a>` is a subcommand whose own arity accepts more arguments (`cdp add foo /tmp` is the canonical case). Otherwise: `cdp: too many arguments` on stderr, exit `64` (`EX_USAGE`).

## 3. Resolver stdout/stderr contract

The resolver (`libexec/cdp-resolve`) is the only piece whose stdout is **parsed by another program** (the shim). Every other binary in `cdp` writes its stdout for human consumption. Keeping the contract one-way and explicit avoids the ambiguity that bites every shell-tool integration.

- **Success, bare jump.** Stdout: a single line `CDP_CD <abspath>` followed by a newline. Stderr: silent. Exit: `0`.
- **Success, jump + macro.** Stdout: the first line is `CDP_CD <abspath>`; subsequent lines are each `CDP_RUN <command>` in source order. Stderr: silent. Exit: `0`.
- **Any error.** Stdout: empty. Stderr: a single line `cdp: <message>`. Exit: a non-zero code per §6.

The `CDP_` prefix on every plan line is reserved for protocol use. Future versions may add new prefixes (e.g. `CDP_LAYOUT` for tmux integration in V2). Lines without a recognized prefix are a malformed plan and the shim must abort with a clear error.

## 4. Plan format (v1)

The plan format the resolver emits to stdout is a sequence of newline-terminated lines, each carrying one of the following prefixes:

| Prefix | Body | Semantics |
|---|---|---|
| `CDP_CD ` | absolute path | The shim must `cd` into this path. There is exactly one `CDP_CD` line, and it is always the first line. |
| `CDP_RUN ` | shell command | The shim must `eval` this command in the current shell after the `cd`. Zero-or-more `CDP_RUN` lines may follow the `CDP_CD` line, in execution order. |

The space after the prefix is part of the prefix; the body begins at the next byte. The body is taken verbatim from the path or `Run` value in the config — no quoting or escaping is performed by the resolver, and none is undone by the shim.

If the body contains a literal newline, the plan is malformed. (Path values cannot contain newlines because the config file is line-oriented, and `Run` values are explicitly trimmed of trailing whitespace and not multi-line.)

## 5. Shell shim source

`cdp init bash` and `cdp init zsh` emit the shim function source for the user to `eval` into their shell. **In V1 the shim is identical for bash and zsh** — both shells accept the same function syntax for our needs. The `bash | zsh` argument is reserved for forward compatibility (e.g. when V2 fish support arrives, or when zsh-only features get added).

The emitted shim has the absolute path to **`bin/cdp`** baked in at `cdp init` time, so the user does not need to add anything to `PATH`. The shim has two paths:

- **Subcommand passthrough** — for `cdp` (no args), `cdp help / --help / -h`, `cdp version / --version / -v`, `cdp add`, `cdp rm`, `cdp ls`, `cdp init`. The shim invokes `bin/cdp` directly with stdout connected to the terminal so the user sees usage text, listings, and the shim source for `init` exactly as the binary writes them.
- **Plan protocol** — for everything else (`cdp <label>` and `cdp <label> <macro>`). The shim captures `bin/cdp`'s stdout, parses each line as `CDP_CD <path>` or `CDP_RUN <command>`, and applies them to the user's interactive shell.

The literal shim source emitted (with `${_CDP_BIN}` substituted at emit time):

```bash
cdp() {
    case "${1:-}" in
        ''|help|--help|-h|version|--version|-v|add|rm|ls|init)
            command '${_CDP_BIN}' "$@"
            return $?
            ;;
    esac
    local plan rc line
    plan="$(command '${_CDP_BIN}' "$@")"
    rc=$?
    if [[ $rc -ne 0 ]]; then
        return $rc
    fi
    while IFS= read -r line; do
        case "$line" in
            'CDP_CD '*)
                cd "${line#CDP_CD }" || return $?
                ;;
            'CDP_RUN '*)
                eval "${line#CDP_RUN }" || return $?
                ;;
            '')
                ;;
            *)
                printf 'cdp: malformed plan line: %s\n' "$line" >&2
                return 70
                ;;
        esac
    done <<<"$plan"
}
```

Notes:

- `command '<path>'` ensures the binary at the absolute path is invoked, never the function (which would recurse).
- `eval` for `CDP_RUN` is intentional, not a child-shell. A macro that exports an environment variable (`export FOO=bar`) is expected to affect the user's interactive shell. This is a deliberate design choice — macros are **not** sandboxed; they are user-authored shortcuts that should behave as if typed at the prompt.
- The shim aborts the macro on the first non-zero exit (`|| return $?` after each `cd` and `eval`). This is V1 default; a future flag may relax it.
- The shim does **not** capture stderr — errors from the binary print to the user's terminal directly.
- The reserved-subcommand list in the shim's `case` statement must match the dispatcher in `bin/cdp`. When V2 adds a subcommand, both get updated and users re-run `eval "$(cdp init bash)"` to pick up the new shim.

## 6. Exit codes

| Code | Meaning |
|---|---|
| `0` | Success. |
| `1` | Unknown label, unknown macro, or runtime check failed (e.g. project path does not exist). |
| `2` | Config file missing or unreadable. |
| `64` (`EX_USAGE`) | Bad CLI invocation: too many args, unknown init flavor, malformed `add` arguments. |
| `65` (`EX_DATAERR`) | Config parse error (delegated from `lib/config.sh`). |
| `70` | Shim received a malformed plan line — should not happen in normal operation; indicates a resolver bug. |

The shim propagates the resolver's exit code unchanged.

## 7. Verbatim runtime error messages

| # | Trigger | stderr message | Exit |
|---|---|---|---|
| 1 | First arg is neither a known label nor a known subcommand | `cdp: unknown label or subcommand: <a>` | `1` |
| 2 | First arg is a label, second is not one of its macros | `cdp: '<b>' is not a macro of project '<a>'` | `1` |
| 3 | Resolver cannot find a config file | `cdp: config file not found at <path>` | `2` |
| 4 | More positional arguments than the dispatch can accept | `cdp: too many arguments` | `64` |
| 5 | `cdp init` called with no/wrong flavor argument | `cdp: 'init' takes one argument: bash \| zsh` | `64` |
| 6 | Resolved project path doesn't exist on disk at jump time | `cdp: project path does not exist: <path>` | `1` |

Error 6 is performed by the resolver after it has the path but **before** it prints the `CDP_CD` line. Failing loudly is preferable to `cd`'ing the user's shell to a nonexistent directory. Users who want the bare-jump even when the path may be missing can `cd` manually.

## 8. Config-file discovery

The resolver searches for a config file in this order, taking the first hit:

1. `$CDP_CONFIG`, if set and non-empty. Use this in tests and in scripted invocations.
2. `$XDG_CONFIG_HOME/cdp/config`, if `XDG_CONFIG_HOME` is set and non-empty.
3. `$HOME/.config/cdp/config`.

If none of (1)/(2) apply and (3) does not exist, the resolver prints `cdp: config file not found at $HOME/.config/cdp/config` to stderr and exits `2`. The path mentioned in the message is the path the user is most likely meant to create — option (3) — even if `XDG_CONFIG_HOME` is set, because users running into this for the first time are usually not running with an exotic XDG setup.

## 9. Worked end-to-end traces

### Trace 1 — Bare jump

Config file `/tmp/cfg`:
```text
Project myproject
    Path /home/user/myproject
```

Invocation:
```
$ CDP_CONFIG=/tmp/cfg cdp myproject
```

Resolver stdout:
```
CDP_CD /home/user/myproject
```

Shim consumes it, `cd /home/user/myproject`, exit `0`.

### Trace 2 — Jump + macro

Config file `/tmp/cfg`:
```text
Project myproject
    Path /home/user/myproject
    Macro deploy
        Run ./scripts/build.sh
        Run ./scripts/publish.sh
```

Invocation:
```
$ CDP_CONFIG=/tmp/cfg cdp myproject deploy
```

Resolver stdout:
```
CDP_CD /home/user/myproject
CDP_RUN ./scripts/build.sh
CDP_RUN ./scripts/publish.sh
```

Shim consumes the plan, `cd`s, then `eval`s each `Run` line in the post-`cd` shell.

### Trace 3 — Unknown label

```
$ CDP_CONFIG=/tmp/cfg cdp not-a-project
cdp: unknown label or subcommand: not-a-project
$ echo $?
1
```

Resolver stdout is empty.

### Trace 4 — `cdp init bash`

```
$ cdp init bash
cdp() {
    local plan rc line
    plan="$('/home/user/.local/libexec/cdp/cdp-resolve' "$@")"
    rc=$?
    if [[ $rc -ne 0 ]]; then
        return $rc
    fi
    while IFS= read -r line; do
        case "$line" in
            'CDP_CD '*)
                cd "${line#CDP_CD }" || return $?
                ;;
            'CDP_RUN '*)
                eval "${line#CDP_RUN }" || return $?
                ;;
            '')
                ;;
            *)
                printf 'cdp: malformed plan line: %s\n' "$line" >&2
                return 70
                ;;
        esac
    done <<<"$plan"
}
```

The `RESOLVE_PATH` is the absolute path to the installed `cdp-resolve`, computed at `cdp init` time. Exit `0`.

### Trace 5 — No-args help

```
$ cdp
Usage: cdp <label> [<macro>]
       cdp add <label> <path>
       cdp rm <label>
       cdp ls
       cdp init bash | zsh
       cdp --help | --version
$ echo $?
0
```

## 10. Open questions (deferred)

- **Macro abort-on-error vs continue-on-error.** V1 aborts the macro at the first non-zero exit (`|| return $?` after each `eval`). A future flag (`Macro foo (continue)` or a per-`Run` annotation) could relax this. Deferred.
- **`--dry-run` mode.** The shim could accept a `--dry-run` flag that prints the plan it would execute without `cd`'ing or `eval`'ing. Useful for debugging macros. Deferred to V2.
- **`fzf` picker on `cdp` with no args.** Deferred — V1 prints help on no args; V2 may launch a picker if `fzf` is installed and stdout is a TTY.
