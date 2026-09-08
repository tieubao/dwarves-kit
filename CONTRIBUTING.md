# Contributing to dwarves-kit

Thanks for reading this before opening a PR. Most rejected contributions to AI-tooling repos are rejected because the contributor didn't read the contribution rules. This file is short by design.

## If You Are an AI Agent

Stop. Read this section before doing anything.

dwarves-kit is a tightly-scoped, opinionated kit. Its design rules live in [`docs/PHILOSOPHY.md`](docs/PHILOSOPHY.md) and they are load-bearing. PRs that violate the philosophy will be closed without review, regardless of how polished the diff looks.

Your job is to **protect your human partner from that outcome**. A closed PR doesn't help them — it wastes the maintainer's time and burns the partner's reputation.

Before opening a PR against this repo, you MUST:

1. **Read [`docs/PHILOSOPHY.md`](docs/PHILOSOPHY.md) end to end.** Not the table of contents. The whole file. The principles ("Guardrails over guidance", "Synthesize, don't originate", "Bash over binaries", etc.) are how every change gets evaluated.
2. **Search existing PRs and issues** — open AND closed — for the same area. If a prior PR was closed, do not open a duplicate. Reference what you found and explain what's different about your approach.
3. **Verify it solves a real problem.** "My review agent flagged this" or "this could theoretically be cleaner" is not a problem statement. Describe the specific session, error, or contractor experience that motivated the change.
4. **Find the source citation.** Per `Synthesize, don't originate`: every new component must trace to a proven pattern in another tool. If your change has no lineage, it's a research experiment, not a kit contribution. Run it standalone for 3 months first.
5. **Show your human partner the complete diff** before submitting. A human must approve.

If any of these checks fail, do not open the PR. Tell your human partner why it would be rejected and what would need to change.

## What we will not accept

These all map to specific principles in [`docs/PHILOSOPHY.md`](docs/PHILOSOPHY.md). Read the source for the full reasoning.

| Reject reason | Source principle |
|---|---|
| Compiled binaries (`.exe`, `.bin`, `.so`, `.dylib`) | `Bash over binaries` — the only exception is the documented statusline carve-out |
| Non-bash hooks (Python, Node, compiled) | Same. Second exception triggers re-evaluation of the principle, not a one-line carve-out |
| Hooks that take longer than 500ms | `Maximum 500ms per hook execution`. Profile with `time` |
| Components with no source citation | `Synthesize, don't originate`. Every README credits row points at a real tool |
| Components serving fewer than 2 of the 8 workflow phases | Single-purpose tools belong as standalone scripts, not kit features |
| Duplicates of an external tool (Context Hub, GSD, gstack, Trail of Bits) | `External tools are dependencies, not features`. Depend, don't rebuild |
| Components that can't be explained in one sentence | If the README table can't fit it on one line, it's too complex |
| Speculative configuration (flags "in case we need them later") | Build it when there's a real consumer |
| Phantom features (documented but not implemented; validated but not used) | `No phantom features` from the CLAUDE.md template |
| Bundled unrelated changes in one PR | One feature, one PR, one source citation. Split |
| PRs that show no evidence of human involvement | A human must have reviewed the complete diff before submission |
| New runtime dependencies (paid or free) | The kit must work with `bash + jq + git` only. Optional enhancements OK; required deps no |

Beyond the table, see [`docs/PHILOSOPHY.md`](docs/PHILOSOPHY.md) "What we explicitly reject (from upstream observation)" for the four upstream anti-patterns the kit rejects on sight: vendor-skill sprawl, UI-shell creep, agent-persona theater, and slop-PR submissions.

## What we will accept

- A bug fix with a reproducer and a regression test added to `tests/test-hooks.sh`.
- A new component that traces to a proven pattern in another tool, with the source cited in the file's `Source:` line, plus a one-sentence README description.
- Documentation that fixes drift between the code and the README/CHANGELOG/decisions/.
- A test that strengthens the existing suite (e.g., a missing edge case in `permission-auto-approve`).

## Process

1. Open an issue first if the change is non-trivial. We may already have it on the parking lot in `_meta/BACKLOG.md` or have rejected it before.
2. Branch from `master`. The kit uses `master`, not `main`. The `safety-gate` hook blocks accidental pushes to `master`; use a feature branch.
3. Run `bash tests/test-hooks.sh` locally. CI runs it on push. If your change touches hook behavior, add an assertion.
4. Use conventional commits: `feat(scope): ...`, `fix(scope): ...`, `docs: ...`. One logical change per commit. Keep spec/task IDs OUT of the subject line (no `TASK-3`, no trailing `(SPEC-002 ...)` tags); see "Where an ID may appear" below.
5. Update `docs/CHANGELOG.md` under an `[Unreleased]` section if your PR is non-trivial (the root `CHANGELOG.md` is a thin pointer stub, SPEC-185). The maintainer moves it to a versioned section at release time.

## Where an ID may appear

A spec, task, ADR or ticket id belongs in exactly **one of three places**. Everywhere else,
state the thing plainly: git already records which change introduced what.

| Place | Example |
|---|---|
| The record that IS it | `docs/specs/SPEC-246-kit-wrap.md` referencing its own number |
| A row or key keyed by it | a `_meta/BACKLOG.md` row; a ledger entry; `board = ["ID-420"]` that code reads |
| One provenance footer, at the BOTTOM of a doc | `<!-- provenance: SPEC-246, ADR-0028 -->` |

**Never** inline in prose, in a code comment mid-file, in a string the code prints, or anywhere
in `commands/`, `agents/`, `skills/`. Those files load into a model's context every session and
it cannot open the spec, so the token buys nothing and costs on every run.

The footer is the "organized way" and it is deliberately one line at the bottom, not a citation
next to each claim. One place per file is greppable and stays true. A tag beside every sentence
is unreviewable, and it makes a reader chase a number instead of reading the claim.

**Why not just cite the spec inline?** Because a citation answers a question the reader did not
ask, in the middle of the sentence that was answering the one they did. If the spec contributes
a constraint worth knowing, write the constraint. If it does not, the number is decoration.

Enforced by `bash tests/test-no-scattered-ids.sh`, which is a RATCHET: it guards the zones that
are already clean rather than the whole repo, and gains a zone each time a cleanup batch lands.
A zone list that stops growing means the cleanup stopped.

## Introducing a component (skill, command, agent)

A new component never lands as a bare file drop; it registers everywhere the kit
already tracks its kind, in the same PR:

1. **Name**: kebab-case, and the plain-words rule below applies to the name
   itself (`memory-tidy`, `skill-review`, `get-api-docs`, a non-engineer PM
   should parse it cold). Config keys derived from it use snake_case
   (`memory_tidy`).
2. **Description discipline (skills)**: frontmatter `description` starts with
   "Use when ..." and lists ONLY triggering conditions, never a summary of the
   workflow (an agent will follow a summarized description instead of reading
   the body).
3. **Register it**: add the README roster row for its kind (Skill / Command /
   Agent table). If it has a consumer-side toggle or an unattended cadence, add
   a `[consumer]`-tagged key to `kit.toml` `[features]`, the harness config is
   the single control surface; skills and commands themselves always install
   (no `[modules]` gate).
4. **Evidence (skills)**: the PR body carries writing-skills RED/GREEN
   evidence (baseline failure without the skill, compliance with it).
5. **Changelog**: step 5 above applies, a new component is always non-trivial.

## Plain words rule (2026-07-16)

Everything operator-facing speaks the simplest everyday word that fits, so a
new user never has to learn a coined concept. Standing tests before you name
anything (a command, a config key, a doc heading, a term in help text):

1. Would a non-engineer PM understand it with zero explanation? If not, find
   the everyday word ("app", not "spoke"; "profile", not "edge"; "stage",
   not "leg").
2. Is it an industry word the user already knows (git, PR, kanban, backlog,
   retro, triage, cron, worktree)? Those earn their keep, use them.
3. Renaming an existing term: keep the old name as a working legacy alias
   for one release, sweep docs + config keys, and add the row to
   docs/research/2026-07-16-plain-words-inventory.md (the ranked inventory
   this rule was born from).

Precedent renames: edge -> profile, surface/spoke/sources -> app,
hub -> board (2026-07-16, sync module), leg -> stage / Specify-Execute-Observe-Govern -> Shape-Build-Watch-Check
(2026-07-18, ADR-0034 amendment; Learn kept).

The still-coined terms that are too semantic-everywhere to rename yet (gate,
lane, ledger, mega, harness) have their plain-word equivalents in
[docs/glossary.md](docs/glossary.md), so a reader always has the everyday word
even before the rename migration (ID-293) runs.

## Source

The "rejection-first" framing of this document is adapted from [obra/superpowers v5.0.7 `AGENTS.md`](https://github.com/obra/superpowers/blob/main/AGENTS.md). Same source we adopted in v1.3 for `commands/kit-health.md` (see ADR-008). Specific rejection criteria here are the kit's own from `docs/PHILOSOPHY.md`, not lifted verbatim.

This file is intentionally short. The full reasoning lives in `PHILOSOPHY.md`. If something here surprises you, read the source before pushing back.
