# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[1.0.1]: https://github.com/mihai-valentin/cdp/releases/tag/v1.0.1
[1.0.0]: https://github.com/mihai-valentin/cdp/releases/tag/v1.0.0
