# Spec: estate seams
Generated: 2026-09-07
Status: DRAFT
References: `lib/config/module-registry.md` §wrap and §precedent (the existing `[consumer]` key rows; every seam row below is the same shape plus a kind and a filler); `lib/config/config.sh` `cmd_list` (the column-report style `config seams` imitates); `lib/classify/significance-classify.sh record` (the one writer of a run's DEBT marker; the wrap step calls it, never `gate-ledger.sh debt` directly); `lib/learn/staging-format.py render` (the one staging-block renderer; `wrap stage` feeds it JSON on stdin); `commands/wrap.md` Step -1 (the pattern for a step that reads a root-only key and degrades to a one-line "skipped" when empty).

## Problem

The estate is three kits that each install alone. dwarves-kit is the process plane (gates, lanes, ledger, review fleets, the landing step). context-kit is the data plane (the context tree and recall over it). learning-kit is a study overlay on the engine. The install dependency points at the engine: both overlays require dwarves-kit >= 2.0. The data flow points the other way: every kit writes knowledge into the context tree. Those two directions must stay separate, and the only thing the engine may know about an overlay is a config key the overlay fills.

Three hand-offs are implicit or backwards today:

1. `/kit:wrap` runs an operator skill through `wrap.before` that writes the run's DEBT marker into this kit's gate ledger and gates new-tool candidates through `precedent`. Both are process-plane work done from outside the kit, so a dwarves-kit-only operator never gets them.
2. Nothing tells the engine where the context tree lives. A knowledge writer at wrap time files a memory note wherever the model guesses.
3. No surface lists the cross-kit seams. `config list` renders every `[consumer]` key as "inert, no live effect", which is false for `wrap.before` (the command runs whatever it names).

## Solution

### Approaches considered

1. **Named seams in the existing registry + one report verb.** Add a `### seams` table to `lib/config/module-registry.md`, a `[knowledge] root` key, a `config seams` verb that resolves each row and checks the target, and two `wrap` verbs the command uses for the process half of distill. Tradeoff: the seam list is prose in a markdown table, so a new seam is a doc edit plus a lint, not a schema.
2. **Per-kit manifest (`kit-manifest.toml` with `provides`/`wants`) and a resolver.** Tradeoff: a new file format across three repos, version negotiation, and nobody maintains a manifest that no command reads daily. ID-396 chose "standalone tool + thin adapter", which needs no manifest.
3. **Bundle context-kit with dwarves-kit.** Tradeoff: inverts the install dependency (context-kit already needs the engine), drags a Rust binary and a personal tree onto a user who asked for a dev loop.

### Chosen approach + why

Approach 1. Every existing seam (`wrap.before`, `wrap.activity_log`, `precedent.registry`) already follows one rule: a key in the operator `kit.toml`, read with `kit_config_get_root`, never from a project `.kit.toml`. Naming that rule and giving it a report costs one config key, one table, one verb, and prose. Approaches 2 and 3 trade the standalone-first doctrine for machinery.

### Extensibility & boundaries

- The load-bearing dimension is the number of seams. A fourth kit adds rows to one table; `config seams` and the registry lint pick them up with no code change. A new kind (beyond `skill|file|dir|binary`) is one case branch in `_seam_resolve`.
- Units: the registry table (data), `config seams` (read-only report over it), `wrap knowledge-root` (one resolver with the fallback rule), `wrap stage` (one writer over the shared renderer), the command prose (calls the verbs). Each is testable alone.

### Architecture

See `## Design`.

## Picture

```
 operator kit.toml                 lib/config/module-registry.md
 ┌──────────────────────┐          ┌─────────────────────────────────┐
 │ [wrap] before        │          │ ### seams                       │
 │ [wrap] activity_log  │          │ key | kind | default | filled by│
 │ [precedent] registry │──read──▶ │ wrap.before  skill  learning-kit│
 │ [knowledge] root     │          │ knowledge.root dir  context-kit │
 └──────────────────────┘          │ prose-rag binary    context-kit │
        ▲   kit_config_get_root    └──────────────┬──────────────────┘
        │   (never a project toml)                │
        │                                         ▼
 overlays fill keys                      bin/config seams
 (context-kit `ctx adopt`,               KEY KIND VALUE STATUS FILLED-BY
  learning-kit install)                  status: default|filled|unresolved

 /kit:wrap
 ├─ Step -1  wrap.before skill            (overlay flush: concepts, til)
 ├─ Step 0..6 unchanged
 ├─ Step 7  learn (NEW, process half)
 │    a. DEBT marker  ── significance-classify.sh record <rid>
 │    b. candidates   ── precedent find --surface inventory --quiet
 │                       └─ no hit ─▶ bin/wrap stage ─▶ <repo>/_meta/backlog-staging.md
 │    c. incidents    ── bin/wrap knowledge-root <repo> ─▶ one memory note
 │                       root filled+resolves ─▶ <root>/projects/<repo>/
 │                       else ─▶ <repo>/.claude/memory/
 ├─ Step 8  reflect (was 7)
 └─ Step 9  report  (was 8)
```

## Design

### Approaches considered + chosen

See `## Solution`. One new tradeoff surfaced here: the seam table could live in `kit.toml` comments instead of the registry, but `config.sh` already parses the registry's markdown tables line by line and `test-config-registry.sh` already lints them, so the registry is the cheaper home.

### Diagram

```
sequence: /kit:wrap Step 7 (learn)

 command          wrap.sh                 classify/            precedent        staging-format.py
   │                │                        │                    │                    │
   │ has DEBT line for <rid>? (grep runs/<rid>.log)               │                    │
   │──no──▶ significance-classify.sh record <rid> "<desc>" ───────▶│                    │
   │◀── verdict ────│                        │                    │                    │
   │ for each candidate procedure/script:    │                    │                    │
   │──▶ precedent find --surface inventory --quiet "<words>" ─────▶│                    │
   │◀── hit? ───────────────────────────────────────────────────────│                    │
   │──no hit──▶ wrap stage "<title>" "<intent>" "<home>" ──▶ render (stdin JSON) ───────▶│
   │            append block to <repo>/_meta/backlog-staging.md    │                    │
   │ for each incident with own-mistake root cause:                │                    │
   │──▶ wrap knowledge-root <repo>  ──▶ kit_config_get_root knowledge.root              │
   │◀── dir (root/projects/<repo> | <repo>/.claude/memory)          │                    │
   │ write one note + index line                                   │                    │
```

### ADR link(s)

ADR-0034 (bin/<sub> <verb> shims, one registry file) and the standalone-first doctrine row ID-396. No irreversible decision: every piece is a config key or a read-only report; removing the key restores today's behaviour.

### Boundaries & failure modes

Out of bounds: the til or memo publish leg, concept flush, research notes (all stay behind `wrap.before`); the vendored prose-rag crate (ID-647); any change inside context-kit or learning-kit. Failure classes: `## Failure modes`.

## Technical Design

### Interfaces (I/O contract)

**`[knowledge] root`** (kit-root `kit.toml`, operator override). String, default `""`. Resolved only with `kit_config_get_root knowledge.root ""`. `~` expands. Empty means repo-local knowledge. A filled value names the context tree root; repo knowledge files under `<root>/projects/<repo-basename>/`.

**`### seams` table** in `lib/config/module-registry.md`, columns `| Key | Kind | Default | Filled by | Reader | Description |`. `Key` is `section.key` or `-` for a non-TOML seam; `Kind` is one of `skill|file|dir|binary`; for `binary` the `Default` cell names the binary and the env override (`prose-rag`, `PROSE_RAG_BIN`). Rows at v1: `wrap.before` (skill, learning-kit or operator), `wrap.activity_log` (file, operator), `precedent.registry` (file, operator), `knowledge.root` (dir, context-kit), `-`/`prose-rag` (binary, context-kit).

**`bin/config seams`**: prints a header row then one row per seam: `KEY KIND VALUE STATUS FILLED-BY`. `VALUE` is the resolved value (operator > kit-root; `(empty)` marker when empty; for `binary` the resolved path or `(not on PATH)`). `STATUS` is `default` (value equals the default), `filled` (non-default and the target resolves), `unresolved` (non-default and the target does not resolve: skill dir missing, path missing, binary absent). A skill resolves when `<dir>/<name>/SKILL.md` exists for any `<dir>` in `${KIT_SKILL_DIRS:-$HOME/.claude/skills:$CLAUDE_PLUGIN_ROOT/skills}` (colon list). Exit 0 always; a missing registry file fails like the other verbs. A project `.kit.toml` never affects any row.

**`bin/wrap knowledge-root <repo>`**: prints one absolute directory. `knowledge.root` filled and the directory exists → `<root>/projects/<basename of repo>` (created on demand, `mkdir -p`); else `<repo>/.claude/memory`. Second line on stderr when it fell back from a filled but missing root: `knowledge-root: <root> does not exist, using <repo>/.claude/memory`. Exit 0 on either branch; exit 64 with usage when `<repo>` is missing or not a directory.

**`bin/wrap stage "<title>" "<intent>" "<home>" [--repo <repo>]`**: renders one staging block through `lib/learn/staging-format.py render` (`u=lo`, `f=mid`, `source=session <today>`), appends it to `<repo>/_meta/backlog-staging.md` (`--repo` defaults to the current git toplevel), creates the file with a one-line header when absent, prints the block's title line. A title already present in that file (case-insensitive, whitespace-collapsed match on the `## [` head) is not appended twice; the verb prints `stage: already staged: <title>` and exits 0. Write failure → `FAILED` line and exit 2 (same contract as `wrap log`).

**Invariants:** no seam key is ever read from a project `.kit.toml`. `config seams` never writes. `wrap stage` writes only the staging file, never a board. `wrap knowledge-root` creates directories only under a filled, existing root.

### Data model changes

- `kit.toml`: new `[knowledge]` section with `root = ""` and a comment block in the same voice as `[wrap]`.
- `lib/config/module-registry.md`: new `### knowledge` key section (one row, `[consumer]`, module `wrap`) and the new `### seams` table.

### API changes

`bin/config seams`, `bin/wrap knowledge-root`, `bin/wrap stage` as above. `commands/wrap.md` Step 7 `learn`; reflect and report renumber to 8 and 9 (or stay `7`/`8` with the new step as `6b` if `tests/test-meta.sh` or `tests/test-wrap.sh` pins the numbers; the implementer checks with `grep -rn "Step 7\|Step 8" tests/`).

### UI changes

None.

### Infrastructure changes

None.

## Task Breakdown

### Phase 1: Foundation

- [ ] TASK-001: `[knowledge] root` key and the seam table. Add the `[knowledge]` section to `kit.toml`; add the `### knowledge` row section and the `### seams` table to `lib/config/module-registry.md`; extend `tests/test-config-registry.sh` with two lints: every `### seams` row whose `Key` is not `-` has a matching key row elsewhere in the registry, and every seam `Kind` is one of the four. Acceptance: `bash tests/test-config-registry.sh` green; `. lib/config/kit-config.sh && kit_config_get_root knowledge.root ""` prints empty on a clean checkout and the operator value when `KIT_CONFIG_OPERATOR` points at a fixture with `[knowledge] root = "/tmp/x"`; a project `.kit.toml` with `[knowledge] root` is ignored by `kit_config_get_root` (existing root-only test pattern, one new case).

### Phase 2: Core

- [ ] TASK-002: `config seams` verb in `lib/config/config.sh` (`_seam_rows`, `_seam_resolve`, `cmd_seams`), usage line, `bin/config` header. Tests in a new `tests/test-config-seams.sh` (fixture registry + fixture operator toml + `KIT_SKILL_DIRS` + a temp PATH): all-default report, a filled skill that resolves, a filled skill that does not (`unresolved`), a filled dir that resolves, a filled dir that does not, binary present vs absent via `PROSE_RAG_BIN` and PATH, a project `.kit.toml` value that must not appear, missing registry fails non-zero. Register the test in `.github/workflows/test.yml` so `tests/run-workflow.sh` discovers it. Acceptance: the new test file green; `bash bin/config seams` on this checkout prints five rows.
- [ ] TASK-003: `wrap knowledge-root` and `wrap stage` in `lib/wrap/wrap.sh` plus `bin/wrap` usage. Cases in `tests/test-wrap.sh`: knowledge-root empty key → `<repo>/.claude/memory`; filled and existing → `<root>/projects/<basename>` created; filled and missing → fallback plus the stderr line; missing repo arg → exit 64. stage: creates the file with header, appends a block the shared parser reads back (`staging-format.py parse` returns one block with the title, `Home`, `Source: session <date>`), a second call with the same title (different case, extra spaces) appends nothing and prints `already staged`, `--repo` targets another checkout, unwritable target → `FAILED` + exit 2. Acceptance: `bash tests/test-wrap.sh` green including the new cases.

### Phase 3: Polish

- [ ] TASK-004: command prose and docs. `commands/wrap.md`: new Step 7 `learn` (a. DEBT marker via `significance-classify.sh record <rid> "<one-line session description>"` only when `runs/<rid>.log` has no `| DEBT |` line, and only when the session had a run id; b. candidates through `bin/precedent find --surface inventory --quiet` then `bin/wrap stage` on no hit, the hit path reported as an FYI bullet; c. incidents with an own-mistake `## Root cause` → one note under `bin/wrap knowledge-root <repo>` plus the `MEMORY.md` index line; each sub-step prints one `skipped: <why>` line when it has nothing), renumber reflect/report, and one report bullet rule: a staged candidate or a filed note is an `FYI` bullet naming the file. `commands/onboard.md` and `commands/adopt.md`: a short "Overlays and seams" section (context-kit fills `knowledge.root` and the `prose-rag` binary; learning-kit fills `wrap.before` with its concept flush; none is required; `bin/config seams` shows the state). `kit.toml` comments. `docs/FEATURES.md` regenerated. `docs/verification/estate-seams.md` proof of done (`## Green run` with uppercase PASS, negative control, reproduce). Acceptance: `bash tests/test-meta.sh` green (FEATURES freshness, no personal paths, step-number scans), `bash tests/test-no-personal-paths.sh` green, the wrap step reads as a contractor could follow it.

## After state

- [ ] `bash bin/config seams` prints five rows with `STATUS` in `default|filled|unresolved`. (Today: no such verb; `config list` calls `wrap.before` inert.)
- [ ] `grep -n '^\[knowledge\]' kit.toml` finds the section; `grep -c '^| knowledge.root' lib/config/module-registry.md` is 1. (Today: no key.)
- [ ] `bash bin/wrap knowledge-root .` prints `<cwd>/.claude/memory` with the key empty, and `<root>/projects/<basename>` with it filled. (Today: no such verb.)
- [ ] `bash bin/wrap stage t i h` appends one block that `python3 lib/learn/staging-format.py parse _meta/backlog-staging.md` reads back. (Today: only the harvest hook writes blocks.)
- [ ] `grep -n 'Step 7: learn' commands/wrap.md` hits and the step names `significance-classify.sh record`, `precedent find --surface inventory --quiet`, `wrap stage`, `wrap knowledge-root`. (Today: the DEBT and candidate steps live in an operator skill.)
- [ ] `grep -n -i 'overlays and seams' commands/onboard.md commands/adopt.md` hits both. (Today: neither mentions an overlay.)

## Acceptance Criteria (global)

- [ ] All tasks pass their individual acceptance criteria
- [ ] Tests cover happy path + edge cases listed below
- [ ] No regressions in existing functionality

## Verification

```
bash tests/test-config-registry.sh && bash tests/test-config-seams.sh && bash tests/test-config.sh && bash tests/test-wrap.sh && bash tests/test-meta.sh && bash tests/test-no-personal-paths.sh
```

## Edge Cases

1. Operator with only dwarves-kit: every seam row `default`; wrap Step 7c files under `<repo>/.claude/memory/`; no step asks for an overlay.
2. `knowledge.root` filled, directory exists: `knowledge-root` prints `<root>/projects/<basename>` and creates it; `config seams` says `filled`.
3. `knowledge.root` filled, directory missing: `config seams` says `unresolved`; `knowledge-root` falls back to repo-local and prints the stderr line; wrap's report carries the fallback as an FYI bullet.
4. `knowledge.root` set in a project `.kit.toml` only: ignored by `kit_config_get_root`, absent from `config seams`, and the test pins it.
5. `knowledge.root` value with `~`: expanded before the existence check (same helper `wrap.activity_log` uses).
6. `wrap.before` names a skill with no `SKILL.md` under any `KIT_SKILL_DIRS` entry: `unresolved`; `/kit:wrap` Step -1 already reports a skill that fails to run.
7. `prose-rag` absent from PATH and `PROSE_RAG_BIN` unset: `unresolved`, `VALUE` = `(not on PATH)`; nothing else changes (recall was optional already).
8. `PROSE_RAG_BIN` set to a non-executable path: `unresolved`.
9. Session with no run id (no gate ledger run): Step 7a prints `skipped: no run id` and does not call the classifier.
10. Run ledger already has a `| DEBT |` line for the rid: Step 7a prints `skipped: DEBT marker present` (the gate wrote it during the run).
11. Candidate words hit an existing tool in the inventory: no staging row; the report's FYI names the existing tool from the `--quiet` summary line.
12. `wrap stage` with an existing title differing only in case or spacing: no second block; `already staged` printed; exit 0.
13. `wrap stage` in a repo with no `_meta/`: creates `_meta/backlog-staging.md` with the header; prints the title.
14. `wrap stage --repo` pointing at a non-git directory: exit 64 with usage.
15. Staging file not writable: `FAILED` line, exit 2, nothing partial written (render to a temp string first, append once).
16. Registry file missing: `config seams` exits non-zero like `config list` (no header-only success).
17. A seam row with an unknown `Kind`: `test-config-registry.sh` fails; `config seams` prints `unresolved` with `VALUE` = `(unknown kind)` rather than aborting the report.
18. Two `KIT_SKILL_DIRS` entries, the skill in the second: `filled`.
19. `CLAUDE_PLUGIN_ROOT` unset: the default skill dir list degrades to `$HOME/.claude/skills` only, no error.
20. Incident file with an empty `## Root cause`: Step 7c writes nothing and says so; it never invents a note.

## Failure modes

| Failure class | Detection signal | Mitigation / recovery |
|---|---|---|
| Knowledge note filed in the wrong tree (root moved after the note) | `config seams` shows `unresolved`; `memory-tidy` audit finds the orphan | Fallback is always repo-local; the operator moves the note by hand; no data loss |
| Staging file corrupted by a partial append | `staging-format.py parse` fails on the file | `wrap stage` renders first, appends in one write, exits 2 on failure |
| DEBT marker written twice for one rid | two `\| DEBT \|` lines in `runs/<rid>.log` | Step 7a checks for an existing line first; `weekend-batch.sh` reads the last line, so a duplicate is harmless |
| Seam row drifts from the key row (renamed key) | `test-config-registry.sh` lint red | Fix the row; the lint names the key |

## Out of Scope

- Retiring the vendored prose-rag crate (ID-647).
- A per-kit manifest format or version negotiation; the seam table is the mechanism.
- Any engine writer for the til, memo, or concept-flush legs; they stay behind `wrap.before`.
- Edits to context-kit or learning-kit (their own rows follow once the key name is fixed by this spec).
- `config set`; keys stay hand-edited.

## Touches

- lib/config/**
- lib/wrap/**
- commands/**
- tests/**
- docs/specs/**
- docs/verification/**

## Decision Log

- DEC-001: seam report lives on `bin/config` as `seams`, not on `plugin-check`; `plugin-check` manages Claude plugins and its `status`/`update` verbs have nothing to do with kit config, while `config.sh` already parses the registry tables. Rejected: `plugin-check --seams` (the brief's first name), a new `bin/seams` shim (one more binary for one verb).
- DEC-002: the DEBT marker comes from `significance-classify.sh record`, the existing classifier and writer, not from a raw `gate-ledger.sh debt` call with values the command would have to invent. Rejected: hard-coding `significance=high worthiness=high` for every batch session (turns every wrap into a tap, the anti-fatigue design in ADR-0031 forbids that).
- DEC-003: `knowledge.root` empty means repo-local `.claude/memory`, the layout `stats memory-sweep` and `memory-tidy` already read, so a dwarves-kit-only install changes nothing. Rejected: a kit-owned default tree under XDG (a second knowledge store nobody asked for).
- DEC-004: seam kinds are `skill|file|dir|binary`, resolved by existence only; no version check. Rejected: floor/version negotiation (ID-396 says standalone tool + thin adapter; the adapter's own probe is the version check).
- DEC-005: the `learn` step is one numbered step with three lettered sub-steps that each print `skipped: <why>` when idle, mirroring Step -1's empty-key behaviour, so the report never goes silent on a step that did nothing.

## Open questions

(none; a /goal loop appends here if it hits a decision this spec does not cover, then stops)
