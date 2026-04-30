# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Config-file format specification (`docs/specs/config-format.md`).
- Resolution semantics + shell-shim protocol specification (`docs/specs/resolve-semantics.md`).
- Repo skeleton: `Makefile`, `install.sh`, `LICENSE` (MIT), `.editorconfig`, `.gitignore`, `.shellcheckrc`, GitHub Actions CI workflow.
- Config parser (`lib/config.sh`) with shared logging helpers (`lib/log.sh`).
- Resolver and shell shim: `bin/cdp`, `libexec/cdp-resolve`, `libexec/cdp-init`, `libexec/cdp-help`.
- Subcommands: `cdp add`, `cdp rm`, `cdp ls` — flock-guarded writes, atomic temp-file rename, scriptable TAB-separated `ls` output.
- bats-core test suite under `tests/` covering parser, resolver, and subcommands.
- README, CONTRIBUTING, and this changelog.
- `install.sh` PREFIX probing (picks `$HOME/.local` or `/usr/local` from `PATH`).
- GitHub Actions release workflow: `git push --tags` of a `v*` tag publishes a tarball + SHA-256 checksum to GitHub Releases.
