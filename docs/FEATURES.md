---
title: Feature registry
status: GENERATED projection
generator: lib/registry/feature-registry.sh
---

# Feature registry

GENERATED , do not hand-edit. Regenerate: `bash lib/registry/feature-registry.sh generate`. One row per live feature; freshness pinned by `tests/test-meta.sh` (regenerate-and-diff). Trigger classes per `docs/workflow-paths.md` section 1: `[H]` human-typed, `[H/I]` human-or-intent, `[I]` intent-read, `[E]` event-fired, `[D]` dispatched. Refs are exact-token greps: Specs over `docs/specs/`, Tests over `tests/*.sh`, Dispatched-by over `commands/*.md` + `skills/*/SKILL.md` (skill dispatchers marked `(skill)`); `-` means no reference found (a coverage gap, not always a defect: read-only agents may be deliberately untested).

## Commands

| Command | Trigger | Description | Specs | Tests |
|---|---|---|---|---|
| `/kit:absorb` | `[H/I]` | Maintainer-only: audit the kit's upstream sources (Credits drift + seed-rescan) and draft a dated, proposal-only absorption report. Does no… | SPEC-004, SPEC-007, SPEC-009 +7 | test-command-emit-sweep.sh, test-hooks.sh, test-meta.sh |
| `/kit:adopt` | `[H/I]` | Adopt the current (or a target) repo into the dwarves-kit operate-contract: inject AGENTS.md + a CLAUDE.md loader + a WORKFLOW pointer + th… | SPEC-004, SPEC-013, SPEC-014 +20 | proof-loop-09-scenario-b.sh, test-adopt.sh, test-command-emit-sweep.sh +5 |
| `/kit:assign` | `[H/I]` | Turn a backlog item (ID-NNN) into a scoped goal draft and route it into the right WORKFLOW lane. Writes .claude/goals/, never executes. | SPEC-006, SPEC-007, SPEC-024 +32 | test-hooks.sh, test-meta.sh |
| `/kit:battery` | `[H/I]` | The full independent-verification battery for a finished branch: a fresh-context acceptance verifier that RE-EXECUTES the verification comm… | SPEC-239, SPEC-244, SPEC-245 +2 | run-workflow.sh, test-break-it.sh, test-hooks.sh |
| `/kit:debug` | `[H/I]` | Systematic debug loop: root cause before any fix. Four phases, an evidence ledger, the 3-fix architecture wall. | SPEC-006, SPEC-013, SPEC-014 +11 | test-config-registry.sh, test-hooks.sh, test-loop-engineering-contract.sh +1 |
| `/kit:design` | `[H/I]` | Opt-in interactive solution-design beat between /think and /spec. Explores 2-3 approaches one question at a time, holds for your approval p… | SPEC-003, SPEC-004, SPEC-005 +105 | test-command-emit-sweep.sh, test-design-record.sh, test-gate-vocab-recording.sh +19 |
| `/kit:devs-team` | `[H/I]` | Parallel multi-lens critique of a solution design (the active spec if present, else the decision brief). Dispatches 5 engineering lenses, m… | SPEC-016, SPEC-018, SPEC-019 +11 | test-gate-vocab-recording.sh, test-meta.sh, test-outcome-emit-sweep.sh |
| `/kit:dispatch` | `[H/I]` | Fire several disjoint VALIDATED specs concurrently, each in its own worktree, then converge. Cross-goal fan-out behind a disjointness gate … | SPEC-002, SPEC-016, SPEC-017 +77 | test-advisor-ledger-emit.sh, test-agent-effectiveness.sh, test-audit-scanner-contract.sh +30 |
| `/kit:docs` | `[H/I]` | Update all project documentation to match the current codebase. Cross-references the diff against every doc file and fixes drift. | SPEC-001, SPEC-002, SPEC-003 +182 | proof-loop-09-scenario-b.sh, run-workflow.sh, test-adopt.sh +60 |
| `/kit:draft-agent` | `[H/I]` | Meta-agent agent-builder. From a one-line description, generates a new subagent definition OR a mega-goal sub-goal file and (by default) in… | SPEC-089, SPEC-108, SPEC-139 +1 | test-agent-effectiveness.sh, test-command-emit-sweep.sh, test-meta-agent.sh +1 |
| `/kit:execute` | `[H/I]` | Autonomous spec execution with verification. Dispatches worker subagents per task, verifies each with task-verifier, retries fixable failur… | SPEC-001, SPEC-003, SPEC-004 +58 | test-break-it.sh, test-gate-vocab-recording.sh, test-hooks.sh +9 |
| `/kit:explain` | `[H/I]` | Turn a merged change into a literate-diff explainer a human READS to understand: background -> goal + intuition -> a prose-ordered diff -> … | SPEC-050, SPEC-060, SPEC-094 +17 | proof-loop-09-scenario-b.sh, test-command-emit-sweep.sh, test-config-registry.sh +9 |
| `/kit:feature-map` | `[H/I]` | Build or refresh a source-cited, agent-checkable feature inventory for ANY target project you point it at: per-module spec + a top-level ch… | SPEC-218, SPEC-219, SPEC-220 +2 | test-command-emit-sweep.sh |
| `/kit:gauntlet` | `[H/I]` | Probe-convergence engine: a bounded-revise loop that converges an ARTIFACT (docs, a runbook, a spec, an API surface) toward a FIXED OUTCOME… | SPEC-226, SPEC-227, SPEC-228 +9 | test-gauntlet-proof-audit.sh, test-meta.sh |
| `/kit:greenlight` | `[H/I]` | Post-push CI-green lane: snapshots an open PR's checks via gh, classifies each failure real vs flaky, fixes real ones via the fix-agent sha… | SPEC-019, SPEC-217 | - |
| `/kit:grill` | `[H/I]` | Universal intake interview: one type-shaped question at a time, each with a recommended answer, until the task is actually understood. Answ… | SPEC-058, SPEC-059, SPEC-063 +19 | test-config-stamp.sh, test-e2e.sh, test-gate-outcome.sh +7 |
| `/kit:kit-health` | `[H/I]` | Run a self-assessment of the kit against its own philosophy. Checks file count, hook performance, source citations, and structural health. | SPEC-001, SPEC-002, SPEC-004 +16 | test-command-emit-sweep.sh, test-meta.sh |
| `/kit:mega` | `[H/I]` | Turn a multi-objective destination into a sequenced roadmap of dependent sub-goals: decompose, front-load every clarification once, set the… | SPEC-034, SPEC-036, SPEC-088 +33 | proof-loop-09-scenario-b.sh, test-advisor-ledger-emit.sh, test-bin-forwarders.sh +23 |
| `/kit:next` | `[H/I]` | Pick up the next undone task from the spec. Loads context, shows acceptance criteria, lets you drive the implementation. | SPEC-001, SPEC-002, SPEC-003 +83 | test-advisor-ledger-emit.sh, test-advisor.sh, test-agent-effectiveness.sh +29 |
| `/kit:onboard` | `[H/I]` | Guided first-run: detect the install mode, offer /kit:adopt for this repo, pick modules, capture the consumer knobs that make them work, di… | SPEC-199, SPEC-213, SPEC-232 +1 | proof-loop-09-scenario-b.sh, test-command-emit-sweep.sh, test-onboard-detect.sh |
| `/kit:pitch` | `[H/I]` | Assemble an outward buy-in doc from what a gated run already produced: the spec, the proof-of-done, the implementation-notes, and the gate … | SPEC-140, SPEC-141, SPEC-193 | test-outcome-emit-sweep.sh, test-pitch.sh |
| `/kit:prototype` | `[H/I]` | Opt-in throwaway-spike beat beside /kit:design. Builds throwaway code that answers ONE design question: a logic/state model driven by hand … | SPEC-075, SPEC-206, SPEC-207 +2 | test-picture-section.sh |
| `/kit:quiz-gate` | `[H/I]` | The ★-tap NUDGE before merging a significant+worthy gate PR: a 5-question quiz built from the ACTUAL diff+tests, routed through deep-unde… | SPEC-125, SPEC-127, SPEC-136 +2 | test-install-modules.sh, test-kit-contract.sh, test-quiz-gate.sh +2 |
| `/kit:retro` | `[H/I]` | Run a retrospective after shipping. Captures what worked, what didn't, and action items for the next cycle. Outputs to docs/retro/RETRO.md. | SPEC-002, SPEC-003, SPEC-006 +36 | test-command-emit-sweep.sh, test-gate-vocab-recording.sh, test-hooks.sh +3 |
| `/kit:review-team` | `[H/I]` | Parallel code review with 3 specialist lenses plus the kit-default advisor extra lens. Dispatches the security, architecture, and test-cove… | SPEC-002, SPEC-003, SPEC-007 +40 | test-advisor-ledger-emit.sh, test-advisor.sh, test-every-step-review.sh +6 |
| `/kit:review` | `[H/I]` | Paranoid code review. Security, architecture, regressions, missing tests, edge cases. Produces actionable TODOS. | SPEC-001, SPEC-002, SPEC-003 +101 | test-adopt.sh, test-advisor-ledger-emit.sh, test-agent-effectiveness.sh +38 |
| `/kit:ship` | `[H/I]` | Ship: review gate, tests, version bump, changelog, conventional commit, docs update, PR. Complete pipeline from done to merged. | SPEC-001, SPEC-002, SPEC-003 +74 | test-board-mirror.sh, test-cheap-guards.sh, test-config-registry.sh +25 |
| `/kit:spec-validate` | `[H/I]` | Adversarial review of a spec before implementation. 6 specialist lenses attack the spec from different angles (5 advisory, 1 blocking on th… | SPEC-002, SPEC-003, SPEC-004 +58 | test-command-emit-sweep.sh, test-design-record.sh, test-every-step-review.sh +7 |
| `/kit:spec` | `[H/I]` | Generate a development spec from a feature idea or decision brief. Creates docs/specs/ with structured requirements. | SPEC-001, SPEC-002, SPEC-003 +158 | test-bin-forwarders.sh, test-break-it.sh, test-command-emit-sweep.sh +43 |
| `/kit:start` | `[H/I]` | Detect project state and suggest the right next command. The entry point for any session. | SPEC-002, SPEC-003, SPEC-004 +42 | test-command-emit-sweep.sh, test-config-stamp.sh, test-e2e.sh +28 |
| `/kit:test-plan-review-team` | `[H/I]` | Parallel multi-lens adversarial critique of a spec's test plan (the ## Test plan section), with a bounded revise loop that tightens it. Dis… | SPEC-031, SPEC-052, SPEC-062 +10 | test-meta.sh, test-outcome-emit-sweep.sh |
| `/kit:test-plan` | `[H/I]` | Derive a test-case coverage matrix from a spec's acceptance criteria before /kit:execute. Writes a `## Test plan` section into the active s… | SPEC-004, SPEC-016, SPEC-018 +27 | test-e2e.sh, test-gate-vocab-recording.sh, test-goal-dispatch.sh +4 |
| `/kit:test-write` | `[H/I]` | Turn a SOLID-verdict `## Test plan critique` into real, executing test code via `kit:test-writer`, one case per matrix row. Never dispatche… | SPEC-203, SPEC-227, SPEC-237 | test-test-writer-contract.sh |
| `/kit:think` | `[H/I]` | Challenge an idea before writing any spec. 6 forcing questions that reframe the product. | SPEC-003, SPEC-004, SPEC-005 +30 | test-command-emit-sweep.sh, test-config-stamp.sh, test-e2e.sh +7 |
| `/kit:ui-design` | `[H/I]` | Downstream UI-design loop: write a structured ## UI design brief, delegate generation to the external frontend-design skill, critique via /… | SPEC-020, SPEC-023, SPEC-102 +6 | test-command-emit-sweep.sh, test-hooks.sh, test-meta.sh +1 |
| `/kit:verify` | `[H/I]` | Re-run the test levels (task-verifier + integration-verifier + acceptance-verifier + system-verifier) on the current spec/branch read-only,… | SPEC-002, SPEC-003, SPEC-006 +37 | test-break-it.sh, test-command-emit-sweep.sh, test-gate-vocab-recording.sh +6 |
| `/kit:visual-team` | `[H/I]` | Parallel multi-lens critique of a visual/UI design. Dispatches 5 design lenses, merges findings, reports a verdict. Report-only, downstream… | SPEC-016, SPEC-018, SPEC-019 +10 | test-command-emit-sweep.sh, test-meta.sh |
| `/kit:wayfind` | `[H]` | Plan a chunk of work too big for one agent session as a shared decision map: map.md + typed decision tickets in the mega-goal folder, resol… | SPEC-206, SPEC-207, SPEC-217 +2 | - |
| `/kit:wrap` | `[H/I]` | The session-scoped landing step after ship: flips board rows, merges the operator's own green PRs one at a time, checks deploys, tidies bra… | SPEC-020, SPEC-060, SPEC-072 +9 | test-bin-forwarders.sh, test-config-seams.sh, test-hooks.sh +1 |

## Agents

| Agent | Trigger | Dispatched by | Description | Specs | Tests |
|---|---|---|---|---|---|
| `acceptance-verifier` | `[D]` | battery, verify | Dynamically executes the active spec's acceptance criteria via its `## Verification` section and reports whether the build actually satisfi… | SPEC-035, SPEC-090, SPEC-092 +4 | test-every-step-review.sh, test-kit-contract.sh, test-meta.sh +1 |
| `advisor` | `[D]` | adopt, battery, mega +3 | The single cross-cutting generic review lens (ADR-0028 SG-05/P5-P6). Runs in TWO modes at the final integration/UAT boundary -- critique (a… | SPEC-090, SPEC-091, SPEC-092 +22 | proof-loop-09-scenario-b.sh, test-adopt.sh, test-advisor-ledger-emit.sh +14 |
| `agent-effectiveness` | `[D]` | draft-agent, loop-engineering (skill) | Validates an agent definition's EFFECTIVENESS (not just its structure) across four lenses -- tools minimal-yet-sufficient, description trig… | SPEC-088, SPEC-090, SPEC-091 +4 | test-advisor.sh, test-agent-effectiveness.sh, test-break-it.sh +2 |
| `api-reviewer` | `[D]` | battery, review-team | Reviews a diff through the API-CONTRACT lens only (breaking changes, versioning, request/response schema, error codes, backward compat, ide… | SPEC-111 | test-meta.sh |
| `audit-scanner` | `[D]` | backlog-reconcile (skill), ci-drift (skill), doc-drift (skill) +3 | Shared read-only Tier-2 evidence scanner for audit-loop instances (doc-drift, topology-drift, ci-drift, backlog-reconcile, web-drift, futur… | SPEC-220, SPEC-222, SPEC-225 +2 | test-audit-scanner-contract.sh, test-meta.sh |
| `break-it` | `[D]` | battery | The adversarial prober lens. Given a branch whose behavioral code carries a green test suite, it hunts for a concrete INPUT or CALL SEQUENC… | SPEC-247, SPEC-249 | test-break-it.sh, test-meta.sh |
| `brief-reviewer` | `[D]` | think | Statically reviews a design brief or requirement (DECISION-BRIEF.md, a spec's Problem/Context section, or an equivalent requirement doc) fo… | SPEC-092, SPEC-108, SPEC-225 | test-every-step-review.sh, test-kit-contract.sh, test-meta.sh +1 |
| `claim-verifier` | `[D]` | - | Adversarially verifies an ARBITRARY free-text claim before it is trusted. Runs an in-harness panel of N independent skeptics, each told to … | SPEC-195 | test-meta.sh |
| `code-reviewer` | `[D]` | battery, devs-team, review-team +1 | Focused code reviewer. Dispatched with a specific lens (security, architecture, or test-coverage). Read-only. Used by /review-team for para… | SPEC-090, SPEC-092, SPEC-109 +9 | test-review-team-plants.sh |
| `data-etl-worker` | `[D]` | - | Implements a data pipeline/transform task, extract/transform/load, parsing, dedup, normalization. Write-capable; prefers DuckDB SQL for the… | SPEC-111 | test-meta.sh, test-role-classify.sh |
| `db-migration-worker` | `[D]` | - | Implements a schema migration task, the up migration plus its reverse/rollback, backfill, and index changes. Write-capable. Dispatched by /… | SPEC-111 | test-meta.sh, test-role-classify.sh |
| `devops-triage` | `[D]` | - | Triages a production error alert (service name, error sample, optional deploy sha) into a bounded root-cause verdict, gathering evidence vi… | SPEC-239 | test-meta.sh |
| `doc-verifier` | `[D]` | docs, draft-agent, execute +1 | Verifies that documentation matches the code. Dispatched by /docs after it updates docs, before the commit. Read-only -- cannot edit docs o… | SPEC-021, SPEC-022, SPEC-023 +11 | test-agent-effectiveness.sh, test-every-step-review.sh, test-meta.sh |
| `fix-agent` | `[D]` | debug, dispatch, execute +5 | Applies targeted fixes based on task-verifier feedback. Scoped to specific files and specific issues. Does not add features or refactor. | SPEC-003, SPEC-007, SPEC-013 +9 | test-meta.sh |
| `frontend-reviewer` | `[D]` | battery, review-team | Reviews a diff through the FRONTEND lens only (a11y/ARIA, semantic HTML, focus/keyboard, state handling, responsive/viewport, color-only si… | SPEC-111, SPEC-237 | test-meta.sh |
| `infra-reviewer` | `[D]` | battery, review-team | Reviews a diff through the INFRA lens only (deploy/rollback safety, CI/CD config, container/IaC least-privilege, secret handling, idempoten… | SPEC-111 | test-meta.sh |
| `integration-verifier` | `[D]` | execute, verify | Verifies that the tasks of a completed build actually wire together. Dispatched once at /execute Step 4 for multi-task specs. Read-only -- … | SPEC-090, SPEC-092, SPEC-115 +1 | test-agent-effectiveness.sh, test-every-step-review.sh, test-meta.sh +2 |
| `meta-agent` | `[D]` | draft-agent, execute | The agent that drafts agents. From a one-line description, drafts a new subagent definition OR a new mega-goal sub-goal file, matching the … | SPEC-088, SPEC-089, SPEC-090 +5 | test-meta-agent.sh, test-meta.sh, test-model-routing.sh |
| `performance-reviewer` | `[D]` | battery, review-team | Reviews a diff through the PERFORMANCE lens only (hot paths, N+1, allocations, caching, latency, complexity). Read-only. Dispatched by /kit… | SPEC-111 | test-meta.sh |
| `recheck-verifier` | `[D]` | execute | Fresh-context re-audit of a right-arm verifier's PASS (task-verifier / integration-verifier / acceptance-verifier / system-verifier). RE-EX… | SPEC-090, SPEC-092, SPEC-107 +5 | proof-loop-09-scenario-b.sh, test-every-step-review.sh, test-meta.sh +1 |
| `research-architecture` | `[D]` | spec | Maps architecture patterns and conventions in an existing codebase. Dispatched by /spec for brownfield projects. Read-only. | SPEC-210, SPEC-211 | test-research-arch-contract.sh |
| `research-context` | `[D]` | spec, test-plan | Quick brownfield orientation for a target area (endpoints, data models, UI, test coverage, recent history) -- capped at 80 lines, throwaway… | - | - |
| `research-features` | `[D]` | feature-map | Deep, uncapped, source-cited feature inventory for one module of a target project -- every entry point gets a file:line citation and a beha… | SPEC-203, SPEC-208, SPEC-209 | - |
| `research-pitfalls` | `[D]` | spec | Finds landmines and risks in a codebase area before new work begins. Dispatched by /spec for brownfield projects. Read-only. | SPEC-211 | test-research-pair-contract.sh |
| `research-stack` | `[D]` | spec | Maps the technology stack of an existing codebase. Dispatched by /spec for brownfield projects. Read-only. | SPEC-211, SPEC-244 | test-research-pair-contract.sh |
| `responding-to-review` | `[D]` | greenlight, review-team | Responds to code review feedback with technical rigor, not performative agreement. Verifies before implementing. Pushes back when reviewer … | SPEC-019, SPEC-078, SPEC-090 | test-meta.sh |
| `security-reviewer` | `[D]` | battery, review-team | Deep security review of code changes. Read-only. Dispatched by /review-team for focused security analysis. More thorough than /review's bui… | SPEC-090, SPEC-092, SPEC-111 +3 | test-kit-contract.sh, test-review-team-plants.sh |
| `slop-stripper` | `[D]` | review-team | Behavior-preserving AI-slop strip pass. Given a base ref, scans the branch diff and applies surgical edits that strip AI-generated smell (r… | - | - |
| `system-verifier` | `[D]` | verify | Runs the whole assembled project's test suite end to end as the dynamic right-arm mirror of the design phase. Fills the agent-less System-t… | SPEC-090, SPEC-092, SPEC-108 +1 | test-every-step-review.sh, test-meta.sh, test-right-arm-parity.sh |
| `task-verifier` | `[D]` | battery, debug, dispatch +4 | Verifies a completed task against its spec acceptance criteria. Run after each worker subagent completes a task. Read-only -- cannot modify… | SPEC-002, SPEC-003, SPEC-007 +16 | test-agent-effectiveness.sh, test-every-step-review.sh, test-meta.sh +2 |
| `test-writer` | `[D]` | test-write | Turns a reviewed test-plan coverage matrix into runnable test code, one case per matrix row, in the repo's existing test framework. Write-c… | SPEC-203, SPEC-220 | test-test-writer-contract.sh |

## Skills

| Skill | Trigger | Description | Specs | Tests |
|---|---|---|---|---|
| `backlog-reconcile` | `[I]` | Use when auditing, reconciling, or verifying a repo's `_meta/BACKLOG.md` Active queue against reality, "audit the backlog", "reconcile the … | SPEC-225, SPEC-242 | test-hooks.sh |
| `ci-drift` | `[I]` | Use for the whole-estate CI audit, "audit the CI", "are the runners clean", "check the release pipeline", "ci drift", "stale workflows / se… | SPEC-232 | test-meta.sh |
| `doc-drift` | `[I]` | Use for the whole-estate doc audit, "run the doc-drift loop", "audit the docs against the code", "are the docs still true", "doc drift swee… | SPEC-029, SPEC-216, SPEC-218 +6 | test-audit-scanner-contract.sh, test-meta.sh |
| `gauntlet-proof-audit` | `[I]` | Use to audit the gauntlet records, "are the ROUNDS.md records honest", "verify the proof corpus", "check each run record against its eviden… | SPEC-242 | test-gauntlet-proof-audit.sh |
| `get-api-docs` | `[I]` | Fetch curated API documentation using Context Hub (chub) before coding against any external API. Use when the task involves calling a third… | - | test-kit-foldin-hooks.sh |
| `loop-engineering` | `[I]` | Use when the user wants to design or add a new bounded loop to the kit's own SDLC orchestration ("let's build a loop", "design a new loop f… | SPEC-209, SPEC-222, SPEC-225 +4 | test-loop-engineering-contract.sh, test-research-arch-contract.sh |
| `memory-tidy` | `[I]` | Use when auditing, consolidating, or cleaning a repo's .claude/memory store, "dọn memory", "memory tidy", the biweekly memory audit, dupl… | SPEC-208, SPEC-225, SPEC-249 | test-memory-tidy-contract.sh, test-research-arch-contract.sh |
| `observe` | `[I]` | Query and render the kit's control plane from an agent session. Use when asked about the fleet's runs, gate verdicts, conformance, spend/to… | SPEC-033, SPEC-052, SPEC-128 +10 | test-bin-forwarders.sh, test-kit-contract.sh, test-orchestrate-wavefront.sh +1 |
| `skill-review` | `[I]` | Review and promote skill drafts that skill-curator staged from past sessions. Use when the user runs /skill-review, says "review my skill d… | SPEC-218 | test-bin-forwarders.sh, test-kit-contract.sh |
| `stats` | `[I]` | Query or render the state of the scattered kit/tide/tg-cleanup/learned ledgers (the dwarves-kit gate/proof/telemetry corpus, tide file-move… | SPEC-001, SPEC-182, SPEC-192 +15 | proof-loop-09-scenario-b.sh, test-bin-forwarders.sh, test-config-stamp.sh +9 |
| `topology-drift` | `[I]` | Maintainer-only (dwarves-kit repo dev only). Use to audit THIS KIT's OWN feature estate against its path map, "run the topology-drift loop"… | SPEC-225, SPEC-235, SPEC-237 | test-audit-scanner-contract.sh, test-meta.sh |
| `web-drift` | `[I]` | Use for the live-website agent-readiness audit, "run the web-drift loop", "audit our websites", "are our sites still readable by an agent",… | SPEC-232 | test-web-drift-refusal-guard.sh |

## Hooks

| Hook | Trigger | Event | Description | Specs | Tests |
|---|---|---|---|---|---|
| `anti-rationalization.sh` | `[E]` | Stop | all legitimate phrases Claude | SPEC-003, SPEC-006, SPEC-008 +7 | test-hooks.sh, test-install-modules.sh, test-meta.sh |
| `auto-format.sh` | `[E]` | PostToolUse | PostToolUse hook, matcher: Write\|Edit | SPEC-003, SPEC-084 | test-adopt.sh, test-hooks.sh, test-install-modules.sh |
| `backlog-stage.sh` | `[E]` | SessionEnd | SessionEnd hook, function-named port of ops-toolkit's cc-backlog | SPEC-192, SPEC-194, SPEC-195 +4 | test-adopt.sh, test-install-modules.sh, test-intake-sweep.sh +2 |
| `citation-guard.sh` | `[E]` | Stop | Stop hook, function-named port of ops-toolkit's cc-citation-guard | - | test-install-modules.sh, test-kit-foldin-hooks.sh |
| `codebase-index.sh` | `[E]` | SessionStart | SessionStart hook (OPT-IN), dwarves-kit | SPEC-043, SPEC-084, SPEC-085 | test-hooks.sh, test-install-modules.sh, test-meta.sh |
| `commit-format.sh` | `[E]` | PreToolUse | PreToolUse hook, matcher: Bash | SPEC-014, SPEC-032, SPEC-064 +1 | test-hooks.sh, test-install-modules.sh, test-meta.sh |
| `context-hints.sh` | `[E]` | UserPromptSubmit | UserPromptSubmit hook, function-named port of ops-toolkit's | - | test-adopt.sh, test-install-modules.sh, test-kit-foldin-hooks.sh |
| `context-readiness.sh` | `[E]` | SessionStart | SessionStart hook | SPEC-003, SPEC-005, SPEC-010 +7 | test-adopt.sh, test-hooks.sh, test-install-modules.sh +1 |
| `harvest.sh` | `[E]` | PreCompact | PreCompact / SessionEnd hook, function-named port of ops-toolkit's | SPEC-194, SPEC-196, SPEC-245 +1 | test-install-modules.sh, test-kit-foldin-hooks.sh |
| `intake-sweep.sh` | `[E]` | - | thin shim over intake-sweep.py (backlog-stage.sh precedent). | SPEC-200 | test-board-promote.sh, test-intake-sweep.sh |
| `money-gate.sh` | `[E]` | PreToolUse | PreToolUse(Edit\|Write\|MultiEdit) hook, function-named port of | SPEC-232 | test-install-clis.sh, test-install-modules.sh, test-learn-propose.sh +1 |
| `notification.sh` | `[E]` | Notification | Notification hook | SPEC-032, SPEC-084, SPEC-196 +1 | test-hooks.sh, test-install-modules.sh |
| `output-offload.sh` | `[E]` | PostToolUse | PostToolUse. When a tool returns more than ~OFFLOAD_MAX_TOKENS tokens, | - | test-hooks.sh, test-install-modules.sh |
| `permission-auto-approve.sh` | `[E]` | PermissionRequest | PermissionRequest hook | SPEC-084 | test-hooks.sh, test-install-modules.sh |
| `post-compact-reinject.sh` | `[E]` | PostToolUse | PostToolUse hook, matcher: compact | SPEC-003, SPEC-010, SPEC-034 +1 | test-install-modules.sh |
| `pre-compact-backup.sh` | `[E]` | PreCompact | PreCompact hook | SPEC-010, SPEC-084 | test-install-modules.sh |
| `prose-rag.sh` | `[E]` | UserPromptSubmit | UserPromptSubmit hook shim for the prose-rag recall inject | SPEC-194, SPEC-204, SPEC-249 +2 | test-bin-forwarders.sh, test-config-seams.sh, test-install-clis.sh +2 |
| `safety-gate.sh` | `[E]` | PreToolUse | PreToolUse hook, matcher: Bash | SPEC-003, SPEC-014, SPEC-019 +7 | proof-loop-09-scenario-b.sh, test-hooks.sh, test-install-modules.sh +2 |
| `secrets-guard.sh` | `[E]` | PreToolUse | PreToolUse hook, matcher: Read\|Edit\|Bash | SPEC-014, SPEC-084 | test-hooks.sh, test-install-modules.sh, test-meta.sh |
| `session-state-save.sh` | `[E]` | Stop+SubagentStop | Stop hook (runs alongside anti-rationalization + slop-cleaner) | SPEC-003, SPEC-010, SPEC-030 +3 | test-hooks.sh, test-install-modules.sh, test-meta.sh |
| `ship-gate.sh` | `[E]` | PreToolUse | each matrix row mapped to the run that exercised it, or an | SPEC-006, SPEC-042, SPEC-044 +47 | test-every-step-review.sh, test-gate-outcome.sh, test-hooks.sh +12 |
| `slop-cleaner.sh` | `[E]` | Stop | breaking the "Exit 0 always" contract three lines above. | SPEC-013, SPEC-014, SPEC-084 +2 | test-hooks.sh, test-install-modules.sh |
| `spec-drift-guard.sh` | `[E]` | PreToolUse | PreToolUse hook, matcher: Write | SPEC-003, SPEC-005, SPEC-006 +4 | test-hooks.sh, test-install-modules.sh |
| `statusline.sh` | `[E]` | StatusLine | StatusLine script | SPEC-025, SPEC-084, SPEC-219 | test-hooks.sh, test-install-modules.sh, test-meta.sh |
| `tool-policy-guard.sh` | `[E]` | PreToolUse | PreToolUse hook enforcing the tool-choice policy. | SPEC-212 | test-install-modules.sh, test-tool-policy-guard.sh |

