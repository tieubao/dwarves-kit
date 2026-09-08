# Verification log: SPEC-246 /kit:wrap

Spec: `docs/specs/SPEC-246-kit-wrap.md`. Branch `feat/kit-wrap`, base 682dda9 (origin/master at start).

## Spec gates

design-critique (architecture and operations lens): REVISE, 8 findings; spec-validate testability lens: FAIL:fixable, 6 spec edits; spec-validate security lens: REVISE, 13 findings incl. 5 blocking (default-branch deletion, fork-parent `gh` answers, stacked child passing the squash proof, unconstrained log path, swallowed write failures). All folded into the Technical Design, Edge Cases 13 and 14, the Failure modes table, and DEC-001 to DEC-005 before build.

## TASK-001 (55b0f4b): verbs, fixtures, gh stub

Command: `bash tests/test-wrap.sh && bash tests/test-bin-forwarders.sh && bash tests/test-meta.sh && bash -n lib/wrap/wrap.sh`
Exit: 0
Output (excerpt): `test-wrap: all 101 passed`; `test-bin-forwarders: all 41 passed, 0 skipped`; `Passed: 829 / 829`
Verdict: PASS (task-verifier: every acceptance clause mapped to a test line; direct probes on this repo: `scan .` prints `-- vs origin/master: ahead=4 behind=0`, `default-branch .` prints `master`, `apply .` dry-run leaves `git branch --list` and `git worktree list` byte-identical, `merge .` reports no open PRs, `log "x: y"` prints the not-written line; scratch fixtures: a `develop` default is never deleted, a stacked child skips with `merged into feat/parent`, `../x` and an absolute path outside `$HOME` exit 1, an embedded newline exits 1, a project `.kit.toml` key is ignored; `merge` fails closed on `mergeStateStatus` BLOCKED, DIRTY, unknown; an off-default non-ff fetch prints `FAILED` and exits 2; the stub records exactly one `pr merge` with no `--delete-branch` or `--auto`)
Re-audit: folded into the battery (acceptance-verifier re-executes the suite and the probes in fresh context).

## NEGATIVE CONTROL (lead, throwaway worktree at 55b0f4b)

Command: `bash lib/gate/negctl.sh <throwaway> "bash tests/test-wrap.sh" "sed -i '' 's/select(.baseRefName == \$def and .headRefOid == \$tip)/select(.headRefOid == \$tip)/' lib/wrap/wrap.sh"` (the squash proof stops checking the merged PR's base)
Exit: 0 green before; 1 under mutation; 0 after `git checkout HEAD -- lib/wrap/wrap.sh`
Output (excerpt): negctl `Verdict: PASS`; under mutation the stacked-child case (`merged into feat/parent`) and the `--apply` delete set go RED
Verdict: RED-as-expected; the throwaway worktree was removed, the shared worktree never mutated

## TASK-002 (0a386af): command, config key, docs

Command: `bash tests/test-meta.sh && bash tests/test-docs-wiring.sh && bash tests/test-command-emit-sweep.sh && bash lib/registry/feature-registry.sh generate`
Exit: 0
Output (excerpt): `Passed: 832 / 832`; docs-wiring 25/25; command-emit-sweep 18/18; FEATURES.md byte-stable across two generator runs; every rule token (`bin/wrap scan`, `board set`, `wrap merge`, `SPEC-065`, `headSha`, `ExitWorktree keep`, `bin/wrap apply`, `--ff-only`, `bin/wrap log`, `ship | ran | shipping pr=`, `Needs you`) present in commands/wrap.md
Verdict: PASS (lead check of the worker report; the battery re-executes)

## Review wave on fdb63f7, fix batch c9ba7e7

Command: `bash tests/test-wrap.sh && bash tests/test-bin-forwarders.sh && bash tests/test-meta.sh && bash tests/test-docs-wiring.sh && bash -n lib/wrap/wrap.sh`
Exit: 0
Output (excerpt): `test-wrap: all 130 passed` (96 before the batch); `all 41 passed`; `Passed: 832 / 832`; docs-wiring 25/25
Verdict: PASS after fixes (five arms: acceptance FAIL:fixable on a CONTEXT.md path leak, a spec grep, two untested edge cases; security FIX THEN SHIP: `--date` bypass HIGH, merge head pin, vacuous empty rollup; test-coverage 6/10 with three mutation-proven HIGH gaps; architecture 8/10; advisor 2 LOW. Mutation results after the batch, each RED in a throwaway copy: the `--date` case, the checks clauses, the `CHANGES_REQUESTED` line, the `--repo` pin, the tip re-check, the lock-age line.)
Re-audit: PASS (recheck-verifier, fresh context: 130/41/832/25, three mutations re-run RED, every behavior claim reproduced)

## wrap log from a worktree (43c1b77)

Command: `bash tests/test-wrap.sh && bash tests/test-meta.sh && bash tests/test-bin-forwarders.sh`
Exit: 0
Output (excerpt): `test-wrap: all 137 passed` (three new cases: the worktree copy gets the line, the main checkout copy stays, running outside the repo writes the configured file); `Passed: 840 / 840`; `all 41 passed`
Verdict: PASS

## NEGATIVE CONTROL (lead, throwaway worktree at 43c1b77)

Command: `bash lib/gate/negctl.sh <throwaway> "bash tests/test-wrap.sh" "<sed that turns the _worktree_copy call into a no-op>"`
Exit: 0 green before; 1 under mutation; 0 after restore
Output (excerpt): negctl `Verdict: PASS`; under mutation the worktree-copy case and the main-copy-untouched case go RED
Verdict: RED-as-expected

## Worktree sweep, main checkout, derived report (#523 6b2eca8, #524 3c00c57, #525 932b280, backfilled at docs/wrap-backfill)

Three PRs changed `commands/wrap.md` and its specs only, with no `lib/` change. Their claims split into
two classes and this entry keeps them apart rather than implying one proof covers both.

### Class 1: mechanical, proven

Command: `bash tests/test-wrap.sh && bash tests/test-config-registry.sh && bash tests/test-meta.sh`
Exit: 0 for each suite
Output (excerpt): `test-wrap: all 224 passed` (205 before this batch, 15 knob cases from #526, 4 resolver
cases added here); config-registry `23/23 passed`; `Passed: 840 / 840`
Verdict: PASS

The resolver recipe step 5 prescribes is now asserted directly: from a worktree,
`git rev-parse --path-format=absolute --git-common-dir` minus `/.git` resolves to the main checkout,
that checkout sits on the default branch (so `apply` reaches its pull path), and the naive `$PWD`
would have yielded the feature branch instead.

### Class 1b: live run (ops-toolkit, 2026-09-08)

Command: `bash bin/wrap apply <consumer repo>` then the same with `--apply --worktrees`
Exit: 0
Output (excerpt): without the flag, `SKIP <path>: --worktrees not given` for 9 worktrees and
`SKIP <branch>: held by a worktree` for 8 branches. With it, 9 `[APPLY] remove worktree` lines, then
the held branches delete as `squash-merged into main, tip matches the PR head`, then
`[APPLY] pull --ff-only (checkout on main)`.
End state, verified by `git worktree list` and `git branch`: 9 worktrees to 0 (one foreign, detached and
locked, correctly skipped); 15 branches to 5, the 4 non-default survivors each held for a named reason
(unpushed commits, or no merged PR).
Verdict: PASS. This is the negative control for #523's central claim: the same command on the same
repo, one flag apart, with opposite outcomes.

### Class 2: model-obedience, NOT proven and not provable by a test

These are instructions in a prompt file. A test can assert the token is present in `commands/wrap.md`,
which proves the text shipped, not that a run obeys it. Recording them as proven would be false.

- #523: `Left alone` is derived from the closing `wrap scan` rather than narrated from intent.
- #524: an item reaches `Needs you` only through the admission test, and everything failing it is run
  first and reported past tense.
- #525: a precedent hit is wired into the tool it named, a clear-shaped miss is built, and only a
  judgment-scoped candidate stages.

What would close the gap: a recorded `/kit:wrap` transcript over a fixture repo carrying a green own PR,
a stale worktree, and a candidate with a precedent hit, asserted against the resulting git state rather
than against the report text. That fixture does not exist; building it is the honest next step, not a
line in this file.

## Needs you admission test, mechanised (9f28db9)

The 2026-09-08 entry above recorded #524's admission test as NOT proven, because a test can
assert the rule shipped, not that a run obeys it. `lib/wrap/report-lint.sh` closes the half of
that gap which is mechanical: it judges the report's PHRASING, which is checkable, and leaves
reversibility, which is not, to the rule itself.

Command: `bash tests/test-wrap.sh && bash tests/test-meta.sh && bash tests/test-bin-forwarders.sh && bash tests/test-docs-wiring.sh`
Exit: 0 for each suite
Output (excerpt): `test-wrap: all 234 passed` (224 before, 10 lint cases); `Passed: 840 / 840`;
`test-bin-forwarders: all 41 passed`; docs-wiring `25/25 passed`
Verdict: PASS

Case 1 is the original defect verbatim, `a. REVIEW then merge #523. Say go and I merge it.`,
the line this session's own wrap report actually printed while the admission test was prose.
It now exits 1. The remaining cases pin the boundaries: `NOTHING` passes, the same sentence in
`What happened` is never judged, a stated blocker passes, a self-runnable command with no
blocker warns rather than fails, a stated blocker clears that warn, a report with no `Needs you`
block is clean, and a missing file exits 2.

## NEGATIVE CONTROL (9f28db9)

Command: `bash lib/gate/negctl.sh . "bash tests/test-wrap.sh" "<sed that blanks PERMISSION_RE>"`
Exit: 0 green before; 1 under mutation; 0 after restore
Output (excerpt): `Verdict: PASS`
Verdict: RED-as-expected.

## Still unproven after this

- #525's build routing in step 7b. No lint can see whether a precedent hit was wired into the
  tool it named; only the resulting commit would show it, and that commit's absence is
  indistinguishable from "there were no candidates this session".
- Whether a run follows step 5's ORDER. The lint reads the report, not the sequence that
  produced it.

## FYI admission test (f4d148f)

The `Needs you` lane got an admission test in #524; `FYI` did not, and the gap showed the
first time the operator read one. That report's `FYI` carried a staged candidate and two
unproven claims, which ARE work to develop further, under a contract that called the section
"never a task". Both readings were defensible, which means the contract was wrong.

Command: `bash tests/test-wrap.sh && bash tests/test-meta.sh && bash tests/test-docs-wiring.sh && bash tests/test-command-emit-sweep.sh && bash tests/test-no-personal-paths.sh`
Exit: 0 for each suite
Output (excerpt): `test-wrap: all 236 passed` (234 before, 2 pins); `All meta tests passed.`;
docs-wiring `25/25 passed`; command-emit-sweep and no-personal-paths green
Verdict: PASS

Two pins, deliberately paired: one asserts the new rule is present, the other asserts the old
"never a task" wording is GONE. A pin on presence alone would stay green if both wordings
shipped side by side, which is the drift this replaces.

## NEGATIVE CONTROL (f4d148f)

Command: `bash lib/gate/negctl.sh . "bash tests/test-wrap.sh" "<sed downcasing NAMES ITS HOME>"`
Exit: 0 green before; 1 under mutation; 0 after restore
Output (excerpt): `Verdict: PASS`
Verdict: RED-as-expected.

## What this does not enforce

That every `FYI` follow-up bullet actually names a path. `report-lint.sh` judges the `Needs you`
block only. A lint over `FYI` would need to tell a state-change bullet, which owes no path, from
a follow-up bullet, which does, and that classification is the judgment the rule asks a writer
to make. Left as prose deliberately, not overlooked.
