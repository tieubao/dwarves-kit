# Consumer contract

What a project or machine needs so an adopted repo works with the dwarves-kit. This is the
onboarding page, not a tutorial: read `AGENTS.md` (the operate-contract itself) and
`WORKFLOW.md` (the lane x phase gate matrix) for how to work once adopted.

## The 4 files `/kit:adopt` injects

`lib/adopt.sh` (driven by `/kit:adopt`) writes these into the target repo, idempotently. All
four are **non-destructive**: none is overwritten by a re-run or `--refresh`.

| File | What it is | Copy or pointer | Refreshed? |
|---|---|---|---|
| `AGENTS.md` | The operate-contract itself | Full copy from the kit | Never (created once, then hands-off) |
| `CLAUDE.md` (managed block) | `@AGENTS.md` import + the classify/gate one-liners, inside `<!-- kit:adopt --> ... <!-- /kit:adopt -->` markers | Generated block, appended | Yes, on `--refresh` (block replaced; rest of the file untouched) |
| `WORKFLOW.md` | Pointer to the installed kit's lane x phase gate matrix | Pointer only (never the 49KB kit copy) | Yes, on `--refresh` |
| `docs/verification/README.md` | The proof-of-done marker; its presence opts the repo into the ship-gate | Generated stub | Never |

Claude Code auto-loads `CLAUDE.md`, not `AGENTS.md`, which is why the loader block exists: it
`@AGENTS.md`-imports the real contract so an agent session actually reads it.

## The `KIT_LEDGER_DIR` knob

One root, shared by the write-side ledger and the read-side `stats` projection. Precedence
(`lib/telemetry/kit-log-dir.sh`):

1. `$KIT_LEDGER_DIR` env var, explicit (empty is a fatal error, never silent fall-through).
2. `$DWARVES_KIT_LOG_DIR` env var, back-compat alias.
3. `[ledger].location` in `.kit.toml` (project) / `kit.toml` (kit-root): `"isolated"` ->
   `$PWD/.kit/logs`, `"shared"`/unset -> the XDG default, anything else -> that literal path.
4. `${XDG_STATE_HOME:-$HOME/.local/state}/dwarves-kit/logs` -- the hardcoded default, outside
   `~/.claude` so a plugin reinstall can never wipe the corpus.

Pick **shared** (default) when several adopted projects should feed one run corpus for
`/kit:retro` and the effectiveness eval. Pick **isolated** (or an explicit path) when a
project's ledger must not mix with anything else on the machine.

## The optional `<project>/.kit.toml` override

Seeded once by `/kit:adopt` (opt-in; never overwritten after creation; `--with a,b,c` seeds
those modules `true` instead of inheriting the kit-root default). Only the keys you set win;
everything you omit inherits the operator `kit.toml`, then the kit-root `kit.toml` default
(`lib/config/kit-config.sh` resolves project > operator > kit-root > default; a missing file
at any layer is skipped).

The operator file lives at `${XDG_CONFIG_HOME:-$HOME/.config}/dwarves-kit/kit.toml`
(`KIT_CONFIG_OPERATOR` overrides the directory). It holds the keys that name per-operator
paths, such as `wrap.activity_log` and `precedent.registry`, so they survive a kit upgrade
instead of living in the kit checkout. It carries the same trust as the kit root: it sits on
the operator's machine and never rides inside a pull request, so `kit_config_get_root` reads
it and still skips the project `.kit.toml`.

Re-run `/kit:adopt` (or `lib/adopt.sh --refresh`) after hand-editing `[modules]` to re-wire
`.claude/settings.json` -- adopt reads `.kit.toml` at adopt time; no hook reads it at
hook-fire time. Hook-bearing modules (`board`, `session`, `advisor`, `cosmetic`) get their
hook added/removed from the project's `settings.json` via a targeted `jq` merge (every other
entry in that file is preserved). Command/skill modules (`queue`, `stats`, `quiz_gate`,
`weekend_batch`, `bridge`) have no hook and never touch `settings.json`.

## The stable entrypoint

Reference `$DWARVES_KIT/bin/<name>`, never a deep `lib/<subsystem>/<file>.sh` path.
The adopt-injected `CLAUDE.md` block already does this for you:

| Stable entrypoint | Forwards to |
|---|---|
| `bin/board` | `lib/board/board.sh` (incl. `board promote`, the staged-candidate human gate, ex `add-backlog`) |
| `bin/classify` | `lib/classify/classify.sh` |
| `bin/gate` | `lib/gate/gate.sh` |
| `bin/goal` | `lib/goal/goal.sh` |
| `bin/learn` | `lib/learn/learn.sh` (`learn debt <list\|collect\|mark-paid>`; `propose`/`drain` refuse until SPEC-195/196) |
| `bin/mega` | `lib/mega/mega.sh` |
| `bin/precedent` | `lib/precedent/precedent.sh` (`find "<words>" --surface records\|inventory\|all`, `--quiet` the close-out form, `--explain <label>`; registry rows are `<kind> <path>` for `repo\|scripts\|skills\|crons\|memory`, resolved `--registry` > `PRECEDENT_REGISTRY` > `kit.toml [precedent] registry` (operator or kit-root only, never a project `.kit.toml`) > `${XDG_CONFIG_HOME:-$HOME/.config}/dwarves-kit/inventory.txt`) |
| `bin/queue` | `lib/queue/queue.sh` |
| `bin/session` | `lib/session/session.sh` (`session <intel\|observe\|recall\|report\|semantic>`, ex the five `bin/session-*`) |
| `bin/spec` | `lib/spec/spec.sh` |
| `bin/stats` | `lib/stats/` (via `uv run --project`) |
| `bin/wrap` | `lib/wrap/wrap.sh` (`scan` report-only; `apply [--apply] [--worktrees]` branch delete + worktree remove + `--ff-only` pull, dry-run by default; `merge [--apply]` one own green PR per call, base = default branch, mergeable, checks green, no unresolved threads, no open dependents; `log` prepends a dated line to `[wrap] activity_log (from a worktree of the log's repo, the worktree's copy is written)`, operator or kit-root `kit.toml` only, path must resolve under `$HOME`; `default-branch` prints the detected name) |

Module CLIs keep their module names (ADR-0034 two-class rule): `bin/prose-rag`,
`bin/worktree-provision`.

A consumer that points at `bin/<name>` survives an internal `lib/` reorg unchanged; a consumer
that reaches a deep lib path does not.

## Doc-vs-code check

The 4 files this page names are exactly the 4 files `lib/adopt.sh` injects (`.kit.toml` and the
`settings.json` wiring are documented above as separate, opt-in mechanisms, not part of the
4-file base contract):

```
$ grep -n '^# [0-9]\. ' lib/adopt.sh
# 1. AGENTS.md -- the operate-contract. NEVER overwritten (even on --refresh).
# 2. WORKFLOW.md pointer -- create if absent; --refresh overwrites to current. Write atomically
# 3. CLAUDE.md loader (@AGENTS.md import) -- append once; --refresh replaces the managed block.
# 4. proof marker -- presence opts this repo into the ship-gate. NEVER overwritten.
```

This doc's table lists `AGENTS.md`, `CLAUDE.md` (managed block), `WORKFLOW.md`,
`docs/verification/README.md` -- matching adopt.sh's numbered steps 1-4 one for one. No drift.
