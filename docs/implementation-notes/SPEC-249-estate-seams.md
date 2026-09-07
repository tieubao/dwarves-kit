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

## 2026-09-07 validate pass

Context: six reviewers plus the advisor returned 11 critical and 13 warning findings on the first draft.
Decision: one revision, recorded as DEC-006 to DEC-012 in the spec; Status flipped to VALIDATED after the rewrite.
Why: every critical finding named a defect the build would have shipped (parser window, second dedupe grammar, missing write fence, unbound expansion, unregistered env var, the `6b` hedge, the `--quiet` branch).
Alternatives: ship the draft and fix in review; the design-time pass is cheaper.
Impact: task count went from four to six; `tests/test-staging-stage.sh` and `tests/test-config-seams.sh` are new files to register in the workflow.
Open questions: none.

## 2026-09-07 15:40 TASK-001 root-only case lives in kit-config.sh, not test-config.sh

Context: the task text says "one new case in `tests/test-config.sh` on the existing root-only pattern ... around line 134." `tests/test-config.sh` is a 5-line delegator (`bash lib/config/kit-config.sh selftest`); every `chk` case, including the referenced "root-only ignores project override" at line 134, lives in `kit-config.sh`'s own embedded selftest block, not in the test file.
Decision: added the `[knowledge]` fixtures and the two new `chk` cases inside `kit-config.sh`'s selftest, next to the existing operator-overlay cases. `bash tests/test-config.sh` runs them unchanged.
Why: matches the file's real structure; a case added to the 5-line delegator would be dead code, and CONTEXT.md's own line-134 pointer already resolves to `kit-config.sh`, confirming the task description named the wrong file.
Alternatives: duplicate the fixture/case logic into `test-config.sh` directly, bypassing the delegation. Rejected: two copies of the same precedence fixture drift the way DEC-007 in the spec warns against for the staging grammar.
Impact: none outside this task; `bash tests/test-config.sh` still is the acceptance command and still goes green.
Open questions: none.
