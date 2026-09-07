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
