# MANUAL

Operator reference for dwarves-kit: every command, hook, and agent, plus how to drive the kit from natural language and how to recover when it misbehaves. For the WHY behind any choice, see `docs/PHILOSOPHY.md`. For component fit and the SDLC state machine, see `docs/architecture.md`. For the end-to-end workflow contract (phases, risk-tier lanes, gates, flow/loop diagrams), see `WORKFLOW.md`.

Same loop, told as a story: an interview turns your ask into a blueprint, a crew builds it, a
logbook records the run, an inspector stamps every doorway, and a debrief writes up the lesson
for next time. The story names are prose only; every command and file below keeps its real
name. Full tour: `/kit:onboard`. Story-name lookup: `docs/glossary.md`.

## Conventions

- Plugin install path (recommended): commands invoked as `/kit:<name>` (e.g. `/kit:spec`).
- Bash install path: drop the prefix, commands invoked bare as `/<name>` (e.g. `/spec`).
- Hooks have no invocation, they fire on Claude Code events.
- Agents have no invocation, they are dispatched by commands.
- Self-intro banner: every `/kit:` command opens its first reply with one line, `[kit:<name>] <one-line purpose>` (from its frontmatter description), and every dispatched agent's report opens the same way, so you always see what is running and why (AGENTS.md "Self-intro").
- Teach on bad input: a command handed a bad or missing input names it, teaches why it matters in one line, and offers the concrete fix, never a dry "invalid input", never proceeding silently. Overrides run but get recorded. Convention + per-command tables: `docs/patterns/teach-on-bad-input.md`.
- Scenarios ride every shaping beat: think/design/grill/spec/test-plan surface survival and must-NOT-happen scenarios via one shared method, generated once at the cheapest altitude and refined downhill, never re-brainstormed from blank. Method: `docs/patterns/scenario-generation.md`; user guide: `docs/guides/scenarios.md`.

## Drive it by intent (start here)

You do not memorize commands. Say what you want; the kit reads your intent, runs the right command(s), and stops only at the real decisions. This table is the interface: find your intent on the left, the kit handles the rest. The `/kit:*` names are shown if you prefer to type them, but you rarely need to.

| You say | Claude invokes | Fires automatically | Stops at |
|---|---|---|---|
| "what's next / what's left" | `/kit:start` (detector) | context-readiness suggestion | nothing (read-only) |
| "assign ID-007" / "start ID-007" | `/kit:assign ID-007` | (none) | hands off to the lane |
| "apply SDD to X" (no ID) | `/kit:assign "<freeform>"` -> `/kit:spec` lane | spec-drift-guard once a spec exists | approve-before-allocate, lane/scope confirm, then per-phase |
| "discuss / iterate the design" | `/kit:design` (+ `/kit:devs-team`) | (none) | every section (human-in-loop) |
| "vague idea about X" | `/kit:think` / brainstorming | (none) | your approval of the objective |
| "run the full lane, your call" | the lane, autonomously | anti-rationalization (in a /goal loop) | hard stops + push/PR |
| "fix this bug / it regressed" | `/kit:debug` (bug lane) | guess-fix guard | root cause + fix verified (`debug.confirm_fix` gates the human step, default off) |
| "review this" / "ship it" | `/kit:review[-team]` / `/kit:ship` | ship gate, push-to-main | DO-NOT-SHIP verdict; the push/PR |
| "can a cold consumer succeed with this artifact alone" (onboarding docs, a runbook, a spec, an API surface) / "test our onboarding" | `/kit:gauntlet` | clean-room probe rounds, artifact revisions between rounds; onboarding is the reference preset | SOLID / REVISE / RECONSIDER (guide: `docs/guides/gauntlet.md`, tutorial: `docs/guides/gauntlet-tutorial.md`) |
| "is the gauntlet surface converging / what does a probe round cost" | `bash lib/gauntlet/stats.sh` (`--write` for a dated snapshot) | read-only projection over `docs/verification/gauntlet/` run records | one table: findings trajectory, rounds-to-clean, probe tokens/cost, probe-model deltas |

For the full playbook (every scenario, the autonomy dial, the freeform front door) see `## Operator scenarios`. For a per-command lookup see `## Command reference`. Hooks fire on their own; commands and skills are invoked, by you or by Claude reading your intent.

## Command reference (the kit invokes these from your intent; you rarely type them)

Index by loop stage (formerly "leg", ADR-0034; the README's "The five stages" section tells the full story). Front-door and meta commands sit outside the stages on purpose:

| Stage | Commands |
|---|---|
| (front door) | `/kit:start`, `/kit:onboard`, `/kit:adopt` |
| Shape | `/kit:wayfind`, `/kit:grill`, `/kit:think`, `/kit:design`, `/kit:prototype`, `/kit:devs-team`, `/kit:visual-team`, `/kit:ui-design`, `/kit:assign`, `/kit:spec`, `/kit:spec-validate`, `/kit:test-plan` |
| Build | `/kit:execute`, `/kit:next`, `/kit:dispatch`, `/kit:mega`, `/kit:debug` |
| Watch | `/kit:explain`, `/kit:pitch` (render the record outward; the read plane itself is the `stats` skill + `session` CLI, not a command) |
| Check | `/kit:review`, `/kit:review-team`, `/kit:test-plan-review-team`, `/kit:test-write`, `/kit:verify`, `/kit:quiz-gate`, `/kit:ship` |
| Learn | `/kit:retro`, `/kit:docs`, `/kit:absorb` |
| (meta) | `/kit:kit-health`, `/kit:draft-agent` |

### `/kit:start`

**Phase:** entry router
**Reads:** project state (existence of `docs/specs/SPEC-NNN-<slug>.md`, git branch, dirty count, hook log activity, `_meta/BACKLOG.md` queue)
**Writes:** nothing; advises in chat which command to run next
**When to invoke:** opening a fresh session and you do not remember where you left off
**Common gotcha:** the router suggests a next step but does not run it. You decide.
**Spec resolution (dual-mode, SPEC-005):** the active spec is the lone non-SHIPPED/PARKED `docs/specs/SPEC-*.md`; with several live, the one whose slug matches the git branch; if zero or several match, it reports `spec:ambiguous(...)` and asks rather than guessing. `docs/specs/` is the sole spec location. The same rule drives the `context-readiness` hook, `spec-drift-guard` (which greps the union of active specs), and `/kit:next`.

**Modes (`$ARGUMENTS`):**
- `/kit:start --brief` -- one line, max 120 chars: state + suggested command + `[branch | N dirty | spec]`. For returning users who want a cue, not a report. Example: `Spec VALIDATED, 3/8 tasks -> /kit:execute. [master | 2 dirty | VALIDATED]`
- `/kit:start` -- the default 3-4 line orientation (unchanged from prior versions).
- `/kit:start --full` -- the default block, then: SPEC task checklist, hook-log line counts (last 7 days, counts only, never raw lines), `git log -5 --oneline`, and the command map grouped by phase. For a new user or a deep status check.

### `/kit:onboard`

**Phase:** guided first-run (interactive orchestrator; SPEC-199)
**Reads:** install mode via `lib/onboard-detect.sh` (plugin / bash / both / none); adoption state via `lib/adopt.sh --check`; the module roster + consumer knobs via `bin/config list|explain` (the SPEC-198 registry, never a hardcoded list)
**Writes:** nothing of its own -- it only ever drives `lib/adopt.sh` (to inject the contract and/or seed `<repo>/.kit.toml` with your module choices), and every such write is previewed (`--dry-run` or a shown plan) and confirmed first; a decline is a strict no-op
**When to invoke:** the first ten minutes on a new machine or a repo you have not adopted yet. It ties together the four things that have to line up before the loop works: which install mode is live, whether this repo is adopted, which modules are on, and which env knobs make them non-inert.
**What it does, in order:** (A) detect the install mode and explain it in one line each -- for `both` it discloses the double-hooks hazard and points at the one-path fix but never mutates settings; for `none` it prints the two install paths and stops. (B) offer `/kit:adopt` for the current repo (preview then confirm; an already-adopted repo is reported healthy and nothing is written). (C) pick modules -- the list is generated from the registry, and the choice is written by driving `lib/adopt.sh --with` (this is how the plugin path, which has no `install.sh --with`, still gets per-repo module selection). (D) for the chosen modules only, surface the consumer knobs that make them non-inert -- a `.kit.toml`-keyed knob is offered as a previewed write, an env-only knob (e.g. `PROSE_RAG_INJECT`, `MONEY_GATE_REPOS`) yields printed `export` guidance. (E) on the plugin path, disclose the gaps honestly (no statusLine HUD, a frozen SHA vs `git pull`, the `KIT_FORCE_FULL` escape and its hazard). (F) on the bash path, INSTALL-STAMP staleness is ONE printed line + a `/kit:kit-health` pointer, never an upgrade flow. (G) end with the five-stage loop in five sentences + `/kit:start` as the next step.
**Fence (ADR-0034 decision 4):** onboard ORCHESTRATES; it calls start + adopt + config and reimplements none of them. It never changes `install.sh`, `adopt.sh`, or `bin/config`.
**Common gotcha:** it is not an upgrade wizard. If the kit is already installed and this repo is already adopted, onboard is a read-only health tour that writes nothing; to change modules later you hand-edit `<repo>/.kit.toml [modules]` and re-run `/kit:adopt --refresh`.

### `/kit:think`

**Phase:** challenge an idea before writing a spec
**Reads:** the idea from chat
**Writes:** `docs/briefs/DECISION-BRIEF.md` only if the verdict is BUILD
**When to invoke:** before any non-trivial feature. Costs ~5 minutes.
**Common gotcha:** the 6 forcing questions are confrontational by design. If you accept them too easily, the brief is weak.

### `/kit:design`

**Phase:** opt-in interactive solution-design beat (between Think and Spec)
**Reads:** `docs/briefs/DECISION-BRIEF.md` (if present), the codebase
**Writes:** appends a `## Solution` section to `docs/briefs/DECISION-BRIEF.md` (never clobbers the brief's product framing); when the design is design-bearing, also appends a `## Design` section (diagram + ADR link(s), ADR-0031 §1 / SPEC-122) that `/kit:spec` folds into the spec
**When to invoke:** when you want to shape the solution with the agent (2-3 approaches, one question at a time, approve per section) before `/kit:spec`. Opt-in; skip it and `/kit:spec` works as before.
**Common gotcha:** under bypassPermissions the per-section `AskUserQuestion` prompts may auto-resolve, hollowing the feedback. Use it interactively. It does not execute and is not a gate. Realizes SPEC-008 Part C; forked from `superpowers:brainstorming`.

### `/kit:prototype`

**Phase:** opt-in throwaway-spike beat beside `/kit:design`
**Reads:** the design question at hand, the brief/spec if present
**Writes:** throwaway code on a `prototype/<name>` branch, never in master; the DECISION folds back into the brief/spec
**When to invoke:** a design question resists prose, a state model that only feels wrong once pushed through real cases (logic TUI, driven by hand), or a layout argued in the abstract (3-5 structurally different UI variants on one route)
**Common gotcha:** HITL by contract: the human drives the prototype and makes the call; the agent builds the instrument, it never answers the design question itself. The prototype is throwaway; only the decision survives.

### `/kit:wayfind`

**Phase:** pre-cycle intake shape for work too foggy for one session
**Reads:** the loose idea; the board
**Writes:** `_meta/megagoals/<slug>/map.md` (destination / decisions-so-far / fog / out-of-scope) + typed decision tickets (`research` / `prototype` / `grilling` / `task`), resolved one per session through the kit's own machinery
**When to invoke:** the OPEN questions outnumber the stateable ones. A well-scoped feature belongs on `/kit:grill` + `/kit:spec`; a decomposable build with a clear route belongs on `/kit:mega`; wayfind is only for genuine fog
**Common gotcha:** map-clear hands off to `/kit:spec` or a ROADMAP, never straight to execute. Grilling tickets are never delegated (the agent must not answer its own questions). User-invoked only (`disable-model-invocation: true`).

### `/kit:devs-team`

Opt-in design-critique lane between `/kit:design` and `/kit:spec`. Dispatches 5 engineering lenses (simplicity, performance, boundaries, data-model, operability) in parallel against the `## Solution`, read spec-first (the active spec if one exists, else the pre-spec `docs/briefs/DECISION-BRIEF.md`), merges findings, and appends a report-only `## Design critique` (SOLID / REVISE / RECONSIDER) to that same doc. Never blocks `/kit:spec`. The design analogue of `/kit:review-team`. Placement is spec-first per SPEC-023.

### `/kit:visual-team`

Opt-in visual-critique lane (downstream-facing; the kit has no UI). Dispatches 5 design lenses (hierarchy/typography, system-consistency, accessibility/contrast, restraint, expressiveness) in parallel against a described or linked visual design. Report-only. Does not generate mockups. Writes `## Visual critique` spec-first (the active spec if one exists, else the pre-spec brief, else inline-only) per SPEC-023.

### `/kit:ui-design`

Opt-in downstream UI-design loop (downstream-facing; the kit has no UI, so it cannot dogfood this lane). Resolves the active spec (else the pre-spec brief) and writes a structured `## UI design` brief: aesthetic direction (purpose / tone-extreme / constraints / differentiation, the part `frontend-design` reads first), layout, a components-and-states matrix, responsive + named viewports, accessibility bars, a 3-tier token ladder, and copy voice. Delegates generation to the external `frontend-design` skill (the kit ships no renderer; degrades gracefully if it is absent), critiques via `/kit:visual-team`, and runs a bounded auto-revise loop (max 2 regenerations; terminates on a SOLID verdict, RECONSIDER, or the cap). Opt-in, report-only. Depends on the external `frontend-design` skill. Per SPEC-020.

### `/kit:test-plan`

Opt-in lane between `/kit:spec-validate` and `/kit:execute`. Reads the active spec's acceptance criteria and writes a `## Test plan` coverage matrix (with a `proof` column naming the command/artifact per case) into the active spec, across happy-path / boundary / failure-injection / security / regression. `/kit:execute` reads that section as its coverage target and uses each case's `proof` as the per-step verify. A coverage target, not exhaustive; not a roundtable.

### `/kit:test-write`

Materializes a reviewed test plan into real test code, after `/kit:test-plan-review-team` records a SOLID `## Test plan critique`. Dispatches the `test-writer` agent per matrix row, in the repo's existing test framework and conventions. Refuses to run on a missing, stale, or non-SOLID critique. Done means every row is covered or reported skipped, and the written tests execute; making assertions pass is `fix-agent`'s job in the build, not this command's.

### `/kit:assign`

**Phase:** orchestrate (backlog item -> goal draft -> lane)
**Reads:** `$ARGUMENTS` = either an `ID-NNN` (today's path) OR **freeform intent** (anything not matching `^ID-[0-9]+$`, e.g. "apply SDD to X"); `_meta/BACKLOG.md` Active queue, the item's Lane column, `AGENTS.md` zones (the projection source for the six-section goal) + the active spec's `## Verification` / `## After state`. Freeform delegates the crystallize interview to `/kit:think`.
**Writes:** `.claude/goals/<slug>.md` (the SPEC-005 draft contract; never `.claude/last-goal.md`), a six-section operating directive (Context-to-read / Constraints / Operating rules / Validation loop / Done-when / Pause-if). On the **freeform path** it first writes a new sanitized `_meta/BACKLOG.md` row with a freshly allocated ID (row-before-draft, approve-before-allocate).
**When to invoke:** you picked an `ID-NNN` from "what's left?", OR you have a freeform feature idea / vague brief with no ID yet, and want it scoped into a goal and routed into the right lane.
**Floor check (advisory):** after the lane is chosen, it runs `bash lib/classify/lane-classify.sh check <chosen> "<title>"`. A `LANE-DOWNGRADE` warning means the task text matches a heavier lane than you chose: size up, or narrow the scope and say why. It warns + logs to `completeness.log` (reviewed at `/kit:ship`); it never blocks ("Detect, don't dictate"). This is the guard for the classify-then-route gap: the classifier suggested a lane, but nothing caught an under-sized choice until now.
**Common gotcha:** it is a mutator-dispatcher: it sets up the goal and hands off, it does NOT execute. The freeform path **delegates** the interview to `/kit:think` (it does not embed one). It detects the goal-loop activator (built-in `/goal`, `ralph-loop`, or `goal-craft`) and degrades to a plain draft file if none is installed. Idempotent per id (and per slug for freeform). Source: SPEC-006 + ADR-0011; freeform front door SPEC-026; floor check SPEC-053.

### `/kit:dispatch`

**Phase:** orchestrate / cross-phase (N specs -> N concurrent worktree workers -> converge)
**Reads:** `$ARGUMENTS` = the specs to fire (or detects `Status: VALIDATED` specs with a `## Touches` section); each spec's `## Touches` directory-prefix globs; the lead-owned hands-off shared-surface list (from WORKFLOW.md, via `lib/gate/dispatch-gate.sh`).
**Writes:** nothing in the main checkout itself. Each dispatched worker writes its own `goal/<slug>` branch in an isolated worktree; the lead integrates the hands-off surfaces once via `/kit:ship`.
**When to invoke:** you have 2+ INDEPENDENT validated specs and want to fire them, tab away, and collect finished branches. The disjointness gate (`lib/gate/dispatch-gate.sh`) decides which run in parallel vs serialize; the drift guard checks each worker stayed in its globs.
**Common gotcha:** cross-goal ONLY (it never parallelizes one spec's tasks; that is `/kit:execute`, still sequential). It NEVER auto-merges (the human merges at `/kit:ship`) and is NOT a DAG: dependent/sequenced sub-goals are `/kit:mega` territory, a real ordering graph is GSD v2. A spec without `## Touches` is rejected by the gate, not assumed-empty. Runs under bypassPermissions for tab-away. Source: SPEC-032; ADR-0019 (boundary), ADR-0020 (primitive), SPEC-031 (convergence).

### `/kit:mega`

**Phase:** orchestrate / cross-phase (one destination -> 3-8 dependent sub-goals -> one bounded loop, one PR per sub-goal)
**Reads:** the conversation's multi-objective intent; `CLAUDE.md` for a `megagoal_root:` / `mega_merge_posture:` hint; each sub-goal's `Done =` + ship-gate ledger via `lib/gate/gate-ledger.sh`; `lib/gate/proof-ledger.sh deployable` (SG-07's classifier) to decide the deploy/UAT terminus.
**Writes:** the scaffold (`ROADMAP.md`, `goals/NN-*.md`, `POINTER_PROMPT.md`, `HANDOFF.md`, `DECISIONS.md`) at the resolved mega-goal directory (SPEC-034 DEC-002: `.claude/goals/<slug>/` for this repo, never `_meta/`, which is reserved for the BACKLOG cockpit). Nothing else until the loop runs; `/kit:mega` itself opens no PR.
**When to invoke:** ONE destination reached through 3-8 genuinely DEPENDENT sub-goals (a single chain, no fan-in/fan-out) -- the sequenced complement to `/kit:dispatch`'s independent/parallel case.
**Common gotcha:** it MIRRORS the ops-toolkit `plan-for-mega-goal` skill's decompose + front-load-checkpoint + per-run-merge-config beats; it does not fork or replace the skill (prefer the skill when installed for anything this command does not cover). Ship-layer auto-merge is real but narrow: only an `auto`-tagged sub-goal's PR can auto-merge, and only once `lib/goal/mega-merge.sh gate` confirms its ship-gate passed (`lib/gate/gate-ledger.sh check`, reused verbatim, never re-implemented); a failing/missing gate REFUSES unconditionally, and the action is dry-run unless `--execute` is passed. `gate`-tagged sub-goals and the final PR under the default `gated-final` posture always stop for a human; the command opens them via `lib/goal/mega-merge.sh mark` (draft + `do-not-merge`) so the `_merge_exclusion` guard always has a mark to catch (SPEC-100 mark half, ID-089). `MEGA_MERGE_POSTURE=per-pr-review` (or `--posture=per-pr-review`) forces dry-run on every PR for a team run, overriding `--execute`. Source: ADR-0028 P2/P3; SPEC-034 (roadmap conventions, ID-037); SPEC-096 (this command + `lib/goal/mega-merge.sh`, kit-hardening SG-08); SPEC-095 / SG-07 (the reused `deployable` classifier).

### Multi-session concurrency (the running-goal registry, `lib/goal/goal-registry.sh`)

`/kit:dispatch` is the single-session axis (one lead, N workers). The other axis is
**multi-session**: one operator opens several Claude sessions on one machine (one goal
each) and walks away. A passive registry under
`$(git rev-parse --git-common-dir)/kit-goals/` (shared by every worktree, never committed)
keeps the sessions from colliding. It is a `lib/` helper, not a slash command.

- `bash lib/goal/goal-registry.sh claim <slug> <lane> <glob>...` -- register a goal. Admitted
  only if its globs are disjoint from every active goal (the `lib/gate/dispatch-gate.sh` rule,
  reused); an overlap is REFUSED with the colliding goal named. `/kit:assign` runs this.
- `bash lib/goal/goal-registry.sh list` -- the cross-session monitor: every running goal +
  lane + status. Surfaced by `/kit:start` (count always, full table in `--full`). It is
  the kit-level companion to the native agent view, which sees only one session's workers.
- `bash lib/goal/goal-registry.sh log <slug> "..."` -- append to the goal's attempt log
  (`<slug>.attempts`), the running, human-legible "what it tried" trail.
- `bash lib/goal/goal-registry.sh status <slug> <state>` / `release <slug>` -- update status /
  drop the entry on completion. A stale `running` entry from a crashed session shows in
  `list` and is cleared with `release` (no GC daemon, by design).

**Common gotcha:** the slug is the bare spec/goal slug (no `goal/` prefix, no slashes).
What stays L5 (Nimbalyst / GSD v2): coordination across machines, by 3+ live human
operators, or with goal-ordering chains. The registry records and compares; it never
schedules, sequences, or merges. Source: SPEC-036; ADR-0022.

### `/kit:spec`

**Phase:** generate the development spec
**Reads:** `docs/briefs/DECISION-BRIEF.md` (if present), the codebase via 4 parallel research subagents (brownfield) or chat (greenfield)
**Writes:** `docs/specs/SPEC-NNN-<slug>.md` (Status: DRAFT), `docs/research/{stack,features,architecture,pitfalls}.md`
**When to invoke:** after `/think`, or directly if the work is well-scoped already
**Common gotcha:** the research agents are parallel-dispatched via Task tool. If your Claude Code is older than v2.0.60, they fall back to inline research and the run is slower.
**Template sections:** the generated spec scaffolds Solution depth (approaches / chosen + why / extensibility, SPEC-008), plus an optional `### Interfaces (I/O contract)` under Technical Design and an optional `## Failure modes` table. Both optional sections are lane-scoped; Reviewers 2 and 5 check them when present. It also pins `## Verification` (the command(s) that prove the spec done) and `## Open questions` (the blocker landing zone a `/goal` loop appends to), so a validated spec is natively pointer-`/goal`-ready (SPEC-012 P1). An optional, on-demand `## Amendments` section (added only when a mid-flight amend happens, never an empty scaffold) records add-scope provenance during a build.

### `/kit:spec-validate`

**Phase:** adversarial review of the spec
**Reads:** `docs/specs/SPEC-NNN-<slug>.md`
**Writes:** comments in chat; the maintainer flips SPEC Status to VALIDATED manually after addressing findings
**When to invoke:** before `/execute` on any spec longer than ~5 tasks
**Common gotcha:** 6 reviewers (security, failure-mode, assumption-destroyer, scope-critic, solution-design & extensibility, design-record) run sequentially. Budget ~10-12 minutes. The 5th reviewer flags shallow or non-extensible designs and is calibrated against false positives + legacy specs. The 6th, Reviewer 6 (SPEC-122 / ADR-0031 §1), is the one BLOCKING check in the set: a design-bearing spec with an empty `## Design` block cannot flip to VALIDATED.

### `/kit:execute`

**Phase:** autonomous build
**Reads:** `docs/specs/SPEC-NNN-<slug>.md` (must be Status: VALIDATED or APPROVED)
**Writes:** code, tests, marks SPEC task checkmarks, appends to SPEC Decision Log
**Dispatches:** worker subagent per task, then task-verifier, then fix-agent on FAIL:fixable (retry max 2)
**When to invoke:** when handing off to a contractor OR running the kit on yourself end-to-end
**Common gotcha:** verification adds ~2x token cost per task. Worth it for the FAIL:fixable catch rate; budget accordingly. Each worker first expands its task into bite-sized verify-each-step increments (TDD when a unit test fits; grep/bash/test-suite verify for doc and config tasks) before coding.
**Mid-flight amend:** if a build reveals scope that must be added now ("also do Y"), do not silently edit the spec or restart the lane. With your approval, amend at a task checkpoint (append `- [ ]` tasks, record an `## Amendments` entry, Status stays VALIDATED) and resume with `/kit:next`. The canonical rule is WORKFLOW.md "## Mid-flight amend"; the operator card is "## Operator scenarios" Scenario 6 below.

### `/kit:next`

**Phase:** manual single-task build
**Reads:** `docs/specs/SPEC-NNN-<slug>.md`
**Writes:** code, tests; you drive the verification yourself
**When to invoke:** when you want hands-on control or the next task needs subtle judgment that the verification pipeline might over-correct on
**Common gotcha:** picks the next unchecked task only. To skip a task or pick a specific one, edit SPEC.md task ordering first. This unchecked-only behavior is also why `/kit:next` (not a fresh `/kit:execute`) is the way to resume after a mid-flight amend: it runs the newly appended tasks and skips the done rows.

### `/kit:draft-agent`

**Phase:** build (meta-tooling)
**Reads:** a one-line role description (or a unit-of-work description) from `$ARGUMENTS`
**Writes:** by default INSTALLS a new subagent, `agents/<name>.md` + the roster rows (MANUAL/architecture/README) + `~/.claude/agents/<name>.md` for runtime; `--draft` stops at a staged draft; `subgoal:` mode drafts a mega-goal sub-goal file (never installed)
**Dispatches:** the `meta-agent` (drafts to staging; the command promotes/installs)
**When to invoke:** when a task needs a specialist role no existing agent covers and you want it as a reusable, named kit agent. For a one-off same-run specialist during `/kit:execute`, you do NOT invoke this, 2b-0 role synthesis handles it inline (see below).
**Common gotcha:** a freshly installed agent is dispatchable only NEXT session (Claude Code loads the agent registry at session start); the command prints the granted tools + an `rm` undo. Sharing an installed agent with the team still goes through a reviewed PR. Design: SPEC-089.

Related, **2b-0 role synthesis** (inside `/kit:execute`): each task is classified by `lib/classify/role-classify.sh`; a specialist-worthy task gets a role synthesized by the `meta-agent` (Mode C, open-ended, any role) and injected into the worker THIS run, cached to `~/.claude/agents/` for reuse. Plain tasks fall through to the generic worker. This is automatic; `/kit:draft-agent` is the manual, install-a-named-agent path. Both share the `meta-agent` + `role-classify.sh` primitives.

### `/kit:debug`

**Phase:** off-cycle (the `bug` lane: defect, regression, failing test, not a new feature)
**Reads:** the bug report / error / failing test, `git diff`, `git log`, `git bisect`
**Writes:** `.claude/debug/<slug>.md` (the evidence ledger), `.claude/debug/<slug>.log` (tagged instrumentation), then a failing test + a single root-cause fix
**When to invoke:** when something is broken and you would otherwise guess-fix. Runs four phases (root cause -> pattern -> hypothesis -> fix) under the iron law "no fix without a recorded root cause," with a 3-failed-fixes-question-architecture wall.
**Common gotcha:** while the ledger's `## Root cause` is blank, the anti-rationalization hook blocks any guess-fix "done" claim and sends you back to Phase 1. That guard is gated on an open debug session, so it never fires in normal coding. After a confirmed fix, run `/kit:review` on the diff. Forked from `superpowers:systematic-debugging` + GSD/doraemonkeys mechanisms; see ADR-0012.

### `/kit:review`

**Phase:** paranoid single-pass review
**Reads:** `git diff`, `docs/specs/SPEC-NNN-<slug>.md`
**Writes:** a `## Review` section in the active spec (replace-not-stack); inline in chat if no spec exists
**When to invoke:** small change (under ~300 lines diff) where one careful pass beats parallel lens-reviewers
**Common gotcha:** outputs a verdict (`SHIP / FIX-REQUIRED / REJECT`). `/ship` reads this and gates on it.

### `/kit:review-team`

**Phase:** parallel 3-lens review
**Reads:** `git diff`
**Dispatches:** 3 `code-reviewer` subagents (security, architecture, test-coverage lenses) in parallel + the deeper `security-reviewer` agent
**Writes:** a `## Review` section in the active spec with per-lens subsections (replace-not-stack); inline in chat if no spec exists
**When to invoke:** medium-to-large diff (>300 lines) or any change touching auth, payments, multi-tenant boundaries
**Common gotcha:** the FIX-THEN-SHIP path dispatches `responding-to-review` to triage findings without performative agreement. `review.apply_findings` ships `true`, so `fix-agent` applies every finding `responding-to-review` VERIFIED and the PR is your review surface; a finding it pushed back on is never applied. Set the key `false` to have them proposed for you to apply by hand.

### `/kit:verify`

**Phase:** on-demand test re-run (V-model right arm), read-only
**Reads:** the active `docs/specs/SPEC-NNN-<slug>.md` (done tasks + acceptance criteria), the working tree / branch
**Dispatches:** `task-verifier` (per done task) + `integration-verifier` (multi-task), read-only
**Writes:** nothing; prints a PASS/FAIL verdict (never dispatches `fix-agent`)
**When to invoke:** after a manual edit post-build, on a branch built elsewhere, or for a read-only `/goal`-loop check, when you want the test levels re-run without a rebuild
**Common gotcha:** it reports, it does not fix. On FAIL, run `/kit:next` or `/kit:execute` to repair. The integration base ref is the merge-base with the default branch (no build base ref exists outside `/execute`).

### `/kit:docs`

**Phase:** doc sync
**Reads:** `git diff`
**Writes:** updates README.md, CHANGELOG.md, and any other doc files whose content drifted from code
**When to invoke:** after `/execute` succeeds, before `/ship`
**Common gotcha:** the command does not invent doc content. If a feature is undocumented in the spec, the command will not document it from the diff alone.

### `/kit:explain`

**Phase:** understanding (the AFTER gate, ADR-0031 §2)
**Reads:** a git ref (`$ARGUMENTS`: a commit / PR / spec), the ACTUAL diff via `lib/explain.sh`, plus recorded test results under `docs/verification/`
**Writes:** a literate-diff explainer artifact under `docs/verification/explain-command/`, background -> goal + intuition -> a prose-ORDERED diff (reading order, not git alphabetical) -> a diagram
**When to invoke:** after a significant change ships, when you want to UNDERSTAND it (stay a participant in the next loop) instead of click-to-merge a raw diff. Advisory, never blocks (engage / defer / wave).
**Composes:** `narrate-log` (the prose arc) + `svg-knowledge-diagram` (a richer figure); the kit does not reinvent pedagogy.
**Common gotcha:** the explainer is grounded in the diff, NOT the agent's narrative, if the commit message or your recollection contradicts the code, the diff wins. The 5-question quiz built ON this artifact is a separate step (`deep-understand`); this command produces the material, not the quiz.

### `/kit:quiz-gate`

**Phase:** understanding (the AFTER gate's speed regulator, ADR-0031 §2/§3)
**Reads:** a git ref + `<rid>` (`$ARGUMENTS`), the ACTUAL diff + recorded tests via `lib/gate/quiz-gate.sh` (which reuses `lib/explain.sh`), and `lib/classify/significance-classify.sh`'s verdict for the change
**Writes:** the human's engage/defer/wave choice to the debt ledger (`| DEBT | response=...` via `gate-ledger.sh debt-response`); on engage, dispatches the `deep-understand` mastery gate with 5 diff-grounded questions
**When to invoke:** at the merge boundary of a `gate`/gated-final PR. It NUDGES only when the change is `tap` (significant AND understanding-worthy); a `wave` or `not-significant` change is never quizzed (anti-fatigue). Advisory, never must-pass, a waved change still merges.
**Composes:** `deep-understand` (the AskUserQuestion mastery gate); the kit builds the questions and routes, it scores nothing.
**Common gotcha:** the quiz questions come from the DIFF + recorded tests, NEVER the agent's narrative, a quiz on the agent's misconceptions is worse than none. `questions`/`route` take a git ref only, so a false story cannot leak in. This gates the human's ATTENTION, not the merge.

### `/kit:ship`

**Phase:** review gate, version bump, changelog, commit, PR
**Reads:** `docs/specs/SPEC-NNN-<slug>.md` (including its `## Review` verdict), `VERSION`, the resolved changelog file (`docs/CHANGELOG.md` if it exists, SPEC-185, else root `CHANGELOG.md`)
**Writes:** bumped `VERSION`, a new entry in the resolved changelog file, git tag, PR via `gh`
**When to invoke:** review is green and docs are synced
**Common gotcha:** blocks if the spec's `## Review` verdict is DO NOT SHIP. Use `/review-team` and `responding-to-review` to triage before re-running ship.
**Release-hygiene warn (Step 4a):** at the version step it warns (never blocks) on a phantom cut, `VERSION` naming a version with no matching git tag, with a heads-up when `[Unreleased]` is accumulating above it. Warn-only; tag `v<version>` or confirm intentional, then continue.

### `/kit:retro`

**Phase:** post-release reflection
**Reads:** `docs/specs/SPEC-NNN-<slug>.md` (completion rate), `git log`, prior `docs/retro/*.md`
**Writes:** `docs/retro/v<version>.md`
**When to invoke:** after `/ship` lands; one per minor or major release, patch releases append to parent retro
**Common gotcha:** action items become real only if you carry them to the next cycle's spec. Track them, do not just write them.

### `/kit:absorb`

**Phase:** maintainer connective tissue (external absorption audit)
**Reads:** README Credits + the pinned seed list in `docs/ABSORPTION.md`; prior proposals under `docs/absorption/`
**Writes:** a dated, proposal-only report under `docs/absorption/` (never a kit component; ends with a `git status` self-check)
**When to invoke:** the monthly-ish absorption ritual, re-audit upstream sources for new/changed patterns worth adopting
**Common gotcha:** maintainer-only and proposal-only, it never absorbs or adds a source to Credits itself (the human merge gate). Two lanes: Credits drift + a seed-rescan of the SPEC-014 set. QA/UI candidates needing binaries surface as "recommend external". Source: SPEC-004 + `docs/ABSORPTION.md`.

### `/kit:kit-health`

**Phase:** self-assessment against PHILOSOPHY.md
**Reads:** the kit itself (file counts, hook performance, settings validity, source citations), plus a repo-scoped release-hygiene check (a phantom cut: `VERSION` names a version with no matching git tag; degrades to a no-op outside the repo)
**Writes:** verdict in chat (`SHIP / FIX-REQUIRED / REJECT`)
**When to invoke:** maintainer-only, before tagging a release of the kit (the release-hygiene check is exactly the "before tagging" guard)
**Common gotcha:** the rejection-first verdict will REJECT on real violations. Do not soften the criteria; address them.

## Hooks (no invocation)

The full hook inventory (every hook, its event, and its behavior) lives in ONE place:
`docs/architecture.md`, the hooks table. This section deliberately does not duplicate it: a
second copy drifted to 14 of 25 rows before the 2026-07-31 doc-drift run caught it, missing
`ship-gate` among others.

One advisory worth knowing by name: `context-readiness` (SessionStart) reads the active spec's
status plus the board's queued count (`board:Nq`, SPEC-083) and suggests the next step; silent
when the project is healthy.

What to remember here: the blocking hooks, everything else advises or warns.

| Blocker | Event | What it stops |
|---|---|---|
| `safety-gate` | PreToolUse(Bash) | `rm -rf` (build-artifact allowlist), push to main, force push, `DROP TABLE`, `git reset --hard`, `kubectl delete`. Override needs explicit user OK. |
| `ship-gate` | PreToolUse(Bash, on push/PR-create) | Shipping without a recorded proof-of-done / gate-ledger record for the lane. The answer to "why did my push get blocked": run `/kit:verify`, or record the audited override. |
| `secrets-guard` | PreToolUse(Read\|Edit\|Bash) | Reads of secret files (`.env`, `~/.ssh`, `~/.aws`, `.pem`); canonicalizes the path first. Allows `.env.example`. Best-effort on the Bash surface. |
| `commit-format` | PreToolUse(Bash) | A `git commit -m` subject that is non-conventional, >72 chars, or carries a SPEC-/TASK-/phase marker. Subject only. |
| `anti-rationalization` | Stop | Premature "done": rationalization phrases, guess-fix during an open `/debug` session, unimplemented-stub markers in the diff. |

## Agents (dispatched, not invoked)

| Agent | Dispatched by | What it does |
|---|---|---|
| `task-verifier` | `/execute` | Read-only verification per task |
| `fix-agent` | `/execute` | Targeted fixes on FAIL:fixable (max 2 retries) |
| `integration-verifier` | `/execute` (Step 4, multi-task) | Read-only: verifies the tasks wire together (each component reaches its activation point + the spec's end-to-end chains) |
| `doc-verifier` | `/docs` (Step 4.5) | Read-only: fact-checks the just-updated docs against the live code (counts, names, existence, cross-refs); reports drift, `/docs` fixes |
| `agent-effectiveness` | `/kit:draft-agent` (Step 4.7) | Read-only: validates a new/changed agent def's effectiveness (tools minimal-yet-sufficient, description fires right, instructions unambiguous, tier fits); diff-keyed, advisory, fail-safe |
| `code-reviewer` | `/review-team` | Focused review with configurable lens |
| `security-reviewer` | `/review-team` | Deep OWASP-style audit |
| `break-it` | `/kit:battery` (escalation lens, behavioral code with tests) | Read-only adversarial prober: hunts one concrete input or call sequence the suite does not constrain, returns `PROBE`/`NO-PROBE`; rung 2 of the coverage -> probe -> mutation ladder, before `lib/gate/mutation-smoke.sh` |
| `advisor` | `/review-team` (Step 2b, critique) + ship/mega final boundary (over-suggest) | Read-only kit-default EXTRA cross-cutting lens; two modes (P5 critique + P6 over-suggest); additive, never replaces the specialized reviewers |
| `brief-reviewer` | (right-arm parity roster; dispatchable on the brief/decision doc) | Read-only static left-arm reviewer of the design brief (`DECISION-BRIEF.md` or a spec's Problem/Context) for clarity, completeness, testability |
| `acceptance-verifier` | (right-arm parity roster; dispatchable at the spec's acceptance boundary) | Read-only dynamic verifier: executes the active spec's `## Verification` section end to end, maps each AC to a passing check |
| `system-verifier` | (right-arm parity roster; dispatchable as the whole-project check) | Read-only dynamic verifier: runs the full unscoped project test suite, the right-arm mirror of design |
| `recheck-verifier` | `/execute` (fresh-context re-audit over a right-arm PASS) | Read-only: RE-EXECUTES a right-arm verifier's recorded check in a fresh context and re-judges; never a read-back of recorded evidence; the ADR-0028 trust metric made real |
| `responding-to-review` | `/review-team` (FIX-THEN-SHIP) | Triages findings without sycophancy |
| `slop-stripper` | `/review-team` (Step 5, opt-in deslop strip) | Behavior-preserving AI-slop strip pass: surgical edits only, never behavior changes unless fixing a real bug |
| `research-stack` | `/spec` | Brownfield stack mapping |
| `research-context` | `/spec`, `/kit:test-plan` | Quick brownfield orientation, capped at 80 lines |
| `research-architecture` | `/spec` | Brownfield architecture patterns |
| `research-pitfalls` | `/spec` | Landmine surfacing pre-build |
| `research-features` | `/kit:feature-map` | Deep, uncapped, source-cited feature inventory for any project; MIGRATE table + parity contract when porting, else a behavior contract |
| `meta-agent` | `/kit:draft-agent` | Generates a new subagent (or a sub-goal file) from a description; the command installs the agent by default (`--draft` to stop at a review draft) |
| `performance-reviewer` | `/review-team` | Read-only PERFORMANCE-lens reviewer (hot paths, N+1, allocations, caching, p95/p99, complexity); returns severity findings + a 0-10 score |
| `api-reviewer` | `/review-team` | Read-only API-CONTRACT-lens reviewer (breaking changes, versioning, schema, error codes, backward compat, idempotency); severity findings + score |
| `frontend-reviewer` | `/review-team` | Read-only FRONTEND-lens reviewer (a11y/ARIA, semantic HTML, focus/keyboard, loading/error/empty/disabled states, responsive, color-only signaling); severity findings + score |
| `infra-reviewer` | `/review-team` | Read-only INFRA-lens reviewer (deploy/rollback safety, CI/CD, container/IaC least-privilege, secret handling, idempotent provisioning, blast radius); severity findings + score |
| `db-migration-worker` | `/execute` 2b-0 | Write-capable schema-migration implementer; writes up + DOWN/rollback + batched backfill + index changes, guards long locks, never drops data without an explicit ask |
| `data-etl-worker` | `/execute` 2b-0 | Write-capable data-pipeline implementer; extract/transform/load, DuckDB SQL for the transform, idempotent re-runs, schema validation, no silent row drops |
| `claim-verifier` | dispatched on a load-bearing free-text claim | Read-only adversarial panel: runs N in-context independent skeptics (default N=3, distinct attack angles, default-refute-if-uncertain, fail-closed) over an ARBITRARY claim and returns a structured majority-vote verdict (HOLDS/REFUTED + tally + threshold + per-skeptic reasons) |
| `test-writer` | `/kit:test-write` | Write-capable: turns a reviewed test-plan coverage matrix into runnable test code, one case per matrix row, in the repo's existing test framework; scope-locked to test files, frozen-evaluator on the spec's AC/Verification |
| `audit-scanner` | doc-drift + topology-drift skills (Tier 2) | Shared read-only evidence scanner for audit-loop instances: receives a target set + contract + evidence class, returns per-item verdicts (audit-loop grammar) with quoted evidence and severity; never fixes, roster has no write path |
| `devops-triage` | on-demand ("triage this production alert/error") | Read-only production-alert triage: bounded root-cause verdict from Workers Logs history + git log/diff/show around the deploy sha; NOT for local repro or test failures (that is `/kit:debug`); cannot modify the codebase or post anywhere |

## Path-scoped rules

`rules/backend-go.md` and `rules/frontend-ts.md` are TEMPLATES. Copy to `.claude/rules/` in the project that needs them. They activate when Claude reads matching files; they do NOT fire on write or create.

## Operator scenarios (what you say -> what happens)

How to drive the kit from natural language: scenario -> trigger phrase -> response ->
orchestration hook. For the flow/loop internals read `WORKFLOW.md` "## Flow and loop
reference"; for the formal state machine read `docs/architecture.md` "## SDLC state
machine".

**The one thing to understand first: three layers, only one is automatic.** Your
sentence does not mechanically trigger a flow. Only hooks fire on their own:

| Layer | Fires how | Examples |
|---|---|---|
| **Hooks** | **Automatic**, on Claude Code events | `context-readiness`, `safety-gate`, `anti-rationalization`, `spec-drift-guard`, `push-to-main` |
| **`/kit:*` commands** | **Invoked** -- you type `/kit:x`, OR Claude reads your intent and runs it | `/kit:start`, `/kit:assign`, `/kit:spec`, `/kit:execute`, `/kit:ship` |
| **Skills** | **Invoked** -- Claude recognizes the situation and loads the skill | `goal-craft`, `superpowers:brainstorming`, `content-spec` |

So when you say "apply SDD," no hook fires on the word. Claude **interprets** the phrase
and **invokes** the right command/skill; the hooks then act as guardrails. A second
load-bearing fact: orchestration is **BACKLOG-ID-first**. `/kit:assign` takes an
`ID-NNN` **or** freeform intent; given freeform it runs the freeform front door (below),
minting the ID on the fly so nothing ships untracked.

**Scenario 1 -- "what's next / what's left".** Fresh session, you want orientation.
Say "what's next", "where were we", or `/kit:start` (`--brief` for one line, `--full`
for the checklist + commits). Claude runs `/kit:start` (a detector): it renders the
`_meta/BACKLOG.md` Active queue + active `.claude/goals/` drafts, read-only. Nothing
changes. Then choose `assign ID-NNN` or `next`.

**Scenario 2 -- "apply SDD to feature X" (no ID yet).** Say "apply SDD to X", "let's
spec this". Not a keyword trigger; Claude maps it to the spec-driven lane and invokes
`/kit:assign` with the freeform intent. `/kit:assign` runs the freeform front door:
delegate the interview to `/kit:think` -> you approve -> allocate ID + BACKLOG row ->
route into the lane (`/kit:spec` -> ... -> `/kit:ship` -> `/kit:retro`). It does not
auto-run the whole flow off a keyword; it sets up and starts the first step, confirming
lane + scope with you.

**Scenario 3 -- "run the full flow, your call".** You want autonomy end to end. Say it
explicitly: "run the full lane autonomously; only stop at hard stops" (autonomous to the
outward-facing step) or "run it all the way to a PR, your call" (autonomous to
merge-ready). Claude drives the lane without pausing at advisory checkpoints. It STILL
stops at the 4 hard stops and at outward-facing irreversible steps (the push, the PR),
unless you said "all the way to a PR." The maximal grant: *"Run the full lane
autonomously, including the push and PR; only stop at the safety hard-stops or a real
blocker."*

**Scenario 4 -- iterate the design (maximal checkpoints).** The opposite of Scenario 3.
Say "let's discuss the solution", "iterate on the design", or `/kit:design`. Claude runs
the opt-in interactive design beat (and/or `/kit:devs-team`, or `superpowers:brainstorming`
for open-ended exploration): it proposes 2-3 approaches, one question at a time, holds for
your approval per section, and appends the agreed Solution to
`docs/briefs/DECISION-BRIEF.md`. It never auto-advances; leave with "the design is good,
write the spec."

**Scenario 5 -- a vague / ambiguous goal.** Say "I have a rough idea about X", "here's a
vague brief: ...". Claude interviews/grills you via `/kit:think` (6 forcing questions)
and/or `superpowers:brainstorming`; `goal-craft` sharpens a fuzzy intent into an
outcome-shaped `/goal`. On your approval of the crystallized objective, `/kit:assign`'s
freeform path allocates the ID + BACKLOG row and starts the lane. It will NOT write the
spec or start the lane until you approve the crystallized objective (a vague brief turned
straight into a spec is how scope drift starts).

**Scenario 6 -- mid-build "also do Y" (a mid-flight scope change).** You are mid-`/kit:execute`
on a `VALIDATED` spec and the work reveals scope to add now. Say "also do Y", "amend the
spec to cover Y". Claude recognizes a mid-flight amend and runs the declared micro-loop
(BUILDING -> SPECIFYING -> BUILDING) instead of silently editing the spec or restarting:
reach a task checkpoint (finish + verify + commit the in-flight task), append new `- [ ]`
tasks + delta the After-state/AC/Verification (completed `- [x]` tasks untouched), record
an `## Amendments` entry, re-validate the DELTA only, then `/kit:next` to resume. The
canonical rule + four invariants are in `WORKFLOW.md` "## Mid-flight amend".

### The freeform -> ID front door (what `/kit:assign` does internally)

Scenarios 2 and 5 are freeform (no ID). The orchestration is ID-first, so `/kit:assign`
mints the ID for you. Hand it freeform intent instead of an `ID-NNN`:

```text
  /kit:assign "<freeform intent>"
     1. delegate crystallize -> /kit:think runs the interview, returns a crystallized
                                objective + a lane (/assign consumes the result; it does
                                not embed the interview)
     2. approve              -> pause for your approval (approve-before-allocate: a vague
                                brief never auto-creates a row)
     3. sanitize + allocate  -> escape `|`/newlines for the table cells; reduce the slug
                                to [a-z0-9-]+; raise the mint floor past the working copy
                                with the board file's own git history (history_max_id(),
                                so a lagging or archived-row checkout cannot re-hand-out a
                                taken ID); write the next ID-NNN row into _meta/BACKLOG.md
                                in the same step, with a loud equal-ID collision check
                                (atomic-allocate)
     4. rejoin the ID tail   -> write the goal draft, pick the lane, route (Scenario 2's
                                flow), exactly as for an ID-NNN argument
```

It preserves ID-first traceability: even an ad-hoc idea gets a BACKLOG row and an ID
before any draft is written. It stays an **invoked command**, not an auto-firing keyword:
Claude interprets "apply SDD to X" and invokes `/kit:assign`; the kit does not watch for
the phrase. The four invariants it upholds: delegate-to-`/kit:think`,
approve-before-allocate, sanitize, atomic-allocate.

### Pre-authorization phrases (the autonomy dial)

| You say | Autonomy | Claude stops at |
|---|---|---|
| "propose it, don't run anything" | none | after planning; waits for go |
| "run it, check with me at each phase" | low (default) | every advisory phase checkpoint |
| "run the lane, only stop at hard stops" | high | the 4 hard stops + the push/PR (outward-facing) |
| "run it all the way to a PR, your call" | max | only the 4 hard stops + a real blocker |

The 4 hard stops (`safety-gate`, `push-to-main`, `anti-rationalization`, the verification
pipeline) are **never** waived by any autonomy level.

(The at-a-glance intent cheat-sheet now lives at the top: see `## Drive it by intent (start here)`.)

## Gate ledger CLI (the grammar commands record with)

Commands normally write these lines for you; when driving by hand (headless runs, a bare adopter
session), the shapes are:

```bash
bash lib/gate/gate-ledger.sh record  <rid> <phase> <ran|skipped> [reason]
bash lib/gate/gate-ledger.sh outcome <rid> <phase> <start|end> [caught=<true|false>]
bash lib/gate/gate-ledger.sh show    <rid>
```

- `<rid>` is the spec/branch slug (e.g. `payment-retry`), never a board `ID-NNN`: the ship-gate
  resolves the slug from the branch name and reads only entries recorded under it.
- Every `[reason]` is free text EXCEPT a `grill` + `skipped` line, whose reason must START with
  one closed-enum token: `reason=home-turf`, `reason=density-low`, or `reason=operator-wave`,
  optionally followed by `: <why>` (e.g. `reason=density-low: one-file doc fix`). Any other
  first token is refused at write time.
- The full verb list (`start`, `debt`, `override`, `check`, ...) is the usage header of
  `lib/gate/gate-ledger.sh` itself; run it with no arguments to print it.

## Troubleshooting and recovery

Diagnose and recover when the kit misbehaves. For why a behavior exists, see `docs/PHILOSOPHY.md` and `docs/decisions/`.

### First step always: turn on debug mode

```
export DWARVES_KIT_DEBUG=1
```

Every hook logs to stderr what it matched and what it decided. Run the failing scenario once with debug on; in 90% of cases the line tells you the bug.

### Where to look

| Symptom | Look at |
|---|---|
| Bash command blocked unexpectedly | `~/.claude/dwarves-kit/logs/safety-gate.log` |
| Stop event keeps firing complaints | `~/.claude/dwarves-kit/logs/anti-rationalization.log` |
| New file warned about unfairly | `~/.claude/dwarves-kit/logs/spec-drift-guard.log` |
| Slop-cleaner nagging on something fine | `~/.claude/dwarves-kit/logs/slop-cleaner.log` |
| Session state lost | `.claude/session-state/last-state.md` and `archive/` |
| Statusline showing defaults | run `bash hooks/statusline.sh < /dev/null` and inspect |
| Hook silently does nothing | `DWARVES_KIT_DEBUG=1` and re-trigger; check stderr |

Log paths (line format `timestamp | EVENT | detail | project_dir`). The **run corpus**
that feeds `/kit:retro` and the effectiveness eval (`runs/<rid>.log`, `completeness.log`,
`proof-overrides.log`) defaults to `${XDG_STATE_HOME:-~/.local/state}/dwarves-kit/logs/`
(SPEC-097: outside the plugin-reinstall blast zone so it survives a reinstall; an existing
`~/.claude/dwarves-kit/logs` corpus is migrated in additively on first use). The **hook
diagnostic logs** above (`safety-gate.log`, `slop-cleaner.log`, etc.) stay at
`~/.claude/dwarves-kit/logs/`, they are ephemeral breadcrumbs, not corpus. Set
`DWARVES_KIT_LOG_DIR` to redirect the corpus elsewhere (it also disables auto-migration, so
an explicit path never ingests the legacy corpus); the test suite sets it to a throwaway
`mktemp` dir so running tests never writes into your real tree.

### Common failure modes

#### Every hook fails with `No such file or directory` (bash install)

Symptom: a session opens with `SessionStart:startup hook error ... bash: $HOME/.claude/dwarves-kit/hooks/context-readiness.sh: No such file or directory`, and no kit hook fires. `settings.json` references every hook at `$HOME/.claude/dwarves-kit/hooks/<script>.sh`; the scripts are not there.

Cause: the bash installer was run from a checkout that is NOT `~/.claude/dwarves-kit` (a dev clone elsewhere, a CI clone, a template dir). Older `install.sh` (pre-SPEC-025) only worked when the repo was cloned in place at `~/.claude/dwarves-kit` (README Option 2); from anywhere else it never placed the scripts at the referenced path.

Fix: re-run the installer (`bash <your-checkout>/install.sh`). The fixed installer links each `hooks/*.sh` into `~/.claude/dwarves-kit/hooks/` (and skips linking when the kit IS in place). Verify:
```
ls -l ~/.claude/dwarves-kit/hooks/   # every referenced *.sh resolves
bash tests/test-meta.sh              # the "Installer materializes ..." guard is green
```
If you are pinned to an older installer, the in-place layout always works: clone (or move) the repo to `~/.claude/dwarves-kit` and run `install.sh` there.

#### `safety-gate` blocked a command I want to run

The hook's exit code 2 is final. Override paths in order:
1. Phrase the command differently. `rm` of one file is allowed; `rm -rf` triggers the block.
2. Use the suggested alternative. The block message names one (`trash` instead of `rm`, branch push instead of force).
3. Run the destructive op outside Claude Code. The hook only sees Claude's tool calls.
4. Last resort: comment out the matching pattern in `hooks/safety-gate.sh`, run the op, restore. Do NOT leave the kit in a relaxed state.

#### `anti-rationalization` keeps firing on legitimate work

Check `~/.claude/dwarves-kit/logs/anti-rationalization.log` for the pattern. The v1.1 trim narrowed to 5 phrases ("left as an exercise", "follow-up PR", "too many issues to address", "that's a separate concern", "follow-up task"). If a legitimate phrase is hitting, it is in this list. Options:
- Rephrase the completion note (this is the intended behavior; the hook is doing its job).
- If the pattern is genuinely too broad, propose removing it via a PR with sample false-positive logs from your `.log` file as evidence.

#### `spec-drift-guard` warns on a file you intentionally added outside the spec

The warning is a nudge, not a block. The file still gets written. The intent is to surface unplanned scope creep so it appears in the chat record. Two responses:
- The new file is genuinely needed. Update the active spec (`docs/specs/SPEC-NNN-<slug>.md`) to list it; the warning stops on subsequent edits.
- The file is genuinely off-spec. Delete it; tighten the spec or cycle through `/think` again.

#### `auto-format` adds 5+ seconds to every edit

The hook was downloading the formatter via `npx --yes` per edit (v1.0 bug). Fixed in v1.1: detection order is project-local > global > npx cache only (`npx --no`). If you still see slowness:
- Confirm the formatter is installed globally: `which prettier`, `which ruff`, etc.
- Confirm the hook is the v1.1+ version: `grep -- '--yes' hooks/auto-format.sh` should return nothing.

#### Session state was lost across compaction

Compaction sequence:
1. `pre-compact-backup.sh` writes a snapshot.
2. Claude Code compacts.
3. `post-compact-reinject.sh` re-injects critical rules.
4. `session-state-save.sh` continues to write to `.claude/session-state/last-state.md` on every Stop.

If state is missing, check in order:
- `.claude/session-state/last-state.md` exists and is current.
- `.claude/session-state/archive/` for the last 10 rotated snapshots.
- Bash install only: confirm both PreCompact and PostToolUse(compact) hooks are registered in `settings.json`.
- Plugin install: same checks against `hooks/hooks.json`.

#### Statusline shows blank or default values

The script reads model, branch, context %, cost, and thinking mode from Claude Code's StatusLine JSON contract. If Anthropic changes the schema, the script shows defaults.

Diagnose:
```
bash hooks/statusline.sh < /dev/null
```

This runs the hook with no input. Compare what it prints to what a real StatusLine event would give. If a real event's JSON has unexpected fields, propose a hook update with the schema diff.

Plugin install path: statusline is NOT configured (v1 plugin schema gap). Either switch to bash install or wait for the schema to gain `statusLine` (sunset trigger in ADR-0009).

#### `task-verifier` blocks on something the spec actually allows

The verifier reads the spec literally. If a task's acceptance criterion is fuzzy ("works well", "is fast enough"), the verifier may FAIL it. Two responses:
- The spec criterion is too fuzzy. Edit the active spec (`docs/specs/SPEC-NNN-<slug>.md`) to make it concrete, then re-run.
- The criterion is concrete but the verifier is wrong. Inspect the verifier's report. If the verifier is hallucinating a requirement, file an issue with the SPEC excerpt + verifier output.

#### `fix-agent` retried twice and the task still fails

The retry cap is by design. After two FAIL:fixable verdicts, the orchestrator halts and asks the human. Read the verifier's final report:
- The task is genuinely harder than the spec assumed. Re-scope in `/think`.
- The fix-agent is making the wrong fix because the verifier's report is unclear. Edit the spec acceptance criterion to be more specific; re-run.
- The acceptance criterion is impossible to meet with the current stack. Update the spec or change the stack.

### Recovery paths

#### Restore session state after a crash

```
ls -lt .claude/session-state/
cat .claude/session-state/last-state.md
```

If `last-state.md` is corrupt, fall back to the most recent archive:
```
ls -lt .claude/session-state/archive/ | head -3
```

Read the archive into the next session prompt.

#### Reset hooks without uninstalling the kit

Bash install:
```
bash install.sh --uninstall   # removes kit hooks from settings.json
bash install.sh                # re-registers
```

Plugin install:
```
/plugin uninstall dwarves-kit@dwarves-marketplace
/plugin install dwarves-kit@dwarves-marketplace
```

#### Roll back a bad release

The kit ships atomic conventional commits, each scoped to a logical change. `git revert <sha>` per bad commit, then re-tag.

If `tests/test-hooks.sh` or `tests/test-meta.sh` start failing after a revert, that is signal: the change being reverted had cross-cutting test impact. Address the failing test before the next tag.

### When to escalate

File an issue at https://github.com/dwarvesf/dwarves-kit/issues with:
- The failing hook or command name.
- The relevant log file contents (redact paths if needed).
- Output of `DWARVES_KIT_DEBUG=1 ...` for the failing scenario.
- Kit version (`cat VERSION`) and Claude Code version.

Do NOT escalate for cases where the kit is doing exactly what it claims (e.g. blocking a `git push --force` to main). Those are working-as-designed; this section is for understanding why, not for routing around.
