# Step 7b now reports an outcome the lint can check

Step 7b of `/kit:wrap` builds the candidates a session produced rather than proposing them. It
was the one step that left no trace when skipped AND no trace when it ran and found nothing.
Those two outcomes were indistinguishable in the report, so skipping it was invisible.

On 2026-09-09 it was skipped for a whole 20-hour session. Step 7a failed with `skipped: no run
id`, that was read as "step 7 does not apply", and `b` never ran. `report-lint.sh` passed the
report clean, because it only judged `Needs you` phrasing. The operator caught it by asking.

That is the same defect the same session documented in
`ops-toolkit/research/2026-09-09-checks-need-a-third-state.md`: a check whose "did not run" is
byte-identical to "ran, found nothing". The wrap command had the bug it helped write up.

## The change

Three parts, one cause.

1. `commands/wrap.md` step 7a now states that a skip in `a` skips only `a`. `b` and `c` do not
   depend on a run id, a run log, or the classifier.
2. The report template gains a required `**Built:**` line carrying exactly one of three
   outcomes: what was built or staged, `NOTHING: no candidates`, or `SKIPPED: <why>`.
3. `lib/wrap/report-lint.sh` fails the report when that line is absent or empty.

The gate is the third part. The first two are prose, and prose is what lost here already.

## Green run

- Command: `report-lint.sh <report with '**Built:** tools/vps-mon/google-cred-probe (PR #2451)'>`
- Exit: 0
- Output: `report-lint: clean (0 warn(s))`
- Verdict: PASS

- Command: `report-lint.sh <report with '**Built:** NOTHING: no candidates'>`
- Exit: 0
- Verdict: PASS

- Command: `report-lint.sh <report with '**Built:** SKIPPED: build_candidates knob is false'>`
- Exit: 0
- Verdict: PASS

All three legitimate outcomes pass, so the gate constrains presence and not content.

## Negative control

The control is the real artifact, not a synthetic one: the actual wrap report printed earlier
that day, the one that passed the old lint while 7b had been skipped.

- Command: `report-lint.sh <the 2026-09-09 wrap report as printed>`
- Exit: 1
- Output: `line 0: no '**Built:**' line; step 7b (build the candidates) owes an outcome`
- Verdict: RED as expected

Second control, an empty header, since a bare `**Built:**` would otherwise satisfy a presence
check and re-open the same hole.

- Command: `report-lint.sh <report ending in a bare '**Built:**'>`
- Exit: 1
- Output: `line 0: '**Built:**' is empty; name what was built, or NOTHING, or SKIPPED with a reason`
- Verdict: RED as expected

## What this does not cover

The lint checks that an outcome was REPORTED, never that the precedent check actually ran. An
agent can still write `NOTHING: no candidates` without running `precedent find`. Closing that
would mean the lint reading the run log for a precedent invocation, which is a bigger change
than the hole justifies today. The line makes the claim explicit and attributable, which is the
step that was missing.
