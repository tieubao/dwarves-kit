---
description: "Ship: review gate, tests, version bump, changelog, conventional commit, docs update, PR. Complete pipeline from done to merged."
---

You are a release engineer. The user says the feature is done. Your job is to verify, package, and ship it cleanly.

## Process

### Step 1: Review gate

Check if a review has been done:
- Resolve the active spec (`docs/specs/SPEC-NNN-<slug>.md`, the SPEC-005 rule) and read its `## Review` section verdict.
- If verdict is `SHIP` or `FIX THEN SHIP` (with fixes applied): proceed.
- If verdict is `DO NOT SHIP`: STOP. Tell the user to fix the issues first.
- If the spec has no `## Review` section: WARN. Ask: "(A) Run /kit:review first / (B) Run /kit:review-team for thorough review / (C) Skip review and ship anyway"

Do not silently skip the review check. The user must explicitly choose to ship without review.

### Step 1b: Completeness log (warn, not block)

Read `~/.claude/dwarves-kit/logs/completeness.log` (the warn+log sink from the WORKFLOW completeness clauses). Surface any entries since the last ship/tag: lost build-decisions (decision-translation) and un-updated companion docs (doc-update, per the WORKFLOW doc-impact map). REPORT them so the maintainer decides; do NOT auto-block on completeness. Hard blocks stay reserved for the spec's `## Review` DO-NOT-SHIP verdict and the safety gates. If the log is absent or empty, say "completeness: clean". Source: SPEC-006.

### Step 1c: End-user guide check (warn, not block)

Apply the test: does this change have an end user who is not the builder? A
library, an internal tool, or infra with no such user is exempt.

If yes: confirm `GUIDE.md` exists at the product root and still matches what
shipped (what it does, how to use it, what to do when it breaks). Template:
`docs/GUIDE.template.md`.

If `GUIDE.md` is missing or stale, REPORT it to the maintainer; do NOT block
the ship. Same voice as Step 1b / Step 4a: hard blocks stay reserved for the
spec's `## Review` DO-NOT-SHIP verdict and the safety gates. Source: SPEC-216.

### Step 2: Run tests

Detect the test runner and execute:
- Node.js: `npm test` or `pnpm test` or `yarn test`
- Go: `go test ./...`
- Python: `pytest` or `python -m pytest`
- Rust: `cargo test`

If tests fail: STOP. Show the failures. Ask if the user wants to fix them first.
If no test runner found: WARN but continue.

### Step 3: Check for uncommitted changes

Run `git status`. If there are unstaged files, show them and ask:
- Which files should be committed?
- Are any of these accidental (build artifacts, .env, node_modules)?

### Step 4: Version bump (if applicable)

Check if the project has a version file:
- `package.json` (Node.js): read current version
- `version.go` or `VERSION` file (Go): read current version
- `Cargo.toml` (Rust): read current version
- `pyproject.toml` (Python): read current version

If a version file exists:
- Determine bump type from the changes:
  - Breaking changes or major refactors: major bump
  - New features: minor bump
  - Bug fixes, docs, refactors: patch bump
- Read `kit_config_get_root ship.confirm_bump "major"`. Its value names which bumps still need a yes: `"major"` (the default, the breaking bump alone), `"always"`, or `"never"`.
- A bump that needs a yes: present it, "Current: 1.2.3, Proposed: 2.0.0 (major: breaking change). Approve?", and wait. A major bump is a semver promise to every consumer, which is why it is the one that holds by default.
- Every other bump: apply it to the version file and report what changed, "1.2.3 to 1.3.0 (minor: new feature)". Nothing is pushed at this step, so a wrong bump is a follow-up commit before the tag exists.

If no version file exists: skip this step silently.

### Step 4a: Release-hygiene warn (warn, not block)

At the version/tag decision, check for a **phantom cut**: `VERSION` names a version that has no matching git tag. Run the check, then REPORT to the maintainer; do NOT block the ship. Mirror the Step 1b "warn, not block" voice: hard blocks stay reserved for the spec's `## Review` DO-NOT-SHIP verdict and the safety gates.

Use this exact check shape (kit-health's check uses the same shape; they must not drift):

```bash
# Graceful degrade: no VERSION or not in a git repo => silent no-op, never error or block.
if [ -f VERSION ] && git rev-parse --git-dir >/dev/null 2>&1; then
  VER=$(tr -d '[:space:]' < VERSION)   # strip whitespace so a trailing newline cannot break the pattern
  # CHANGELOG resolution (SPEC-185): docs/CHANGELOG.md wins if present (the thin-root-stub
  # convention this kit's own repo uses); else the plain root CHANGELOG.md most repos use.
  CL=CHANGELOG.md; [ -f docs/CHANGELOG.md ] && CL=docs/CHANGELOG.md
  if [ -n "$VER" ] && [ -z "$(git tag -l "v$VER")" ]; then
    echo "WARN release-hygiene: phantom cut. VERSION names v$VER but no matching git tag exists."
    # Accumulation context: [Unreleased] non-empty => work piling above an untagged cut.
    if [ -f "$CL" ] && awk '/## \[Unreleased\]/{f=1;next} /^## /{f=0} f && NF{print}' "$CL" | grep -q .; then
      echo "         work is accumulating above an untagged cut v$VER."
    fi
  fi
fi
```

If the phantom cut fires, surface it as a heads-up at the version step (remember to tag `v$VER`), then continue. During a real release this fires between the version-bump commit and the tag, where the warn is the correct "remember to tag" nudge. Source: SPEC-028 (DEC-001 warn-only, DEC-005 shared shape).

### Step 5: Generate changelog entry

The target file is `docs/CHANGELOG.md` if it exists (SPEC-185 thin-root-stub convention),
else the plain root `CHANGELOG.md`.

If a changelog file exists (or the project follows a changelog convention):
- Generate an entry from the commits since last release/tag:
  ```
  ## [version] - YYYY-MM-DD

  ### Added
  - [feature descriptions from feat() commits]

  ### Fixed
  - [fix descriptions from fix() commits]

  ### Changed
  - [refactor/chore descriptions]
  ```
- Prepend to the resolved changelog file (newest first).
- If no changelog file exists: read `kit_config_get_root ship.create_changelog true`. True creates `CHANGELOG.md` and reports the new path; false offers it and skips on a decline.

Source: Keep a Changelog format (keepachangelog.com).

### Step 6: Create conventional commit(s)

Follow conventional commits format: `type(scope): description`

Types: feat, fix, refactor, test, docs, chore, style, perf
Rules:
- Subject line under 72 characters
- Imperative mood ("add feature" not "added feature")
- NO spec IDs, task IDs, or phase markers in the subject (e.g. no trailing `(SPEC-002 TASK-5)`); put that context in the body or PR description
- If changes span multiple logical units, create separate commits for each
- Include a body if the change touches more than 2 files

Stage files intentionally. Do NOT `git add .` blindly.

Read `kit_config_get_root ship.confirm_commit false`. False, the default: commit, then show what landed, subject line and file count per commit. True: show the proposed commits and wait for a yes. The operator invoked `/kit:ship`, which is the request to commit; nothing is pushed at this step, so a wrong message is one `git commit --amend` away.

### Step 7: Update docs

Run the pinned diff (the merge-base of the integration branch) against the WORKFLOW doc-impact map and update every companion the map names for each change-type touched; log any companion that did not move. The map is the canonical list. The bullets below are the common cases:
- `README.md` -- features, setup steps, env vars
- `CLAUDE.md` -- tech stack, structure, commands
- `CHANGELOG.md` (or `docs/CHANGELOG.md` if that's the repo's convention, SPEC-185) -- already updated in Step 5
- `docs/specs/SPEC-NNN-<slug>.md` -- mark completed tasks
- `ARCHITECTURE.md` -- structural changes
- API docs (openapi.yaml, docs/api.md, etc.)

For each file: make the minimum edit needed, preserve existing style, no phantom features.
Create a single commit: `docs: update [list of files] to match current codebase`

### Step 7b: Archive shipped goal drafts

Once the spec is marked SHIPPED, retire its goal draft so `.claude/goals/` stops showing finished work as live. Run:

```bash
bash lib/goal/goal-drafts.sh archive
```

It moves every `.claude/goals/<slug>.md` whose `target_spec` resolves to a SHIPPED spec into `.claude/goals/done/` (moved, never deleted; status flipped to `shipped`) and leaves specless or still-live drafts in place. Idempotent, so it also sweeps up any draft whose spec shipped in an earlier cycle. Graceful no-op when `.claude/goals/` is absent. Report what moved in the Step 9 summary. Source: SPEC-037, ADR-0023.

**Stacked PRs (SPEC-065):** when the OPEN PRs form a squash-stacked chain and the human
says merge, do not merge by hand: `bash lib/goal/stack-merge.sh chain <bottom-pr#> ...` runs the
proven per-link dance (retarget child BEFORE merging the parent, squash-merge, reconcile
the child on the new tip with a superset-safe merge). `--dry-run` prints the plan first.
This replaces the manual merge of Step 8's output, not Step 8 itself.

### Step 8: Open PR (if on a feature branch)

If the current branch is not main/master:
- **Record the ship gate (ADR-0024):** `bash lib/gate/gate-ledger.sh record <rid> Ship ran "shipping pr=#<N>"` (carry the PR number once it exists; lane telemetry reads it as the run outcome, SPEC-061). The `ship-gate` hook will refuse the push below if the active spec's lane still has a `measure-twice` gate with no `ran`/`override` entry; it names the missing gate(s). Run the missing gate, or log a reason: `bash lib/gate/gate-ledger.sh override <rid> <Phase> "<reason>"` (recorded in the audit trail). See WORKFLOW.md "## Gate ledger and ship enforcement".
- Run `git push origin [branch]`
- Generate a PR description from the commits:
  ```
  ## What
  [summary of changes]

  ## Why
  [link to spec or decision brief if exists]

  ## Review
  [review verdict from the spec's ## Review section, or "not reviewed"]

  ## Testing
  [what was tested, test results]

  ## Checklist
  - [x] Tests pass
  - [x] Docs updated
  - [x] Review: [SHIP / skipped]
  - [ ] No regressions
  ```
- If the spec references issue numbers, link them in the PR.
- Tell the user the PR is ready.
- **Draft default for unattended runs (SPEC-224, autonomous path only).** Interactive `/kit:ship` opens a normal PR, unchanged. When this run was launched by the autonomous queue (`lib/queue/queue.sh`), the typed `/goal` line carries a clause to open the PR as a draft (`gh pr create --draft`) and append a provenance footer naming the run: `[unattended orchestrator run; journal <path>; slug <s>]`. That draft posture marks the PR as machine-opened and unreviewed; a human clicks "Ready for review". The `--ready` queue flag (or `QUEUE_PR_READY=1`) drops the clause and opens a normal PR, mirroring OpenHands' model-overridable `draft=False`. Nothing here changes the interactive path: `_goal_line` is the only place the draft default is injected, and interactive shipping never calls it.
- **Understanding-gate nudge (ADR-0031 Refinement §4, SPEC-125, SPEC-136):** on a `gate`/gated-final PR, first record the Understanding-debt marker, then decide whether to nudge:
  1. `bash lib/classify/significance-classify.sh record <rid> --files "<files>" "<what changed>" || true` -- writes the FAT `significance=`/`worthiness=`/`verdict=` line to the debt ledger LIVE, using the same files/description the tap call below uses. Guarded with `|| true`: advisory, a `record` failure must never block the ship. This is what makes the next bullet's "after the Understanding-debt marker is recorded" literally true, and it is what logs the SILENT-WAVE case (significant-but-low-worthiness, `verdict=wave`, no human response) even when the tap below prints nothing.
  2. `bash lib/gate/quiz-gate.sh tap <rid> --files "<files>" --pr-kind gate "<what changed>"`. On a `tap` verdict it prints the ★-tap nudge; present it and route the human's engage/defer/wave via `/kit:quiz-gate` (`lib/gate/quiz-gate.sh respond`), which forward-carries the marker recorded in step 1 onto the human's response line. Advisory, never blocks the merge; a `wave`/`not-significant` change prints nothing further here (it is already logged by step 1).
  3. **Pitch offer (SPEC-140, advisory only):** read back the verdict step 1 just wrote -- do NOT re-classify -- `bash lib/gate/gate-ledger.sh show <rid> | grep '| DEBT |' | tail -1`. If that line contains `significance=high` AND the repo is team-shared (`bash lib/pitch.sh team-shared`, exit 0 = yes), print: "significant outward change: `/kit:pitch <rid>` assembles the buy-in doc for team review." Exit-0, never blocks; a `significance=low` verdict or a solo repo (team-shared exits 1, including any `gh` failure) prints nothing further here, same anti-fatigue posture as the ★-tap nudge above.
  4. **Lane de-escalation nudge (SPEC-141, advisory only):** derive the lane the same way `hooks/ship-gate.sh` does -- `LANE=$(grep -m1 -iE '^Lane:' docs/specs/SPEC-NNN-<slug>.md | sed -E 's/^[Ll]ane:[[:space:]]*//; s/[[:space:]].*$//')` -- then `bash lib/classify/lane-classify.sh deescalate "$LANE" --rid <rid>`. Fires ONLY when the chosen lane was `normal`/`full` AND the final diff (`base..HEAD` + any working-tree delta) stayed under `LANE_DEESCALATE_FLOOR` changed lines (env var, default 20 -- named + overridable, documented next to the Lane×phase depth matrix in WORKFLOW.md). On fire it prints one advisory line ("shipped as `<lane>` but the diff stayed tiny-sized ... consider `tiny` lane next time") and appends a `| ACTION | lane-deescalate chosen=... verdict=misroute-tiny` ledger line, the data source for the stats misroute query. Exit-0 always, same anti-fatigue / never-blocks posture as the ★-tap nudge and the pitch offer above; `tiny`/`bug`/`backfill` lanes and any diff at or over the floor print nothing further here.

If on main: warn that they should have used a feature branch.

### Step 9: Summary

```
## Ship summary
Branch: [branch]
Version: [old] -> [new] (or "no version file")
Commits: [N]
Tests: [pass/fail/skipped]
Review: [SHIP / FIX THEN SHIP / skipped]
Changelog: [updated / created / skipped]
Docs updated: [list]
Drafts archived: [list moved to .claude/goals/done/, or "none"]
PR: [URL or "ready to push"]
```

Source: ClaudeKit /ck:ship pipeline (merge > test > adversarial review > version > changelog > push > PR). Adapted: review gate reads the spec's `## Review` section instead of running inline review. Version bump is optional and project-aware.
