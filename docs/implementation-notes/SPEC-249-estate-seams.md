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

## 2026-09-07 16:20 TASK-003: no deviations; matches SPEC-249 verbatim

Context: `stage` verb on `lib/learn/staging-format.py` per the `### Interfaces` paragraph and edge cases 18, 19, 22, 23.
Decision: implemented `cmd_stage()` exactly as specified: reads one JSON object on stdin, computes `norm(title)`, calls `existing_keys(("staging", staging), ("board", backlog))`, prints `stage: already staged: <title>` and exits 0 on a hit, else renders one block via `render_block` (`u=lo`, `f=mid`, `source=session <today>`), writes a one-line `# Backlog staging\n\n` header (mirroring `lib/session/intel/bin/session-intel`'s pattern) only when the file is absent, appends header+block in one `open(..., "a").write()` call, prints the block's first line, exits 0. An `OSError` around that one write prints `FAILED: <reason>` and exits 2 before any byte lands. Malformed stdin JSON prints a usage-style line and exits 64.
Why: DEC-007 names this module as the one place that owns `norm`/`existing_keys`/`render_block`; the writer composes them instead of copying the grammar into bash.
Alternatives: none considered; the interface paragraph is fully prescriptive.
Impact: `_main`'s usage line and the module's top docstring now name `stage` alongside `parse`/`render`; the "write side" comment above `render_block` now credits `stage` as a third caller alongside drain and propose. New `tests/test-staging-stage.sh` registered in `.github/workflows/test.yml` after the `test-wrap.sh` step. Directory creation for the staging file's parent is deliberately NOT this verb's job (TASK-004's `wrap stage` owns path resolution + fences before calling this writer).
Open questions: none.

## 2026-09-07 17:05 TASK-002: malformed-row cell count uses 4, not 5

Context: the Interfaces paragraph says a malformed seam row has "fewer than three cells"; nothing pins the arithmetic. The first pass counted `${#f[@]}` after `IFS='|' read -ra f <<< "$row"` and used a `-lt 5` threshold, reasoning a well-formed 4-pipe row splits into 5 fields the way `awk` or parameter-expansion splitting would.
Decision: threshold is `-lt 4`. Bash's `read -a` under a non-whitespace `IFS` keeps a LEADING empty field from the opening pipe but drops the TRAILING one from the closing pipe, so `"| Key | Kind | Filled by |"` (3 data cells) splits into exactly 4 array elements, and `"| Key | Kind |"` (2 cells) splits into 3.
Why: verified directly (`IFS='|' read -ra f <<< "$row"; echo "${#f[@]}"`) against both shapes; the `-lt 5` version flagged every well-formed seam row, including the five live ones, as malformed.
Alternatives: switch to `awk`-based field counting (trailing empty preserved) to avoid the asymmetry. Rejected: `_row_get` (existing, unmodified) already relies on the same `read -a` behavior for the six-column registry rows, so a seam-row helper using a different split mechanism would be two inconsistent conventions in one file.
Impact: `_seam_cells` and its `-lt 4` check in `lib/config/config.sh`; `tests/test-config-seams.sh`'s malformed-row fixture row is a real 2-column `"| test.malformed_seam | dir |"` line, verified to trip it.
Open questions: none.

## 2026-09-07 17:05 TASK-002: unregistered seam key treated as malformed

Context: the spec names two failure shapes for `unresolved`'s marker VALUE: a malformed row (`(malformed row)`) and an unknown kind (`(unknown kind)`). It does not say what to print when a seam row has a valid `Key`/`Kind` shape but the `Key` matches no registry row at all (`_find_row` fails) -- a case the live registry can never hit (AC6 in `tests/test-config-registry.sh` lints it) but a fixture registry could.
Decision: that case also reports `VALUE=(malformed row)`, `STATUS=unresolved`, rather than aborting or printing a third marker.
Why: `_seam_resolve` never calls `_resolve` (the invariant), and a key with no registry row has no default/module to join against -- structurally the same problem as a row with no `Filled by` cell, so reusing the existing marker avoids inventing a fourth VALUE string the Interfaces paragraph never names.
Alternatives: a distinct `(unregistered key)` marker. Rejected: unnecessary given the case cannot occur against the shipped registry, and the AC6 lint is the real guardrail.
Impact: none on the live registry's five rows (all pass `_find_row`). Defensive only.
Open questions: none.

## 2026-09-07 TASK-004: cmd_log does not actually call _write_guard

Context: the Interfaces paragraph for `bin/wrap stage` and DEC-008 both say the new writers run "`_worktree_copy` and `_write_guard` exactly as `cmd_log` does." Reading `cmd_log` (lib/wrap/wrap.sh) shows it calls `_realpath_f`, the HOME fence, and `_worktree_copy`, but never `_write_guard`; that helper is only called from `run()`, the apply verb's write wrapper.
Decision: `wrap stage` calls `_write_guard "$repo_top"` before writing (mirroring `run()`'s pattern), and `wrap knowledge-root` calls `_write_guard "$repo_real"` (the `<repo>` argument) before its `mkdir -p`, even though the existing `cmd_log` they were modeled on does not call it.
Why: the Invariants section states the general rule ("every wrap writer runs ... `_write_guard`") plainly, twice, "`knowledge-root` included"; the cross-reference to `cmd_log`'s own behavior is the part that does not match the code. Satisfying the stated invariant over the inaccurate cross-reference keeps both new writers consistent with each other and with `run()`.
Alternatives: skip `_write_guard` entirely, matching `cmd_log` byte-for-byte. Rejected: the invariant is stated as a requirement for `knowledge-root` by name, not as a description of legacy behavior to copy.
Impact: `lib/wrap/wrap.sh` `cmd_stage` and `cmd_knowledge_root`; both fall back (stage: exit 1 fence failure; knowledge-root: repo-local fallback, exit 0) when `_write_guard` reports the checkout locked. No test forces a stale index.lock for these two verbs (the existing apply-verb lock tests already cover `_write_guard` itself); adding one is optional follow-up, not required by the task's acceptance list.
Open questions: none.

## 2026-09-07 TASK-004: basename check uses parameter expansion, not `basename`

Context: the Interfaces paragraph requires "a resolved basename of `.`, `..`, or empty" to exit 64. After `cd "$repo" && pwd -P`, `..` and `.` components are always collapsed by the shell before `pwd -P` ever prints, so a literal `..`/`.` basename cannot survive resolution; the one case that reliably fires is `<repo>` resolving to `/`, and the external `basename` command prints `/` (not empty) for that input on both GNU and BSD.
Decision: compute the basename with parameter expansion (`base="${trimmed##*/}"` on `trimmed="${repo_real%/}"`), which gives `""` for `/`, matching the spec's "empty" case. A repo argument that lexically ends in `/..` against a non-existent intermediate component (e.g. `x/y/..` where `x/y` does not exist) is already refused earlier, by the `cd` failure branch, with the same exit 64.
Why: verified directly; the external `basename` binary and shell parameter expansion disagree only on this one input, and parameter expansion is the one that produces the value the spec names.
Alternatives: call `basename "$repo_real"` and add a special-case for `/`. Rejected: parameter expansion already gives the right answer with no extra branch.
Impact: `cmd_knowledge_root` in `lib/wrap/wrap.sh`; `tests/test-wrap.sh` covers both the `/` case (empty basename, exit 64) and a `/no-such-subdir/..` argument (caught by the earlier `cd` failure, exit 64).
Open questions: none.

## 2026-09-07 16:40 TASK-005: three prose calls the task text left open

Context: the task text names three prose spots to touch, but the spec's own DEC-011 lists only two ("the two prose mentions in `wrap.md` (lines 7 and 35)"), and one of the three (the retro sentence in reflect, "before the report") carries no step number to update, and the "## What this command does NOT do" section carries no existing distill/knowledge bullet to contradict.
Decision: (a) line 7's "each of the eight steps" became "every step below in order," the wording the task text itself offered as the no-digit option. (b) line 35's "step 8's report" became "step 9's report." (c) the reflect step's "before the report" sentence stayed byte-identical: it names no step number, so renumbering left it correct as written. (d) "## What this command does NOT do" stayed unchanged: it names no distill/knowledge/til bullet today, so nothing in it contradicts the new Step 7; the new step's own heading already states the process half lives there.
Why: (a)/(b) are the two mentions DEC-011 identifies by line number. (c)/(d) are "no-op, verified" rather than deviations: editing text that already reads correctly would be churn, not a fix.
Alternatives: word line 7 as a literal count ("ten steps"). Rejected: the task text prefers "every step" when digits would need to track future renumbering, and this step count is exactly the kind of thing a later task changes again.
Impact: `commands/wrap.md` only; `bash tests/test-meta.sh` and `bash tests/test-no-personal-paths.sh` both green (the one pre-existing `docs/FEATURES.md` staleness failure predates this task and is TASK-006's to regenerate).
Open questions: none.

## 2026-09-07 TASK-006: heading placed as `## C2. Overlays and seams`

Context: the task text allows `## Overlays and seams` or a `###` variant "if the file's heading depth calls for it," graded only by a case-insensitive grep on the phrase. `commands/onboard.md` numbers its top-level sections `## A.`/`## B.`/`## C.`/`## D.`/`## D2.`/`## E.`/`## F.`/`## G.`, with `D2` already an established sub-lettered pattern for a section that belongs conceptually inside the surrounding step.
Decision: used `## C2. Overlays and seams` in `onboard.md`, inserted between section C ("Pick the modules, then adopt in ONE call," the module bridge) and section D, matching the file's own lettering convention rather than a bare `## Overlays and seams` heading. `commands/adopt.md` has no such lettering scheme, so it got the plain `## Overlays and seams` heading, placed after the "What adoption installs" paragraph (which discusses `[modules]`) and before `## Do NOT`.
Why: the acceptance grep only checks the phrase case-insensitively, so either heading form satisfies it; matching the file's existing convention is the "existing voice" instruction and avoids an inconsistent, unlabeled section breaking the A-G flow.
Alternatives: a bare `## Overlays and seams` in onboard.md too. Rejected: it would read as a new top-level stage on par with A-G rather than a note attached to the module-choice step, which is not what the section is.
Impact: `commands/onboard.md`, `commands/adopt.md`. `docs/FEATURES.md` regenerated via `bash lib/registry/feature-registry.sh generate`; its onboard/adopt row Spec counts bumped by 1 each because SPEC-249 itself names `/kit:onboard` and `/kit:adopt` in TASK-006's text (the exact-token grep over `docs/specs/`), not because of any new reference these edits added. `bash tests/test-meta.sh` (840/840) and `bash tests/test-no-personal-paths.sh` (3/3) both green.
Open questions: none.

## 2026-09-07 integration pass: log-dir resolver is source-only

Context: the integration verifier ran every command Step 7 names; `bash lib/telemetry/kit-log-dir.sh` prints nothing because the file is a sourced library with an early-return guard, so Step 7a would always print `skipped: no run log`.
Decision: both mentions in `commands/wrap.md` (Step 7a, and the pre-existing one in the reflect step) now use `bash -c 'source lib/telemetry/kit-log-dir.sh; kit_resolve_log_dir'`.
Why: every other consumer sources the file; the command prose was the only caller running it.
Alternatives: add a standalone mode to the library; out of scope for a doc build.
Impact: the reflect step fix is a pre-existing defect repaired in passing, not a build regression.
Open questions: `wrap knowledge-root` on a non-git directory falls back with the reason `index.lock held by another writer` because `_write_guard` returns 1 when `git rev-parse` fails; the fallback is right, the reason text is misleading. Left for a follow-up row.

## 2026-09-07 17:07 review fix batch A: config seams hardening

Context: a review pass on `lib/config/config.sh` found one confirmed command-execution path, two advisor-drift defects, one untested branch, and one stale registry description.

Decision: add `_env_val NAME`, which returns an env value only when NAME matches a shell identifier and returns 1 otherwise; call it from `_resolve` and `_seam_resolve`. Fence `file` and `dir` seam targets to a realpath under `$HOME`. Stop `_seam_rows` at the next top-level `## ` heading, in the engine and in the lint copy. Add fixture coverage for the `_find_row` failure branch. Add `wrap` to both `BACKLOG_STAGE_*` Module cells with the defaulting clause.

Why: bash evaluates an array subscript during indirect expansion, so a registry cell of `EVIL[$(cmd)]` ran cmd on `"${!cell:-}"`, and `CONFIG_REGISTRY_FILE` is an unvalidated env override. Confirmed by exploit: a canary file appeared after both `config seams` and `config list`. The seam consumers (`wrap log`, `wrap knowledge-root`) already refuse a target outside `$HOME`, so bare existence made `config seams --check` exit 0 on a root the consumer rejects. The seam window ran to end of file while the lint stopped at the literal `## Known gaps`, so any future pipe table after `## Seams` would be read as seam rows by one and not the other. `wrap stage` reads both `BACKLOG_STAGE_*` knobs and defaults instead of erroring when they are unset, which the rows denied.

Alternatives: `eval` with a quoted name (same class of risk, no gain); an allowlist of known env names (breaks on every new registry row); dropping the indirect expansion for a `printenv` call (loses set-but-empty semantics `_resolve` depends on); keeping bare existence and fixing the consumers instead (the fence is the consumer contract, not a bug).

Impact: `bin/config seams` output shape is unchanged on this checkout, header plus five rows, every live row still `filled` or `default`. A malformed env-var cell now resolves as unset in `_resolve` and as `unresolved` / `(malformed row)` in `_seam_resolve`. A `file` or `dir` seam target outside `$HOME` flips from `filled` to `unresolved`, which makes `--check` exit 1 where it used to pass.

Open questions: the `binary` kind still accepts any executable path, with no `$HOME` fence, because `PROSE_RAG_BIN` legitimately resolves under `/usr/local` or a PATH entry. Whether a binary seam deserves its own allowlist is a separate call.

## 2026-09-07 17:12 review fix batch B: wrap write fences

Context: a review pass on `lib/wrap/wrap.sh` reproduced a redirected append. `cmd_stage` and `cmd_log` ran the symlink refusal, the regular-file check and the HOME fence on the path BEFORE `_worktree_copy` swapped in the current worktree's own copy, and `_worktree_copy` gates that copy with `[ -f ]` alone, which follows a symlink. Three further findings: `cmd_knowledge_root` fenced `<root>` and then created `<root>/projects/<basename>` through whatever `projects` pointed at, the `BACKLOG_STAGE_STAGING` override accepted an absent leaf anywhere under HOME, and the python append reopened the path by name after the bash check.

Decision: extract `_home_fence <path> [label]` and `_refuse_symlink <path> [label]`, and use them at all three fence sites. Re-run the symlink refusal and the fence on the POST-copy path in both `cmd_stage` and `cmd_log`; for `stage` the post-copy location rule is the repo toplevel or the current worktree toplevel by default, and HOME for the env override. In `cmd_knowledge_root`, refuse a symlink at `projects` and at the leaf, then re-resolve the created directory and fence it again. Require an existing regular file when the env override chose the staging path; the repo default keeps create-on-absent. Open the append with `os.open(..., O_WRONLY|O_APPEND|O_CREAT|O_NOFOLLOW, 0o644)` plus `os.fdopen`.

Why: a symlink planted at `_meta/backlog-staging.md` inside a worktree redirected a staged block to any file on disk, and the same order made `wrap.activity_log` writable outside HOME. The override reaches wrap through the environment, which a repo `.envrc` writes, so create-on-absent under HOME let it seed a staging block into an agent instruction file with operator authority. `O_NOFOLLOW` closes the window between the bash check and the python open.

Alternatives: keep the fences where they are and tighten `_worktree_copy` to reject a symlink itself (one caller could still hand it a pre-copy path that changes later, and the helper would then own a policy its callers vary on); drop `_worktree_copy` and always write the configured path (loses the committable-line property the worktree copy exists for); resolve the staging path with realpath before every write (defeats create-on-absent for the default path).

Impact: `wrap stage` with `BACKLOG_STAGE_STAGING` pointing at an absent file now exits 1 instead of creating it. `wrap knowledge-root` falls back to `<repo>/.claude/memory` when `projects` is a symlink. Every other path keeps its behavior. Test counts: `tests/test-wrap.sh` 192, `tests/test-staging-stage.sh` 24.

Open questions: `_worktree_copy` still returns a path on a `[ -f ]` gate that follows symlinks. The callers re-fence, and the helper carries a comment saying they must, but a future third caller can forget. Whether the helper should refuse a symlink itself is a follow-up call.

## 2026-09-07 17:33 review fix batch C: resolve before fence

Context: batch B left the post-copy re-fence running on an UNRESOLVED string. A symlink at a PARENT directory of the worktree copy (`wt/_meta` pointing at a directory outside HOME) passed `_refuse_symlink`, which inspects the leaf only, and passed `_home_fence` and the repo-prefix rule, which both matched the string's prefix. Reproduced: `wrap log` and `wrap stage` each wrote outside HOME and exited 0. Three smaller gaps: `_home_fence` refused a path equal to `$HOME` while `_under_home` accepted it, so `config seams` called a root `filled` that `wrap knowledge-root` rejected; `_skill_dirs` hand-rolled the prefix case `_under_home` owns; the seam report's `file` check followed a leaf symlink.

Decision: resolve the copied path with `_realpath_f` immediately after `_worktree_copy` in both `cmd_log` and `cmd_stage`, then fence the resolved value against the realpath'd `repo_top` and `cur_top`. Make `_home_fence` resolve its own argument and accept `$HOME` itself. Migrate `_skill_dirs` to `_under_home`. Add `[ ! -L ]` to the seam `file` check.

Why: a leaf-only refusal plus a prefix match on a string is not a fence. The resolution has to happen on the exact value the write uses, and putting it inside `_home_fence` means a future caller cannot forget it. HOME-equality parity closes the case where the advisor and the consumer disagree on the same path.

Alternatives: refuse a symlink at every component of the copied path (more code, same outcome as one realpath); make `_worktree_copy` itself return only resolved paths (the helper would then own a policy its callers vary on, the open question batch B left); document that callers must resolve first (batch B already tried that shape and this bug is what it cost).

Impact: `wrap log` and `wrap stage` refuse a worktree copy reached through any symlinked parent, exit 1, nothing written. `wrap knowledge-root` accepts `knowledge.root` equal to `$HOME`. A symlinked `wrap.activity_log` under HOME reads `unresolved` in `config seams` instead of `filled`. Test counts: `tests/test-wrap.sh` 201, `tests/test-config-seams.sh` 37.

Open questions: `_realpath_f` on `/` returns `//`, which every fence refuses, so no caller is wrong today, but the degenerate return is not obviously correct for a future caller.
