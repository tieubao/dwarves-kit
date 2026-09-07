# Proof of done: printf-into-grep-q under pipefail

Scope: every `printf ... | grep -q` site in `tests/*.sh` (303 after the sweep, 47 files) now wraps the producer as `{ trap '' PIPE; printf ... 2>/dev/null || :; }` so the pipeline exit is grep's. No assertion changed. Origin: the macOS CI job on #508 failed `test-config-registry.sh` line 133 with `printf: write error: Broken pipe`.

## Root cause

`grep -q` exits on the first match. printf then writes to a closed pipe. With SIGPIPE at its default the subshell dies with 141; with SIGPIPE ignored (the GitHub runner) printf returns 1. Under `set -o pipefail` either turns a matched grep into a failed pipeline. The race only lands when the payload outruns grep's first read, which is why it surfaced as a flake.

The first cut (`{ printf ... || :; }` alone) covered only the ignored-signal regime: with SIGPIPE default the subshell is killed before `|| :` runs. The `trap '' PIPE` inside the group covers both.

## Green run (commit 4658dca, detached worktree at a plain path, macOS, bash 3.2 and 5.3)

| Step | Command | Result |
|---|---|---|
| Syntax | `for f in tests/*.sh; do bash -n "$f"; done` | 0 errors |
| Site census | grep for `printf ... \| grep -q` unguarded | 0 left, 303 guarded, 0 double-guarded |
| CI script set | the 68 scripts named in `.github/workflows/test.yml`, run one by one | 66 PASS, 2 FAIL (below) |

The two local failures are not the sweep:

- `tests/test-kit-gates-cost.sh` runs from `lib/stats` in CI; the local runner invoked it from the repo root (path artifact of the runner script).
- `tests/test-orchestrate-wavefront.sh` fails `wave_run g`, `wave_run h2`, `dispatch k` on this host. Bisect in the same worktree: the first-wrap commit fails, the trap commit with the wavefront file reverted fails, and master's own `tests/` on the final libs fails the same three. The mock barrier sessions exit 7 (sibling never overlapped) in every leg, a host timing condition. It had passed on the same commit earlier in the day.

Recorded run:

```
Command: bash tests/test-meta.sh
Exit: 0
Verdict: PASS (840/840)

Command: bash tests/test-config-registry.sh
Exit: 0
Verdict: PASS (19/19, the assertion that failed on the #508 macOS job)

Command: bash docs/verification/test-grep-pipefail-negctl.sh
Exit: 0
Verdict: PASS (CONTROL: PASS, both signal regimes)
```

## Rollback

`git revert` of the sweep commits restores the bare `printf | grep -q` form. Nothing else depends on the guarded shape; the tests assert the same things either way.

## Negative control (`docs/verification/test-grep-pipefail-negctl.sh`)

A 300 KB payload outruns the pipe buffer, so the race is deterministic.

```
old form, SIGPIPE default: exit=141 (RED expected)
old form, SIGPIPE ignored (CI): exit=1 (RED expected)
guarded form, SIGPIPE default: exit=0 (0 expected)
guarded form, SIGPIPE ignored (CI): exit=0 (0 expected)
guarded form, no match: exit=1 (1 expected)
CONTROL: PASS
```

Same output under `/bin/bash` 3.2.57 and Homebrew bash 5.3.15.
