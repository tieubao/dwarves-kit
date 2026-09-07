# Implementation notes: SPEC-249 estate seams

Delta from the spec only. Decisions the spec already records are referenced by DEC number.

## 2026-09-07 spec drafting

Context: the decision brief named the report `plugin-check --seams` and the DEBT step as a raw `gate-ledger.sh debt` call.
Decision: `config seams` on `bin/config`, and `significance-classify.sh record` for the marker.
Why: DEC-001 and DEC-002 in the spec.
Alternatives: the brief's names.
Impact: the brief is superseded on those two points; the spec is the contract.
Open questions: none.

## 2026-09-07 research writes landed outside the worktree

Context: two research agents wrote their reports under the main checkout's `docs/research/` and one into the session scratchpad, not the worktree.
Decision: moved the files into the worktree by hand; the main checkout stayed clean.
Why: the agents resolved a relative `docs/research/` against their own cwd.
Alternatives: re-run with absolute paths.
Impact: every later dispatch in this spec names absolute paths under the worktree.
Open questions: none.
