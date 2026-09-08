# Glossary: the kit's words in plain English

The kit tries to speak the simplest everyday word that fits (see the
[Plain words rule](../CONTRIBUTING.md#plain-words-rule-2026-07-16)). Some coined
or jargon terms still survive in code, config, and file names because renaming
them touches hundreds to a thousand+ files each, a migration project per term,
not a doc sweep. This page is the bridge: it maps each surviving jargon term to
the everyday word so a new reader never has to learn a coined concept to
understand the docs.

Source of the ranked list: `docs/research/2026-07-16-plain-words-inventory.md`.

## Semantic-everywhere terms (ID-293, rename deferred)

These are the load-bearing coined words. Each appears in 300-1000+ files (code
identifiers, config keys, module and file names, test assertions), so a full
rename is its own migration project and is deliberately NOT done here.
Read the plain word; the jargon is what the code still calls it.

| Jargon (in code) | Plain word | What it means |
|---|---|---|
| gate | a check / quality check | A checkpoint at a phase boundary that must pass before the work proceeds (e.g. the ship-gate refuses a push that has no proof of done). "Quality gate" is quasi-standard, so this one may stay. |
| lane | risk level | How much ceremony a task gets, sized to its risk: `tiny` / `normal` / `full`. A one-line typo fix is a low risk level; an auth change is a high one. |
| ledger | a log / an append-only history | The append-only record of what the run did (gates run, tokens spent, overrides). Never edited in place, only appended, so it is an audit trail. |
| mega / mega-goal | a roadmap (multi-goal program) | One destination decomposed into several dependent sub-goals shipped one PR at a time. `bin/mega` drives the reconcile/report/review of such a program. |
| harness | the kit | The whole machinery of this repo (hooks, commands, gates, agents). "The harness" and "the kit" mean the same thing; prefer "kit". |

## Reader-facing jargon (plain word in prose; code name kept)

Lower-blast-radius terms. The code keeps the name; when you write operator-facing
prose, prefer the plain word.

| Jargon | Plain word |
|---|---|
| dispatch | hand work to a worker / send |
| orchestrate | coordinate (run sub-goals together) |
| lens | a review angle |
| verifier | a read-only checker |
| mirror | copy / sync the board out |
| promote | approve a staged item onto the board |
| scaffold | generate the starting skeleton |
| registry | a lookup table / manifest |
| spec-drift | the code no longer matches its spec |
| quiz-gate | the understanding-check nudge |
| over-suggest | the advisor's extra-suggestions mode |
| tombstone | a removed-item marker |
| surface | an operator-facing entry point (the sync-target sense is already "app") |
| phase | one gate checkpoint inside a lane's run (grill, spec, review, ...) |
| stage | one of the five loop stages: Shape / Build / Watch / Check / Learn |
| wayfind | plan a big chunk of work as a shared decision map before splitting it |
| doc-drift | the docs no longer match the code (sibling of spec-drift) |
| topology-drift | the audit of every kit feature against its path map |
| loop-engineering | designing a new bounded scan-fix loop |
| audit-scanner | the shared read-only evidence gatherer (reports findings, never fixes) |
| -team (suffix) | a command that runs a panel of review lenses in parallel |

## Terms kept because they are already standard

These are industry words a user already knows; they earn their keep and are NOT
renamed: `git`, `PR`, `branch`, `commit`, `kanban`, `backlog`, `retro`,
`triage`, `cron`, `worktree`, `snapshot`, `debt`, `intake`, `adopt`, `manifest`,
`contract`, `proof-of-done`, `V-model`, `fan-out`, `wavefront`, `spanner`,
`descent`, `staging`.

## Already renamed (for reference)

The plain-words pass already landed these (old name kept as a legacy alias for
one release where it was a config key or command):

| Old | New |
|---|---|
| edge | profile |
| surface / spoke / sources (sync target) | app |
| hub | board |
| leg | stage |
| Specify / Execute / Observe / Govern | Shape / Build / Watch / Check (Learn kept) |
| verif-counts | verify-counts |
| SDD (first use) | spec-driven development (SDD) |

## The workshop story names (onboarding narrative)

The README quickstart, `/kit:onboard`, and the MANUAL opening tell the loop as one story: an
interview, a night shift, a logbook, an inspector, and a debrief. These are prose only, never
command or file names; the code keeps calling the stages Shape/Build/Watch/Check/Learn.

| Story name | Real name |
|---|---|
| The interview | Shape |
| The night shift | Build |
| The logbook | Watch |
| The inspector | Check |
| The debrief | Learn |

## Why the big five are not renamed here

`gate` (~1016 files), `ledger` (~780), `lane` (~647), `mega` (~532), and
`harness` (~319) are semantic-everywhere: the name is a code identifier, a
config key, a module directory, and a file name, not just prose. Renaming any
one of them is a dedicated migration project with its own PR, legacy-alias
window, and full-suite run. This glossary is the deliberate first slice:
it delivers the onboarding benefit (a reader always has the plain word) without
the destabilising code churn, and it is the precondition ID-293's own backlog
note names ("unpark after the glossary lands").
