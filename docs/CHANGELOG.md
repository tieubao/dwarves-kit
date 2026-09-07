# Changelog

All notable changes to dwarves-kit are documented here.

## [Unreleased]

## [2.2.0] - 2026-09-07

### COMPAT (contract surfaces, per forge kit-versioning.md)
- Ledger grammar: unchanged. lanes.d plan format: unchanged. Export `schema`: unchanged (1).
- Seam keys (new surface, additive, MINOR): `[knowledge] root`, `[wrap] before`, `[wrap] activity_log`, `[precedent] registry`, `PROSE_RAG_BIN`; every default keeps the kit working with nothing filled. `bin/config seams [--check]` reports them.
- `prose_rag` module: the vendored crate is gone; recall now needs context-kit's `prose-rag` binary on PATH or `PROSE_RAG_BIN`. With neither, the hook stays silent and `index` skips; only an explicit query errors with the install hint.
- Overlay floors: unchanged (learning-kit and context-kit declare `>= 2.0`; both keep passing their contract tests against this cut).

- prose-rag: the module is an ADAPTER (SPEC-250). `bin/prose-rag` resolves `$PROSE_RAG_BIN` (a regular executable file) then `prose-rag` on PATH, the order `config seams` already reports for that row, and execs it; the vendored Rust crate under `lib/prose-rag/rust` is deleted, because context-kit owns the engine (`cargo install --path src/prose-rag`) and two builds of one engine drift. The three no-engine exits are unchanged: `hook` exits 0, an unconfigured `index` exits 0, any other verb prints an install hint naming context-kit's crate and exits 1. New `tests/test-prose-rag-adapter.sh`.
- config: named cross-kit seams (SPEC-249). A `[knowledge] root` key (operator or kit-root only; empty means repo-local `.claude/memory`) tells the engine where the context tree lives; a `## Seams` join table in `lib/config/module-registry.md` tags each seam with a kind and the overlay that fills it; `bin/config seams [--check]` reports every seam as `default|filled|unresolved|absent` without executing a target, fenced the way the consumers fence (realpath under HOME, no symlink, no relative path), and `--check` gives an installer a one-bit exit. `_env_val` guards every indirect env expansion in `config.sh` against a forged registry name.
- wrap: Step 7 `learn` owns the process half of session distill (SPEC-249): the DEBT marker via `significance-classify.sh record`, new-tool candidates through `precedent find --json` into the staging buffer, and one memory note per own-mistake incident under `bin/wrap knowledge-root`. New verbs `wrap knowledge-root <repo>` (fenced root, repo-local fallback) and `wrap stage` (paths and fences in bash, the write in `staging-format.py stage`, which dedupes over staging and board with a Unicode-aware key). Every wrap writer resolves the post-worktree-copy path before fencing it. `commands/onboard.md` and `commands/adopt.md` name the overlays and their seams.
- sync: new `--filter <app>:intake_skip_re=<regex>` keeps a foreign app item on the app whatever `intake` says (body regex, MULTILINE). An adopted item with no in-scope tag scope-exits on the next tick and closes on the app, which is right for junk tickets and wrong for one that has its own lifecycle there: a member-facing support ticket carries a `thread:` line, and archiving it made the support desk tell the member their ticket was solved. `intake_ok` checks the skip first; a bad regex fails the parse.
- wrap: step 5 removes the session's own `EnterWorktree` worktree once `wrap scan` proves its branch squash-merged and the tree is clean (`ExitWorktree remove` with `discard_changes: true`, then `git branch -D`); the old rule kept it and asked, which left a finished worktree behind on every wrap. Keep now applies only to a dirty, unproven, or `gh`-less worktree, named in `Left alone`.
- config: an operator-owned `kit.toml` now sits between the project `.kit.toml` and the kit-root `kit.toml` (SPEC-248). `kit_config_operator()` resolves `${KIT_CONFIG_OPERATOR:-${XDG_CONFIG_HOME:-$HOME/.config}/dwarves-kit}/kit.toml`; `kit_config_get` reads project > operator > kit-root > default and `kit_config_get_root` reads operator > kit-root > default, because the operator file lives on the operator's machine and never rides inside a pull request. Per-operator paths such as `wrap.activity_log` and `precedent.registry` now survive a kit upgrade instead of living in the kit checkout. New `[wrap] before` consumer key names a skill `/kit:wrap` invokes before step 0, whose report lines fold in after the report's `FYI` line; `/kit:wrap` also gained its trigger phrases.
- wrap: new `/kit:wrap`, the session-scoped landing step after ship (SPEC-246). `lib/wrap/wrap.sh` + `bin/wrap` ship five verbs (`scan`, `apply`, `merge`, `log`, `default-branch`), porting the operator's `repo-wrapup` scripts and `session-closeout` Phase 2 into the kit: board rows flip, the operator's own green PRs merge one at a time under gates (base is the default branch, mergeable, checks green, no unresolved threads, no open dependents per SPEC-065), a `workflow_dispatch` deploy gets a `headSha` check, branches and worktrees tidy under proof (an ancestor deletes with `-d`, a squash-merge proof deletes with `-D`, nothing forced), the default branch pulls `--ff-only`, and an activity line prepends through the new `[wrap] activity_log` consumer key. `/kit:wrap` is the only caller of `/kit:retro` off a ship-ledger fact. `commands/start.md` and `commands/retro.md` name it.
- precedent: `bin/precedent find` now answers "done before?" over two corpora. The records surface (specs, ADRs, retros, verification, run ledger) is unchanged and byte-parity pinned; the new inventory surface scans what has been BUILT (tools, scripts, bin, cli, `_meta` wrappers, experiments, memory notes, skills, feature registries, the kit's own verbs, `~/.claude/skills`, `~/.local/bin`, launchd plists, wrangler crons) with AND scoring, secret redaction, a 240-char cap, and a DATA marker. Sources beyond the repo and the kit come from a consumer registry (`repo | scripts | skills | crons | memory` rows; `--registry` > `PRECEDENT_REGISTRY` > `kit.toml [precedent] registry` > the XDG default). `--explain <label>` prints a hit's header, confined to the scanned roots. `lib/precedent.sh` (root orphan) is gone; `/kit:assign` and `/kit:grill` call `bin/precedent find`. Ported from ops-toolkit's `repo-sweep whathas` (SPEC-245).
- docs: onboarding golden-path pass (ID-400). README leads with the two-command plugin install +
  `/kit:onboard` + `/kit:start`, module list stays below the fold; new `docs/QUICKSTART.md`; the
  bash installer is relabeled a maintainer/power path; a "disclose gaps, don't hide them" principle
  in `docs/PHILOSOPHY.md` generalizes `/kit:onboard` section E's honest-disclosure convention.
- agents: new devops-triage subagent, on-demand production error-alert triage (evidence-first, read-only, bounded verdict); ambient twin lives in ops-toolkit tools/alert-triage/

### Fixed
- **Queue launcher pre-flights the `/goal` 4000-char cap.** Interactive `/goal` refuses
  anything over 4000 chars, but the launcher never checked before typing, so an over-budget
  pointer opened a real window, typed a silently-rejected goal, and sat idle forever with no
  journal entry. `QUEUE_GOAL_CHAR_LIMIT` (default 4000) is now checked before any window
  opens; an over-budget pointer fails fast to journal `error` with the reason named.
- **`test-queue.bats` sandboxes its ledger root; NC2/NC6/NC7 un-failed.** The suite sandboxed
  the journal but not the run files, so guard counters leaked into the operator's real
  `~/.local/state` and accumulated across local runs until the SPEC-221 breaker trip rewrote
  the NCs' expected `stalled` into `error stagnation_detected`, machine-local, invisible on
  fresh checkouts. `KIT_LEDGER_DIR` now points at the per-test sandbox, a T13 tripwire pins
  the resolver, and the leaked files were cleaned. The ID-463 class, state-dir edition.
- **Queue launcher no longer strands a row on a dropped Enter (SPEC-217).** `_mux_submit`'s
  still-pending check matched the literal `/goal` at the prompt, but a long typed goal
  renders tail-first in the input box, so the string never appears there. A dropped Enter
  read as submitted and the row sat idle with no journal entry, reproduced on 3 consecutive
  live `#auto` runs, each needing a manual Enter to unstick. Detection is now "any prompt
  line still carries content", errs toward re-Entering rather than toward a false submit.
- **`tests/test-meta.sh` no longer rewrites the tree it runs in.** `feature-registry.sh`'s
  `generate()` unconditionally called `sync_counts()`, so the freshness check, which
  regenerates to a throwaway temp path purely to diff, silently rewrote `README.md` and
  `docs/architecture.md` on every run, masking the exact drift it had just flagged.
  `sync_counts` now fires only when `generate` writes the real file in place. Also fixes the
  drift itself: `/kit:gauntlet` was missing from README's command table and
  `docs/architecture.md`'s V-phase inventory; a pristine run is now 809/809 and leaves the
  tree byte-identical (checksummed before/after, plus an independent negative control).

### Added
- **Auto review-fix loop on the full lane (SPEC-231).** The multi-lens review now runs by
  default, not on request: `/kit:execute` drives `/kit:review-team` (the three specialist
  lenses plus the kit-default advisor, in one pass) after build on the full lane, and the
  spec stage runs a default design-time critique plus advisor over-suggest before validate.
  Findings sort convergent-first (a defect two or more lenses agree on outranks single-lens
  taste), and the review re-runs over each fix batch up to two rounds, because a fix batch
  can reopen the bug it fixed. The verdict stays advisory (auto-run, not auto-block), and a
  lane gate keeps the cost on the full lane only. Foundation: `docs/patterns/review-fix-loop.md`.
- **`slop-stripper` agent: the behavior-preserving AI-slop strip pass (kit ID-402).** Resolves the
  deslop absorption contradiction (2026-06-11 pinned-kits called it a duplicate of the simplify +
  maintainability-lens surfaces; the 2026-07-25 absorption survey scored it ABSORB). Both were
  right about different halves: the DETECT half (the 5-item checklist) duplicates the review lenses
  and the slop-cleaner hook, but the FIX half, an edit-capable, behavior-preserving strip pass that
  applies surgical edits before merge, had no home in the kit. Every existing surface is
  detect-only by design (review lenses are read-only, ADR-0005; slop-cleaner nudges and never
  auto-fixes; fix-agent only fires on verifier FAIL:fixable and its anti-patterns forbid
  "improving" unflagged code). The new agent re-implements the deslop mechanism from az-skills
  (no license; original prose, source cited) and lands as an OPT-IN step on `/kit:review-team`'s
  decision gate: the operator's judgment is the gate, then `/kit:verify` before `/kit:ship`.
- **Test-plan coverage advisory at the ship boundary (ID-466).** The test plan fed
  `/kit:execute`'s verify steps but nothing at the gate traced the proof back to the matrix.
  New `proof-gate.sh coverage <spec> [proof.md ...]` subcommand parses both matrix dialects
  (numbered `#` column and the older category form, ordinal fallback) and reports
  `OK` / `NO-MAP` / `UNMAPPED: <rows>`; the ship-gate emits a warn-only `[advisory]` when a
  spec with a `## Test plan` has no `## Test plan coverage` map in its proof doc, or the map
  leaves rows unmapped. Detect-not-dictate: never blocks, and a spec without a test plan owes
  nothing new. Owed shape documented in `docs/verification/README.md`. Third live `#auto`
  queue-watcher run, filed and shipped the same day (PR #366).

### Fixed
- **Board-sync id-collision guard (ID-309).** `plan_sync`'s title-prefix link step trusted a
  matching id alone as proof of identity; a repaired board row whose id had been reused by a
  spoke-born item (minted while the row was invisible to `parse_board`) could get silently
  overwritten, retitled, and flipped to a wrong status by the unrelated spoke item. The link
  step now refuses to adopt a spoke item whose title disagrees with the board row's, emitting
  a collision note naming both titles instead. `next_id` already scanned raw board text (not
  parsed rows) so it needed no change. Second live run of the SPEC-217 `#auto` queue watcher,
  unattended end to end, PR #344.

### Added
- **`docs/impl-playbook/` ships in the kit itself, review-team agents cite it by stable path.**
  security-reviewer, code-reviewer (architecture + test-coverage lenses), infra-reviewer,
  frontend-reviewer, and test-writer now cite `~/.claude/dwarves-kit/docs/impl-playbook/<file>.md`
  at the checklist item each rule backs (OWASP/ASVS for security, Fowler's pyramid for test
  layering, coding-hygiene for the architecture lens, Cloudflare specifics for infra). The
  content used to be the maintainer's personal, machine-local reference; moved into the repo
  and generalized so every adopter's citations resolve, not just the maintainer's own machine.
  `install.sh` deploys the directory to the stable install path on both the full-install and
  plugin-compat paths, with a matching `--uninstall` removal step.

### Fixed
- **`tests/test-install-compat.sh` now sandboxes `$HOME` (ID-463).** The suite ran `install.sh`
  with only `CLAUDE_DIR` overridden; the compat branch it exercises writes a CLI shim straight
  to `$HOME/.local/bin` for every known module, so on 2026-08-01 a real run clobbered 4 live
  shims (`board`, `prose-rag`, `session`, `worktree-provision`), retargeting them at a `mktemp`
  dir that vanished on test exit and broke a live hook. Both `install.sh` invocations in the
  suite now get their own throwaway `HOME`, plus a tripwire assertion that fails if any
  dwarves-kit-managed shim in the real `~/.local/bin` ever points back into the test's own
  `$TMPDIR`. First unattended, end-to-end run of the SPEC-217 `#auto` queue watcher: self-grill,
  sanitized prompt, runaway guards, and the draft-PR-by-default posture all fired for real,
  producing draft PR #342.

### Added
- **`backlog-reconcile` skill: the audit-loop pattern's 4th SDLC instance (SPEC-225).**
  General-purpose (every `/kit:adopt`ed repo, not maintainer-only): audits a repo's
  `_meta/BACKLOG.md` Active queue against reality, a row's `Status` verdicted against its
  `Target artifact` spec's own `Status:` header, or a git-log match for `(tiny, no spec)`
  rows, and ships fixes via PR. Mirrors `topology-drift`'s Tier1-mechanical/Tier2-model-delta
  shape, reuses `lib/board/backlog.sh` and `agents/audit-scanner.md` unchanged.
- **Two cheap guardrails on the autonomous run queue (SPEC-224 / ID-461).** Both ride channels
  SPEC-221 already built, so the diff is small and adds no process. (1) DRAFT-PR-BY-DEFAULT on the
  unattended path: the queue never runs `gh` itself, so `_goal_line` appends a clause to the typed
  `/goal` line telling the launched run to open its PR as a draft (`gh pr create --draft`) and stamp
  a provenance footer naming the run (`[unattended orchestrator run; journal <path>; slug <s>]`),
  mirroring OpenHands' model-overridable `draft=True`. `queue run --ready` (or `QUEUE_PR_READY=1`)
  is the escape hatch that opens a normal PR. Interactive `/kit:ship` never calls `_goal_line`, so
  it is untouched. (2) A per-row and queue-wide SPEND CEILING on a self-reported tool-call count: the
  run writes `TOOL_CALLS: <n>` into its SPEC-221 `<slug>.status` file, and the conductor reads it on
  the poll it already does. `QUEUE_MAX_TOOL_CALLS` stops a row (verdict `stalled`, the shared journal
  reason set to a new value `spend_ceiling`) after its observed turn; `QUEUE_MAX_TOTAL_TOOL_CALLS`
  aborts the remaining rows after the current one ships (SWE-agent's two-tier split). Both default 0
  (disabled, matching SWE-agent's `per_instance_call_limit=0`), so the shipped overnight behavior is
  byte-identical until an operator opts in. The ceiling is composed OR-style with the wall-clock
  `QUEUE_TIMEOUT_SECS` (first-to-trip wins); self-report is a guardrail, and the wall-clock is the
  non-gameable backstop. Claim-leases (the row's third idea) were scoped out: SPEC-221's beat-file
  presence already IS the in-flight claim (DEC-003) and its reaper is the lazy expiry.
- **An untrusted-input pass on the autonomous run queue (SPEC-223 / ID-459).** The `#auto` path
  types a pointer file's body into a `--dangerously-skip-permissions` session, and the board row is
  what selects that file, so on the watcher-planned path that body is untrusted text rather than an
  operator-authored prompt. `lib/queue/sanitize.sh` adds `sanitize_cell`, an ORDERED pipeline where
  each step closes a bypass the previous one leaves open: HTML-entity decode (single and double
  encoded), an invisible-codepoint strip by Unicode PROPERTY (`\p{Cf}` plus
  `\p{Default_Ignorable_Code_Point}`, never an enumerated list), ANSI strip, control strip (a
  newline would submit the prompt early, so removing it is a security property here), HTML-comment
  DELETION, code-fence stripping (gh-aw exempts fences to protect patches; a goal prompt has no
  patch, so the exemption is inverted and nothing is exempt), pipe escaping (a board row is a
  markdown table), an https-only URL allow-list with a percent-decode preamble, and a size cap that
  truncates with a VISIBLE marker instead of rejecting. The typed prompt is then framed by an
  untrusted-content preamble and fenced with explicit begin/end markers. `queue.sh run` gains
  `--sanitize-prompt` (implied by `--from-boards`); `watch-board.sh --apply` forwards it. A
  hand-authored tsv is unchanged, because operator authorship is the trust boundary the pointer
  allow-list already uses. A run that writes a protected path (`.claude/*`, `CLAUDE.md`,
  `AGENTS.md`, `.github/*`, `_meta/BACKLOG.md`, tunable via `QUEUE_PROTECTED_GLOBS`) ends `gated`
  instead of shipping: DETECTION, not prevention, since nothing in bash sits between a
  skip-permissions session and the filesystem. A host without the sanitizer skips the row with a
  named reason and opens no window. Proof: `docs/verification/notes-sanitization.md` (52 assertions,
  a negative control per section, three live revert-to-RED probes, and a security round whose
  Critical finding, an enumerated invisible-character list broken by U+034F, is fixed and now
  regression-tested). Deferred with a tripwire: gh-aw's read-only-agent plus safe-outputs plus
  model-judge separation, which becomes real work the day a second person can edit a watched board
  or the loop ingests text the operator did not author.
- **Runaway guards on the autonomous run queue (SPEC-221 / ID-460).** Three mechanisms, all
  hanging off per-slug sidecar files under `<log-dir>/queue-runs/`, and none of them a daemon:
  the reaper runs on the `queue watch` tick the operator already invokes. (1) A stale-window
  watchdog: the conductor touches a heartbeat every poll, a beat older than 10 minutes reports
  an orphan and refuses to plan the slug, and one older than 60 minutes writes a verdict
  (honoring the run's own `EXIT_SIGNAL` if it finished), increments the stall counter, and
  schedules a jittered 5-15 minute retry; the third stall writes an empty `retry_after`, which
  is the quarantine. This closes the case where a dead conductor process left NO journal row and
  the row was re-planned forever. (2) A circuit breaker: consecutive no-progress and repeated-error
  counters trip to `error` reason `stagnation_detected` with a 30-minute cooldown, with four
  escape hatches (repo moved, self-reported files changed, an explicit completion, and a run that
  stopped to ASK freezes the counters rather than counting as stagnation). (3) A dual-condition
  exit gate: a run may write an explicit `EXIT_SIGNAL: true|false`, which always outranks pane
  prose; `false` keeps the run going even against a `RUNNER_DONE` pane, and a present-but-malformed
  signal is never a completion. With no status file, completion detection is byte-identical to
  before. Also: `_slug_ok` now rejects `/` (the slug names a sidecar file), and the progress check
  no longer lets `git -C ""` silently read the operator's current directory.
- **Self-answer mode + the backlog watcher, the orchestrator-loop pilot (SPEC-217 / ID-457).**
  `/kit:grill` gains an explicit self-answer mode for autonomous runs: it activates only when
  the driving row carries the operator-set `#auto` tag, and every self-answered question lands
  as a debt-ledger row (question, answer, why) that `learn debt collect` surfaces at paydown;
  the rule is "never decide invisibly", interactive lanes untouched. `queue watch`
  (`lib/queue/watch-board.sh`) is a filter in front of `queue run`: it plans `queued` rows
  tagged `#auto` that pass the pointer allow-list plus a symlink-aware containment pass, dedups
  against the queue journal (`done`/`gated` are terminal), dry-run by default, budget cap
  forwarded to the queue. Side fix: `_pointer_allowlist_reason` no longer glob-expands its
  pattern loop against the cwd, which had broken legitimate `--from-boards` pointers when run
  from the repo root.
- **Spec template gains `## Picture`, the pre-build twin of visual proof (SPEC-214 / ID-454).**
  A spec's `## Picture` section (ASCII/box-drawing diagram of the pieces + arrows, never
  mermaid) sits between `## Solution` and `## Design`, required non-empty on full-lane specs,
  encouraged elsewhere. A UI-shaped spec points it at a `/kit:prototype` branch + variant
  instead of drawing ASCII. `/kit:spec-validate` Reviewer 4 (Scope Critic) gains a mechanical
  presence check (full-lane only) plus a lens question: does the picture agree with
  `## Task Breakdown`. Both bullets are advisory; Reviewer 6 stays the only reviewer that can
  refuse `VALIDATED`. Proven the same way SPEC-122's `## Design` check is proven, a
  fixture-based structural test (`tests/test-picture-section.sh`) since the reviewer itself is
  prompt text, not code.
- **`GUIDE.md`, the end-user owner's manual (SPEC-216 / ID-456).** `docs/GUIDE.template.md`
  is a fill-in skeleton (what this does / how to use it / what to do when it breaks, one
  page, ELI10 register) for products with an end user who is not the builder. `/kit:ship`
  gains a warn-not-block check applying that same "has an end user" test; `/kit:docs`'s
  scan step keeps `GUIDE.md` in scope on doc-drift passes. No renderer, no new command;
  libraries and infra are exempt by the same test.
- **`/kit:wayfind`: the file-based decision map (SPEC-207 / ID-450).** User-invoked
  pre-cycle intake shape for efforts too foggy for one session, ported from
  mattpocock/skills wayfinder (MIT) onto files + the board: `_meta/megagoals/<slug>/map.md`
  (Destination / Decisions-so-far gists / fog / out-of-scope) + typed decision tickets
  (`research|prototype|grilling|task`) routing to the kit's own machinery; claim-by-header,
  frontier = open unblocked unclaimed, one ticket per session (research fan-out excepted),
  the agent never answers its own grill questions. Map clear hands off to `/kit:spec` or a
  ROADMAP.md beside the map, never straight to execute. One umbrella board row per map.
  Tracker-native storage stays parked (2026-07-25 tripwire unchanged). WORKFLOW.md gains
  the wayfind intake paragraph + SPEC-206's Prototype phase-table row.
- **`/kit:prototype`: the throwaway-spike beat (SPEC-206 / ID-448).** Opt-in beat beside
  `/kit:design`, ported from mattpocock/skills prototype (MIT). The question decides the
  shape: logic branch (pure portable module driven by a full-frame TUI) or UI branch (3-5
  structurally different variants on one route via `?variant=`, prod-gated floating
  switcher). Validated decision folds into the owning brief/spec; the prototype survives
  as a primary source on a `prototype/<name>` branch, never in master. HITL by contract.
  Executor for wayfind prototype tickets (ID-450).
- **Fowler smell baseline + review-team dispatch safeguards (SPEC-205 / ID-449).** The
  architecture lens (`agents/code-reviewer.md`) and solo `/kit:review` carry Fowler's
  12-smell baseline (Refactoring ch.3, via mattpocock/skills code-review, MIT) with
  three binding rules: repo standard overrides, every smell a labelled judgement call,
  skip what tooling enforces. `/kit:review-team` fails fast (`git rev-parse` + non-empty
  diff) BEFORE dispatching subagents, and its report summary states totals + worst issue
  PER LENS, never a single cross-lens winner (the SPEC-081 merge machinery is unchanged).
- **Multi-vendor sub-goal dispatch (ID-390).** A mega-goal sub-goal can declare
  `Harness: codex` (or `pi` / `opencode`) in its goal file to run on a non-Claude
  CLI, billing that vendor's quota instead of the Claude one while Claude stays the
  coordinator. New `lib/queue/harness.sh` resolves a vendor to its headless argv +
  prompt-delivery mode (facts read off each installed CLI, not a copied table);
  `orchestrate.sh` wires it via `_harness_of` / `_run_one_session_vendor`. Drives
  each vendor's real non-interactive mode (`codex exec`, `pi --print`,
  `opencode run`), so the exit code is real, unlike the prior-art TUI-puppeting
  approach (AI-Builder-Club `open-agent-teams`) it was evaluated against. **Opt-in,
  OFF by default:** gated by `[mega].enabled_agent_clis`, read from the KIT-ROOT
  install kit.toml ONLY (never a project `.kit.toml`, which rides inside an untrusted
  PR and could self-enable a vendor). Grounded completion is unchanged and
  vendor-independent: a vendor sub-goal advances only when it flips its ROADMAP box.
  Fail-closed: an unknown or not-enabled harness is a pre-flight STOP, never a silent
  claude fallback; `Effort:` is charset-validated so it cannot inject argv flags or
  break out of codex's TOML config; an argv-mode prompt is newline-guarded so a
  leading `-` is never parsed as a flag. Non-claude sub-goals run the plain path only
  (no token accounting / stream tail / stall watchdog; WARNed, not silent). Also
  admits the `fable` tier, which a stale allowlist had been rejecting pre-flight.
  Design + proof: `docs/verification/harness-adapter.md`; review-round hardening
  (1 CRITICAL + 4 HIGH) in `docs/implementation-notes/multi-vendor-dispatch.md`.
- **`skills/memory-tidy`, the judgment half of the memory plane.** Pairs with the
  read-only `stats memory-sweep` scanner (SPEC-136): evidence-required per-note
  verdicts (KEEP / MERGE / STALE / UNSURE) via agent fan-out, danger check for
  notes whose advice contradicts current policy, index rebuild with parity
  checks, all confined to a worktree branch and shipped as a PR (the operator's
  approval gate). Consumer cadence toggle `[features].memory_tidy` in `kit.toml`
  (`[consumer]`, default off); the scheduled runner lives consumer-side
  (ops-toolkit `tools/memory-tidy/`). CONTRIBUTING gains an "Introducing a
  component" convention (naming, description discipline, registration,
  evidence) so new skills/commands/agents never land as unregistered file
  drops. First production run: tieubao/ops-toolkit#972.
- **`sync` one-way insert-only push to a foreign team board** (`notion-taskboard`
  app, SPEC-003, implements ops-toolkit ID-138). Pushes a repo's board rows out
  to a team-OWNED Notion board (create page, never update, never read for merge,
  board file never written); fields are set only on page-create so team edits are
  never overwritten, and the local sync-state map is the identity index. Status/
  Priority/Weight map to the team board's own option names via `.kit.toml [sync]`
  config, so the team schema is never mutated. The two-way mesh and its four live
  adapters are untouched (`create_only` is a separate path, and the two-way
  board parser stays `ID-`-only; only the one-way READ path accepts any
  `[A-Z]+-\d+` prefix, e.g. dfoundation `DF-NN`, and it never mints or writes
  board ids). The sink validates every mapped option against the target's
  schema before any create, so it never auto-creates an option on the team
  board; state is checkpointed after each create so a mid-batch failure never
  re-pushes a page.

### Changed
- **`bridge` module folded into `sync`** (zero live consumers at fold time: no
  `bridge=on` rows, no snapshot, module off). Legacy `mirror`/`status`/`writeback`
  verbs stay runnable with a deprecation note until the SPEC-002 P2 port (ID-290),
  which must carry the `row_hash` git-wins conflict rule and the live-probed Hermes
  reachable-state map.
- **`board promote` write path hardened** (kit ID-288): flock single-writer lock
  (stable-inode lockfile in tmpdir), read-after-lock, 4-cell row validation, atomic
  replace. Closes the parallel-session duplicate-ID and malformed-row minting that hit
  the ops-toolkit board on 2026-07-16.

### Added
- **`sync.mode = cron`: scheduled `board sync` (kit ID-289).** Wires the
  `[sync] mode` key (previously `[reserved]`) to a real per-repo macOS
  LaunchAgent: `lib/sync/deploy/macos/install` refuses to render or load
  anything unless the target repo's own `.kit.toml` sets `mode = "cron"`
  (any other value is a clean, named refusal); the installed launcher also
  re-checks `mode` live on every scheduled run and skips cleanly once a repo
  un-opts-in. New `sync.interval_secs` key (default 3600) sets cadence. One
  LaunchAgent per adopted repo (not a kit-weekly job -- sync is per-repo by
  nature). Tests: `tests/test-sync-cron-install.sh` +
  `tests/test-sync-cron-launcher.sh`.
- **`sync` module: two-way board↔apps sync (SPEC-001/SPEC-002 P1).** The ops-toolkit
  backlog-sync engine graduates into the kit as registered module `sync` (stage: Shape,
  formerly leg Specify -- renamed by ID-292, see below)
  at `lib/sync/`: `board sync` mirrors an adopted repo's BACKLOG.md to Apple Reminders /
  Notion / Hermes kanban / Multica with per-app three-way merge (board wins; app
  deletions tombstone; inbox intake with `#inbox` quarantine). Config on the ADR-0034
  layer: `.kit.toml [sync]` (`apps`, per-app keys, audience filters `only_tags` /
  `skip_tags` / `intake`, `scope_exit_cap`), resolved in `cmd_sync` via the one TOML
  reader; the python engine takes flags only. Filtered rows freeze two-way and close on
  the app (scope-exit) with a cap + `--allow-scope-exit` override. Plain-words
  vocabulary: profile/app/board (was edge/surface+spoke/hub); legacy config aliases
  kept. Tests: `tests/test-sync.sh` (engine, fake transports) +
  `tests/test-sync-dispatch.sh` (both board conventions, legacy alias, error
  paths). Proof: `lib/sync/docs/proof-of-done.md`.
- **Plain words rule (CONTRIBUTING.md) + ranked jargon inventory**
  (`docs/research/2026-07-16-plain-words-inventory.md`); rename backlog: ID-291 (cheap
  cluster), ID-292 (shipped below), ID-293 (big cluster, parked).
- **The five legs renamed to Shape/Build/Watch/Check/Learn (ID-292).** `Specify`,
  `Execute`, `Observe`, `Govern` become `Shape`, `Build`, `Watch`, `Check` (`Learn`
  kept); the container word `leg` becomes `stage`. ADR-0034 amended per its own lock
  (decision 3's as-decided table left unrewritten); `lib/config/module-registry.md`
  carries the old names as a one-release parenthetical alias, README/architecture/
  data-flow/MANUAL/kit-contract/onboard docs and the registry-lint assertions in
  `tests/test-meta.sh` swept to the new vocabulary. Docs-first: no module or
  code-identifier renames.
- **Model-routing enforcement pinned + proven (SPEC-116).** Resolves `orchestrate-hardening`
  open-fork 3: the enforcement site is `lib/queue/orchestrate.sh` (`_route()` + the serial/wave delegate
  dispatch sites, which already existed under SPEC-087), not `lib/classify/route-suggest.sh` (a decompose-time
  suggester with no dispatch-time call site, so it structurally cannot contradict an explicit
  `Model:` field). The no-`Model:`-field fallback tier is confirmed as "inherit the parent session's
  tier" (SPEC-107). `tests/test-model-routing.sh` proves the default-applied positive case for
  opus/sonnet/haiku on the serial path plus one case on the concurrent wave path, and the fallback
  negative control. No `lib/` behavior change; this is a proof + documentation pin.

## [2.1.0] - 2026-09-06

### Added
- **Verifier tier parity (SPEC-244): a verifier is never dumber than its worker.** A spec carrying
  the bare `Model: opus` header now dispatches every verifier for that spec (task, recheck,
  integration, acceptance, system) with an explicit `model: opus` override, the review-team
  dispatch-time pattern. Absent the header, verifiers keep their frontmatter default.
  `recheck-verifier` pins `model: opus` unconditionally: it is the false-PASS backstop and runs
  once per verified task, so the volume is low. Reviewers, research agents, and `doc-verifier`
  stay as they are, stated as deliberate in the spec so nobody reverses it by accident.
  `commands/execute.md` loses the old "Verifiers keep their own frontmatter tiers (unchanged)"
  wall-off, and SPEC-107 gains a supersession note for the verifier half.

## [2.0.0] - 2026-07-03

The release hold lifts: its stated condition , the **kit-hardening** megagoal , is complete, and
the **kit-face** megagoal (production-facing + cost-measured) ships on top of it. The major bump is
driven by the three agent renames below (a breaking change for any repo that dispatches them by
name) and by tool.toml joining VERSION + plugin.json as a pinned version surface.

### BREAKING
- **Three agents renamed to the `<x>-reviewer` / `<x>-verifier` convention (ADR-0029).** A repo
  that dispatches these by `subagent_type` or scaffolds them in an invocation template must update:

  | old | new |
  |---|---|
  | `integration-checker` | `integration-verifier` |
  | `reviewer` | `code-reviewer` |
  | `security-auditor` | `security-reviewer` |

  A grep across the sibling consumer repos (`~/workspace/<owner>/*`) found the old names ONLY in
  historical research notes, `LAB_LOG`/`BACKLOG` entries, and the `plan-for-mega-goal`
  invocation-template , NO live `subagent_type:` dispatch wiring , but the template and any consumer
  that dispatches by these names should update.

### Added , kit-face megagoal (each sub-goal = one merged PR; #128-136)
- **Cheap-first tier default, one stance across three surfaces (SPEC-107, #128).** `/kit:execute`
  workers dispatch `sonnet` by default with an optional bare `Model:` header on the spec as the
  hard-reasoning escape hatch; `meta-agent` Mode B writes `Model: sonnet` on abstain (reversing the
  earlier "human's call"); the `plan-for-mega-goal` subgoal-template defaults `Model: sonnet`. Opus
  is now the deliberate exception, not the silent default (SPEC-087's "Opus only on the hard
  sub-goals").
- **Meta-agent provenance + a runtime efficacy metric (SPEC-108, #129).** Generated agents carry a
  `generated-by: draft-agent <date> <context>` frontmatter key (backfilled on the 5
  kit-hardening-generated agents; `/kit:draft-agent` stamps it going forward). SPEC-073 gains metric
  11, generated-agent catch count: SPEC-088 validates the definition at install, metric 11 validates
  the deployment at runtime.
- **Capture-gated token accounting + efficiency metrics (SPEC-110, #132).** A new `gate-ledger.sh
  tokens` subcommand records a `| TOKENS |` ledger line (an additive, gate-invisible marker);
  `handoff_gen.py sum-usage` extracts per-session usage from the stream-json capture; `lane-telemetry
  report` grows a token section (median tokens-to-done per lane, cache efficiency, run-granularity
  rework share) and `render --mermaid` annotates each lane with its median. Capture-gated: only
  `--stream` / `DETERMINISTIC_HANDOFF` runs record TOKENS; the default `claude -p` invocation is
  byte-unchanged (SPEC-087 pin) and honest runs report `usage=?`, never a fake zero.
- **Operator-persona design lens (SPEC-109, #130).** `/kit:visual-team` accepts an operator-supplied
  `persona: <archetype>` as an inline 6th critique lens (same contract, uniform merge), threaded from
  `/kit:ui-design`. DEC-017 records the boundary vs DEC-003 (a runtime operator archetype is
  supplied-not-baked; the kit ships no persona, the taste liability is the operator's), with a
  `/kit:kit-health` check-13 carve-out so the sanctioned path is not flagged as persona theater.
- **UI done-modes + a bounded quiescence loop (SPEC-112, #134).** `/kit:ui-design` gains a
  `Done-mode` flag , `proof` (mandatory floor) | `over-test` (adds a test-plan + coverage-delta) |
  `quiescence` (Phase B extended into a converging loop: two-sided stop , zero NEW >=HIGH AND no OPEN
  >=HIGH , cap 3, `[[QL-VERDICT]]` markers, a `### Deferred findings` ledger). DEC-018 records the
  cap divergence (quiescence 3 vs plain REVISE 2).
- **Starter role-specialized agent roster (SPEC-111, #133).** Six domain specialists, mixed by fit,
  each gated + provenance-stamped, with two live dispatch paths: workers (`db-migration-worker`,
  `data-etl-worker`) via `/kit:execute` 2b-0's reuse branch (a new `role-classify.sh agent-for`
  lookup makes the hit deterministic), reviewers (`performance`/`api`/`frontend`/`infra-reviewer`)
  via `/kit:review-team`'s opt-in domain lens. Reconciles SPEC-089: 2b-0's reuse-known-worker vs
  synthesize-novel branch is the single router; `generic` escalates to Mode-C (the dynamic long tail).
- **README mermaid lifecycle hero + test-pinned layout counts (SPEC-113, #135).** The hand-drawn
  ASCII lifecycle becomes a native mermaid flowchart (6 phases, gate classes); the directory-layout
  counts are corrected (24 agents, 17 hooks) and a computed test-meta parity pin kills the
  count-drift class. `docs/v-model.svg` is linked from WORKFLOW.md (which keeps the ASCII canon).
- **Navigable docs map (SPEC-114, #136).** `docs/README.md` extends below its verbatim front door
  into a thematic map covering every record class , adding `implementation-notes/` and
  `verification/` (the load-bearing `verification/README.md` the ship-gate keys on) , with a
  `lib/spec/spec-index.sh` pointer for the specs and no rotting counts.

### Fixed
- **install.sh is now plugin-aware, no more double-registered hooks.** When the
  kit plugin (`kit@dwarves-marketplace`) is already installed, `install.sh`
  detects it and does a COMPAT-ONLY install: it symlinks the legacy
  `~/.claude/dwarves-kit/{lib,WORKFLOW.md,AGENTS.md}` paths (so docs that still
  call `bash ~/.claude/dwarves-kit/lib/<x>.sh` in plain bash, where
  `${CLAUDE_PLUGIN_ROOT}` is unset, keep resolving) and skips the settings.json
  hook merge + flat-command symlinks the plugin already owns. This removes the
  "don't run both paths" footgun: running both previously double-registered every
  hook and could pin a drifting lib/ version. Force the full bash install with
  `KIT_FORCE_FULL=1`. Covered by `tests/test-install-compat.sh`.

### Added
- **spec-index: read-only registry view across co-located docs/specs namespaces
  (no numbering/discovery change).** New `lib/spec/spec-index.sh` scans every
  `*/docs/specs/SPEC-*.md` in the repo and lists them grouped by namespace
  (`central docs/specs` and co-located ones like `tools/<name>`), each group
  sorted by local number. Numbering stays deliberately per-namespace and local;
  this view is NOT wired into `spec-next` / `goal-drafts` / `precedent`, which
  remain namespace-scoped. Covered by `tests/test-spec-index.sh`.

## [1.7.0] - 2026-06-11

### Added
- **Operator doc sync + README parity pins (SPEC-085 / ID-070, the 2026-06-10
  intake wave closes 8/8).** README's hook and command tables had drifted
  (claimed 14 hooks vs 16 real, 22 commands vs 25; `ship-gate`, the hook that
  blocks unproven ships, was absent from the public table). Counts fixed, four
  rows added, six stale descriptions refreshed (board-aware context-readiness,
  confidence-gated review-team, INCONCLUSIVE verify), and the README tables now
  carry the same computed parity pins as the architecture inventories, so the
  next drift fails the suite instead of waiting for a reader to notice.
- **Hook fallback layer declared (SPEC-084 / ID-036, I3 closed , the layering
  contract is complete).** `docs/architecture.md` now states the 3-layer rule
  (orchestration decides, agents isolate, hooks are fallback ONLY for failure
  modes that survive prose), a 4-step placement decision test for the next
  proposed hook, and a classed 16-row inventory (5 hard, 3 advisory, 8
  convenience) with a parity pin so the table cannot drift. "Guardrails over
  guidance" is reconciled as bounded: guardrail = the hard subset where trust
  fails and damage is irreversible. ID-027 landed as a spec-validate
  Reviewer 4 autonomy-gate bullet; ID-012 P2 is dispositioned as a worked
  example (loop QA stays orchestration + ship-gate, no new hook).

### Fixed
- **The nameless hooks-suite flake (ID-081), root-caused and fixed.** BSD
  `script(1)` copies terminal attrs from its own stdin; when a harness hands
  the suite a SOCKET stdin (agent runners), the ioctl fails and `script` exits
  before the child runs, so the PTY color test saw zero bytes, flaky only
  because stdin's type varies by harness. The test now feeds `script` an
  explicit `/dev/null` stdin and reads the typescript file instead of racing
  stdout. The negative control still flips RED when the color gate is broken.

### Added
- **Session-start board wire (SPEC-083 / ID-033, I1 closed).** The
  `context-readiness` SessionStart hook now sees the board: a `board:<N>q`
  state token whenever `_meta/BACKLOG.md` exists, and a queue-aware
  intent-first suggestion ("N queued on the board; state the task, or
  /kit:assign --next"). Every cycle suggestion was rewired to speak intent
  first with the command in parentheses; a live spec's cycle suggestion beats
  the board pull. The 5-hop wire audit (session start -> orchestration ->
  commands) is recorded in the spec; hop 1 was the only break.
- **Per-finding validator wave (SPEC-082 / ID-079; EveryInc, MIT , the final
  absorption candidate, 6/6 done).** Every unsuppressed CRITICAL/HIGH finding
  gets ONE adversarial refuter subagent (never batched: batching recreates
  persona bias); refuted findings demote to the appendix with the
  counter-evidence, confirmed ones are marked validated, and a validator infra
  failure NEVER drops a P0/P1 (stays, marked unvalidated, verdict treats as
  live). Validators run mid-tier; the cost note tells the truth about the
  added subagents.
- **Anchored-confidence merge for review-team (SPEC-081 / ID-075; EveryInc, MIT,
  15/16 , the top absorption candidate).** Reviewers return findings with a
  confidence at 5 behavioral anchors (each with a self-test); fingerprint dedup
  (file + line-bucket +-3 + normalized title); cross-lens corroboration promotes
  one anchor step; a LATE <75 gate (CRITICAL survives at 50+) suppresses weak
  findings into a never-dropped appendix AFTER they get their promotion chance.
  Review closed 2 logic holes: suppressed findings can no longer be routed at the
  decision gate, and telemetry findings=K now counts the main report only.
- **verify-this delta + architecture tripwires (SPEC-080 / ID-077, ID-080;
  cursor, MIT).** /kit:verify restates the claim falsifiably (condition + metric
  + threshold) before measuring and may return INCONCLUSIVE (named causes; not a
  pass). Review found the gate hole TWICE: an INCONCLUSIVE record with Exit: 0
  satisfied proof-ledger, and the first guard then blocked the documented
  append-retry workflow , final semantics: last-verdict-wins on both check
  paths, 4 behavioral fixtures. Reviewer 2 gains the 1k-line and
  spaghetti-growth tripwires.
- **The 12th task type: review (SPEC-079 / ID-074).** Standalone review of a code
  artifact now routes from intake (the ID-065 trace had it at 0/3): classifier
  rule with an acting-on-feedback negative guard, registry row (inert: the report
  IS the proof), loops row wired to SPEC-078 routing, 5b dialect, grill bank,
  every count + list swept 11->12. Review found 2 CRITICAL false-pass meta pins
  (hardcoded 11-type alternation stayed green without the new row) , both made
  falsifiable at 12.
- **review-team apply-class routing + model tiering (SPEC-078 / ID-076, ID-078;
  EveryInc, MIT).** Every finding carries a Route (gated_auto -> responding-to-
  review, manual -> board row, advisory -> spec record; conservative on lens
  disagreement; no auto-apply class). Security lens dispatches with an explicit
  session-model override (its agent frontmatter would silently down-tier
  otherwise , review catch); the other lenses run mid-tier, cutting the
  command's token cost to ~1.5-2x from 3x.
- **START amend path + stack-merge self-reconcile (SPEC-077 / ID-072, ID-073).**
  `gate-ledger.sh start --amend` writes a sanctioned START-AMEND correction; every
  reader (report, misfires, trace, ship-gate) takes the last amend, else the first
  plain START , an honest lane fix no longer reads as a MULTI-START misfire (and
  the audit found report/trace already disagreed on which START wins; unified).
  stack-merge now self-reconciles every link's own branch onto its base before the
  squash (state-keyed; both wave-1 and wave-2 chain resumes had hit GraphQL
  conflicts), with ff-sync, post-push ancestry assertion, and branch restore.
- **V-model descent contract (SPEC-076 / ID-068).** Every left-arm step now
  carries a review obligation on EVERY lane (tiny gains a run-lite Review; weight
  scales, the obligation never waives) and descent order is detected: the lane's
  plan order IS the descent order, `gate-ledger.sh descent <rid> <lane>` replays
  the ledger timeline (run-lite phases implicit, grill + required phases real
  checkpoints, one deduped line per gap), ship-gate surfaces violations as an
  advisory , never a mid-flight block (ADR-0024). Promotion to a hard gate waits
  on SPEC-073 telemetry.
- **Absorption proposal: the two pinned kits (ID-069).** compound-engineering +
  cursor/plugins scanned proposal-only: 6 gate-passers (anchored-confidence merge
  15/16, apply-class routing 15/16, verify-this INCONCLUSIVE verdict 14/16, model
  tiering 14/16, per-finding validators 13/16, two quality tripwires 13/16), 8
  rejections, licenses MIT. Lane-A drift fixed (upstream deprecated safe_auto).
  Adoption waits on the human merge gate.
- **Use-case path audit + eval/research anchor recall (SPEC-075 / ID-065).** The
  three real loop shapes traced end to end: research routes 2/3 (now 3/3),
  build-experiment 1/3 (now 3/3), autoreview 0/3 , the 12th-type decision is
  ID-074 on the board with all SPEC-057 parity surfaces named. Kit-vs-skills
  verdict: no destination conflicts; the gap class was recall, not capability.
- **Lane x type composition rule + audit (SPEC-074 / ID-066).** The 55 (lane,
  type) pairs now have a written contract: the type names the CONTENT (loop steps,
  proof dialect, executor), the lane names the EVIDENCE (the depth-matrix gates
  ship-gate enforces); loop steps map into the canonical phases, gaps record
  skipped-with-loop-note. Three precedence facts pinned (tiny/backfill inert
  short-circuit; bug+incident; degenerate lanes). The audit also caught the
  backfill anchor missing its own documented example (fixed, failing-first) and
  review hardened it against compound phrases carrying hard-gate subjects.
- **Doc-loop second entry path + telemetry-eval design (ID-060, ID-067 / SPEC-073).**
  The WORKFLOW doc loop now names BOTH entry paths (code-diff-triggered diff sweep;
  standalone revision via content brief), one shared doc-verifier exit. The
  telemetry/PoD effectiveness evaluation is fully designed (10 metrics with
  thresholds + dispositions decided before the data exists) and PARKED until 3-5
  days of post-rid-standardization usage; doc-verifier caught 2 overclaims in the
  design (a phantom --since flag, a phantom escapes subcommand), corrected.
- **Classifier anchor recall fixes (SPEC-072 / ID-057, ID-064).** data-tool no
  longer steals feature-work-ON-a-CLI (bare `cli` anchor narrowed to
  build/write/create/wrap/ship verb phrasings; `make` deliberately excluded);
  markdown-only / doc-tree bootstrap work classifies tiny via a new 3b precedence
  slot that runs AFTER the hard-gate pass, so a README about auth tokens or kit
  machinery still classifies full (multi-lens review HIGH: the first draft put the
  anchors at tiny's precedence 2, silently preempting hard-gates). The negative
  control itself found and closed an unpinned regex arm.
- **Four gate/ledger defect fixes (SPEC-071 / ID-061, ID-063, ID-062, ID-050).**
  proof-gate's class now floors at the task-type registry default (a doc task is
  `inert`, not blanket `behavioral`; migration/incident/operate floor at `stateful`,
  planning/learning at `inert`); the SPEC-069 boardless advisory relocated above the
  spec check so spec-less pushes finally get the nudge; new evidence-dies-with-the-
  session advisory (a build-ran run shipping no docs/verification record warns, never
  blocks, covering the proof-gate's deliberate fail-open seams); progress renders a
  disposed-past-the-pointer phase as `*` with a legend instead of a misleading ✓.
  Failing-test-first (5 RED pre-fix), multi-lens reviewed (7/7/7, all findings fixed
  in-branch).
- **One canonical rid: the branch slug (SPEC-070 / ID-059).** `lib/gate/gate-ledger.sh rid`
  prints the runid-normalized branch slug (refuses master/main/detached/empty-stem,
  loudly), the same key `hooks/ship-gate.sh` checks at push, so assign-time records
  and ship-time enforcement meet on one ledger: the mirror-record dance (5x in one
  day, worst friction of the quality wave) is gone and lane-telemetry's untracked
  metric becomes honest for new runs. Every gate-ledger RID call site swept from
  `<spec-slug>`/`<slug>` to `<rid>` (debug.md's escaped-from spec reference exempt);
  agreement pin guards the duplicated transform; `ledger_file` gains an empty-stem
  guard (review S1: a `feat/@` branch would have merged audit trails into a hidden
  .log). Multi-lens reviewed (3 lenses, 2 HIGH + 3 MEDIUM found and fixed in-branch).

- **Retro follow-ups: detect what prose forgot, escalate where it bled, color the walk (SPEC-069 / ID-058).** The operator's 5-question retro became machinery: (1) telemetry detects **boardless runs** (ledgered work the board never saw; the whole quality wave ran un-boarded until caught, because the rule was prose and prose loses to context decay) and **shipped-incomplete runs** (a ship gate over un-disposed phases, the spec-064 think class), both surfaced at S1/misfires + a ship-gate advisory line; (2) runs touching lib/ or hooks/ now owe the multi-lens /kit:review-team (two 2-HIGH drafts, both in those surfaces, are the evidence); (3) grill orientation points unfamiliar-code questions at codebase-memory before blind grep; (4) plan/progress/trace gain TTY-gated colors (green disposed, bold-yellow pointer, dim pending, red MISFIRE), piped output byte-identical so 300+ test pins pass untouched; (5) spec-064's missing think gate retro-patched with an honest note. First live run of the detectors immediately flagged the real pre-discipline history (3 boardless, 2 shipped-incomplete).

- **Precedent lookup at intake (SPEC-068 / ID-056).** The second brain had a write head (specs, ADRs, retros, run reasons accumulate every cycle) and no read head: every new task started from a blank page. `lib/precedent.sh find "<task>"` keyword-greps the durable surfaces + run-ledger reasons, ranks by distinct-keyword hits, prints top-N with headlines; /kit:assign runs it before sizing (matches feed the goal draft's Context) and /kit:grill's orientation reads it (a precedent contradicting the ask is the first question). Grep by design, no index/embeddings/daemon. First live smoke on the real repo surfaced 4 genuinely relevant specs for a classifier-tuning ask.

- **The golden run: an end-to-end harness (SPEC-067 / ID-055).** 700+ unit pins prove each part in isolation; nothing proved the parts agree. `tests/test-e2e.sh` builds a temp repo + temp log world and walks ONE task through the whole loop (board pull -> classify both axes -> START -> grill -> phase gates -> ship), then asserts the three read surfaces tell the same story: gate-ledger (check green, progress complete 8/8), lane-telemetry (run + ship counted, verdict surfaces, trace renders, no misfires), and the board (queued -> claimed -> shipped). A deliberately misrouted second run must be SEEN by report, misfires, and trace. CI runs it as a third suite. Bonus: the harness's first execution found a real classifier over-match (bare `cli` anchor steals feature-work-ON-a-cli), filed as ID-057 per the disposition contract.

- **Install by copy, version-pinned (SPEC-066 / ID-054).** Hooks, lib, and the contract files were symlinked into the install dir, so the LIVE enforcement code followed the clone's checked-out branch (a fixed safety-gate silently regressed mid-session on a branch switch; SPEC-064's own ship ran the old ship-gate). Now bash-install copies everything, chmod +x, writes an INSTALL-STAMP (version/sha/date), and re-install is the explicit upgrade path with anti-drift (hand-edited installed copies revert). kit-health gains a staleness probe (stamp sha vs repo HEAD); uninstall removes copies; CLAUDE_DIR is env-overridable so the install is fixture-tested (7 tests incl. the anti-drift negative control).

- **Stack-merge codified (SPEC-065 / ID-053).** The squash-stacked-chain merge dance (retarget the child BEFORE merging the parent or GitHub auto-closes it; squash-merge; reconcile the child on the new tip with a superset-safe `-X ours` merge BY SHA) was executed by hand twice in one day, stranding a PR the first time. `lib/goal/stack-merge.sh next <pr>|chain <pr>...` runs it, `--dry-run` prints the plan, clean-tree guarded; ship.md points stacked shipping at it. Honest limits in the header: squash-only, one child per parent, conflicts beyond `-X ours` abort for a human.

- **Hook precision: parse argv, not prose + the spec-number guard (SPEC-064 / ID-051 + ID-052).** Seven false positives in one day taught the lesson: a string-matched enforcement layer reads DATA as commands, and every false alarm teaches the operator to route around the gate. safety-gate is rewritten parse-aware (heredoc bodies stripped, compounds split into segments, quoted spans excluded; each rule keys on its segment's real argv) with every 2026-06-10 false positive as a permanent pin and every destructive shape re-verified to still block. ship-gate engages on heredoc-stripped code only and gates the cd-target repo (the cross-repo misfire fix). New lib/spec/spec-next.sh ends the SPEC-number collisions (scans specs/, all branches, recent subjects; spec.md wires it; this spec's own 064 came from it). 12 new tests; live 17-case allow/block matrix in the PR.

- **Run legibility: plan, progress, trace + a recordable grill (SPEC-063).** Three operator asks: the run should announce its road on entry, show "step k/n" as it walks, and leave a full reviewable story. `gate-ledger.sh plan <lane>` prints the lane's ordered checklist (matrix-derived, grill prepended as the universal intake phase, tiny exempt); `gate-ledger.sh progress <rid> <lane>` prints `<rid> · <lane> · step k/n (<phase>)` + a ✓/▶/· checklist (plan x ledger, no new state); `lane-telemetry.sh trace <rid>` renders one run's ledger as a story (routing header with LANE/TYPE MISFIRE flags, humanized timeline, escaped-from indictments called out). The grill becomes a recorded phase: ran with a summary, or skipped WITH a reason (an unrecorded skip is invisible to telemetry, which defeats the point; the gap was found when the operator noticed grill never fired during the telemetry waves). Wired: assign prints the plan after the START record; AGENTS carries the standing show-the-road + progress-at-phase-entry rule; grill records itself at exit. 1 pin + 9 fixture tests incl. a record-removal negative control (the ▶ pointer moves back).

- **Telemetry closure: type misroutes, escaped defects, operator scenarios (SPEC-062).** SPEC-061 measured lane routing; the operator's evaluation goal was wider. Three holes closed: (1) START gains a `ctype=` pair so TYPE misroutes (the absorb->eval class, the kind that imposes a wrong proof dialect) reach the report and `misfires`; (2) test-design quality gets its metric: `/kit:debug` records `escaped-from=<spec>` when a defect indicts a shipped spec's test plan, aggregated into an `escaped defects` report section per spec, and `/kit:test-plan` + `/kit:test-plan-review-team` record their verdicts into the ledger; (3) WORKFLOW's "What the operator sees, and when" writes the contract down: S1 session-open misfire shortlist via /kit:start, S2 full report + disposition pass at /kit:retro (recommended after 3-5 days of runs), S3 escaped-defect recorded at debug time and surfaced at S1/S2, with a sample report block. 1 pin + 7 fixture tests incl. a ctype-strip negative control; this run's own ledger carries a real chosen=normal/classified=bug misfire as a live fixture.

- **Lane telemetry + the feedback loop (SPEC-061).** The kit's lanes were unmeasured: run facts existed in pieces (gate ledgers, completeness.log) but nothing recorded the routing decision (chosen vs classified lane, type, repo), review verdicts, or outcomes in queryable form, and nothing aggregated, so a lane misfire died in chat instead of improving the classifier. Now: `gate-ledger.sh start` records the routing facts at `/kit:assign`; reviews record their verdicts via the existing `record` verb; `/kit:ship` carries `pr=#N`; new `lib/telemetry/lane-telemetry.sh report|misfires` aggregates read-side (pure bash/awk over the existing pipe-delimited ledgers, no new store, no daemon); `/kit:retro` Step 1d reviews it under a disposition contract (every misfire becomes a keyword fix + pin, a BACKLOG row, or a recorded accepted-noise line); WORKFLOW "How lanes are judged" names the five signals (misclassification rate, gate skip/override rate, review findings curve, duration vs weight, untracked runs). Telemetry proposes; the human at retro disposes. 3 pins + 6 fixture tests incl. an in-suite negative control.

- **Classifier recall tuned from a live-session truth table (SPEC-060).** A probe of 8 real asks from one working arc found 7/8 falling to the spec-feature default, and one harmful misfire ("evaluate skills + absorb into the kit" -> eval, imposing the wrong metrics+seeds proof dialect). Four narrow anchor extensions: operate gains merge-the-stack / session-wrap / LAB_LOG phrasing; reconcile gains untangle/stranded/orphaned estate anchors; planning gains mega-goal/roadmap-scaffold; a new 4b absorb guard above eval routes absorb-into-kit work to spec-feature (co-occurrence-gated so "absorb the loss into the budget" falls through). No new type: the 11 cover the semantics; real phrasing beats invented phrasing. 14 pins (8 positive real rows + 6 adjacent negatives); negative control run live (guard disabled -> eval -> restored).

- **Absorb wave: feedback-loop-first debugging + deep-module review vocabulary + the skill-routing rule (SPEC-059; absorbed from mattpocock's `diagnose` + `improve-codebase-architecture`).** `/kit:debug` gains `## Phase 0: Build a feedback loop`: a fast, deterministic, agent-runnable pass/fail signal is most of the debugging skill (every later phase just re-runs it), with a 9-tactic construction catalog (failing test -> trace replay -> bisection harness -> differential loop), the iterate-on-the-loop discipline (faster / sharper / more deterministic), repro-rate guidance for flaky bugs, and an honest cannot-build-a-loop stop. `/kit:review-team`'s architecture lens now speaks deep-module vocabulary (deep/shallow, the deletion test, seams, leverage/locality, after Ousterhout) so findings are concrete instead of vibes. PHILOSOPHY §1 gains `### Skill routing: what belongs in the kit`: loop machinery absorbs into the kit; reflex skills and domain procedures live in the operator's skill estate with the type registry's owning-skill column as the bridge, so every future absorb routes mechanically. The same wave's evaluation rejected `grill-me` (superseded by SPEC-058), `triage` (the board IS the state machine), and `teach` (operator's learning estate is deeper); 3 pins + negative control.

- **`/kit:grill`, the universal intake interview (SPEC-058 / ID-049; absorbed from mattpocock's grill-with-docs).** The maintainer's pre-kit workflow grilled the operator before any work; the new intake had lost it (think challenges ideas, design explores solutions, nothing gathered requirements for any type). /kit:grill slots between type classification and the phase-0 Done=: one question at a time with a recommended answer, question banks shaped per all 11 work types, contradictions checked against the repo, and write-as-you-go (a resolved term -> the repo glossary; a decision meeting the 3-criteria bar -> a sparse ADR; the Q&A digest -> the goal draft's Context, the second-brain feed). Exit proposes the Done= the answers imply + a re-classification check. Tiny lane exempt. Wired into AGENTS.md task loop, /kit:assign, and the WORKFLOW phase-0 lead-in; pinned, with the negative control run during build and recorded in SPEC-058's ## Review.

- **Taxonomy expansion: 6 -> 11 work types + universal done-first (SPEC-057 / ID-048; deepens PHILOSOPHY §6 N1/N3).** An evidence sweep over the operator's full LAB_LOG found the 6 types covered ~47% of real work. Five recurring kinds become first-class, each with a classifier rule + registry row + WORKFLOW loop + test-design dialect: **incident** (alert -> triage -> root-cause before fix -> INC record -> monitoring; evidence-ledger dialect), **reconcile** (inventory -> conform/drift -> fix -> reference-fix -> gate; absorbs cleanup/audit/drift), **operate** (recurring procedure runs: payroll/recon/radar; run-ledger dialect), **planning** (gather -> prioritize -> enqueue board rows -> digest), **learning** (ingest -> explain -> practice -> self-check bar). Three deliberate folds documented: deployment stays migration (+launchd/daemon/provision keywords), agent-org config rides spec-feature, discovery splits research/reconcile by intent. Universal phase 0: every loop defines its done scenario (proof contract + dialect test design) BEFORE running, and every `/kit:assign` draft must carry a `Done =` line; SPEC-031 notes the V-model right arm is type-agnostic. 12-case classifier truth table + an 11/11/11 parity pin (a half-added type goes RED); both negative controls recorded.

- **Per-type test-design dialects; test-first becomes the default for normal/full (SPEC-056 / ID-046; realizes PHILOSOPHY §6 N3).** `test-design-standard.md` §5b: one spine, six bodies, spec-feature keeps the BDD category matrix; eval designs metrics + hand-verified seeds + falsifiability controls; research designs a claim-verification matrix; migration/cleanup designs inventory coverage + a rollback REHEARSAL; data-tool designs a recorded live run + negative control; doc designs doc-verifier matches. `/kit:test-plan` classifies the type first and designs in that dialect (same `## Test plan` heading, same AC-traceability). The cycle table flips test-plan from opt-in to default for normal/full (tiny exempt; advisory, never a hard block). Meta pin + negative control.

- **The Active queue is a kanban board with pull mode (SPEC-055 / ID-045; realizes PHILOSOPHY §6 N2).** New `lib/board/backlog.sh`: `board` renders the queue as kanban columns (illegal statuses surface as UNRECOGNIZED instead of vanishing), `next` picks the first queued row (file order = priority), `set` flips a row's leading status keyword mechanically while preserving its annotation prose. SPEC-005's vocabulary gains `claimed` (a pulled item; the cross-session claim stays in goal-registry). `/kit:assign --next` pulls the top queued item without the operator naming one; `/kit:start` nudges the board. No daemon, no parallel database: the markdown file stays the one source of truth. The board's first real render immediately found three drifted rows (two shipped-but-queued, one illegal status), migrated via `set` (dogfood). 10 fixture tests + a meta pin.

- **Right-sized loops per work type (SPEC-054 / ID-044; realizes PHILOSOPHY §6 N1).** The classifier knew six work types but only code had a cycle; research/eval/doc/migration/data-tool work ran as unstructured chat. Now WORKFLOW.md `## Type loops` defines each non-code type's entry -> phases -> exit (research: frame -> sweep -> adversarial claim-verify -> cited report; eval: metrics + seeds -> ladder -> TEST-REPORT; migration: inventory -> dry-run -> staged apply -> rollback proven; etc.), the task-types registry gains an `agent` column (preassigned vs dynamic executor; appended as column 6 so proof-gate's index-based parser is untouched, verified byte-identical), and `/kit:assign` + `/kit:start` classify the type BEFORE sizing, routing non-code work to its loop. Chat stays chat: loops engage on task execution. Also fixed the registry's data-tool artifact example that still taught the generator-clobbers-canonical anti-pattern (contradicted #30). 3 meta pins + negative control.

- **Advisory lane floor-check closes the classify-then-route gap (`lib/classify/lane-classify.sh check`, SPEC-053 / ID-043; revives PR #13).** The classifier suggested a lane, but nothing caught when the lane actually *chosen* in `/kit:assign` was lighter than that deterministic floor, so an under-sized `full`/`bug` task slipped through silently. A new `check <chosen-lane> "<desc>"` subcommand re-classifies the task text and warns + logs to `completeness.log` (reviewed at `/kit:ship`) when `rank(chosen) < rank(suggested)`, with risk ranks `tiny < normal=bug=backfill < full`. Wired into `commands/assign.md` Step 5 right after a lane is committed. Advisory only: always exits 0, never blocks (Detect, don't dictate); over-sizing stays silent (always safe); an unrecognized lane warns distinctly instead of crashing. Originally built 2026-05-23 against the keyword classifier (PR #13); went stale when #26 rewrote the classifier to flag-scoring; re-ported onto `classify_core` with behavior unchanged. 7 behavior tests (`tests/test-hooks.sh`) + 2 structural guards (`tests/test-meta.sh`); `/kit:dispatch` excluded (it seeds from the classifier, cannot downgrade).

### Changed

- **README narrative reframed as a closed agent loop.** The README's narrative layer now positions the kit in closed-looping vocabulary (`goal -> loop -> evaluate -> improve -> result`): a lifecycle-as-loop diagram with per-phase gate labels, a "Why a closed loop" open-vs-closed comparison, and a fleet-shaped verification-pipeline diagram (orchestrator -> worker -> read-only verifier -> fix-agent, max 2). A doc-verifier pass on the first draft caught four enforcement overclaims (most phase gates are advisory; only the four hard stops block), fixed before ship: tagline scoped to "until the verifier passes", advisory labels on the diagram, spec validation scoped to the full lane, "gates are mechanical" scoped to hard gates. Factual sections (install, command/hook/agent tables, structure, credits) unchanged. Follow-ups queued as ID-059 (doc loop standalone-revision entry path) and ID-060 (proof-gate `behavioral` upgrade false positive on the phrase "no behavior change").
- **Corrected the V-model framing to build-left / test-right (reworks SPEC-031 / ID-034).** SPEC-031 shipped the V-model lens with the arms as DEFINE (left, including test-design) mirrored by VERIFY (right). That was wrong twice over: it mixed *commands* and *agents* on the same arm (e.g. listed `task-verifier`, an agent, where a command was implied), and it put test design on the left as if the kit shifted testing left, which it does not (the kit has one late `/kit:test-plan` step, not a test designed at every phase). Reframed so the **left arm BUILDS** (Brief/Requirement -> Solution-design -> Spec -> Code) and the **right arm TESTS** (test design via `/kit:test-plan`, then the unit -> integration -> system -> acceptance levels execute and report); static review gates (`/kit:spec-validate`, `/kit:devs-team`, `/kit:review`, `/kit:review-team`, `/kit:visual-team`, `/kit:docs`) wrap the V but are not test levels. `WORKFLOW.md`'s `## The V-model lens` redrawn; `docs/architecture.md` inventory regrouped into BUILD / vertex / TEST / static-gate / cross-phase (parity unchanged at 31); ADR-0018 Decision #1 corrected in place (its lens-over-cycle and count-agnostic decisions stand). Also fixed two inventory drifts found en route: `integration-checker` is dispatched only by `/kit:execute` (not review), and `security-auditor` is a standalone agent dispatched by no command. Refined so each static-review gate (`/kit:spec-validate`, `/kit:devs-team`, `/kit:review`, `/kit:visual-team`, `/kit:docs`) is shown inline as the static verification of its artifact, mirrored by the right-arm dynamic test, and a `## The V-model lens` coverage-gaps note names the proposed `/kit:verify` command, the `security-auditor` orphan-agent wiring (ID-039), and the optional `acceptance-verifier` agent. Source: 2026-05-23 V-model framing + coverage review.
- **Wired the `security-auditor` orphan agent into `/kit:review-team` (ID-039).** The agent existed but no command dispatched it (dead code by the kit's no-phantom rule, surfaced by the V-model coverage map). `/kit:review-team`'s security slot now dispatches `security-auditor` (the dedicated deep-security reviewer) instead of the generic `reviewer` security lens; `docs/architecture.md`, the WORKFLOW V-model lens, and `docs/v-model.svg` updated to show it dispatched, not orphaned. No new command, per the command-vs-agent rule (an agent needs a trigger, not its own command).
- **Plugin command namespace renamed `dwarves-kit` -> `kit` (ID-031).** Commands now resolve as `/kit:<cmd>` (e.g. `/kit:spec`); install is `/plugin install kit@dwarves-marketplace`. `plugin.json` + `marketplace.json` carry the new name; the meta-test name guard tracks it. The repo/project name is unchanged. `user` was rejected as the namespace: it is a reserved prefix (personal/project commands) and collides with their resolution. Discovered while migrating off the bash installer: CC 2.1.148 cannot install a local directory-source marketplace plugin, so the maintainer loads the kit via a `--plugin-dir` shell wrapper (namespace + live edits); github-source is the frozen end-user path. Reference: `ops-toolkit/research/2026-05-22-cc-plugin-local-install.md`.
- **Swept the stale `/user:` invocation form to `/kit:` across the live docs (SPEC-029 / ID-031).** 326 `/user:<cmd>` occurrences became `/kit:<cmd>` across 31 files (`README.md`, `MANUAL.md`, `WORKFLOW.md`, `CLAUDE.md`, `docs/`, `commands/`, `examples/`). `/user:` never resolved the kit on CC 2.x (reserved prefix) and bare `/<cmd>` was only the flat-installer artifact. A new denylist meta-test guard (`tests/test-meta.sh`) fails on any `/user:` in live docs and auto-covers future files; dated/point-in-time records (`docs/specs`, `docs/retro`, `docs/decisions`, `docs/handoff`, `docs/research`) plus `CHANGELOG.md` and `_meta/` are exempt (rewriting records falsifies history). README + MANUAL gained a one-line plugin-vs-bash invocation note (`/kit:spec` vs bare `/spec`). Validated via `/kit:spec-validate` (the 5-lens pass caught an allowlist-vs-denylist guard flaw before it shipped). Meta suite to 257.
- **Finished the `/user:` sweep at the install + hook surfaces (SPEC-030 / ID-032).** SPEC-029 swept the docs but its guard was `*.md`-only, so `install.sh` and `hooks/*.sh` still printed the dead `/user:` form to users (the install success line, the session-state resume note, the `context-readiness` next-step hints, the `anti-rationalization` block reason). Swept per surface to the form correct for its cohort: `install.sh` (the bash path, which resolves bare) -> bare `/<cmd>`; the hooks (which run under both install paths and cannot detect which) -> neutral, slash-free command names, since no single slash form serves both the bash (`/<cmd>`) and plugin (`/kit:<cmd>`) cohorts. The `tests/test-meta.sh` namespace guard now also scans `install.sh` + `hooks/*.sh` (DEC-003; `tests/` excluded so it cannot flag its own descriptive comment), closing the blind spot that let SPEC-029 ship incomplete. No `*.md` doc changed; hook control flow / exit codes unchanged. Meta suite stays 257 (the guard gained file coverage, not a new assertion).

### Added

- **The proof-of-done gate now enforces in CONSUMER repos, not just dwarves-kit (SPEC-045, fix).** `hooks/ship-gate.sh` resolved its lib as `${CLAUDE_PLUGIN_ROOT:-$ROOT}/lib/...`, so in bash-install mode (no `CLAUDE_PLUGIN_ROOT`) it looked for `lib/gate/proof-ledger.sh` inside the repo being pushed; a consumer repo has none, so the gate failed open everywhere but dwarves-kit itself. Fixed: resolve from the stable install root `${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/dwarves-kit}/lib/`, and `install.sh` now deploys `lib/` there (dir symlink, in-place-guarded, removed on `--uninstall`). `lib/gate/proof-gate.sh` uses `pwd -P` so the registry still resolves through the symlink. End-to-end repro in `docs/verification/SPEC-045.md`: a behavioral consumer diff fails open without the lib, BLOCKS with it, passes once proof is added. Pin in `tests/test-meta.sh` (suite 389 -> 390). Unblocks adopting the gate across the active engineering repos.

- **Task-type contracts compose onto the proof gate (SPEC-044).** A second classification axis on the verification gate. `lib/classify/task-type-classify.sh` maps a task to a work TYPE (eval/research/doc/migration/data-tool/spec-feature); `docs/verification/task-types.md` (one row per type, the extension point) maps each type to its proof artifact + owning skill. `lib/gate/proof-gate.sh contract "<desc>"` composes the TYPE (artifact shape + skill) with the existing proof CLASS (rigor); the class still wins on rigor (a migration upgrades to stateful). The `proof-ledger.sh` BLOCKED message now points to `proof-gate.sh contract` for the type-specific artifact (auto-typing a diff is a deferred follow-up). 18 structural assertions in `tests/test-meta.sh` (suite 371 -> 389). Proof: `docs/verification/SPEC-044.md` (green run + negative control). Status: implemented + self-verified on `feat/proof-done-task-types`; pending `/kit:spec-validate` + `/kit:review` + merge before SHIPPED.

- **Single-source verification numbers + the experiment sibling (`lib/gate/verif-counts.sh`).** Cross-pollination with the `tool-eval-experiment` discipline (the two are dialects of one evidence grammar: recorded, reproducible, falsifiable). Borrowed FROM the benchmark's `gen_docs.py` single-source pattern: suite counts are generated into the GEN block of `docs/verification/COUNTS.md` from the live suites, never hand-typed into N docs where they drift; a verification log links there instead of transcribing a number. `docs/verification/README.md` gains a "Sibling discipline" section naming the experiment (the research-paper / comparison form) vs proof of done (the QC / confirmation form), and mapping the shared mechanisms (our negative control = their falsifiability check; their single-source numbers = this). The reverse borrow landed in ops-toolkit + the chezmoi skill: the `tool-eval-experiment` skill now requires a recorded **falsifiability check** (the eval twin of our negative control) and the benchmark records one (`harness/probes/falsifiability.py` -> `results/falsifiability.json`, generated into `TEST-REPORT.md`). 3 structural pins (`tests/test-meta.sh` 365 -> 368). **Dogfooded:** `docs/verification/shared-evidence-discipline.md` links COUNTS.md instead of typing the count, records the regenerate (add tests -> figure moves 365 -> 368, no hand-edit), and a NEGATIVE CONTROL (revert the impl -> the 3 pins fail).

- **Proof of done is enforced at the ship gate, not just advised (`lib/gate/proof-ledger.sh`, ADR-0025).** The proof-of-done discipline was command/agent advice an agent could skip. Now it is a wall: a behavioral or stateful change cannot pass the ship/push boundary without a matching, fresh proof-of-done entry. The gate keys off the **branch diff** (not a spec), so it fires the same whether the work came through `/kit:execute` or a freeform `/goal` loop , closing the bridge the existing spec-keyed lane gate (ADR-0024) missed (it fails open without a spec). `hooks/ship-gate.sh` runs the proof check before its lane check; exit 2 blocks and names the change's class and exactly what proof is missing. **Opt-in per repo** (engages only where `docs/verification/README.md` exists) so a globally-installed hook never blocks unrelated repos; **fails open** on ambiguity; the only bypass is a **logged override** (`proof-ledger.sh override <slug> "<reason>"`), never silent. 14 behavioral + hook-integration tests (`tests/test-hooks.sh` 151 -> 164) + 7 structural pins (`tests/test-meta.sh` 358 -> 365). **Proven live + dogfooded:** `docs/verification/enforce-proof-of-done.md` records the suites green, a NEGATIVE CONTROL (revert the gate in a throwaway worktree -> 11 tests fail, the wall stops blocking, exit 2 -> 0), and a LIVE run of the hook BLOCKING a spec-less behavioral change (exit 2) then PASSING once proof is added (exit 0). Deliberately out of scope: enforcing verifier-implementer independence (the gate checks the entry exists + is valid-shaped, not who produced it), and the stateful live proof on a real deploy/migration repo.

- **Proof of done is gated by task risk class (`lib/gate/proof-gate.sh`).** The discipline now lands where the risk is and gets out of the way where it isn't. A new classifier (reusing `lib/classify/lane-classify.sh`) maps a task to one of three **proof classes**: **stateful** (deploy / migration / data / persistent state) , exercise the REAL flow on a copy or dry-run, record it, and note rollback/reversibility (`[UNAVAILABLE: reason]` if no such flow exists in the repo, never a fake run); **behavioral** (changes behavior) , run the REAL primary flow the change adds (not a tangential test that happens to pass) plus a negative control; **inert** (docs / comments / cosmetic) , exempt, record `[PROOF OF DONE: exempt -- reason]`, no run. Wired into the convention (`docs/verification/README.md` risk-class table + the run-the-real-flow rule), `commands/execute.md`, `commands/verify.md`, and `agents/task-verifier.md` (inert exempt is accepted; a stateful task marked exempt or missing reversibility is a FAIL). 8 behavioral classify tests (`tests/test-hooks.sh` 143 -> 151) + 7 structural pins (`tests/test-meta.sh` 351 -> 358). **Proven behaviorally:** the classifier's own primary flow recorded real in `docs/verification/risk-gated-proof-of-done.md` (GREEN `proof-gate.sh class ...` -> correct classes; NEGATIVE CONTROL removes the impl in a throwaway worktree -> classify exit 127 + the 8 proof-gate assertions fail, 151 -> 143; shared checkout untouched), the inert exemption shown, and the stateful class honestly marked `[UNAVAILABLE]` (dwarves-kit has no deploy/migration flow). Key sharpening over the prior proof-of-done: the recorded run must exercise the *real* flow, not a proxy.

- **Proof of done = green + a negative control + reproducible (SPEC-042).** A captured green run is still a weak proof: it shows the check passes, not that the check *exercises* the change. "Done" is now a proof of done with three parts , the captured green run, a **negative control** (the same check shown to go RED when the work is reverted, so the green is not trivially green), and reproducibility (re-run the logged `Command:`). `docs/verification/README.md` names the concept; `commands/execute.md` (Step 4) and `commands/verify.md` produce the negative control for load-bearing (`normal`/`full`) changes in a throwaway worktree (the shared checkout is never reverted), and a check that stays green when reverted is a finding, not a pass (tiny/docs lanes may skip with a logged reason); `agents/task-verifier.md` flags a weak/absent negative control (read-only, it does not revert) and its tool allowlist now runs a bash/make/just project suite, not only npm/go/pytest/cargo (a real gap , the verifier could not run dwarves-kit's own `bash tests/test-meta.sh`). 5 new `tests/test-meta.sh` pins (346 -> 351). **Proven behaviorally, not hand-followed:** an independent verify-flow agent drove `/kit:verify` end-to-end against SPEC-042 and returned real records , GREEN `bash tests/test-meta.sh` exit 0 (351/351) and a NEGATIVE CONTROL exit 1 (337/351, the 14 verification pins fail) run in a throwaway worktree, restore GREEN exit 0, shared checkout untouched; transcribed to `docs/verification/proof-of-done.md`. Still no blocking hook (the ship-gate-blocks-on-missing-proof remains the deferred enforcement escalation).

- **Execution-backed verification + the verification log (`docs/verification/<spec-slug>.md`).** "Verify before proceeding" now means the check was *actually run* and the run is *recorded as a re-runnable artifact*, not asserted in prose. The verifiers already ran the suite, but the result evaporated into a "Tests: passing" line nobody could re-run. Now: (1) `agents/task-verifier.md` Section 2 requires capturing the exact command, its real exit code, and an output excerpt, and reports them in a `Verification record` block under every verdict; a task with no runnable check records an explicit `[NO EXECUTABLE CHECK: <reason>]` instead of a silent pass (the soft-warning path is gone). (2) `commands/execute.md` appends a verification-log entry at each phase checkpoint (Step 3) and at completion (Step 4), and surfaces the `docs/verification/<spec-slug>.md` path in the completion summary alongside the implementation-notes path. (3) `commands/verify.md` appends one entry per read-only run (the only thing it writes; it never touches the code under test) and its read-only framing is carved to allow recording the run. (4) `docs/verification/README.md` is the convention (entry shape: `Command:` / `Exit:` / `Output (excerpt):` / `Verdict:`; re-run the `Command:` line to regression-check a past verdict). (5) `docs/PHILOSOPHY.md` records the bend under "Verify before proceeding" as an extension of ADR-0005, mirroring the SPEC-041 implementation-notes by-product-of-the-flow shape; kept as command/agent text + convention doc pinned by `tests/test-meta.sh` (9 new guards, meta suite 337 -> 346), not a new hook, since the record is produced structurally by the verify flow. `commands/review.md` (static judgment, not test execution) gains a boundary note: it reads test state from the verification log rather than asserting "tests pass" from inspection, and a missing/`[NO EXECUTABLE CHECK]` entry is itself a review finding. Demonstrated live on this change: `docs/verification/verify-by-execution.md` carries a real `bash tests/test-meta.sh` run (exit 0, 346/346) plus an honest `[NO EXECUTABLE CHECK]` entry for the one subjective aspect, and re-running the logged command reproduced the verdict. This is the *recording* dimension of verify-arm hardening; it is a thematic neighbor of ID-020 (the removal-class absence check, already covered by `task-verifier` Section 1b), not the same gap and not a closure of it. A ship-gate that blocks on a missing verification entry is the documented enforcement escalation if advice proves insufficient (deferred). No new command, no new agent.
- **codebase-memory SessionStart auto-index hook, fixed to actually fire (SPEC-043).** `hooks/codebase-index.sh` background-indexes the cwd repo in codebase-memory-mcp so `/kit:spec` + `/kit:execute` can query a structural index instead of grepping, with zero manual step. Opt-in by tool presence (no-ops quietly when codebase-memory-mcp is absent), backgrounded so session start never blocks, build-then-incremental-refresh. The hook shipped earlier (commit a1a6e4b) but was **inert in practice**: it lived on an unmerged branch, so the global `settings.json` symlink into the dwarves-kit working tree dangled and the hook silently no-opped; and its `[ -d .git ]` guard is false in a git **worktree** (`.git` is a file there), skipping every worktree session. Fix: guard on `git rev-parse --is-inside-work-tree` and index `git rev-parse --show-toplevel` (worktree- and subdir-correct), plus ship it onto master so the symlink resolves. 3 `tests/test-meta.sh` pins (exists+executable, guards-on-rev-parse-not-`[ -d .git ]`, registered in both registries). Verified live: the fixed hook fires in a worktree (the old guard would have skipped). Lesson recorded: a new kit hook is only live once it lands on master (the install symlinks the working tree).

- **Implementation-notes log during `/kit:execute` and `/kit:next` (SPEC-041 / ID-041).** Workers and contractors now maintain `docs/implementation-notes/<spec-slug>.md` for the run of decisions the spec did not pin down, deviations from spec, tradeoffs worth surfacing, and constraints the spec missed. Five-bullet entry shape (Context / Decision-or-Change / Why / Alternatives considered / Impact). One file per spec, markdown only, no `.html`. Empty-case clause: if a build runs end-to-end with zero off-spec moments, the worker still writes a `No deviations from spec` line so silence is intentional, not forgotten. Three insertion points: (1) `commands/execute.md` worker template gains the rule under `## Rules`, the worker's `## When done` report names the file path + entry count, and the orchestrator's `### Step 4: Completion` execution-summary carries the line + nudges `/kit:ship` to include it in the PR body. (2) `commands/next.md` Step 4 hand-off reminds the implementor and scaffolds the file header before handing off. (3) The maintainer's dotfiles overlay (`~/.claude/CLAUDE.md` § "When implementing from specs") carries the paired rule so ad-hoc "implement X" / "build out Y" framings outside the kit also fire it. Four `tests/test-meta.sh` guards pin the rule (worker-template rule present, "When done" reporting names the path, completion-summary carries the file, `/kit:next` hand-off carries the reminder), so it cannot regress silently. No new command, no new agent, no behavior change to the verifier pipeline; the PR-body surfacing is operator discipline, not a hook (preserves the ID-036 orchestration-first / hooks-as-fallback layering). Tiny lane, backfill SDD (the implementation shipped before the spec; SPEC-041 documents the after-state + decisions). Kit commit 2dd80b9; paired dotfiles commit 3bc78eb.
- **Freeform front door: `/kit:assign` now accepts freeform intent, not only `ID-NNN` (SPEC-026 / ID-022).** A vague brief or "apply SDD to X" is a native one-shot intake instead of a hand-bridged detour. The argument resolver routes `^ID-[0-9]+$` down the unchanged ID-first path and anything else down a freeform path that: delegates the crystallize interview to `/kit:think` (assign stays a light mutator-dispatcher, it does not embed the interview, DEC-003); gates on explicit human approval of the crystallized objective **before** allocating anything (approve-before-allocate, so no half-baked rows, DEC-002); sanitizes the text (escape `|`, newlines -> spaces in BACKLOG cells; slug reduced to `[a-z0-9-]+` so it cannot traverse out of `.claude/goals/`, DEC-004); atomically allocates the next ID by re-reading max in the write step with a loud post-write collision check (DEC-005); writes the BACKLOG row before the goal draft (row-before-draft); then rejoins the existing ID-first tail (draft -> lane -> hand-off). ID-first traceability preserved; unparks the SPEC-024-deferred griller entry. Pinned by `tests/test-meta.sh`; documented in `MANUAL.md`. Source: SPEC-026 / ID-022.
- **Multi-session concurrent goals: the cross-session running-goal registry (`lib/goal/goal-registry.sh`, SPEC-036 / ID-040).** Extends concurrency from the single-session `/kit:dispatch` fan-out to the case where one operator opens several Claude sessions on one machine (one goal each) and walks away, with no shared lead. Five pieces landed: (1) **ADR-0022** supersedes the "multi-session stays L5" PHILOSOPHY boundary (conflict C4, the multi-session twin of SPEC-032's C1) for exactly the one-operator / N-same-machine-sessions / disjoint-goals case; `docs/PHILOSOPHY.md` (lines ~121 + ~151) and `commands/kit-health.md` (a recorded carve-out) reworded so the bend is deliberate, and `_meta/BACKLOG.md`'s parked "L5 not needed until 3+ concurrent sessions" entry re-scoped. Across machines, 3+ live human operators, and goal-ordering chains stay L5 (Nimbalyst / GSD v2). (2) **`lib/goal/goal-registry.sh`**: a passive per-goal file registry under `$(git rev-parse --git-common-dir)/kit-goals/` (shared by every worktree of the repo, inherently untracked) with `claim` / `list` / `log` / `status` / `release`; one single-writer file per goal (no shared write); the cross-session disjointness gate **reuses** `lib/gate/dispatch-gate.sh` (a new shared `gate_normalize_glob` single-sources the prefix rule), so a goal overlapping an active one is REFUSED, the colliding goal named. (3) The **claim** step wired into `/kit:assign` (refuse-on-overlap before routing into a lane). (4) The cross-session **monitor** wired into `/kit:start` (a "Running goals (cross-session)" count always, the full `goal-registry list` table in `--full`), the kit-level companion to the native agent view (which sees only one session's subagents); `/kit:dispatch` also registers its in-session workers so one `list` shows both axes. (5) Each goal leaves a human-legible **attempt log** (`<slug>.attempts`), the convention documented in the `/kit:assign` directive + the `/kit:dispatch` worker prompt (helper-backed, detect-don't-dictate). No daemon, no scheduler, no DAG, no durability state machine; the registry records and compares, it never sequences or merges. Tests: registry round-trip (claim disjoint→both, claim overlap→refused, list/log/status/release) in `tests/test-hooks.sh`; structural + boundary guards (ADR exists, PHILOSOPHY reworded, lib executable, assign/start/dispatch wiring, kit-health carve-out) in `tests/test-meta.sh`. No new command ⇒ architecture inventory parity unchanged. Source: SPEC-036; ADR-0022; reuses SPEC-032 gate + SPEC-031 single-writer model.
- **Cross-goal concurrent dispatch built + proven (`/kit:dispatch`, SPEC-032 / ID-035).** The kit can now fire N independent `VALIDATED` specs concurrently, each in its own git worktree, then converge lead-owned. Five pieces landed: (1) **ADR-0019** supersedes the four standing "one session / sequential" boundaries with the bounded model (one lead orchestrating N isolated worktree workers behind a disjointness gate); `docs/PHILOSOPHY.md` (the four C1 boundaries + a "Shallow and wide is width, not a runtime" note) and `commands/kit-health.md` (a recorded fan-out carve-out) reworded so the conflict is settled, not silently broken. (2) **`lib/gate/dispatch-gate.sh`**, a new pure-bash home for command-helper logic: the **disjointness gate** (pairwise directory-prefix-glob overlap, conservative prove-or-serialize, undeclared-spec REJECT) + the **drift guard** (a worker's real diff must stay inside its declared globs and never touch a hands-off surface; hands-off list extracted from WORKFLOW.md, single-source). (3) A required-for-dispatch **`## Touches`** section in the spec template (`commands/spec.md`). (4) **`/kit:dispatch`**: fan-out via `Agent(run_in_background, isolation:worktree)` (ADR-0020 primitive), a wait-queue for overlapping specs, the worker blocker/signal contract (READY/BLOCKED/FAILED), and lead-owned convergence + worktree GC (unlock -> remove -> branch -D); no DAG, no auto-merge. (5) Registered across README, MANUAL, and the `docs/architecture.md` V-phase inventory (32 -> 33 entries, parity green). Tests: gate + drift behavioral cases in `tests/test-hooks.sh`, structural guards + the ADR/PHILOSOPHY/kit-health un-nerf in `tests/test-meta.sh` (meta 297 -> 304, hooks to 106). **Proven on a live run:** two disjoint demo specs dispatched concurrently into two isolated worktrees, each ran the kit task loop and committed conventionally, zero cross-write, drift-clean. That run also surfaced + fixed a real correctness bug: the drift base must be the worktree fork point (`git merge-base`), not a session-global `HEAD`, because `isolation:worktree` snapshots the lead's uncommitted state into each worktree. Intra-spec `/kit:execute` is unchanged (still sequential). Source: SPEC-032; ADR-0019/0020; SPEC-031 convergence.
- **Deterministic task-type -> risk-lane auto-classification (`lib/classify/lane-classify.sh`).** Encodes the `WORKFLOW.md` "Size the work first" lane triggers once (precedence backfill -> tiny -> full -> bug -> normal, "when in doubt, heavier"), wired into the intake path (`/kit:assign`) and the dispatch path (`/kit:dispatch`) so a lane is auto-chosen from the task description instead of ad-hoc judgment. Suggests, never dictates (Detect-don't-dictate). Verifiable on the three sample types (a doc fix -> tiny, a bug -> bug, a full feature -> full) plus normal + backfill, pinned in `tests/test-hooks.sh`; structural wiring guards in `tests/test-meta.sh`.
- **`/kit:verify`: on-demand read-only re-run of the V-model right arm (SPEC-035 / ADR-0021 / ID-038).** Re-dispatches `task-verifier` + `integration-checker` against the active spec/branch with no rebuild and no fix, printing a PASS/FAIL verdict. The on-demand executor of the right arm's unit + integration levels, for re-checking after a manual edit, a branch built elsewhere, or a read-only `/goal`-loop check. A command (not an agent) per the command-vs-agent rule; read-only (no `fix-agent`) like `/kit:review`; the integration base ref is the merge-base with the default branch (the C1 spec-validate fix). 3 new `tests/test-meta.sh` guards (exists + description; dispatches both agents; declares the read-only no-fix-agent invariant); architecture inventory 31 -> 32. The three rejected phantom commands (`/kit:accept`, `/kit:check-reqs`, `/kit:doc-spec`) stay rejected.
- **SPEC-029** (`docs/specs/SPEC-029-invocation-namespace-sweep.md`): the invocation-sweep spec, with the live-vs-historical scope split, the dual-ship invocation decision (DEC-001), and the denylist guard design (DEC-004..008).
- **SPEC-030** (`docs/specs/SPEC-030-namespace-sweep-fallout.md`): the install/hook sweep-fallout spec, with the per-surface invocation truth table, the hook-form decision (DEC-002: neutral slash-free phrasing for hooks, where SPEC-029 kept `/kit:` for docs), and the guard extension to runtime surfaces (DEC-003).
- **V-model lifecycle lens + lead-owned convergence contract (SPEC-031 / ID-034).** Frames the kit's cycle as a V (each define phase mirrored by its verify phase, build at the bottom) as a *lens over* the existing `WORKFLOW.md` cycle table, not a second table (ADR-0018). Adds to `WORKFLOW.md`: `## The V-model lens` (names every cycle phase + the two mirror gaps brief/requirement, covered today by ship-acceptance tracing the brief's pain + retro, no new command), a lane×phase depth matrix (5 lanes × 13 phases, each cell measure-twice/run-lite/skip), and `## Lead-owned convergence` (the enumerated hands-off shared-surface list workers must not write, integrated once by the lead via `/kit:ship`; the non-duplication clause delegates cross-task wiring to `integration-checker` and the shared write to `/kit:ship`). `docs/architecture.md` gains a command/agent → V-phase inventory (parity-tested). The "8 phases" hard count is reworded to count-agnostic "lifecycle phases" across the operating surfaces (`docs/PHILOSOPHY.md`, `commands/kit-health.md`) + the absorption-gate citations (SPEC-003/004/007), criterion #2's meaning preserved. 4 new `tests/test-meta.sh` guards (lens + convergence present, all cycle phases in the lens, hands-off ⊆ doc-impact map, inventory parity), hardened against a vacuous pass after review; meta suite 257 → 284. The hands-off list is the artifact SPEC-032's disjointness gate imports. Built + adversarially reviewed this cycle: `/kit:execute` caught a self-defeating acceptance criterion (the blanket 8-phases grep, scoped to operating surfaces via AMEND-001) and `/kit:review` caught a self-disabling-guard flaw in the new tests, both fixed. Source: SPEC-031 / ID-034.
- **Concurrent-workflow spec set.** `docs/specs/SPEC-032-concurrent-goal-dispatch.md` (ID-035): cross-goal `/kit:dispatch` fan-out + a file-disjointness gate + a post-task drift guard, the dispatch primitive locked to in-session worktree subagents by **ADR-0020** after a head-to-head bakeoff spike (SPEC-033) that proved the `claude agents` agent view is monitor-only. **SPEC-032 is now built** (see the `/kit:dispatch` entry above; all 10 tasks done). `docs/specs/SPEC-034-mega-goal-lane.md` (ID-037): the sequential/dependent `/kit:mega` complement, still queued (out of scope for the cross-goal dispatch work; sequential chains, not disjoint fan-out). Plus the V-model-gated decision brief and the parallelism research note. ADR block linearized 0017-0020.

## [1.6.0] - 2026-05-22

### Changed

- **Dropped hand-maintained component counts and stripped spec IDs from the WORKFLOW contract.** The exact `N hooks / N commands / N agents / N skill` strings are removed from every live surface (`.claude-plugin/{plugin,marketplace}.json`, `README.md`, `MANUAL.md`, `CLAUDE.md`, the `docs/architecture.md` component table, `tool.toml`) and replaced with qualitative phrasing; the `92`/`238` test-suite-total comments in `CLAUDE.md` are dropped too. Counts rot silently: this swept up live drift the guards never caught (`architecture.md` said 19 commands, `tool.toml` said 12 hooks / 18 commands / 9 agents). With nothing left to keep in sync, both count tests in `tests/test-meta.sh` are removed (the ID-013 component-count guard added earlier this cycle and the older command-count parity test); meta suite 238 -> 213. `WORKFLOW.md` no longer cites `SPEC-NNN`/`ADR-NNN` inline (the `docs/specs/SPEC-NNN-<slug>.md` filename pattern stays): rules are stated by concept with one provenance pointer to `docs/specs/` + `docs/decisions/`, and the count-sweep chore paragraph is replaced by a version-only note. SPEC-004 + SPEC-005 `Status:` reconciled VALIDATED -> SHIPPED (shipped alongside SPEC-006).

### Added

- **Release-hygiene guard: a warn on a phantom version cut (SPEC-028).** Closes the recurring messy-release state the SPEC-018 + SPEC-027 retros both flagged (`VERSION`/`plugin.json` cut to a version that was never tagged, with `[Unreleased]` piling on top). Two warn-only surfaces detect the **phantom cut** (`VERSION` names a version with no matching `git tag`), plus a soft heads-up when `[Unreleased]` is non-empty above it: a `/user:ship` Step-4a warn (at the version/tag decision) and a `commands/kit-health.md` check (run before tagging, repo-scoped, degrades to a no-op outside the repo). Warn-only, never blocks (Approach A; PHILOSOPHY reserves hard blocks for safety, and an untagged cut is a legitimate release transient, so a hard `tests/test-meta.sh` tag assertion was rejected). Both surfaces share one pinned check shape (whitespace-strip + `git tag -l "v$VER"` + a `git rev-parse --git-dir` degrade guard + the same `[Unreleased]` non-empty awk), pinned by 2 `tests/test-meta.sh` assertions (meta suite to 256). The verification pipeline earned its keep here: task-verifier caught one DEC-005 guard drift, the integration-checker caught a second, and `/user:review` caught a third (the soft accumulation-signal drift), all on the guard's own two copies (DEC-005/DEC-006). Source: SPEC-028 / ID-026.
- **Mid-flight spec amend: a declared path to add scope to a building spec without restarting the lane (SPEC-027).** Closes the `BUILDING -> SPECIFYING -> BUILDING` gap (operating-layer-vision Scenario 7): when a build reveals scope that must be added now ("also do Y"), the operator approves, then the spec is amended in place at a task checkpoint instead of being silently mutated or the lane restarted. Convention, not a new command or hook (Approach A; PHILOSOPHY "earn the abstraction"). Four invariants, canonical in `WORKFLOW.md` "## Mid-flight amend": no lane restart (`Status:` stays VALIDATED, only the delta re-validated), add-only (completed `- [x]` tasks frozen), recorded + operator-approved at a checkpoint (an optional on-demand `## Amendments` provenance section in the spec), resume with `/user:next` (not a fresh `/user:execute`). Projected into `docs/operating-layer-vision.md` §3.3 (the transition row) + §5 (gap closed), `commands/execute.md` (the no-silent-mutation anti-pattern now points at the amend path), `commands/spec.md` (the `## Amendments` template section), `docs/PLAYBOOK.md` Scenario 7 + `docs/ORCHESTRATION.md` 5.4 (operator projections), and pinned by 4 `tests/test-meta.sh` assertions (meta suite to 254). `/user:review` (HIGH) added the operator-approval gate the canonical rule had omitted (DEC-008). Source: SPEC-027 / ID-023.
- **Kit-root `AGENTS.md`: a tool-agnostic operate-contract front door (SPEC-024).** A portable, four-zone operating layer (the same shape any agent runner can read) that fronts the kit's behavioral contract; `CLAUDE.md` and `WORKFLOW.md` now point at it so the cycle and house rules have one neutral entry point instead of being CLAUDE-only. Ships a downstream template at `examples/hello-spec/AGENTS.md` so a consuming project starts with the same front door. Source: SPEC-024.
- **`backfill` brownfield lane (SPEC-024)**: an intake lane for adopting the kit into an existing repo (bring the operate-contract, specs convention, and guardrails onto code that predates them), recorded in `WORKFLOW.md` alongside the existing intake lanes.
- **Six-section goal projection in `/user:assign`**: the goal draft `/user:assign` writes now projects the backlog item across six fixed sections (Context-to-read / Constraints / Operating rules / Validation loop / Done-when / Pause-if) sourced from the `AGENTS.md` zones + the active spec, so a handed-off goal carries fuller context into its lane.
- **`## After state` section in the `/user:spec` template**: specs now scaffold the observable post-implementation end state, complementing the existing Verification / Open-questions stop-criteria.
- **doc-impact-map rows for `AGENTS.md` and the top-level files**: the WORKFLOW doc-impact map (reviewed by `/user:ship` + `/user:retro`) now lists `AGENTS.md` and a "new top-level file" trigger so a change that touches them is flagged for a doc update.
- **Regression coverage for the install settings-merge against a pre-existing third-party hook (test/guard, not a fix)**: `tests/test-meta.sh` gains a block asserting `install.sh`'s `settings.json` merge preserves an existing third-party hook entry. This is added coverage, not a bug fix: the current installer already unions third-party hooks correctly, so no installer change was needed. Plus review-driven anti-drift assertions (CLAUDE.md/WORKFLOW.md carry no read-order restatement) and hello-spec AGENTS.md zone pins. Meta suite to 241 asserts. Source: SPEC-024.
- **`/user:ui-design` command + the downstream UI-design loop (SPEC-020)**: writes a structured `## UI design` brief (aesthetic-direction preamble + layout + states matrix + named viewports + a11y bars + 3-tier token ladder + voice) into the active spec (else the pre-spec brief), delegates generation to the external `frontend-design` skill (the kit ships no renderer), critiques via `/user:visual-team`, and runs a bounded auto-revise loop (E6 `<user-feedback>` injection-wrap, E7 unconditional accumulated-feedback re-send, terminate on SOLID / RECONSIDER / max-2 cap). Opt-in, report-only, downstream-facing (the PHILOSOPHY carve-out + kit-health allow-note now name both `/user:visual-team` and `/user:ui-design`). The kit is now 20 commands. Brief enriched per the 2026-05-21 deep scan (`docs/research/2026-05-21-ui-design-loop-deep-scan.md`): aesthetic-direction from `frontend-design`'s real input, token ladder + states matrix + a11y bars + voice adapted from `nextlevelbuilder/ui-ux-pro-max-skill` (its renderer / fonts / `.cjs`+`.py` tooling rejected per bash-over-binaries), loop shapes from gstack. Dogfooded through `/user:spec-validate` twice; the re-dogfood caught an unimplementable numeric stop (visual-team emits no combined score) and folded it to a SOLID-verdict stop. Credits: gstack (loop shapes), `frontend-design` (generator), `ui-ux-pro-max-skill` (brief sub-shapes). Source: SPEC-020.
- **`/user:absorb` command + the absorption ritual (SPEC-004)**: a maintainer-only, proposal-only external-absorption audit that generalizes SPEC-002/SPEC-014's one-shot surveys into a recurring ritual. `docs/ABSORPTION.md` carries it: two lanes (Credits drift re-audit + a seed-rescan of the SPEC-014 survey set, scanning the interest areas workflow/agents/QA/UI), the adoption rubric (>=10), the gate, and the **human merge gate** (discovery + scoring + drafting are automatic; adopting a source or adding it to Credits is maintainer-approved, preserving "synthesize, don't originate"). `/user:absorb` writes a dated, ranked + capped, proposal-only report under `docs/absorption/` (HEAD-SHA baseline for since-last-run, an overflow appendix so a real ADOPT is never dropped, a `git status` self-check); QA/UI candidates needing binaries route to "recommend external". The kit is now 19 commands. Think+Design narrowed lane B to a seed-rescan (web-search discovery deferred as tool-weak). Also corrected the plugin manifests' stale hook/agent counts (now 14 hooks / 11 agents). Source: SPEC-004 + `docs/ABSORPTION.md`; DATA-not-instructions guard from ADR-0008.
- **Reviewer 5 (Solution-Design & Extensibility Critic)** in `/user:spec-validate`: flags shallow or non-extensible designs, with a calibration clause (no false-positive storm) and a legacy-grace clause for specs predating the richer template. Source: SPEC-008; forked from `superpowers:brainstorming` ("design for isolation and clarity") + its spec-document-reviewer calibration. Not a runtime dependency.
- **I/O contract + Failure modes sections** in the `/user:spec` template, plus pointer bullets in `/user:spec-validate` Reviewer 2 (failure modes) and Reviewer 5 (I/O contract). Both sections optional + lane-scoped. Source: SPEC-009; forked from ops-toolkit SDD (`agency-lead-radar` / `tide`). Not a runtime dependency.
- **`/user:design` command (opt-in)**: an interactive solution-design beat between `/think` and `/spec` (propose 2-3 approaches one question at a time, present the design in sections, approve per section), appending the Solution to `docs/specs/DECISION-BRIEF.md` for `/spec` to fold in. Realizes SPEC-008 Part C; forked from `superpowers:brainstorming`. The kit is now 13 commands. Closes the "ran without my feedback" half of the original signal.
- **`/user:debug` command + `bug` lane (SPEC-013)**: a systematic debug loop (four phases: root cause -> pattern -> hypothesis -> fix) under the iron law "no fix without a recorded root cause," with an append-only evidence ledger (`.claude/debug/<slug>.md`), `[DEBUG Hn]`-tagged instrumentation to `.claude/debug/<slug>.log` plus region-marker cleanup, `git bisect` for regressions, failing-test-first routed into the existing verification pipeline, and human-confirm before declaring fixed. `WORKFLOW.md` gains a `bug` intake lane and an off-cycle Debug row. The kit is now 14 commands. Forked from `superpowers:systematic-debugging` + GSD `gsd-debugger` (evidence ledger) + doraemonkeys debug-mode (tagged logs, region cleanup) + SuperClaude `/sc:troubleshoot`; classic lineage Agans ("9 Indispensable Rules") + Zeller (delta debugging). **ADR-0012** records the command+hook hybrid as a refinement of ADR-0008.
- **`.claude/goals/` draft-store contract + state model (SPEC-005)**: documents the kit's three-store state model (`_meta/BACKLOG.md` queue, `docs/specs/` contract, `.claude/goals/` ephemeral drafts) in `docs/architecture.md`, a formal Active-queue Schema in `_meta/BACKLOG.md`, and the goal-draft store beside the built-in `/goal` (the kit never writes `last-goal.md`; activator-agnostic with graceful degradation). **ADR-0011** records the draft-store-not-a-shadow decision. No `/user:goals` command yet (deferred to SPEC-006).
- **`/user:assign` command + the orchestration spine (SPEC-006)**: wires the backlog Active queue -> `/user:assign ID-NNN` (goal-crafts a `.claude/goals/` draft, picks the lane from the item, detects the activator, hands off to the lane's first command; never executes, never writes `last-goal.md`, idempotent per id) -> the WORKFLOW lane -> ship. `/user:start` + `/user:next` now render the queue + goal drafts read-only. `WORKFLOW.md` gains a `## The spine` section and two warn+log completeness clauses (decision-translation + doc-update) with a doc-impact map reviewed by `/user:ship` + `/user:retro`; PHILOSOPHY section 3 gains a bounded/unbounded loop note covering both the goal and debug loops. The kit is now 15 commands (also corrects `.claude-plugin/{plugin,marketplace}.json`, stale at 13). Source: SPEC-006.
- **Three opt-in design-assurance lanes (SPEC-016)**: `/user:devs-team` and `/user:visual-team` add parallel multi-lens critique of a design (in the decision brief or the active spec) before it hardens (the design analogue of `/user:review-team`), and `/user:test-plan` derives a test-case coverage matrix from a spec's acceptance criteria before `/user:execute`. Generic house-style lenses, inline parallel Task dispatch, report-only verdicts, no hard gate. `/user:visual-team` is downstream-facing (recorded PHILOSOPHY carve-out so kit-health does not flag it). The kit is now 18 commands. Lenses adapted from `zvadaadam/az-skills` devs-roundtable + design-roundtable, recast as generic lenses; test-plan is the kit's own coverage shape. Source: SPEC-016.
- **Two guardrail hooks (SPEC-014): `secrets-guard` + `commit-format`.** `secrets-guard` (PreToolUse Read\|Edit\|Bash) blocks reads of secret files (`.env`, `~/.ssh`, `~/.aws`, `.pem`, keychains), canonicalizing the path first so `~`/`$HOME`/`..` spellings cannot bypass; fail-closed on a match, fail-open on parse error; allows `.env.example`. The Read/Edit deny plus a new `settings.json` `permissions.deny` block is the primary layer; the Bash-surface check is best-effort defense-in-depth (a reader denylist is bypassable, stated honestly, not exfil-proof). `commit-format` (PreToolUse Bash) blocks a `git commit -m` subject that is non-conventional, >72 chars, or carries a SPEC-/TASK-/phase marker (subject only; bodies + editor commits pass). The kit is now 14 hooks. **ADR-0014.** Sources: Trail of Bits deny-list + claudekit `file-guard` (secrets); GSD `gsd-validate-commit` (commit-format).
- **`integration-checker` agent (SPEC-021)**: a read-only adversarial cross-task verifier dispatched once at `/user:execute` Step 4 for multi-task specs, filling the seam between per-task `task-verifier` and the once-at-end full suite (which silently passes when integration tests are absent). It verifies each new component reaches its activation point (a hook registered, a handler mounted, an export imported AND called) and the spec's stated end-to-end chains, without inventing links between independent tasks; scoped read-only tools (no write/bare-Bash, meta-asserted, DEC-006); diffs the whole build via a pre-build base ref; reuses fix-agent for fixable wiring gaps. The kit is now 10 agents. **ADR-0015.** Source: GSD `gsd-integration-checker`.
- **`doc-verifier` agent (SPEC-022)**: a read-only fact-checker dispatched by `/user:docs` at a new Step 4.5 (after it applies updates, before the commit) that independently verifies the just-updated docs against the live code (counts, command/flag names, file paths, existence, cross-references), closing the fox-guards-henhouse gap where `/docs` was the only reader of what `/docs` wrote. It reads the uncommitted doc diff, flags only checkable contradictions (not phrasing or prose), and reports; `/docs` re-edits a `FAIL:fixable` (max 2 rounds, not fix-agent, since `/docs` is not the `/execute` pipeline). Scoped read-only tools (meta-asserted). The kit is now 11 agents and has three read-only verifiers (task-verifier / integration-checker / doc-verifier), all on the ADR-0005 pattern; the retro should confirm the trio pays off. **ADR-0016.** Source: GSD `gsd-doc-verifier`.

### Changed

- **`/user:devs-team` + `/user:visual-team` aligned to spec-first placement (SPEC-023)**: both critique lanes now write their `## Design critique` / `## Visual critique` into the active spec when one exists (else the pre-spec brief; visual-team else inline), matching `/user:test-plan` (SPEC-018) and `/user:ui-design` (SPEC-020). Previously `devs-team` wrote brief-first and `visual-team` had no spec path, so the WORKFLOW.md placement rule was true for two lanes and waived for two; now all four share the spec-first head (visual-team keeps an inline tail since it alone can run with neither artifact). Both resolve the active spec via the shared SPEC-005 detection and ask on a multi-match; a meta-test pins the spec-first wording (both of devs-team's read and write sides). **Supersedes SPEC-016's `## Design critique` / `## Visual critique` placement.** WORKFLOW.md's two tables drop the "predates the rule" caveats. Source: SPEC-023; dogfooded through `/user:spec-validate` (the assumption-destroyer lens caught a draft that misread SPEC-020's writer model, corrected before implementation).
- **`/user:test-plan` writes into the spec + `/user:execute` consumes it (SPEC-018)**: the coverage matrix moves from a root `TEST-PLAN.md` to a `## Test plan` section appended into the active spec (mirroring `/user:devs-team`'s `## Design critique`), and `/user:execute` now reads that section, injecting each task's cases into the worker prompt and using each case's `proof` command as the per-step verify. Fixes the SPEC-016 Part B orphan (the plan was produced but never consumed) and makes the plan multi-spec safe (each spec carries its own). Adds a `proof` column to the matrix (behavior-to-proof, adapted from harness-experimental's `TEST_MATRIX.md` Evidence column); `proof` is `TBD` when unknown, never fabricated. The `## Test plan` heading is pinned in both `test-plan.md` and `execute.md` by a meta-test (drift guard). **Supersedes SPEC-016 Part B's root-file placement.** Source: SPEC-018; dogfooded through `/user:spec-validate` (1 critical caught: the wiring was lexical, not behavioral, now fixed).
- **`/user:spec` Solution template**: replaced the one-line `## Solution` block with scaffolded sub-sections (Approaches considered, Chosen approach + why, Extensibility & boundaries, Architecture) so specs carry design depth by default. Source: SPEC-008; forked from `superpowers:brainstorming` ("propose 2-3 approaches"). The opt-in `/user:design` interactive beat is deferred behind the PHILOSOPHY §5 bar.
- **`/user:spec` template stop-criteria (SPEC-012 Part 1)**: pinned `## Verification` (the command(s) that prove a spec done) and `## Open questions` (the blocker landing zone a `/goal` loop appends to), so any validated spec is natively pointer-`/goal`-ready. Part 2 (the QA gate around the loop) is held until the pointer-`/goal` pattern has real runs.
- **`tests/test-meta.sh`**: spec-authoring depth + contract assertions (3 Solution sub-headings + Reviewer 5 + the 5-reviewers header + a stale-"4 reviewer" drift guard, SPEC-008; the I/O contract + Failure modes headings, SPEC-009; a no-stray-`.planning/` guard + the demo-migration assertions, SPEC-010; commands/design.md presence, SPEC-011; the Verification + Open-questions headings, SPEC-012 P1). Suite total: 121 → 135.
- **Unified the spec-location convention onto `docs/specs/SPEC-NNN-<slug>.md`** for both the kit and downstream projects (was: downstream `.planning/SPEC.md`). The 5 spec-aware hooks resolve the active spec from `docs/specs/` (interim selector: highest non-SHIPPED/PARKED `SPEC-NNN`; SPEC-005 dual-detect refines later) with a bounded `.planning/` deprecation fallback (removed next minor). Satellite artifacts: research -> `docs/research/`, retro -> `docs/retro/`, CONTEXT -> `docs/specs/CONTEXT.md`, decision-brief folded into the spec. The demo (`examples/hello-spec`) migrated. **ADR-0010 supersedes ADR-0002.** Source: SPEC-010 Part 1 (Part 2 worktree-safety pending).
- **Spec detection is now branch-aware (SPEC-005)**: `context-readiness.sh`, `spec-drift-guard.sh`, `commands/next.md`, `commands/start.md` resolve the active spec among non-SHIPPED/PARKED `docs/specs/` specs by git-branch slug match, emitting `spec:ambiguous(...)` instead of silently picking when several are live (replaces SPEC-010's interim highest-NNN selector); `spec-drift-guard` greps the union of all active specs. The leakage sweep extends to `agents/` (research agents write `docs/research/`, not `.planning/research/`). SPEC-005 was reconciled to ADR-0010 (docs/specs-first; `.planning` is the deprecation fallback) since it predated SPEC-010. Tests: test-hooks 42 → 52 (10 detection fixtures), test-meta +4 (state-model + agents guard).
- **`/user:execute` worker step expansion (SPEC-017)**: each worker now expands its task into bite-sized "smallest verifiable increment -> verify -> commit" steps before coding (TDD when a unit test fits; grep/bash/test-suite verify for the kit's doc and config tasks), instead of a 3-bullet sketch. Worker-side (orchestrator stays lean), no new command, no new artifact; the task-verifier runtime gate is unchanged. Folds writing-plans-grade granularity into the kit's idiom. Source: SPEC-017.
- **`hooks/anti-rationalization.sh` gains a gated guess-fix guard (SPEC-013)**: blocks a premature fix/done claim ONLY when an open `.claude/debug/` ledger still has an empty `## Root cause`; silent in all non-debug sessions (~26ms, under the 500ms budget). The command<->hook contract (the `## Root cause` heading literal) is pinned in both files by a `tests/test-meta.sh` assertion so it cannot silently drift (DEC-010).
- **`tests/test-hooks.sh` + `tests/test-meta.sh` (SPEC-013)**: 3 hook behavior cases for the guess-fix guard (block when undiagnosed; allow once root cause recorded; dormant outside a debug session) and 13 meta assertions for the debug command structure, the DEC-010 cross-file `## Root cause` pin, and the WORKFLOW bug lane. Suite totals: hooks 52 → 55, meta 135 → 148.
- **`safety-gate.sh` + `anti-rationalization.sh` + `install.sh` (SPEC-014)**: `safety-gate` gains a build-artifact allowlist (a single `rm -rf node_modules/dist/.next/target/...` passes; compound commands still block) plus `DROP TABLE` / `git reset --hard` / `kubectl delete` blocks; `anti-rationalization` gains a phantom-implementation guard (a completion claim + an unimplemented-stub line such as `raise NotImplementedError` in the diff's added lines blocks, anchored so code that merely names the marker does not self-trigger); `install.sh` now unions `permissions.deny` on merge (was hooks-only). `tests/test-hooks.sh` adds 33 behavior cases and the hook-count assertion moves 12 → 14 (suite to 92 green); `test-meta.sh` parity auto-covers the two new hooks (178 green). A fresh-context code review caught and fixed three issues before merge: an `rm -rf node_modules/../..` traversal escape in the allowlist (now rejects any `..` token), a symlink bypass in secrets-guard (now resolves symlinks via `realpath` and matches both forms), and JSON-injection on a path containing a quote (now emits via `jq`). Sources: gstack `careful` (safety-gate), claudekit `self-review` (phantom-impl).

### Fixed

- **`context-readiness.sh` + `session-state-save.sh` count fragility**: `find ... | grep -v` and `grep -c ... || echo 0` both mishandled the zero-match case under `set -e`/pipefail. In a source-file-free repo the hook aborted with no output; a spec with 0 done tasks rendered `tasks:0\n0/N` plus an `integer expected` error. Now uses `{ grep -v ... || true; }` and `grep -c ... || true`. Found during SPEC-010 execution (ID-013).
- **`install.sh` never materialized the hooks `settings.json` references (SPEC-025)**: settings hard-code every hook (and the statusline) at `$HOME/.claude/dwarves-kit/hooks/<script>.sh`, but the bash installer only `chmod`'d the scripts at its own `$KIT_DIR/hooks/`, merged settings, and created `logs/`. That coincidence held only for the documented in-place clone (README Option 2: clone to `~/.claude/dwarves-kit`); from a dev checkout or CI clone elsewhere, `~/.claude/dwarves-kit/` got only `logs/` and all 14 hooks plus the statusline pointed at missing files, so a fresh session opened with `SessionStart ... No such file or directory` and every hook was silently dead. `install.sh` now links each `hooks/*.sh` into `~/.claude/dwarves-kit/hooks/` when the kit lives elsewhere (per-file symlinks, mirroring the existing `commands/` step, so dev edits stay live), detects the in-place layout and skips linking (a naive loop there deletes the real scripts and leaves broken self-referential symlinks, a regression the first cut shipped and the SDD pass then caught), and the uninstall removes only the symlinks it created. `tests/test-meta.sh` gains a 3-assertion guard (referenced scripts exist in `hooks/`; an isolated out-of-place install resolves every path; an in-place install keeps the scripts resolvable) so neither failure mode can regress past CI. Meta suite 213 -> 216.

## [1.6.0] - 2026-05-20

### Added

- **`WORKFLOW.md`** (repo root): the agent-facing workflow contract. Names each lifecycle phase, routes work by risk tier (tiny / normal / full), and points at the existing guardrail that enforces each boundary. Delivered via the `CLAUDE.md` pointer (auto-loaded each session); it suggests and routes, it does not block. Downstream template ships at `examples/hello-spec/WORKFLOW.md` (`.planning/` path convention). Source: SPEC-003; harness-experimental intake model + the AGENTS.md pattern.
- **`tests/test-review-team-plants.sh`**: behavioral regression guard for the `/review-team` security lens. Plants 3 known-bad fixtures under `$TMPDIR` (trap-cleaned, never in the repo) and asserts the security-review prompts still carry the detection vocabulary for each class; a term missing from both `security-auditor.md` and `reviewer.md` fails the build. Wired into CI. Source: superpowers v5.1.0 (SPEC-002 TASK-1).
- **Tiered `/user:start`**: `--brief` (one line, state + next command) and `--full` (SPEC task checklist, hook-log line counts, recent commits, phase-grouped command map) via `$ARGUMENTS`; default output is byte-for-byte unchanged. Source: GSD v1.43-rc2 (SPEC-002 TASK-3).
- **`tests/test-meta.sh`**: 6 assertions for the WORKFLOW.md contract (SPEC-003) plus a `model:` parity check on every agent, value in `{sonnet,haiku,opus}` (SPEC-002 TASK-2). Suite total: 104 → 120 (the extra check is the new CONTRIBUTING.md cross-link from TASK-5).

### Changed

- **`CLAUDE.md` Workflow section** (kit root + `examples/hello-spec/`): replaced the duplicated step list with a pointer to `WORKFLOW.md`, so the cycle lives in exactly one place.
- **`docs/PHILOSOPHY.md`**: reconciled the canonical lifecycle phase count to 8 (Think, Spec, Validate, Build, Review, Docs, Ship, Reflect; was 7 in one place and 9 in another), and added a "What we explicitly reject (from upstream observation)" section enumerating four audited anti-patterns (vendor-skill sprawl, UI-shell creep, agent-persona theater, slop-PR submissions). `CONTRIBUTING.md` and `commands/kit-health.md` cross-reference it, and the same 9→8 count fix was applied in both. Source: SPEC-002 TASK-5.
- **`README.md`, `MANUAL.md`, `docs/architecture.md`**: one-line cross-reference to `WORKFLOW.md` (the architecture pointer frames it as the imperative companion to the data-flow diagram).

### Fixed

- **OMC lineage correction**: the `task-verifier` pattern no longer claims the unverifiable "OMC" anchor. The README Credits bullet is removed and ADR-0005's Source line now owns the pattern as synthesized from the family of architect-verifier-in-Ralph-loop patterns. Source: SPEC-002 TASK-4 / DEC-003.

## [1.5.1] - 2026-04-21

Audit-fix release. Same-day patch following a retroactive `/review-team` and `/retro` that surfaced gaps in the v1.4/v1.5 SDLC application.

### Fixed

- **`plugin.json` version drift**: `.claude-plugin/plugin.json` was still declaring `1.4.0` after VERSION bumped to `1.5.0`. Now bumped to `1.5.1` and asserted by `tests/test-meta.sh` (parity check between VERSION and plugin manifest). The bug shipped briefly in v1.5.0; v1.5.0 tag is preserved in history.

### Added

- **`tests/test-meta.sh`**: 62 new assertions covering structural integrity that grep-only checks miss. Validates: plugin manifest schema (including version-matches-VERSION parity), hooks.json/settings.json hook count parity, all hooks.json paths use `${CLAUDE_PLUGIN_ROOT}`, every agent/command markdown file has YAML frontmatter with required fields, CLAUDE.md Subagents list bidirectionally matches `agents/*.md`, demo project files have all required template sections, workflow has explicit permissions block, CONTRIBUTING.md cross-links resolve. Test suite total: 42 → 104.
- **CI hardening**: workflow now runs `tests/test-meta.sh` alongside `tests/test-hooks.sh`. `actions/checkout` pinned to release SHA (supply-chain best practice). Explicit `permissions: contents: read` (least privilege).
- **`docs/retro/v1.3-v1.5.md`**: cycle retrospective covering what worked, what hurt, action items. First retro since the kit started; addresses the action item to make `/retro` part of the release ritual.

### Changed

- **README "Project structure" section**: replaced the embedded file tree (drifted across 5 releases, last accurate at v1.0) with a concise top-level overview pointing at `git ls-files` for the canonical listing. Removes a recurring drift surface.
- **README "Changelog" section**: removed the duplicated highlight bullets (last updated at v1.2.0). CHANGELOG.md is now sole source of truth for version history.
- **README "v2 roadmap"**: removed "Plugin marketplace packaging" (shipped in v1.4); added "Multi-harness packaging" deferred line.
- **`examples/hello-spec/README.md`**: added a one-line synthetic-demo disclaimer at the bottom (the `spm` package is fictional; the file shapes are real).

## [1.5.0] - 2026-04-21

### Added

- **GitHub Actions CI** (`.github/workflows/test.yml`): runs `bash tests/test-hooks.sh` on push to `master` and on every PR. Matrix: macOS + Ubuntu. Also validates all JSON files (`plugin.json`, `marketplace.json`, `hooks.json`, `settings.json`) parse cleanly.
- **CI status badge in README** (top of file alongside version, license, Claude Code plugin badges).
- **README hero section**: tagline, badge row, value prop, "Who this is for" / "Who this is NOT for" sections, prominent plugin install command. First-screen visible to anyone landing on the repo.
- **Demo project at `examples/hello-spec/`**: small self-contained walkthrough showing real `CLAUDE.md`, `.planning/SPEC.md`, and a README that explains how the kit picks each file up. Demo subject: a Python CLI's `--version` flag.
- **`CONTRIBUTING.md`** at repo root: rejection-first voice (adapted from superpowers v5.0.7 AGENTS.md, same source as v1.3 kit-health). Numbered MUST list before opening a PR. "What we will not accept" enumerates PHILOSOPHY.md's actual rejection criteria with cross-links.

### Notes

- All changes are additive. No breaking changes. No removals.
- No new ADR: every change fits within existing principles. PHILOSOPHY.md unchanged.
- README's component count line updated to "9 agents" (was "8"); tracks the `responding-to-review` agent added in v1.3.
- CI is **descriptive**, not enforcing: PRs that fail CI are flagged but not auto-blocked. Enforcement still lives in the `safety-gate` hook locally.

## [1.4.0] - 2026-04-21

### Added

- **Claude Code plugin packaging**: Kit now installs via `/plugin marketplace add dwarvesf/dwarves-kit` + `/plugin install dwarves-kit@dwarves-marketplace`. No `git clone`, no bash, no `jq` required. Updates via `/plugin update dwarves-kit`.
- **`.claude-plugin/plugin.json`**: Plugin manifest with name, version, description, author, homepage, repository, keywords. Auto-discovers `agents/`, `commands/`, `skills/` directories.
- **`.claude-plugin/marketplace.json`**: Self-hosted marketplace manifest. Single-plugin marketplace named `dwarves-marketplace` pointing at the repo root.
- **`hooks/hooks.json`**: Plugin-format hook registration. Same 12 hooks across 8 event types as the bash install path. Uses `${CLAUDE_PLUGIN_ROOT}` for path-portable script references.
- **README dual install section**: Plugin install presented first as recommended path. Bash install retained as alternative for CI / older Claude Code versions / non-plugin contexts. One-line note about Anthropic official marketplace submission via https://claude.ai/settings/plugins/submit.

### Changed

- **`docs/decisions.md`**: Added ADR-009 documenting the dual-ship deviation from PHILOSOPHY's "Replace, don't deprecate" with explicit rationale and sunset trigger.

### Notes

- This is an additive release. The bash installer (`install.sh`) and root `settings.json` are unchanged. Existing installs continue to work without action.
- **Do not run both install paths on the same machine.** Hooks would register twice. Pick one.
- Plugin install does not configure `statusLine` (not in v1 plugin schema). Use the bash install if you want the statusline HUD.

## [1.3.0] - 2026-04-21

### Added

- **`responding-to-review` agent**: New subagent that responds to code review findings with verify-before-implement, no performative agreement, YAGNI check, and push-back-when-wrong. Wired into `/review-team` Step 5 so the FIX-THEN-SHIP path can dispatch it. Source: superpowers v5.0.7 `skills/receiving-code-review/SKILL.md`, adapted from a Skill (auto-discovered) to a custom subagent (dispatched on demand).
- **`task-verifier` "Extra / unneeded work" check (Section 3b)**: Verifier now explicitly checks whether the worker built features that weren't requested, over-engineered, or added nice-to-haves outside the spec. Distinct from the existing file-scope check. Source: superpowers v5.0.7 `skills/subagent-driven-development/spec-reviewer-prompt.md`.
- **`reviewer` (architecture lens) decomposition + contribution checks**: New bullets for "decomposed for independent testability" and "what this change contributed (don't flag pre-existing file size)". Source: superpowers v5.0.7 `skills/subagent-driven-development/code-quality-reviewer-prompt.md`.
- **`commands/kit-health` rejection-first verdict**: Output template now produces `SHIP / FIX-REQUIRED / REJECT` verdicts with explicit gate rules. New Step 4 "What this kit will reject" section enumerates 10 auto-REJECT conditions grounded in PHILOSOPHY.md. Source framing: superpowers v5.0.7 `AGENTS.md` "What We Will Not Accept".

### Changed

- **`task-verifier` Rules**: Added "Verify by reading code, not by trusting the worker's report" as the first rule. Source: superpowers v5.0.7 spec-reviewer-prompt.
- **`commands/review-team` Step 5**: FIX-THEN-SHIP path now suggests dispatching `responding-to-review` to handle the findings without performative agreement.
- **`CLAUDE.md`**: Added `responding-to-review` to the Subagents inventory.
- **`docs/decisions.md`**: Added ADR-008 covering the superpowers v5.0.7 adoption.

### Fixed

- **`tests/test-hooks.sh`**: Stale assertion `expected 10 event hooks` updated to `12` to match actual settings.json count (drift since v1.2 added SubagentStop and StatusLine entries). Test suite now reports 42/42 instead of 41/42.

## [1.2.0] - 2026-03-30

### Added

- **Verification pipeline**: /execute now runs worker > task-verifier > fix-agent retry loop (max 2) for every task. No task is accepted without verification.
- **8 custom agents**: task-verifier (read-only verification), fix-agent (targeted fixes), reviewer (configurable lens), security-auditor (OWASP audit), research-stack, research-features, research-architecture, research-pitfalls (4 parallel brownfield researchers).
- **/start command**: entry point router that detects project state and suggests next command. Source: CCGS /start.
- **/review-team command**: parallel 3-lens review dispatching security + architecture + test-coverage reviewers simultaneously.
- **session-state-save.sh** (Stop + SubagentStop): persists session state to `.claude/session-state/`, rotates last 10 archives. Fail-open.
- **docs/COLLABORATIVE-DESIGN.md**: shared protocol for structured decision-making (Question > Options > Recommendation > Decision > Record).
- **SubagentStop event** in settings.json for session-state-save.

### Changed

- **/execute**: complete rewrite with verification pipeline, Collaborative Design Protocol integration, codebase-memory-mcp awareness.
- **/ship**: added review gate (checks REVIEW.md verdict), version bump detection, automatic changelog entry generation.
- **/spec**: added 4 parallel research subagents for brownfield projects (Mode A: formal agents, Mode B: inline fallback).
- **/spec-validate**: enhanced Scope Critic with aggressive atomicity check, dependency declaration checking, testability criteria.
- **context-readiness.sh**: v2 upgrade. Reads spec status, counts completed tasks, suggests next command ("detect, don't dictate").
- **install.sh**: added agents install/uninstall, path-scoped rules auto-copy to `.claude/rules/`.
- **PHILOSOPHY.md**: added "Verify before proceeding" and "Verify, then trust" principles. Updated version strategy.
- **rules/*.md**: YAML `paths` changed to multi-line list format.

## [1.1.0] - 2026-03-30

### Security

- **permission-auto-approve**: reject commands with pipes, chains, subshells (`|`, `&&`, `;`, `$()`, backticks) before checking whitelist. Prevents injection via chained commands.

### Fixed

- **anti-rationalization**: trimmed from 13 to 5 patterns. Removed 8 false-positive-prone phrases ("out of scope", "pre-existing", "we can revisit", "a future improvement", "for now, this should", "beyond the scope", "outside the current task", "I'll leave that for").
- **auto-format**: no more `npx --yes` network downloads per edit. Detection order: project-local binary > global binary > npx cache only (`npx --no`).
- **install.sh**: fixed jq merge logic that silently replaced user's existing hooks. Now removes dwarves-kit hooks first (idempotent), then concatenates arrays. Backs up settings.json before every modify.
- **context-readiness**: reduced context noise. Only outputs warnings and compact state (branch, dirty count). Healthy project = empty JSON = zero context cost.
- **spec-drift-guard**: shortened warning message, added `.claude/` to skip list.

### Added

- **statusline.sh** (StatusLine): shows `[model] branch | ctx:XX%! | $cost | think:on/off`. Context warning at 60% (`!`) and 80% (`!!`). Bash-only.
- **slop-cleaner.sh** (Stop hook): checks recently modified files for functions >50 lines, deep nesting >4 levels, files >300 lines, duplicate code blocks. Nudge only, never blocks.
- **kit-health command**: self-assessment against PHILOSOPHY.md principles. Checks file count, hook performance, settings validity, source citations, structural health.
- **rules/backend-go.md**: Go backend conventions template (path-scoped rules).
- **rules/frontend-ts.md**: TypeScript frontend conventions template (path-scoped rules).
- **tests/test-hooks.sh**: automated test suite (40+ cases) covering safety-gate, anti-rationalization, permission-auto-approve, auto-format, context-readiness, slop-cleaner, statusline.
- **Hook logging**: safety-gate, spec-drift-guard, slop-cleaner now log decisions to `~/.claude/dwarves-kit/logs/`.
- **Debug mode**: `DWARVES_KIT_DEBUG=1` makes all hooks log to stderr.
- **install.sh --uninstall**: clean removal of hooks, commands, skills from settings.json.

### Changed

- File budget: replaced hard 35-file cap with "every file must justify its existence" rule in PHILOSOPHY.md.
- README: added v1.1 changelog section, testing instructions, debug mode docs, hook log docs, known limitations.
- PHILOSOPHY.md: added indirect lineage documentation, expanded "NOT cover" section for parallel execution.
- v1.1-handoff.md: rewritten from build spec to post-build handoff document.

## [1.0.0] - 2026-03-29

Initial release. 9 hooks + 9 commands + 1 skill.

### Hooks
- safety-gate (PreToolUse): blocks rm -rf, push to main, force push
- context-readiness (SessionStart): project status injection
- anti-rationalization (Stop): catches incomplete work rationalization
- auto-format (PostToolUse): runs formatter on file changes
- spec-drift-guard (PreToolUse): warns on unplanned files
- pre-compact-backup (PreCompact): saves session snapshot
- post-compact-reinject (PostToolUse): re-injects rules after compaction
- notification (Notification): desktop alert when Claude needs input
- permission-auto-approve (PermissionRequest): auto-approves read-only operations

### Commands
- /user:think, /user:spec, /user:spec-validate, /user:execute, /user:next
- /user:review, /user:docs, /user:ship, /user:retro

### Other
- settings.json with all hooks registered
- CLAUDE.md project template with Trail of Bits quality rules
- install.sh idempotent installer
- skills/get-api-docs Context Hub integration
- docs/PHILOSOPHY.md design principles
