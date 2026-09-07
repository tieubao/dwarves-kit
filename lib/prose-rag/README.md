# prose-rag

Semantic search over your own prose corpus (a knowledge base, research notes, a
learned-ledger), so a prompt can pull in the relevant notes you have already
written. Fully local, no cloud embedder.

**This module is an adapter, not an engine (SPEC-250).** context-kit owns the
recall engine and its Rust crate; the kit vendored a second copy of it until
2026-09-07, and two builds of one engine drift. What ships here is the wiring:
the dormant UserPromptSubmit recall hook (`hooks/prose-rag.sh`, active only with
`PROSE_RAG_INJECT=1`) and the stable CLI entrypoint `bin/prose-rag`, which
resolves the engine binary and execs it. The shim never builds anything.

Enable with `bash install.sh --with prose_rag`.

## Install the engine (once per machine)

In a context-kit checkout:

```bash
cargo install --path src/prose-rag     # puts `prose-rag` on PATH
prose-rag index                        # first run downloads the model (~124MB), then ~1s
```

`bin/prose-rag` resolves, in this order, the same order `bash bin/config seams`
reports for the `PROSE_RAG_BIN` row:

1. `$PROSE_RAG_BIN`, when it names a regular executable file (context-kit fills this).
2. `prose-rag` on PATH.

With neither, `hook` exits 0 (a recall hook must never break a prompt), `index`
with no corpus configured prints "nothing indexed" and exits 0 (the shipped
kit-weekly job stays silent-green), and any other verb prints the install hint on
stderr and exits 1.

## Configure the corpus

The corpus is CONSUMER CONFIG: set `PROSE_RAG_CORPUS` to colon-separated
dirs/files (for example `~/notes:~/research:~/ledger.md`); unset means an empty
corpus and `index` skips clean. Under launchd, supply it via
`~/.config/kit-weekly/env`.

## Use

```bash
prose-rag query "claude code hook latency"      # rank relevant prior notes
prose-rag query "..." --k 8 --floor 0.4 --json
prose-rag index                                  # incremental: only changed files re-embed
prose-rag index --full                           # force a full rebuild
```

## Opt-in, recall-gated hook

A UserPromptSubmit hook injects the top matches, but only when it earns its keep:

- **Opt-in master switch.** The hook is inert unless `PROSE_RAG_INJECT=1` is in the environment, so you can wire it and leave it dormant until you flip the env. `--force` bypasses the switch (testing).
- **Recall gate.** Even when on, it only fires on recall/research-phrased prompts ("have I written...", "did I already..."). Operational prompts (edits, git, "fix this") are skipped first, so they pay ~4ms.

```json
{ "type": "command", "command": "/abs/path/to/prose-rag hook" }
```

## Tests

```bash
bash tests/test-prose-rag-adapter.sh    # resolution order + the three no-engine exits
```

The engine's own suite lives in context-kit, next to the crate.

## Design records

`SPEC.md` and `docs/implementation-notes/` are the historical records of the
folded-in engine (the Python original, then the Rust port). They describe the
engine, which now lives in context-kit; read them for the chunking rules, the
recall gate, and the embedding choices, not for the current build path.
