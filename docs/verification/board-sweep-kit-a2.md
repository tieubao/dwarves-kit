# Verification log: board-sweep-kit-a2 (ID-648, ID-642)

Branch `fix/board-sweep-kit-a2`, base `24ac3a8` (origin/master at start).

Two unrelated backlog rows landed on one branch: `bin/release` targeted the wrong changelog file and missed a version surface (ID-648), and the shared `SECRET_SHAPE_RE` in `lib/precedent/inventory.py` / `lib/session/recall/session_recall.py` missed several credential shapes (ID-642).

## Green run (4247fa2)

Command: `bash tests/test-release.sh`
Exit: 0
Output: `PASS=8 FAIL=0` -- dry-run reports the `tool.toml` surface, reports `docs/CHANGELOG.md` (not the root stub) as the roll target, leaves the tree clean after `--dry-run`, never touches the root `CHANGELOG.md` stub (dry or wet), the wet-run section header uses a hyphen separator, `tool.toml`'s version is bumped to match `VERSION`, and an unrelated `plugin.json` field is left alone (negative control).
Verdict: PASS

Command: `bash tests/test-precedent.sh`
Exit: 0
Output: `65/65 passed`, including the pre-existing byte-equality pin and a new ID-642 pin exercising AWS secret access keys, a PEM private-key header, a 1Password `ops_` token, `PASSWORD=`/`TOKEN=` assignments (all must redact), and two benign lines (a sentence, a `git commit` invocation -- must NOT redact).
Verdict: PASS

Command: `bash tests/test-meta.sh`
Exit: 0
Output: `Passed: 840 / 840` (includes the SPEC-115 3-surface version pin and the SPEC-219 `docs/FEATURES.md` freshness pin, both exercised by this branch's changes)
Verdict: PASS

Command: `cd lib/session/recall && python3 -m unittest discover -s tests`
Exit: 0
Output: `Ran 14 tests in 0.162s / OK`
Verdict: PASS

## NEGATIVE CONTROL (4247fa2, mechanised via negctl.sh)

Command: `bash lib/gate/negctl.sh . "bash tests/test-release.sh" "git checkout 24ac3a8 -- bin/release"`
Exit: 0 green before; 1 under mutation; 0 after restore
Verdict: PASS -- reverting `bin/release` to its pre-fix (24ac3a8) copy turns the fixture suite red (tool.toml surface silent, `docs/CHANGELOG.md` not named, section-header separator wrong, `tool.toml` not bumped), proving the test pins the actual bug rather than passing vacuously.

Command: `bash lib/gate/negctl.sh . "bash tests/test-precedent.sh" "git checkout 24ac3a8 -- lib/precedent/inventory.py"`
Exit: 0 green before; 1 under mutation; 0 after restore
Verdict: PASS -- reverting only `inventory.py`'s copy of `SECRET_SHAPE_RE` to its pre-fix (24ac3a8) narrower pattern turns both the byte-equality pin and the new ID-642 shape pin red, proving both new/changed assertions are load-bearing.

## Reproduce

```
git checkout 4247fa2
bash tests/test-release.sh
bash tests/test-precedent.sh
bash tests/test-meta.sh
```

## Scope note

The backlog row for ID-642 names a third copy, `SECRET_SHAPE_RE` in ops-toolkit's `repo-sweep` tool. That file lives in the sibling `tieubao/ops-toolkit` repo, out of reach from a dwarves-kit-only branch and worktree. Only the two dwarves-kit copies (`lib/precedent/inventory.py`, `lib/session/recall/session_recall.py`) are widened here, kept byte-equal per the existing `tests/test-precedent.sh` pin. Widening the ops-toolkit copy to match is a follow-up in that repo.

**Follow-up closed, no work needed.** ops-toolkit deleted its copy on 2026-09-06 and pointed `repo-sweep whathas` at `precedent find --surface inventory`, so it inherits this regex at runtime. Verified against ops-toolkit `origin/main`: `git grep SECRET_SHAPE_RE -- tools/repo-sweep/` returns nothing. The kit holds two copies, not three.
