# Proof of done: lane-classify kit-machinery hook-term scoping

Verdict: PASS

## Bug

`lib/classify/lane-classify.sh`'s `kit-machinery` hard-gate regex carried a bare
`\bhook(s)?\b` term with no scoping. Any task description merely containing the word
"hook" (a Claude Code settings.json hook entry, a React `useEffect` hook, a git
pre-commit hook) escalated to the `full` lane, even with no relation to the kit's own
hook/gate enforcement machinery.

## Fix (v1, then a CI-caught correction)

**v1** replaced the bare `\bhook(s)?\b` alternative with a noun-scoped set: `hooks/`
(the kit's hook directory) or `hooks\.json` (its registration file), plus `\bhook(s)?\b`
co-occurring within 30 chars of `kit|machinery|enforcement|gate-ledger|ship-gate|
lane-classify`, plus `the kit ... hook(s)`.

**v1 shipped a regression, caught by CI, not by local runs.** `tests/test-hooks.sh:1763`
pins `classify "write its AGENTS.md and disable the safety hooks"` -> `full`
(`lane-classify.sh:131` cites this exact phrase in a comment as a deliberate backfill +
hard-gate-subject case). That phrase carries no kit-internal noun ("safety hooks" is not
`hooks/`, not `kit`, not `gate-ledger`...), so under v1 it fell through the backfill
branch, matched no hard-gate flag, and landed on `backfill` instead of `full`. The gap:
v1's proximity list was built from NOUNS naming kit internals; this case is identified by
an ADJECTIVE + VERB ("disable ... safety hooks"), a different signal entirely. Local runs
never caught it because the local test pass only re-ran the lane-adjacent suites
(`test-lane-classify.sh`, `test-lane-escalation.sh`, etc.), not `tests/test-hooks.sh`,
which is where this pin actually lives.

**v2** widened the term to catch intent-to-weaken-a-guard regardless of which internal
noun is named: `(disable|bypass|turn off|skip|remove)[a-z]*\b.{0,20}\bhook(s)?\b`,
the same disabling verbs looking forward from `hook`, plus `\bsafety\b.{0,15}\bhook(s)?\b`
and `\bguard\b.{0,15}\bhook(s)?\b`. Still one regex term (the `kit-machinery` hard-gate
alternative) in `lib/classify/lane-classify.sh`; no other line touched.

**v2 also tripped a self-inflicted doc-drift the first time it was written.** The first
draft of the new positive test case used the literal string "safety-gate hook" to prove
a kit gate name outside the explicit noun list still escalates. `hooks/safety-gate.sh`
is a real hook in this repo, and `lib/registry/feature-registry.sh`'s doc generator does
an exact-token grep of `tests/*.sh` to count each hook's test-suite callers for
`docs/FEATURES.md`. Adding that literal string bumped `safety-gate.sh`'s caller count by
one, so the committed `docs/FEATURES.md` went stale (`tests/test-meta.sh`'s
"docs/FEATURES.md is fresh" pin, SPEC-219) -- 839/840. Fixed by rewording the test case
to a fabricated, non-existent gate name ("pre-flight") that still exercises the same
`the kit ... hook` regex path without colliding with a real basename.

## Acceptance criteria -> confirmation

| AC | Criterion | How proven | Result |
|----|-----------|------------|--------|
| AC1 | settings.json/jq edit stays `normal` (repro 1) | `classify "add a single key to settings.json with jq"` = normal | PASS |
| AC2 | SessionEnd hook entry to settings.json stays `normal` (repro 2, was `full`) | `explain "add a SessionEnd hook entry to settings.json"` = normal | PASS |
| AC3 [NC] | React `useEffect` hook mention stays `normal` | `classify "add a useEffect hook to the component"` = normal | PASS |
| AC4 [NC] | git pre-commit hook mention stays `normal` | `classify "add a pre-commit git hook to run lint"` = normal | PASS |
| AC5 | ship-gate PreToolUse hook still escalates | `explain "change the ship-gate PreToolUse hook"` = full (kit-machinery) | PASS |
| AC6 | kit's gate-ledger hook still escalates | `explain "edit the kit's gate-ledger hook"` = full (kit-machinery) | PASS |
| AC7 | bare `hooks/` directory mention still escalates | `explain "add a new hook to hooks/ that blocks force-push"` = full (kit-machinery) | PASS |
| AC8 | kit's own unlisted-gate-name hook still escalates | `explain "modify the kit's own pre-flight hook to add a new check"` = full (kit-machinery) | PASS |
| AC9 | CI-caught regression: disable-the-safety-hooks still up-lanes to full | `classify "write its AGENTS.md and disable the safety hooks"` = full | PASS |
| AC10 [no regression] | docs/FEATURES.md stays fresh, no caller-count drift from the new test text | `bash lib/registry/feature-registry.sh generate` diffed against committed `docs/FEATURES.md` = no diff | PASS |
| AC11 [no regression] | full lane-classify + adjacent lane suites + the hook suite that caught the regression stay green | see run-table | PASS |

## Confirmation run-table

Every suite the CI workflow (`.github/workflows/test.yml`) runs, executed locally against
this branch:

| Command | Exit | Result |
|---------|------|--------|
| `bash tests/test-hooks.sh` | 0 | 497/497 passed (this is the suite that caught the CI regression) |
| `bash tests/test-meta.sh` | 0 | 840/840 passed (includes the docs/FEATURES.md freshness pin) |
| `bash tests/test-docs-wiring.sh` | 0 | 25/25 |
| `bash tests/test-delivery-ratio.sh` | 0 | 8/8 |
| `bash tests/test-install-modules.sh` | 0 | 37/37 |
| `bash tests/test-bin-forwarders.sh` | 0 | 41/41 |
| `bash tests/test-e2e.sh` | 0 | 20/20 |
| `bash tests/test-review-team-plants.sh` | 0 | 8/8 |
| `bash tests/test-orchestrate.sh` | 0 | ALL PASS |
| `bash tests/test-orchestrate-wavefront.sh` | 0 | ALL PASS (flaky on the first full-suite pass, 1 FAILED; re-run in isolation came back ALL PASS, unrelated to this branch -- no lane-classify/hook/registry touch in that suite) |
| `bash tests/test-multiplexer.sh` | 0 | ALL PASS |
| `bash tests/test-tier4-close.sh` | 0 | ALL PASS |
| `bash tests/test-pane-viewer.sh` | 0 | ALL PASS |
| `bash tests/test-subagent-panes.sh` | 0 | ALL PASS |
| `bash tests/test-token-capture.sh` | 0 | ALL PASS |
| `bash tests/test-model-routing.sh` | 0 | 6/6 |
| `bash tests/test-spec-index.sh` | 0 | 9/9 |
| `bash tests/test-spec-reserve.sh` | 0 | 35/35 |
| `bash tests/test-mutation-smoke.sh` | 0 | 32/32 |
| `bash tests/test-role-classify.sh` | 0 | 24/24 |
| `bash tests/test-lane-classify.sh` | 0 | 32/32 |
| `bash tests/test-significance-classify.sh` | 0 | 25/25 |
| `bash tests/test-lane-telemetry.sh` | 0 | 29/29 |
| `bash tests/test-mega-merge.sh` | 0 | 30/30 |
| `bash tests/test-ledger-durability.sh` | 0 | 37/37 |
| `bash tests/test-deployable-done.sh` | 0 | 17/17 |
| `bash tests/test-ledger-substrate.sh` | 0 | 9/9 |
| `bash tests/test-stats-no-persist.sh` | 0 | 5/5 |
| `bash tests/test-gate-outcome.sh` | 0 | 25/25 |
| `bash tests/test-proof-negctl.sh` | 0 | 10/10 |
| `bash tests/test-gate-ledger-history.sh` | 0 | 9/9 |
| `bash tests/test-redteam-gate.sh` | 0 | 40/40 |
| `bash tests/test-bench.sh` | 0 | PASS (5 files) |
| `bash tests/test-outcome-emit-sweep.sh` | 0 | 51/51 |
| `bash tests/test-meta-agent.sh` | 0 | 72/72 |
| `bash tests/test-proof-visual-evidence.sh` | 0 | 4/4 |
| `bash tests/test-design-record.sh` | 0 | 26/26 |
| `bash tests/test-explain.sh` | 0 | 14/14 |
| `bash tests/test-quiz-gate.sh` | 0 | 29/29 |
| `bash tests/test-weekend-batch.sh` | 0 | 38/40 (2 SKIP, 0 FAIL) |
| `bash tests/test-understanding-wiring.sh` | 0 | 19/19 |
| `bash tests/test-proof-table-gen.sh` | 0 | 25/25 |
| `bash tests/test-security-hardening.sh` | 0 | 22/22 |
| `bash tests/test-coverage-delta.sh` | 0 | ALL PASS |
| `bash tests/test-kri-wiring.sh` | 0 | 31/31 |
| `bash tests/test-grill-conditioning.sh` | 0 | 23/23 |
| `bash tests/test-command-emit-sweep.sh` | 0 | 18/18 |
| `bash tests/test-pitch.sh` | 0 | 29/29 |
| `bash tests/test-lane-deescalate.sh` | 0 | 22/22 |
| `bash tests/test-advisor-ledger-emit.sh` | 0 | 27/27 |
| `bash tests/test-board.sh` | 0 | 36/37 (1 SKIP, 0 FAIL) |
| `bash tests/test-board-mirror.sh` | 0 | 76/76 |
| `bash tests/test-board-writeback.sh` | 0 | 53/54 (1 SKIP, 0 FAIL) |
| `bash tests/test-mega.sh` | 0 | 16/16 |
| `bash tests/test-mega-review.sh` | 0 | 26/26 |
| `bash tests/test-mega-report.sh` | 0 | 17/17 |
| `bash tests/test-config-registry.sh` | 0 | 19/19 |
| `bash tests/test-kit-contract.sh` | 0 | 25/25 |
| `bash tests/test-no-personal-paths.sh` | 0 | 3/3 |
| `bash tests/test-learn-propose.sh` | 0 | 42/42 |
| `bash tests/test-learn-drain.sh` | 0 | 23/23 |
| `bash lib/session/intel/tests/smoke.sh` | 0 | 15/15 |
| `bash tests/test-kit-weekly.sh` | 0 | 15/15 |
| `bash tests/test-webcheck.sh` | 0 | 81/81 |
| `python3 lib/webcheck/tests/test_webcheck.py` | 0 | 81/81 |
| `bash tests/test-gauntlet-proof-audit.sh` | 0 | 11/11 |
| `bash tests/test-precedent.sh` | 0 | 48/48 |
| `bash tests/test-break-it.sh` | 0 | 68/68 |
| `bash tests/test-wrap.sh` | 0 | 137/137 |
| `cd lib/session/recall && python3 -m unittest discover -s tests` | 0 | 14/14 |
| `cd lib/stats && uv sync && bash tests/test-kit-gates-cost.sh` | 0 | 14/14 |

## Negative control

Reverted `lib/classify/lane-classify.sh` to its pre-fix content (`git checkout 80be35a
-- lib/classify/lane-classify.sh`, the commit before either fix) with the current test
pins in place, re-ran `tests/test-lane-classify.sh`:

```
=== lane-classify kit-machinery hook-term scoping (bare 'hook' false positive) ===
  PASS hook-scope [NC] settings.json edit, no 'hook' word, stays normal (normal)
  FAIL hook-scope [NC] generic Claude Code hook mention stays normal -- got 'full', expected 'normal'
  FAIL hook-scope [NC] React hook mention stays normal -- got 'full', expected 'normal'
  FAIL hook-scope [NC] git hook mention stays normal -- got 'full', expected 'normal'
  ...
  PASS hook-scope disable-the-safety-hooks still up-lanes to full (full)   <- true on the OLD bare-hook regex too, no signal here
=== 29/32 passed, 3 failed ===
```

RED, reproducing the exact original bug (3 failures, the false-positive cases). Restored
the fix (`git checkout HEAD -- lib/classify/lane-classify.sh`) and re-ran: 32/32 passed.

## Reproduce

```
bash lib/classify/lane-classify.sh classify "add a single key to settings.json with jq"                # normal
bash lib/classify/lane-classify.sh explain  "add a SessionEnd hook entry to settings.json"               # normal
bash lib/classify/lane-classify.sh explain  "change the ship-gate PreToolUse hook"                       # full (kit-machinery)
bash lib/classify/lane-classify.sh explain  "edit the kit's gate-ledger hook"                             # full (kit-machinery)
bash lib/classify/lane-classify.sh classify "write its AGENTS.md and disable the safety hooks"            # full (CI regression case)
bash tests/test-lane-classify.sh
bash tests/test-hooks.sh
bash tests/test-meta.sh
```
