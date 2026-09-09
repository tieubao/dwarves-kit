# Proof of done: board id mint reads git history, not just the checkout

Row: ID-650. Branch: `fix/board-id-mint-b7`.

## Defect

`sync_core.next_id()` minted from `backlog.read_text()`, the board file on disk.
No `git fetch`, no pull, no git read of any kind existed in the call chain
(`board.sh cmd_capture`, `board.sh cmd_sync` then `backlog_sync.py`, and
`add-backlog`'s own separate copy). A checkout behind origin, or a board whose
rows were archived out, read an already-taken id as free.

Measured impact: three collisions in one ops-toolkit board (ID-811, ID-682,
ID-727). The ID-682 row on that board still carries the repair note, "Renumbered
from ID-682 on 2026-09-09: the browser-harness fork-sync row claimed that ID
eight minutes earlier and board sync dropped this one every tick."

## Live reproduction, before the fix

The defect was still live on the ops-toolkit board at the time of the fix.

| Command | Output |
|---|---|
| `grep -oE '^\| ID-[0-9]+ \|' _meta/BACKLOG.md \| grep -oE '[0-9]+' \| sort -n \| tail -1` | `822` |
| `git log -p --all --format= -- _meta/BACKLOG.md \| grep -oE '^[-+ ]?\| ID-[0-9]+ \|' \| grep -oE '[0-9]+' \| sort -n \| tail -1` | `823` |

Result: defect confirmed live. The working copy topped out at ID-822, so the
next mint would have handed out ID-823, which history already held.

## Fix

`history_max_id(path, prefix)` raises the mint floor from `git log -p --all`
over the board file. `--all` reaches remote-tracking refs, so a lagging working
tree stops mattering once the clone has fetched. `-p` reaches rows later deleted
or archived out. The matched line shape is the row-anchored one `next_id`
already uses, after the diff marker, so an id token in prose still never counts
(the ID-480 rule is preserved, not reintroduced).

Threaded through all three minters:

| Minter | Before | After |
|---|---|---|
| `lib/board/board.sh` `cmd_capture` | `next_id(text, prefix)` | `next_id(text, prefix, path)` |
| `lib/sync/sync_core.py` `apply_board` | `next_id(text, prefix)` | `next_id(text, prefix, path)`, path from both `backlog_sync.py` call sites |
| `lib/board/bin/add-backlog` | own `re.findall(r"ID-(\d+)")` over all text | delegates to `sync_core.next_id`, history floor computed once per promote run |

`add-backlog` carried a second, weaker rule: a bare regex over the whole text,
which is the ID-480 prose-poisoning bug `sync_core` had already fixed. It now
routes through the shared minter, so that bug dies on that path too.

## Green run

| Command | Exit | Verdict |
|---|---|---|
| `bash tests/test-sync.sh` | 0 | PASS, 262 passed in 0.61s (5 new tests included) |
| `bash tests/test-board-promote.sh` | 0 | PASS, 17 run, 17 passed, 0 failed |
| `bash docs/verification/board-id-mint-history-floor.sh` | 0 | PASS, RED without the fix, GREEN with it |
| full suite, `for t in tests/test-*.sh` | 0 | 127 suites passed, 4 failed |

The 4 failing suites (`test-classify-md-inert`, `test-goal-dispatch`,
`test-proof-override-order`, `test-stable-interface`) fail identically on a
clean `origin/master` worktree, so they pre-date this branch. `test-meta.sh`
passes, which is the `docs/FEATURES.md` freshness gate.

## Negative control

Mechanised and re-runnable: `docs/verification/board-id-mint-history-floor.sh`
strips the history floor out of `next_id`, runs the three collision tests, then
restores and re-runs.

```
=== 1. fix REVERTED (history floor removed): expect RED ===
FFF                                                                      [100%]
>           assert next_id(stale, "ID", board) == 824
E           AssertionError: assert 823 == 824
>           assert next_id(text, "ID", board) == 823
E           AssertionError: assert 822 == 823
>           assert assigned["r1"] == "ID-824"
E           AssertionError: assert 'ID-821' == 'ID-824'
FAILED lib/sync/tests/test_core.py::test_next_id_skips_an_id_only_git_history_still_holds
FAILED lib/sync/tests/test_core.py::test_next_id_sees_an_id_taken_on_another_ref
FAILED lib/sync/tests/test_core.py::test_apply_board_mint_clears_ids_only_history_holds
3 failed, 44 deselected in 0.23s
reverted exit status: 1

=== 2. fix RESTORED: expect GREEN ===
...                                                                      [100%]
3 passed, 44 deselected in 0.20s
restored exit status: 0

negative control OK: RED without the fix, GREEN with it
```

Each reverted failure is the collision itself: the pre-fix mint returns 823
where 823 is taken, 822 where 822 is taken, ID-821 where ID-821 is taken.

## Cost

One `git log -p --all` per mint, over one file.

| Board | Rows | Time |
|---|---|---|
| ops-toolkit (largest in the estate) | ~820 | 0.44s |
| dwarves-kit | ~650 | 0.04s |

Mints are human-paced (`board capture`, `board promote`) or once per sync tick,
and `add-backlog` pays it once per promote run rather than once per row.
Acceptable.

## Residual race, NOT closed

An id another machine pushed that this clone has never fetched stays invisible.
No local scan can see it, so the mint can still collide with it.

Closing that needs a check at push time, not at mint time: compare the minted
ids against the remote before the push lands, and renumber on a hit. That is a
change to the push path, out of scope here.

A `git fetch` before each mint was considered and deliberately rejected. It
narrows the window without closing it, and it buys that by adding network
latency plus an offline failure mode to every mint, including `board capture`,
which the operator runs interactively.

Local concurrency between two promote runs on one machine was already covered
by the `flock` in `add-backlog`; this branch does not change it.

## Outcome

Command: `bash docs/verification/board-id-mint-history-floor.sh`
Exit: 0
Verdict: PASS

