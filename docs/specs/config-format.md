# cdp — Config-File Format Specification (V1)

This document is the canonical specification of the `cdp` config-file format. It is the single source of truth for the parser implementation in `lib/config.sh`. If the implementation and this document disagree, this document wins and the implementation is wrong.

## 1. Overview

`cdp` reads a single human-edited config file that lists **projects** (each with an absolute path) and, optionally, **macros** under each project (each macro is a sequence of shell command lines that run after `cd`'ing into the project's path). The format is SSH-config-inspired: indentation-based blocks, case-insensitive keywords, `#` line comments. There is no escape syntax, no quoting, and no string-interpolation step at parse time — the parser is intentionally trivial.

The file lives at `${CDP_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/cdp/config}`. The parser does not invent a default file if the path is absent; absence is reported by the resolver, not the parser.

## 2. Lexical rules

- **Encoding.** UTF-8 only. Bytes outside valid UTF-8 are not rejected at the lexer level (the parser is byte-based) but the human-readable interpretation is UTF-8.
- **Line endings.** LF (`\n`) is canonical. CRLF (`\r\n`) is normalized to LF before parsing — a trailing `\r` on any line is stripped. CR-only line endings are not supported.
- **Blank lines.** A line containing only whitespace (spaces and/or tabs) is ignored.
- **Comments.** A line whose first non-whitespace character is `#` is a comment and is ignored. **Trailing comments are NOT supported.** A `#` that appears mid-line is treated as a literal character belonging to the surrounding value. This keeps the parser trivial — values that need a literal `#` need no escaping, and there is no quoting context to track.

## 3. Keywords and case

The keywords are: `Project`, `Path`, `Macro`, `Run`, `Tmux`, `Layout`, `Pane`. The first four cover V1; `Tmux`, `Layout`, and `Pane` were added in V1.1 — see [`tmux-layout.md`](tmux-layout.md) for the full tmux-block specification.

Keywords are **case-insensitive**: `project`, `Project`, `PROJECT` are all valid spellings of the same keyword. The canonical form used in this document and in error messages is **title-case** (`Project`, `Path`, `Macro`, `Run`, `Tmux`, `Layout`, `Pane`).

Identifiers (project labels, macro names, tmux-block names, pane names) are **case-sensitive**. `Project Foo` and `Project foo` are two different projects.

## 4. Indentation rules

- A `Project <label>` line **must** start at column 0 (no leading whitespace).
- A `Path`, `Macro`, or `Tmux` line inside a `Project` block **must** be more indented than its parent `Project` line. Any positive amount of leading whitespace works.
- A `Run` line inside a `Macro` block **must** be more indented than its parent `Macro` line.
- A `Layout` or `Pane` line inside a `Tmux` block **must** be more indented than its parent `Tmux` line.
- A `Run` line inside a `Pane` block (V1.1 — tmux integration) **must** be more indented than its parent `Pane` line.
- Indentation may mix tabs and spaces. The parser does not assume a tab width. The rule is purely "strictly more leading whitespace bytes than the parent line." Two child lines under the same parent need not match each other — only each must be deeper than the parent.

In practice, a 4-space indent for `Path`/`Macro` and an 8-space indent for `Run` is recommended.

## 5. Value rules per keyword

### 5.1 `Project <label>`

- One argument: the project label.
- The label is the rest of the line after `Project<whitespace>`, with leading and trailing whitespace trimmed.
- Label syntax: `[a-zA-Z][a-zA-Z0-9_-]*` (must start with a letter, then letters, digits, underscore, or hyphen).
- Labels are unique within the config; a duplicate is a parse error (see §7).
- Labels must not collide with reserved subcommands (see §6).

### 5.2 `Path <abspath>`

- Required exactly once per `Project` block (zero or two-plus is a parse error).
- The value is everything after `Path<whitespace>`, with trailing whitespace trimmed. Internal whitespace is preserved verbatim — paths with spaces are supported.
- **Tilde expansion** is performed at parse time: a leading `~/` is replaced with `$HOME/`. A bare `~` (no slash) is replaced with `$HOME`. `~user/foo` (other-user expansion) is **not** supported.
- After tilde expansion, the path **must be absolute** (begin with `/`). A relative path is a parse error.
- The path's **existence is NOT validated at parse time**. The resolver performs this check at jump time. This lets users author config entries before the directories exist.

### 5.3 `Macro <name>`

- One argument: the macro name.
- Trimmed identically to a project label.
- Name syntax: `[a-zA-Z][a-zA-Z0-9_-]*` — same as project labels.
- Macro names are unique within their parent project; a duplicate within the same project is a parse error.
- A macro name **may** collide with the parent project's own label, or with another project's label, or with another project's macro name. The resolver disambiguates by positional arity: `cdp <a>` is always jump-only; `cdp <a> <b>` is always jump-and-run-macro.
- Macro names must not collide with reserved subcommands (see §6).

### 5.4 `Run <command>`

- The value is everything after `Run<whitespace>`, with trailing whitespace trimmed.
- The value is taken **verbatim** as a single shell command line. There is no escape sequence, no continuation, no quoting interpretation. Variable expansion, command substitution, and pipe semantics happen later, when the macro runs in the user's shell.
- One macro may have multiple `Run` lines; they execute in source order, in the user's interactive shell, after the `cd`.
- An empty `Run` (no command after the keyword) is a parse error.
- `Run` is also valid inside a `Pane` block (V1.1 — tmux integration); see [`tmux-layout.md`](tmux-layout.md) §4.5 for the pane-specific semantics. The line-level grammar is identical.

### 5.5 `Tmux <name>`, `Layout <expression>`, `Pane <name>` (V1.1)

These three keywords define a tmux-orchestrated pane layout for a project. They are summarized here for the parser's benefit; the canonical specification is [`tmux-layout.md`](tmux-layout.md).

- `Tmux <name>` opens a sub-block inside a `Project`. Name syntax: `[a-zA-Z][a-zA-Z0-9_-]*`. Names are unique within the parent project, and must not collide with any `Macro` name in the same project (parse error — see §7).
- `Layout <expression>` is required exactly once per `Tmux` block. The value is the rest of the line after `Layout<whitespace>`, trimmed of trailing whitespace, and parsed per the Layout DSL grammar in [`tmux-layout.md`](tmux-layout.md) §5. Layout-level errors (undefined pane reference, dangling pane, duplicate reference, malformed grammar) are reported at parse time.
- `Pane <name>` opens a nested sub-block inside a `Tmux` block. Name syntax: `[a-zA-Z][a-zA-Z0-9_-]*`. Pane names are unique within their parent `Tmux` block. Each `Pane` must contain at least one `Run` line.

Projects without `Tmux` blocks parse and resolve exactly as in V1.

## 6. Reserved subcommands

The following identifiers are reserved and may not be used as a project label or as a macro name. A collision is a parse error.

```
add  rm  ls  init  edit  --help  -h  --version  -v
```

This list **may grow** in V2+ as new subcommands are introduced. Adding to it is a backward-incompatible change for users who happen to have a project labeled with the new name. The release notes for any such V2 release will name the affected reserved word; users with collisions must rename their project before upgrading. Documenting this constraint up-front lets V1 users avoid future-proof traps (don't name a project `which` if you ever expect to upgrade).

## 7. Uniqueness and structural constraints (all parse errors)

- Duplicate project label.
- Duplicate macro name within the same project.
- A `Project` block with zero `Path` lines, or two-plus `Path` lines.
- A `Macro` line outside any `Project` block.
- A `Run` line outside any `Macro` or `Pane` block.
- A project label that matches a reserved subcommand.
- A macro name that matches a reserved subcommand.
- A relative path after tilde expansion.
- An empty `Run`.
- An unknown keyword.

V1.1 (tmux) additions:

- Duplicate `Tmux` name within the same project.
- A `Tmux` name that collides with a `Macro` name in the same project (the two share the `cdp <label> <name>` dispatch arity; collisions are forbidden rather than resolved by lookup-order).
- A `Tmux` name that matches a reserved subcommand.
- A `Tmux` block with zero `Layout` lines, or two-plus `Layout` lines.
- A `Tmux` block with zero `Pane` blocks.
- A `Layout` line outside any `Tmux` block.
- A `Pane` line outside any `Tmux` block.
- Duplicate `Pane` name within the same `Tmux` block.
- A `Pane` name that matches a reserved subcommand.
- A `Pane` block with zero `Run` lines.
- A `Layout` expression that fails to parse against the Layout DSL grammar.
- A `Layout` expression that references a pane name not defined as a `Pane` block in the parent `Tmux`.
- A `Pane` block whose name is not referenced by the parent `Tmux`'s `Layout` expression.
- A `Layout` expression that references the same pane name more than once.

## 8. Error reporting

Every parse error is emitted to **stderr** in the form:

```
cdp: config:<line>: <message>
```

`<line>` is the 1-based line number in the source file. `<message>` is one of the canonical messages below. The parser exits with code **65** (`EX_DATAERR`).

| Condition | Message |
|---|---|
| Unknown keyword | `unknown keyword: '<keyword>'` |
| Duplicate project label | `duplicate label: '<label>'` |
| Duplicate macro name in project | `duplicate macro name '<name>' in project '<label>'` |
| Multiple `Path` lines in a project | `multiple Path lines for project '<label>'` |
| Missing `Path` line | `project '<label>' has no Path` |
| Relative `Path` value | `Path must be absolute: '<value>'` |
| Empty `Run` line | `empty Run line` |
| Reserved label/name | `project label '<label>' is reserved` / `macro name '<name>' is reserved` / `tmux name '<name>' is reserved` / `pane name '<name>' is reserved` |
| `Macro` outside a `Project` block | `Macro outside Project block` |
| `Run` outside a `Macro` or `Pane` block | `Run outside Macro or Pane block` |
| Duplicate Tmux name in project (V1.1) | `duplicate tmux name '<name>' in project '<label>'` |
| Tmux/Macro name collision in project (V1.1) | `name '<name>' already used as Macro in project '<label>'` (or `as Tmux`) |
| Multiple `Layout` lines in one Tmux block (V1.1) | `multiple Layout lines for tmux '<name>' of project '<label>'` |
| Missing `Layout` in a Tmux block (V1.1) | `tmux '<name>' of project '<label>' has no Layout` |
| Tmux block with no Panes (V1.1) | `tmux '<name>' of project '<label>' has no Pane` |
| `Layout` outside a `Tmux` block (V1.1) | `Layout outside Tmux block` |
| `Pane` outside a `Tmux` block (V1.1) | `Pane outside Tmux block` |
| Duplicate Pane name within a Tmux block (V1.1) | `duplicate pane name '<name>' in tmux '<tmux-name>' of project '<label>'` |
| Pane block with no Runs (V1.1) | `pane '<name>' in tmux '<tmux-name>' of project '<label>' has no Run` |
| Layout DSL parse error (V1.1) | `layout for tmux '<name>' of project '<label>' is malformed: <reason>` |
| Layout references undefined pane (V1.1) | `layout references undefined pane '<pane>' in tmux '<name>' of project '<label>'` |
| Pane defined but not referenced (V1.1) | `pane '<name>' defined but not referenced in layout` |
| Pane referenced more than once (V1.1) | `pane '<name>' referenced more than once in layout` |

The parser is **fail-fast**: it reports the first error and exits. It does not attempt multi-error recovery — fix one, re-run.

## 9. Worked examples

### Example 1 — Minimal one-project no-macros

```text
Project myproject
    Path /home/user/myproject
```

### Example 2 — One project, two macros, each one Run

```text
Project myproject
    Path /home/user/myproject
    Macro deploy
        Run ./scripts/publish.sh
    Macro logs
        Run tail -f /var/log/myproject.log
```

### Example 3 — Multi-step macro with three Run lines

```text
Project api
    Path /home/user/projects/api
    Macro dev
        Run pnpm install
        Run pnpm --filter web build
        Run pnpm --filter web dev
```

### Example 4 — Tilde-expanded path

```text
Project notes
    Path ~/Documents/notes
```

After parsing, the project's resolved path is `$HOME/Documents/notes`.

### Example 5 — Tabs + spaces mixed indentation, valid

```text
Project mixed
	Path /tmp/mixed
    Macro hello
		Run echo hi
        Run echo bye
```

The leading whitespace bytes are: `Path` uses one tab, `Macro hello` uses four spaces, the first `Run` uses two tabs, the second `Run` uses eight spaces. Each child's leading whitespace is strictly more bytes than its parent — accepted.

### Example 6 — Lowercased keywords

```text
project lower
    path /tmp/lower
    macro check
        run ls -la
```

Identical semantics to the title-case form.

### Example 7 — A commented-out project block

```text
# Project archived
#     Path /tmp/archived
#     Macro deploy
#         Run ./old-deploy.sh

Project active
    Path /tmp/active
```

The `archived` project is not parsed at all (every line begins with `#`). Only `active` is registered.

### Example 8 — Duplicate label, parse error

Source:

```text
Project foo
    Path /tmp/a
Project foo
    Path /tmp/b
```

Output (stderr) and exit:

```
cdp: config:3: duplicate label: 'foo'
```

Exit code: `65`.

## 10. Open questions (deferred to V1.2+)

- **`Include <other-config>`** — should we support file-include directives, à la SSH config? Useful for keeping per-machine overrides in a separate file that's not version-controlled. Deferred until users request it.
- **`Env KEY=VALUE` per project** — auto-export environment variables on jump. This sits between project-config and direnv's territory; might be best left to direnv. Deferred.
- **Multi-window `Tmux` blocks** — V1.1 creates one tmux window per session. A future `Window <name> { ... }` nested construct could express multi-window layouts. Deferred until users hit the single-window ceiling.
- **Per-pane `Cwd <subpath>`** — every pane currently inherits the project's `Path`. A `Cwd` child of `Pane` could override it for that pane. Deferred to V1.2.

### Resolved questions

- **`Layout` keyword reservation** — reserved as of V1.1 alongside `Tmux` and `Pane`. Users with `Macro` or `Pane` names spelled `layout`, `tmux`, or `pane` must rename before upgrading from V1.0.x → V1.1.
