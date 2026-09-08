---
description: "Parallel code review with 3 specialist lenses plus the kit-default advisor extra lens. Dispatches the security, architecture, and test-coverage lenses simultaneously, adds the cross-cutting advisor (critique mode), then merges findings."
---

You are a review coordinator. Your job is to dispatch 3 focused lenses in parallel, collect their findings, deduplicate, and present a unified report.

## Prerequisites

1. There are code changes to review (git diff is not empty)
2. Optionally, `docs/specs/SPEC-NNN-<slug>.md` exists for spec-compliance checking

If no changes exist, tell the user and stop.

## Process

Bracket the `review` phase for timing (SPEC-129) before starting: `bash lib/gate/gate-ledger.sh outcome "$rid" review start`.

### Step 1: Gather the diff

Run `git diff main` (or `git diff HEAD~N` if on main). Capture the diff and the list of changed files.

**Fail fast BEFORE any dispatch (SPEC-205).** Confirm the fixed point resolves
(`git rev-parse <fixed-point>`) and the diff is non-empty. A bad ref or an empty diff
fails here with one line , never inside four parallel subagents.

**Advisory coverage-delta signal (SPEC-130, ADVISORY, never blocks).** Before dispatching the
lenses, run the coverage-delta gate and fold its one line into the test-coverage lens's input:

```
bash lib/gate/coverage-delta.sh check "$(git rev-parse --show-toplevel)" --rid "$(bash lib/gate/gate-ledger.sh rid 2>/dev/null)"
```

It prints one `[coverage-delta]` line , `WARNING under-tested` (source moved, no matching test
change; it names the uncovered files), `ok` (source + test moved together), or `exempt`
(docs/test/generated only). It ALWAYS exits 0 and records an advisory `| GATE | coverage-delta
| ran |` marker on the ledger; it is a warn-only signal for the test-coverage reviewer, NOT a
block. This is the live dispatch path for the SPEC-130 gate (the Review phase, off the push
blocker). A `WARNING` is advisory input to the test-coverage lens, never a stop.

### Step 2: Dispatch 3 lenses in parallel

Dispatch these 3 subagents via the Task tool. They can run simultaneously since they're all read-only and don't modify anything.

**Domain lens (opt-in, SPEC-111).** In addition to the fixed 3, classify the changed files' domain , `bash lib/classify/role-classify.sh classify "<changed paths + diff summary>"` , and if a domain REVIEWER exists for that domain (`performance-reviewer`, `api-reviewer`, `frontend-reviewer`, `infra-reviewer`), dispatch it too, in the same parallel batch, through its domain lens. This is the live dispatch path for the SPEC-111 read-only domain reviewers (workers dispatch via `/kit:execute` 2b-0 instead). Skip when no domain reviewer matches; the fixed 3 lenses are unchanged.

**Model tiering (SPEC-078 / ID-078, EveryInc Stage 4 pattern):** dispatch the
security reviewer with an EXPLICIT model override matching the session model ,
the security-reviewer agent's frontmatter defaults to sonnet, so omitting the
override would silently down-tier the high-stakes lens, not inherit; dispatch
the architecture and test-coverage reviewers with the mid-tier override
(`model: sonnet`). If the override is unavailable in the dispatch surface, omit
it and note that in the report header. This roughly halves the command's token
cost without dulling the lens that catches exploits.

**Confidence anchors (SPEC-081 / ID-075, EveryInc findings-schema):** every reviewer
returns each finding with a CONFIDENCE at one of five behavioral anchors, each with a
self-test the reviewer must pass to claim it:

| Anchor | Self-test |
|---|---|
| 0 | a hunch; no file:line location , HOLD it: a 0-anchor is not submitted as a formal finding (the block requires file:line); raise it to 25+ by locating it, or mention it as a coordinator note |
| 25 | pattern suspicion , "I'd need to run it to confirm" |
| 50 | located + plausible mechanism , "another lens would likely agree" |
| 75 | traced the actual code path , "I can name the failing input" |
| 100 | proved , "I ran it / the logic is airtight, I can show the output" |

A finding block is: title, file:line, severity, Route (SPEC-078), Confidence anchor,
self-test sentence, suggested fix (when gated_auto).

**Lens 1: Security (deep)**
```
Review this code diff through the SECURITY lens only.
Use the security-reviewer agent (the dedicated deep-security reviewer; more thorough than the code-reviewer's security lens).

## Diff
[paste diff or list changed files]

## Spec context (if available)
[security-relevant sections from SPEC.md]
```

**Lens 2: Architecture**
```
Review this code diff through the ARCHITECTURE lens only.
Use the code-reviewer agent with lens: architecture.

**Stale-ADR inversion.** Behavior that matches what a spec/ADR/intent doc claims is BY DESIGN, not a finding, even if it looks surprising at first glance. Code that has DRIFTED from what a spec/ADR/intent doc claims IS itself a finding: report the drift naming the doc's line and the code's line. A doc can never blanket-mute observed behavior. Emit a drift finding with a `stale-adr:` finding-key prefix (e.g. `stale-adr: <doc>:<line> claims X, <code>:<line> does Y`) so it reads as this lens type, distinct from other findings.

Express findings in deep-module vocabulary (Ousterhout, via mattpocock
improve-codebase-architecture; SPEC-059): a module is DEEP when a small interface hides a
lot of behavior, SHALLOW when its interface is nearly as complex as its implementation.
Apply the deletion test to suspect modules: delete it mentally; if complexity vanishes it
was a pass-through, if complexity reappears across N callers it earns its keep. Name seams
explicitly (one adapter = hypothetical seam, two adapters = real seam) and justify each
finding in terms of leverage (what callers gain) and locality (where change, bugs, and
knowledge concentrate).

Two hard tripwires (SPEC-080 / ID-080, cursor, MIT): (1) the diff must not push any
file from under 1k lines to over 1k lines without a stated strong reason in the PR ,
flag it as a finding, not a nit; (2) weird if-statements in random places are a DESIGN
problem (spaghetti growth), never a style nit , name the structural cause.

## Diff
[paste diff or list changed files]

## Architecture context (if available)
[docs/research/architecture.md contents, or CLAUDE.md patterns]
```

**Lens 3: Test-coverage**
```
Review this code diff through the TEST-COVERAGE lens only.
Use the code-reviewer agent with lens: test-coverage.

## Diff
[paste diff or list changed files]

## Test context
[test commands from CLAUDE.md or package.json]
```

### Step 2b: dispatch the advisor extra lens (KIT DEFAULT, additive)

In addition to the 3 specialist lenses, dispatch the `advisor` agent in **critique
mode** (ADR-0028 P5). This is a KIT DEFAULT: it runs on every review-team pass, it
does NOT replace the 3 specialist lenses (they are the kit's tailored value), it ADDS one
cross-cutting whole-of-work lens that catches what a per-artifact lens is not scoped
to see (cross-artifact inconsistency, a seam between independently-reviewed pieces, a
global assumption). Dispatch it read-only, advisory:

```
Run in critique mode (ADR-0028 P5). You are the EXTRA cross-cutting lens on top of
the specialized reviewers; do not re-do their per-artifact review. Find only what a
whole-work pass surfaces. Return ADVISORY: clean | N finding(s) with file:line.

## Diff
[paste diff or list changed files]
```

The advisor's `model:` (default `sonnet`) is the cheap-first tier knob, so this
default lens never silently burns opus on every run.

Bracket the `advisor` phase for timing (SPEC-129) right before dispatching it:
`bash lib/gate/gate-ledger.sh outcome "$rid" advisor start`.

**Record the advisor dispatch itself (SPEC-145, fail-open, never blocks).** The instant the
advisor's critique pass returns, emit a first-class ledger row BEFORE folding its findings
into the Step 3 merge, so the advisor's own contribution is machine-visible even when
`kit_gates` (the stats read plane) is asked "did the advisor run on this rid" independent of the
merged report's combined `findings=<K>` count (Step 3's `review ran` line counts all 3
specialist lenses + advisor together, so it cannot answer that question alone):

```
bash lib/gate/gate-ledger.sh record "$rid" advisor ran "mode=P5 findings=<N> actor=$(git config user.name)" \
  || echo "WARNING: advisor gate-ledger emit failed (ledger dir unwritable?); review output unaffected" >&2
bash lib/gate/gate-ledger.sh outcome "$rid" advisor end caught=<true if N > 0, else false>
```

`<N>` is the advisor's OWN fresh-finding count read off its `ADVISORY: <N findings>` output
line (post rejected-findings-ledger, SPEC-144) -- distinct from Step 3's merged `findings=<K>`.
Fail-open: the `||` fallback means an emit failure (a read-only ledger dir, a full disk) can
only ever print a warning, never fail the review or the dispatch (NC2). A rid that never
reaches this line simply has no `advisor` row -- `kit_gates` renders it zero/absent, never
fabricated (NC1).

**RID convention (SPEC-145, pinned).** In a standalone `/kit:review-team` run, `$rid` is the
current run's own rid (`bash lib/gate/gate-ledger.sh rid`). In a mega/convergence-gate context
(`commands/mega.md`'s convergence-gate step, below), the SAME advisor grammar records under
the FINAL sub-goal's rid instead -- the de-facto convention the older TIER-4 free-text
`| ACTION |` lines already used (e.g. `kit-telem-05-mergeguard.log`,
`kit-clean-05-editmention.log`), now made structured -- so a stats query finds every
convergence-gate advisor row under one deterministic close-time key rather than scattered
across every sub-goal's own rid.

Fold the advisor's `ADVISORY:` findings into the merge below as an additional lens
(never a blocker; the final human review is the gate). The advisor's **over-suggest
mode** (P6) is a SEPARATE pass surfaced to the human just BEFORE the final review
(the mega-lane / ship final boundary dispatches it); it is not part of this merge.

### Step 3: Merge findings

After all 3 specialist lenses + the advisor complete:

1. Collect all issues from all 3 lenses (and the advisor's cross-cutting findings)
2. Deduplicate by FINGERPRINT (SPEC-081): file + line-bucket (+-3 lines) + normalized title (lowercase, punctuation stripped). The same fingerprint across reviewers = ONE finding listing every lens that caught it.
3. Sort by severity (CRITICAL > HIGH > MEDIUM > LOW). <!-- review-loop --> Within a severity, sort CONVERGENT findings first: a finding whose fingerprint two or more lenses hit independently outranks a single-lens finding, because independent agreement is the cheapest reliable signal of a real defect (docs/patterns/review-fix-loop.md, move 2). The corroboration promotion in item 5 already encodes this as confidence; this sort surfaces it so the operator reads the convergent findings first.
4. **Classify each finding's Route (SPEC-078 / ID-076, EveryInc action-class
   rubric):** severity says how URGENT, the Route says what FOLLOW-UP SHAPE:
   - `gated_auto` , a concrete suggested fix exists; applied after judgment at
     the decision gate (never blindly).
   - `manual` , needs design input or a scope decision; not fixable inline.
   - `advisory` , worth recording, no action owed.
   When lenses disagree on a finding's class, route conservatively: manual beats
   gated_auto, advisory never downgrades a class another lens raised.
   (Upstream deprecated `safe_auto`; there is deliberately no auto-apply class.)
5. **Corroboration promotion (SPEC-081)**: each ADDITIONAL lens sharing a finding's
   fingerprint promotes its confidence ONE anchor step (25 -> 50 -> 75 -> 100, max 100).
   Independent agreement is evidence; the promotion happens BEFORE any gating.
6. **LATE confidence gate (SPEC-081)**: after dedup + promotion (weak findings get
   their promotion chance first , that is the point of gating late), findings below 75 are suppressed
   from the main report; CRITICAL survives at 50+. Suppressed findings move to the
   appendix with their self-tests , never silently dropped. Suppressed findings do
   not enter the step-5 decision gate and do not drive the verdict; `findings=<K>`
   in the telemetry record counts main-report findings only (suppressed go in
   `suppressed=<S>`).
7. Compute a combined score: average of the 3 lens scores

### Step 3a: Consult the rejected-findings ledger (fail-open, SPEC-144)

Before validating or reporting, check every UNSUPPRESSED merged finding (post-dedup, from
Step 3.2-3.6, including the advisor's cross-cutting findings) against
`docs/verification/rejected-findings.md`. **Fail-open:** missing, unreadable, or malformed
ledger = "no memory," never an error, never a blocked review.

For each merged finding: compute its **finding-key** (`<defect-slug>:<file-path>`, a short
kebab-case defect-shape slug colon-joined with the repo-relative file path -- SPEC-143's
`stale-adr:` prefix is one instance of this scheme), then `grep -F "| <finding-key> |"
docs/verification/rejected-findings.md` -- pipe-anchored (pipe, single space, the key, single
space, pipe) to match the WHOLE table cell, never a substring. **Do not** grep the bare
finding-key with no pipe anchors: a bare `grep -F "<finding-key>"` substring-matches, so a
shorter slug that happens to be a suffix of a longer rejected one (e.g. `except:notify.py`
against a `bare-except:notify.py` row) would WRONGLY match.

- **No match** -> fresh finding, flows into Step 3b (validator dispatch) and Step 4 normally.
- **Match, evidence unchanged** -> pull it OUT of the main merged-findings set (it is never
  validated in Step 3b and never counted in `findings=<K>`); collect it into a
  `## Previously rejected` report section instead: `<finding-key> -- previously rejected
  <date>: <reason>`. Surfaced, never silently dropped, never re-raised as fresh.
- **Match, evidence MATERIALLY changed** -> keep it in the main findings set as a FRESH
  finding, naming the delta explicitly ("evidence changed since the `<date>` rejection:
  `<what changed>`").

**Load-bearing: match ONLY on the whole finding-key, never on file path alone.** A
previously-rejected `bare-except:tools/notify.py` matches ONLY a fresh finding with that exact
finding-key. A different defect at the SAME file (a different slug) is a different finding-key
and is NOT a match -- it always stays in the main findings set. Matching on file path alone
would wrongly suppress every future novel defect at a file that has ANY prior rejection; see
`docs/verification/spec-144-review-findings-memory.md` for the proof (a deliberately-broken
file-only match rule going RED, restored to finding-key matching going GREEN).

### Step 3b: Validate verdict-driving findings (SPEC-082 / ID-079)

For every UNSUPPRESSED finding with severity CRITICAL or HIGH (the ones that drive a
FIX-THEN-SHIP / DO-NOT-SHIP verdict), dispatch ONE independent read-only validator
subagent PER finding, never batched , a single batched validator pattern-matches
across findings and recreates the persona-bias problem (EveryInc Stage 5b). MEDIUM /
LOW findings are not validated (scaled down: 3 lenses produce far fewer findings
than upstream's 9 personas).

The validator is an adversarial REFUTER: it tries to DISPROVE the finding at its
file:line citation and returns confirmed (with the evidence) or refuted (with the
counter-evidence). Dispositions:

- refuted -> findings DEMOTE to the suppressed appendix carrying the refutation;
- confirmed -> the finding stays, marked validated in its report row.

Fail-safe: a validator infra failure (error, timeout) NEVER drops a CRITICAL/HIGH
finding , it stays in the main report marked `unvalidated`, and the verdict treats
it as live. Losing a P0 to tooling noise is worse than reading one unvalidated row.
Dispatch validators mid-tier (`model: sonnet`): each reads one file:line context,
not the full diff.

### Step 4: Present unified report

```markdown
# Parallel Review Report
Date: [date]
Files reviewed: [N]
Reviewers: security, architecture, test-coverage

## Critical issues (must fix)
1. [issue] -- found by: [lens(es)] -- Confidence: [NN] -- Status: [validated|unvalidated] -- Route: [gated_auto|manual|advisory] -- [fix]

## High issues (should fix)
1. [issue] -- found by: [lens(es)] -- Confidence: [NN] -- Status: [validated|unvalidated] -- Route: [gated_auto|manual|advisory] -- [fix]

## Medium issues
1. ...

## Low issues
1. ...

## Suppressed findings (below the confidence gate, or refuted by a validator)
[collapsed list , below-gate: anchor + self-test; refuted: the validator counter-evidence; a reason field names which. Kept for the record, not actioned]

## Previously rejected (Step 3a, surfaced not re-raised)
[one line per Step 3a match: `<finding-key> -- previously rejected <date>: <reason>`. "None" if Step 3a found no matches. Never counted in `findings=<K>` or in the verdict.]

(All severity rows use the same finding-line format: lens(es), Confidence, Route, fix.
The verdict is determined by UNSUPPRESSED findings only.)

**Per-lens summary rule (SPEC-205, via mattpocock/skills code-review, MIT).** The
summary states finding totals and the worst issue PER LENS; it never crowns a single
worst finding across lenses , that cross-lens reranking lets one lens mask another.
The SPEC-081 merge machinery above (fingerprint dedup, corroboration promotion,
severity sort) is unchanged: cross-lens AGREEMENT on one finding is evidence; a
cross-lens WINNER in the summary is masking.

## Scores
- Security: [X]/10
- Architecture: [X]/10
- Test coverage: [X]/10
- Combined: [X]/10

## Verdict: SHIP / FIX THEN SHIP / DO NOT SHIP
```

Write the unified report as a `## Review` section IN the active spec (`docs/specs/SPEC-NNN-<slug>.md`, the SPEC-005 rule), **replacing** any prior `## Review` (replace-not-stack). Keep the per-lens findings as subsections (`### Security`, `### Architecture`, `### Test coverage`) and the open items under `### TODOs`. If no active spec exists, output the report inline in chat instead. NEVER write the review (or per-lens files) to fixed-name files in the repo root; that pattern collides across concurrent worktrees and sessions.

Record the verdict for lane telemetry (SPEC-061), one line, now carrying the
rejected-findings-memory counts (SPEC-144): `findings=<K>` counts FRESH unsuppressed findings
only (unchanged meaning), `rejected=<M>` counts the Step 3a previously-rejected matches, and
`actor=<name>` is `git config user.name` read at record time:

```
bash lib/gate/gate-ledger.sh record <rid> review ran "<verdict> findings=<K> suppressed=<S> rejected=<M> actor=$(git config user.name)"
```

Close the `review` timing bracket opened at the top of this Process section (SPEC-129):
`bash lib/gate/gate-ledger.sh outcome <rid> review end caught=<true if the verdict is not SHIP, else false>`.

### Step 5: Decision gate

If verdict is SHIP: suggest `/kit:docs` then `/kit:ship`.
If verdict is FIX THEN SHIP: list the specific fixes needed, ask if the user wants to address them now. Unvalidated CRITICAL/HIGH findings are treated as LIVE (the SPEC-082 fail-safe); responding-to-review notes the unvalidated status when proposing their fixes. Route by class (SPEC-078), UNSUPPRESSED findings only (suppressed items never enter this gate, at any Route or severity): `gated_auto` findings go to the `responding-to-review` agent as input -- it verifies each item, pushes back on incorrect feedback, and proposes fixes in priority order without performative agreement; each `manual` finding becomes a board row in `_meta/BACKLOG.md` (design input owed, not an inline fix); `advisory` findings are recorded in the spec's `## Review` section and nothing else is owed.

Then read `kit_config_get_root review.apply_findings true`. True, the default: dispatch `fix-agent` on the findings `responding-to-review` VERIFIED, scoped to those files and those issues, and report each fix with its finding. The branch is not the product, the PR is, and a fix sitting in a report costs a round trip to apply by hand. False: leave them proposed for the operator to apply. **The verification is the gate at either setting.** A finding `responding-to-review` pushed back on is never applied, because the agent judged the reviewer wrong; report the pushback and its reasoning instead. `manual` and `advisory` findings never reach this step.
If verdict is DO NOT SHIP: explain what's fundamentally wrong.

**Deslop strip (OPT-IN, before ship).** When the operator wants the AI-slop strip
before merge, dispatch `slop-stripper` (agents/slop-stripper.md) with the base ref
(`git merge-base <default-branch> HEAD`, or the diff range the lenses reviewed). It
applies surgical, behavior-preserving edits to the branch diff (redundant comments,
over-defensive handling, unnecessary casts, flattenable nesting, patterns
inconsistent with the file) and returns a STRIP REPORT. Never auto-run, and
`review.apply_findings` does not change that: a strip rewrites the whole diff on
style grounds rather than fixing a verified finding, so there is no per-item
judgment to stand behind it. That is the line between the two. A `gated_auto`
finding is applied only after `responding-to-review` verified that specific item
(SPEC-078, never blindly); the strip has no such per-item verification, so it stays
the operator's call. Run `/kit:verify` after the strip, then `/kit:ship`.

<!-- review-loop -->
### Step 5b: The bounded review-fix loop (full lane)

A fix batch can reintroduce the bug it fixed: the review that caught the money-path regressions in the founding session ran AGAIN after each fix, over the fix diff. On the full lane, after the operator addresses the FIX THEN SHIP findings (Step 5), re-run this whole command over the NEW diff (the fix batch), in fresh context. The loop foundation and its scaling gate live in `docs/patterns/review-fix-loop.md`.

Stop conditions, whichever comes first:

- **Converged:** the re-run surfaces no CONVERGENT finding (no fingerprint hit by two or more lenses) at CRITICAL or HIGH. Single-lens taste does not restart the loop.
- **Round cap:** two review rounds have run (the original plus one re-review). Two rounds caught the real regressions in practice; more rounds spiral into polish.

At the cap with a convergent CRITICAL or HIGH finding still open, do NOT report SHIP: report `UNRESOLVED AT CAP` and name the finding, so the operator judges it rather than a silent pass. The verdict grammar is otherwise unchanged.

Lane gate: this loop runs on the FULL lane only. Normal runs one pass with no re-review; tiny runs no review. The gate is the cost guard, not an omission.

### Step 6: Operator rejection appends to the ledger (SPEC-144)

If the operator rejects one or more findings from the unified report (by-design, false
positive, deliberate won't-fix), append ONE new row per rejected finding to
`docs/verification/rejected-findings.md`'s table: today's date, the lens(es) that raised it
(the `found by:` field from the report row), the finding's finding-key, `rejected`, and the
operator's stated reason distilled to one clause. Append-only: never edit or remove an
existing row. Create the file from its own template if it does not exist yet. Only an explicit
operator rejection appends a row; a finding the operator fixes, defers to `_meta/BACKLOG.md`
(the `manual` route), or says nothing about is never appended.

## When to use /review-team vs /review

- `/review` (existing): Single-pass review by one agent. Faster, cheaper. Good for small changes, solo work, quick iteration.
- `/review-team` (this command): Parallel 3-lens review. More thorough, ~1.5-2x the tokens with model tiering (3x untiered); each unsuppressed CRITICAL/HIGH finding adds one mid-tier validator subagent (SPEC-082). Good for: PRs before merge, contractor work review, pre-release code, anything touching auth/payments/data.

Source: Addy Osmani's parallel agent review pattern. EveryInc/compound-engineering-plugin (MIT) for the apply-class rubric + model tiering (SPEC-078, absorption 2026-06-11). gstack /review for the paranoid tone. Claude Code Agent Teams documentation for parallel subagent dispatch. mattpocock/skills improve-codebase-architecture for the architecture lens's deep-module vocabulary (SPEC-059).
