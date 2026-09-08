---
description: "The session-scoped landing step after ship: flips board rows, merges the operator's own green PRs one at a time, checks deploys, tidies branches and worktrees, writes the activity line, calls /kit:retro when a shipped PR merged, and prints the skim-first report. Use when the operator says to wrap up or close out the session, land the work, or run the end-of-session routine: 'wrap up', 'wrap this up', 'close out', 'let's wrap', 'session wrap', 'land it', 'pack this up for the day', 'wrap up, update items status, commit, merge PRs and clean up worktrees and stale branches, then pull the latest'."
---

Self-intro (AGENTS.md "Self-intro" convention): open your first reply with exactly one banner line, `[kit:wrap] Land the session after ship: board rows, merges, deploy check, tidy, activity line, retro.`, then proceed.

You are the session's landing step. The operator just shipped, or is ending the session, and nothing in the kit lands that session on its own: board rows stay unflipped, the operator's own green PRs stay unmerged, a merged-but-undeployed PR goes unnoticed, branches and worktrees pile up, and `/kit:retro` never runs. Your job is one pass over every repo the session touched, closing out every step below in order.

## When this runs

- After `/kit:ship` completes, for the repo that just shipped.
- At the end of a session, before the operator closes the terminal.
- Whenever the operator asks to land, wrap up, or close out the session.
- Never mid-build: a spec still mid-execute has nothing to land yet.

## Prerequisites

- Each named repo (or the current repo, when none is named) is a git repository. A non-repo argument prints a skip line and the rest proceed.
- `gh` is optional. When it is absent or unauthenticated, every branch that is not a plain ancestor of the default branch verdicts `unknown: LEAVE` and `bin/wrap merge` refuses with exit 1; the command still runs the other seven steps and reports the degraded state, it never stops for this reason alone.

## Process

Bracket the phase for timing (SPEC-129) before starting: `bash lib/gate/gate-ledger.sh outcome <rid> wrap start`.

Run the steps below once per repo the session touched (the current repo when the operator names none). Positional repo arguments; wrap never discovers touched repos on its own (Out of Scope).

### Step -1: the before seam

An operator can put one skill in front of this command. Read the key first:

```bash
. lib/config/kit-config.sh && kit_config_get_root wrap.before ""
```

An empty value means no skill runs, which is the default; go straight to step 0. A named skill runs NOW, before step 0, and its report lines fold into step 9's report after the `FYI` line. The key resolves with `kit_config_get_root`, so it comes from the operator `kit.toml` or the kit-root `kit.toml` and never from a project `.kit.toml`: it names code this command runs, and a project toml rides inside an untrusted PR.

Read the three autonomy knobs in the same call, once, and carry the values through the pass:

```bash
. lib/config/kit-config.sh
kit_config_get_root wrap.merge_own_prs true
kit_config_get_root wrap.tidy_worktrees true
kit_config_get_root wrap.build_candidates true
```

Each governs exactly one step: `merge_own_prs` step 3, `tidy_worktrees` step 5, `build_candidates` step 7b. The shipped defaults are all `true`, so wrap acts. Every one of the three authorizes a write, which is why all three resolve with `kit_config_get_root` and never from a project `.kit.toml`. A `false` turns that step's action into a report line; it never turns the step off, and it never relaxes a refusal the tools make on their own. Name every knob read as `false` in the report's `FYI`, so a step that stayed its hand says why.

### Step 0: concurrent-writer check

Foreign activity in a repo's checkout means either signal is present: a worktree reflog entry newer than the session start, or an `index.lock` file that is older than 5 seconds or persists for 5 seconds (a lock that clears within the window is ordinary git traffic). Run `bin/wrap scan <repo>` for the checkout, ahead/behind count, dirty files, worktrees, branch verdicts, and the operator's own open PRs.

- `bin/wrap scan <repo>` is report only; it never writes.
- On foreign activity: STOP, report what was found, and leave that repo alone for the rest of the pass. Do not touch a dirty file this session did not write.
- The check runs again, repo by repo, immediately before steps 3, 5, and 6 (the three steps that write). A repo that goes foreign between checks drops out of the remaining steps for that repo only.

### Step 1: board rows

For every backlog row whose source of truth this session closed, flip it through THAT repo's board wrapper, `<repo>/_meta/board set <ID> shipped|parked|dropped "<PR or SHA>"` (or `<repo>/board set` where the wrapper lives at the root); with no wrapper, `bin/board set <ID> <state> --backlog-file <repo>/_meta/BACKLOG.md`. A bare `bin/board set` without `--backlog-file` targets the kit's own board, never the wrapped repo's. A row this session merely touched, without closing its source of truth, stays where it is.

### Step 2: commit by name

Commit any of the operator's own outstanding work under its own name and message. This step is a command-layer judgment call, not a verb: `wrap` owns no commit write. Skip it when nothing of the operator's own is outstanding.

### Step 3: merge the operator's own PRs

`wrap.merge_own_prs` false: merge nothing, report every own open PR as `OPEN` under `Shipped`, and say in `FYI` that the knob is off. Steps 4 onward still run.

Otherwise re-run the step 0 check first. Then, once per PR: `bin/wrap merge --apply <repo>`. It merges exactly one own, green PR whose base is the default branch and reports every skip reason for the rest.

- `wrap merge` never runs twice for the same PR in one call; call it again for the next PR.
- When the session's open PRs form a chain, follow SPEC-065 order: retarget every dependent onto its grandparent's target first, then merge parent-first, oldest ancestor first.
- Never merge a PR the operator did not open.

### Step 4: deploy check

A merged PR is not a deployed one. For a repo whose deploy is a `workflow_dispatch`, dispatch it and confirm `headSha == merge SHA` before the report claims `DEPLOYED`. A repo with no dispatch-shaped deploy has nothing to check here; say so plainly rather than guessing at a deploy that does not exist.

- The command checks a deploy; it never dispatches one on its own initiative (Out of Scope). Dispatching happens only when the operator asked for this repo's deploy as part of landing the session.

### Step 5: branches, worktrees, pull

Re-run the step 0 check first. Then, in this order: remove the session's own worktree (the bullet below), `bin/wrap scan <repo>` again to see the current branch verdicts, `bin/wrap apply --worktrees <repo>` as a dry run, read every `SKIP` line, then `bin/wrap apply --apply --worktrees <repo>` to execute. Close the step by re-running `bin/wrap scan <repo>`: that final scan, not memory, is what step 9's `Left alone` reports.

- `<repo>` is the MAIN checkout path, never the session's cwd. Resolve it once: `main=$(git -C <cwd> rev-parse --path-format=absolute --git-common-dir)` then strip the trailing `/.git`. Off the main checkout `apply` sees the feature branch as current and never pulls, which is how a repo stays behind while the report claims it landed.
- Pass `--worktrees` on every call, dry run and apply alike, unless `wrap.tidy_worktrees` is false. It is the flag the operator asks for by saying "clean up worktrees", and `apply` refuses a dirty, detached, or checked-out worktree on its own, so the flag is not the safety. Omitting it also strands every branch a worktree holds: `apply` skips those with `held by a worktree` and the branch survives with it. With the knob false, drop the flag, leave every worktree, list them under `Left alone`, and name the knob in `FYI`; the session's own worktree bullet below is unaffected, because that removal is proven per worktree rather than swept.
- `bin/wrap apply` without `--apply` changes nothing; always read its dry-run SKIP lines before adding `--apply`.
- Pull on the default branch is `--ff-only`; off the default branch, `apply` fetches the default branch into itself instead and reports a refusal as `FAILED`, never forced. That fetch refuses outright when the default branch is checked out in another worktree, which is the second way a repo stays behind; the main-checkout rule above is what avoids both.
- The session's own `EnterWorktree` worktree goes FIRST, before `wrap apply` runs, so the harness records the removal instead of finding the directory gone. Once `wrap scan` proves its branch squash-merged (tip matches the PR head) and the worktree is clean, remove it: `ExitWorktree remove` with `discard_changes: true` (the squashed commits are not ancestors of the default branch, so the tool asks; the proof is the confirmation), then `git branch -D <branch>`. The operator gave that confirmation once, as a standing rule, and a worktree whose PR merged this session is finished work, never something to keep. `ExitWorktree keep` only when the worktree is dirty, the branch is not proven merged, or the proof is unavailable (no `gh`); say which in `Left alone`. A plain secondary worktree still routes through `wrap apply --worktrees` and skips when dirty, detached, or held by the checked-out branch.
- Never remove a dirty or foreign worktree, under `--worktrees` or otherwise.
- Never force-push and never rewrite history to make a delete or a pull succeed.

### Step 6: activity line

Re-run the step 0 check first. Then: `bin/wrap log "<slug>: <one sentence>"`. When the current directory is a git worktree of the repo that holds the configured file, the same repo-relative file inside that worktree is written instead, so the line is committable on the session's branch; the main checkout's copy is left alone. With no `wrap.activity_log` key in the kit-root `kit.toml`, it prints the line and says where it did not land; that is a clean result, not a failure.

### Step 7: learn

The process half of distill (SPEC-249): a DEBT marker for the run, new-tool candidates checked against precedent, and one memory note per incident this session caused. Three lettered sub-steps, each prints one line when idle.

Sub-step `b` BUILDS what it can rather than proposing it. Everything it writes is a committed change in a git repo, so a wrong call costs one revert, and a staged row that waits for a yes costs a round trip on work the operator already asked for. A row is staged only when the candidate fails the `Needs you` admission test, meaning its scope is a judgment whose options carry different irreversible outcomes. Sub-step `c` writes one memory note and never a board row.

a. DEBT marker.

```bash
rid=$(bash lib/gate/gate-ledger.sh rid)
```

An empty `rid` prints `skipped: no run id`. Otherwise resolve the log dir with `logdir=$(bash -c 'source lib/telemetry/kit-log-dir.sh; kit_resolve_log_dir')` (the file is source-only and prints nothing when run as a command); a missing `runs/<rid>.log` prints `skipped: no run log`; a `| DEBT |` line already in it prints `skipped: DEBT marker present`. Otherwise `bash lib/classify/significance-classify.sh record <rid> "<one-line session description>"`; a non-zero exit prints `skipped: classifier failed (rc N)` and the step continues to b.

b. Candidates. A candidate is anything this session BUILT or proposed to build that could outlive the session: a new script or tool, an enhancement the operator asked for and the session deferred, a manual multi-step procedure run three or more times, or a one-off script the operator called recurring. The check runs on the first one, not the third, because a single-purpose script written next to an existing tool is the fragment this step exists to prevent. `wrap.build_candidates` false: run the precedent check anyway, then stage every candidate with the `bin/wrap stage` line below and quote the top hit in the FYI bullet where one came back. Building is what the knob governs; checking precedent is not optional at either setting, because a staged row that does not name the tool it should have joined recreates the fragment one release later.

Otherwise, for each candidate run `bin/precedent find --surface inventory --json "<two or three words>"`, then route on the answer:

- **`nothing_matched` false, a hit came back.** The candidate is an enhancement to something that already exists, which is the whole reason this check runs. WIRE IT INTO THE HIT NOW: edit that tool or script in its own repo, commit under its own name, and report the change as an FYI bullet naming the file and the commit. Do not stage a row and do not merely quote the hit line. A single-purpose script written beside an existing tool is the fragment this step exists to prevent, and quoting the tool it should have joined prevents nothing.
- **`nothing_matched` true, and the shape is obvious.** One home, one clear entry point, no design fork. BUILD IT in that home repo, commit, and report it as an FYI bullet naming the path and the commit.
- **`nothing_matched` true, and the scope is a judgment.** Competing homes, an unclear boundary, or a build large enough that the wrong shape costs more than a revert. Stage it: `bin/wrap stage "<title>" "<intent>" "<home>" --repo <the checkout of that home repo>` with `<home>` the repo that would own it. The row lands in the home repo's `_meta/backlog-staging.md`, so `--repo` is what puts it there: without it the row lands in the current repo and `<home>` is only a text field (`already staged` from the verb needs no bullet). Say in the FYI bullet which fork made it a judgment.

No candidates: `skipped: no candidates`. Nothing here reaches a public repo or an outward-facing surface; a candidate that would (a publish, a send, a charge) is never built here, it goes to `Needs you` under the admission test.

c. Incidents. For every `docs/incidents/*.md` written this session whose `## Root cause` names our own mistake, `bin/wrap knowledge-root <repo>` gives the directory. A note already there naming the incident id in its first heading: `skipped: note exists`. Otherwise write one note, how to work here and what to do differently, plus its `MEMORY.md` index line, in that directory. An empty `## Root cause` writes nothing. A `knowledge-root:` fallback line on stderr becomes an FYI bullet, not a skip. No incidents: `skipped: no incidents`.

### Step 8: reflect

Resolve the kit log dir (`bash -c 'source lib/telemetry/kit-log-dir.sh; kit_resolve_log_dir'` prints it) and grep the run ledgers under it for a `| GATE | ship | ran | shipping pr=#<n>` line naming any PR number merged in step 3. Anchor the number so `#7` never matches `#71`: `grep -rE "shipping pr=#<n>([^0-9]|$)" "<log dir>"`. Any hit means run `/kit:retro` now, before the report. No hit means no spec cycle shipped this session; skip retro and say so in the report's FYI line.

### Step 9: report

Print the skim-first block below. It is the single reply for this command; there is no separate per-step report.

```
## Wrap: <session slug, 3 to 6 words>

✅ **Needs you:** NOTHING
   -- or --
🔴 **Needs you:**
a. DECIDE | RUN | REVIEW | UNBLOCK <what>. <why it sits with the operator>. <the one command or the decision>.
b. ...

**What happened**
- **<workstream>**: <the problem as the operator saw it>. <root cause in one clause>. <what changed>. <how it was proven>.

**Shipped**
- **<repo>**: #<pr> (<sha>) DEPLOYED <run or fleet line> | #<pr> 🟡 MERGED, NOT DEPLOYED | #<pr> OPEN

**Left alone:**
- <repo>: <files / worktrees / branches>, <whose>, PULL BLOCKED
   -- or --
- NOTHING

**FYI:**
- <what changes for the operator from now on>
- <a state the operator will meet next time>
   -- or --
- NOTHING
```

- `Needs you` leads and is always present, even as `NOTHING`. It is a lettered action list; it sits at the top, ahead of every other section, because this report is read from the top and the items are the whole point.
- **Admission test, run it on every drafted item before the report prints.** An item earns a place in `Needs you` only when the operator is the ONLY one who can do it. Three classes qualify: it needs a human credential or presence (a root password, a GUI, 2FA, a physical device); it is irreversible and outward-facing (send the email, charge the card, terminate the host, delete in production); or it is a judgment whose options carry different irreversible outcomes. Everything else fails the test. For each failing item, RUN IT NOW, then move it to `What happened` in the past tense. Merging your own green PR, pulling the default branch, installing what you just merged, dispatching an established deploy, and rerunning a check all fail the test: they are work, and the report is written after the work, not instead of it.
- The failure mode this test exists to stop: a finished build parked behind "say go and I will merge it". That reads as diligence and costs the operator a round trip to type "ok". Landing the change is part of finishing it. When something genuinely blocks, `Needs you` names the blocker, never the permission.
- **Run the lint before printing.** Write the drafted report to a scratch file and check it: `bash lib/wrap/report-lint.sh <file>`. Exit 1 names a `Needs you` item that asks permission instead of stating a blocker; go do that item, move it to `What happened`, and re-run until the lint is clean. A `warn` line names an item built around a command the kit can run with no blocker stated: read it again, and either state the blocker or do the work. The lint judges phrasing, not reversibility, so it catches the one shape that is always wrong and leaves the judgment calls to the admission test above.
- Exactly two emoji, no others: `✅` or `🔴` leads `Needs you` (green only when it says `NOTHING`), and `🟡` marks a `MERGED, NOT DEPLOYED` PR, the one `Shipped` state that still needs a hand. Nothing on section headers, lettered items, or in prose.
- Status words stay UPPERCASE tokens, always the same ones: `NOTHING`, `DEPLOYED`, `MERGED, NOT DEPLOYED`, `OPEN`, `PULL BLOCKED`, and a leading verb on each `Needs you` item from `DECIDE`, `RUN`, `REVIEW`, `UNBLOCK`. Prose stays lowercase.
- `What happened` is one bullet per workstream, two to four sentences: the problem as the operator saw it, the root cause, what changed, how it was proven. A ten-minute session earns one bullet; a long one earns five or six.
- `Shipped` is one line per repo: PR number, merge SHA, deploy state.
- `Left alone` and `FYI` are bullet lists, one item per repo or fact, never joined with `|` or `;`.
- `Left alone` is derived from step 5's closing `bin/wrap scan`, never written from memory of what the steps intended. Every worktree, branch, and dirty file that scan still reports gets a bullet with its owner and the reason, one bullet per repo, so the operator knows a repo is not fully clean and why. A single `- NOTHING` bullet only when that final scan came back clean.
- `FYI` closes the message: one bullet per fact that changes what the operator will MEET next time but asks nothing of them now. It is the read-and-move-on lane, the counterweight to `Needs you`: a state that shifted under them (a default that changed, a file that moved, a queue that grew, a job that will fire), never a task. An item that needs a decision, a command, or a review was misfiled and belongs in `Needs you` instead. A single `- NOTHING` bullet when there is nothing to report.
- A staged candidate, a filed memory note, or a knowledge-root fallback from step 7 is an `FYI` bullet naming the file or the reason, in the existing `FYI` grammar.
- An overlay (a consumer's own routing, distill, or knowledge-capture step) appends its own labelled sections after `FYI`, in the same shape: a bold label line followed by bullets, one item per note, candidate, or queue entry; the kit's grammar stops there. A `wrap.before` skill's report lines fold in at that same place.
- No table unless the session touched four or more repos. No restating what each step did.

Record the run (SPEC-139), one line: `bash lib/gate/gate-ledger.sh record <rid> wrap ran "<summary>"`. Close the timing bracket (SPEC-129): `bash lib/gate/gate-ledger.sh outcome <rid> wrap end caught=<true if a repo hit step 0's foreign-activity STOP, else false>`.

## What this command does NOT do

- Never force-pushes.
- Never rewrites history.
- Never merges a PR it did not open.
- Never touches a dirty file.
- Never removes a dirty or foreign worktree.
- Never dispatches a deploy on its own initiative; it checks one the operator already dispatched or asked it to dispatch as part of this pass.
