> Historical design record from the ops-toolkit origin (2026-06). Corpus paths
> and host names below are the original author's; in the kit the corpus is
> consumer config via `PROSE_RAG_CORPUS`, and the Python engine described here
> was dropped at the fold (Rust engine only).

# SPEC: prose-rag

**Status**: superseded on the engine axis (2026-07-11). This spec describes the original
Python engine (fastembed bge-small + sqlite-vec, floors 0.55/0.62, ~250ms hook, full
re-embed per index). The canonical engine is now the Rust one in `rust/` (model2vec
static embeddings, incremental index, floors 0.32/0.40, ~29ms hook): see `README.md`
for the current contract and `docs/implementation-notes/rust-port.md` for the port
story. Both engines have since left the kit: SPEC-250 retired the vendored crate and
`bin/prose-rag` is an adapter over context-kit's binary (`cargo install --path
src/prose-rag`). The CLI shape, chunking rules, corpus, recall gate, and opt-in hook design below
hold for both engines. `tests/smoke.sh` has since grown to 11 checks (was 7); the Rust
engine's acceptance record is `docs/proof-of-done.md` feature 2.
**Audience**: implementer + future me
**Last updated**: 2026-06-14 (supersession banner 2026-07-11)

## Purpose

Stop re-deriving things I have already written. prose-rag indexes my prose corpus (`tieubao/til` + `ops-toolkit/research/` + `_meta/learned-ledger.md`) into a local semantic store and, on each prompt, surfaces the most relevant prior notes as context. Everything runs locally on the Air (fastembed bge-small, 384-d, into sqlite-vec); no prose leaves the machine.

Sub-goal 03 of `cc-elevation` (context-retrieval axis). Source: `research/2026-06-14-claude-code-events-tools-elevation.md` Axis 1. codebase-memory / Serena do NOT fit this (they are code-structure tools, no prose embeddings); confirmed by the 2026-06-06 benchmark.

## CLI contract

```
prose-rag index [--corpus PATH ...] [--db PATH]
prose-rag query "<text>" [--db PATH] [--k N] [--floor F] [--json]
prose-rag hook  [--db PATH] [--k N] [--floor F]      # reads a UserPromptSubmit payload on stdin
```

| Default | Value |
|---|---|
| `--db` | `~/.claude/prose-rag/index.db` (env `PROSE_RAG_DB`) |
| corpus | til + ops-toolkit/research + learned-ledger.md (env-overridable) |
| model | `BAAI/bge-small-en-v1.5` (env `PROSE_RAG_MODEL`) |
| query `--floor` | 0.55 |
| hook `--floor` | 0.62 |

Runs under the uv project venv (imports fastembed + sqlite-vec).

## Behaviour

- **index**: walk the corpus, split each markdown file into heading-anchored chunks (cap 1500 chars, skip <40), embed in one batch, replace the `chunks` table (source, heading, text, embedding blob).
- **query**: embed the text, brute-force `vec_distance_cosine` over all chunks, return top-k with similarity (`1 - distance`) >= floor.
- **hook**: read the UserPromptSubmit payload (`prompt`), query, and if any matches clear the floor, print a short "Relevant prior notes" block to stdout (which UserPromptSubmit injects as context). Silent (no output, exit 0) when nothing is relevant or the payload is junk.

**Relevance floor** is calibrated, not guessed: bge baseline similarity to unrelated text is ~0.50, genuine matches are 0.70-0.90, so the floors sit at 0.55 / 0.62.

## Non-goals

- **<100ms hook**: not met. fastembed cold-start is ~250ms/process, so the hook adds ~250ms/prompt. The hook is therefore OPT-IN; the index/query CLI is the latency-insensitive core. A warm daemon (future) would close the gap; not built for v1.
- **The Obsidian vault** and **a cloud embedder (Voyage)**: out (privacy: local-only). Flippable open knobs.
- **codebase-memory / Serena**: wrong tool class (code structure, not prose). Not used.
- **ANN index**: brute-force is fine at this corpus size.

## Verification (acceptance criteria)

`tests/smoke.sh` (temp 2-doc corpus, runs via `uv run`):

1. index builds (2 chunks).
2. seeded query: the distinctive doc is top-1 with sim >= 0.70.
3. relevance floor: gibberish returns nothing above 0.65 (negative control).
4. floor filter works: seeded at floor 0.99 returns nothing.
5. hook injects on an on-topic prompt (the doc appears).
6. hook stays silent off-topic (negative control).
7. hook never errors on empty/junk payload.

Plus a real run: indexed 4082 chunks; "hook latency self observability" -> til Hooks + the elevation note (0.76-0.78); "semantic retrieval over my notes" -> the elevation note + a prior prose-rag note (0.77-0.78). See `docs/proof-of-done.md`.

## Dependencies

- **python3** + the uv project venv: `fastembed` (bge-small ONNX, ~130MB on first run), `sqlite-vec`. `uv.lock` committed; `uv sync` to install.

## Install

```bash
cd tools/prose-rag && uv sync          # creates .venv from uv.lock
.venv/bin/python bin/prose-rag index   # build the index (~8 min for the full corpus)
.venv/bin/python bin/prose-rag query "what did I learn about X"
```

Opt-in UserPromptSubmit hook (note the latency caveat), in `~/.claude/settings.json`:

```json
{ "type": "command", "command": "/abs/tools/prose-rag/.venv/bin/python /abs/tools/prose-rag/bin/prose-rag hook" }
```

Use `.venv/bin/python` directly (not `uv run`) to avoid extra startup overhead. Re-run `index` when the corpus changes (a future cron can do this).

## Provenance

Born 2026-06-14 as `cc-elevation` sub-goal 03. fastembed chosen over model2vec by measurement (faster cold-start AND better embeddings here). REVERSED 2026-07-11 by the Rust port: mmap + lazy row conversion eliminated model2vec's cold-start penalty, and potion-retrieval-32M's quality proved acceptable on real recall queries (see `docs/implementation-notes/rust-port.md`). The query that proved it relevant also surfaced `research/2026-06-09-prose-rag-notes.md`, my own earlier thinking on this exact idea.
