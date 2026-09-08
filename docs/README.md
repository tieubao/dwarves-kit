# docs/, the kit's design record (you do NOT need this to USE the kit)

If you just want to **use** dwarves-kit, stop here and read the repo [`README.md`](../README.md) or the condensed [`QUICKSTART.md`](QUICKSTART.md): install, then run your first `/kit:` cycle. Everything else in `docs/` is the kit's own design history and dogfood output, written while building the kit. A new user never has to open it.

This folder is large because the kit was built **through its own workflow**: every feature got a spec, most got an ADR, each cycle got a retro. That accumulation is the point, not clutter, but it is for maintainers and the curious, not for getting started.

## What's here

| Path | What it is | Read it if you want to... |
|---|---|---|
| [`architecture.md`](architecture.md) | Components, data flow, the state model, the verification pipeline | understand how the pieces fit before extending the kit |
| [`execution-planes.md`](execution-planes.md) | The four ways the kit runs agents: board, orchestrator, queue, gauntlet, and their trust models | work out which engine to reach for, or why two of them share a directory |
| [`PHILOSOPHY.md`](PHILOSOPHY.md) | Design principles, target user, the rejection list | know why a feature was kept out (load-bearing for contributors) |
| [`MANUAL.md`](MANUAL.md) | The full command reference | look up a `/kit:*` command's exact behavior |
| [`WORKFLOW.md`](WORKFLOW.md) | The full lifecycle write-up (root `WORKFLOW.md` is now a thin pointer stub to this) | understand the think -> spec -> execute -> review -> ship loop end to end |
| [`CHANGELOG.md`](CHANGELOG.md) | Release history | see what shipped in a given version |
| [`consumer-contract.md`](consumer-contract.md) | The stable surface a consumer repo may depend on | adopt the kit into another repo without reaching into internals |
| [`ABSORPTION.md`](ABSORPTION.md) | How the kit absorbs patterns from upstream sources | run `/kit:absorb` or audit source drift |
| `specs/` | One spec per feature (`SPEC-NNN-<slug>.md`), tracked in place via a `Status:` header | see how a feature was designed; also the kit's **live** spec store (hooks detect the active spec here) |
| `decisions/` | Architecture Decision Records, one per file (`NNNN-<slug>.md`) | understand why a choice was made, and what superseded it |
| `briefs/` | Pre-spec decision briefs + shared context notes | see the design exploration that preceded a spec |
| `retro/` | Per-cycle retrospectives (output of `/kit:retro`) | learn what worked and what hurt across cycles |
| `research/` | Dated deep-scans that fed specific specs | trace a spec back to its source research |
| `absorption/` | Templates + index for the absorption workflow | work on `/kit:absorb` |
| `audits/` | One-off dated audit reports (not tied to a single spec) | read a point-in-time cross-cutting audit |
| `releases/` | Per-version release artifacts | see what a specific release contained |
| [`impl-playbook/`](impl-playbook/) | Per-language/architecture implementation rules, distilled from named external style guides and standards | look up the rule set the review-team agents (`security-reviewer`, `code-reviewer`, `infra-reviewer`, `frontend-reviewer`, `test-writer`) cite for a given language or area |

## How to read it (for maintainers)

Start with `architecture.md` for the mental model, then `PHILOSOPHY.md` for the guardrails. From there, a spec (`specs/SPEC-NNN-*.md`) is the contract for one feature and an ADR (`decisions/NNNN-*.md`) is the reasoning behind one decision; ADRs supersede each other in place (the `## Status:` line names the superseder) rather than being rewritten.

## The full record, by theme

The `## What's here` table above is the quick map. The complete set of record classes, for a
maintainer navigating the whole `docs/` tree (every path below is in place; this is one central
map, not per-dir READMEs , `specs/` and `verification/` keep their own, deliberately):

**Design + decisions**
- [`specs/`](specs/) , one spec per feature, the live spec store. Numbering is per-namespace and
  local (each `*/docs/specs/` owns its own `SPEC-001..` sequence). Enumerate them with
  `bash lib/spec/spec-index.sh` (the read-only registry view) rather than a per-file list here , a
  hand-kept list would rot. See [`specs/README.md`](specs/README.md) for the numbering convention.
- [`decisions/`](decisions/) , ADRs (`NNNN-<slug>.md`), superseded in place.
- [`briefs/`](briefs/) , pre-spec `DECISION-BRIEF-*.md` write-ups + `CONTEXT.md`, the design
  exploration a spec gets drafted from. Not live specs (those stay in `specs/`).

**Build trail (what the workflow leaves behind , the two classes the quick map omits)**
- [`implementation-notes/`](implementation-notes/) , per-spec DELTA logs: the decisions made
  *during* a build that the spec did not pin, deviations, and constraints future-you should know.
  One file per spec-slug.
- [`verification/`](verification/) , per-feature proof-of-done records (run-tables + negative
  controls). **LOAD-BEARING:** [`verification/README.md`](verification/README.md) is the
  proof-of-done marker the ship-gate keys on (`hooks/ship-gate.sh`) , link it, never move it.
  `verification/generated/` holds the machine-generated companion run-tables (`proof-table-gen.sh`
  writes here; this folded the old repo-root `docs/runs/` in , never overwrites a canonical
  `proof-of-done.md`). There is no separate `docs/proof/`: that fold is complete, its content lives
  under `verification/` too.
- [`retro/`](retro/) , per-cycle retrospectives (output of `/kit:retro`).
- [`releases/`](releases/) , per-version release artifacts (one dir per shipped version).

**Sourcing**
- [`research/`](research/) , dated deep-scans that fed specific specs.
- [`absorption/`](absorption/) , templates + index for the `/kit:absorb` workflow.
- [`audits/`](audits/) , one-off dated audit reports that aren't tied to one spec or one cycle
  (e.g. a full-repo tool-usage audit).

No counts live in this map on purpose (a count rots; the README's directory-layout counts are the
ones under a test-meta parity pin). To count or list any class, read the directory or run
`bash lib/spec/spec-index.sh` for specs.
