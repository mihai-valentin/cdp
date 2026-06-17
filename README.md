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

No npm, no composer, no Go binary, no Python. Bash 4+, coreutils, and an `flock` from util-linux are all you need at runtime. `tmux` is required only if you use [Tmux blocks](#tmux-integration); macros and bare jumps work without it.

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
VERSION=1.6.0
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
cdp edit                    # open the config in $VISUAL / $EDITOR
cdp check                   # parse the config and report validity
```

`cdp add` derives the project label from the directory's basename when you don't pass one, so the common case is just `cdp add` from inside the project. The path argument accepts `.`, a relative path, `~`, or an absolute path and is canonicalized to an absolute path before it's written. If the basename isn't a valid label (e.g. it contains a `.`), pass one explicitly: `cdp add <label> <path>`. Forms: `cdp add` (current dir), `cdp add <path>`, `cdp add <label> <path>`.

`cdp ls` output is `LABEL\tPATH\tACTIONS` — friendly to `awk`. Pipe to `column -t -s$'\t'` for a human-readable view. Each entry in `ACTIONS` is `<name>:<kind>` where `<kind>` is `macro` or `tmux`, in source order. Macros inherited from a `Group` (see below) carry a trailing `@<group>` suffix (e.g. `claude:macro@xlnf`). Macros and tmux blocks have no dedicated subcommand in V1 — use `cdp edit` (or any editor of your choice) to add or modify them.

`cdp edit` resolves the editor in the standard `$VISUAL` → `$EDITOR` → `vi` chain. If the config file does not yet exist, the parent directory is created so the editor opens at the resolved path; the file is materialized on save.

`cdp check` runs the parser over the resolved config and reports whether it is valid — exit `0` and a brief OK line on stderr on success, exit `2` if the file is missing or unreadable, exit `65` with the parser's `config:<line>: <message>` on a parse error. Pairs naturally with `cdp edit` for an edit-then-validate loop, and is safe to use as a precondition: `cdp check && cdp <label>`.

### Tmux integration

`cdp <label> <tmux-name>` materializes a per-project tmux pane layout (or attaches if the session already exists). Each `Tmux` block names its layout with a small DSL — `h:[…]` for side-by-side splits, `v:[…]` for stacked splits, with arbitrary nesting — and one `Pane <name>` block per pane carrying the commands to send.

```text
Project myapp
    Path /home/user/myapp
    Tmux dev
        Layout h:[main | v:[test | logs]]
        Pane main
            Run pnpm dev
        Pane test
            Run pnpm test --watch
        Pane logs
            Run tail -f var/log/app.log
```

Then `cdp myapp dev` builds the layout (one `main` pane on the left; `test` over `logs` on the right) and attaches you. If the `myapp-dev` tmux session already exists, the user's running panes are kept as-is and `cdp` just attaches.

Direction convention follows tmux: `h` = horizontal divider (panes side-by-side), `v` = vertical divider (panes stacked). The full grammar, walk semantics, and protocol live in [`docs/specs/tmux-layout.md`](docs/specs/tmux-layout.md).

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

### Groups (shared macros)

Wrap a set of related projects under a `Group` block to share `Macro`s across them. A group's macros are inherited by every nested project; a project's own macro of the same name **shadows** the inherited one.

```text
Group xlnf
    Macro claude
        Run ../xlnfclaude -c

    Project xlnf
        Path /home/user/xlnf
        Macro claude              # shadows the group's claude
            Run ./xlnfclaude -c

    Project cdp
        Path /home/user/xlnf/cdp
                                  # inherits claude from the group

    Project shawarma
        Path /home/user/xlnf/shawarma
                                  # inherits claude

Project nexus                     # column 0 — outside any group
    Path /home/user/nexus
    Macro claude
        Run claude -c
```

Then `cdp cdp claude` runs `../xlnfclaude -c` (inherited), `cdp xlnf claude` runs `./xlnfclaude -c` (override), and `cdp nexus claude` runs `claude -c` (no group affiliation). `cdp ls` shows the inheritance:

```
cdp     /home/user/xlnf/cdp     claude:macro@xlnf
nexus   /home/user/nexus        claude:macro
xlnf    /home/user/xlnf         claude:macro
```

Group rules in brief: nesting determines membership (one group per project); a `Group` carries `Macro`s and, optionally, one `Path` root (see below) — `Tmux` and nested `Group` are parse errors; project-local always wins on name collision.

#### Group workspace root

Add a single `Path` line directly under a `Group` (before its projects) to set a **workspace root**. Member projects are then resolved against it:

```text
Group xlnf
    Path /home/user/xlnf          # the group's workspace root
    Project xlnf                  # no Path  → /home/user/xlnf  (the root itself)
    Project cdp
        Path cdp                  # relative → /home/user/xlnf/cdp
    Project notes
        Path /opt/notes           # absolute → /opt/notes  (wins, escapes the root)
```

A relative member `Path` is joined onto the root; an absolute member `Path` wins (escapes the root); a member with no `Path` resolves to the root itself. The group root is tilde-expanded and must be absolute. A `Group` without a `Path` root behaves as before — its members must each declare an absolute `Path`.

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

v1.6.0 — `Group` blocks can now declare a `Path` workspace root that member projects are resolved against (relative joins onto the root, absolute wins, no-Path resolves to the root). Built on the v1.5.x `cdp add` ergonomics / v1.4.x `Group` blocks / v1.3.x `cdp check` / v1.2.x `cdp edit` / v1.1.x tmux-integration line. The roadmap and open items are tracked as GitHub issues; the formal grammar and protocol live under [`docs/specs/`](docs/specs/).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md).

## License

MIT — see [`LICENSE`](LICENSE).
