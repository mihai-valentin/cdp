# cdp — Tmux Layout Specification (V1.1)

This document is the canonical specification of `cdp`'s tmux integration: the `Tmux` config block, the `Layout` mini-DSL grammar, the resolver plan-line extensions that carry tmux setup, and the shim's handoff to the `cdp-tmux` orchestrator. It complements [`config-format.md`](config-format.md) and [`resolve-semantics.md`](resolve-semantics.md) — those documents describe the V1 surface; this one describes the V1.1 additions. If any of the three disagree, this document wins for tmux concerns and the others wins for everything else.

## 1. Why this exists

A daily `cdp myproj dev` workflow for a multi-process project (e.g. `pnpm dev` + `pnpm test --watch` + `tail -f log`) currently requires the user to either chain the commands serially in a `Macro`, or to manage a tmux session by hand. V1.1 lets the user **declare a tmux pane layout per project** and have `cdp` materialize it on jump, attaching the user to the resulting session.

This is **opt-in per project**. Projects without `Tmux` blocks behave exactly as in V1.

## 2. Conceptual model

A **Tmux block** belongs to a `Project` and has a name, just like a `Macro`. Inside it, the user declares:

- A single **`Layout`** line that describes how panes are arranged (a tree of horizontal/vertical splits).
- One **`Pane <name>`** sub-block per pane, each containing one or more **`Run`** lines that are sent to that pane after the layout is created.

`cdp <project> <tmux-name>` then:

1. `cd`s the user's interactive shell into the project's path (same as a bare jump).
2. If a tmux session named `<project>-<tmux-name>` already exists, `tmux attach -t <project>-<tmux-name>` and stop.
3. Otherwise, create a detached tmux session, walk the layout tree to split panes, send each pane's `Run` lines via `tmux send-keys`, then `tmux attach -t <project>-<tmux-name>`.

Inside each pane, the working directory is the project path (inherited from the detached session's `-c` argument).

## 3. Direction convention

The `Layout` DSL uses `h` and `v` with **tmux's** semantics, not English semantics:

- `h` — **horizontal split** — the dividing line is horizontal; panes sit **side-by-side** (left | right).
- `v` — **vertical split** — the dividing line is vertical; panes sit **stacked** (top / bottom).

This matches `tmux split-window -h` and `tmux split-window -v` exactly. Users who think in English ("vertical split = side-by-side") will find this initially counterintuitive — the spec uses tmux's convention because the user will read tmux documentation more often than they read this spec, and a single mental model is cheaper than a translation table.

## 4. Config-block syntax

A `Tmux` block sits inside a `Project` block at the same level as `Macro`. Inside the `Tmux` block, exactly one `Layout` line is required, followed by one `Pane <name>` sub-block per pane named in the layout.

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

Indentation rules carry over from [`config-format.md`](config-format.md) §4: each child line is more indented than its parent. `Pane` is a child of `Tmux`; `Run` inside a `Pane` is a child of `Pane`.

### 4.1 Keywords (additions to §3 of config-format)

The keyword set is extended from `{Project, Path, Macro, Run}` to `{Project, Path, Macro, Run, Tmux, Layout, Pane}`. Case-insensitivity rules carry over verbatim.

### 4.2 `Tmux <name>`

- One argument: the tmux block name.
- Name syntax: `[a-zA-Z][a-zA-Z0-9_-]*` — same shape as `Macro` and `Project`.
- Must not collide with the V1 reserved-subcommand list (see [`config-format.md`](config-format.md) §6).
- Must not collide with another `Tmux` name in the same project (parse error).
- Must not collide with a `Macro` name in the same project (parse error — see §7 below for the rationale).

### 4.3 `Layout <expression>`

- Required exactly once per `Tmux` block (zero or two-plus is a parse error).
- The value is everything after `Layout<whitespace>`, with trailing whitespace trimmed.
- The value is parsed as a Layout DSL expression (§5).
- The set of pane names referenced in the expression must equal the set of `Pane` blocks defined in the parent `Tmux` block — no orphans, no dangling references (parse error in either direction).

### 4.4 `Pane <name>`

- Opens a sub-block inside a `Tmux` block.
- One argument: the pane name.
- Name syntax: `[a-zA-Z][a-zA-Z0-9_-]*`.
- Pane names are unique within their parent `Tmux` block (parse error on duplicate).
- Pane names need not be unique across `Tmux` blocks of the same project, or across projects.
- A `Pane` block must contain at least one `Run` line (parse error on zero — empty panes serve no purpose; if the user wants an empty shell pane, they may include `Run :` or `Run true`).

### 4.5 `Run <command>` inside `Pane`

- Same syntax and trim rules as `Run` inside `Macro` ([`config-format.md`](config-format.md) §5.4).
- Each `Run` line is sent to the pane via `tmux send-keys ... Enter`, in source order. The orchestrator does not wait between `Run` lines — they queue up in the pane's command buffer.

## 5. Layout DSL

The `Layout` value is a small expression language describing a tree of pane splits.

### 5.1 Grammar (EBNF)

```ebnf
layout      = node ;
node        = pane_ref | split ;
split       = direction , ":" , "[" , child_list , "]" ;
child_list  = node , { sep , node } ;
direction   = "h" | "v" ;
sep         = "|" ;
pane_ref    = identifier ;
identifier  = letter , { letter | digit | "_" | "-" } ;
letter      = "a" .. "z" | "A" .. "Z" ;
digit       = "0" .. "9" ;
```

Whitespace (spaces and tabs only — no newlines, since the entire layout lives on one line) is ignored anywhere except inside an `identifier`.

### 5.2 Semantics

- A bare `pane_ref` is a one-pane layout. Tmux receives one window with one pane.
- A `split` describes a tmux container with two-or-more panes laid out per `direction`. The first child fills the container; each subsequent child is created by `tmux split-window -<direction>` against the previous child.
- Splits nest arbitrarily. Each nested split is created against its parent's pane before the parent's other children are added — see §6.3 for the canonical walk order.

### 5.3 Identifier resolution

Each `pane_ref` in a layout must match exactly one `Pane <name>` block in the same `Tmux` parent. References are resolved at parse time:

- Reference to an undefined pane → parse error: `cdp: config:<line>: layout references undefined pane '<name>' in tmux '<tmux-name>' of project '<label>'`.
- Defined pane never referenced → parse error: `cdp: config:<line>: pane '<name>' defined but not referenced in layout`.
- Same pane referenced more than once in one layout → parse error: `cdp: config:<line>: pane '<name>' referenced more than once in layout`. (Tmux does not support a single pane appearing in multiple positions; allowing this would silently misrepresent the layout.)

### 5.4 Cardinality

- A `child_list` must contain at least two children. A `split` of one child is meaningless and is a parse error.
- The DSL has no upper bound on splits or nesting depth. In practice, more than ~6 panes per layout becomes unreadable; that is a user concern, not a parser concern.

### 5.5 Worked examples

| Layout value | Tree | Panes |
|---|---|---|
| `main` | `main` | one pane named `main` |
| `h:[a \| b]` | `(h: a, b)` | two side-by-side panes |
| `v:[a \| b]` | `(v: a, b)` | two stacked panes |
| `h:[a \| b \| c]` | `(h: a, b, c)` | three side-by-side panes |
| `h:[main \| v:[test \| logs]]` | `(h: main, (v: test, logs))` | left half = `main`; right half = `test` over `logs` |
| `v:[hdr \| h:[nav \| body \| aside]]` | `(v: hdr, (h: nav, body, aside))` | top strip + three columns below |

## 6. Resolution semantics (extensions to resolve-semantics.md)

### 6.1 Per-project actions namespace

In V1, `cdp <label> <name>` looked `<name>` up in the project's `Macros`. In V1.1, the parser builds a single per-project **actions** map containing every `Macro` and every `Tmux` block, tagged by kind:

```
CDP_ACTIONS["<label>\x1f<name>"] = "macro"   |   "tmux"
```

The macro/tmux uniqueness constraint (§4.2) ensures no collisions in this map. The resolver does one lookup and dispatches accordingly.

### 6.2 Plan-line additions

The resolver's plan format (`resolve-semantics.md` §4) is extended with four new prefixes, all reserved under the `CDP_TMUX_` namespace:

| Prefix | Body | Cardinality | Semantics |
|---|---|---|---|
| `CDP_TMUX_SESSION ` | session name | exactly 1 | Tmux session to create or attach. Always `<project>-<tmux-name>` in V1.1 (no override). |
| `CDP_TMUX_LAYOUT ` | DSL expression (verbatim, post-trim) | exactly 1 | The layout tree to materialize if the session does not already exist. |
| `CDP_TMUX_PANE ` | `<pane-name>\x1f<command>` | zero-or-more | One line per `Run` of one pane, in `(pane source order, run source order)`. The `\x1f` (ASCII Unit Separator) cannot appear in a pane name (identifier grammar) and is the same separator the parser already uses internally — chosen to avoid quoting. |
| `CDP_TMUX_ATTACH` | (none) | exactly 1, last | Marks the end of the tmux setup block. The shim treats this as the trigger to invoke `libexec/cdp-tmux`. |

A complete tmux plan is therefore:

```
CDP_CD <abspath>
CDP_TMUX_SESSION <session-name>
CDP_TMUX_LAYOUT <dsl>
CDP_TMUX_PANE <pane>\x1f<cmd>
... (more CDP_TMUX_PANE lines) ...
CDP_TMUX_ATTACH
```

`CDP_CD` always comes first so the shim's `cd` happens before tmux sees the cwd. `CDP_TMUX_ATTACH` always comes last so the shim has a deterministic end-of-plan signal.

### 6.3 Orchestrator walk order

When the session does not exist, `libexec/cdp-tmux`:

1. Verifies `tmux` is on `$PATH`. If not, prints `cdp: tmux not found on PATH` to stderr and exits `3`.
2. Parses the layout DSL into a tree (delegated to `lib/tmux.sh`).
3. Walks the tree **breadth-first by slot** (NOT depth-first), assigning each leaf a tmux pane index. The leftmost leaf is pane 0; subsequent panes are emitted by processing each split's child slots top-down before recursing into any one. The full algorithm:

   ```
   emit_leaf(leftmost_leaf(root), op=ROOT)        # pane 0
   queue = [(root, walk_index_of_root_leftmost)]
   while queue:
       node, my_rep_idx = queue.pop_front()
       if node is a split with direction d and children c[0..n-1]:
           reps = [my_rep_idx]                     # first child shares the parent's rep
           for i in 1..n-1:
               new_idx = emit_leaf(leftmost_leaf(c[i]),
                                   op=SPLIT d reps[i-1])
               reps.append(new_idx)
           for i in 0..n-1:
               queue.push((c[i], reps[i]))
   ```

   This BFS-by-slot order is **mandatory** for nested splits. A naive depth-first walk like `[a, b, c, d]` for `h:[v:[a|b] | v:[c|d]]` would force tmux into an L-shaped partition (impossible). The correct order is `[a, c, b, d]`: split horizontally first to establish the two columns, then split each column vertically.

4. Emits a sequence of tmux commands:
   - `tmux new-session -d -s <session> -c <cwd> -n cdp` to create the session with pane 0.
   - For each subsequent leaf in walk order with op `SPLIT <dir> <parent-walk-idx>`, `tmux split-window -t <session>:cdp.<tmux-pane-id-at-walk-idx> -<dir> -c <cwd>`. Capture the new tmux pane id with `-P -F '#{pane_id}'` and store it indexed by walk-index for later send-keys targeting.
   - After all panes exist, for each pane's `Run` lines (in source order): `tmux send-keys -t <session>:cdp.<pane-id> -- <cmd> Enter`. One invocation per `Run` line; do not concatenate.
5. `exec tmux attach -t <session>` to attach the user (or `tmux switch-client` if `$TMUX` is set — see §6.5).

Rationale: the walk-and-split approach matches how tmuxp/teamocil work and avoids tmux's `select-layout` (which uses a serialized layout string that is opaque and version-fragile). Step-by-step splitting is verbose but readable and survives tmux upgrades.

### 6.4 Existing-session policy

Per the user decision recorded with this spec: if `tmux has-session -t <session>` returns success, the orchestrator skips steps 2–4 and goes straight to `exec tmux attach -t <session>`. The user's running panes, their cwds, and their command history are preserved. There is no V1.1 "force recreate" flag — if the user wants a fresh session, they `tmux kill-session -t <session>` themselves first.

### 6.5 Outside-tmux requirement

The orchestrator must run from a shell that is **not already inside tmux**. If `$TMUX` is set:

- If the existing session matches `<session>`, the orchestrator does `tmux switch-client -t <session>` instead of `tmux attach`.
- If `$TMUX` is set but the session does not yet exist, the orchestrator creates it (detached, as usual) and `tmux switch-client -t <session>` to it.
- If `$TMUX` is set and points to a different tmux server (rare — multiple sockets), the orchestrator falls back to printing the session name and a hint, exit code `3`. This edge case is not worth special-casing in V1.1.

### 6.6 Shim extensions

The shim emitted by `cdp init` (resolve-semantics §5) gains a `CDP_TMUX_*` branch in its read loop. The shim accumulates the four kinds of tmux lines into shell-locals (session name, layout string, an array of `pane\x1fcmd` records) and on `CDP_TMUX_ATTACH` invokes `libexec/cdp-tmux` with those values, then `exec`s tmux as that script directs.

Sketched shim addition (illustrative — the canonical source lives in `libexec/cdp-init`):

```bash
case "$line" in
    'CDP_TMUX_SESSION '*) _cdp_tmux_session="${line#CDP_TMUX_SESSION }" ;;
    'CDP_TMUX_LAYOUT '*)  _cdp_tmux_layout="${line#CDP_TMUX_LAYOUT }" ;;
    'CDP_TMUX_PANE '*)    _cdp_tmux_panes+=("${line#CDP_TMUX_PANE }") ;;
    'CDP_TMUX_ATTACH')
        '<absolute-path-to-cdp-tmux>' \
            "$_cdp_tmux_session" "$_cdp_tmux_layout" "${_cdp_tmux_panes[@]}"
        return $?
        ;;
esac
```

The shim does **not** parse the layout DSL — that is the orchestrator's job. The shim's only obligation is correct accumulation and dispatch.

## 7. Why `Macro` and `Tmux` names cannot collide within a project

The two are dispatched via the same `cdp <label> <name>` arity — there is no flag to disambiguate. Allowing both kinds to share a name and dispatching by lookup-order would be silent and surprising; making it a parse error fails the user's config loudly when they author the collision, with a message naming both definitions. The cost of the rename is small; the cost of a silent dispatch ambiguity is debugging at 11pm.

## 8. Exit codes (additions to resolve-semantics.md §6)

| Code | Meaning |
|---|---|
| `3` | `tmux` not on `$PATH`, or `$TMUX` points to a foreign socket and resolution can't proceed. |

The macro-related codes (1, 2, 64, 65, 70) keep their meanings.

## 9. Verbatim runtime error messages (additions to resolve-semantics.md §7)

| Trigger | stderr message | Exit |
|---|---|---|
| `tmux` not installed | `cdp: tmux not found on PATH` | `3` |
| Session creation failed (tmux returned non-zero) | `cdp: failed to create tmux session '<session>': <tmux's stderr line>` | `1` |
| Inside foreign tmux socket | `cdp: $TMUX points to a different tmux server; cannot orchestrate from here` | `3` |

Parse-time errors live in `config-format.md` §8.

## 10. Worked end-to-end traces

### Trace 1 — Create new session

Config `/tmp/cfg`:
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

Invocation:
```
$ CDP_CONFIG=/tmp/cfg cdp myapp dev
```

Resolver stdout (with `\x1f` shown as `␟` for readability):
```
CDP_CD /home/user/myapp
CDP_TMUX_SESSION myapp-dev
CDP_TMUX_LAYOUT h:[main | v:[test | logs]]
CDP_TMUX_PANE main␟pnpm dev
CDP_TMUX_PANE test␟pnpm test --watch
CDP_TMUX_PANE logs␟tail -f var/log/app.log
CDP_TMUX_ATTACH
```

Shim accumulates, calls `cdp-tmux myapp-dev "h:[main | v:[test | logs]]" "main␟pnpm dev" "test␟pnpm test --watch" "logs␟tail -f var/log/app.log"`. Orchestrator runs `tmux new-session -d -s myapp-dev -c /home/user/myapp -n cdp`, two `tmux split-window` calls, three `tmux send-keys` calls, then `exec tmux attach -t myapp-dev`.

### Trace 2 — Attach to existing session

Same config, same invocation, but `tmux has-session -t myapp-dev` succeeds.

Resolver stdout: identical to Trace 1.

Orchestrator skips create+split+send-keys and goes straight to `exec tmux attach -t myapp-dev`. The user's running panes are unchanged.

### Trace 3 — Macro and Tmux name collision (parse error)

Config:
```text
Project myapp
    Path /tmp/myapp
    Macro dev
        Run pnpm dev
    Tmux dev
        Layout main
        Pane main
            Run pnpm dev
```

Invocation: any.

Stderr:
```
cdp: config:5: name 'dev' already used as Macro in project 'myapp'
```

Exit code: `65`.

### Trace 4 — Tmux not installed

`tmux` removed from `$PATH`. `cdp myapp dev` reaches the orchestrator (after `cd`), which prints:

```
cdp: tmux not found on PATH
```

Exit code: `3`. The `cd` already happened — the user's shell remains in `/home/user/myapp`. This is a deliberate choice: the cwd change is harmless, and the user is already where they wanted to be.

## 11. Out of V1.1 (deferred to later)

- **Multiple windows.** V1.1 creates one tmux window per session (named `cdp`). Multi-window support would extend the layout DSL with a window-grouping construct (e.g. `Window <name> { ... }`) and is left for V1.2+.
- **Per-pane working directory override.** All panes inherit the project's `Path`. A `Pane <name>` could grow a `Cwd <subpath>` child line; deferred until concrete demand.
- **Send-keys delay between `Run` lines.** Some commands take measurable time to set up a prompt; sequential `send-keys` may interleave keystrokes. If users hit this, a `Delay <ms>` annotation or a `--wait-prompt` flag is the V1.2 candidate.
- **Layout templates / aliases.** Reusing `h:[main | v:[test | logs]]` across projects via a `LayoutAlias <name> <expr>` top-level keyword is plausible if projects converge on a few canonical shapes. Deferred.
- **`cdp tmux <project> <name>` explicit dispatch.** V1.1 dispatches on positional arity only. An explicit subcommand would help when a future ambiguity arises (e.g. flag-augmented forms). Not needed in V1.1.
- **Force-recreate flag.** `cdp myapp dev --recreate` to kill an existing session and rebuild. The current spec says "kill it yourself" — escalate to a flag if that turns out to be a daily annoyance.
- **Pre-attach hook.** A `BeforeAttach <cmd>` line for project-wide setup that should run once per session (e.g. `direnv allow`). Deferred.
