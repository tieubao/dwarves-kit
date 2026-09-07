# Decision Brief: estate seams (ID-646)

## Verdict: BUILD (config seams + one report + two wrap steps; no new manifest format)

## Core thesis

The estate is three kits that each install alone: dwarves-kit is the process plane (gates, lanes, ledger, review fleets), context-kit is the data plane (the context tree and recall over it), learning-kit is a study overlay on the engine. Install dependency points at the engine (both overlays require dwarves-kit >= 2.0); data flow points the other way (every kit writes knowledge into the context tree). Those two directions must stay separate, and the only thing the engine may know about an overlay is a config key the overlay fills.

Today three hand-offs are implicit or backwards:

1. `/kit:wrap` runs an operator skill through `wrap.before` that writes `| DEBT |` markers into this kit's gate ledger and gates new-tool candidates through `precedent`. Both are process-plane work; they belong in the command, not in a skill outside the kit.
2. Nothing tells the engine where the context tree lives. Knowledge writers (the wrap distill step, `memory-tidy`, `stats memory-sweep`) default to whatever the model guesses.
3. No surface shows an operator which seams are filled. `plugin-check` checks the plugin; the cross-kit wiring is invisible.

## Strongest argument for

Every existing seam (`wrap.before`, `wrap.activity_log`, `precedent.registry`) already follows one rule: a key in the operator `kit.toml`, read with `kit_config_get_root`, never from a project `.kit.toml`. Generalising that rule to a named seam list costs one config key, one read-only report, and prose. It satisfies the standalone-first doctrine (ID-396) without a manifest format nobody maintains.

## Strongest argument against

A `[knowledge] root` key with no engine writer behind it is a promise. Mitigation: the wrap distill step and `memory-tidy` are the first two readers in this spec, and the report marks a filled key whose path does not exist as `unresolved`.

## Recommended scope for v1

**IN:**

- `[knowledge] root = ""` in kit-root `kit.toml`. Empty means repo-local: `<repo>/.claude/memory/` for repo memory, `docs/retro/` for retros. A filled value is the context tree root; repo knowledge then files under `<root>/projects/<repo>/`. Read with `kit_config_get_root` only.
- A seam registry: `lib/config/seams.tsv` (or an equivalent single table), one row per seam: key, kind (`skill|path|file|binary`), default, filled-by (which overlay or the operator), reader (which command reads it). Rows at v1: `wrap.before`, `wrap.activity_log`, `precedent.registry`, `knowledge.root`, `prose-rag` (binary on PATH or `PROSE_RAG_BIN`).
- `plugin-check --seams`: prints the table with the resolved value and a status per row: `default`, `filled`, `unresolved` (filled but the skill/path/binary does not resolve). Read-only, exit 0 always, no JSON needed at v1.
- `/kit:wrap` gains the process half of session distill, after the `wrap.before` seam and before step 0 or as a named step: (a) if the session was an orchestrated batch (a run id in the gate ledger with dispatched workers, a spec run, a goal run), record the `| DEBT |` marker via `lib/gate/gate-ledger.sh debt`; (b) candidates for a new tool or skill (a procedure run three or more times, a one-off script the operator called recurring) go through `precedent find --surface inventory --quiet` and land as a staging row via the existing staging writer, never a board row; (c) incidents written this session whose `## Root cause` names our own mistake become one repo memory note under the knowledge root. Everything else (til publish, concept flush, research notes) stays outside, behind `wrap.before`.
- `commands/onboard.md` and `commands/adopt.md`: one short section naming the overlays (context-kit fills `knowledge.root` and the `prose-rag` binary; learning-kit fills `wrap.before` with its concept flush), stating none is required, and pointing at `plugin-check --seams`.
- `kit.toml` comments for the new key; `docs/FEATURES.md` regenerated.

**CUT:**

- Retiring the vendored prose-rag crate (ID-647, separate row).
- A per-kit manifest file, a `provides`/`wants` schema, version negotiation. The seam table is the whole mechanism.
- Any engine writer for the til or memo publish leg.
- Changes to context-kit or learning-kit (they follow in their own repos once the key name is fixed).

## Survival scenarios

- Operator with only dwarves-kit: `plugin-check --seams` shows every row `default`; `/kit:wrap` files a memory note under `<repo>/.claude/memory/`; nothing asks for an overlay.
- Operator with context-kit: `knowledge.root` filled; the wrap note lands under `<root>/projects/<repo>/`; the report shows `filled` with the path.
- Operator sets `knowledge.root` to a path that does not exist: report says `unresolved`; `/kit:wrap` falls back to repo-local and says so in its report.
- A project `.kit.toml` sets `knowledge.root`: ignored, the report shows the operator or kit-root value; a test pins this.
- Session with no batch run and no incident: wrap's new step prints one line saying so and moves on.
