# Contributing to cdp

## Quickstart

```bash
git clone https://github.com/mihai-valentin/cdp.git
cd cdp
make check       # lint + tests
```

`make check` runs `shellcheck --severity=style` over every shell script and the bats test suite under `tests/`. Both `shellcheck` and `bats-core` must be on `$PATH`.

## Code style

- Bash 4+; no pure-POSIX-sh constraint. The shell shim emitted by `cdp init` works in both bash and zsh; everything else assumes `#!/usr/bin/env bash`.
- `set -euo pipefail` at the top of every script.
- `shellcheck --severity=style` clean.
- Modular layout:
  - `bin/cdp` — thin dispatcher (the only piece sourceable into a user's shell).
  - `libexec/cdp-*` — per-subcommand scripts, invoked as subprocesses.
  - `lib/*.sh` — sourced helpers. Sourced libs do **not** set shell options on the caller.
- No third-party runtime dependencies — bash, coreutils, and `flock` from util-linux. Dev-only tools (`shellcheck`, `bats-core`) are fine.
- User-facing output goes to stderr unless it is the resolved path or a parseable plan line on stdout (the shell shim parses stdout).

## Testing

Tests live under `tests/` and use [bats-core](https://github.com/bats-core/bats-core). New behavior must come with a test. Tests are hermetic — `setup()` exports `CDP_CONFIG=$BATS_TEST_TMPDIR/cdp-config` so no test ever touches the user's real registry.

```bash
make test          # runs bats tests/
bats tests/foo.bats  # run one file
```

## Commits

Conventional Commits: `feat:`, `fix:`, `docs:`, `test:`, `chore:`, `refactor:`. Example:

```
feat(resolve): emit CDP_RUN for each macro Run line in source order
```

## Issues / PRs

For V1, please open a GitHub issue with reproduction steps before sending a PR for non-trivial work. The CLI surface is intentionally small; new subcommands (tmux layouts, fzf picker, completion plugins, `cdp edit`, `cdp which`, importers) are tracked as V2 candidates.
