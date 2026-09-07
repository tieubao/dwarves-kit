# Verification log: precedent inventory iterators restored

Spec: `docs/specs/SPEC-245-precedent-inventory.md`. Branch `fix/precedent-iterators`, base `origin/master`.
Lane: `normal` (`lib/classify/lane-classify.sh classify` -> `normal`).
Proof-gate contract (`lib/gate/proof-gate.sh contract "restore precedent inventory iterators"`):
`type=migration class=stateful`, so this log carries a recorded run AND a rollback path, even
though the change itself is inert library code with no persisted state.

Rollback: `git revert <merge sha>`. The change touches one Python module, one test file, and one
spec paragraph. `inventory.py` is read-only over every source it scans, so no revert has to undo
any written state.

## What changed

An audit compared `precedent find --surface inventory` against the `repo-sweep whathas` command
it replaced, on the same on-disk state, and found five iterators narrower than the original.
All five are restored:

| # | Iterator | Before | After |
|---|---|---|---|
| 1 | research records | `research/` never read | `<repo>/research/*.md` scanned per `repo` registry row, indexed by frontmatter title, purpose, description |
| 2 | tool helper scripts | `tool.toml` + `tools/<x>/bin/*` only | plus `tools/<x>/scripts/`, `tools/<x>/lib/`, and top-level `tools/<x>/*.sh` and `*.py` |
| 3 | experiments | frontmatter title or description, else the first `#` heading | plus the `tech:` tag list and the README lede |
| 4 | PEP-723 header | inline `# /// script` metadata indexed as the summary | the block is skipped, the docstring underneath is indexed |
| 5 | duplicate skill label | one skill copied into two scanned dirs printed twice under an identical bare label | first dir wins, keyed on the resolved real path and on the directory name |

## Run table

| Command | Exit | Verdict |
|---|---|---|
| `bash tests/test-precedent.sh` | 0 (`64/64 passed`) | PASS |
| `bash tests/test-meta.sh` | 0 (`Passed: 840 / 840`) | PASS |
| `bash tests/test-hooks.sh` | 0 (`Passed: 497 / 497`) | PASS |
| `bash tests/test-bin-forwarders.sh` | 0 (`all 41 passed, 0 skipped`) | PASS |
| `bash tests/test-no-personal-paths.sh` | 0 (`Passed: 3 / 3`) | PASS |
| `bash tests/run-workflow.sh` | 0 (`0 red of 70 steps`, first run; `1 red` on a later run, see below) | PASS |

The one red on a later full-suite run is `tests/test-orchestrate-wavefront.sh`
(`wave_run g: concurrency NOT proven`). It is environmental, not this diff: the branch touches
no file under its subject, the same suite ran green on this branch earlier in the session, and
run alone it passes twice in a row (`rc=0`, `rc=0`). SPEC-245's own proof of done records the
same suite failing this way on this host with a run-to-run varying count, the timing signature
of its mock-session markers.

The sixteen new cases in `tests/test-precedent.sh` (48 before, 64 after) cover every restored
iterator and every guard inside it: a research record reached only through `purpose:`, a
`tools/<x>/scripts/` helper, a `tools/<x>/lib/` helper, a top-level `tools/<x>/*.py` entry
point, an experiment whose subject lives only in `tech:`, the same experiment reached through
its lede, a PEP-723 docstring hit, a PEP-723 dependency-list non-hit, a skill copied into two
scanned dirs printing one label, a symlinked skill dir under another name collapsing by real
path, a non-runnable file under `bin/` staying out, a `test`-prefixed helper staying out, the
research dir's own `README.md` staying out, a stray `tools/.DS_Store` not aborting the scan,
and redaction reaching both a research record's frontmatter and a tool helper's header.

## Negative controls

Each restored iterator was reverted one at a time on the branch, the suite re-run, and the file
restored. Every revert turned its own case or cases red and left the rest green, so no case
passes for a reason other than the fix.

```
=== negative control 1-research: rc=1 ['62/64 passed']
    FAIL research records: a frontmatter purpose hit surfaces the research file
    FAIL redaction reaches a research record's frontmatter
=== negative control 2-tool-helper-subdirs: rc=1 ['61/64 passed']
    FAIL tool helpers: a tools/<x>/scripts/ helper surfaces
    FAIL tool helpers: a tools/<x>/lib/ helper surfaces
    FAIL redaction reaches a tool helper script's comment header
=== negative control 2b-toplevel-tool-scripts: rc=1 ['63/64 passed']
    FAIL tool helpers: a top-level tools/<x>/*.py entry point surfaces
=== negative control 2c-runnable-filter: rc=1 ['63/64 passed']
    FAIL tool helpers: a non-executable, non-script file under bin/ is not indexed
=== negative control 2d-test-prefix-skip: rc=1 ['63/64 passed']
    FAIL tool helpers: a test-prefixed helper is not indexed
=== negative control 2e-stray-file-guard: rc=1 ['20/64 passed']
    (44 of 64 cases red: every query dies on NotADirectoryError; the one
     new case for it is 'a stray non-directory entry under tools/ does not abort the scan')
=== negative control 3-experiments: rc=1 ['62/64 passed']
    FAIL experiments: a frontmatter tech: tag is searchable
    FAIL experiments: the README lede is searchable
=== negative control 4-pep723: rc=1 ['62/64 passed']
    FAIL PEP-723: the docstring under a # /// script block is indexed
    FAIL PEP-723: the inline dependency list is not indexed
=== negative control 5a-skill-dedupe-dirname: rc=1 ['62/64 passed']
    FAIL skills dedupe: a skill copied into two scanned dirs prints exactly one label
    FAIL skills dedupe: a symlinked skill dir under another name collapses by real path
=== negative control 5b-skill-dedupe-realpath: rc=1 ['62/64 passed']
    FAIL skills dedupe: a skill copied into two scanned dirs prints exactly one label
    FAIL skills dedupe: a symlinked skill dir under another name collapses by real path
=== negative control 6-research-readme-skip: rc=1 ['63/64 passed']
    FAIL research records: the dir's own README index is not indexed as a record
```

Mutations used, one per run: drop the `scan_repo_research` call; narrow the helper subdir tuple
to `("bin",)`; drop the top-level `tools/<x>/*.sh|*.py` candidate list; drop the
`is_executable_or_shell` filter; drop the `test`-prefix skip; drop the non-directory guard; drop
`tech` and the lede from the experiment haystack; drop the `# /// script` skip; drop each arm of
the skill dedupe in turn; drop the research `README` skip.

## Live before / after

Master's `inventory.py` and this branch's, run against the same on-disk ops-toolkit checkout
(the operator's, path elided here so the tree ships no personal path):

```
python3 lib/precedent/inventory.py --root <ops-toolkit checkout> \
  --kit <this worktree> --quiet -- discord post
```

BEFORE (master):

```
precedent: 88 inventory hits in 7 sections; top: skills
```

No `## research` section, no `## experiments` section.

AFTER (branch):

```
## research
  research/2026-09-07-foundation-ops-shared-lib-map.md  , foundation-ops shared-lib map, and why precedent could not see the duplication
  research/2026-08-30-etl-and-discord-report-inventory.md  , Estate inventory, scheduled ETL pipelines and Discord reporting paths
## experiments
  experiments/discord-user-send/  , discord-user-send
  experiments/fare-watch/  , fare-watch
precedent: 95 inventory hits in 9 sections; top: skills
```

`research/2026-09-07-foundation-ops-shared-lib-map.md` and two of the three named experiments
appear after and not before. `experiments/payout-batch-replay/` does not match this query in
either implementation: its README frontmatter, `tech:` list, and first twelve body lines carry
neither `discord` nor `post`, so the AND scorer gives it 0 under whathas's own rules too. It
surfaces on a query its README does carry: `paginate notion` prints
`experiments/payout-batch-replay/` on this branch and nothing on master, because the lede is the
only place those words appear.

Two more before/after pairs, same command shape:

| Query | Before | After |
|---|---|---|
| `cf worker state` | `32 inventory hits in 2 sections` | plus `tools/vps-mon/scripts/cf-worker-state.sh` |
| `benchmark ollama` | `3 inventory hits in 2 sections` | plus `tools/llm-bench/bench.py` (PEP-723 header skipped, docstring indexed) |
| `scaffold tool` | `skill ops-tool-shape` printed twice | printed once |

## Known deltas from the original whathas

- Helper scripts now inherit whathas's own filter: a candidate must be executable or end in
  `.sh` or `.py`, and a name starting with `test` or `.` is skipped. A non-executable,
  extensionless file directly under `tools/<x>/bin/` is therefore no longer indexed.
- `scan_repo_tools` skips a non-directory entry beside the tool dirs. A stray `.DS_Store` under
  `tools/` crashed the scan before this guard.
- Memory notes stay searched by body, wider than whathas's frontmatter-only scan. Recorded in the
  spec as DEC-006.
- A `tools/<x>/scripts` or `lib` symlinked outside the repo root is still followed and indexed,
  as it was for `bin/` before this change. whathas had no confinement here either. Left as is
  rather than adding a guard that would silently drop a legitimate symlinked helper; the review
  raised it as LOW.

## Review

Three lenses, parallel, on the working tree before commit (the diff touches `lib/`, so AGENTS.md
requires a multi-lens review). Security 8/10, architecture 7/10, test coverage 6/10.

| # | Finding | Lens | Sev | Disposition |
|---|---|---|---|---|
| 1 | The dedupe keyed on the frontmatter `name:`, which the scanned repo controls, so a repo-local skill in any directory could suppress the operator's own skill of that name. Reproduced. | security | MEDIUM | fixed: key on the DIRECTORY name plus the real path, never the frontmatter name |
| 2 | A symlinked `scripts`/`lib` under a tool is followed out of the repo root. | security | LOW | accepted, recorded above; pre-existing for `bin/`, matches whathas |
| 3 | No case pinned redaction on the new hit surfaces. | security | LOW | fixed: two cases, a token in a research `title:` and one in a helper's header |
| 4 | The new runnable-file check duplicated `is_executable_or_shell` inline and widened it to `.py`. | architecture | MEDIUM | fixed: one helper, `exts` parameter, both call sites |
| 5 | The spec's Picture and registry-kinds table no longer described what a `repo` row scans. | architecture | MEDIUM | fixed: both list `research/*.md` and the widened tool-helper set |
| 6 | The memory-body line sat under Out of Scope, a section of exclusions, while describing something the port DID. | architecture | LOW | fixed: moved to the Decision Log as DEC-006 |
| 7 | `FRONTMATTER_PURPOSE_RE` declared mid-file, away from its three siblings. | architecture | LOW | fixed: moved to the constants block |
| 8 | `--explain` cannot resolve a tag-prefixed label from a secondary `repo` registry row. | architecture | LOW | advisory, pre-existing for `bin/`, `cli/`, `experiments/`; not this diff's job |
| 9 | Five behaviors inside the restored iterators had no case: the runnable-file filter, the `test`-prefix skip, the non-directory guard, the research `README` skip, and the realpath arm of the dedupe. Each survived deletion with the suite green. | test-coverage | HIGH / MEDIUM | fixed: six cases added, each proven red by its own mutation |
