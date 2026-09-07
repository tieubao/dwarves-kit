---
description: "Adopt the current (or a target) repo into the dwarves-kit operate-contract: inject AGENTS.md + a CLAUDE.md loader + a WORKFLOW pointer + the proof marker, idempotently, and wire the lane/loop-type/proof classifiers so the ship-gate engages."
---

You are adopting a repo into the dwarves-kit operating layer. This installs the operate-contract
so that, from now on, an agent working in that repo classifies the work and picks a lane before
coding, and the ship-gate engages on push.

## Run

`$ARGUMENTS` may name a target dir (default: the repo root), `--check` (status only), or
`--with <a,b,c>` (seed these modules `true` in a FRESH `.kit.toml`; ignored once one exists).

1. Resolve the target: default `.` (`git rev-parse --show-toplevel`).
2. Run the driver (idempotent, non-destructive):

   ```
   bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/dwarves-kit}/lib/adopt.sh" [--check] [--with <a,b,c>] <target>
   ```

3. Report what it created (or that the repo was already adopted). Tell the user the one next
   step: open a session in the adopted repo and run `/kit:start` to classify the first task.

## What adoption installs

- `AGENTS.md` -- the operate-contract (read-first).
- a `CLAUDE.md` loader pointer (Claude Code auto-loads CLAUDE.md, not AGENTS.md).
- `WORKFLOW.md` -- a pointer to the installed kit's lane x phase matrix (not a 49KB copy).
- `docs/verification/README.md` -- the proof marker that makes the ship-gate engage.
- `.kit.toml` -- an OPT-IN starter override of the kit-root defaults (SPEC-192). Created
  only on a fresh adopt (never overwritten afterward); `--with` seeds the named modules
  `true` instead of inheriting the kit-root default. Edit `[modules]` any time and re-run
  `/kit:adopt` (or `--refresh`) to re-wire.
- `.claude/settings.json` hook entries for this project's currently-enabled hook-bearing
  modules (`board`, `session`, `advisor`, `cosmetic`) -- a targeted jq MERGE, re-wired on
  every adopt run from the project's CURRENT `.kit.toml`, never a wholesale file rewrite.
  Command/skill modules (`queue`, `stats`, `quiz_gate`, `weekend_batch`, `bridge`) need no
  settings.json entry.

The classifiers (`lane-classify`, `task-type-classify`, `proof-gate`) run from the installed kit;
adoption wires the contract to reference them. It never copies the engine.

## Overlays and seams

Adoption installs the engine alone; no `[modules]` entry requires a companion kit. Two overlays
exist today. context-kit is the data plane: it owns the context tree and recall over it, and
fills `[knowledge] root` plus the `PROSE_RAG_BIN` binary. learning-kit is a study overlay on the
engine; it fills `[wrap] before` with its concept flush.

A seam is a key in the operator `kit.toml`, never this repo's `.kit.toml`, that the engine reads
with `kit_config_get_root`. `bash "$KIT/bin/config" seams` lists every seam with its state
(`default`, `filled`, `unresolved`, `absent`); `--check` exits 1 on an unresolved row, for an
installer. With nothing filled, every seam reads `default` or `absent` and the adopted repo works
the same. Table: `lib/config/module-registry.md` under `## Seams`.

## Do NOT

- Overwrite an existing AGENTS.md / CLAUDE.md / `.kit.toml` (the driver guards this; never
  force it; `--with` on an existing `.kit.toml` is a no-op with a note).
- Copy `lib/` or the full `WORKFLOW.md` into the consumer.
