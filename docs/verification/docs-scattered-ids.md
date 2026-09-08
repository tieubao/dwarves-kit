# Verification log: stripping pure-id parentheticals from the living docs

Branch `docs/strip-scattered-ids`, base 9c0aad4.

143 tags removed across nine living docs. Scope was deliberately narrow: only a parenthetical
whose ENTIRE content is ids and separators. A sentence therefore never lost information, the
tag went and the claim stayed.

## Green run

Command: `bash tests/test-meta.sh && bash tests/test-docs-wiring.sh && bash tests/test-no-scattered-ids.sh && bash tests/test-no-personal-paths.sh && bash tests/test-command-emit-sweep.sh && bash tests/test-hooks.sh && bash tests/test-wrap.sh`
Exit: 0 for each suite
Output (excerpt): `All meta tests passed.` (840); docs-wiring `25/25 passed`;
`test-no-scattered-ids: all 3 passed`; no-personal-paths, command-emit-sweep, hooks and wrap
each exit 0
Verdict: PASS

## NEGATIVE CONTROL, and the first one was wrong

**First attempt, recorded because it is instructive.** The mutation put ` (SPEC-074)` BACK into
a heading the strip had cleaned, expecting red. It stayed green: `Verdict: FAIL: test stayed
green under the mutation (the check is vacuous)`.

That verdict was misleading and the test was fine. The re-anchored assertion greps
`Lane x type composition`, which is a SUBSTRING of `Lane x type composition (SPEC-074)`, so a
superstring still matches. The assertion's job is to prove the section exists, not to prove it
carries no tag. The mutation tested a property nobody claimed.

**Correct control.** Mutation: rename the heading so the section name is gone.
Command: `bash lib/gate/negctl.sh . "bash tests/test-meta.sh" "<sed renaming the heading>"`
Exit: 0 green before; 1 under mutation; 0 after restore
Output (excerpt): `Exit: 1 (under mutation, RED expected)`; `Verdict: PASS`
Verdict: RED-as-expected. The anchor still detects a missing section, which is what moving it
off the id had to preserve.

## Seven assertions failed first, and they were right to

`tests/test-meta.sh` greps a heading to prove a section still exists, and had used the id as
the anchor text. Five anchors now read the section NAME instead. That is a better assertion:
the section's presence is the thing being pinned, and a number was never what made it present.

Two more wanted a doc to cross-reference an ADR. Those are resolved by the rule's own mechanism
rather than by an exception: `docs/PHILOSOPHY.md`, `docs/architecture.md`, `AGENTS.md` and
`docs/WORKFLOW.md` each gained ONE provenance footer at the bottom, which is exactly where the
rule says a design pointer belongs.

## The transform, and the bug it carries a fix for

`lib/registry/strip-pure-id-parentheticals.py` is committed rather than discarded, because two
batches remain and it encodes a mistake worth not repeating. Its first version tidied
whitespace before punctuation and turned `any .sh file` into `any.sh file`. The rule now fires
only where the punctuation ENDS a token. The space-collapsing pass was removed outright: these
docs are full of ASCII diagrams and aligned tables where a run of spaces is layout, not slop.

Corruption check after the corrected run: `any .sh file` intact, table and diagram spacing
unchanged, 152 lines changed against 143 tags removed.

## Deliberately not done

122 MIXED parentheticals remain, such as `(ADR-0028 P2/P3, kit-hardening SG-08)`. Stripping
only the id there yields `(P2/P3, kit-hardening)`, which reads worse than the original. Each
needs a written sentence, not a regex. They are the next hand pass, not a gap in this one.

The scattered-id ratchet does not gain a docs zone here for that reason: the surface is not
clean yet, and a zone that fails on day one is a zone that gets disabled.
