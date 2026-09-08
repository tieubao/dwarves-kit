# Implementation notes: SPEC-246 /kit:wrap

Delta from the spec only.

## 2026-09-06 Before build

- The spec went through design-critique (architecture lens) and two spec-validate lenses (testability, security) before build; every REVISE item is folded into the Technical Design and the Decision Log rather than kept as a list, so the build reads one contract.
- Lane is `full` by classification (new command plus new subsystem); the review step is review-team with the bounded fix loop, then the battery.

## 2026-09-06 TASK-001 The unresolved-thread gate reads mergeStateStatus

Context: the Interfaces paragraph requires the merge verb to refuse a PR when a review
thread is unresolved. `gh pr view --json` exposes no `reviewThreads` field. Asking for it
makes gh reject the whole call, so the gate as literally worded has no gh CLI expression.

Decision: request `mergeStateStatus` on the same `pr view` call and refuse anything but
`CLEAN`, `HAS_HOOKS` or `UNSTABLE`.

Why: GitHub reports `BLOCKED` for a pull request whose merge is held by an unresolved
conversation or an unmet review requirement. One field on a call the verb already makes,
and it fails closed: an unknown state refuses rather than merges.

Alternatives: a `gh api graphql` reviewThreads query (a fourth gh invocation, needs an
owner and repo pair that a local-path origin does not carry, and it fails on any host
where graphql is blocked); dropping the gate (refused, the spec names it).

Impact: the verb also refuses a PR blocked for a reason other than a thread, for example a
missing required review. That direction is the safe one. A later task may add the graphql
query behind the same verdict string.

Open questions: none.

## 2026-09-06 TASK-001 A refused off-default fetch is a FAILED write, exit 2

Context: when the checkout sits off the default branch, `apply` skips the pull and runs
`fetch origin <default>:<default>` instead. The reference script printed a soft note when
that fetch refused. The spec says a write whose git command fails prints `FAILED` and
`apply` exits 2, and separately that the fetch refusal is reported.

Decision: the fetch is a write, so it takes the blanket rule: `FAILED` plus exit 2.

Why: one rule for every write beats two. A refused fetch means the local default branch
diverged from origin, which the operator must see, and a zero exit hides it from a caller.

Alternatives: keep the reference's soft note (a diverged local default branch then exits 0).

Impact: an `apply --apply` run in a repo whose local default branch diverged exits 2 even
though nothing else failed. The line names the fetch.

Open questions: none.

## 2026-09-06 TASK-001 The gh stub answers five invocations, not three

Context: the task description names three stub invocations. The merge verb needs
`mergeable`, `statusCheckRollup`, `reviewDecision`, `mergeStateStatus` and `baseRefName`
per PR, plus the post-merge state check.

Decision: the stub also answers `pr view <n> --json <detail fields>` and `pr view <n>
--json state,mergeCommit`, and `pr merge`. The per-branch merged-PR fixtures stay in env
vars keyed by the sanitized branch name, as described.

Why: `gh pr list --author "@me" --state open` cannot carry the gate fields, and inventing a
wider list call would diverge from the invocation the scan verb already uses.

Alternatives: one fat `pr list` with every field (a shape the scan verb would not share).

Impact: the test asserts the exact recorded argv for every call, so a change to the
invocation set is visible.

Open questions: none.

## 2026-09-06 TASK-001 Smaller calls the spec left open

Context: several details had no wording in the spec.

Decision and why, one line each:

- The activity-log prepend copies the target's mode onto the temp file before the `mv`, so
  the spec's "mode preserved" and its "mv over the target" both hold.
- `apply` prints an explicit `SKIP <branch>: default or protected branch name` line for the
  detected default plus `main` and `master`; the reference skipped them silently, and a
  silent skip reads like an oversight in a report a human scans.
- Argument collection uses an indexed array with a counter, never `arr+=()` with
  `${#arr[@]}`: an empty array reads as unbound under `set -u` in the bash 3.2 that macOS
  ships, and CI runs the macOS leg.
- `scan` prints `(gh query failed)` when gh is authenticated but the PR list call fails,
  which keeps the section honest instead of empty.

Impact: none beyond the report text and portability.

Open questions: none.

## 2026-09-07 TASK-002 Report block heading is `## Wrap:`, not `## Closeout:`

Context: the spec's Interfaces paragraph says the report block is "the `## Closeout` grammar",
naming the operator's ported skill as the shape reference (DEC-004). It does not say the kit's
own heading text must stay `## Closeout`.

Decision: the kit's block opens `## Wrap: <session slug>`.

Why: `/kit:wrap` is the command emitting the block; a heading naming the operator's personal
skill would read as unexplained inside a kit doc a stranger repo reads with no dotfiles
context. Every other rule (Needs you first, the two emoji, the uppercase tokens, What
happened / Shipped / Left alone / FYI, the overlay-appends-after-FYI seam) is ported verbatim.

Alternatives: keep `## Closeout:` literally (rejected, ties a generic kit report to a personal
skill's name).

Impact: none beyond the heading string; an overlay matching on the ported grammar should match
on the section names below the heading, not the heading itself.

Open questions: none.

## 2026-09-07 TASK-002 `wrap` gets no Module stages table row

Context: `lib/config/module-registry.md`'s `## Module stages` table is scoped to
`KIT_KNOWN_MODULES` (`install.sh`), the completeness rule stated at the top of that section.
`wrap` has no install hook and is not in that list, the same position `precedent` is already in
(no Module stages row, no README Install-table row; only its own env<->key subsection).

Decision: add `wrap`'s env<->key row and its README stage-table (Check/Govern) mention, but no
`## Module stages` row and no Install-layer table row.

Why: matches the existing precedent case exactly; adding a row would put `wrap` in a table
whose completeness check does not expect it, a drift the next `KIT_KNOWN_MODULES` sweep would
have to explain away.

Alternatives: add a row anyway for visibility (rejected, breaks the stated scope of that table).

Impact: none; `wrap` is documented as a subsystem in the five-stages prose table, not as an
installable module.

Open questions: none.

## 2026-09-07 Review fix batch

Context: a multi-lens review of the branch returned a fix batch. This entry records the deltas from the spec, one per finding.

Decision, `--date` validation: `wrap log` now refuses any `--date` that is not a literal
`YYYY-MM-DD`, before any write. Why: the value prefixes a line in a file the kit writes, so a
multi-line value forged an extra log line. The check is a `case` glob, so `2026-13-45` fails on
its day field. Impact: an operator who passes a malformed date gets exit 1 and an untouched file.

Decision, merge head pin: `_pr_detail` now reads `headRefOid` and `gh pr merge` carries
`--match-head-commit`. Why: a push landing between the gate and the merge would otherwise ship
an unreviewed head. Fail-closed: an absent head SHA aborts the merge with exit 2 rather than
merging unpinned.

Decision, checks gate: an empty or null `statusCheckRollup` now passes only when GitHub reports
`mergeStateStatus == CLEAN`. Why: an empty rollup proves nothing on its own, and a repo whose
checks have not registered yet reported the same shape as a repo with no checks.

Judgment call, the `--tips-file` seam: `apply` gained an internal `--tips-file <path>` option,
documented in `--help` as a test seam. Why: the mid-run tip re-check had no test, because a real
concurrent push cannot be staged deterministically inside the suite. The option replaces the
run's own snapshot, which is the smallest surface that makes the re-check observable.
Alternatives: a hidden env var (rejected, a flag is visible in `--help`); a sleep-and-push race
(rejected, flaky). Impact: one more parsed flag on `apply`; it refuses a path that does not exist.

Decision, `_write_guard` fails closed: an unresolvable git dir now returns 1 (refuse) instead of
0 (allow). Why: the old code treated "cannot tell" as "safe to write".

Decision, worktree paths: `_apply_worktrees` reads `git worktree list --porcelain -z`, so a path
carrying a newline stays whole. A path that cannot be entered now prints `SKIP <path>:
unresolvable` instead of being dropped silently.

Decision, one detail read per PR: `cmd_merge` writes each PR's full JSON to a temp file and the
eligibility loop reads it back. The second `_pr_detail` call is gone. Why: the dependents gate
needs every base before the first verdict, which forced the two-pass shape, not two fetches.

Decision, unreadable PR JSON: an empty `_pr_gate` verdict prints `SKIP #n: unreadable PR JSON`
rather than falling through the gate.

Decision, named constants: `LOCK_STALE_SECS` and `LOG_LINE_BUDGET` replace the two literals, and
one comment above `set -uo pipefail` records why `-e` is absent (the `run()` rc-capture pattern).

Decision, `commands/wrap.md` step 7: the retro grep anchors the PR number, so `#7` cannot match
`#71`.

Open questions: none.

## 2026-09-07 CI: the lock guard probed git status (lead)

- Context: the ubuntu CI leg failed the fresh-lock case. The guard treated a young `index.lock` as ordinary traffic only when `git status --porcelain` passed; on that git build the probe contends for the same lock and fails, so a young lock was refused. macOS git did not contend, which is why every local run passed.
- Change: `_write_guard` polls the lock file itself for up to `LOCK_STALE_SECS`; a lock that clears in the window is traffic, one that persists is a writer. The fresh-lock test now releases the lock from the background after 2 s (write proceeds) and then leaves one in place (refused). Spec Interfaces and `commands/wrap.md` step 0 say the same rule.

## 2026-09-07 CI: GNU stat -f is file-system mode (lead)

- Context: the fresh-lock case still failed on ubuntu after the poll fix. `_mtime` tried `stat -f %m` first; on GNU stat `-f` reports the file system and prints the mount point with exit 0, so the fallback to `-c %Y` never ran and the age parsed as garbage.
- Change: both helpers try GNU `-c` first; BSD stat rejects `-c` and falls through to `-f`. Local macOS run stays 131/131 through the fallback.

## 2026-09-07 wrap log and worktrees (lead)

- Context: the operator file names one fixed LAB_LOG path inside the ops-toolkit main checkout. Sessions work in worktrees of that repo and the main checkout cannot switch branches, so a line written there was uncommittable. Found on the first live use.
- Change: `_worktree_copy` rewrites the target to the same repo-relative file inside the current worktree when both share a git common dir. Three test cases: the worktree copy gets the line, the main copy stays, running from outside the repo writes the configured file itself.

## 2026-09-08 the autonomy batch and its deliberate skips (lead)

- Context: four PRs (#523 to #526) hardened wrap's write steps after a live session where wrap reported a landed session while nine worktrees survived and a green own PR sat unmerged behind a permission request.
- Decision, no ADR for the admission test: `Needs you` gained an admission test in #524 and #525/#526 both cite it, which is normally the ADR threshold. It stays a SPEC-246 clause plus SPEC-249 DEC-013 instead, because the kit's own rule is to write a record only where it hits a gate. Nothing gates on this rule outside `commands/wrap.md`, so an ADR would be ceremony with no reader. Revisit if a second command adopts the test.
- Decision, three booleans over one posture key: `merge_own_prs`, `tidy_worktrees` and `build_candidates` gate three different risk classes (a write to a shared default branch, a local delete, a commit of new code). One aggregate `wrap.autonomy` would bundle the shared-repo action with the local one and then need precedence rules against per-axis overrides, which is the complexity the three plain booleans avoid.
- Decision, root-only resolution for all three: each knob authorizes a write and a project `.kit.toml` rides inside an untrusted pull request, so `kit_config_get_root` is the only correct reader. A contributor must not be able to widen what wrap does to the machine running it. Asserted per knob in `tests/test-wrap.sh`, not left as prose.
- Tradeoff, unprovable claims: #523's derived `Left alone`, #524's admission test and #525's build routing are instructions in a prompt file. `docs/verification/kit-wrap.md` records them as NOT proven rather than citing token-presence as evidence. The fixture that would close the gap (a repo carrying a green own PR, a stale worktree, and a candidate with a precedent hit, asserted against resulting git state) is named there and not built.
- Open question for the operator: the same stall pattern sits in `commands/ship.md` (commit confirmation, version-bump approval, changelog offer) and `commands/debug.md` (a second human confirm after the loop's own verification already passed). Those were surveyed, not flipped, because ship and debug carry their own gate semantics and the change deserves its own branch.
