# Verification log: bin/mega status and the SG-NN grammar

Branch `fix/mega-status-sg-grammar`, base 24ac3a8 (origin/master at start).

Two sub-goal id grammars are live in one subsystem. `/kit:mega` scaffolds `SG-NN`
(`commands/mega.md`) and `lib/queue/orchestrate.sh:333` parses it. `lib/mega/mega.sh:282`
required a digit immediately after the checkbox, so `SG-01` never matched.

## The defect, reproduced before the fix

Command: feed both grammars to the pre-fix regex `^-\ \[(.)\]\ ([0-9]+-[A-Za-z0-9_-]+)`
Input: `- [x] SG-01 Collapse the module , auto` and `- [ ] SG-02 Wire the seam , gate`
Output: `NO MATCH` for both lines
Verdict: CONFIRMED. `bin/mega status` is the reconciler that flags `MERGED-UNCHECKED`,
`CLAIM-UNVERIFIED` and `STALLED` by diffing a roadmap's claims against git and PR truth.
Against a current-grammar roadmap it matched zero rows, found zero drift, and reported
success. A checker that cannot see its input passes, which is the worst failure mode a
reconciler has.

## Green run (585b79d)

Command: `bash tests/test-mega.sh`
Exit: 0
Output (excerpt): `ok - status parses the current SG-NN grammar (the form /kit:mega scaffolds)`;
`ok - status sees an unchecked SG-NN row too, not just the checked one`; `PASS=18 FAIL=0`
(16 before, 2 new)
Verdict: PASS

The new fixture is deliberately written in the CURRENT grammar. Every pre-existing fixture
used `NN-slug`, and `SG-` appeared nowhere in the suite, which is precisely why the suite
could not have caught this.

## NEGATIVE CONTROL (585b79d)

Command: `bash lib/gate/negctl.sh . "bash tests/test-mega.sh" "<sed reverting the regex to the old-only form>"`
Exit: 0 green before; 1 under mutation; 0 after restore
Output (excerpt): `Exit: 1 (under mutation, RED expected)`; `Verdict: PASS`
Verdict: RED-as-expected. Restoring the old-only regex turns the suite red, so the new cases
test the parser rather than the fixture.

## Scope

Latent, not live: no non-archived megagoal in this repo uses `SG-NN` yet, so nothing was
mis-audited in practice. That makes this the cheapest moment to fix it. Both grammars are
accepted; no archived roadmap changes behavior.
