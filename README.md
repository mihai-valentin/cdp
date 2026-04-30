# cdp — change-dir-project

[![CI](https://github.com/mihai-valentin/cdp/actions/workflows/ci.yml/badge.svg)](https://github.com/mihai-valentin/cdp/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Tiny bash CLI that replaces `cd /long/path/to/project` with `cdp <label>`. Per-project **macros** (defined in an SSH-style config file) let you bundle a jump with the commands you usually type after it: `cdp myproject deploy` jumps and runs the deploy steps.

```bash
# Jump to a project
cdp myproject

# Jump and run a macro defined for that project
cdp myproject deploy

# Add / list / remove projects
cdp add myproject /home/user/myproject
cdp ls
cdp rm myproject
```

No npm, no composer, no Go binary, no Python. Bash 4+, coreutils, and an `flock` from util-linux are all you need at runtime.

## Install

### From source (recommended)

```bash
git clone https://github.com/mihai-valentin/cdp.git
cd cdp
make install                       # installs to $HOME/.local
# Add this to your ~/.bashrc or ~/.zshrc:
eval "$(~/.local/bin/cdp init bash)"
```

`make install` puts `cdp` in `$PREFIX/bin`, scripts in `$PREFIX/libexec/cdp/`, and helper libs in `$PREFIX/lib/cdp/`. Override the prefix with `make install PREFIX=/usr/local`.

### Without `make`

```bash
./install.sh
```

`install.sh` probes your `PATH` and picks `$HOME/.local` or `/usr/local` accordingly. Override with `./install.sh --prefix=<path>`.

### From a release tarball

```bash
VERSION=1.0.0
curl -sLO https://github.com/mihai-valentin/cdp/releases/download/v${VERSION}/cdp-${VERSION}.tar.gz
curl -sLO https://github.com/mihai-valentin/cdp/releases/download/v${VERSION}/cdp-${VERSION}.tar.gz.sha256
sha256sum -c cdp-${VERSION}.tar.gz.sha256
tar -xzf cdp-${VERSION}.tar.gz
cd cdp-${VERSION} && ./install.sh
```

### Uninstall

```bash
make uninstall
```

## Usage

### Jump

```bash
cdp <label>
```

`cdp myproject` resolves the `myproject` project's `Path` and `cd`s your shell into it. The shim function emitted by `cdp init` performs the actual `cd` — a regular binary cannot mutate its parent's cwd.

### Jump + macro

```bash
cdp <label> <macro>
```

`cdp myproject deploy` jumps to `myproject` and then runs the `deploy` macro's `Run` lines, in order, **in your interactive shell**. Macros aren't sandboxed — `export FOO=bar` inside a macro affects your shell, by design.

### Manage projects

```bash
cdp add <label> <path>      # add an entry
cdp rm <label>              # remove an entry
cdp ls                      # list projects (TAB-separated)
```

`cdp ls` output is `LABEL\tPATH\tMACROS` — friendly to `awk`. Pipe to `column -t -s$'\t'` for a human-readable view. Macros are added by editing the config file directly; there is no `cdp add-macro` in V1.

### Shell shim

```bash
cdp init bash      # prints shim source for bash
cdp init zsh       # prints shim source for zsh (identical body in V1)
```

Source it once per interactive shell, typically by adding `eval "$(cdp init bash)"` to your `~/.bashrc` (or `~/.zshrc`).

## Config file

The config file lives at `$CDP_CONFIG`, or `$XDG_CONFIG_HOME/cdp/config`, or `$HOME/.config/cdp/config` — searched in that order.

```text
Project myproject
    Path /home/user/myproject
    Macro deploy
        Run cd ./static-pages
        Run ./scripts/publish.sh
    Macro logs
        Run tail -f /var/log/myproject.log

Project api
    Path /home/user/projects/api
    Macro dev
        Run pnpm install
        Run pnpm --filter web dev
```

The formal grammar lives in [`docs/specs/config-format.md`](docs/specs/config-format.md). Highlights: indentation-based blocks, case-insensitive keywords, `#` line comments only (no trailing comments), tilde expansion at parse time.

## Shell support

- **bash 4+** and **zsh** are tested daily.
- macOS ships bash 3.2 by default. Install a modern bash via Homebrew (`brew install bash`) or use zsh (the system default on recent macOS).
- fish and other shells are not supported in V1.

## Troubleshooting

**`cdp: command not found`** — the eval line isn't in your rc file, or your rc file isn't being read by your shell. Confirm with `type cdp`; if it returns "not found", add the eval line and start a fresh shell.

**`cdp: requires bash 4 or newer`** — you're on macOS's default bash 3.2. Install bash 4+ (`brew install bash`) and exec it as your shell, or switch to zsh.

**`cdp: config file not found at ...`** — the config file doesn't exist yet. Run `cdp add <label> <path>` to bootstrap it; the parent directory will be created automatically.

**`cdp myproject` runs but my cwd doesn't change** — your shell's `cdp` is being shadowed by an alias or another function. Run `type cdp`; if it shows an alias, `unalias cdp` and re-source your rc file.

## Status

v1.0.0 — first stable release. The roadmap and open items are tracked as GitHub issues; the formal grammar and protocol live under [`docs/specs/`](docs/specs/).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md).

## License

MIT — see [`LICENSE`](LICENSE).
