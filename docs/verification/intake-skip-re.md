# Proof of done: `intake_skip_re` keeps threaded tickets on the app

Change under proof: `lib/sync/sync_core.py` `intake_ok` gains a body regex
filter `intake_skip_re`, checked before the intake mode. `backlog_sync.py`
accepts `--filter <app>:intake_skip_re=<regex>` and rejects a bad regex at
parse time. Motivation: under `intake=all` a member-facing support ticket
(body carries a `thread:` line) was adopted onto the hub and archived on the
next scope-exit, which the support desk read as an ops close and told the
member their ticket was solved 20 minutes after filing.

## Green run

| # | Check | Command | Result | Verdict |
|---|---|---|---|---|
| 1 | New case + whole sync suite | `bash tests/test-sync.sh` | 257 passed in 0.26s | PASS |
| 2 | Consumer runner test with the fixed kit | `DWARVES_KIT=<this worktree> bash jobs/notion-taskboard-pull/test-takeover` (foundation-ops) | `threaded support ticket adopted 0 (want 0)`, VERDICT: PASS | PASS |
| 3 | Flag registered in help | `python3 lib/sync/backlog_sync.py --help \| grep -c intake_skip_re` | 1 | PASS |

## Negative controls

| # | Control | Command | Result | Verdict |
|---|---|---|---|---|
| 1 | Revert `sync_core.py` to `origin/master`, keep the test | `git show origin/master:lib/sync/sync_core.py >\| lib/sync/sync_core.py; pytest lib/sync/tests/test_core.py -k intake_skip_re` | 1 failed | RED as expected |
| 2 | Restore | `git checkout HEAD -- lib/sync/sync_core.py; bash tests/test-sync.sh` | 257 passed | PASS |
| 3 | Consumer runner test against the unfixed kit | `DWARVES_KIT=~/.claude/dwarves-kit bash jobs/notion-taskboard-pull/test-takeover` (foundation-ops, before the kit merge) | `threaded support ticket adopted 1`, VERDICT: FAIL | RED as expected |

## Reproduce

```
bash tests/test-sync.sh
uv run --no-project --with pytest -- pytest lib/sync/tests/test_core.py -q -k intake_skip_re
```
