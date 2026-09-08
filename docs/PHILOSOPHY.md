# PHILOSOPHY.md

> This document is for the maintainer, not the end user.
> It governs what gets added, what gets rejected, and why.
> Read this before proposing any change to the kit.

---

## 1. Design principles

Each principle resolves a real tradeoff. If it can't be violated, it's not a real principle.

### "Toolbox, not appliance"

We believe the kit is a set of independently useful modules a consumer installs a-la-carte, not a single feature-flagged product they switch on wholesale. "Bash over binaries" and "shallow and wide beats deep and narrow" are not just craft preferences here, they are STATED CHOICES in service of this composability: a small, legible surface that installs piece by piece is only possible if each piece stays simple (bash, readable in 30 seconds) and no piece tries to do everything (breadth over depth per phase). The essential SPINE, safety-gate, ship-gate, spec-drift-guard, secrets-guard, commit-format, anti-rationalization, is always wired, because it guards irreversible boundaries (push, merge, secrets, commit hygiene) no consumer should be able to accidentally skip. Everything else is opt-in: board/session/advisor/cosmetic (hook-bearing modules) and queue/stats/quiz_gate/weekend_batch/bridge (hookless modules, commands/skills/lib entries with no hook to gate) install only when named via `install.sh --with <a,b,c>`, recorded in the consumer's own `kit.toml [modules]`, a per-consumer install RECORD, never a runtime feature-registry a hook reads back (a standing CI lint keeps it that way). Git is the only shared medium: a module writes to the append-only ledger, the spec store, or the backlog file on disk, never to private in-memory or database state another module depends on.

**Decision this already made:** the spine/optional split (Decision B, kit-modularity SG-04); the `kit.toml`-is-not-a-registry CI lint; the standalone `<subsystem> <verb>` entries (`board`, `stats`, `gate`, `classify`, `spec`, `goal`, `session`, kit-modularity SG-03) each self-documenting via their own `--help`, with the `kit` uber-dispatcher evaluated and SKIPPED for the same reason, a central binary or registry is exactly the coupling seam the toolbox model exists to avoid.

**Decision this would reject:** "add a `kit init` wizard that turns modules on interactively," or "a central `kit list` registry the hooks consult to decide what's active." Both re-create the single point of coupling that turns a-la-carte pieces back into one appliance.

**The anti-goal, stated plainly: the kit must never feel like one big product.** If installing it ever requires understanding the whole system before using any one part of it, the modularity has failed regardless of what the code looks like underneath.

### "Reversible in git" is the line between acting and asking (2026-09-08)

We believe an action a `git revert` undoes should be DONE and reported, never offered and
waited on. Asking costs the operator a round trip to type "ok" and buys no safety, because the
undo was already free. The line is not "risky versus safe", which nobody can apply
consistently. It is mechanical: **can a revert undo it?** A commit in a private repo, a local
file write, a branch or worktree delete, a merge of the operator's own green PR, all yes, so
they act. A publish, a send, a charge, a production delete, a force-push, all no, so they ask.

Every such action is a named knob whose shipped default acts, so an operator who wants the
report instead flips one line rather than losing an argument. The full set lives in `kit.toml`
under `[ship]`, `[debug]`, `[review]` and `[wrap]`; `bash bin/config list` renders it. A `false`
turns that step's action into a report line. It never turns the step off, and it never relaxes
a refusal the tools already make on their own.

Two rules keep this from becoming recklessness. **Per-item verification stays the gate
everywhere:** a review finding is applied only if the responding agent verified that specific
item, and a fix is declared done only if its own test passes. **The exception is named, not
implied:** the `til` publish leg stays gated because a deleted public note stays cached and
indexed, and `wrap.drain_staged` ships `false` because it starts unattended work rather than
finishing requested work. Naming the exceptions is what makes silence on everything else safe.

**Decision this already made:** the `Needs you` admission test in `commands/wrap.md`, mechanised
as `lib/wrap/report-lint.sh`, which fails a report whose item offers to do the work instead of
naming a blocker.

**Decision this would reject:** "ask before every commit, to be safe." The commit is not pushed,
so the question protects nothing and spends the operator's attention, which is the scarce thing.

### Multi-agent future (a stated boundary)

The standalone `<subsystem> <verb>` SHELL surface (`board`, `stats`, `gate`, `classify`, `spec`, `goal`, `session`) is runtime-agnostic: any shell-capable agent, pi, opencode, Claude Code, or a human at a terminal, can run `bash lib/gate/gate.sh ledger rid` directly, because it is bash reading and writing files git already tracks, nothing Claude-Code-specific. The agent-AUTHORING surface (`agents/`, `commands/`, `skills/`) is not: it is Claude Code's loader format specifically, frontmatter YAML, `/kit:<name>` namespacing, the Task-tool dispatch contract, and porting the kit to another runtime would mean that runtime growing its own loader for the same underlying scripts, not a rewrite of the scripts. This is a boundary the kit states honestly rather than papers over: the shell layer already is multi-agent-ready; the authoring layer is not, by construction, until a second loader exists to read it.

### Team mode: parked, not absent

`[modules] team_mode` exists as a named, reserved slot in `install.sh` (requesting it errors "reserved, not-yet-installable module", it does not silently accept the value), a deliberate act of naming a known future need without building it prematurely (Decision C). The tripwire for building it is concrete, not aspirational: a second named human user actively operating against the same kit install. Until that fires, the single-operator assumptions already baked into the goal registry (ADR-0022, the cross-session disjointness gate) and the board/mirror conflict rule (git wins, always, per SPEC-147/149) would need real design work, not a flag flip. Parked and honestly labeled beats quietly absent.

### "Guardrails over guidance"

We believe enforcement beats advice. A rule in CLAUDE.md is followed ~70% of the time. A hook with exit code 2 is followed 100% of the time. Therefore we build hooks for anything safety-critical, and use commands/CLAUDE.md only for things where human judgment matters.

**Decision this already made:** Anti-rationalization is a Stop hook, not a line in CLAUDE.md. Push-to-main blocker is a PreToolUse hook, not a convention.

**Decision this would reject:** "Add a CLAUDE.md rule saying 'always write tests first.'" If it matters enough to enforce, it needs a hook (like tdd-guard). If it's just advice, it belongs in the team wiki, not the kit.

### "Synthesize, don't originate"

We believe cherry-picking battle-tested patterns from mature tools is better than inventing new workflows. Every command and hook in this kit traces its lineage to a specific repo. We don't invent novel approaches; we curate and integrate proven ones.

**Decision this already made:** /think is gstack's /office-hours adapted. /review is gstack's paranoid reviewer + Trail of Bits' quality rules. The safety-gate hook is Trail of Bits' verbatim code. We cited every source in README.md.

**Components with indirect lineage (originated in-kit but grounded in existing patterns):**
- context-readiness.sh: analogous to CI pre-flight checks (GitHub Actions `if:` conditions, Buildkite pre-command hooks). Novel integration, proven pattern.
- spec-drift-guard.sh: analogous to linting rules that flag undeclared variables. The "check against a manifest" pattern exists in package managers (lockfile drift checks), dependency auditing, and Terraform plan drift detection.
- /kit-health: analogous to `npm audit`, `cargo clippy`, self-diagnostic commands in mature CLIs.
- the SPEC format (`docs/specs/SPEC-NNN-<slug>.md`): derived from architecture decision records (ADR), user story templates, and GSD's task breakdown convention. The format is a composition, not an invention.

**v1.2 additions with direct lineage:**
- task-verifier subagent: synthesized from the family of architect-verifier-in-Ralph-loop patterns, adapted to a read-only Claude Code custom subagent. The verify-after-every-task pattern is the same; the mechanism changed from in-session check to isolated subagent.
- fix-agent subagent: Smart Ralph's fail-fix-re-verify loop, adapted to a write-scoped subagent dispatched only on FAIL:fixable verdicts.
- /start command: CCGS's /start router (detects project stage and routes to the right agent), adapted to read the active spec's `Status:` field.
- context-readiness v2 (command suggestions): same CCGS /start detection pattern, injected into SessionStart hook context instead of requiring a command invocation.

**Decision this would reject:** "I have a new idea for a code review methodology nobody's tried." Test it as a standalone experiment first. If it works in production for 3+ months, then propose merging it into the kit with a source citation.

### "One kit, whole cycle"

We believe a unified kit covering Think-through-Retro is more valuable than 4 best-of-breed tools that don't talk to each other. The spec format that /spec produces is the same format that /execute reads, that /review checks against, and that /docs updates. Data flows through the cycle; nothing is re-entered.

**Decision this already made:** the spec (`docs/specs/SPEC-NNN-<slug>.md`) is the shared contract between /spec, /spec-validate, /execute, /next, /review, and /docs. The spec-drift-guard hook references the same directory.

**Decision this would reject:** "Let's use GSD for planning and a separate tool for execution with its own format." Format translation between tools is where context gets lost. One format, one directory, one kit.

### "Shallow and wide beats deep and narrow"

We believe covering the full lifecycle (Think, Spec, Validate, Build, Review, Docs, Ship, Reflect) at 70% depth each is better than covering a couple of phases at 100% depth. The biggest failures in AI-assisted development come from skipped phases (no spec, no review, no retro), not from insufficient depth in any one phase.

**This principle UPHOLDS cross-goal fan-out, it does not forbid it (ADR-0019).** Running N goals concurrently is *width* (N lifecycles at 70% depth each), not the *depth* of an in-kit scheduler. The boundary "Shallow and wide" draws is against rebuilding a runtime (a DAG, wave execution, crash recovery), not against breadth. Fan-out behind the disjointness gate stays shallow-and-wide; a topological scheduler would not, and is handed to GSD v2.

**Decision this already made:** /execute uses Claude Code's native Task tool for subagent dispatch. It's not as sophisticated as GSD v2's Pi SDK runtime (which has crash recovery, token tracking, and automated git branching). But it exists, and it covers the execution gap that 0 commands would leave.

> **"GSD v2" disambiguation.** Throughout this doc, *GSD v2* means the standalone agent at [gsd-build/gsd-2](https://github.com/gsd-build/gsd-2) (npm `gsd-pi`, a TypeScript runtime on the Pi SDK with its own CLI), **not** a newer release of the *GSD v1 / get-shit-done* Claude Code plugin. They are two separate products that share a brand. The kit absorbed *patterns* from the v1 plugin; it points at the v2 *runtime* as an external execution engine to integrate, never to rebuild.

**Decision this would reject:** "Let's build a custom TypeScript runtime for task execution like GSD v2." That's building a product, not maintaining a kit. If execution depth becomes the bottleneck, adopt GSD v2 as the execution engine and integrate it, don't rebuild it.

### Skill routing: what belongs in the kit

The kit owns LOOP MACHINERY: lanes, type loops, gates, proof dialects, the board, and the commands that drive them. Two other skill tiers live OUTSIDE the kit, in the operator's own skill estate: **reflex skills** (instant, gate-free responses: explain a concept, zoom out to a module map, hand off a session) and **domain procedures** (incident runbooks, learning-day pipelines, payroll closes). The type registry's owning-skill/agent column is the bridge: a kit loop may NAME an external procedure as its executor, but the kit never absorbs the procedure itself.

Absorb routing follows mechanically: an external skill that describes how a loop, gate, or proof should run is absorbed into the kit (`/kit:absorb`, with citation). An external skill that is a reflex or a domain procedure lands in the operator's skill estate and at most earns a registry reference. Chat stays chat (§6 N1's coexistence corollary: the kit engages only when a task is being executed); reflexes stay reflexes.

**Decision this already made:** `/kit:grill` absorbed grill-with-docs (intake is loop machinery, SPEC-058); `handoff` and `zoom-out` were routed to the operator estate; `teach`'s ideas routed to the operator's learning procedure (SPEC-059).

**Decision this would reject:** "Add a /kit:explain command so users can ask concept questions inside the kit." That is a reflex, not a loop; absorbing it grows the kit's surface without adding any gate, proof, or loop value.

### "Verify before proceeding"

We believe every task output should be verified by a dedicated agent before the orchestrator moves on. Self-reported "done" from a worker agent is not proof of completion. The verification pipeline (worker > verifier > fix-agent retry) catches issues at the cheapest point: right after the task, before downstream tasks build on top of a broken foundation.

**Decision this already made:** /execute dispatches a read-only task-verifier subagent after each worker completes. The verifier checks acceptance criteria, runs tests, and checks scope compliance. On FAIL:fixable, a fix-agent applies targeted corrections (max 2 retries). On FAIL:escalate or after 2 failed retries, the human decides.

**Source:** synthesized from the family of architect-verifier-in-Ralph-loop patterns (read-only verification after execution); Smart Ralph's fail-fix-re-verify loop (retry with feedback). Adapted: separate read-only verifier (cannot modify code) and write-scoped fix-agent (scoped to specific files). This separation prevents the verifier from "fixing" things by silently rewriting code. See ADR-0005.

**Decision this would reject:** "Let the worker self-verify before reporting done." Self-verification is the fox guarding the henhouse. The worker's context is biased toward its own implementation. A fresh context window with only the spec and the diff catches things the worker's context normalized away.

**Bend (execution-backed verify).** "Verify" means the check was *actually run* and the run is *recorded as a re-runnable artifact*, not asserted in prose. The verifiers ran the suite but the result evaporated into a "Tests: passing" line nobody could re-run. (This is the *recording* dimension of the verify arm; it is distinct from ID-020's removal-class absence check, which `task-verifier` Section 1b already covers. The two are thematic neighbors, not the same gap.) Now `task-verifier` reports a `Verification record` (the exact command + captured exit code + output excerpt), `/kit:execute` and `/kit:verify` append it to `docs/verification/<spec-slug>.md`, and a task with no runnable check records an explicit `[NO EXECUTABLE CHECK: <reason>]` instead of a silent pass. A later reader re-runs the recorded `Command:` line to regression-check the verdict. This is the lab-notebook discipline (a run is only verified once it is logged and reproducible), the same by-product-of-the-flow shape the implementation-notes log (SPEC-041) already established. It extends ADR-0005 (verify-then-trust); it does not add a new principle. Kept as command/agent text + a convention doc pinned by `tests/test-meta.sh`, not a new hook: the record is produced structurally by the verify flow, so it does not depend on the LLM remembering. A ship-gate that *blocks* on a missing verification entry was the deferred enforcement escalation; it is now **built** (ADR-0025): `lib/gate/proof-ledger.sh`, wired into `hooks/ship-gate.sh`, refuses the ship/push boundary for a load-bearing change with no matching, fresh proof-of-done entry. It keys off the branch diff (not a spec), so it fires on freeform `/goal` work too, is opt-in per repo (only where `docs/verification/README.md` exists), and bypasses only via an explicit logged override. This is the deliberate "guardrails over guidance" escalation: advice became a wall, but only at the one irreversible boundary, mirroring ADR-0024's lane gate.

### "Bash over binaries"

We believe every hook should be a readable shell script, not a compiled binary or a Node.js project. A contractor should be able to open any .sh file, read it in 30 seconds, and understand what it does. When a hook misbehaves, `bash -x hooks/safety-gate.sh` is the entire debugging workflow.

**Decision this already made:** All 9 hooks are bash scripts using jq for JSON parsing. No Python, no Node, no compiled code. Auto-format detects formatters with `command -v` and runs them directly.

**Decision this would reject:** "Let's rewrite hooks in Python for better JSON handling." Adds a runtime dependency, slows startup, and makes debugging harder. The only exception is upgrading anti-rationalization to a prompt-type hook (which delegates to the LLM, not Python).

**Carve-out:** The HUD/statusline script may use Node.js (via mjs) because StatusLine runs per-turn and needs fast JSON parsing that bash+jq struggles with at scale. This is the only exception. If a second exception is proposed, the principle should be revisited entirely, not bent again.

### "Detect, don't dictate"

We believe the kit should detect the user's current state and suggest the right action, not require them to memorize 11 commands. A full-time coder in flow state doesn't want to remember whether the next step is /review or /docs or /ship. The kit should surface what's relevant based on project state.

**Decision this already made:** context-readiness hook (v1.2) reads the active spec's status, counts completed tasks, checks whether the spec carries a `## Review` section, and injects a one-line "next:" suggestion into Claude's context at session start. The /start command provides the same detection as an explicit entry point. Both detect and suggest; neither blocks.

**Decision this would reject:** "Add a phase-locking system that blocks /execute unless /spec-validate has been run." Rigid *mid-flight* phase gates annoy experienced coders who know when to skip a step. Detect and suggest, never block progression mid-flight. **The exception is irreversible-cost actions, which DO block:** safety hooks (rm-rf, push-to-main, force-push) and, per ADR-0024, the ship/push boundary, which refuses when a lane's required (measure-twice) gate has no `ran`/`override` entry in the run ledger. This is the same logic as push-to-main (ship is irreversible), not a new kind of gate: the block lives only at ship, never at a mid-flight phase, and a logged override always exists, so the mechanism records what was skipped rather than forcing every gate. See ADR-0024 (the ID-036 hooks-also-enforce-at-ship layering bend).

### "Disclose gaps, don't hide them"

We believe a doc describing an alternate or degraded path should state exactly what it cannot do, in short bullets, right where that path is offered. A silent gap surfaces later as a confused bug report; a disclosed gap lets the user route around it up front.

**Decision this already made:** `/kit:onboard` section E states the plugin-path gaps (no statusLine HUD, a frozen SHA vs `git pull`, project hook wiring that points at the bash path, the `KIT_FORCE_FULL=1` escape) as four short bullets, at the exact moment the plugin path is offered, not buried in a troubleshooting doc.

**Decision this would reject:** "Just skip mentioning the gap; most people will not hit it." Every doc offering a path with a known limit generalizes this convention, README included.

**Corollary (distribution honesty):** a shipped surface (script, agent frontmatter, spec) names a Tier-1 default first, external tools any adopter has (docker, git, the `claude` CLI); a personal or platform-specific tool (a maintainer's own vault ref, ops-toolkit CLI, container runtime) appears only as a clearly-marked example the adopter substitutes. An adopter should never hit a dependency they do not have on the default path.

### "Verify, then trust"

We believe every task output should be verified by a separate agent before being accepted. The worker who writes code is not the right judge of whether that code meets the spec. A dedicated verifier with read-only access and specific acceptance criteria catches issues that self-assessment misses. When verification fails on fixable issues, a scoped fix agent gets exactly one shot (max 2 retries total) before escalating to a human. We don't retry ambiguous failures because they indicate design problems, not code bugs.

**Decision this already made:** /execute dispatches task-verifier (read-only subagent) after every worker completes. Verdicts are PASS, FAIL:fixable, or FAIL:escalate. fix-agent handles FAIL:fixable with a max 2 retry cap. FAIL:escalate always goes to the human.

**Decision this would reject:** "Let the worker self-verify by running tests before reporting." Self-verification is necessary but not sufficient. The verifier checks spec compliance, scope drift, and quality issues that the worker has no incentive to flag about its own work.

**Decision this would also reject:** "Remove the retry cap and let fix-agent keep trying." Unbounded retries burn tokens without progress when the issue is architectural. Two retries is the sweet spot: catches most import/assertion/off-by-one bugs, escalates everything else.

### "External tools are dependencies, not features"

We believe the kit should check for external tools and warn when they're missing, but never rebuild their functionality. Context Hub, Context7, codebase-memory-mcp, and MCP servers are separate products that evolve on their own schedule. The kit's job is integration, not duplication.

**Decision this already made:** context-readiness hook checks if chub is installed and if .mcp.json exists. The get-api-docs skill teaches Claude to use chub. Neither rebuilds chub's functionality.

**Decision this would reject:** "Let's build our own API doc fetcher instead of depending on Context Hub." If chub breaks or disappears, we remove the check. We don't maintain a replacement.

---

## 2. Target user and their actual week

### Who this is for

Han at Dwarves Foundation. Two modes, one person.

**Lead mode**: Technical lead managing contractors. Delegates implementation, reviews PRs, plans features. Splits time between ops (Notion, payments, hiring) and engineering (specs, code review, architecture). Touches the kit at phase boundaries: beginning of week (plan), middle (hand off), end (review + ship).

**Coder mode**: Full-time builder using Claude Code 6-8 hours/day. Needs: HUD for context budget awareness, faster permission approvals, slop detection after long sessions, session state persistence across compaction. The cycle is tighter: hours instead of days, per-task instead of per-week.

Both modes share the same spec format, hooks, and commands. The difference is frequency of interaction, not the workflow itself. A contractor using the kit operates in a variant of coder mode.

Not: a team of 10 with a dedicated DevOps pipeline. Not: a team of 3+ live human operators, nor coordination across machines (that's L5, use Nimbalyst/Conductor). In-scope: one lead session fanning out N isolated worktree workers over disjoint specs (ADR-0019), and one operator running N concurrent same-machine sessions over disjoint goals, coordinated by the passive running-goal registry (ADR-0022). "Several sessions" means one human running several, not a team.

### What their week looks like

**Lead mode week:**

**Monday**: Review last week's shipped work. Check contractor PRs. Plan the week's features.
Kit touches: /retro (if not done Friday), /think for new features.

**Tuesday-Wednesday**: Spec new features, hand off to contractors. Context: Notion tasks, Slack async, GitHub PRs.
Kit touches: /spec, /spec-validate. Contractor gets spec + CLAUDE.md + kit installed on their machine.

**Wednesday-Thursday**: Contractor builds. Han does ops work (payments, hiring, client calls). Gets desktop notifications when Claude Code needs input on the contractor's machine.
Kit touches: /execute or /next (contractor runs these), hooks enforce during build (safety-gate, auto-format, spec-drift, anti-rationalization). Pre-compact backup protects long sessions.

**Friday**: Review, ship, reflect. Han reviews the contractor's work, updates docs, ships, captures learnings.
Kit touches: /review, /docs, /ship, /retro.

**Coder mode day:**

Morning: /next to pick a task, or /execute for autonomous mode. HUD visible throughout showing context budget.
Midday: Code for 2-4 hours. Hooks enforce continuously. Compaction backup fires at ~50k tokens. Permission auto-approve removes friction for reads.
Afternoon: /review own work, /docs to update documentation, /ship to commit and PR. /next for the next task.
End of day or end of sprint: /retro to capture learnings.

### What the kit does NOT cover

- **Ops work**: Contractor payments, hiring pipeline, client comms. These use Notion + existing Dwarves skills, not the kit.
- **IDE choice**: The kit works from the terminal. VS Code, Neovim, whatever.
- **CI/CD**: The kit produces commits and PRs. GitHub Actions or whatever CI pipeline runs after that is a separate concern.
- **Multi-agent coordination across machines or by a team**: When 3+ contractors (multiple human operators) run Claude Code, or sessions must coordinate across machines, that's L5 orchestration (Nimbalyst/Intent territory). In-kit: one **lead** session orchestrating N isolated worktree workers within itself (ADR-0019), and one operator's N concurrent same-machine sessions over disjoint goals, coordinated by the passive running-goal registry (ADR-0022, the cross-session disjointness gate + monitor). What stays L5: coordination across machines, 3+ live human operators sharing a pool, and goal-ordering chains (B waits for A to merge).
- **Project management**: No sprint boards, no story points, no velocity tracking. Notion handles that.
- **A cross-task DAG / scheduler / runtime**: bounded cross-goal fan-out IS in-scope (ADR-0019, SPEC-032): one lead session fans out N disjoint `VALIDATED` specs into isolated worktree workers behind a disjointness gate, with lead-owned convergence. What stays out: a topological / wave scheduler, crash-recovery durability, and intra-spec task parallelism (`/kit:execute` itself stays sequential, dispatching one task at a time via the Task tool). The moment goals develop real ordering chains (C needs A+B merged, then D needs C), hand execution to GSD v2 (Pi SDK runtime) or Agent Teams; the kit does not rebuild a runtime.

---

## 3. Design boundaries (the NO list)

### Hard limits

- **Every file must justify its existence.** No file count cap, but every addition must solve a real problem. If a file hasn't been used in 30 days, it's a deprecation candidate.
- **Maximum 500ms per hook execution.** If a hook takes longer, it degrades the coding experience. Profile with `time` before merging.
- **No compiled binaries.** Everything is bash, markdown, or JSON. If a feature requires a binary, it becomes an external dependency, not part of the kit.
- **No paid dependencies.** The kit must work with free tools only. Paid tools (ClaudeKit Engineer Kit, Exa API) can be optional enhancements but never required.
- **No LLM API calls in v1 hooks.** Prompt-type hooks call the LLM, adding latency and cost. Deferred to v2, and only for anti-rationalization where the accuracy gain justifies it.

### Feature rejection criteria

Reject a proposed feature if ANY of these are true:

1. **It duplicates an external tool.** If Context Hub, GSD, gstack, or a plugin already does it well, depend on it instead.
2. **It serves fewer than 2 lifecycle phases.** Single-purpose tools belong as standalone scripts, not kit features.
3. **It requires the user to change their existing Notion/GitHub workflow.** The kit adapts to how Dwarves already works. It doesn't impose a new project management system.
4. **It can't be explained in one sentence.** If you can't describe what the hook/command does in one line of the README table, it's too complex.
5. **It has no source citation.** Per the "synthesize, don't originate" principle, every pattern must trace to a proven implementation.

### When to recommend an external tool instead

- Need browser-based QA? Install gstack for /qa (requires Playwright + Bun).
- Need full autonomous execution with crash recovery? Install GSD v2 (requires Pi SDK).
- Need multi-agent orchestration? Install Nimbalyst or Conductor.
- Need security auditing? Install Trail of Bits plugin marketplace.
- Need TDD enforcement? Install tdd-guard plugin.

The kit is the glue layer. It doesn't compete with specialized tools.

### Loop boundaries (bounded in-session, not unbounded outer)

The kit ships bounded in-session loops and declines unbounded outer ones. This refines SPEC-003 DEC-005 (the prior "outer loops declined" framing), which read too bluntly.

- **Unbounded outer bash loop** (an external `while` re-spawning sessions until done): declined. That is autonomous-runtime territory (GSD v2 / OMC); the fence stays firm (see "When to recommend an external tool instead" above).
- **Bounded in-session Stop-hook loop** (a continuation that keeps the current session working until a condition holds): native and first-party-blessed (Anthropic's `ralph-loop` plugin: "the loop happens inside your current session"). The kit already owns this primitive twice: the **goal loop** (the anti-rationalization Stop hook backing a `/goal` / `goal-craft` / `ralph-loop`-activated objective, wired from the backlog by `/kit:assign`, SPEC-006) and the **debug loop** (the `/kit:debug` iron-law loop with its guess-fix guard, SPEC-013). Both are bounded by a model-evaluated stop condition and the existing safety subset, not by an external driver.

The distinction: bounded loops continue *within* a session under a verifiable stop; unbounded loops spawn *new* sessions without one. The kit does the first, declines the second. Source: SPEC-006 (this note), SPEC-003 DEC-005 (prior framing), Anthropic `ralph-loop`.

### Downstream-facing lanes (a recorded exception to "serves 2+ phases")

Most kit features must serve 2+ of the kit's own workflow phases. `/kit:visual-team` (SPEC-016) and `/kit:ui-design` (SPEC-020) are recorded exceptions: the kit is bash/CLI with no UI, so a visual-design critique and a UI-design loop serve no phase of the kit's *own* work. They are shipped because the kit is also a template for downstream projects that *do* have a UI. The kit dogfoods `/kit:devs-team` and `/kit:test-plan` but not the two visual lanes. These exceptions are named here, and in `commands/kit-health.md`, so the self-assessment does not flag the lanes as speculative features. New downstream-only lanes must clear this same explicit bar: a named consumer outside the kit, not "might be useful someday." Two such lanes now exist; a third should prompt reconsidering a downstream `ui` plugin namespace rather than a third individual carve-out.

---

## What we explicitly reject (from upstream observation)

The 2026-05-20 upstream audit (the 10 source repos checked at their then-current HEADs) surfaced four recurring anti-patterns in the wider Claude-Code-tooling ecosystem. The kit rejects each on sight. Each entry names the pattern, where it was observed, the principle it violates, and the review-criterion that catches it.

1. **Vendor-skill sprawl.** Bundling ever more third-party skills into the kit so the install "does more."
   - Observed: ClaudeKit (`mrgoonie/claudekit-skills`, HEAD @ 2026-05-20 audit), whose skill set drifts wider release over release.
   - Violates: "External tools are dependencies, not features" and the NO-list one-sentence rule.
   - Caught by: a new skill must serve 2+ workflow phases and trace to a single proven source; a skill that exists only to pad the catalog is rejected.

2. **UI-shell creep.** Growing a statusline/HUD into a stateful UI layer with caches, themes, and its own config surface.
   - Observed: oh-my-claudecode (`Yeachan-Heo/oh-my-claudecode`, HEAD @ 2026-05-20 audit), whose HUD accumulates cache-GC and theming concerns.
   - Violates: "Bash over binaries" and "every script readable in 30 seconds"; a UI shell is a product, not glue.
   - Caught by: the statusline carve-out is display-only; any cache, persisted state, or theme engine in a hook is rejected.

3. **Agent-persona theater.** Wrapping agents in role-play personas (a "studio", an "agent company", named characters) to imply capability the mechanism does not have.
   - Observed: the "agent-company OS" framing associated with the OMC name (`1mancompany/OneManCompany`, HEAD @ 2026-05-20 audit).
   - Violates: "Guardrails over guidance" and ADR-0008 (persona/coercion prose is not enforcement).
   - Caught by: agents are named for their function (task-verifier, fix-agent), never for a persona; identity or stake framing in a prompt is rejected.

4. **Slop-PR submissions.** AI-generated pull requests with no human involvement, speculative fixes, or features nobody asked for: the rising threat to any popular AI-tooling repo.
   - Observed: the defensive rejection wall in obra/superpowers `AGENTS.md` (v5.1.0), written precisely because the phenomenon is now common.
   - Violates: "Synthesize, don't originate" and "No speculative features."
   - Caught by: CONTRIBUTING.md's "If You Are an AI Agent" wall plus the rejection criteria above; a PR that cannot cite its source or name the phase it serves is closed.

---

## 4. Differentiation thesis

Why pick dwarves-kit over installing GSD + gstack + Trail of Bits separately?

The honest answer: dwarves-kit is less powerful than any of those tools in their area of specialty. GSD's spec generation is deeper. gstack's review is more thorough. Trail of Bits' security config is more comprehensive.

What dwarves-kit offers is **lifecycle continuity**. The spec format that /spec produces flows unchanged into /execute, /review, /docs, and /ship. The hooks reinforce the commands: context-readiness checks for a spec before the build starts, spec-drift-guard warns during the build, anti-rationalization catches premature completion, post-compaction re-injection restores rules after long sessions.

With separate tools, you get: GSD's planning-dir format, gstack's todo-file format, Trail of Bits' settings.json. Three tools, three conventions, three directories. The contractor has to learn all three. When something breaks between phases, nobody owns the gap.

With dwarves-kit: one spec location (docs/specs/), one convention, one install. The contractor runs `install.sh` and gets everything. The hooks protect them automatically. The commands guide them through the phases. The data flows.

The thesis is not "better components" but "better integration." If that thesis is wrong -- if the integration overhead isn't worth the depth tradeoff -- then the right answer is to use the specialized tools directly and accept the format translation cost.

---

## 5. Evolution strategy

### Adding a new component

1. **Identify the source.** What existing tool or pattern does this come from? (principle: "synthesize, don't originate")
2. **Score with the adoption rubric.** Layer fit + Pain match + Adoption cost + Timing; the scored table lives in `docs/ABSORPTION.md` (not a `/eval-tool` command). Must score 10+ to be ADOPT.
3. **Check the NO list.** Does it violate any hard limit or rejection criterion?
4. **File budget check.** Will the kit stay under 35 files? If not, what gets removed?
5. **Performance check.** For hooks: does it complete in under 500ms?
6. **Write the one-sentence description.** If you can't, it's too complex.
7. **Add source citation.** README credits section must be updated.
8. **Test on one real project for 1 week before merging.**

### Deprecating a component

If a component has been unused for 30 days (no contractor reports using it, no signal in retros), it's a candidate for removal. Steps:

1. Move to a `deprecated/` directory (not deleted immediately)
2. Remove from settings.json and README
3. After another 30 days with no complaints, delete entirely
4. Document the removal in CHANGELOG.md with rationale

### AutoResearch optimization

Corrected citation (2026-07-31): the real source is [github.com/karpathy/autoresearch](https://github.com/karpathy/autoresearch). It tunes ONE numeric metric (`val_bpb`, a training loss) with a serial hill-climb: mutate the current best, `git commit` on improvement, `git reset` on failure, loop forever until a human interrupts it. It has no LLM-as-judge step anywhere. The three-file contract and the LLM-judged scoring below are this kit's own extension, not something the Karpathy repo demonstrates. Full comparison and adoption verdict: `docs/research/2026-07-31-karpathy-autoresearch-loop.md`.

This kit's own extension applies the same "search variants, keep the best" idea to targets that have no cheap numeric metric, so it swaps in an LLM-as-judge score, and it never runs unbounded (see "Loop boundaries" above, an unbounded outer loop is declined territory here regardless of source):

- **Command prompts**: a three-file contract (program.md = kit philosophy frozen, skill.md = command prompt modifiable, eval.py = LLM-as-judge scoring). Run N bounded iterations, keep the highest-scoring prompt variant. Applies to /review, /spec-validate, /think.
- **Hook patterns**: run anti-rationalization patterns against a corpus of Claude outputs and measure false positive and false negative rates.
- **Verifier accuracy**: optimize task-verifier's prompt once a corpus of verified tasks exists. Score equals the percent of real bugs caught (false negative rate) against the percent of correct code wrongly flagged (false positive rate). Target: under 5% false positive, under 20% false negative. Needs 30+ real verified tasks to build the corpus.

The bar for this: run it only when manual iteration has plateaued AND 10+ real session transcripts exist to evaluate against. Before that, manual iteration is faster. For the task-verifier specifically: collect 30+ real verification transcripts first. As of 2026-07-31, `docs/runs/` holds none, so this bar is not yet met.

### Version strategy

- **v1.0-v1.1**: Commands + hooks. Manual iteration on prompts. Sequential task dispatch.
- **v1.2** (current): Verification pipeline (task-verifier + fix-agent + retry loop). Bootstrapping router (/start). Path-scoped rules. Context-readiness v2 with command suggestions.
- **v2.x** (pending real usage data): Prompt-type hooks (anti-rationalization upgraded to Haiku evaluation). /qa command with browser testing. Agent Teams parallel execution. Plugin marketplace packaging.
- **v3.x**: Agent-type hooks for deep verification. Multi-runtime support (Codex, Gemini). AutoResearch-optimized prompts.

No timeline commitment. Version bumps happen when real usage exposes the limits of the current version, not on a calendar schedule.

---

## 6. North-star criteria (2026-06, amended 2026-07-25)

Direction, not an implementation commitment. N1-N3 set by the maintainer 2026-06-10 after the
SPEC-016 / proof-colocation arc exposed the pattern: the kit is excellent at routing CODE work and
silent about everything else. N4-N7 set by the maintainer 2026-07-25 (the workflow-assessment arc):
the standing DIRECTIONS every future feature, absorb, or solution must align with. Every proposal
that touches intake, loops, the backlog, quality, packaging, orchestration, or team surfaces MUST
state which criterion it serves; a proposal that serves none of them and none of §1's principles is
a NO-list candidate by default. When a proposal CONFLICTS with a criterion, that conflict is
surfaced to the maintainer, never silently absorbed.

**Maintainer meta-principles** (observed across the 2026-06/07 arcs; the recurring judgments behind
the criteria, use them to break ties):

- **Attention at two points.** The human spends attention defining "done" and judging the artifact;
  never watching the middle. (Feeds N5; the slop economics: shrink cost-of-discard, not mid-flight
  supervision.)
- **Evidence before claims.** Nothing is done on assertion; a check ran or it did not. (§1 "Verify
  before proceeding"; the verifier chain; proof-of-done.)
- **Plain files, plain words.** State lives in git-trackable files anyone can `cat`; names use
  vocabulary a new teammate already knows (glossary, ID-307/ID-391). A capability locked inside a
  runtime or a jargon term is a coupling seam.
- **Risk buys ceremony.** Process depth tracks blast radius, never uniformity; a heavy process on a
  small diff is a defect (lanes, ship-time de-escalation).
- **Propose, never dispose.** Machines propose with citations; a human promotes. No automated leg
  writes directly to a board or rewrites the framework.
- **Defer, don't own.** When the host runtime or an external tool does something well, the kit
  integrates rather than re-implements (agent-os v3 lesson; "Synthesize, don't originate").
- **Queue-and-route with receipts.** Nothing is handled inline into oblivion: every input lands in a
  queue with a routing rule, drains to a named durable home, and leaves a receipt.

### N1 — Every work type earns a right-sized loop

We believe a research task, an eval, a tool comparison, a test-design pass, and a cleanup sweep each
deserve a defined loop the same way coding work deserves a lane, sized to the work, not inflated to
the full ceremony and not collapsed into freestyle chat. Coexistence is explicit: chat stays chat;
the kit engages when a task is being executed. Each loop names its executing agent, either
preassigned (a named subagent or owning skill) or selected dynamically (a persona/profile chosen at
dispatch).

**What exists today:** `lib/classify/task-type-classify.sh` classifies twelve work types (six when this
criterion was set 2026-06-10; expanded the same day by SPEC-054/057) and maps each to a proof
artifact + owning skill + executor in `docs/verification/task-types.md`. Lanes give spec-feature
work five right-sized paths; the other eleven types carry their own loops (WORKFLOW `## Type loops`).

**The gap:** the five non-code types have proof SHAPES but no defined CYCLE: no entry -> phases ->
exit, no agent designation. In practice they run as unstructured chat, which is exactly the
"important work gets the full cycle, everything small runs shallow" failure the maintainer flagged.

**A conforming proposal looks like:** it extends the existing registry (loop + agent columns), reuses
existing commands/skills as loop bodies, and keeps "right-sized" honest, a research loop that feels
like ceremony for a research task is a rejection, not a win. **It would reject:** a new slash command
per type (registry rows, not surface area); "everything goes through the full lane" (that is the
opposite of right-sized).

### N2 — Work is pulled from a board, not pushed by an operator

We believe the backlog should behave like a kanban board: classified work parks there with an honest
status, and an agent can PULL the next queued item without the maintainer sitting at the keyboard
typing "go". Operator-driven chat keeps working; pull is an additional trigger, not a replacement.

**What exists today:** `_meta/BACKLOG.md` is the proto-kanban (ID-NNN rows, hand-noted statuses);
`/kit:assign` turns a named item into a routed goal; `lib/goal/goal-registry.sh` already guards
cross-session claims.

**The gap:** rows have no status state machine, there is no board view, and nothing can take "the
next queued item", every dispatch needs the human to name the item. Assignment is push-only.

**A conforming proposal looks like:** it makes the BACKLOG itself the board (states + mechanical
transitions + a render), wires pull into the existing assign/claim machinery, and stays
minimum-infra (no daemon, no web UI; autonomous triggering is a later, separately-argued step).
**It would reject:** a parallel task database beside the BACKLOG (two sources of truth); a scheduler
runtime (the "Shallow and wide" boundary already hands that to external engines).

### N3 — Quality is test-first, shaped per type, and proof-stored

We believe a work item's tests are designed BEFORE execution, in the dialect that fits its type:
BDD-style scenarios for features, metrics + hand-verified seeds for evals, claim-verification
matrices for research, inventory + rollback rehearsal for migrations/cleanups, and that every
quality-check execution lands as an immutable recorded run the proof gate can see. The depth of the
test design tracks the weight of the task, not a one-size template.

**What exists today:** the deepest-built criterion: `docs/verification/test-design-standard.md` (the
spine), `/kit:test-plan` + `/kit:test-plan-review-team` (authoring + adversarial critique), the
verification framework (test-design + immutable `runs/`), and the proof-of-done ship-gate.

**The gap:** test-plan is opt-in, so most work skips design-first; and the standard speaks one
dialect (feature-shaped), so non-code types have no fitting way to design their checks even when
they want to.

**A conforming proposal looks like:** it specializes the ONE standard per type (dialects, not forked
documents), reads the type to pick the dialect automatically, and flips test-first from opt-in to
default-suggested where a behavioral/stateful proof is owed, advisory, never a hard block ("Detect,
don't dictate"). **It would reject:** a second test standard; a blocking test-first gate (the
ship-gate already owns blocking).

### N4, Modularity: every part stands alone, composes, and is swappable

We believe each capability is a standalone tool a developer or contributor can adopt, improve, and
replace with ZERO kit present, and that co-installed tools compose INTO the framework through the
manifest. Because the technologies and techniques keep evolving, every module must be individually
contributable and individually replaceable without surgery on the rest; the framework is what the
modules become together, not a container they live inside.

**What exists today:** the kit-modularity arc (ID-277): standalone `<subsystem> <verb>` commands,
layered install, `kit.toml [modules]` as an install record, plain-file artifacts (ledger, board,
specs); §1 "Toolbox, not appliance" states the internal half of this belief.

**The gap:** modules are separable INSIDE the kit but not yet extractable OUTSIDE it, the
delete-the-kit test fails; no generated per-host adapters; visual proof and test-design live as
external or embedded capability rather than standalone tools (ID-395/ID-396).

**A conforming proposal looks like:** plain-files-first core + one script that works with the kit
deleted + ONE generated per-host adapter + a manifest entry declaring what it EXPOSES
(`docs/research/2026-07-25-packaging-prior-art-refresh.md`). Acceptance test: delete the kit, every
tool still works; delete a tool, the kit is missing one capability, never broken. **It would
reject:** a capability that only exists inside the plugin; a module whose file format only makes
sense with the orchestrator running (the BMAD-pack shape); hand-maintained per-harness copies.

### N5, Autonomy: long-running multi-agent orchestration, hands-off in the middle

We believe the kit's first operating mode is the maintainer running multiple agents and subagents
over long horizons, mostly hands-off: attention spent defining "done" up front and judging artifacts
at the end, with the middle unattended. Human involvement mid-run is an exception triggered by
decision TYPE (architecture, risk, privacy), never a per-stage checkpoint.

**What exists today:** the /goal loop, the mega wavefront (ADR-0030), the overnight queue launcher,
worker -> verifier -> fix-agent with bounded retries, grounded completion, the watchdog, ship-only
enforcement (ADR-0024).

**The gap:** no fan-in/fan-out ordering graph yet (ID-394); failure semantics for mid-graph nodes
unnamed (prune-descendants is undocumented industry-wide, the kit can be first); runs still
occasionally end on questions the loop could have answered.

**A conforming proposal looks like:** it extends the ready-queue/verifier machinery, keeps every
mid-run gate advisory-and-recorded, and names its failure policy explicitly. **It would reject:** a
feature that requires the operator mid-run (per-stage approval gates); an unbounded loop with no
telemetry or termination contract.

### N6, Self-improvement: the kit learns from its own runs

We believe the kit improves itself through its own stage loop (Shape -> Build -> Watch -> Check ->
Learn): every run emits measurable signals across its surfaces and artifacts, the Learn stage turns
them into cited proposals, and "propose, never dispose" keeps a human at the promote step. The
mid-term goal: the framework gets better because it ran, not because someone remembered to improve
it.

**What exists today:** gate-ledger + lane-telemetry + stats projections; `learn propose` -> staging
-> `board promote`; `caught=bool` + override-rate per gate; delivery-ratio; kit-health;
learn-propose precision tracking (ID-294/ID-305).

**The gap:** the learning loop has one precision data point (calibrating, not yet trusted);
review-economics unmeasured (ID-392); context freshness is pull-based with no owner (ID-100).

**A conforming proposal looks like:** it adds or consumes a measurable signal, feeds the Learn
stage's staging file, and is itself measured (the meta-loop). **It would reject:** self-rewriting
automation that bypasses staging; an unmeasured "smart" feature (the ruflo trap: capability claims
with no observable signal).

### N7, Serve the team: carry the cognitive load for humans + agents together

We believe the kit's end purpose is cognitive off-load for a TEAM: the maintainer plus multiple
humans plus agents coordinating on shared surfaces, nobody needing to hold the process, the state,
or the judgment scaffolding in their head. A solo power tool is the starting point, not the goal;
every feature should be weighed for how it lands when a second and fifth person arrive.

**What exists today:** team-mode as a named parked slot (§1) with a concrete tripwire; the board
sync spokes + the Multica pilot (board delegation to agent teammates); the plain-words glossary
(ID-293) and rename queue (ID-307); the human onboarding + card-template work (dfoundation
DF-151/152).

**The gap:** single-operator assumptions in the goal registry and conflict rules (ADR-0022,
git-wins); pickup cost rated the weakest team dimension (2/5, 2026-07-24 assessment); no
review-economics data to know whether delegation actually holds at team scale.

**A conforming proposal looks like:** it lowers pickup cost (plain words, a 2-page front door),
works unchanged for a second named user, and keeps human judgment as the last gate. **It would
reject:** a surface only the maintainer can operate; jargon-first naming; a feature that scales
agent output without scaling review capacity (the unbudgeted-reviewer trap).

### How the criteria compound

N1-N3 are one system: board rows (N2) carry the type, the type picks the loop (N1), the loop's
first phase designs the tests whose runs become proofs (N3). N4-N7 are the direction that system
grows toward: N4 makes every part contributable and swappable, N5 runs the parts unattended at
scale, N6 makes the running improve the parts, and N7 is why any of it exists, a team thinking
together with less cognitive load. A proposal advancing one criterion should say what it assumes
about the others; a proposal that advances one by breaking another (e.g. a pull mechanism (N2)
that dispatches work with no test design (N3)) is not conforming.
