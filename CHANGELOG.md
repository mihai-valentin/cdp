# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[1.1.2]: https://github.com/mihai-valentin/cdp/releases/tag/v1.1.2
[1.1.1]: https://github.com/mihai-valentin/cdp/releases/tag/v1.1.1
[1.1.0]: https://github.com/mihai-valentin/cdp/releases/tag/v1.1.0
[1.0.2]: https://github.com/mihai-valentin/cdp/releases/tag/v1.0.2
[1.0.1]: https://github.com/mihai-valentin/cdp/releases/tag/v1.0.1
[1.0.0]: https://github.com/mihai-valentin/cdp/releases/tag/v1.0.0
