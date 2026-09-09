# Verification log: four rotting suites, and the CI that could not see them

Branch `fix/tests-assert-invariants`, base bd7b23c.

Four suites were red on master. None was a product bug. Each asserted a proxy or a transient
state rather than the property it was named for, which is the same defect class that made the
doc tests grep an id to prove a section exists.

## The defects, each reproduced before the fix

| Suite | What it asserted | Why it rotted |
|---|---|---|
| `test-classify-md-inert` | a pre-fix lib copied to `/tmp` reproduces the bug | the lib resolves siblings relative to its own path, so the copy aborted `FATAL: lib/telemetry/kit-log-dir.sh missing` before classifying. That dependency arrived after the test was written |
| `test-proof-override-order` | a control that reverts an UNCOMMITTED edit | passes only before its own fix is committed; permanent failure after. It also `git stash`ed the shared checkout |
| `test-goal-dispatch` | "exactly 5 forwarding branches use exec" | a sixth was added; the structure was correct and the count was not |
| `test-stable-interface` | `bin/classify` returns `full` for a sample task | the row is about FORWARDING; a legitimate classifier change read as a broken forwarder |
| `test-stable-interface` | `bin/gate ledger rid` returns a rid | `rid` only derives on a work branch. Under `set -euo pipefail` the non-zero refusal killed the suite before the assertion ran, so it passed on a PR branch and died on master |

That last row is why CI never caught any of this: CI only ever runs a branch.

## Green run (29e555c)

Command: `bash tests/run-all.sh`
Exit: 0
Output (excerpt): `run-all: all 131 suites passed`
Verdict: PASS

Cross-checked per suite from BOTH checkouts, because branch-versus-master asymmetry is what hid
one defect:

```
test-classify-md-inert       branch: OK   master: OK
test-goal-dispatch           branch: OK   master: OK
test-proof-override-order    branch: OK   master: OK
test-stable-interface        branch: OK   master: OK
```

## NEGATIVE CONTROLS, now real rather than permanently skipped

Two of the four suites ARE negative controls, and both were inert before this branch.
`test-proof-override-order` reported `[NO EXECUTABLE CHECK]` plus a failure on every run;
`test-classify-md-inert` reported an empty classification. Both now execute and go red when
the fix they guard is removed, which is the property a control exists to have. Their own output
is the evidence: `negative control: the pre-fix order correctly goes RED (old order re-blocks a
real proof)` and `inert-FIRST-stripped lib classifies md-only 'migrate' as stateful`.

## The CI gap, measured

`.github/workflows/test.yml` listed suites one hand-written step at a time:

```
in CI: 74    on disk: 131    never run anywhere: 57
```

A green CI was checking 57 percent of what the repo has. `tests/run-all.sh` replaces 77
hand-listed steps with one glob, caps each suite at 300s so a single hang cannot burn the job,
and prints the failing tail. A glob cannot drift out of date.

Cost, measured rather than guessed: 131 suites take 10m07s locally, against 74 in three to four
minutes on the ubuntu leg. Sharding is a cheaper problem to solve later than a regression nobody
can see. Flagged for the operator rather than decided silently.

## Reproduce

```
git checkout 29e555c
bash tests/run-all.sh
```
