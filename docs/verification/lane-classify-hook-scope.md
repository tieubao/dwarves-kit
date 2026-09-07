# Proof of done: lane-classify kit-machinery hook-term scoping

Verdict: PASS

## Bug

`lib/classify/lane-classify.sh`'s `kit-machinery` hard-gate regex carried a bare
`\bhook(s)?\b` term with no scoping. Any task description merely containing the word
"hook" (a Claude Code settings.json hook entry, a React `useEffect` hook, a git
pre-commit hook) escalated to the `full` lane, even with no relation to the kit's own
hook/gate enforcement machinery.

## Fix

Replaced the bare `\bhook(s)?\b` alternative with a scoped set: `hooks/` (the kit's
hook directory) or `hooks\.json` (its registration file) as literal path anchors, plus
`\bhook(s)?\b` co-occurring within 30 chars of `kit|machinery|enforcement|gate-ledger|
ship-gate|lane-classify`, plus `the kit ... hook(s)`. One regex term changed; no other
line in `lib/classify/lane-classify.sh` touched.

## Acceptance criteria -> confirmation

| AC | Criterion | How proven | Result |
|----|-----------|------------|--------|
| AC1 | settings.json/jq edit stays `normal` (repro 1, was already correct) | `classify "add a single key to settings.json with jq"` = normal | PASS |
| AC2 | SessionEnd hook entry to settings.json now `normal` (repro 2, was `full`) | `explain "add a SessionEnd hook entry to settings.json"` = normal | PASS |
| AC3 [NC] | React `useEffect` hook mention stays `normal` | `classify "add a useEffect hook to the component"` = normal | PASS |
| AC4 [NC] | git pre-commit hook mention stays `normal` | `classify "add a pre-commit git hook to run lint"` = normal | PASS |
| AC5 | ship-gate PreToolUse hook still escalates | `explain "change the ship-gate PreToolUse hook"` = full (kit-machinery) | PASS |
| AC6 | kit's gate-ledger hook still escalates | `explain "edit the kit's gate-ledger hook"` = full (kit-machinery) | PASS |
| AC7 | bare `hooks/` directory mention still escalates | `explain "add a new hook to hooks/ that blocks force-push"` = full (kit-machinery) | PASS |
| AC8 | kit's safety-gate hook (generic gate name) still escalates | `explain "modify the kit's safety-gate hook to add a new check"` = full (kit-machinery) | PASS |
| AC9 [no regression] | full lane-classify + adjacent lane suites stay green | see run-table | PASS |

## Confirmation run-table

| Command | Exit | Result |
|---------|------|--------|
| `bash tests/test-lane-classify.sh` | 0 | 31/31 passed |
| `bash tests/test-lane-escalation.sh` | 0 | 22/22 passed |
| `bash tests/test-lane-deescalate.sh` | 0 | 22/22 passed |
| `bash tests/test-lane-telemetry.sh` | 0 | 29/29 passed |
| `bash tests/test-significance-classify.sh` | 0 | 25/25 passed |

## Negative control

Reverted `lib/classify/lane-classify.sh` to its pre-fix content (`git checkout HEAD~1 --
lib/classify/lane-classify.sh`) with the new test pins from this branch still in place,
re-ran `tests/test-lane-classify.sh`:

```
=== lane-classify kit-machinery hook-term scoping (bare 'hook' false positive) ===
  PASS hook-scope [NC] settings.json edit, no 'hook' word, stays normal (normal)
  FAIL hook-scope [NC] generic Claude Code hook mention stays normal -- got 'full', expected 'normal'
  FAIL hook-scope [NC] React hook mention stays normal -- got 'full', expected 'normal'
  FAIL hook-scope [NC] git hook mention stays normal -- got 'full', expected 'normal'
=== 28/31 passed, 3 failed ===
```

RED, reproducing the exact bug (3 failures, the false-positive cases). Restored the fix
(`git checkout HEAD -- lib/classify/lane-classify.sh`) and re-ran: 31/31 passed (see
run-table above).

## Reproduce

```
bash lib/classify/lane-classify.sh classify "add a single key to settings.json with jq"           # normal
bash lib/classify/lane-classify.sh explain  "add a SessionEnd hook entry to settings.json"          # normal
bash lib/classify/lane-classify.sh explain  "change the ship-gate PreToolUse hook"                  # full (kit-machinery)
bash lib/classify/lane-classify.sh explain  "edit the kit's gate-ledger hook"                       # full (kit-machinery)
bash tests/test-lane-classify.sh
```
