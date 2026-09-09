# Proof of done: raise `learn propose` promote precision

Closes ID-305. The prior measurement is `docs/verification/learn-propose-precision.md`, which
found 23 percent raw promote-precision on 69 staged candidates and traced the loss to three
causes, none of them hallucination.

## What changed

| Cause the measurement named | Share of that batch | Where the fix landed |
|---|---|---|
| Dedup anchor never read the cross-repo cockpit boards or megagoal TODO/ROADMAP files | 28 of 69 | `lib/learn/staging-format.py` `existing_keys()` gains `cockpit` and `roadmap` source kinds; `lib/learn/propose.py` `_dedup_sources()` assembles them |
| Candidates valid at staging, finished by triage time, promoted anyway | 19 of 69 | `lib/board/bin/add-backlog` refuses a block older than `BOARD_PROMOTE_MAX_AGE_DAYS` (default 14) |
| A candidate filed against a repo its cited file does not live in | 1 named | `lib/board/bin/add-backlog` refuses a mis-homed block |

Neither promote refusal deletes anything. The block stays `[staged]` for the operator to fix,
reject, or override with `BOARD_PROMOTE_STALE_OK=1`.

The default window is 14 days, not `learn drain`'s 30. The measured decay gap was 16 days, so a
30-day window would have caught none of the 19.

## The measurement

`tests/test-learn-propose-precision.sh` runs one labelled sample twice: once with the new
surfaces switched off through configuration, which reproduces the pre-fix behaviour, and once
with them on. It counts what reaches the BOARD, not what reaches staging, because the promote
gates are half the fix.

```
Command: bash tests/test-learn-propose-precision.sh
Exit: 0

== ID-305 promote-precision, 17 labelled candidates (4 genuinely new, 13 false positives) ==
                               reached board true pos   precision
  before (surfaces off)        17         4          24%
  after  (surfaces on)         6          4          67%
  residual false positives after the fix: 2 (the paraphrased duplicates; exact-key dedup by design)

  PASS  before: every candidate reached the board (17)
  PASS  after: no true positive was lost (4/4)
  PASS  after: fewer candidates reached the board (6 < 17)
  PASS  after: precision rose
  PASS  residual is exactly the paraphrased duplicates (2)

== 5 run, 5 passed, 0 failed ==
```

**Read this number honestly.** The sample is 17 candidates, and it is a reconstruction. The
69-candidate triage kept its class counts but not its candidate list, so it cannot be replayed.
The reconstruction scales that class mix down and reproduces the CLASSES, not the rows. The
before-figure landing at 24 percent against the real 23 percent is a sanity check on the class
mix, not a second independent measurement.

Two of the seven duplicates are paraphrases of a tracked row. Dedup is exact normalized-key
membership by design, so it cannot catch them, and they survive as false positives. That
residual is deliberate: a harness that scored 100 percent would be measuring its own fixture.
The honest claim is that the fix removes the classes the triage identified on a class-faithful
sample. It is not a field prediction.

## Run table

| Check | Command | Exit | Result |
|---|---|---|---|
| propose suite, dedup widening | `bash tests/test-learn-propose.sh` | 0 | 48 run, 48 passed |
| promote suite, aging and home gates | `bash tests/test-board-promote.sh` | 0 | 29 run, 29 passed |
| precision measurement | `bash tests/test-learn-propose-precision.sh` | 0 | 5 run, 5 passed |
| drain suite, unchanged behaviour | `bash tests/test-learn-drain.sh` | 0 | 23 run, 23 passed |

## Negative controls (mechanised)

Each ran through `lib/gate/negctl.sh`, which refuses a dirty tree, proves GREEN, mutates, proves
RED, restores, and proves GREEN again.

```
Command: bash tests/test-learn-propose.sh
Mutation: perl -pi -e 's/^    return sources$/    return sources[:2]/' lib/learn/propose.py
Exit: 0 green -> 1 red -> 0 green
Verdict: PASS

Command: bash tests/test-board-promote.sh
Mutation: perl -pi -e 's/^MAX_AGE_DAYS = .*/MAX_AGE_DAYS = 99999/' lib/board/bin/add-backlog
Exit: 0 green -> 1 red -> 0 green
Verdict: PASS

Command: bash tests/test-board-promote.sh
Mutation: perl -pi -e 's/^    path = mis_homed\(b\)$/    path = None/' lib/board/bin/add-backlog
Exit: 0 green -> 1 red -> 0 green
Verdict: PASS

Command: bash tests/test-learn-propose-precision.sh
Mutation: perl -pi -e 's/^    return sources$/    return sources[:2]/' lib/learn/propose.py
Exit: 0 green -> 1 red -> 0 green
Verdict: PASS
```

The first mutation truncates the anchor back to staging plus board, which is exactly the pre-fix
source list. The suite going red under it is what makes the green attributable to the widening.

## Limits worth stating

- **Exact-key dedup is unchanged.** Widening the SOURCES was the measured win. Loosening the
  MATCHING is a different change with its own false-negative risk, and this data does not
  support it. SPEC-144 chose exact membership on purpose.
- **The 14-day window is a judgment call from one data point.** The measured gap was 16 days.
  A shorter window refuses more real work, a longer one lets more decayed work through. The
  operator can retune it without a code change.
- **The home check needs both halves.** It refuses only when the cited path is absent from the
  named home AND present in this repo. Absence alone would refuse legitimate proposals about
  files that do not exist yet.
- **`tests/test-board-promote.sh` is not in `.github/workflows/test.yml`.** That workflow lists
  suites by hand and misses this one. PR #539 replaces the hand-list with a glob, which picks it
  up. Until that merges, the promote gates are covered locally and not in CI.

## Follow-on

The two paraphrased duplicates are the remaining measurable false-positive class. Closing them
needs fuzzy or embedding-backed matching, which is a separate change with its own precision and
recall trade. Not filed as a row here; the residual is documented above so a future measurement
starts from a known number.
