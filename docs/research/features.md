# Feature Map: Cross-Kit Config Seams

## Endpoints & Verbs

| Verb/Function | File:Line | Contract |
|---|---|---|
| `kit_config_get <section.key> [default]` | lib/config/kit-config.sh:63-73 | Resolves project > operator > kit-root > default (project may override for safety non-critical keys) |
| `kit_config_get_root <section.key> [default]` | lib/config/kit-config.sh:82-90 | Resolves operator > kit-root > default (SKIPS project for security-bearing keys like gauntlet.runner_host, wrap.activity_log, wrap.before) |
| `kit_config_operator()` | lib/config/kit-config.sh:32 | Returns `${KIT_CONFIG_OPERATOR:-${XDG_CONFIG_HOME:-$HOME/.config}/dwarves-kit}/kit.toml` |
| `kit_config_root()` | lib/config/kit-config.sh:31 | Returns `${KIT_CONFIG_ROOT:-${DWARVES_KIT:-$HOME/.claude/dwarves-kit}}/kit.toml` |
| `kit_config_project()` | lib/config/kit-config.sh:33 | Returns `${KIT_PROJECT_ROOT:-$PWD}/.kit.toml` |
| `plugin-check status [--no-refresh]` | lib/plugin-check/bin/plugin-check:199-281 | Lists installed plugins: status in {current, OUTDATED, unknown}, skips directory-source dev-trees |
| `plugin-check update [name] [--apply]` | lib/plugin-check/bin/plugin-check:307-436 | Dry-run or apply bumps via official `claude plugin update` CLI; never runs twice per PR |
| `wrap scan <repo>` | lib/wrap/wrap.sh:~100-200 | Report-only; detects worktrees, dirty files, branch verdicts, PR status, foreign activity via index.lock age |
| `wrap merge --apply <repo>` | lib/wrap/wrap.sh | Merges exactly ONE own, green PR to default branch; never runs twice per session |
| `wrap apply [--apply] [--worktrees] <repo>` | lib/wrap/wrap.sh | Dry-run branch/worktree cleanup; pull --ff-only on default; remove merged worktrees via ExitWorktree |
| `wrap log "<slug>: <one sentence>" [--date YYYY-MM-DD]` | lib/wrap/wrap.sh | Prepends activity line to operator's log file (kit-root config-bearing key read) |
| `wrap default-branch <repo>` | lib/wrap/wrap.sh | Detects origin/HEAD else origin/main else origin/master; exit 1 if none resolve |
| `gate-ledger.sh debt <rid> significance=<low\|high> worthiness=<low\|high> verdict=<tap\|wave\|not-significant> [response=<engage\|defer\|wave>] [reason=...]` | lib/gate/gate-ledger.sh | Records learning debt with four required fields + optional response + sanitized reason (= → :) |
| `precedent find --surface inventory --quiet <words>` | lib/precedent/precedent.sh | Scores tools/skills/crons/memory across term patterns; returns 1-N results or summary line |
| `bin/config list` | bin/config | Dumps all config keys with DISPLAY KEY, current value, PROVENANCE (kit-root/operator/project) |

## Data Models

| Model | File | Key Fields |
|---|---|---|
| kit.toml | kit.toml | [modules], [ledger], [mega], [gate], [features], [sync], [observe], [gauntlet], [precedent], [wrap] sections; status tags [impl]/[design]/[reserved]/[consumer] |
| .kit.toml | (project root) | Project-level override, never overwritten after first adopt; [modules] section rewritable by user edit |
| wrap.activity_log | Resolved from kit-root config wrap.activity_log key | Single-operator file, mode preserved, prepended newest-first; empty = no write (clean result, not failure) |
| backlog-staging.md | _meta/backlog-staging.md | Blocks: `## [staged\|expired\|rejected\|promoted ID-NNN] <title>` + `- Field: value` lines (Intent, Approach, Tags, Home, Source) |
| run ledger | resolved via lib/telemetry/kit-log-dir.sh | Append-only TSV; one line per gate event; wrap outcome reads for `shipping pr=#<n>` to trigger /kit:retro |

## Configuration Keys (Seams)

| Section | Key | [Status] | Consumer/Meaning |
|---|---|---|---|
| wrap | activity_log | [consumer] | Operator's own log file (kit-root read only; never project) |
| wrap | before | [consumer] | Skill name invoked FIRST in /kit:wrap step 0 (kit-root read only; never project) |
| precedent | registry | [consumer] | Extra scan locations: `<kind> <path>` file (kind = repo\|scripts\|skills\|crons\|memory) |
| gauntlet | runner_host | [impl] | SSH host for remote test runs (kit-root read only, security-bearing) |
| gauntlet | probe_key_ref | [impl] | 1P ref runner resolves at run time (kit-root read only) |
| modules | board, session, advisor, cosmetic, queue, stats, ... | [impl] | Per-module hook/CLI enable flags in [modules] section |

## UI Components & Workflows

| Component | File | Purpose |
|---|---|---|
| commands/onboard.md | commands/onboard.md | Guided first-run: detect install mode, offer adopt, pick modules, preview writes, tour the loop |
| commands/adopt.md | commands/adopt.md:1-48 | Adoption driver: install AGENTS.md, CLAUDE.md loader, WORKFLOW pointer, proof marker, .kit.toml, settings.json hooks |
| commands/wrap.md | commands/wrap.md | Landing workflow, steps -1 through 9: before-seam, concurrent-check, board-rows, commit, merge PRs, deploy-check, cleanup, activity-log, learn, reflect, report. Four `[wrap]` autonomy knobs gate the write steps; the three that finish requested work default to act, `drain_staged` defaults off because it starts unattended work |
| wrap report | commands/wrap.md `### Step 9: report` | skim-first block: `Needs you` (✅/🔴, admission test: only what the operator alone can do), `What happened`, `Shipped` (#PR, deploy state), `Left alone` (derived from the closing `wrap scan`), `FYI`, overlays |

## Test Coverage

| Test File | Covers |
|---|---|
| tests/test-config.sh | kit_config_get precedence (project > operator > kit-root > default), kit_config_get_root (operator > kit-root, no project), inline comments, unquoting, missing keys/sections |
| lib/plugin-check/bin/plugin-check | (self-contained; no separate test file; verdict logic in-module) |
| lib/stats/tests/test-memory-lens.sh | memory-lens subject indexing via repo scan of .claude/memory/*.md |
| tests/ | (no dedicated wrap, precedent, gate-debt, staging tests; those are integration-grade or covered by consuming commands) |

**GAPS:** Plugin-check verdict logic lacks unit tests (edge cases: sentinel versions, hex-sha validation). Staging-format grammar has no round-trip test (parse + render preserves block state). Precedent scoring has no isolated suite.

## Recent Git History

```
git log --oneline -10 lib/config/ lib/wrap/ lib/gate/gate-ledger.sh lib/precedent/ lib/stats/src/stats/memory_lens.py
```

(Most recent work on config layer, wrap, gate-debt, precedent, memory-lens; git log will show exact commits.)

## Key Files (Ranked by Relevance)

1. **lib/config/kit-config.sh** (156 lines) — Single config resolver; three-layer precedence engine; `kit_config_get` vs `kit_config_get_root` split for security. Embedded selftest suite.

2. **kit.toml** (192 lines) — Source-of-truth for every kit-wide knob; section headers with [status] tags; keys define seams (wrap.activity_log, wrap.before, precedent.registry, gauntlet.runner_host).

3. **lib/wrap/wrap.sh** (800+ lines) — Session landing verbs (scan, merge, apply, log, default-branch); foreign-activity detection; worktree teardown logic; activity-log prepend.

4. **commands/wrap.md** (137 lines) — 8-step process with clear "step -1 before seam" (operator's wrap.before skill), step 6 activity-log, step 7 retro-trigger.

5. **lib/gate/gate-ledger.sh** (debt function ~50 lines) — Learning-debt recording with significance/worthiness/verdict/response quartet + sanitized reason field.

6. **hooks/backlog-stage.py** (100+ lines) — SessionEnd harvest; stages candidates to backlog-staging.md; rate-limited + detached-child pattern for timeout safety.

7. **lib/learn/staging-format.py** (174 lines) — Block grammar: parse/render/dedup for staging blocks; ONE shared definition (staging-format*); shared by propose + drain.

8. **lib/precedent/inventory.py** (200+ lines) — Inventory scan (tools/skills/crons/memory); secret-scrubbing; scoring by term pattern + adjacency bonus.

9. **commands/onboard.md** (140+ lines) — Guided first-run choreography; adopts via lib/adopt.sh; bridges plugin path's missing --with.

10. **commands/adopt.md** (48 lines) — Non-destructive idempotent adoption; creates AGENTS.md, CLAUDE.md loader, .kit.toml, .claude/settings.json hooks.

11. **lib/stats/src/stats/memory_lens.py** — Memory audit lens; reads .claude/memory/*.md; dedup + age scoring.

12. **lib/plugin-check/bin/plugin-check** (482 lines) — Plugin freshness via CLI-owned state files; verdict logic (sha > version); dry-run + --apply split.

