# Architecture

How dwarves-kit fits together. Read PHILOSOPHY.md first for the WHY; this file is the WHAT and HOW. The harness-level loop story (the five stages, formerly "legs": Shape → Build → Watch → Check → Learn, and which module serves which) lives in the README's "The five stages" section, backed by ADR-0034 and the machine registry `lib/config/module-registry.md`; this file does not restate it.

## Component layout

The kit ships five kinds of artifact. Each maps to a Claude Code primitive:

| Kit dir | CC primitive | Trigger |
|---|---|---|
| `hooks/` | Hook | Event (PreToolUse, Stop, StatusLine, etc.) |
| `commands/` | Slash command | Human typing `/kit:<name>` |
| `agents/` | Custom subagent | Dispatched by a command via Task tool |
| `skills/` | Skill | Claude auto-triggered from skill description |
| `rules/` | Path-scoped rules | Active when Claude reads matching files |

The kit is intentionally flat. Component dirs sit at the top of the repo, not nested under `src/`, because the kit IS a flat set of prompts and bash scripts; there is no compilation step that justifies a `src/` boundary.

**`bin/` is the stable consumer interface.** One more top-level dir holds the consumer-facing entrypoints: `bin/board`, `bin/classify`, `bin/gate`, `bin/precedent`, `bin/wrap`, thin forwarders to the corresponding `lib/<subsystem>/` entry. A CONSUMER of the kit (an adopted repo's `_meta/board` / `board-all` shim, or the CLAUDE.md block `lib/adopt.sh` injects) references `$DWARVES_KIT/bin/<name>`, never a deep `$DWARVES_KIT/lib/<subsystem>/<file>.sh` path. This is the durable fix for the board-shim class of bug: when the kit-modularity regroup moved `lib/board.sh` -> `lib/board/board.sh`, every consumer that hard-referenced the old deep path broke silently. With `bin/` as the contract, an internal `lib/` reorg's blast radius is the ONE kit-owned wrapper line inside `bin/<name>`, not every consumer. The pick (per-subsystem shims, NOT a `kit <sub> <verb>` uber-dispatcher) is constrained by AGENTS.md's "there is no `kit` uber-dispatcher" architecture statement; `bin/` merely exposes the existing per-subsystem commands at a stable path. `install.sh` deploys `bin/` next to `lib/` (copy in the bash install, symlink in plugin-compat).

Two dirs hold bash that is not a CC primitive: `tests/` (the suites) and `lib/` (deterministic command-helper bash that a command invokes but that is not event-triggered, so it does not belong in `hooks/`). Today `lib/` holds `dispatch-gate.sh` (the pure-bash disjointness gate + drift guard `/kit:dispatch` runs, ADR-0019), `lane-classify.sh` (the deterministic task-type -> risk-lane classifier `/kit:assign` + `/kit:dispatch` call, plus the advisory `check` floor guard `/kit:assign` runs after a lane is chosen to flag an under-sized choice; warn + log, never block), `backlog.sh` (the Active queue rendered as a kanban board + the mechanical state flips behind `/kit:assign --next`, SPEC-055), and `goal-registry.sh` (the cross-session running-goal registry `/kit:assign` claims into and `/kit:start` lists, ADR-0022; it sources `dispatch-gate.sh` to reuse the one disjointness rule), `task-type-classify.sh` (the deterministic task -> work-type classifier, SPEC-054/057/060), `role-classify.sh` (the deterministic task -> specialist-DOMAIN fast-path hint behind dynamic agent synthesis, a cheap pre-filter to the open-ended meta-agent Mode C, SPEC-089), `gate-ledger.sh` (the per-run gate ledger + START routing record, ADR-0024/SPEC-061; a
`grill`+`skipped` line is write-time validated against a closed `reason=<home-turf|density-low|
operator-wave>` enum, SPEC-138, so the kit's least-used gate is auditable rather than free text), `proof-gate.sh`/`proof-ledger.sh` (the proof-of-done class + ship-gate ledger, SPEC-016 line), and `lane-telemetry.sh` (the read-side aggregator over the run ledgers: `report` + `misfires`, reviewed at `/kit:retro` Step 1d, SPEC-061). A helper earns a place in `lib/` only when it must be unit-testable in isolation (all are); one-off bash a command runs inline stays inline (kit-health, ship). `board.sh` is the kit's cockpit board command: it wraps `backlog.sh` for the single-repo kanban render, migrates in the `priority` quadrant awk and the cross-repo `priority matrix` pivot that used to live in a consumer's own `_meta/board`/`_meta/board-all` wrapper scripts (byte-identical output is a pinned non-regression), and adds a `queue` subcommand that reads the CONSUMER's `boards.txt` registry (via `--repo-root`/`REPO_ROOT`, never a kit-side personal default) to emit an allow-listed feed for an unattended overnight runner. `parse-board.sh` is the one structured BACKLOG.md parser both `board.sh`'s `queue` and `board-mirror.sh` (below) reuse, rather than each re-parsing the markdown independently. `board-mirror.sh` backs the `board.sh mirror`/`status` subcommands: a git<->Hermes kanban bridge, read-mirror leg only (`board-writeback.sh` owns the reverse writeback leg). It extracts opted-in (`bridge=on` in `boards.txt`) BACKLOG.md rows + active mega-goal roadmaps, diffs them against an incremental NDJSON snapshot via a bash+awk keyed comparison (no DuckDB -- dozens of rows, not analytics), and loads through `hermes kanban` CLI verbs only (ADR-0001 native-first). A load-bearing finding from this sub-goal's live dev-home E2E: two of Hermes v0.18.0's six documented kanban states (`todo`, `running`) have NO durable CLI-only creation path at all (a card lands there for an instant, then a later unrelated CLI call silently auto-promotes it back to `ready`, with no gateway/dispatcher process running); the bridge's reachable target set is therefore `{triage, ready, blocked, done}` only, and `claimed`/`speccing`/`validated`/`executing` all fall back to `ready` honestly rather than claim a distinction the CLI cannot actually hold. `board-writeback.sh` backs `board.sh writeback`: the reverse leg, consuming the mirror snapshot as its bearing surface. It sources `board-mirror.sh` (function-level reuse, not a re-fork) for the extract/hash/native-state machinery, reverse-maps a Hermes-side status move onto its nearest legal `backlog.sh` git state (a documented lossy collapse -- the forward map is many-to-one, so `ready` reverse-maps to `claimed` as the honest nearest "picked up" state, never a guess at which of claimed/speccing/validated/executing the operator meant), and enforces the row_hash CONFLICT RULE (git wins: a Hermes-side edit applies only if the row's current hash still matches the snapshot's recorded value; a missing/corrupt snapshot refuses ALL edits outright rather than degrading to "apply everything"). Every apply lands in an ISOLATED `git worktree` off the CURRENT HEAD (never the caller's own checkout, never a stale ref), as one `actor=hermes`-attributed commit on a fresh `chore/board-sync` branch, pushed and opened as a HELD `gh pr create` PR (argv-only; never auto-merged). Snapshot refresh after a successful apply updates only `hermes_status` (so writeback does not re-diff the same not-yet-merged move); `row_hash` passes through unchanged, since the git SoT itself has not changed until the PR merges -- at which point `board mirror`'s own ordinary idempotence heals the row.

## Data flow through `docs/specs/SPEC-NNN-<slug>.md`

> The front door to all of this is [`AGENTS.md`](../AGENTS.md) (repo root): the tool-agnostic operate-contract that any runtime reads first; `CLAUDE.md` and `WORKFLOW.md` point at it rather than restate it. The imperative companion to the descriptive map below is [`WORKFLOW.md`](../WORKFLOW.md) (repo root): the same lifecycle phrased as the contract an agent follows, with risk-tier lanes (including the `backfill` brownfield lane: review an existing codebase and write the operating-layer docs, doc-output only, no app-behavior change) and the gate at each boundary.

`docs/specs/SPEC-NNN-<slug>.md` is the shared contract for the full lifecycle. It is the single source of truth that crosses command boundaries:

```
/kit:think      reads:  user idea (chat)
                 writes: docs/briefs/DECISION-BRIEF.md  (if BUILD)

/kit:spec       reads:  docs/briefs/DECISION-BRIEF.md, codebase via 4 research agents
                 writes: docs/specs/SPEC-NNN-<slug>.md  (Status: DRAFT)
                         docs/research/{stack,features,architecture,pitfalls}.md

/kit:spec-validate  reads:  docs/specs/SPEC-NNN-<slug>.md
                     writes: docs/specs/SPEC-NNN-<slug>.md  (Status: VALIDATED) or comments

/kit:execute    reads:  docs/specs/SPEC-NNN-<slug>.md
                 writes: code, tests, docs/specs/SPEC-NNN-<slug>.md task checkmarks, decision log
                 dispatches: worker -> task-verifier -> fix-agent (retry max 2)

/kit:next       reads:  docs/specs/SPEC-NNN-<slug>.md
                 writes: code, tests; you drive verification

/kit:review     reads:  git diff, docs/specs/SPEC-NNN-<slug>.md
                 writes: ## Review section in the active spec (else inline)

/kit:review-team  reads:  git diff
                   dispatches: security-reviewer (security) + code-reviewer agent x2 (architecture, test-coverage)
                   writes:  ## Review section (per-lens subsections) in the active spec (else inline)

/kit:docs       reads:  git diff
                 writes: README.md, CHANGELOG.md, other docs as drift dictates

/kit:ship       reads:  docs/specs/SPEC-NNN-<slug>.md (incl. its ## Review verdict), VERSION
                 gate:   blocks if the spec's ## Review verdict is DO NOT SHIP
                 writes: VERSION, CHANGELOG.md entry, git tag, PR

/kit:retro      reads:  docs/specs/SPEC-NNN-<slug>.md, git log
                 writes: docs/retro/v<version>.md
```

**Unified convention**: the diagram above applies to both the kit itself and downstream projects, which now share one spec location: `docs/specs/SPEC-NNN-<slug>.md`, tracked in place via a `Status:` header (DRAFT / VALIDATED / SHIPPED). No planning-dir split, no migration step. `docs/specs/` is the sole spec location; the legacy planning-dir deprecation fallback has been removed. See ADR-0010 (supersedes ADR-0002).

**V-model lifecycle lens (ADR-0018, reframed 2026-05-23)**: the kit's workflow is shaped as a V: a **BUILD arm** (left, decompose + implement) and a **TEST arm** (right, plan + execute + report), with Code at the vertex. Each static-review gate verifies one artifact at its phase (not a separate lane); they are not test levels. The V-model is a lens over WORKFLOW.md's cycle table, not a second phase list. Feature-rejection criterion #2 is count-agnostic: "serves fewer than 2 lifecycle phases." See ADR-0018 (SPEC-031 C2; build-left/test-right reframe 2026-05-23).

**Concurrency boundary (ADR-0019 + ADR-0020 + ADR-0022)**: the kit permits concurrency along two axes and stops short of a DAG / wave scheduler / crash-recovery runtime (handed to GSD v2).
- **In-session (ADR-0019 + ADR-0020):** **bounded cross-goal fan-out**, one lead session orchestrating N isolated worktree workers over disjoint `VALIDATED` specs, behind a disjointness gate, with lead-owned convergence. ADR-0019 supersedes the four standing "one session / sequential" boundaries (SPEC-032 C1); ADR-0020 locks the dispatch primitive to in-session `Agent(run_in_background, isolation:worktree)` workers (Path A, proven by the SPEC-033 spike), not the read-only `claude agents` view. The implementing surface is `/kit:dispatch`; the convergence contract is SPEC-031.
- **Cross-session:** **one operator's N concurrent same-machine sessions over disjoint goals**, coordinated by a passive **running-goal registry** (`lib/goal/goal-registry.sh`), one single-writer file per goal under `.git/kit-goals/`, reusing the same disjointness rule to refuse a goal that overlaps an active one, and serving as the cross-session monitor (`list`, surfaced in `/kit:start`) plus each goal's attempt log. ADR-0022 supersedes the "multi-session stays L5" boundary (SPEC-036 C4) for exactly this case. What stays L5 (Nimbalyst / GSD v2): coordination across machines, 3+ live human operators, and goal-ordering chains. The registry records and compares; it never schedules, sequences, or merges.

Where they meet: the native `claude agents` view monitors the subagents inside *one* session; the running-goal registry is the kit-level roll-up that lists every concurrent goal *across* sessions, tagged with its goal + lane. `/kit:dispatch` also registers its in-session workers, so one `goal-registry list` shows both axes.

## Command and agent V-phase inventory

Every command and agent mapped to its V-model arm, grouped so the left side (BUILD) and the right side (TEST) read at a glance. The **left arm** decomposes and implements; the **right arm** plans, executes, and reports the tests; **Code** is the vertex. **Static quality gates** verify each artifact by review (not test execution) at its phase; **cross-phase** entries sit outside it.

### Left arm: BUILD (decompose + implement)

| Entry | Type | V-phase | Arm | Note |
|---|---|---|---|---|
| `/kit:think` | command | Brief | build | Stress-tests the idea before any spec; primary output is `DECISION-BRIEF.md` |
| `/kit:assign` | command | Requirement | build | Turns a backlog item into a goal draft; routes it into the right lane |
| `/kit:grill` | command | Requirement (intake) | build | Universal intake interview between type classification and the phase-0 Done=; type-shaped one-question-at-a-time, write-as-you-go |
| `/kit:design` | command | Solution-design | build | Opt-in interactive beat between think and spec; shapes the solution one decision at a time |
| `/kit:prototype` | command | Solution-design | build | Opt-in throwaway spike answering one design question (logic TUI or UI variants); decision folds into the brief/spec, code survives on a `prototype/<name>` branch |
| `/kit:wayfind` | command | Requirement (intake) | build | User-invoked decision map for too-foggy-for-one-session efforts; typed tickets route to grill/prototype/research machinery; hands off to spec or a ROADMAP |
| `/kit:spec` | command | Spec | build | Produces `SPEC-NNN-<slug>.md` (Status: DRAFT); dispatches 4 research agents for brownfield context |
| `/kit:feature-map` | command | Spec (brownfield) | build | Formalizes a feature inventory for any target project: dispatches `research-features` per module (parallel) into `docs/specs/<module>.md` + a top-level checklist; adds a MIGRATE table + parity contract when a port/migration target is named |
| `/kit:ui-design` | command | UI design | build | Opt-in; writes UI brief, delegates generation, routes through visual-team, auto-revises (bounded) |
| `research-architecture` | agent | Spec (brownfield) | build | Maps architecture patterns; dispatched by /spec; read-only |
| `research-context` | agent | Spec (brownfield) | build | Quick brownfield orientation (endpoints, models, UI, tests, recent history), capped at 80 lines; dispatched by /spec, /kit:test-plan; read-only |
| `research-pitfalls` | agent | Spec (brownfield) | build | Finds landmines and risks before new work; dispatched by /spec; read-only |
| `research-stack` | agent | Spec (brownfield) | build | Maps technology stack; dispatched by /spec; read-only |
| `research-features` | agent | Spec (brownfield) | build | Deep, uncapped, source-cited feature inventory for any project: MIGRATE table + parity contract when porting, else a behavior contract; dispatched by /kit:feature-map; read-only |

### Vertex: BUILD (code)

| Entry | Type | V-phase | Arm | Note |
|---|---|---|---|---|
| `/kit:execute` | command | Build + test dispatch | code | The vertex; dispatches worker → task-verifier → fix-agent per task (max 2 retries); the test agents it dispatches are listed under the TEST arm |
| `/kit:next` | command | Build | code | Manual-drive variant of execute; loads next undone task, lets the human control the loop |
| `fix-agent` | agent | Build (targeted fix) | code | Applies bounded fixes named by task-verifier; scoped to specific files/issues; no feature additions |

### Right arm: TEST (plan, execute, report)

| Entry | Type | V-phase | Arm | Note |
|---|---|---|---|---|
| `/kit:test-plan` | command | Test design (write tests) | test | Opt-in; derives the coverage matrix from AC before /execute so the build has a planned target; the kit's single test-design step |
| `/kit:test-plan-review-team` | command | Test design (review) | test | Opt-in; 6 lenses adversarially critique the `## Test plan` (lens 6 tiering N/A-skips on non-AI plans, SPEC-201) + bounded revise loop, between /test-plan and /execute; report-only |
| `/kit:test-write` | command | Test design (materialize) | test | Opt-in; resolves a SOLID-verdict `## Test plan critique` and dispatches `test-writer` per matrix row to turn it into real, executing test code; never dispatches against a missing/stale/non-SOLID verdict |
| `test-writer` | agent | Test design (materialize) | test | Turns a reviewed test-plan coverage matrix into runnable test code, one case per matrix row, in the repo's existing framework; write-capable but scope-locked to test files; dispatched by `/kit:test-write` |
| `task-verifier` | agent | Unit / task test | test | Runs each task's AC + the project suite after each worker; read-only; primary enforcer in the verification pipeline |
| `integration-verifier` | agent | Integration test | test | Verifies cross-task wiring at /execute Step 4 for multi-task specs; read-only |
| `/kit:ship` | command | Acceptance test (gate) | test | Executes the acceptance check; blocks on DO-NOT-SHIP; bumps version, writes changelog, cuts PR |
| `acceptance-verifier` | agent | Acceptance test | test | Executes the spec's own `## Verification` section end to end and maps each AC to a passing check; read-only; fills the right arm's previously agent-less Acceptance row (ADR-0028 right-arm parity) |
| `system-verifier` | agent | System test | test | Runs the whole assembled project test suite, unscoped, as the dynamic mirror of the design phase; read-only; fills the right arm's previously agent-less System-test row (ADR-0028 right-arm parity) |
| `recheck-verifier` | agent | Re-audit (fresh-context) | test | Dispatched after a right-arm verifier (task-verifier/integration-verifier/acceptance-verifier/system-verifier) returns PASS; RE-EXECUTES the recorded verification command in a fresh context and re-judges, never a read-back; the ADR-0028 trust metric ("% of done-claims that survive a fresh-context re-audit") made real; advisory + recorded, never a mid-flight hard block |
| `/kit:verify` | command | Test re-run (on demand) | test | Read-only re-run of the unit + integration levels (dispatches `task-verifier` + `integration-verifier`) against the active spec; no rebuild, no fix; the right arm on demand |
| `/kit:battery` | command | Independent verification (finished branch) | test | The full battery: fresh-context acceptance re-execution against a stated baseline + multi-lens review + advisor extra lens, dispatched in parallel at prescribed tiers; findings merged into one verdict, fixes applied by the lead |

### Static quality gates (static verification of each artifact; review, not test execution)

| Entry | Type | V-phase | Arm | Note |
|---|---|---|---|---|
| `/kit:spec-validate` | command | Spec review | gate | Adversarial pre-build gate; 6 lenses attack the spec (5 advisory, 1 blocking on the design record); sets Status: VALIDATED |
| `/kit:devs-team` | command | Design critique | gate | Opt-in; 5 engineering lenses stress-test the solution design before the spec hardens |
| `/kit:review` | command | Code review | gate | Single-pass paranoid review; security, architecture, regressions, edge cases |
| `/kit:review-team` | command | Code review | gate | Parallel variant; dispatches `security-reviewer` (security) plus the `code-reviewer` agent x2 (architecture / test-coverage lenses) |
| `/kit:visual-team` | command | Visual critique | gate | Opt-in; 5 design lenses critique UI output; mirrors review-team for visual work |
| `/kit:docs` | command | Doc sync | gate | Diffs code vs docs and patches drift; dispatches doc-verifier before committing |
| `/kit:explain` | command | Understanding (AFTER gate) | gate | ADR-0031 §2; emits a literate-diff explainer (background -> goal+intuition -> prose-ordered diff -> diagram) via `lib/explain.sh`, composing narrate-log + svg-knowledge-diagram; grounded in the diff + test results, advisory |
| `/kit:quiz-gate` | command | Understanding (AFTER gate) | gate | ADR-0031 §2/§3; the ★-tap NUDGE before merging a significant+worthy gate PR: 5 diff-grounded quiz questions (`lib/gate/quiz-gate.sh`) routed through deep-understand, keyed on `lib/classify/significance-classify.sh`'s `tap` verdict; three logged responses (engage/defer/wave), advisory, never must-pass |
| `/kit:pitch` | command | Understanding (AFTER gate, outward) | gate | SPEC-140; the OUTWARD twin of `/kit:explain` -- assembles a buy-in doc (outcome -> unknowns -> evidence -> cost -> ask) from the spec, proof-of-done, implementation-notes, and the ledger's grill/DEBT records via `lib/pitch.sh`; a missing source is an explicit line, never invented; `commands/ship.md` Step 8 offers it only when `significance=high` AND the repo is team-shared (`lib/pitch.sh team-shared`); never auto-posts |
| `/kit:gauntlet` | command | Contributor-surface convergence | gate | Maintainer-only bounded-revise loop (Evaluator-Optimizer lineage) proving a median-skill dev can onboard from the docs alone, build one seed card, and submit unaided; each round persists a full run record (`docs/verification/gauntlet/<date>-<slug>/`), the orchestrator revises the surface, tears down, respins |
| `code-reviewer` | agent | Code review | gate | Focused single-lens reviewer; dispatched by /review-team with a lens (architecture / test-coverage; security now uses security-reviewer) |
| `security-reviewer` | agent | Security review | gate | Deep security analysis; dispatched by `/kit:review-team` as the security reviewer (replacing the generic code-reviewer security lens); also invocable directly for an ad-hoc deep pass |
| `doc-verifier` | agent | Docs verification | gate | Verifies doc claims against live codebase after /docs updates; read-only; the doc-sync twin of task-verifier |
| `agent-effectiveness` | agent | Agent-def review | gate | Validates a new/changed agent definition's effectiveness across 4 lenses (tools/description/instructions/tier); dispatched diff-keyed by /kit:draft-agent Step 4.7; read-only, advisory, fail-safe |
| `break-it` | agent | Adversarial probe (extra lens) | test | Escalation-tier lens dispatched by /kit:battery when the diff carries behavioral code with tests; hunts one concrete input the suite does not constrain and returns PROBE/NO-PROBE; rung 2 of the coverage -> probe -> mutation ladder, before lib/gate/mutation-smoke.sh; read-only, advisory, never writes a test |
| `advisor` | agent | Cross-cutting review (extra lens) | gate | Kit-default generic lens at the final integration/UAT boundary; two modes (P5 critique via /review-team Step 2b, P6 over-suggest before the final review); additive to the specialized reviewers, read-only, advisory |
| `brief-reviewer` | agent | Brief review | gate | Static left-arm reviewer of the design brief / requirement (`DECISION-BRIEF.md` or a spec's Problem/Context) for clarity, completeness, and testability before it hardens into a spec; read-only; the mirror the brief row previously lacked (ADR-0028 right-arm parity, ADR-0029) |

### Cross-phase (outside the V)

| Entry | Type | V-phase | Arm | Note |
|---|---|---|---|---|
| `/kit:wrap` | command | Land (post-ship) | cross-phase | Session-scoped landing step after ship: flips board rows, merges the operator's own green PRs one at a time (`bin/wrap merge`), checks a `workflow_dispatch` deploy's `headSha`, tidies branches and worktrees (`bin/wrap apply`), writes the activity line (`bin/wrap log`), and calls `/kit:retro` when a shipped PR merged this session |
| `/kit:retro` | command | Reflect | cross-phase | Post-ship narrative mirror of the entire V; captures learnings, not a gate |
| `/kit:start` | command | Session entry | cross-phase | Detects project state and recommends the right next command; never executes |
| `/kit:onboard` | command | First-run onboarding | cross-phase | Interactive first-run orchestrator: detects install mode via `lib/onboard-detect.sh`, offers `/kit:adopt`, picks modules (bridging the plugin path's missing `--with`), captures consumer knobs from the SPEC-198 registry, discloses plugin-path gaps, ends with the five-stage tour; CALLS start/adopt/config, reimplements none (ADR-0034 fence); previews + confirms every write |
| `/kit:adopt` | command | Repo onboarding | cross-phase | Injects the operate-contract + proof marker + a CLAUDE.md pointer into a target repo (idempotent, via `lib/adopt.sh`); wires the classifiers so the ship-gate engages there |
| `/kit:kit-health` | command | Maintainer audit | cross-phase | Self-assessment against PHILOSOPHY.md; run before tagging; not part of the normal cycle |
| `/kit:absorb` | command | Upstream maintenance | cross-phase | Audits Credits drift + seed-rescan; proposal-only; maintainer-only connective tissue |
| `/kit:debug` | command | Bug lane (off-cycle) | cross-phase | Off-cycle loop: root cause before any fix; evidence ledger; 3-fix architecture wall |
| `/kit:dispatch` | command | Concurrent fan-out | cross-phase | Fans out N disjoint VALIDATED specs into isolated worktree workers behind the disjointness gate (`lib/gate/dispatch-gate.sh`); drift-guards each; lead-owned convergence; no DAG / no auto-merge |
| `/kit:mega` | command | Sequenced fan-out | cross-phase | Mirrors the plan-for-mega-goal skill: decomposes 3-8 DEPENDENT sub-goals into one bounded-loop roadmap, front-loads every clarification once, sets the per-run merge config; ship-layer auto-merge for `auto`-tagged sub-goals rides `lib/goal/mega-merge.sh` -> `lib/gate/gate-ledger.sh check`, refusing unconditionally on a failing/missing gate (ADR-0028 P2/P3, SPEC-034, SPEC-096) |
| `responding-to-review` | agent | Review response | cross-phase | Responds to review feedback with technical rigor; proposes fixes, does not apply them |
| `slop-stripper` | agent | Review response | cross-phase | Behavior-preserving AI-slop strip pass (deslop mechanism, kit ID-402): surgical edits only, never behavior changes unless fixing a real bug; opt-in dispatch at the `/kit:review-team` decision gate, pre-ship |
| `/kit:draft-agent` | command | Meta-tooling | cross-phase | Generates a subagent (or sub-goal file) via the `meta-agent`; installs the subagent by default (roster-sync + `cp` to `~/.claude/agents/`); `--draft` stops at a staged draft |
| `meta-agent` | agent | Meta-tooling | cross-phase | Drafts a new subagent definition or mega-goal sub-goal file from a one-line description; determines minimal tools; the subagent writes to staging only, the command promotes/installs |
| `performance-reviewer` | agent | Code review | gate | Read-only performance-lens reviewer (hot paths, N+1, allocations, caching, p95/p99, complexity); dispatched by `/kit:review-team` as the performance domain lens when the diff touches perf-sensitive code |
| `api-reviewer` | agent | Code review | gate | Read-only api-contract-lens reviewer (breaking changes, versioning, schema, error codes, backward compat, idempotency); dispatched by `/kit:review-team` as the api domain lens |
| `frontend-reviewer` | agent | Code review | gate | Read-only frontend-lens reviewer (a11y/ARIA, semantic HTML, focus/keyboard, state handling, responsive, color-only signaling); dispatched by `/kit:review-team` as the frontend domain lens |
| `infra-reviewer` | agent | Code review | gate | Read-only infra-lens reviewer (deploy/rollback safety, CI/CD, container/IaC least-privilege, secrets, idempotent provisioning, blast radius); dispatched by `/kit:review-team` as the infra domain lens |
| `db-migration-worker` | agent | Code (implement) | build | Write-capable schema-migration implementer (up + DOWN/rollback, batched backfill, index changes; guards long locks, no data drop without explicit ask); dispatched by `/kit:execute` 2b-0 as the db-migration domain implementer |
| `data-etl-worker` | agent | Code (implement) | build | Write-capable data-pipeline implementer (ETL, DuckDB SQL transform, idempotent re-runs, schema validation, no silent row drops); dispatched by `/kit:execute` 2b-0 as the data-etl domain implementer |
| `audit-scanner` | agent | Estate audit (Tier 2) | cross-phase | Shared read-only evidence scanner for the audit-loop instances (doc-drift, topology-drift skills): receives target set + contract + evidence class, returns per-item verdicts in the audit-loop grammar with quoted evidence; tools roster has no write path, so the propose/apply split holds mechanically in unattended cadence runs |
| `claim-verifier` | agent | Claim verification | cross-phase | Read-only adversarial panel over an ARBITRARY free-text claim: N in-context independent skeptics (default N=3, distinct attack angles, default-refute-if-uncertain, fail-closed), majority-vote structured verdict (HOLDS/REFUTED + tally + threshold + per-skeptic reasons); the semantic half of the citation-guard hook; dispatched on a load-bearing assertion (kit-foldin SG-06) |
| `/kit:greenlight` | command | Post-push CI lane | cross-phase | Snapshots an open PR's checks via gh, classifies each failure real vs flaky, fixes real ones (fix-agent shape, verified locally before push), retries flaky within a bounded budget; opt-in, report-only, never hard-gates ship or merge |
| `devops-triage` | agent | Production triage | cross-phase | Read-only bounded root-cause verdict on a production error alert (Workers Logs history + git log/diff/show around the deploy sha); on-demand in kit-adopted repos; NOT local repro or test-failure debugging (that is `/kit:debug`) |

**Classification notes:**
- The right arm is *test execution*; the static gates are *review*. Both are "verification" loosely, but only the right arm runs tests. `/kit:spec-validate`, `/kit:review`, `/kit:docs` review; `task-verifier`, `integration-verifier`, `/kit:ship` test.
- `/kit:execute` is the vertex (code); it also dispatches the right-arm test agents (`task-verifier`, `integration-verifier`), which are listed once, under the TEST arm.
- Cross-phase entries span arms or sit outside the V (debug, maintenance, session routing). Forcing them onto one arm would misrepresent them.
- A new command or agent adds exactly one row; the parity check asserts row count == live file count to keep this table from drifting.

## Command vs agent (the layering rule)

A **command** is a control-plane *trigger*: a human or the `/goal` loop invokes it to enter a phase, gate a decision, or orchestrate work (it may dispatch agents). An **agent** is a data-plane *actor* a command (or Claude) dispatches to do one job in an isolated context; it is never invoked directly.

Decision test, in order:

1. Does a human or the loop **trigger it directly**? -> command.
2. Does the work need a **fresh / isolated context** (read-only verification so the author's bias cannot leak) or **parallel fan-out** (N lenses at once)? -> agent.
3. Does it **sequence or gate** other steps? -> command.
4. Is it a **repeatable single-job actor** invoked by a step? -> agent.

The load-bearing reason agents exist is **isolation**, not "sub-functions" (PHILOSOPHY "verify with a fresh context, not self-report"). A job needing neither isolation nor parallelism is steps inside a command, not an agent (that is why `/kit:spec-validate`'s 6 lenses are inline: they share the spec's context).

Two failure modes this rule catches:

- **Phantom command**: a command for something only ever dispatched by a step (you would never type `/kit:task-verify`). Verification is an agent, not a command.
- **Orphan agent**: an agent no command dispatches and the user cannot invoke is dead code. Every agent needs a trigger.

This is the command/agent half of the ID-036 layering contract (orchestration / agents / hooks); the hook half is declared in the next section.

## Hook fallback layer (closing the layering contract)

The three layers compose orchestration-first:

```
Layer 1  ORCHESTRATION  AGENTS.md operate-contract + commands + type loops.
         (LLM-driven)   Decides and acts. ALL guidance lives here.
Layer 2  AGENTS         Isolated step-actors (previous section). Exist for
                        fresh-context verification and parallel fan-out.
Layer 3  HOOKS          Fallback enforcement ONLY. A hook exists when, and
         (fallback)     only when, prose instruction is not enough.
```

Hooks are the bottom layer by design: each one costs latency on every matching
event and risks false-positive friction, so the kit reaches for one last, as
fallback for failure modes that survive prose instruction (rationalizing
"done", rushing a destructive command, reading a secret "just to check",
shipping without proof). Everything an instructed LLM reliably does belongs in
Layer 1.

**Placement decision test** for the next proposed hook, in order:

1. Can the orchestration layer be trusted to do it every time when told in
   prose? -> Layer 1 (AGENTS.md / a command). Not a hook.
2. Does the failure mode survive prose AND the damage is irreversible
   (destroyed files, leaked secret, polluted main, false "done")? -> HARD hook:
   blocks (exit 2 / deny).
3. Does it survive prose but the drift is recoverable and a human may
   legitimately override? -> ADVISORY hook: warns (exit 0 + context), never
   blocks.
4. Is there no judgment involved at all (formatting, state save, HUD)? ->
   CONVENIENCE hook: declared non-enforcement, so nobody mistakes auto-format
   for a guardrail.

**The inventory** (one row per `hooks/*.sh`; the parity check pins row count to
file count so this table cannot drift):

| Hook | Event | Class | Failure mode it backstops |
|---|---|---|---|
| `safety-gate` | PreToolUse Bash | hard | destructive deletes, push-to-main, force-push under deadline pressure |
| `secrets-guard` | PreToolUse Read/Edit/Bash | hard | reading secret files "just to check"; transcript is plaintext |
| `ship-gate` | PreToolUse Bash | hard | shipping without proof of done / recorded gates (ADR-0024 boundary) |
| `commit-format` | PreToolUse Bash | hard | drifting commit subjects (type, length, ticket-tag leakage) |
| `anti-rationalization` | Stop | hard | declaring work complete while rationalizing known-incomplete work |
| `spec-drift-guard` | PreToolUse Write | advisory | creating files the active spec never mentions |
| `slop-cleaner` | Stop | advisory | long-session code bloat; suggests, never blocks |
| `context-readiness` | SessionStart | advisory | starting blind: injects spec/board state + an intent-first next step |
| `context-hints` | UserPromptSubmit | convenience | none (temporal + keyword skill-hint injection, sub-ms, never blocks) |
| `citation-guard` | Stop | advisory | hallucinated `file:line` citations in the final message; log-only by default, opt-in strict mode (`CITATION_GUARD_STRICT=1`) blocks |
| `harvest` | PreCompact, SessionEnd | convenience | none (stages durable learnings / a LAB_LOG draft to a staging file; never writes a durable home, always exits 0) |
| `backlog-stage` | SessionEnd | convenience | none (stages forward-looking work-items to a staging file; never writes the board, always exits 0) |
| `intake-sweep` | SessionStart (invoked by backlog-stage --surface) | convenience | none (sweeps consumer-declared deferred-link sources into the same staging file; config-gated no-op, always exits 0) |
| `auto-format` | PostToolUse Write/Edit | convenience | none (idempotent formatting) |
| `output-offload` | PostToolUse * | advisory | oversized tool output bloating context; offloads the full payload to a file + nudges, never blocks |
| `statusline` | StatusLine | convenience | none (HUD) |
| `notification` | Notification | convenience | none (desktop notify) |
| `permission-auto-approve` | PermissionRequest | convenience | none (removes approve-20-times friction for read-only ops) |
| `session-state-save` | Stop | convenience | none (state persistence) |
| `pre-compact-backup` | PreCompact | convenience | none (session snapshot) |
| `post-compact-reinject` | PostToolUse compact | convenience | none (re-injects rules compaction stripped) |
| `codebase-index` | SessionStart (opt-in) | convenience | none (background indexing) |
| `money-gate` | PreToolUse Edit/Write/MultiEdit | convenience | a silent careless edit to a ledger/payroll/wallet file in a repo the consumer named financial (inert until MONEY_GATE_REPOS is set) |
| `prose-rag` | UserPromptSubmit | convenience | re-deriving what the consumer already wrote; injects prior notes on recall-shaped prompts (dormant unless PROSE_RAG_INJECT=1) |
| `tool-policy-guard` | PreToolUse | advisory | drifting to a denied/ask-tier tool the policy file maps per domain (inert until a tool-policy.json exists) |

**C3 reconciled.** PHILOSOPHY's "Guardrails over guidance" is bounded, not
blanket: guardrail = the hard subset, where trust fails AND damage is
irreversible. Everything else stays guidance in Layer 1, because a hard hook
is the most expensive enforcement the kit has (every event, every repo, every
false positive). ADR-0024 is the boundary discipline that keeps it cheap:
gates collect advisory evidence mid-flight and enforce once, at ship.

**Folded concerns, dispositioned.** ID-012 P2 (the autonomous-loop QA gate) is
a worked example of the placement test, not a new hook: the loop's QA is
Layer 1 (`/kit:verify` inside the loop) plus the existing `ship-gate` at the
boundary; rule 1 says prose suffices for the loop's own verify step, rule 2
already covers the ship boundary. ID-027 (the autonomy-gate lens) lands in
Layer 1 as a `/kit:spec-validate` Reviewer 4 bullet: a spec whose behavior
runs inside an autonomous loop must not let the loop make a scope /
architecture / risk decision without a human gate.

## State model

The kit keeps a small set of distinct state stores. Keeping them distinct prevents the "what's left vs what's active vs the contract" confusion. Review output is not a separate store: it lives in the active spec as a `## Review` section (so concurrent worktrees and sessions never share a review file).

| Store | Committed? | Lifetime | Role |
|---|---|---|---|
| `_meta/BACKLOG.md` | yes (git) | durable | the queue of committed work ("what's left"); schema lives in that file |
| `docs/specs/SPEC-NNN-<slug>.md` | yes (git) | durable | the design contract per cycle ("the contract"); also carries the on-demand `## Review` section |
| `.claude/goals/<slug>.md` | no (gitignored) | ephemeral | candidate goal **drafts** ("what's active"); filesystem-authoritative, archive-on-ship lifecycle |
| `.claude/goals/done/<slug>.md` | no (gitignored) | ephemeral | archived drafts whose `target_spec` shipped; moved here (never deleted), skipped by the render commands |
| `.git/kit-goals/<slug>.goal` | no (under `.git`, untracked) | run-time | the cross-session running-goal **registry** claim ("what's executing now"); the lock that keeps N same-machine sessions disjoint |
| `.claude/last-goal.md` | no (gitignored) | ephemeral | the built-in `/goal`'s single active slot; the kit never writes it |

**Draft vs registry, the two "goal" stores side by side.** A goal **draft** (`.claude/goals/<slug>.md`) is design-time candidate work, "what's active." A registry **claim** (`.git/kit-goals/<slug>.goal`) is the run-time lock, "what's executing now" across concurrent same-machine sessions. They are not duplicates: the slug is the shared key tying a draft to its claim. A draft is filesystem-authoritative (no derived cache, ADR-0023) and is moved to `done/` once its `target_spec` ships (`lib/goal/goal-drafts.sh archive`, run by `/kit:ship`); a claim is created by `lib/goal/goal-registry.sh claim` and released when the goal completes.

The active spec among these is resolved by the SPEC-005 rule (`docs/specs/`, branch-selected when several are live). The `/kit:start`/`/kit:next` rendering of the backlog queue + goal drafts is wired in SPEC-006; both enumerate top-level `.claude/goals/*.md` (a non-recursive glob), so archived drafts under `done/` are skipped.

## Mega-goal orchestration: serial and wavefront (`lib/queue/orchestrate.sh`)

> The kit runs agents four different ways (board, this orchestrator, the queue, the gauntlet).
> `docs/execution-planes.md` compares them: what each is for, how they hand off, where they
> deliberately do not connect, and their differing trust and isolation models. This section
> owns this orchestrator's internals.

`orchestrate.sh run <megagoal-dir>` drives a mega-goal ROADMAP as one fresh `claude -p` session per
sub-goal (SPEC-087: no session accumulates more than one sub-goal's context). By default it runs
**strictly serially**. Opt-in **wavefront** scheduling lets dep-independent
sub-goals run as concurrent waves. The whole wave subsystem is gated behind one env var.

### The overnight queue launcher (`lib/queue/queue.sh`, a sibling, SPEC-148)

`orchestrate.sh` drives ONE mega-goal's sub-goals as headless `claude -p` sessions. `lib/queue/queue.sh`
is the complementary layer ABOVE that: a dumb sequential scheduler that runs a QUEUE of drafted
megas overnight, one after another. Crucially it uses a DIFFERENT mechanism, it drives the
operator's **live interactive** Claude Code `/goal` session, not a headless `claude -p`. It opens a
fresh `tmux` window (`TERMINAL_MUX`; cmux was tried and dropped -- no CLI-verified argv-safe
launch primitive, per SPEC-119 DEC-001 / SPEC-121 DEC-004), types `/goal <pointer>` via
`send-keys`, and polls `capture-pane` for the completion marker (`RUNNER_DONE` / `RUNNER_GATED:`),
line-anchored AND blank-line-guarded (a marker line must be the first captured line or preceded by
a blank line, so a soft-wrapped echo of the typed prompt -- designed to CONTAIN the marker text --
cannot false-trigger; a 2026-07-05 security review found the naive line-anchor alone was not
enough). This rides the operator's already-authed login and sidesteps the AUTH/KILL-CLASS risk of
a headless worker whose token expires or is killed independently (field-proven twice). It journals
every verdict to `queue-journal.tsv` (idempotent nights: a `done` slug is skipped on re-run) and
stops the whole night after two consecutive `error`-or-`stalled` megas (both signal the launch
mechanism itself is dysfunctional; an account-rate-limit circuit-breaker). Sources: a hand-authored
tsv (`slug<TAB>repo<TAB>pointer`, allow-list-EXEMPT: operator authorship is the trust boundary) or
`--from-boards` (runner-fastpath sub-goal 04's `board queue` emit; pointers additionally confined
by a `realpath`-resolved allow-list, defense-in-depth on top of 04's own confinement). Exposed as
`orchestrate.sh queue <src>` (a one-line alias; the logic lives in `queue.sh`, so orchestrate.sh's
own suite is untouched). The mux/marker mechanism lives in `lib/queue/queue.sh` `_launch_once` /
`_scan_marker`; the allow-list in `_pointer_allowlist_reason`.

### The per-cycle dispatch decision (waves are the default; serial is the opt-out)

Each loop cycle the driver decides serial-vs-wave on the **admitted** count, never raw readiness:

```text
                        ┌─────────────────────────── per cycle ───────────────────────────┐
  ROADMAP.md            │                                                                  │
  (- [ ] SG-NN          │   WAVE_CAP < 2 ?  ──yes──▶  SERIAL BODY  (unchanged, byte-        │
, auto|gate|gate!  │       │ no                   identical): _next() picks the first  │
     [depends SG-MM])   │       ▼                      unchecked, run ONE claude -p session │
        │               │   _wave_gate ▶ admitted set                                       │
        ▼               │       │                                                           │
   _ready_set  ───────▶ │   admitted < 2 ? ──yes──▶  SERIAL BODY (first READY pick)         │
   (unchecked AND all   │       │ no                                                        │
    `depends` checked)  │       ▼                                                           │
                        │   _wave_run  ▶  run admitted concurrently (cap WAVE_CAP)          │
                        │       │         then _wave_converge (merge one-at-a-time)         │
                        └───────┴──────────────────────────────────────────────────────────┘
```

`WAVE_CAP` defaults to **2** (ID-090 activation) ⇒ dep-independent sub-goals whose `## Touches` are
provably disjoint run concurrently. A mega-goal whose sub-goals declare NO `## Touches` still
serializes (admitted=0 ⇒ the `WAVE_CAP < 2` branch is not taken but `_wave_gate` admits nothing ⇒
serial fallthrough ⇒ byte-identical), so the default is a no-op for un-migrated mega-goals. Set
`WAVE_CAP=1` to force the old always-serial loop regardless of Touches. Dispatch keys on the
**admitted** count (not raw ready-set size) because a no-deps mega-goal has *every* unchecked
sub-goal ready at once; only sub-goals that survive admission run concurrently.

### The wavefront pipeline (what runs a wave)

```text
  _ready_set        _wave_gate                       _wave_run                    _wave_converge
  ──────────        ──────────                       ─────────                    ──────────────
  unchecked   ─▶    greedy, ROADMAP order:     ─▶    for each `run` id (cap N):   ─▶  merge landed
  AND deps          admit iff (a) declares its        · git worktree per sub-goal      branches ONE
  satisfied         OWN `## Touches` AND (b)           (.claude/worktrees/<id>)        AT A TIME,
                    proves disjoint (dispatch-         · claude -p (own proc group)     ROADMAP order,
                    gate.sh) vs every already-         · reap: kill -0 poll +           under the flip
                    admitted member; else `defer`      grounded box-flip check          lock; same-file
                    (Touches-less ⇒ always defer)      · sibling fails ⇒ drain,         overlap ⇒ refuse
                                                        mark failed, no orphans         (never silently
                                                        (SIGTERM kills the group)       clean-merge wrong)
```

Disjointness reuses `lib/gate/dispatch-gate.sh` (ONE disjointness authority, ADR-0019). The **self-Touches**
requirement matters: `dispatch-gate` admits the first member of a set vacuously, so without requiring a
candidate's own `## Touches`, a Touches-less sub-goal would be wrongly admitted. `commands/mega.md`
now emits a `## Touches` section per generated sub-goal, so newly-decomposed mega-goals are
wave-eligible by default; an existing mega-goal whose sub-goals predate that convention simply
serializes until its goal files declare Touches (the conservative fallback, never wrong).

### Completion, gates, and the concurrency-safety model

```text
  SHARED control plane (mega-goal dir)          per-session isolation (worktrees)
  ────────────────────────────────────          ─────────────────────────────────
  ROADMAP.md   ◀── cmd_flip <megadir> <id>       .claude/worktrees/<id>  (own checkout,
    (canonical  │   flips the box under an          own branch; where code changes land)
     boxes)     │   mkdir-lock, write-temp-       claude -p session (own process group,
                │   then-mv (atomic rename)         so SIGTERM kills the whole tree)
  .orchestrate/ │                                 HANDOFF-<id>.md  (per-edge feed-forward:
    events.log  │   append-only, replay-derived    written iff the sub-goal has DEPENDENTS;
    (completion │   (a crashed/concurrent           a child injects each dep-parent's file,
     substrate) │    session cannot corrupt it)     falling back to plain HANDOFF.md)
                ▼
  flip.lock/    mkdir-lock: PID-liveness stale reclaim (alive⇒wait / dead⇒reclaim /
                unreadable⇒reclaim past FLIP_LOCK_STALE_SECS), rmdir only, never rm -rf
```

Box flips target the **shared** `$megadir/ROADMAP.md` by absolute path (never a worktree's own copy,
which the driver would never see). Two **gate** policies:

- `gate`, **chain-stop**: holds only its own dependent chain; independent branches keep running.
- `gate!`, **stop-all**: quiesces the whole loop for a human (today's global-stop, preserved).

On a Touches-less mega-goal (no concurrency) a `gate` still stops the whole loop via the serial
fallthrough, so `gate` semantics only visibly differ once sub-goals declare Touches and a real wave
forms, at which point `gate` holds its chain while independent branches run, and the driver emits a
one-time advisory pointing to `gate!` for a global stop-all. The default flip to `WAVE_CAP=2`
was gated on an audit that no live mega-goal ROADMAP relies on `gate`=global-stop (clean).

**Env surface:** `WAVE_CAP` (default **2** = waves on; `1` forces serial; integer `>=1`), `FLIP_LOCK_STALE_SECS` (default 120),
`WAVE_MERGE_CMD` (the convergence merge hook; real `gh`-backed wiring is ID-090). Full design +
exit-criteria proof: `docs/specs/SPEC-106-dag-wavefront-scheduling.md` + `docs/verification/orchestrate-wavefront.md`.

## Verification pipeline (the load-bearing piece)

```
worker subagent completes task
  v
task-verifier (read-only) checks acceptance criteria + tests
  +--> PASS:  mark done in docs/specs/SPEC-NNN-<slug>.md, continue
  +--> FAIL:fixable:  dispatch fix-agent (write-scoped, retry_count < 2)
  |     |
  |     v
  |   re-run task-verifier
  +--> FAIL:escalate (or retry >= 2):  stop, ask human
```

Read-only verifier and write-scoped fix-agent are different subagents on purpose. The verifier cannot "fix" things by silently rewriting code; it can only report. The fix-agent is bounded by the scope the verifier names. See ADR-0005.

## Collaborative Design Protocol

When an agent encounters a 2+ way design decision during implementation, it follows this 5-step protocol. Referenced by `agents/code-reviewer.md`, `agents/security-reviewer.md`, `commands/execute.md`. Original ADR: 0007.

### When to invoke
- 2+ valid implementation approaches and the choice materially affects the outcome
- A decision is irreversible or expensive to undo (data model, API contract, architecture pattern)
- The spec is ambiguous and the agent must interpret intent

Do NOT invoke for:
- Obvious single-approach tasks (fix a typo, add a missing import)
- Style decisions covered by project rules (naming, formatting)
- Decisions already made in the spec's Decision Log

### The 5 steps

**Step 1: Question.** State the decision in one sentence.
```
DECISION NEEDED: Should user auth use JWT tokens or session cookies?
```

**Step 2: Options.** 2-3 options, each with what / tradeoff / when-it-wins.
```
OPTION A: JWT tokens
  + Stateless, scales horizontally, good for API-first
  - No server-side revocation without blacklist
  Best when: multiple clients (web + mobile), microservices

OPTION B: Session cookies
  + Server-side revocation, simpler security model
  - Requires session store (Redis), sticky sessions for scale
  Best when: single web app, strong revocation requirements

OPTION C: JWT + refresh token rotation
  + Stateless access + revocable refresh
  - More complex, two token types to manage
  Best when: need both API flexibility and revocation
```

**Step 3: Recommendation.** Which option, and why.
```
RECOMMENDATION: Option A (JWT tokens)
REASON: The spec describes an API consumed by web + mobile. No revocation
requirement is mentioned. JWT is simpler for this use case.
```

**Step 4: Decision.** Mode-dependent.
- **Lead mode**: Pause and ask the human. Use AskUserQuestion if available.
- **Coder mode / subagent**: Orchestrator or verifier picks. If the recommendation aligns with the spec, proceed; if it contradicts, escalate.
- **Autonomous mode** (/execute): Proceed with the recommendation. Log it. The task-verifier will catch misalignment.

**Step 5: Record.** Append to `docs/specs/SPEC-NNN-<slug>.md` Decision Log:
```
- DEC-[N]: [decision] -- [rationale] -- [alternatives rejected] -- [who decided: human/orchestrator/auto]
```

### Activation lines

In an agent prompt:
```
When you encounter a decision with 2+ valid approaches, follow the
Collaborative Design Protocol in docs/architecture.md. Present options,
recommend one, and proceed according to your mode (lead/coder/autonomous).
```

In a command that dispatches an agent:
```
## Decision mode
[lead: pause for human approval / autonomous: proceed with recommendation and log]
```

The orchestrator in `/execute` defaults to `autonomous` for worker subagents (the verifier catches bad decisions after the fact) and `lead` when the user is running `/next` manually.

## Dependencies

### Required
| Tool | Why | Install |
|---|---|---|
| jq | Parse JSON in hook scripts; merge settings.json | `brew install jq` (macOS), `apt install jq` (Linux) |
| git | Branch detection, diff for review, commit for ship | Pre-installed on most systems |
| Claude Code | The agent runtime the kit extends | `npm install -g @anthropic-ai/claude-code` |

### Recommended
| Tool | Why | Install |
|---|---|---|
| Context Hub (chub) | Curated API docs prevent hallucinated APIs | `npm install -g @aisuite/chub` |
| Context7 | Library docs via MCP (React, Next.js, etc.) | MCP server, connect in Claude Code settings |
| codebase-memory-mcp | AST-level codebase indexing for large projects | MCP server, connect in Claude Code settings |
| trash (macos-trash) | Safe delete alternative (safety-gate suggests it) | `brew install macos-trash` |

### Formatters auto-detected by `hooks/auto-format.sh`
| Formatter | Languages | Install |
|---|---|---|
| prettier | JS, TS, CSS, JSON, MD, HTML | `npm install -g prettier` or project-local |
| gofmt | Go | Bundled with Go |
| ruff | Python | `uv tool install ruff` or `pip install ruff` |
| black | Python (fallback if ruff not found) | `pip install black` |
| rustfmt | Rust | Bundled with Rust toolchain |

The hook detects in this order: project-local binary, global binary, npx cache only (`npx --no`). It never downloads from the network mid-edit (regression fix in v1.1).

## Where things write to disk

Beyond the repo itself, the kit writes to:

| Path | What | Who writes |
|---|---|---|
| `${XDG_STATE_HOME:-~/.local/state}/dwarves-kit/logs/runs/<rid>.log` | Per-run gate/routing ledger, the retro + eval corpus (DURABLE: outside the plugin-reinstall blast zone, SPEC-097; legacy `~/.claude/dwarves-kit/logs` migrated in additively) | gate-ledger.sh |
| `${XDG_STATE_HOME:-~/.local/state}/dwarves-kit/logs/completeness.log` | Lane-downgrade / completeness records | lane-classify.sh (write), lane-telemetry.sh (read) |
| `${XDG_STATE_HOME:-~/.local/state}/dwarves-kit/logs/proof-overrides.log` | Logged proof-of-done overrides | proof-ledger.sh |
| `~/.claude/dwarves-kit/logs/anti-rationalization.log` | Blocked Stop-event patterns | anti-rationalization.sh |
| `~/.claude/dwarves-kit/logs/safety-gate.log` | Blocked destructive Bash commands | safety-gate.sh |
| `~/.claude/dwarves-kit/logs/secrets-guard.log` | Blocked secret-file reads (path + tool, never contents) | secrets-guard.sh |
| `~/.claude/dwarves-kit/logs/commit-format.log` | Blocked non-conventional commit subjects | commit-format.sh |
| `~/.claude/dwarves-kit/logs/spec-drift-guard.log` | Files created outside the spec | spec-drift-guard.sh |
| `~/.claude/dwarves-kit/logs/slop-cleaner.log` | Bloat detections | slop-cleaner.sh |
| `.claude/session-state/last-state.md` | Latest session snapshot | session-state-save.sh |
| `.claude/session-state/archive/*` | Last 10 rotated snapshots | session-state-save.sh |
| `.claude/debug/<slug>.md` | Per-bug evidence ledger (Symptoms / Root cause / Evidence / Eliminated / Fix attempts / Resolution) | /kit:debug |
| `.claude/debug/<slug>.log` | `[DEBUG Hn]`-tagged instrumentation output | /kit:debug |

All `.claude/` paths are gitignored (the kit ignores `.claude/`); downstream templates ignore it too.

Logs are the eval corpus for future prompt optimization. See PHILOSOPHY.md, "AutoResearch optimization" section.

## Install paths

Two paths, do not run both. See ADR-0009.

1. **Plugin install** (recommended): `/plugin marketplace add dwarvesf/dwarves-kit` + `/plugin install kit@dwarves-marketplace`. Uses `.claude-plugin/plugin.json` + `hooks/hooks.json` with `${CLAUDE_PLUGIN_ROOT}` references. No `statusLine` (v1 plugin schema gap).
2. **Bash install** (alternative): `bash install.sh`. Uses root `settings.json` with absolute paths. Configures `statusLine`. Requires `jq`, `git`, `bash`.

## The estate (overlays and seams)

This kit is the engine of a small estate and installs alone. Two other kits pair with it,
each in its own repo with its own version, and each stays optional:

| Kit | Plane | Relationship to the engine |
|---|---|---|
| context-kit (horizontal) | data: the user's context tree (`self/ people/ projects/ topics/ journal/`), recall, export | requires nothing; fills `[knowledge] root` (through `ctx adopt`) and puts `prose-rag` on PATH, which `bin/prose-rag` resolves; the vendored engine copy is gone |
| learning-kit (vertical) | study skills, presets, a `study` lane, a concept ledger | requires the engine (floor 2.0); overlays skills and a `lanes.d` plan, writes the same ledger with `lane=study`, fills `[wrap] before` with its concept flush |

The only runtime coupling is a **seam**: a key in the operator `kit.toml` that the
engine reads with `kit_config_get_root` (operator file, then kit root, never a project
`.kit.toml`) and an overlay fills at install. `bin/config seams [--check]` lists every
seam as `default | filled | unresolved | absent`; the table and its rules are
`lib/config/module-registry.md` `## Seams`. Install and data point in
opposite directions: overlays install on the engine, every kit writes knowledge into
the tree. The engine never calls an overlay and never branches on a kit name; a vertical
feature that needs engine code becomes an absorption row. The cross-repo map, the
install matrix, and the release policy live in the forge program repo
(`docs/ARCHITECTURE.md`, `docs/design/kit-distribution.md`, `docs/design/kit-versioning.md`).

## SDLC state machine

The "## State model" above is the *data* state (the three stores). This is the *process*
state: the states a single unit of work moves through, and the guarded transitions
between them. It is the formal model behind `WORKFLOW.md`'s cycle/lanes (the rules) and
`docs/MANUAL.md`'s "## Operator scenarios" (the operator-facing projection). The point of
declaring it is that at any moment Claude (and the operator) can answer four questions
without guessing: where am I, where can I go, what does each transition cost/require (the
guard), and how do I trigger it.

### States

| State | Meaning | Entry | Exit |
|---|---|---|---|
| `IDLE` | no active unit of work | session start; an item shipped/abandoned | intake |
| `TRIAGING` | intake: intent -> lane + (eventually) an ID | `/assign`, `/think`, "apply SDD", a vague brief | lane chosen |
| `DESIGNING` | solution exploration (iterative) | full lane, or "let's design" | solution approved |
| `SPECIFYING` | the spec is being written | `/spec` | spec `DRAFT` exists |
| `VALIDATING` | adversarial spec review | `/spec-validate` | `VALIDATED` or NEEDS REVISION |
| `BUILDING` | execution sub-machine (worker -> verifier -> fix -> integration) | `/execute`, `/next` | all tasks + integration PASS |
| `REVIEWING` | code review | `/review`, `/review-team` | verdict recorded |
| `DOCUMENTING` | doc sync + doc-verifier | `/docs` | docs match code |
| `SHIPPING` | ship pipeline | `/ship` | tagged/PR; spec `SHIPPED` |
| `REFLECTING` | retrospective | `/retro` | retro written |
| `DEBUGGING` | off-cycle debug sub-machine (iron law) | `/debug` | root cause + fix verified; human-confirm only when `debug.confirm_fix=true` |
| `BLOCKED` | meta-state: parked, awaiting a human | "park", "I'm stuck", a hard stop, escalate | unblock / abandon |
| `SHIPPED` | terminal: the item is done | `/ship` completes | (re-open -> TRIAGING) |
| `ABANDONED` | terminal: the item is dropped | "kill it" | none |

### Master diagram

```text
                          ┌────────────────────────── re-open ("follow-up") ──────────────────────────┐
                          ▼                                                                            │
   ┌──────┐  intake     ┌──────────┐  lane=full      ┌───────────┐  approved   ┌────────────┐         │
   │ IDLE │ ──────────▶ │ TRIAGING │ ─────────────▶  │ DESIGNING │ ──────────▶ │ SPECIFYING │         │
   └──────┘             └────┬─────┘                 │ ⇄ iterate │             └─────┬──────┘         │
      ▲                      │ lane=normal           └───────────┘                   │ DRAFT          │
      │ shipped              │ (skip design)                                          ▼                │
      │                      ├──────────────────────────────────────────────▶  VALIDATING            │
      │                      │ lane=tiny: edit->verify->done (no spec)               │ VALIDATED       │
      │                      │ lane=bug ─────────────▶ DEBUGGING                      │  ▲ NEEDS        │
      │                      │ lane=backfill: docs only, no app code                  │  │ REVISION     │
      │                      ▼                                                        ▼  │              │
      │            ┌──────────────────────────────────────────────────────────▶ BUILDING ────────────┘
      │            │  guard: all tasks PASS + integration PASS                       │ ⇄ retry (fix<=2)
      │            │  guard (hard): verification pipeline, anti-rationalization      │ escalate
      │            ▼                                                                  ▼
      │        REVIEWING ◀── FIX THEN SHIP / DO NOT SHIP (loop back to SPECIFYING/BUILDING)
      │            │ SHIP / fixes applied
      │            ▼
      │       DOCUMENTING ──▶ SHIPPING ──▶ REFLECTING ──▶ (SHIPPED) ──▶ IDLE
      │                       │  guard (hard): DO-NOT-SHIP verdict, push-to-main blocker
      │                       │
   (any state) ──"park"/"stuck"/escalate──▶ BLOCKED ──resume──▶ (prior state)
   (any state) ──"kill it"──▶ ABANDONED (terminal)
   (any state) ──bug found──▶ DEBUGGING ──root cause+fix+confirm──▶ (prior state)
```

### Transition table (the contract)

| From | Trigger (phrase / command) | Guard | To |
|---|---|---|---|
| IDLE | "what's next" then pick; `/assign ID`; "apply SDD X"; vague brief | none | TRIAGING |
| TRIAGING | lane = full | scope confirmed | DESIGNING |
| TRIAGING | lane = normal | scope confirmed | SPECIFYING |
| TRIAGING | lane = tiny | trivial edit | BUILDING (no spec) |
| TRIAGING | lane = bug | a defect | DEBUGGING |
| DESIGNING | "iterate", redirect | per-section approval pending | DESIGNING |
| DESIGNING | "design is good, write the spec" | solution approved | SPECIFYING |
| SPECIFYING | `/spec` done | spec `DRAFT` exists | VALIDATING (full) / BUILDING (normal) |
| VALIDATING | `/spec-validate` verdict | VALIDATED | BUILDING |
| VALIDATING | NEEDS REVISION | revisions required | SPECIFYING |
| BUILDING | task FAIL:fixable | retries < 2 | BUILDING (fix-agent) |
| BUILDING | task FAIL:escalate / retries == 2 | unfixable | BLOCKED |
| BUILDING | "also do Y" / "amend the spec" | at a task checkpoint; completed tasks frozen; Status stays VALIDATED | SPECIFYING (amend, not restart) |
| SPECIFYING | resume via `/next` | amend recorded | BUILDING (resume) |
| BUILDING | all tasks done | **all PASS + integration PASS** (hard) | REVIEWING |
| REVIEWING | verdict SHIP / FIX-applied | not DO-NOT-SHIP | DOCUMENTING |
| REVIEWING | FIX THEN SHIP / DO NOT SHIP | findings open | SPECIFYING / BUILDING |
| DOCUMENTING | `/docs` done | doc-verifier PASS | SHIPPING |
| SHIPPING | `/ship` | **not DO-NOT-SHIP, not push-to-main** (hard) | REFLECTING |
| REFLECTING | `/retro` done | retro written | SHIPPED -> IDLE |
| any | "park" / "I'm stuck" | a blocker exists | BLOCKED |
| any | "kill it, not worth it" | operator confirms | ABANDONED |
| any | a bug surfaces | a defect | DEBUGGING |
| SHIPPED | "the shipped X needs a follow-up" | none | TRIAGING (new spec) |

### Sub-machines

- **BUILDING** expands to: `worker -> task-verifier -> {PASS | FAIL:fixable -> fix-agent (<=2) | FAIL:escalate} -> integration-verifier`. The diagram is in `docs/WORKFLOW.md` "## Flow and loop reference" (the execute pipeline), and the read-only contract is in "## Verification pipeline" above.
- **DEBUGGING** expands to: `Phase 1 Root cause -> Phase 2 Pattern -> Phase 3 Hypothesis -> Phase 4 Implementation`, under the iron law (no fix without a recorded root cause), guarded by the guess-fix guard. The diagram is in `docs/WORKFLOW.md` "## Flow and loop reference" (the debug loop).

### Hard stops as guards (the only blockers)

| Hard stop | Guards the transition | Effect |
|---|---|---|
| safety-gate | any transition running destructive Bash | blocks the command |
| push-to-main | SHIPPING -> (the push) | blocks the push |
| anti-rationalization | BUILDING -> REVIEWING; any -> "done" | blocks premature/false done |
| verification pipeline | BUILDING -> REVIEWING | blocks if a task fails |

Everything else is advisory: it suggests the transition, it does not block it. The
implementing specs for the gap-closing transitions (the freeform front door, the
mid-flight amend) are in `docs/specs/`; this model is their acceptance reference.

<!-- provenance: ADR-0010 (spec-location convention), ADR-0019, ADR-0022, ADR-0025, ADR-0028 -->
