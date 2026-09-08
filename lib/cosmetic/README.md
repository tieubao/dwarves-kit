# cosmetic

Six hooks that make a session nicer to sit in front of. **None of them is part of the
loop.** ADR-0034 assigns every kit module a primary stage (Shape / Build / Watch /
Check / Learn, formerly Specify / Execute / Observe / Govern / Learn); `cosmetic` is the one module with **`(none)`**, and
`lib/config/module-registry.md` records it as "orthogonal to the loop". That is not a
filing accident, it is the module's whole contract.

## Where its files actually live

This dir is documentation only. **The module has no code of its own** and this README
does not move any: all six executables live in the kit's flat `hooks/` dir alongside the
spine hooks, because that is where the installer's hook map reads them from
(`install.sh `kit_module_hooks()``). This dir exists so the module has a front door, a spec, and a proof
like every other module the kit contract (SPEC-200) enumerates.

| What | Where |
|---|---|
| The six hook scripts | `hooks/{auto-format,notification,slop-cleaner,statusline,permission-auto-approve,codebase-index}.sh` |
| Module -> hook map | `install.sh `kit_module_hooks()`` (`kit_module_hooks()`) |
| Event + matcher registration | `settings.json` (user install) and `hooks/hooks.json` (plugin install) |
| statusLine registration | `settings.json` `.statusLine.command`, gated on the same `--with cosmetic` opt-in (`install.sh's statusLine registration block`) |
| Design | `lib/cosmetic/docs/specs/SPEC-201-cosmetic-hooks.md` |
| Proof | `lib/cosmetic/docs/proof-of-done.md` |
| Tests | `tests/test-hooks.sh`, section "cosmetic module: the non-blocking contract" (the shared hook suite, where every kit hook test lives) |

## The one contract: cosmetic never blocks

A cosmetic hook may **decorate, notify, format, index, or nudge**. It may never gate. In
Claude Code hook terms that means two hard rules, both asserted in `tests/test-hooks.sh`:

1. **Never exit 2.** Exit 2 is the only blocking code (it blocks the tool call on
   `PreToolUse`, and blocks stoppage on `Stop`). Every cosmetic hook exits 0, including
   on garbage stdin.
2. **Never emit a block/deny decision.** `slop-cleaner` nudges via `additionalContext`,
   never `{"decision":"block"}`. `permission-auto-approve` only ever emits
   `{"behavior":"allow"}` and has no deny branch at all, so it can widen a permission but
   never withhold one.

Corollary: **a cosmetic hook's failure mode is a no-op, not an error.** If the tool it
wraps is missing (no `prettier`, no `codebase-memory-mcp`, no `osascript`), it degrades
silently and exits 0. If its input is unparseable, it still exits 0.

## The six hooks

| Hook | Event (matcher) | Does | Degrades to |
|---|---|---|---|
| `auto-format` | `PostToolUse` (`Write\|Edit`) | Runs the file's formatter after a write: prettier / gofmt / ruff-or-black / rustfmt | no-op if no formatter is on PATH (never `npx --yes`, which would hit the network) |
| `notification` | `Notification` | Desktop toast when Claude needs input or permission (`osascript`, else `notify-send`) | no-op on a host with neither |
| `slop-cleaner` | `Stop` | Scans files modified since session start for bloat (long functions, deep nesting, >300 lines, dupe blocks) and **nudges** via `additionalContext` | no-op outside a git work tree; no-op if nothing was modified |
| `statusline` | `statusLine` (not a hook) | Renders `[model] branch \| ctx:N% \| $cost \| think:on\|off` | prints a degraded line; never fails the turn |
| `permission-auto-approve` | `PermissionRequest` | Auto-allows read-only tools + a whitelist of safe Bash prefixes; **rejects any command with a pipe/chain/subshell operator** before matching | falls through to the normal permission dialog |
| `codebase-index` | `SessionStart` | Background-refreshes the repo's `codebase-memory-mcp` structural index | no-op (quiet) when `codebase-memory-mcp` is not installed |

## Opting in

The whole module is off by default. It is not part of the always-wired spine:

```
bash install.sh --with cosmetic
```

That wires all six hooks **and** the `statusLine` command. Without it, the installer
strips every one of them out of the settings it writes, and prints
`[skip] statusLine not registered (cosmetic module not enabled...)`.

## Knobs

| Env | Read by | Default | Effect |
|---|---|---|---|
| `DWARVES_KIT_DEBUG` | all except `statusline` | `0` | `1` = trace to stderr |
| `DWARVES_KIT_LOG_DIR` | `slop-cleaner` | `$HOME/.claude/dwarves-kit/logs` | where the nudge log and the per-session seen-file live |
| `DWARVES_KIT_SESSION_MARKER` | `slop-cleaner` | `/tmp/.dwarves-kit-session-start` | the "modified since" baseline; overridable for tests |

Full behavior, non-behavior, and degrade paths per hook, plus the three findings from the
audit that wrote it (one of them a real defect, now fixed):
`docs/specs/SPEC-201-cosmetic-hooks.md`.
