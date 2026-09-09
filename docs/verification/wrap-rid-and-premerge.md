# ID-651 + ID-653: a structural wrap skip, and a merge before the PR opens

Two unrelated fixes, one branch, both backlog rows.

## ID-651: wrap Step 7a reports a structural skip, not a clean one

`gate-ledger.sh rid` refuses outright on `master`/`main` (no branch to key a ledger entry
to). `/kit:wrap` Step 7a read that refusal as `skipped: no run id`, the same wording as a
genuinely clean skip (no run log, DEBT marker already present). A session landing from the
default branch could not tell "nothing to record" from "the marker was never reachable".

Fix: Step 7a now captures the rid command's exit code and stderr, and on a non-zero exit
prints `skipped (structural): DEBT marker impossible this run (<reason>)`, quoting
`gate-ledger.sh rid`'s own reason. A session-derived rid was considered and rejected: the
ledger's rid is the same key `hooks/ship-gate.sh` checks at push (SPEC-070), so a rid tied
to the session instead of the branch would write an entry no push-time check and no other
reader could ever trace back to a branch, a worse failure than the skip it would replace.

### Green run

- Command: `bash tests/test-meta.sh` (new `=== ID-651 ===` block)
- Exit: 0
- Output: `wrap.md Step 7a captures the rid exit code, not just stdout` PASS, `wrap.md Step 7a
  names the structural-skip wording` PASS, `wrap.md Step 7a rules out a session-derived rid
  (ledger key stays branch-only)` PASS
- Verdict: PASS

- Command: `bash tests/test-hooks.sh` (SPEC-070 block, new stderr-content assertion)
- Exit: 0
- Output: `rid on master names 'not on a work branch' on stderr` PASS
- Verdict: PASS

Direct before/after, `gate-ledger.sh rid` run against a fresh `master` fixture:

```
=== BEFORE (old wrap.md line: rid=$(bash lib/gate/gate-ledger.sh rid)) ===
skipped: no run id

=== AFTER (new wrap.md line: rid_out="$(... rid 2>&1)"; rid_rc=$?) ===
skipped (structural): DEBT marker impossible this run (rid: not on a work branch (got
'master'); create the branch first, then derive the rid)
```

### Negative control

Reverted `commands/wrap.md` to the pre-fix text (`git checkout HEAD~1 -- commands/wrap.md`),
committed state otherwise unchanged.

- Command: `bash tests/test-meta.sh` against the reverted file
- Exit: 1
- Output: all three `ID-651` assertions FAIL (`expected '0', got '1'`) -- `rid_rc` absent,
  `skipped (structural)` absent, the no-synthesized-rid sentence absent
- Verdict: RED as expected

Restored `commands/wrap.md` (`git checkout HEAD -- commands/wrap.md`); the same three
assertions PASS again.

## ID-653: premerge.sh check before the PR opens

`.gitattributes` marks append-only logs `merge=union`, but GitHub's squash-merge ignores
that on the server side. A branch that touched `LAB_LOG.md`/`BACKLOG.md` after the default
branch moved could show CONFLICTING on GitHub even though a plain local merge resolves
cleanly, costing a re-merge and re-push once per occurrence.

Fix: `lib/gate/premerge.sh check` runs in `/kit:ship` Step 8, right before `git push`. It
fetches the default branch and, only when the working branch is behind, runs `git merge
--no-edit` (never a rebase, never `-X ours/theirs`). A real conflict leaves `git merge`'s own
unresolved state -- unmerged paths, non-zero exit -- for the operator to resolve by hand.
Already-current is a silent no-op: no fetch-twice, no output, exit 0.

Constraints and how each is met:

1. **Never force-push, never rewrite history.** `git merge --no-edit` only; no `push -f`, no
   `rebase`. Source-pinned by `tests/test-premerge.sh` (`grep -q -- '--force'` and a
   comment-excluding `rebase` grep, both must miss).
2. **A real conflict stops and surfaces, never auto-resolves.** No `-X ours`/`-X theirs`
   anywhere in the script (source-pinned). The conflict case leaves `git status --porcelain`
   showing `UU base.txt` and the file holding both sides' content between `<<<<<<<` markers,
   proven by the fixture in Case C below.
3. **Already up to date does nothing and says nothing.** Case A below: exit 0, empty stdout
   AND stderr.
4. **Never fires outside a PR-open flow.** The only caller is `/kit:ship` Step 8; nothing
   else invokes `premerge.sh`. `grep -rln "lib/gate/premerge.sh"` outside `commands/ship.md`
   and `tests/test-premerge.sh` returns nothing.

### Green run

- Command: `bash tests/test-premerge.sh`
- Exit: 0
- Output: `20/20 passed` -- covers already-current (Case A), a clean merge that lands the
  incoming file without touching the feature commit's SHA and produces a real 2-parent merge
  commit (Case B), a same-line conflict that leaves both sides in markers with no auto-pick
  (Case C), running from the default branch itself (Case D), and a non-repo path (Case E),
  plus the three source pins above
- Verdict: PASS

- Command: `bash tests/test-meta.sh`
- Exit: 0
- Output: `843 / 843` (regenerated `docs/FEATURES.md` reflects the new test-file cross-ref)
- Verdict: PASS

### Negative control

Moved `lib/gate/premerge.sh` out of the tree (`mv lib/gate/premerge.sh /tmp/...`).

- Command: `bash tests/test-premerge.sh`
- Exit: 0 (suite itself exits clean; individual assertions fail)
- Output: `7/20 passed` -- every case that calls the script fails with `No such file or
  directory`
- Verdict: RED as expected

Restored the file; `bash tests/test-premerge.sh` returns `20/20 passed` again.

## Full suite

`bash tests/test-hooks.sh`: 498/498. `bash tests/test-meta.sh`: 843/843. `bash
tests/run-all.sh` was run in full; the two suites it reported failing
(`test-orchestrate-gate-dispatch`, `test-proof-negctl`) fail identically on a clean
`origin/master` checkout with none of this branch's changes applied, confirmed by running
both directly against master. Neither touches `commands/wrap.md`, `commands/ship.md`, or
`lib/gate/premerge.sh`.
