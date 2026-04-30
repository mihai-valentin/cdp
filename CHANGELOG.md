# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[1.0.0]: https://github.com/mihai-valentin/cdp/releases/tag/v1.0.0
