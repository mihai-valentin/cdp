# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.6.0] - 2026-06-17

### Added

- `Path` line inside a `Group` block declares a **workspace root** for that group. Member projects are resolved against it: a **relative** member `Path` is joined onto the root (`Path cdp` under root `/home/user/xlnf` → `/home/user/xlnf/cdp`), an **absolute** member `Path` wins (escapes the root), and a member with **no** `Path` resolves to the root itself. The root is tilde-expanded and must be absolute; a trailing slash is normalized away. Composition happens at parse time, so `CDP_PATHS[<label>]` holds the final absolute path and the resolver / `cdp ls` are unchanged.
- New parser global `CDP_GROUP_PATHS` (assoc: group-name → absolute root). Populated only for groups that declare a `Path`.
- Tests: 11 new bats cases in `tests/group.bats` covering relative join, absolute-wins, no-Path-resolves-to-root, nested sub paths, trailing-slash normalization, tilde expansion, the no-root error cases (relative / omitted member Path still error), relative-root error, duplicate-group-Path error, and coexistence with inherited macros. Total bats coverage now 145.

### Changed

- A `Path` line directly under a `Group` is no longer a parse error (it sets the group root). The `Path inside Group block` error is removed; `Path` under a `Group` with a relative value now errors with `Group Path must be absolute: '<value>'`, and a second `Path` under one `Group` errors with `multiple Path lines for group '<group>'`.
- Spec: `docs/specs/config-format.md` gains §5.7 (group root `Path`), an updated §7 constraints list, §8 error-table rows, Example 10, and the deferred "Group-level `Workspace`" open question is moved to resolved.

## [1.5.0] - 2026-06-17

### Added

- `cdp add` now accepts zero, one, or two arguments. With **no args** it adds the current working directory; with a **single path** (`.`, a relative path, `~`, or an absolute path) it adds that directory. In both cases the project label defaults to the directory's basename, so the everyday case is just `cdp add` from inside the project. The explicit two-arg form `cdp add <label> <path>` is unchanged.
- Path canonicalization: the path argument is now resolved to an absolute path via `cd … && pwd` (logical pwd, preserving the user's symlinked view) before being written, so `.` and relative paths are accepted everywhere — not just absolute paths. The prior "path must be absolute" error is gone.
- When a label is derived from a directory whose basename is not a valid label (e.g. it contains a `.`), `cdp add` fails with a hint to pass an explicit label: `cdp add <label> <path>`.

### Changed

- `cdp add` usage text broadened to `cdp add [<label>] [<path>]` in `cdp --help` and the arg-count guard now rejects only 3+ args (was: exactly 2 required).

## [1.4.0] - 2026-05-11

### Added

- `Group <label>` block in the config grammar — wraps a set of nested `Project` blocks and declares `Macro`s that are inherited by every member project at action-lookup time. A project's own same-named `Macro` shadows the inherited one; the resolver tries the per-project `CDP_ACTIONS` map first, then falls back to `CDP_GROUP_MACROS[<group>\x1f<name>]` only when no project-local action by that name exists. Hits never cross groups: a project belongs to **exactly one** group, determined by lexical nesting (no `In <group>` declaration in V1.4 — multi-group membership is deferred). Group-level macros run with the same `CDP_CD <project-path>` + `CDP_RUN <line>` plan format as project-level macros, so the shim, `eval`-into-shell semantics, and abort-on-first-error rules all carry over unchanged.
- `Group` is **macro-only**: `Path`, `Tmux`, and nested `Group` lines inside a `Group` block are parse errors (`Path inside Group block`, `Tmux inside Group block`, `nested Group not allowed`). Path-prefix support (a `Workspace <abspath>` declaration on the `Group` so members can use relative `Path`s) and group-level `Tmux` blocks are explicitly deferred to V1.5+.
- Indentation tracking in `lib/config.sh`: the parser now records each line's leading-whitespace byte count and stores it on the open `Group` so it can detect (a) a deeper-indented Project as a member of the group, (b) a shallower-or-equal-indented Project as the group's terminator, and (c) a deeper-indented Group as illegal nesting. A `Project` line at column 0 still parses as an ungrouped top-level project, so legacy configs without `Group` blocks parse byte-identically to V1.3.x.
- `cdp ls` annotates inherited entries in the `ACTIONS` column with a trailing `@<group>` suffix (e.g. `claude:macro@xlnf`). Project-local actions keep the plain `:macro` / `:tmux` suffix; shadowed group entries are suppressed (no double-listing under the project they're shadowed from). The TAB-separated three-column layout is unchanged so existing `awk` consumers keep working.
- New globals populated by the parser for downstream consumers: `CDP_GROUPS` (assoc: group-name → 1), `CDP_PROJECT_GROUP` (assoc: project-label → group-name, only for grouped projects), `CDP_GROUP_MACROS` (assoc: `group\x1fmacro` → 1), and `CDP_GROUP_RUNS_<group>_<macro>` (indexed: Run lines, source order). Hyphens in identifiers are mapped to underscores for the array-name portion only, matching the existing convention for `CDP_RUNS_*` and `CDP_TMUX_PANE_RUNS_*`.
- Tests: 20 new bats cases in `tests/group.bats` covering parsing (Group label syntax, duplicates, reserved-name collision, bare `Group` keyword, empty Group, Group-only / Project-only / mixed configs), forbidden constructs (`Path` / `Tmux` inside Group, nested Group, duplicate Macro within a Group), inheritance semantics (single-member, multi-member, multi-Run macro), override (project-local shadows group), negative cases (ungrouped Project does NOT see Group macros; `Macro outside Project or Group block`), `cdp ls` annotation (suffix appears for inherited, suppressed for shadowed, absent for ungrouped), and coexistence with `Tmux` blocks inside a grouped Project. Total bats coverage now 129 (up from 109).

### Changed

- `Macro` keyword's "outside" error message broadened from `Macro outside Project block` to `Macro outside Project or Group block` to reflect that V1.4 accepts `Macro` directly under `Group` as well as under `Project`. Existing tests asserting the legacy substring still pass because the new message is a superset.

## [1.3.0] - 2026-05-05

### Added

- `cdp check` subcommand. Parses the resolved config file via the existing `cdp_config_load_or_die` path and reports validity. Exit `0` with a brief `cdp: config OK: <path> (<n> project[s])` line on stderr; exit `2` if the config file is missing or unreadable; exit `65` on parse error (the parser owns the `config:<line>: <message>` text). stdout stays silent on success so the command composes naturally as a precondition: `cdp check && cdp <label>`. Pairs with `cdp edit` for an edit-then-validate loop. Like `edit`, `check` is fast-pathed in the shim emitted by `cdp init` (alongside `add | rm | ls | init | edit | help | version`) so it bypasses the plan-pipeline `$(…)` capture used for jump and macro/tmux dispatch.
- Reserved-name list extended with `check` in both the parser (`lib/config.sh::_cdp_is_reserved`) and `cdp add` so the new subcommand cannot collide with a project / macro / tmux / pane label.
- Tests: 9 new bats cases in `tests/subcommands.bats` (empty-config OK, multi-project count, singular-vs-plural noun, stdout/stderr split, missing-config exit-2, parse-error exit-65, relative-path exit-65, arg-count guard, reserved-label guard at both `cdp add` and parser layers) and 1 regression test in `tests/resolve.bats` asserting `check` is in the shim's fast-path case.

## [1.2.0] - 2026-05-02

### Added

- `cdp edit` subcommand. Opens the resolved config file in the user's editor — `$VISUAL` if set, else `$EDITOR`, else `vi`. The editor is `exec`'d so it inherits the shell's controlling TTY directly. If the config file does not yet exist, the parent directory is created (`mkdir -p`) so the editor opens at the resolved path; the file is materialized on save. The shell shim emitted by `cdp init` fast-paths `edit` alongside `add | rm | ls | init | help | version` so the editor's TTY is never captured by the plan-pipeline `$(…)` capture used for jump and macro/tmux dispatch.
- Reserved-name list extended with `edit` in both the parser (`lib/config.sh::_cdp_is_reserved`) and `cdp add` so the new subcommand cannot collide with a project / macro / tmux / pane label.
- Tests: 6 new bats cases in `tests/subcommands.bats` (env-var resolution order, parent-dir auto-create, arg-count guard, vi fallback, reserved-label guard) and 1 regression test in `tests/resolve.bats` asserting `edit` is in the shim's fast-path case.

## [1.1.2] - 2026-05-01

### Fixed

- v1.1.1's `/dev/tty` reconnect in the orchestrator surfaced a second tmux failure on WSL2: `open terminal failed: can't use /dev/tty`. WSL2 (and possibly other platforms with non-glibc tty layers) refuses tmux's later `/dev/tty` open when a parent process opened the same device first. The shim now preserves the user's real stdin fd via a block-level `{ … } 9<&0` redirection that scopes around the entire plan-dispatch loop, and the `CDP_TMUX_ATTACH` arm hands fd 9 to `cdp-tmux` via `<&9`. The orchestrator therefore never opens `/dev/tty` itself in the interactive path — tmux opens its own controlling terminal as it does in any normal `tmux attach` invocation. The `/dev/tty` fallback in `libexec/cdp-tmux` is retained as a best-effort path for direct (non-shim) invocations where stdin is non-TTY. Regression test in `tests/resolve.bats` asserts the emitted shim contains both `} 9<&0` and `<&9`. Spec updated at `docs/specs/resolve-semantics.md` §5.

## [1.1.1] - 2026-05-01

### Fixed

- `cdp <project> <tmux-name>` failed with `open terminal failed: not a terminal` whenever the shell shim invoked the orchestrator. The shim wraps its plan-line dispatch in `done <<<"$plan"`, which redirects stdin to a here-string for the entire loop body — including the `cdp-tmux` call that `exec`s `tmux attach`. Tmux refuses to attach without a tty on stdin. The orchestrator now reconnects to `/dev/tty` when its stdin is non-TTY (probed via subshell so contexts where `/dev/tty` exists as a node but cannot be opened — bats, headless CI — fall through cleanly without a redirect-failure exit). Regression test added in `tests/cdp_tmux.bats`.

## [1.1.0] - 2026-05-01

### Added

- Tmux integration. `Tmux <name>` blocks inside a `Project` declare a per-project pane layout via a `Layout` mini-DSL (`h:[…]` for side-by-side, `v:[…]` for stacked, arbitrary nesting) plus one `Pane <name>` sub-block per pane carrying `Run` lines to send via `tmux send-keys`. `cdp <label> <tmux-name>` materializes the layout (or attaches if the session already exists) and switches the user into it. New canonical specification at `docs/specs/tmux-layout.md` covering the EBNF grammar, BFS-by-slot walk algorithm, plan-line protocol, attach/switch-client policy, and exit codes.
- Layout DSL parser (`lib/tmux.sh`): pure-bash recursive-descent parser plus walk emitter. Validated by 24 bats cases covering happy paths (incl. the 2x2 grid that requires BFS-by-slot to produce the correct `[a, c, b, d]` walk order) and 12 error cases.
- Tmux orchestrator (`libexec/cdp-tmux`): checks `tmux` is on `$PATH`, short-circuits to `tmux attach` when the session already exists, otherwise creates the session detached, walks the layout to issue `tmux split-window` calls, sends each pane's commands, then `exec tmux attach` (or `tmux switch-client` if invoked from inside an existing tmux session).
- Shell-shim extension: the function emitted by `cdp init` accumulates `CDP_TMUX_SESSION`/`CDP_TMUX_LAYOUT`/`CDP_TMUX_PANE` plan lines and on `CDP_TMUX_ATTACH` hands off to `libexec/cdp-tmux` (absolute path baked in at install time).
- Resolver dispatch unified through a per-project `CDP_ACTIONS` map; `Macro` and `Tmux` block names cannot collide within one project (parse-time error). `cdp ls` now exposes both with `:macro`/`:tmux` suffixes.
- Bats coverage grew 34 → 90 (24 layout, 16 config-parse-tmux, 6 resolver, 10 orchestrator-against-stub-tmux, plus the V1 baseline).

### Changed

- `cdp ls` column header `MACROS` → `ACTIONS`. Each entry now carries a `:kind` suffix (`deploy:macro,dev:tmux`). The format is still TAB-separated and `awk`-friendly. Insertion order tracked via `CDP_ACTION_ORDER` so output mirrors config source order.
- Resolver's two-arg unknown-name message: `'<b>' is not a macro of project '<a>'` → `'<b>' is not a macro or tmux of project '<a>'`.
- `cdp --help` documents `cdp <label> <tmux-name>` and points to `docs/specs/tmux-layout.md`.
- `Run` keyword's "outside" error message: `Run outside Macro block` → `Run outside Macro or Pane block`.
- Install scripts (`Makefile` install target and `install.sh`) patch a fourth absolute path (`_CDP_TMUX`) into `libexec/cdp-init` and `libexec/cdp-tmux` alongside the existing `_CDP_LIBEXEC`/`_CDP_LIB`/`_CDP_BIN` patches.
- New exit code `3` reserved for tmux-not-installed and foreign-tmux-server cases. Macro/V1 exit codes (1, 2, 64, 65, 70) keep their meanings.

## [1.0.2] - 2026-05-01

### Fixed

- `install.sh` no longer requires GNU `make`. It previously shelled out to `make -C "$repo_root" install`, which contradicted the README's "Without `make`" install path. The script now performs the install natively (`mkdir`, `install -m`, and the same absolute-path `sed` patch the Makefile applies) and is byte-equivalent to `make install` in its output layout.

### Changed

- Post-install message (printed by both `make install` and `install.sh`) now lists every installed directory, explains *why* the shell shim is required (a child process cannot mutate its parent shell's cwd), gives both the `eval` snippet and a copy-paste `echo … >> ~/.bashrc` one-liner, and tells users how to activate (new shell or `source`) and verify (`type cdp` reports a function). The previous one-liner output left users guessing what to do with the eval line.

## [1.0.1] - 2026-04-30

### Fixed

- Installed binaries failed for every invocation other than `cdp <label> <macro>` because the shim invoked `libexec/cdp-resolve` directly while the libexec scripts self-located `lib/` via a `$0`-relative path that only worked in the dev tree (`$PREFIX/libexec/lib` does not exist post-install; the lib lives at `$PREFIX/lib/cdp/`). The shim now invokes `bin/cdp` (the dispatcher) so subcommands run with stdout connected to the terminal and label-jumps still go through the `CDP_CD`/`CDP_RUN` plan protocol; `make install` patches absolute `_CDP_LIB`/`_CDP_LIBEXEC`/`_CDP_BIN` paths into every entry-point script as a defense-in-depth measure for direct invocations.

## [1.0.0] - 2026-04-30

### Added

- CLI surface: `cdp <label>`, `cdp <label> <macro>`, `add`, `rm`, `ls`, `init bash | zsh`, `--help`, `--version`.
- SSH-style config-file format and parser (`lib/config.sh`); shared logging helpers (`lib/log.sh`).
- Resolver and shell shim: `bin/cdp`, `libexec/cdp-resolve`, `libexec/cdp-init`, `libexec/cdp-help`. The shim has the absolute path to `cdp-resolve` baked in at `cdp init` time, so users do not need to add `libexec/` to `PATH`.
- Config-mutating subcommands (`cdp add`, `cdp rm`) use `flock`-guarded writes with atomic temp-file-then-rename.
- `cdp ls` output is TAB-separated and `awk`-friendly; suppresses the header when stdout is not a TTY.
- bats-core test suite covering parser, resolver, and subcommands (including a parallel `flock`-stress test).
- Build / install plumbing: `Makefile` (`lint`, `test`, `check`, `install`, `uninstall`), `install.sh` with PATH-based PREFIX probing (`$HOME/.local` or `/usr/local`), MIT `LICENSE`, `.editorconfig`, `.shellcheckrc`.
- GitHub Actions CI workflow (`shellcheck` + bats on every push / PR).
- GitHub Actions release workflow: pushing a `v*` tag publishes a `cdp-<version>.tar.gz` plus SHA-256 sidecar to GitHub Releases.
- Formal specifications: `docs/specs/config-format.md` and `docs/specs/resolve-semantics.md`.

[1.4.0]: https://github.com/mihai-valentin/cdp/releases/tag/v1.4.0
[1.3.0]: https://github.com/mihai-valentin/cdp/releases/tag/v1.3.0
[1.2.0]: https://github.com/mihai-valentin/cdp/releases/tag/v1.2.0
[1.1.2]: https://github.com/mihai-valentin/cdp/releases/tag/v1.1.2
[1.1.1]: https://github.com/mihai-valentin/cdp/releases/tag/v1.1.1
[1.1.0]: https://github.com/mihai-valentin/cdp/releases/tag/v1.1.0
[1.0.2]: https://github.com/mihai-valentin/cdp/releases/tag/v1.0.2
[1.0.1]: https://github.com/mihai-valentin/cdp/releases/tag/v1.0.1
[1.0.0]: https://github.com/mihai-valentin/cdp/releases/tag/v1.0.0
