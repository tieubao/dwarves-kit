# Verification log: SPEC-249 estate seams

Spec: `docs/specs/SPEC-249-estate-seams.md`. Branch `feat/estate-seams`, base 1d50cc3 (origin/master 80be35a plus the spec commits).

## Spec gates

spec-validate (six reviewers) plus advisor over-suggest: NEEDS REVISION on the first draft (11 critical, 13 warnings), one revision recorded as DEC-006 to DEC-012, then VALIDATED. design-record: design-bearing, sequence diagram present, pass.

## TASK-001 (d9ebc00): knowledge root key and seam registry

Command: `bash tests/test-config-registry.sh && bash tests/test-config.sh`
Exit: 0
Output (excerpt): `=== 23/23 passed ===` (AC6 seam keys match registry rows, AC7 kinds valid, AC8 no seam row leaks into `config list`); `PASS kit-config selftest` with the two root-only `knowledge.root` cases.
Verdict: PASS (task-verifier: 6/6 criteria; `## Seams` at registry line 350 after `## Allowlist` at 319; `bin/config list | grep -c knowledge.root` is 1; no dashes or personal paths in the diff).
Re-audit: PASS (recheck-verifier re-ran the command and the three hand checks from fixtures outside the repo; added a non-vacuity probe: `kit_config_get knowledge.root` sees the project value while `kit_config_get_root` returns empty, so the ignore comes from the root-only rule). Note for re-runners: `KIT_CONFIG_OPERATOR` names a directory holding `kit.toml`, not a file.

## TASK-003 (eaa7682): staging-format stage verb

Command: `bash tests/test-staging-stage.sh && bash tests/test-learn-propose.sh && bash tests/test-learn-drain.sh`
Exit: 0
Output (excerpt): `21 run, 21 passed, 0 failed`; `42 run, 42 passed, 0 failed`; `TOTAL: 23 PASS: 23 FAIL: 0`.
Verdict: PASS (task-verifier: 8/8; hand checks in a temp dir: header on create, parse round-trip, case/spacing/punctuation and board-Item dedupe byte-identical no-ops, chmod 000 target `FAILED:` exit 2 with nothing written; `cmd_stage` uses the module's own `norm`/`existing_keys`/`render_block` and one write).
Re-audit: PASS (recheck-verifier re-ran the three suites and five hand cases from a scratch dir; md5 of the staging file unchanged across both dedupe cases; the board branch of `existing_keys` fires in practice; `FAILED:` goes to stdout, matching the interface).

## TASK-002 (8c7bc41): config seams report

Command: `bash tests/test-config-seams.sh && bash tests/test-config-registry.sh && bash tests/test-config.sh`
Exit: 0
Output (excerpt): `=== 24/24 passed ===`; `=== 23/23 passed ===`; `PASS kit-config selftest`.
Verdict: PASS (task-verifier: 9/9; `bin/config seams` prints five rows, `--check` rc matches; sandboxed checks: project toml value never leaks, a `KIT_SKILL_DIRS` entry outside HOME stays `unresolved`, `PROSE_RAG_BIN` unset with a scoped empty PATH gives `absent`, a non-executable gives `unresolved`, missing registry exits 1; `_seam_resolve` never calls `_resolve` and only probes with `command -v` / `-x`).
Re-audit: PASS (recheck-verifier re-ran the suites and six sandboxed checks; planted an executable `prose-rag` stub that prints a canary and the canary never appeared, so the verb resolves without executing; the `Command:` lines in this log assume the worktree root as cwd).

## TASK-004 (b945497): wrap knowledge-root and stage verbs

Command: `bash tests/test-wrap.sh && bash -n lib/wrap/wrap.sh && bash tests/test-bin-forwarders.sh`
Exit: 0
Output (excerpt): `test-wrap: all 180 passed` (39 new cases); `test-bin-forwarders: all 41 passed, 0 skipped`.
Verdict: PASS (task-verifier: 9/9; temp-HOME hand checks: empty key → repo-local and nothing created; filled existing root → `<root>/projects/<basename>`; missing, outside-HOME, and symlink-outside-HOME roots fall back with the stderr line and create nothing; `/` and no arg exit 64; stage creates the file, dedupes on case/spacing/punctuation, refuses a symlink and an outside target with nothing written, honours `BACKLOG_STAGE_STAGING`, writes the worktree's copy from a worktree, relays `FAILED` exit 2; JSON built through python `sys.argv`).
Re-audit: PASS (recheck-verifier re-ran the three commands and eleven hand cases in a temp HOME; a missing fence would have created a directory outside HOME or written through a symlink and none did; JSON goes through `sys.argv` at wrap.sh:764-772; note for re-runners: `_worktree_copy` no-ops when the worktree checkout lacks the file, so the worktree case needs the staging file committed first).

## TASK-005 (be23314): wrap.md Step 7 learn

Command: `bash tests/test-meta.sh; bash tests/test-no-personal-paths.sh`
Exit: 0
Output (excerpt): `Passed: 839 / 840` with the one failure `docs/FEATURES.md is fresh` owned by TASK-006; `Passed: 3 / 3`.
Verdict: PASS (task-verifier: 8/8; `### Step` sequence -1, 0..9 in order; five verbs present and their live usage matches; seven idle lines present; no dashes or contractions in the new text). Documentation task: the mechanical checks are the greps above; the prose judgment is the lead's review of the verbatim step in the worker report.

## TASK-006 (098f626): overlays and seams sections, FEATURES regenerated

Command: `bash tests/test-meta.sh && bash tests/test-no-personal-paths.sh && bash lib/registry/feature-registry.sh generate && git diff --stat docs/FEATURES.md`
Exit: 0
Output (excerpt): `Passed: 840 / 840` including `docs/FEATURES.md is fresh`; `Passed: 3 / 3`; empty diff after regenerate.
Verdict: PASS (task-verifier: 5/5; both command docs carry the section; the facts match the live `## Seams` table and the `--check` exit at config.sh:333).

## Green run (lead, worktree at 098f626)

Command: `bash tests/test-config-registry.sh && bash tests/test-config.sh && bash tests/test-config-seams.sh && bash tests/test-staging-stage.sh && bash tests/test-wrap.sh && bash tests/test-meta.sh && bash tests/test-no-personal-paths.sh`
Exit: 0
Output (excerpt): `=== 23/23 passed ===`; `PASS kit-config selftest`; `=== 24/24 passed ===`; `21 run, 21 passed, 0 failed`; `test-wrap: all 180 passed`; `Passed: 840 / 840`; `Passed: 3 / 3`.
Verdict: PASS

## NEGATIVE CONTROL (lead, throwaway worktree at 098f626, removed after)

Command: `bash lib/gate/negctl.sh <throwaway> "bash tests/test-config-seams.sh" "sed -i '' 's|/^## Seams/ {inseam=1; next}|/^## Seamz/ {inseam=1; next}|' lib/config/config.sh"`
Exit: 0 green before; 1 under mutation; 0 after `git checkout HEAD -- lib/config/config.sh`
Output (excerpt): negctl `Verdict: PASS`; with the seam-table marker broken the report prints zero rows and the five-row and status cases go red.
Verdict: RED-as-expected

Command: `bash lib/gate/negctl.sh <throwaway> "bash tests/test-wrap.sh" "<python edit that swaps the knowledge-root case arms so the outside-HOME fence never fires>"`
Exit: 0 green before; 1 under mutation; 0 after restore
Output (excerpt): negctl `Verdict: PASS`; with the fence disabled the outside-HOME and symlink-outside-HOME cases go red (a directory gets created under the rejected root).
Verdict: RED-as-expected; the shared worktree was never mutated.

Proof class: behavioral (`config seams`, `wrap knowledge-root`, `wrap stage`, `staging-format.py stage` change what the kit does); the green run above exercises the primary flows directly, the negative controls bite on both the config and the wrap side.

## INTEGRATION (a933149)

Command: the spec's `## Verification` line verbatim, plus `grep -n 'kit-log-dir' commands/wrap.md`, `bash bin/config seams`, `bash bin/wrap knowledge-root .`, and the Step 7a walk (rid, log dir, run log, DEBT grep)
Exit: 0
Output (excerpt): first pass FAIL:fixable, one wiring gap (Step 7a ran the source-only `kit-log-dir.sh` as a command, so the step could never reach the classifier); fixed in a933149; second pass PASS: 5/5 components reach their activation point, 4/4 chains connected, seven suites green, seams prints five rows, knowledge-root falls back to `<worktree>/.claude/memory`, 7a on this run would call `significance-classify.sh record estate-seams`.
Verdict: PASS
Re-audit: folded into the battery (acceptance-verifier re-executes the suite and the After-state commands in fresh context).

## REVIEW FIX BATCH (4b32c0c, 9fd15ee, 79e2b5c): green run at d97b1fe

The three review-team fix commits changed `lib/config/config.sh` and `lib/wrap/wrap.sh` under the earlier entries, so the run above is superseded by this one.

Command: `bash tests/test-config-registry.sh && bash tests/test-config.sh && bash tests/test-config-seams.sh && bash tests/test-staging-stage.sh && bash tests/test-wrap.sh && bash tests/test-meta.sh && bash tests/test-no-personal-paths.sh`
Exit: 0
Output (excerpt): `=== 23/23 passed ===`; `PASS kit-config selftest`; `=== 37/37 passed ===`; `24 run, 24 passed, 0 failed`; `test-wrap: all 201 passed`; `Passed: 840 / 840`; `Passed: 3 / 3`.
Verdict: PASS

## NEGATIVE CONTROL (lead, throwaway worktree at d97b1fe, removed after)

Command: `bash lib/gate/negctl.sh <throwaway> "bash tests/test-config-seams.sh" "<sed that widens _env_val's identifier guard to accept any non-empty name>"`
Exit: 0 green before; 1 under mutation; 0 after `git checkout HEAD -- lib/config/config.sh`
Output (excerpt): negctl `Verdict: PASS`; with the guard widened the forged-registry canary cases and the malformed-row cases go red.
Verdict: RED-as-expected

Command: `bash lib/gate/negctl.sh <throwaway> "bash tests/test-wrap.sh" "<sed that makes _home_fence return 0 for every path>"`
Exit: 0 green before; 1 under mutation; 0 after restore
Output (excerpt): negctl `Verdict: PASS`; with the fence disabled the outside-HOME knowledge-root cases and the parent-symlink worktree cases for `stage` and `log` go red.
Verdict: RED-as-expected; the shared worktree was never mutated.

Exploit re-verification (security lens, fresh context, temp HOME): forged env-name canary never created through `config seams` or `config list`; worktree leaf symlink, parent-directory symlink outside HOME, parent symlink inside HOME but outside the repo, and a two-hop chain all refused for `stage` with byte-identical canaries; `log` refuses the outside-HOME shapes (its fence is HOME-only by spec); symlinked `<root>/projects` falls back with nothing created; absent env-override staging target refused; symlinked python target `FAILED` exit 2. Record: the spec's `## Review` section.
