# Verification log: the provenance rule and its ratchet lint

Branch `feat/provenance-rule`, base b46e1bf.

The previous batch stripped ids from 22 printed strings and recorded an honest gap: no test
asserted on those strings, so a future edit could reintroduce one silently. This closes it.

## Green run (cc57cfb)

Command: `bash tests/test-no-scattered-ids.sh && bash tests/test-meta.sh && bash tests/test-docs-wiring.sh && bash tests/test-command-emit-sweep.sh && bash tests/test-no-personal-paths.sh`
Exit: 0 for each suite
Output (excerpt): `test-no-scattered-ids: all 3 passed`; `All meta tests passed.` after regenerating
`docs/FEATURES.md`; docs-wiring `25/25 passed`; command-emit-sweep and no-personal-paths green
Verdict: PASS

## NEGATIVE CONTROL (cc57cfb)

Command: `bash lib/gate/negctl.sh . "bash tests/test-no-scattered-ids.sh" "<sed reintroducing a spec tag into a gate-ledger message>"`
Exit: 0 green before; 1 under mutation; 0 after restore
Output (excerpt): `Exit: 1 (under mutation, RED expected)`; `Verdict: PASS`
Verdict: RED-as-expected. Putting a stripped id back into a printed string turns the suite red,
which is precisely what nothing did before this branch.

## The lint found a defect the hand sweep missed

Its first run failed Zone 2 on `commands/execute.md`, carrying the same
`no deviations` instruction with a bracketed id token that had been fixed in `commands/next.md`
an hour earlier. Two emitters, one found by reading, one found by the check. That is the
argument for the check.

## Why a ratchet and not an audit

The repo carries roughly 2,600 scattered ids predating the rule. A lint over all of them fails
on day one and gets disabled by Tuesday. This one guards the zones already clean and gains a
zone per cleanup batch. The third assertion pins the rule text in `CONTRIBUTING.md`, so the
lint cannot outlive its own documentation.

Zones today: printed strings under `hooks/` and `lib/`; instructions in `commands/` that emit
an id. Zones still unguarded, matching the batches not yet done: living docs, the prompt-layer
bodies, non-string code comments, test comments.

## Exemptions, each a real one

- A printf substitution whose VALUE is the number a worker acts on.
- `lib/*/tests/`: test-progress echoes, never operator-facing.
- A quoted data key the code reads, such as a `tool.toml` board row.
