# Proof of done: echo-into-grep-q under pipefail

Scope: every `echo ... | grep -q` site in `tests/*.sh` and `tests/*.bats` (111 sites, 21 files) now wraps the producer as `{ trap '' PIPE; echo ... 2>/dev/null || :; }` so the pipeline exit is grep's. No assertion changed. Same defect class as #510 (`docs/verification/test-grep-pipefail.md`), which swept `printf ... | grep -q` sites and missed these because it grepped for `printf` only.

## Root cause

`grep -q` exits on the first match. `echo` then hits EPIPE writing to the closed pipe. With SIGPIPE at its default disposition the subshell running `echo` dies with 141 before any `|| :` can run; with SIGPIPE ignored (the GitHub runner) `echo` returns 1. Either way, `set -uo pipefail` (line 35 of `tests/test-kit-contract.sh`) turns a matched grep into a failed pipeline, so a real match reads as a miss. This produced a false FAIL on master run 34092722090 (merge of #511, macos-latest job):

```
line 235: echo: write error: Broken pipe
FAIL: every staged-block writer goes through the one renderer (offenders: lib/learn/propose.py)
```

`lib/learn/propose.py` does import `staging_format` and call `sf.render_block`; the assertion misread the EPIPE-killed pipeline as a miss.

## Green run

| Command | Exit | Verdict |
|---|---|---|
| `bash tests/test-kit-contract.sh` | 0 | PASS (25/25, staged-block-writer check reads PASS) |
| `bash tests/test-hooks.sh` | 0 | PASS (497/497) |
| `bash tests/test-meta.sh` | 0 | PASS (840/840) |
| `bash tests/test-orchestrate.sh` | 0 | PASS |
| `bash tests/test-routing.sh` | 0 | PASS (14/14) |
| `bash tests/test-learn-propose.sh` | 0 | PASS (42/42) |
| `bash tests/test-intake-sweep.sh` | 0 | PASS (28/28) |
| `bash tests/test-gate-ledger-history.sh` | 0 | PASS (9/9) |
| `bash tests/test-gate-ledger-report.sh` | 0 | PASS (8/8) |
| `bash tests/test-gate-outcome.sh` | 0 | PASS (25/25) |
| `bash tests/test-config-stamp.sh` | 0 | PASS (17/17) |
| `bash tests/test-every-step-review.sh` | 0 | PASS (17/17) |
| `bash tests/test-agent-effectiveness.sh` | 0 | PASS (24/24) |
| `bash tests/test-board-publish.sh` | 0 | PASS (19/19) |
| `bash tests/test-break-it.sh` | 0 | PASS (68/68) |
| `bash tests/test-meta-agent.sh` | 0 | PASS (72/72) |
| `bash tests/test-picture-section.sh` | 0 | PASS (21/21) |
| `bash tests/test-understanding-wiring.sh` | 0 | PASS (19/19) |
| `bash tests/test-web-drift-refusal-guard.sh` | 0 | PASS (7/7) |
| `bash tests/test-goal-dispatch.sh` | 1 | PASS (see caveat below, unrelated pre-existing fail) |
| `bash docs/verification/test-echo-grep-pipefail-negctl.sh` | 0 | PASS (CONTROL: PASS, both signal regimes) |

Recorded run:

```
- Command: bash tests/test-kit-contract.sh
- Exit: 0
- Verdict: PASS
```

`tests/test-goal-dispatch.sh` fails one unrelated assertion (`row13: exactly 5 forwarding branches use exec bash $GOAL_DIR/...`, a `grep -c` count against `lib/goal/goal.sh` with no echo/pipe in it) identically on unmodified `origin/master` (confirmed via `git stash`), so it is pre-existing drift, not a regression from this change. This branch's own `row12` assertion in the same file (an `echo | grep -q` site) is fixed and PASSes.

Site census: `grep -rnE 'echo [^|]*\| *grep -q' tests/ | grep -v "trap '' PIPE"` returns 0 matches after the sweep. Total `{ trap '' PIPE; ... }` guards in `tests/`: 397 (286 pre-existing from the #510 printf sweep + 111 new from this sweep).

Syntax check: `bash -n` on every changed `.sh` file, 0 errors.

## NEGATIVE CONTROL

The task-provided single-line 200-500 KB probe (`echo "$big" | grep -q a` with no embedded newline) does not reproduce the race on this host: a solo large write fits inside this darwin box's pipe buffer before grep starts reading, so `echo` never blocks and never sees EPIPE (`bare=0` at both 200 KB and 500 KB). The race needs the same shape #510's `printf` negctl used: multiple lines, so `grep -q` can match and exit after the first line while the writer is still blocked on the rest. `docs/verification/test-echo-grep-pipefail-negctl.sh` uses that shape (a 300 KB line repeated three times) and reproduces the exact failure signature from run 34092722090 (`echo: write error: Broken pipe`):

```
$ bash docs/verification/test-echo-grep-pipefail-negctl.sh
old form, SIGPIPE default: exit=141 (RED expected)
old form, SIGPIPE ignored (CI): exit=1 (RED expected)
guarded form, SIGPIPE default: exit=0 (0 expected)
guarded form, SIGPIPE ignored (CI): exit=0 (0 expected)
guarded form, no match: exit=1 (1 expected)
CONTROL: PASS
```

Same output under both bash builds on this host:

```
/bin/bash (GNU bash 3.2.57, Apple-signed): CONTROL: PASS
/opt/homebrew/bin/bash (GNU bash 5.3.15): CONTROL: PASS
```

## Rollback

`git revert` of this PR's commit restores the bare `echo | grep -q` form. Nothing else depends on the guarded shape; the tests assert the same things either way.
