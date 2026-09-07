# Spec: estate seams
Generated: 2026-09-07
Status: VALIDATED
References: `lib/config/module-registry.md` §wrap and §precedent (the existing `[consumer]` key rows; a seam is one of those rows plus a kind and a filler); `lib/config/config.sh` `cmd_list` (the column-report style `config seams` imitates) and `_registry_rows` (the parser window the seam table must stay OUT of); `lib/wrap/wrap.sh` `cmd_log` (the `_realpath_f` + HOME fence + `_worktree_copy` + `_write_guard` chain every wrap writer runs); `lib/classify/significance-classify.sh record` (the one writer of a run's DEBT marker); `lib/learn/staging-format.py` `norm`, `existing_keys`, `render_block` (the one dedupe rule and the one block grammar; the new `stage` verb composes them); `commands/wrap.md` Step -1 (a step that reads a root-only key and prints one "skipped" line when empty).

## Problem

The estate is three kits that each install alone. dwarves-kit is the process plane (gates, lanes, ledger, review fleets, the landing step). context-kit is the data plane (the context tree and recall over it). learning-kit is a study overlay on the engine. The install dependency points at the engine: both overlays require dwarves-kit >= 2.0. The data flow points the other way: every kit writes knowledge into the context tree. Those two directions must stay separate, and the only thing the engine may know about an overlay is a config key the overlay fills.

Three hand-offs are implicit or backwards today:

1. `/kit:wrap` runs an operator skill through `wrap.before` that writes the run's DEBT marker into this kit's gate ledger and gates new-tool candidates through `precedent`. Both are process-plane work done from outside the kit, so a dwarves-kit-only operator never gets them.
2. Nothing tells the engine where the context tree lives. A knowledge writer at wrap time files a memory note wherever the model guesses.
3. No surface lists the cross-kit seams. `config list` renders every `[consumer]` key as "inert, no live effect", which is false for `wrap.before` (the command runs whatever it names).

## Solution

### Approaches considered

1. **Named seams in the existing registry + one report verb.** A `[knowledge] root` key, a three-column join table (`## Seams`) that tags existing registry rows with a kind and a filler, a `config seams` verb that resolves each row and checks its target, and a `stage` verb on the shared staging module the wrap command uses for the process half of distill. Tradeoff: the seam list is a markdown table, so a new seam is a doc edit plus a lint, not a schema.
2. **Per-kit manifest (`kit-manifest.toml` with `provides`/`wants`) and a resolver.** Tradeoff: a new file format across three repos, version negotiation, and nobody maintains a manifest no command reads daily. ID-396 chose "standalone tool + thin adapter", which needs no manifest.
3. **Bundle context-kit with dwarves-kit.** Tradeoff: inverts the install dependency (context-kit already needs the engine), drags a Rust binary and a personal tree onto a user who asked for a dev loop.

### Chosen approach + why

Approach 1. Every existing seam (`wrap.before`, `wrap.activity_log`, `precedent.registry`) already follows one rule: a key in the operator `kit.toml`, read with `kit_config_get_root`, never from a project `.kit.toml`. Naming that rule and giving it a report costs one config key, one join table, one verb, and prose. Approaches 2 and 3 trade the standalone-first doctrine for machinery.

North star (PHILOSOPHY §6): serves N4, modularity, every seam resolves with zero overlays present. Touches N5: Step 7 is an unattended writer at wrap time; its only sinks are the staging buffer (the human gate) and one memory note under a fenced root.

### Extensibility & boundaries

- The load-bearing dimension is the number of seams. A fourth kit adds rows to one table; `config seams` and the registry lint pick them up with no code change. A new kind beyond `skill|file|dir|binary` is one case branch in `_seam_resolve`. At twenty rows the report stays one flat table ordered as the registry orders them; `--check` gives an installer a boolean without parsing columns.
- Units: the join table (data), `config seams` (read-only report over it), `staging-format.py stage` (the one staging writer), `wrap knowledge-root` (one resolver with the fallback rule and the write fence), `wrap stage` (path resolution + fences, then the python writer), the command prose (calls the verbs). Each is testable alone.

### Architecture

See `## Design`.

## Picture

```
 operator kit.toml                 lib/config/module-registry.md
 ┌──────────────────────┐          ┌────────────────────────────────────┐
 │ [wrap] before        │          │ ## Env <-> key registry (parser    │
 │ [wrap] activity_log  │          │   window: existing key rows, plus  │
 │ [precedent] registry │──read──▶ │   knowledge.root, PROSE_RAG_BIN,   │
 │ [knowledge] root     │          │   KIT_SKILL_DIRS)                  │
 └──────────────────────┘          │ ## Allowlist                       │
        ▲   kit_config_get_root    │ ## Seams  (OUTSIDE the window)     │
        │   (never a project toml) │   key | kind | filled by           │
        │                          └───────────────┬────────────────────┘
 overlays fill keys                                ▼
 (context-kit `ctx adopt`,                bin/config seams [--check]
  learning-kit install)                   KEY KIND VALUE STATUS FILLED-BY
                                          default|filled|unresolved|absent

 /kit:wrap
 ├─ Step -1  wrap.before skill            (overlay flush: concepts, til)
 ├─ Step 0..6 unchanged
 ├─ Step 7  learn (NEW, process half)
 │    a. DEBT marker  ── rid from gate-ledger.sh rid; runs/<rid>.log has no DEBT
 │                       └─▶ significance-classify.sh record <rid>
 │    b. candidates   ── precedent find --surface inventory --json
 │                       └─ nothing_matched ─▶ bin/wrap stage
 │                            └─▶ staging-format.py stage ─▶ <repo>/_meta/backlog-staging.md
 │    c. incidents    ── bin/wrap knowledge-root <repo> ─▶ one memory note (idempotent)
 │                       root filled, under HOME, exists ─▶ <root>/projects/<repo>/
 │                       else ─▶ <repo>/.claude/memory/
 ├─ Step 8  reflect (was 7)
 └─ Step 9  report  (was 8)
```

## Design

### Approaches considered + chosen

See `## Solution`. Two tradeoffs surfaced in review and are recorded in DEC-006 and DEC-007: the seam table is a join table outside the registry parser's window (a sibling `###` table would inject fake rows into `config list`), and the staging writer lives in the python module that already owns the grammar and the dedupe key, so bash never grows a second copy of either.

### Diagram

```
sequence: /kit:wrap Step 7 (learn)

 command        gate-ledger      classify/          precedent        wrap.sh            staging-format.py
   │                │                │                  │                │                     │
   │─ rid ─────────▶│                │                  │                │                     │
   │◀─ <rid> or "" ─│                │                  │                │                     │
   │ "" or no runs/<rid>.log or a DEBT line present ─▶ print skipped, go to b               │
   │─ record <rid> "<desc>" ────────▶│                  │                │                     │
   │◀─ verdict | rc≠0 ⇒ skipped: classifier failed (rc) │                │                     │
   │ for each candidate:             │                  │                │                     │
   │─ find --surface inventory --json "<words>" ───────▶│                │                     │
   │◀─ nothing_matched / top hit ─────────────────────── │                │                     │
   │─ nothing_matched ⇒ stage "<title>" "<intent>" "<home>" ────────────▶│                     │
   │                                 │  resolve repo realpath, staging path, fences, worktree copy, write guard
   │                                 │                  │                │─ stage (stdin JSON) ▶│
   │                                 │                  │                │◀ title | already staged
   │ for each incident with an own-mistake root cause:  │                │                     │
   │─ knowledge-root <repo> ────────────────────────────────────────────▶│                     │
   │◀─ dir (fenced root/projects/<repo> | <repo>/.claude/memory) ────────│                     │
   │ note already names the incident? ⇒ skipped; else write one note + index line             │
```

### ADR link(s)

ADR-0034 (bin/<sub> <verb> shims, one registry file, one grammar per artifact) and the standalone-first doctrine row ID-396. No irreversible decision: every piece is a config key, a read-only report, or a verb with a fallback; removing the key restores today's behaviour.

### Boundaries & failure modes

Out of bounds: the til or memo publish leg, concept flush, research notes (all stay behind `wrap.before`); the vendored prose-rag crate (ID-647); any change inside context-kit or learning-kit; the `config list` "inert" render for `[consumer]` rows. Failure classes: `## Failure modes`.

## Technical Design

### Interfaces (I/O contract)

**`[knowledge] root`** (kit-root `kit.toml`, operator override). String, default `""`. Resolved only with `kit_config_get_root knowledge.root ""`. `~` expands by the same rule `wrap.activity_log` uses. Empty means repo-local knowledge. A filled value names the context tree root; repo knowledge files under `<root>/projects/<repo-basename>/`.

**Registry rows added** (inside the parser window, in the existing six-column shape): `knowledge.root` under a new `### knowledge` section (`[consumer]`, module `wrap`); `PROSE_RAG_BIN` (env-only, default `prose-rag` on PATH, `[consumer]`, module `prose_rag`); `KIT_SKILL_DIRS` (env-only, default `$HOME/.claude/skills` plus `${CLAUDE_PLUGIN_ROOT:-}/skills` when set, `[consumer]`, module `wrap`). The AC1 drift lint sees every new `KIT_` read under `lib/` registered.

**`## Seams` table**: a new top-level heading placed AFTER `## Allowlist` (so `_registry_rows`, which stops at `## Allowlist`, never sees it). Columns `| Key | Kind | Filled by |`. `Key` is the `section.key` or env var name of an existing registry row; `Kind` is one of `skill|file|dir|binary`; `Filled by` is free text naming the overlay or "operator". Rows at v1: `wrap.before` skill (learning-kit or operator), `wrap.activity_log` file (operator), `precedent.registry` file (operator), `knowledge.root` dir (context-kit), `PROSE_RAG_BIN` binary (context-kit). Default, module, and description come from the joined registry row, never repeated here.

**`bin/config seams [--check]`**: header then one row per seam: `KEY KIND VALUE STATUS FILLED-BY`. Resolution never touches a project `.kit.toml`: a `section.key` resolves with `kit_config_get_root` only; an env-only key reads `${VAR:-}`. `VALUE` is the resolved value, `(empty)` when empty, the resolved executable path for `binary`. `STATUS`: `default` (value empty or equal to the registry default and the kind is not `binary`), `filled` (non-default and the target resolves), `unresolved` (non-default and the target does not resolve; also a malformed row with fewer than three cells, `VALUE` `(malformed row)`; also an unknown kind, `VALUE` `(unknown kind)`), `absent` (`binary` kind with the env var unset and nothing on PATH: the overlay is simply not installed). Target checks: `skill` → `<dir>/<name>/SKILL.md` exists for some `<dir>` in the skill dir list, where `KIT_SKILL_DIRS` entries are kept only when their realpath sits under `$HOME` and the default list is `$HOME/.claude/skills` plus `${CLAUDE_PLUGIN_ROOT:-}/skills` when that variable is set (no unbound expansion under `set -u`); `file` → after `~` expansion, an existing regular file; `dir` → an existing directory; `binary` → `${VAR:-}` if set must be executable, else `command -v <default name>`. The verb never executes a target. Exit 0 for any row state; with `--check`, exit 1 when any row is `unresolved`; exit 1 when the registry file is missing (same as `config list`). Output carries operator paths, so the proof doc runs it against a fixture operator toml.

**`python3 lib/learn/staging-format.py stage`**: reads one JSON object on stdin: `title`, `intent`, `home`, `staging` (absolute path of the staging file), `backlog` (absolute path of the board file, may be missing). Computes the key with `norm(title)`, builds `existing_keys(("staging", staging), ("board", backlog))`, and if the key is present prints `stage: already staged: <title>` and exits 0. Otherwise renders one block with `render_block` (`u=lo`, `f=mid`, `source=session <today>`), creates the file with a one-line header when absent, appends the block in ONE write, prints the block's `## [staged] <title>` line, exits 0. An unwritable target prints `FAILED: <reason>` and exits 2 with nothing partial written. The dedupe check runs inside the same process immediately before the append.

**`bin/wrap stage "<title>" "<intent>" "<home>" [--repo <repo>]`**: `<repo>` defaults to the current git toplevel; a non-git directory exits 64 with usage. Staging path is `$BACKLOG_STAGE_STAGING` when set, else `<repo>/_meta/backlog-staging.md`; board path is `$BACKLOG_STAGE_BACKLOG` when set, else `<repo>/_meta/BACKLOG.md`. Fences before any write: the staging path's parent resolves through `_realpath_f`; the target is absent or an existing regular file, never a symlink; the resolved path sits inside the repo toplevel's realpath, or under `$HOME` when the env override chose it; then `_worktree_copy` and `_write_guard` exactly as `cmd_log` does. Then it shells out to the python `stage` verb and relays its stdout and exit code. Fence failure prints `wrap stage: <reason>` and exits 1.

**`bin/wrap knowledge-root <repo>`**: prints one absolute directory and exits 0 on either branch. Repo: `<repo>` must exist; it is resolved with `cd && pwd -P`; a basename of `.`, `..`, or empty exits 64. Root: `kit_config_get_root knowledge.root ""` with `~` expanded; empty → `<repo>/.claude/memory`. Filled → the root resolves through `_realpath_f`, must sit under `$HOME`'s realpath, and must be an existing directory; then `<root>/projects/<basename>` is created with `mkdir -p`. Any of those failing (missing, outside HOME, a symlink that resolves elsewhere, `mkdir` refused) prints `knowledge-root: <reason>, using <repo>/.claude/memory` on stderr and prints the repo-local path. Missing argument exits 64 with usage.

**Invariants:** no seam key is ever read from a project `.kit.toml`, and `config seams` never calls `_resolve`. `config seams` never writes and never executes a seam target. One staging dedupe rule exists (`norm` + `existing_keys`), one block grammar (`render_block`), and bash holds neither. Every wrap writer runs `_realpath_f`, the HOME fence, `_worktree_copy`, `_write_guard`. `wrap stage` writes only the staging file, never a board. `wrap knowledge-root` creates directories only under a filled, fenced, existing root.

### Data model changes

- `kit.toml`: new `[knowledge]` section, `root = ""`, comment block in the `[wrap]` voice (all of it in TASK-001).
- `lib/config/module-registry.md`: three new key rows inside the window; the new `## Seams` join table after `## Allowlist`.

### API changes

`bin/config seams [--check]`, `staging-format.py stage`, `bin/wrap stage`, `bin/wrap knowledge-root` as above. `commands/wrap.md` gains Step 7 `learn`; reflect and report renumber to 8 and 9 (nothing under `tests/` pins the wrap step numbers: `grep -rn "Step 7\|Step 8" tests/` hits only `ship.md` assertions); the prose "each of the eight steps" (line 7) and "step 8's report" (line 35) update with them.

### UI changes

None.

### Infrastructure changes

None.

## Task Breakdown

### Phase 1: Foundation

- [ ] TASK-001: registry and key. Add `[knowledge] root = ""` with its comment block to `kit.toml`; add the three registry rows inside the window and the `## Seams` table after `## Allowlist` in `lib/config/module-registry.md`; extend `tests/test-config-registry.sh` with three lints: every `## Seams` row's `Key` matches a registry row, every `Kind` is one of the four, and the count of `_registry_rows` is unchanged by the seam table (assert the table's keys do not appear in `config list` output twice). Acceptance: `bash tests/test-config-registry.sh` green; `kit_config_get_root knowledge.root ""` prints empty on a clean checkout and the operator value when `KIT_CONFIG_OPERATOR` points at a fixture with `[knowledge] root = "/tmp/x"`; a project `.kit.toml` `[knowledge] root` is ignored (one new case in `tests/test-config.sh` on the existing root-only pattern).

### Phase 2: Core

- [ ] TASK-002: `config seams` in `lib/config/config.sh` (`_seam_rows` reading between `## Seams` and end of file, `_seam_resolve`, `cmd_seams`), usage line, `bin/config` header. New `tests/test-config-seams.sh` with a fixture registry, fixture operator toml, a temp `HOME`, `KIT_SKILL_DIRS`, and a temp PATH: all-default report; skill filled and resolving; skill filled and missing (`unresolved`); a `KIT_SKILL_DIRS` entry outside HOME ignored; dir filled and existing; dir filled and missing; binary absent (`absent`); `PROSE_RAG_BIN` set to a non-executable (`unresolved`); binary on PATH (`filled`); a project `.kit.toml` value that must not appear; malformed row; unknown kind; `--check` exit 1 on unresolved and 0 otherwise; missing registry exits 1; `CLAUDE_PLUGIN_ROOT` unset does not abort. Register the file in `.github/workflows/test.yml`. Depends on TASK-001. Acceptance: the new test green; `bash bin/config seams` on this checkout prints five rows.
- [ ] TASK-003: `stage` verb in `lib/learn/staging-format.py` per the interface, plus a `tests/test-staging-stage.sh` (or cases in the existing staging test if one exists): creates the file with header; appends a block `parse` reads back with `Home` and `Source: session <date>`; same title in different case, spacing, or punctuation appends nothing and prints `already staged`; a title already on the board file is refused the same way; unwritable target prints `FAILED` and exits 2 with the file unchanged. Register the test. Acceptance: the test green; `python3 lib/learn/staging-format.py` usage line lists `stage`.
- [ ] TASK-004: `wrap knowledge-root` and `wrap stage` in `lib/wrap/wrap.sh` plus `bin/wrap` usage. Cases in `tests/test-wrap.sh`: knowledge-root with the key empty → `<repo>/.claude/memory`; filled, under HOME, existing → `<root>/projects/<basename>` created; filled but missing → fallback plus the stderr line; filled but outside HOME (temp dir outside the test HOME) → fallback; root a symlink resolving outside HOME → fallback; repo arg ending in `..` → exit 64; missing arg → 64. stage: default paths from the repo toplevel; `BACKLOG_STAGE_STAGING` honoured; a symlinked staging file refused (exit 1, nothing written); a target outside the repo refused; from a worktree the worktree's copy is written (`_worktree_copy`); relays `already staged` and the `FAILED` exit 2 from python; non-git `--repo` → 64. Depends on TASK-003. Acceptance: `bash tests/test-wrap.sh` green including the new cases.

### Phase 3: Polish

- [ ] TASK-005: `commands/wrap.md` Step 7 `learn` and the proof doc. Step 7: a. rid via `bash lib/gate/gate-ledger.sh rid`; log dir via `bash lib/telemetry/kit-log-dir.sh`; skip with `skipped: no run id`, `skipped: no run log`, or `skipped: DEBT marker present`; else `bash lib/classify/significance-classify.sh record <rid> "<one-line session description>"`, and a non-zero rc prints `skipped: classifier failed (rc N)` and continues. b. for each candidate (a procedure run three or more times this session, or a script the operator called recurring): `bin/precedent find --surface inventory --json "<two or three words>"`; `nothing_matched` true → `bin/wrap stage "<title>" "<intent>" "<repo>"`; false → an FYI bullet quoting the top hit line, no row. c. for each `docs/incidents/*.md` written this session whose `## Root cause` names our own mistake: `bin/wrap knowledge-root <repo>`; if a note in that directory already names the incident id in its first heading, `skipped: note exists`; else one note plus its `MEMORY.md` index line; an empty `## Root cause` writes nothing. Each sub-step prints one line when idle. Renumber reflect and report to 8 and 9 and fix the two prose mentions. Report rule: a staged candidate, a filed note, or a knowledge-root fallback is an `FYI` bullet naming the file or the reason. Proof: `docs/verification/estate-seams.md` (`## Green run`, uppercase PASS, exact commands, negative control, reproduce), run against a fixture operator toml so no operator path lands in the doc. Acceptance: `grep -n 'Step 7: learn' commands/wrap.md` hits and the step names `gate-ledger.sh rid`, `significance-classify.sh record`, `precedent find --surface inventory --json`, `wrap stage`, `wrap knowledge-root`; `grep -c 'eight steps' commands/wrap.md` is 0; `bash tests/test-meta.sh` and `bash tests/test-no-personal-paths.sh` green.
- [ ] TASK-006: overlay docs. `commands/onboard.md` and `commands/adopt.md` each gain a short "Overlays and seams" section (context-kit fills `knowledge.root` and `PROSE_RAG_BIN`; learning-kit fills `wrap.before` with its concept flush; none is required; `bin/config seams` shows the state, `--check` for an installer). Regenerate `docs/FEATURES.md`. Acceptance: `grep -il 'overlays and seams' commands/onboard.md commands/adopt.md` lists both; `bash tests/test-meta.sh` green (FEATURES freshness).

## After state

- [ ] `bash bin/config seams` prints five rows with `STATUS` in `default|filled|unresolved|absent`; `bash bin/config list | grep -c 'knowledge.root'` is 1 and no seam-table key appears twice. (Today: no such verb; `config list` calls `wrap.before` inert.)
- [ ] `grep -n '^\[knowledge\]' kit.toml` finds the section; `grep -c '^## Seams' lib/config/module-registry.md` is 1 and it sits after `## Allowlist`. (Today: no key, no table.)
- [ ] `bash bin/wrap knowledge-root .` prints `<cwd>/.claude/memory` with the key empty, and `<root>/projects/<basename>` with it filled to an existing dir under HOME. (Today: no such verb.)
- [ ] `printf '{"title":"t","intent":"i","home":"h","staging":"/tmp/s.md"}' | python3 lib/learn/staging-format.py stage` appends one block `parse` reads back; a second call prints `already staged`. (Today: only the harvest hook and `learn propose` write blocks.)
- [ ] `grep -n 'Step 7: learn' commands/wrap.md` hits; `grep -c 'eight steps' commands/wrap.md` is 0. (Today: the DEBT and candidate steps live in an operator skill.)
- [ ] `grep -il 'overlays and seams' commands/onboard.md commands/adopt.md` lists both. (Today: neither mentions an overlay.)

## Acceptance Criteria (global)

- [ ] All tasks pass their individual acceptance criteria
- [ ] Tests cover happy path + edge cases listed below
- [ ] No regressions in existing functionality

## Verification

```
bash tests/test-config-registry.sh && bash tests/test-config.sh && bash tests/test-config-seams.sh && bash tests/test-staging-stage.sh && bash tests/test-wrap.sh && bash tests/test-meta.sh && bash tests/test-no-personal-paths.sh
```

## Edge Cases

1. Operator with only dwarves-kit: every key row `default`, `PROSE_RAG_BIN` `absent`; Step 7c files under `<repo>/.claude/memory/`; no step asks for an overlay.
2. `knowledge.root` filled, under HOME, exists: `knowledge-root` prints `<root>/projects/<basename>` and creates it; `config seams` says `filled`.
3. `knowledge.root` filled, directory missing: `config seams` `unresolved`; `knowledge-root` falls back with the stderr line; wrap's report carries an FYI bullet.
4. `knowledge.root` outside HOME, or a symlink resolving outside HOME: `knowledge-root` falls back; nothing is created there.
5. `knowledge.root` on a read-only or unreachable volume: `mkdir -p` fails, fallback with the stderr line.
6. `knowledge.root` set in a project `.kit.toml` only: ignored by `kit_config_get_root`, absent from `config seams`; pinned by a test.
7. `knowledge.root` with `~`: expanded before the checks.
8. Repo argument `/x/y/..` or `/`: basename `..` or empty → exit 64; nothing written.
9. `wrap.before` names a skill with no `SKILL.md` under any kept skill dir: `unresolved`; Step -1 already reports a skill that fails to run.
10. `KIT_SKILL_DIRS` entry outside HOME (set by a repo `.envrc`): dropped from the list; cannot turn a report `filled`.
11. `PROSE_RAG_BIN` unset and no `prose-rag` on PATH: `absent`, not an error; recall was optional already.
12. `PROSE_RAG_BIN` set to a non-executable path: `unresolved`; the verb never runs it.
13. `CLAUDE_PLUGIN_ROOT` unset: the default skill dir list is `$HOME/.claude/skills` alone; no `set -u` abort.
14. Session with no run id, or a rid with no `runs/<rid>.log`: Step 7a prints the matching `skipped:` line; the classifier is not called.
15. Run log already has a `| DEBT |` line: `skipped: DEBT marker present`.
16. Classifier exits non-zero (bad enum, unwritable ledger dir): `skipped: classifier failed (rc N)`; wrap continues to 7b.
17. Candidate words match the inventory: no staging row; the FYI bullet quotes the top hit line from the JSON.
18. `wrap stage` with an existing title differing in case, spacing, or punctuation, or a title already on the board: `already staged`; exit 0; no second block.
19. `wrap stage` in a repo with no `_meta/`: creates `_meta/backlog-staging.md` with the header.
20. `wrap stage --repo` on a non-git directory: exit 64.
21. Staging file is a symlink, or resolves outside the repo (and outside HOME when the env override chose it): exit 1, nothing written.
22. Staging file not writable: python prints `FAILED`, exit 2, nothing partial; wrap relays the code.
23. Two wrap sessions stage the same title at once: both may pass the check; `learn drain` shows the duplicate and the operator rejects one (`## Failure modes`).
24. Running from a worktree: `_worktree_copy` writes the worktree's staging file; the main checkout's copy is left alone.
25. Registry file missing: `config seams` exits 1 like `config list`.
26. Seam row with an unknown `Kind` or fewer than three cells: the registry lint fails; the report prints `unresolved` with the marker value instead of aborting.
27. Two `KIT_SKILL_DIRS` entries under HOME, the skill in the second: `filled`.
28. Incident file with an empty `## Root cause`: Step 7c writes nothing and says so.
29. Second `/kit:wrap` pass over the same repo (or a rerun after a Step 0 stop): 7c finds the note that names the incident id and prints `skipped: note exists`; 7b's `already staged` covers the candidate.
30. Twenty seam rows: the report stays one table in registry order; `--check` is the one-bit summary.

## Failure modes

| Failure class | Detection signal | Mitigation / recovery |
|---|---|---|
| Knowledge note filed in the wrong tree (root moved after the note) | `config seams` shows `unresolved`; `memory-tidy` audit finds the orphan | Fallback is always repo-local; the operator moves the note by hand; no data loss |
| Note written outside HOME through a bad root or symlink | none needed: the fence refuses before `mkdir` | Fallback to repo-local, stderr names the reason |
| Staging file corrupted by a partial append | `staging-format.py parse` fails on the file | The python writer renders first and appends in one write; exit 2 on failure |
| Two sessions append the same title concurrently | duplicate block visible in `learn drain` | The check runs inside the writer right before the append; a survivor duplicate is rejected by the human at drain |
| Classifier fails mid-step | the `skipped: classifier failed (rc N)` line in the wrap report | No marker written; `learn debt` treats the run as never classified; rerun `record` by hand |
| DEBT marker written twice for one rid | two `\| DEBT \|` lines in `runs/<rid>.log` | Step 7a checks first; `weekend-batch.sh` reads the last line, so a duplicate is harmless |
| Seam row drifts from its key row (renamed key) or the table lands inside the parser window | `test-config-registry.sh` lint red; `config list` row count changes | Fix the row or move the heading; the lint names the key |
| Seam report shows `filled` for a skill chosen by a repo `.envrc` | none: entries outside HOME are dropped | Only the operator's own dirs count |

## Out of Scope

- Retiring the vendored prose-rag crate (ID-647).
- A per-kit manifest format or version negotiation; the seam table is the mechanism.
- Any engine writer for the til, memo, or concept-flush legs; they stay behind `wrap.before`.
- Edits to context-kit or learning-kit (their own rows follow once the key name is fixed by this spec).
- `config set`; keys stay hand-edited.
- The `config list` "inert" render for `[consumer]` rows: it stays as is; `config seams` is the live view. A one-line follow-up row if it misleads anyone.
- `config seams --json` and a per-kit filter: add when a third kit's installer needs them.

## Touches

- lib/config/**
- lib/wrap/**
- lib/learn/**
- commands/**
- tests/**
- docs/specs/**
- docs/verification/**

## Decision Log

- DEC-001: seam report lives on `bin/config` as `seams`, not on `plugin-check`; `plugin-check` manages Claude plugins and its `status`/`update` verbs have nothing to do with kit config, while `config.sh` already parses the registry tables. Rejected: `plugin-check --seams` (the brief's first name), a new `bin/seams` shim.
- DEC-002: the DEBT marker comes from `significance-classify.sh record`, the existing classifier and writer, not from a raw `gate-ledger.sh debt` call with invented values. Rejected: hard-coding `significance=high worthiness=high` for every batch session (turns every wrap into a tap; ADR-0031 forbids that).
- DEC-003: `knowledge.root` empty means repo-local `.claude/memory`, the layout `stats memory-sweep` and `memory-tidy` already read, so a dwarves-kit-only install changes nothing. Rejected: a kit-owned default tree under XDG.
- DEC-004: seam kinds are `skill|file|dir|binary`, resolved by existence only; no version check. Rejected: floor/version negotiation (ID-396: the adapter's own probe is the version check).
- DEC-005: the `learn` step is one numbered step with three lettered sub-steps that each print one line when idle, mirroring Step -1, so the report never goes silent on a step that did nothing.
- DEC-006 (validate): the seam table is a three-column JOIN table (`Key | Kind | Filled by`) under a top-level `## Seams` heading after `## Allowlist`, outside `_registry_rows`' window. A sibling `###` table would have injected five fake rows into `config list`; a six-column copy would have duplicated default, module, and description and needed the drift lint only because of that duplication. Rejected: adding two columns to every existing registry row (churns 300 lines for five rows).
- DEC-007 (validate): the staging writer is a `stage` verb on `staging-format.py`, which already owns `norm`, `existing_keys`, and `render_block`; `wrap stage` only resolves paths and runs the fences. A bash reimplementation of normalize + dedupe + append is the exact drift `hooks/backlog-stage.py` documents having suffered. Dedupe covers staging AND board, as `propose.py` does.
- DEC-008 (validate): every wrap writer, `knowledge-root` included, runs the `cmd_log` chain: `_realpath_f`, the HOME fence, `_worktree_copy`, `_write_guard`. A repo basename of `.`/`..`/empty and a symlinked staging file are refused outright. Rejected: existence checks alone.
- DEC-009 (validate): `binary` rows get a fourth status `absent` (overlay not installed) distinct from `unresolved` (installed but broken), and `--check` gives installers a one-bit exit. Rejected for now: `--json`, a per-kit filter, a Reader lint (add when a third kit asks).
- DEC-010 (validate): env-read inputs to the seam report (`KIT_SKILL_DIRS`, `PROSE_RAG_BIN`) are registered rows, expanded with `${VAR:-}`, and skill dirs outside HOME are dropped, because a repo `.envrc` can set them. The report never executes a target, so the remaining exposure is a false `filled`, and that path is closed.
- DEC-011 (validate): Step 7 renumbers reflect and report to 8 and 9; `grep -rn "Step 7\|Step 8" tests/` hits only `ship.md` assertions, and the two prose mentions in `wrap.md` (lines 7 and 35) update with it. Rejected: a `6b` step that would have contradicted the acceptance grep.
- DEC-012 (validate): candidate matching branches on `precedent find --json` (`nothing_matched`), because `--quiet` always exits 0 and its summary names a section, not a tool.

## Open questions

(none; a /goal loop appends here if it hits a decision this spec does not cover, then stops)
