# Spec: `/kit:wrap`, the landing step after ship

Generated: 2026-09-06
Status: SHIPPED (dwarves-kit #502, merge 9e360ce7)
Lane: full
Type: spec-feature
File: `docs/specs/SPEC-246-kit-wrap.md`
References: the operator's `session-closeout` skill Phase 2 and its skim-first report shape (the operator's dotfiles `session-closeout` skill, the six numbered steps and the `## Closeout` block: port the steps and the report grammar, drop the operator-specific distill phase); `repo-wrapup` scripts `wrapup-scan.sh` (report-only scanner: checkout, ahead/behind, dirty files, worktrees, branch verdicts, open PRs) and `wrapup-apply.sh` (gated executor: branch delete only as an ancestor of the default branch or with a merged PR whose head equals the tip, worktree remove only under a flag and only clean and attached, pull ff-only on the default branch; every skip prints its reason): port both verbatim as `wrap scan` and `wrap apply`, generalising `origin/main` to the detected default branch; `bin/learn` + `lib/learn/learn.sh` (shim and verb entry); `lib/precedent/precedent.sh` (repo-root resolution, `kit_config_get_root` for a consumer key); `commands/retro.md` (the cycle-scoped reflect step this command calls); ops-toolkit `_meta/lablog-add` (the activity-log line format: `YYYY-MM-DD · <slug>: <one sentence>` prepended newest-first, dash refusal, 300-char warn).

## Problem

The kit's lifecycle ends at `/kit:ship` (review gate, tests, changelog, PR). Nothing in the kit lands the session after that: board rows are not flipped to shipped, the operator's own green PRs are not merged, a merged-but-undeployed PR is not noticed, branches and worktrees pile up, the default branch is not pulled, no activity line is written, and `/kit:retro` has no caller (`/kit:start` suggests it; nothing runs it). The operator carries all of that in a personal skill (`session-closeout`, dotfiles) whose Phase 2 is generic git and board mechanics, with a second personal skill (`repo-wrapup`) holding the two scripts. Every adopter without those skills ends sessions by hand, and the operator's copies cannot be retired while the kit has no home for them.

## Solution

### Approaches considered

1. **A new session-scoped command `/kit:wrap` over a `wrap` subsystem** (`bin/wrap` with `scan`, `apply`, `merge`, `log`, `default-branch` verbs, `lib/wrap/`). The command orders the steps per touched repo, calls `board set` and `gh`, and ends by calling `/kit:retro` when a spec cycle merged. Tradeoff: one more command and one more bin entry.
2. **Extend `/kit:retro` with a landing tail.** Tradeoff: retro is cycle-scoped and never writes git state (PHILOSOPHY, detect not dictate); a session touches several repos and needs merges and deletes. Mixing the two bloats a reflection ritual with mechanics.
3. **Extend `/kit:ship` past the PR.** Tradeoff: ship is per feature and stops at the PR by design; merging, deploy checks and worktree tidy are session-wide and need every PR of the session, not the one just opened.

### Chosen approach + why

Approach 1. Session scope is the distinguishing property: one pass over every repo the session touched, after every ship. Retro keeps its scope and gains its missing caller. Ship keeps its fence.

### Extensibility & boundaries

- Load-bearing dimension: the number of touched repos and the number of consumer seams (activity log today; a deploy verifier later). Repos are positional arguments; a seam is one config key read with `kit_config_get_root`, never a project toml (it names a file the kit writes to).
- Units: `lib/wrap/wrap.sh` (verbs, gates, default-branch detection), `commands/wrap.md` (the ordered steps, the merge and deploy rules, the report grammar), `tests/test-wrap.sh` (fixture remotes and clones). The verbs never switch a branch and never touch a dirty file; `merge` is the one verb that talks to GitHub, under its own gates; board flips and commits stay in the command as judgment calls with named rules.
- Out of the closed set: the distill phase (til, learned-ledger, memory routing) stays with the operator overlay; `learning-kit` owns the study side (LK-23).

### Architecture

See `## Design`.

## Picture

```
/kit:ship (per feature, ends at the PR)
      │
      ▼
/kit:wrap  (per session, per touched repo)            bin/wrap ──exec──▶ lib/wrap/wrap.sh
  0 concurrent-writer check (worktree list, reflog)        scan  <repo>...        report only
  1 board rows        board set <ID> shipped|parked|dropped apply [--apply] [--worktrees] <repo>...
  2 commit by name    (command, judgment)                   log   "<slug>: <sentence>"
  3 merge own PRs     wrap merge [--apply] <repo>  (one PR per call)   └─ prepends to wrap.activity_log
  4 deploy check      headSha == merge SHA where deploy is a dispatch   (kit-root kit.toml key)
  5 branches, worktrees, pull  wrap scan -> wrap apply (dry) -> wrap apply --apply
  6 activity line     wrap log
  7 reflect           /kit:retro when a merged PR appears in a ship ledger line
  8 report            skim-first block: Needs you, What happened, Shipped, Left alone, FYI
  (step 0 re-runs before 3, 5 and 6)
```

## Design

### Approaches considered + chosen

See `## Solution`.

### Diagram

```
operator: "/kit:wrap [<repo>...]"
   │  no repos given: the current repo
   ▼
commands/wrap.md
   ├─ for each repo: bin/wrap scan <repo>            (fetch --prune, checkout, ahead/behind vs default, dirty, worktrees, branch verdicts, own open PRs)
   │     STOP on: a dirty file this session did not write, an index.lock, a worktree with recent foreign activity
   ├─ board set … for every row this session's source of truth closed
   ├─ commit by name; bin/wrap merge --apply <repo> once per PR (gates: own, base = default, mergeable, checks green, no unresolved threads, no open dependents)
   ├─ deploy check where the repo deploys by dispatch
   ├─ bin/wrap apply <repo> (dry) -> read every SKIP -> bin/wrap apply --apply [--worktrees] <repo>
   ├─ bin/wrap log "<slug>: <sentence>"      (no key set: prints the line, exits 0, says where it did not land)
   ├─ /kit:retro when a merged PR number appears in a `ship ran "shipping pr=#N"` ledger line
   └─ the report block
```

### ADR link(s)

ADR-0034 (`bin/<subsystem> <verb>`; `wrap` is a subsystem noun with five verbs). ADR-0028 P5 unchanged: retro remains the reflect step; wrap is its caller. No new ADR.

### Boundaries & failure modes

The verb layer is a closed write set of four gated writes: `git branch -d`/`-D` under the two proofs, `git worktree remove` under `--worktrees` on a clean attached secondary worktree, `git pull --ff-only` on the default branch, and the activity-log prepend; plus one `gh pr merge` under the `merge` verb's gates. The command layer adds `board set` and `git commit` as judgment steps with named rules; it never writes through any other path. Every git call runs with `GIT_TERMINAL_PROMPT=0`. `gh` absent or unauthenticated (`gh auth status` fails): every non-ancestor branch is `unknown: LEAVE`, `merge` refuses, the report says so. Default branch: `refs/remotes/origin/HEAD` when it resolves to an existing `refs/remotes/origin/<name>`, else `main` if `origin/main` exists, else `master`, else exit 1 and skip the repo. See `## Failure modes`.

## Technical Design

### Interfaces (I/O contract)

```
wrap scan  <repo> [<repo>...]                          report only, exit 0
wrap apply [--apply] [--worktrees] <repo> [<repo>...]   dry-run by default; --apply executes the gated writes
wrap merge [--apply] <repo>                            merges ONE own green PR whose base is the default branch; dry-run by default
wrap log   "<slug>: <one sentence>" [--date YYYY-MM-DD] prepends to the operator's activity log
wrap default-branch <repo>                             prints the detected name; exit 1 when none resolves
wrap --help                                            exit 0; names all five verbs
```

- `scan`, per repo: `== <repo>`; `-- checkout on: <branch|<detached>>`; `-- vs origin/<default>: ahead=N behind=M`; `-- dirty files` (first 10 or `(clean)`); `-- worktrees` (the `git worktree list` lines); `-- local branches` with one verdict per branch, the detected default plus `main` and `master` always excluded: `SAFE-d: ancestor of origin/<default>`, `SQUASH-MERGED per gh: safe to -D`, `NOT merged / unknown: LEAVE`; `-- open PRs authored by me` from `gh pr list --repo <origin url> --author "@me" --state open --json number,title,headRefName` or `(gh unavailable)` / `(gh unauthenticated)`. A fetch failure prints `(fetch failed; counts may be stale)`.
- `apply`, per repo, prints `[DRY-RUN]`/`[APPLY] <action>` or `SKIP <what>: <reason>`. Gates: the skip list is the detected default branch plus `main` and `master`; the checked-out branch and any branch held by a worktree skip; a branch deletes with `-d` only as an ancestor of `origin/<default>`; else with `-D` only under the squash proof: `gh pr list --repo <origin url> --head <b> --state merged --json headRefOid,baseRefName,mergedAt` where some entry has `mergedAt` non-null, `baseRefName == <default>`, and `headRefOid == <local tip>`; a merged PR whose base is another branch skips with `merged into <base>, not the default branch`; a tip that differs skips with both short SHAs; worktrees skip without `--worktrees`, when dirty, when detached, and when the path canonicalises (`pwd -P`) to the main worktree; pull is `--ff-only` only on the default branch, otherwise `fetch origin <default>:<default>` runs and its refusal is reported. When the fetch failed, every delete is skipped with `fetch failed, stale ancestor data`. Immediately before each write the verb re-checks `index.lock` (older than 5 s, or still present after a 5 s wait, counts as foreign; a lock that clears within the window is ordinary traffic) and that the branch tip equals the tip the same run scanned; a moved tip skips. A write whose git command fails prints `FAILED <action>: exit <n>` and `apply` exits 2 at the end; nothing is retried or forced.
- `merge`: lists the operator's open PRs on `<origin url>` whose `baseRefName` is the default branch; a PR is eligible only when `mergeable == MERGEABLE`, every `statusCheckRollup` entry is `SUCCESS` or `SKIPPED` (none pending, none failing), `reviewDecision != CHANGES_REQUESTED`, no review thread is unresolved, and no other open PR of the operator has this PR's head as its base (a stacked parent skips with `dependents open, retarget them first (SPEC-065)`). Dry-run lists eligible and skipped PRs with reasons; `--apply` merges exactly one (`gh pr merge <n> --squash`, never `--delete-branch`, never `--auto`), then verifies `gh pr view <n> --json state,mergeCommit` reports `MERGED` and prints the merge SHA, exit 2 if not. Run it once per PR.
- `log`: the value of `wrap.activity_log` (kit-root `kit.toml` via `kit_config_get_root`, never a project toml) must be an absolute or `~`-prefixed path whose `realpath` (symlinks resolved) lies under `$HOME`'s realpath and names an existing regular file; anything else exits 1 naming the resolved path. The text must be free of control characters (newline, carriage return, tab) and of em or en dashes, else exit 1 and nothing written. The line `<date> · <text>` is prepended by writing a temp file and `mv` over the target (mode preserved), emitted with `printf '%s\n'`, warned over 300 chars. When the current directory is a git worktree of the repo that holds the configured file, the same repo-relative file inside that worktree is written instead, so the line is committable on the session's branch; the main checkout's copy is left alone. Key unset: prints the line and `wrap log: no wrap.activity_log key in the kit-root kit.toml; line not written`, exit 0. `--date` replaces the date prefix.
- `default-branch`: the detection above, printing the bare name.
- Exit codes per verb: 64 usage everywhere; `scan` 0 (a non-repo argument prints a skip line); `apply` 0, or 2 when any write failed; `merge` 0, 2 when the post-merge check fails, 1 when `gh` is unavailable or unauthenticated; `log` 0 or 1 as above; `default-branch` 0 or 1.

`commands/wrap.md` carries the eight steps with these fixed rules: step 0 defines foreign activity as a worktree reflog entry newer than the session start and an `index.lock` older than 5 s or persisting for 5 s, and the check runs again before steps 3, 5 and 6; step 3 uses `wrap merge` (one PR per call) and, when the session's open PRs form a chain, SPEC-065 order (retarget dependents first, merge parent-first); merged is not deployed, a `workflow_dispatch` repo gets the dispatch and a `headSha == merge SHA` check before `DEPLOYED` is claimed; the session's own EnterWorktree worktree is removed (`ExitWorktree remove`, `discard_changes: true`, then `git branch -D`) once `wrap scan` proves its branch squash-merged and the worktree is clean, and kept only when dirty, unproven, or without `gh`; step 5 targets the main checkout rather than the session cwd, passes `--worktrees` on every `apply` call, and closes with a final `wrap scan` that step 9 derives `Left alone` from; step 7 runs `/kit:retro` when a PR merged in step 3 appears in a `| GATE | ship | ran | shipping pr=#<n>` line of any run ledger under the kit log dir; the report block is the `## Closeout` grammar with `Needs you` first, the fixed uppercase tokens, and the sections `What happened`, `Shipped`, `Left alone`, `FYI` (an overlay may append its own lines after `FYI`).

### Data model changes
`kit.toml` gains `[wrap]` with `activity_log = ""` tagged `[consumer]`, resolved with `kit_config_get_root` (kit-root `kit.toml` ONLY; a project `.kit.toml` is never read for this key because it names a file the kit writes to, `kit-config.sh:64-75`). `lib/config/module-registry.md` gains the row with that sentence.

### API changes
New `bin/wrap`, new `commands/wrap.md`. `commands/start.md` names `/kit:wrap` as the step after ship and before retro. `commands/retro.md` "When to run" gains "called by `/kit:wrap` when a shipped PR merged".

### UI changes
None.

### Infrastructure changes
None.

## Task Breakdown

### Phase 1: Foundation
- [x] TASK-001 (DONE, commit 55b0f4b, verified): `lib/wrap/wrap.sh` (verbs `scan`, `apply`, `merge`, `log`, `default-branch`, `--help`; the two reference scripts ported with every gate above; `GIT_TERMINAL_PROMPT=0` exported) and `bin/wrap` (shim shape of `bin/learn`); `tests/test-wrap.sh` registered in `.github/workflows/test.yml`; `tests/test-bin-forwarders.sh` census. Fixture: three bare remotes with clones whose defaults are `main`, `master`, and `develop` (`origin/HEAD` set), each with branches `merged-ancestor` (merged into the default), `unmerged` (ahead, no PR), `squash-ok` and `squash-stale` (not ancestors), plus a clean secondary worktree on `wt-clean`, a dirty one on `wt-dirty`, and a detached one; a fourth clone with `origin/HEAD` pointing at a pruned name; a fifth repo with no remote. `gh` is a stub script on PATH driven by env vars that answers three invocations exactly: `pr list --repo <url> --head <b> --state merged --json headRefOid,baseRefName,mergedAt` (a JSON list: `squash-ok` returns the local tip with `baseRefName` = default, `squash-stale` returns a different SHA, a `stacked-child` branch returns the tip with `baseRefName` = `feat/parent`, others `[]`), `pr list --repo <url> --author "@me" --state open --json number,title,headRefName` (one fixed PR), and `auth status` (exit 0, or exit 1 when `GH_STUB_UNAUTH=1`). Acceptance (each a grep-able assertion): `scan` prints `-- vs origin/main: ahead=`, `-- vs origin/master: ahead=`, `-- vs origin/develop: ahead=`, `merged-ancestor  [SAFE-d: ancestor of origin/<default>]`, `squash-ok  [SQUASH-MERGED per gh: safe to -D]`, `squash-stale  [NOT merged / unknown: LEAVE]`, `unmerged  [NOT merged / unknown: LEAVE]`, and the open-PR line, for all three fixtures; `apply` dry-run prints `SKIP` lines for `wt-clean` (no `--worktrees`), `wt-dirty`, the detached worktree, the checked-out branch, `squash-stale` with both SHAs, `stacked-child` with `merged into feat/parent`, and pull when off the default; `apply --apply --worktrees` deletes `merged-ancestor` and `squash-ok` only, removes `wt-clean` only, never touches `develop`, `main`, `master`, pulls ff-only on the default branch (assert the clone's HEAD advanced), and exits 0; with a stub `git`-free failure injected (make the default branch non-ff by a remote rewrite) the pull prints `FAILED` and `apply` exits 2; with `PATH` stripped of `gh`, verdicts are `LEAVE` and `merge` exits 1; with `GH_STUB_UNAUTH=1` the same; `merge` dry-run lists the stub PR as eligible, `--apply` calls the stub's `pr merge` once and verifies via `pr view` (the stub records calls to a file; assert one merge call and no `--delete-branch`/`--auto`); `default-branch` prints `main`, `master`, `develop`, falls through to `main` when `origin/HEAD` dangles, exits 1 on the remote-less repo; `log` with `KIT_CONFIG_ROOT` at a temp kit root whose `kit.toml` sets `activity_log` to a temp file under `$HOME` (temp HOME) prepends `<today> · <text>` as line 1, `--date 2026-01-02` overrides the prefix, an em dash exits 1 with nothing written, a newline exits 1, a 320-char text writes and warns, a missing file exits 1, a project `.kit.toml` under `<repo>` setting the key is ignored (line not written, the not-written message printed), an absolute path outside `$HOME` exits 1, a `..` path exits 1; `--help` exits 0 and names `scan`, `apply`, `merge`, `log`, `default-branch`; `apply` without `--apply` changes nothing (`git branch --list` and `git worktree list` byte-equal before and after). The suite, `test-meta.sh`, `test-bin-forwarders.sh` green.

### Phase 2: Core
- [x] TASK-002 (DONE, commit 0a386af, verified by test-meta 832/832 and the grep tokens): `commands/wrap.md` (frontmatter `description`; the Self-intro banner line; `## When this runs`; the eight steps with every fixed rule from the Interfaces paragraph, each rule quoted as its own bullet so a reader can grep `wrap merge`, `SPEC-065`, `headSha`, `ExitWorktree keep`, `--ff-only`, `ship | ran | shipping pr=`, `Needs you`; the report grammar block), `kit.toml [wrap]` + `lib/config/module-registry.md` row, `commands/start.md` and `commands/retro.md` pointers, README (lifecycle sentence, subsystem command list, stage table Govern row), `docs/architecture.md` bin paragraph, `docs/consumer-contract.md` entry (verbs, gates in one line each, the `activity_log` rule), `docs/CHANGELOG.md` [Unreleased], `docs/FEATURES.md` regenerated. Acceptance: `bash lib/registry/feature-registry.sh generate` byte-stable; `test-meta.sh` green; `grep -n "kit:wrap" commands/start.md commands/retro.md README.md` each non-empty; `grep -c` of each quoted rule token above in `commands/wrap.md` is at least 1.

### Phase 3: Polish
- [x] TASK-003 (DONE, lead; docs/verification/kit-wrap.md, battery wave, negative control): proof of done at `docs/verification/kit-wrap.md` (behavioral: a real `wrap scan` and `wrap apply` dry-run on this worktree's repo, `wrap merge` dry-run, `wrap log` against a scratch kit root; negative control by disabling the `baseRefName` check in the squash proof and watching the suite go RED); battery before merge.

## After state
- [ ] `bin/wrap scan <repo>` on this kit prints the checkout, ahead/behind vs `origin/master`, dirty files, worktrees, branch verdicts, and own open PRs. (Today: the same report needs the operator's dotfiles script.)
- [ ] `bin/wrap apply --apply <repo>` deletes only proven-merged branches into the default branch, refuses the default branch by name, reports a failed write with exit 2, and pulls ff-only. (Today: dotfiles script, `origin/main` literal, failures swallowed.)
- [ ] `bin/wrap merge <repo>` lists the operator's mergeable PRs with a reason per skip and merges one under `--apply` without `--delete-branch` or `--auto`. (Today: prose rules in a personal skill.)
- [ ] `bin/wrap log "x: y"` with `[wrap] activity_log` set in the kit-root `kit.toml` prepends a dated line to that file and refuses a path outside `$HOME`. (Today: ops-toolkit's own `_meta/lablog-add`.)
- [ ] `/kit:wrap` exists with the eight steps and calls `/kit:retro` off the ship ledger; `/kit:start` names it. (Today: retro has no caller.)
- [ ] `bash tests/test-wrap.sh` exists and is green.

## Acceptance Criteria (global)
- [ ] All tasks pass their individual acceptance criteria
- [ ] Tests cover happy path + edge cases listed below
- [ ] No regressions: `tests/test-meta.sh`, `tests/test-bin-forwarders.sh`, `bash tests/run-workflow.sh`

## Verification

```
bash tests/test-wrap.sh && bash tests/test-meta.sh && bash tests/test-bin-forwarders.sh
bin/wrap scan . | grep -E '^-- vs origin/(main|master): ahead='
bin/wrap default-branch . | grep -E '^(main|master)$'
bin/wrap merge . | grep -E '^(eligible|SKIP|no open PRs|\(gh )'
```

## Edge Cases
1. Default branch `master` or `develop`: every verdict, the skip list, and the pull use it.
2. `origin/HEAD` dangling after an upstream rename: fall through to `main`, then `master`; none: exit 1, skip line.
3. `gh` absent or unauthenticated: `(gh unavailable)` / `(gh unauthenticated)`, every non-ancestor branch `LEAVE`, `merge` exits 1.
4. Squash proof with a differing tip: SKIP with both short SHAs.
5. Merged PR whose base is another branch: SKIP `merged into <base>, not the default branch`.
6. Dirty or detached secondary worktree: SKIP even with `--worktrees`; the main worktree never enters the removal loop (canonical paths).
7. Checkout off the default branch: pull skipped, `fetch origin <default>:<default>` runs, its refusal is reported.
8. Rewritten upstream: `pull --ff-only` refuses, printed as `FAILED`, exit 2, never forced.
9. Fetch failed: every delete skipped with the stale-data reason.
10. `log` with a dash, a control character, a missing file, a path outside `$HOME`, a `..` path, or a project-toml-only key: exit 1 (or the not-written exit 0 for the unset key), nothing written.
11. A non-repo path among several: skip line, the others proceed.
12. `apply` without `--apply` and `merge` without `--apply`: no write of any kind, asserted byte-equal.
13. A branch tip moved between scan and write: SKIP, never deleted.
14. `merge` on a stacked parent with open dependents: SKIP naming SPEC-065.

## Failure modes
| Failure class | Detection signal | Mitigation / recovery |
|---|---|---|
| Offline or fetch fails | `(fetch failed ...)` line | scan counts marked stale; apply skips every delete; pull not attempted |
| `gh` auth expired | `gh auth status` non-zero | `(gh unauthenticated)`; verdicts `LEAVE`; `merge` exits 1 |
| Rewritten upstream (force-push) | `pull --ff-only` non-ff | `FAILED` line, exit 2, never reset or forced |
| Hook blocks a pull or a merge | git exit non-zero | `FAILED` line, exit 2 |
| Protected branch needing credentials | git would prompt | `GIT_TERMINAL_PROMPT=0` turns the prompt into a `FAILED` line |
| Stale `gh` answer or fork parent | tip or base mismatch, `--repo` pinned to origin | SKIP with both values |
| Concurrent writer in the same checkout | step 0 and the pre-write re-check | STOP, report, leave the repo |

## Out of Scope
- The distill phase (til, learned-ledger, memory notes): operator overlay; LK-23 for the study side.
- Deploy dispatch itself: the command checks, it never dispatches.
- Touched-repo discovery: repos are arguments; the current repo is the default.

## Decision Log
- DEC-001: `wrap.activity_log` is a file path, not a command, resolves from the kit-root `kit.toml` only, must be absolute or `~`-prefixed, and its realpath must sit under `$HOME`. One log serves every repo the operator wraps (the reference use case logs every session into one repo's file), so a repo-relative value was the wrong shape. The kit does the prepend in the `lablog-add` format.
- DEC-002: the two dotfiles scripts are ported with their gates and five corrections from validation: the skip list is the detected default branch plus `main` and `master`; the squash proof pins `--repo` to origin, requires `mergedAt` and `baseRefName == default`, and matches any entry; worktree paths canonicalise before compare; write failures surface as `FAILED` with exit 2; `scan`'s count test becomes a numeric-guard `case`.
- DEC-003: merge is a gated verb (`wrap merge`), not command prose, so "one PR per call, never `--delete-branch`, never `--auto`" is enforced rather than remembered.
- DEC-004: the report grammar moves into the kit with "the operator" for "Han"; the two personal lines (`Distilled`, `Candidates`) are not in the kit grammar; an overlay appends after `FYI`.
- DEC-005: the retro trigger is a ledger fact (a merged PR number in a `ship ran "shipping pr=#N"` line), not a guess about "this session".

## Review

One parallel wave on HEAD fdb63f7 served the review gate and the battery: acceptance-verifier, security (opus), architecture, test-coverage, advisor. Coverage-delta: source and tests moved together. Negative control recorded in `docs/verification/kit-wrap.md`.

### Verdict: FIX THEN SHIP

| # | Finding | Arm | Sev | Route |
|---|---|---|---|---|
| 1 | `log --date` takes its value raw; a newline or an em dash in the date bypasses both content gates and forges extra ledger-shaped lines (proven). | security | HIGH | fixed: `YYYY-MM-DD` gate, exit 1 |
| 2 | Pending or failing `statusCheckRollup` rejection has no red-turning test; deleting the clause leaves 101/101 green (proven by mutation). | test-coverage | HIGH | fixed: PENDING and FAILURE fixtures |
| 3 | `reviewDecision == CHANGES_REQUESTED` rejection: same, no red-turning test. | test-coverage | HIGH | fixed: fixture |
| 4 | The `--repo` pin on `gh` calls is never asserted; the stub ignores it, so stripping it stays green. | test-coverage | HIGH | fixed: argv assertions on the recorded calls |
| 5 | `merge` reads gates from a snapshot and merges whatever the head is at call time; no head-SHA pin (the delete path has one). | security | MEDIUM | fixed: `headRefOid` + `--match-head-commit` |
| 6 | An empty check rollup with `UNSTABLE` passes vacuously. | security | MEDIUM | fixed: empty rollup only with `CLEAN` |
| 7 | Pre-write tip re-check has no test; Edge Case 13 unproven. | test-coverage, acceptance | MEDIUM | fixed: internal `--tips-file` seam + case |
| 8 | Stale `index.lock` rule has no test. | test-coverage | MEDIUM | fixed: both sides |
| 9 | `cmd_merge` fetches each PR's detail twice against its own comment. | architecture | MEDIUM | fixed: one cached JSON per PR |
| 10 | `docs/briefs/CONTEXT.md` leaks home-rooted paths; `test-no-personal-paths.sh` red inside `run-workflow.sh`. | acceptance | regression | fixed by the lead |
| 11 | The spec's Verification `merge` grep exits 1 on a real repo with zero open PRs. | acceptance | spec | fixed: pattern widened |
| 12 | Edge Case 9 (fetch failed) has no test. | acceptance | MEDIUM | fixed: broken-remote fixture |
| 13 | Step 7's PR-number grep is unanchored (`#4` matches `#498`). | security | LOW | fixed |
| 14 | A worktree path with a newline vanishes from the report; empty gate verdict prints an empty reason; `_write_guard` treats an uninterrogable repo as writable. | security | LOW | fixed |
| 15 | `set -uo` without a comment; two magic numbers; kit.toml comment says mtime where the code preserves mode. | architecture, advisor | LOW | fixed |
| 16 | `REVIEW_REQUIRED` with `CLEAN` on an unprotected repo merges; the spec forbids only `CHANGES_REQUESTED`. | security | accepted | recorded here as the spec's choice |
| 17 | ID-644 at `speccing` while built. | advisor | LOW | fixed: `executing` |

### Scores

Security: FIX THEN SHIP (every path-escape variant held; the `--date` door and the merge pin were the gaps). Architecture 8/10 (deep module, real stub seam, lifecycle consistent). Test coverage 6/10 before the batch.

## Open questions
(none)
