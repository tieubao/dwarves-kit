# Two red suites: a proof-gate assertion that never reached the gate, and stale wrap-lint fixtures

PR #539 made CI run every suite. That exposed two failures that predate this week: case [9] of
`tests/test-proof-negctl.sh`, and four cases in `tests/test-wrap.sh`.

## Failure 1: the test was wrong, the gate was right

Case [9] asserts the safety property behind the whole proof gate: a negative control that
FAILED must not satisfy `proof-ledger check()`. It reported that a FAIL block and a PASS block
both returned 0, which reads as the gate accepting broken proofs.

The gate is correct. The test never reached it.

The fixture repo is built by `git init`. The test then called `check "$PR" master`. On any
machine whose `init.defaultBranch` is `main`, `master` is not a commit, and `check()` returns 0
at its documented fail-open:

```
git -C "$root" rev-parse --verify -q "$base" >/dev/null 2>&1 || return 0
```

That fail-open is deliberate, stated at the top of `lib/gate/proof-ledger.sh`: a gate bug must
never block unrelated work. Both calls hit it, so both returned 0, and the assertion measured
the fail-open rather than the gate.

Given a base that resolves, the gate rejects the FAIL block. `check()` reads the LAST `Verdict:`
line and refuses on `FAIL` or `INCONCLUSIVE`. Proof, on the same fixture the test builds:

| Base passed to `check()` | Proof block | Exit |
|---|---|---|
| `master` (does not resolve) | `Verdict: FAIL` | 0, fail-open, gate never ran |
| `main` (the repo's real default branch) | `Verdict: FAIL` | 1, BLOCKED |
| `main` | `Verdict: PASS` | 0, accepted |

The rc=1 run prints:

```
BLOCKED: proof of done. This is a 'behavioral' change; it cannot ship/merge without a matching
proof-of-done entry in docs/verification/.
  Need: a docs/verification/<slug>.md added by this branch with a green run AND a NEGATIVE CONTROL
```

No proof ever shipped unchecked because of this. `hooks/ship-gate.sh` resolves the base itself:

```
DEFAULT=$(_resolve_base)
BASE=$(git -C "$ROOT" merge-base HEAD "$DEFAULT" 2>/dev/null || true)
if [ -n "$BASE" ] && [ "$BASE" != "$HEADSHA" ]; then
```

It only calls `check()` with a real commit, so the fail-open is unreachable from the shipping
path. The hole was in the test, not the wall.

The fix asks the fixture repo for its own default branch instead of assuming one. Case [9b] is
new and pins the fail-open explicitly, so the next reader cannot mistake a disarmed gate for a
satisfied one, which is exactly what happened here for four commits.

## Failure 2: the tests were stale, the lint was right

PR #546 made a `**Built:**` line REQUIRED of every wrap report. `commands/wrap.md`:

> **`**Built:**` is REQUIRED, and the lint fails without it.**

It taught `lib/wrap/report-lint.sh` to enforce that, and shipped no test for the new rule. Four
fixtures in `tests/test-wrap.sh` predate the rule and carry no `**Built:**` line, so they now
fail on a contract they were never updated for. PR #548 touches step 7a prose only; it changes
nothing the lint reads, so it does not interact.

The fix adds the line to the shared `_report` helper and the one raw fixture, and adds the
coverage PR #546 owed: a missing Built line fails, an empty one fails, a named one passes.

## Green run

| Command | Exit | Result |
|---|---|---|
| `bash tests/test-proof-negctl.sh` | 0 | `test-proof-negctl: all 11 passed` |
| `bash tests/test-wrap.sh` | 0 | `test-wrap: all 241 passed` |
| `bash tests/test-meta.sh` | 0 | `Passed: 843 / 843` |
| `bash tests/run-all.sh` | see below | 132 suites, only the pre-existing red remains |

`tests/test-orchestrate-gate-dispatch.sh` is red at `origin/master` before this branch (5
FAILED on a detached checkout of `743b136`). It is out of scope here and stays red.

## Negative control

Each fix reverted one at a time, target assertions confirmed RED, then restored.

| Reverted | Assertion that goes RED | Restored |
|---|---|---|
| `BASE` back to the literal `master` in case [9] | `[9] FAIL: check rc FAIL-block=0 PASS-block=0` | green |
| `**Built:**` stripped from `_report` | the four wrap-lint fixtures fail | green |
| the Built-rule cases removed | no assertion covers the PR #546 lint at all | green |

Run table recorded in `docs/runs/` by the branch's negative-control run.

## Reproduce

```bash
bash tests/test-proof-negctl.sh
bash tests/test-wrap.sh
bash tests/run-all.sh
```
