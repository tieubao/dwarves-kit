---
description: "Pick up the next undone task from the spec. Loads context, shows acceptance criteria, lets you drive the implementation."
---

You are a task dispatcher. Read the spec, find the next task to work on, and set up the context for implementation.

## Process

### Step 1: Find the next task

Read the active spec. Resolve it the same way the hooks do (the SPEC-005 dual-mode rule, reconciled to ADR-0010): among `docs/specs/SPEC-*.md`, take the lone non-SHIPPED/PARKED spec; if several are live, pick the one whose slug matches the current git branch; if the branch match is zero or ambiguous, ask the user which spec (do NOT guess). `docs/specs/SPEC-NNN-<slug>.md` is the sole spec location (ADR-0010).

Find the first task that is:
- Not marked as done (`[x]` or `DONE`)
- Has all dependencies satisfied (dependent tasks are done)

If multiple tasks are available (independent, no ordering constraint), present them and let the user pick.

### Step 2: Load context

For the selected task, gather:
- The task description and acceptance criteria from the spec
- Relevant files mentioned in the task or in `docs/briefs/CONTEXT.md`
- Current git branch and status
- Any related decision records from `docs/decisions/`

### Step 3: Present the task briefing

```
## Next task: TASK-[ID]
[description]

### Acceptance criteria
- [ ] [criterion 1]
- [ ] [criterion 2]

### Files to touch
- [file 1] — [what to change]
- [file 2] — [what to change]

### Context loaded
- [relevant file or decision]

### Dependencies
- TASK-[X]: [done/pending]

### Remaining after this
- [N] tasks left in current phase
- [N] tasks left total
```

### Step 4: Hand off

Say: "Ready to implement. Work through the acceptance criteria one by one. When done, run `/kit:next` again for the next task, or `/kit:review` to review your changes."

**Also remind**: "As you implement, maintain `docs/implementation-notes/<spec-slug>.md`. Append an entry whenever you make a decision the spec did not pin down, deviate from the spec, hit a tradeoff worth surfacing, discover a missing constraint, or hit an open question you'd want the operator to confirm or revise. Entry shape: `## YYYY-MM-DD HH:MM <title>` with Context / Decision / Why / Alternatives considered / Impact / Open questions lines. If the task runs with zero deviations, append a one-line `No deviations; matches the spec verbatim` entry so the absence is intentional. The file is surfaced in the `/wrap-session` LAB_LOG line and the PR description."

If the file does not yet exist, create it with a short header (`# Implementation notes: <spec-slug>` + a one-line pointer to the spec path) before handing off, so the implementor only has to append.

Do NOT start implementing. This command is a dispatcher, not an executor. The user or contractor drives the implementation after seeing the briefing.

### Step 5: When called again after completion

If the user runs `/kit:next` again:
1. Ask: "Is TASK-[previous] done? Mark it complete?"
2. If yes, update `docs/specs/SPEC-NNN-<slug>.md` to mark it `[x]` with the commit hash
3. Find and present the next task

## Edge cases

- **All tasks done**: "All tasks in the spec are complete. Run `/kit:review` for code review, then `/kit:ship` to merge." Then surface the `_meta/BACKLOG.md` Active queue (read-only; the Schema there defines the columns) as "what's left next", plus any `.claude/goals/` drafts (top-level `*.md` only; archived drafts under `.claude/goals/done/` are skipped), so the next item can be picked with `/kit:assign ID-NNN`. Degrade gracefully on a malformed queue; never mutate.
- **No spec found**: "No spec found. Run `/kit:spec` to generate one first."
- **Ambiguous spec** (several live `docs/specs/` specs, no single branch match): list them and ask which to work on; do not pick one silently (mirrors the hooks' `spec:ambiguous(...)`).
- **Blocked task**: "TASK-[ID] depends on TASK-[X] which is not yet done. Complete TASK-[X] first, or choose a different task."
