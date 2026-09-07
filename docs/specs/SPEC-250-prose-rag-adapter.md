# Spec: prose-rag adapter
Generated: 2026-09-07
Status: APPROVED
Lane: normal
References: `bin/prose-rag` (the stable consumer entrypoint whose resolution order changes; keep every exit contract it states in its header); `lib/config/config.sh` `_seam_target_resolves` binary kind (the same `PROSE_RAG_BIN` then `command -v prose-rag` order the seams report already uses, DEC-009/DEC-010 of SPEC-249); context-kit `src/prose-rag` (the crate this adapter now points at; CK-7).

## Problem

context-kit owns the recall engine: its Cargo workspace carries `prose-rag` and `cargo install --path src/prose-rag` puts the binary on PATH (CK-7, 2026-07-26). This kit still vendors a full copy of the crate under `lib/prose-rag/rust` (116K) and `bin/prose-rag` looks only at builds of that copy, so two builds of one engine drift and the seams report (`PROSE_RAG_BIN` row) describes a binary the adapter never uses. ID-647.

## Solution

### Approaches considered

1. **Thin adapter over PATH.** `bin/prose-rag` resolves `$PROSE_RAG_BIN`, then `prose-rag` on PATH, and execs it; the vendored crate is deleted. Tradeoff: a kit-only operator without context-kit loses recall until they install the binary, which was already the documented optional state.
2. **Keep the crate, add PATH first.** Tradeoff: two engines remain, the drift this row exists to end.
3. **Git submodule of context-kit.** Tradeoff: couples release cadences, the exact thing `kit-versioning.md` forbids.

### Chosen approach + why

Approach 1. The seam row already names the binary and the resolution order; the adapter simply obeys it. Approach 2 keeps the defect; 3 re-couples the kits.

### Extensibility & boundaries

One resolver in one shim. A future engine (a different binary name) is one more `command -v` line. Unit: `bin/prose-rag` (resolution and the three no-engine exits), testable with a stub on a temp PATH.

## Picture

```
 caller (hook, kit-weekly index, operator)
   │
   ▼
 bin/prose-rag ── $PROSE_RAG_BIN executable? ──▶ exec it
   │              else `command -v prose-rag`? ──▶ exec it     (context-kit's cargo install)
   │              else:
   ├─ hook            -> exit 0 (a recall hook never breaks a prompt)
   ├─ index, no corpus-> print "nothing indexed", exit 0
   └─ anything else   -> "prose-rag: engine not installed; cargo install --path <context-kit>/src/prose-rag" exit 1
 lib/prose-rag/rust  -> deleted; README/SPEC say "adapter", point at context-kit
```

## Design

obvious: one shim's lookup order changes to the order the seams report already documents, and a duplicate crate is deleted.

## Technical Design

### Interfaces (I/O contract)

`bin/prose-rag <verb> [args]`: if `PROSE_RAG_BIN` is set and executable (regular file, `-f` and `-x`), exec it with the arguments; else if `command -v prose-rag` finds one, exec it; else `hook` exits 0 silently; `index` with no `PROSE_RAG_CORPUS` and no `--corpus` prints the existing "no corpus configured" line and exits 0; any other verb prints `prose-rag: engine not installed; install context-kit's binary: cargo install --path <context-kit>/src/prose-rag (or set PROSE_RAG_BIN)` on stderr and exits 1. Invariant: the shim never runs a build and never looks under `lib/prose-rag/`.

### Data model changes

None. `kit.toml [modules] prose_rag` comment states the module wires the hook and this adapter, and that the engine binary comes from context-kit.

## Task Breakdown

### Phase 1: Foundation

- [ ] TASK-001: the adapter and its test. Rewrite `bin/prose-rag` per the interface; new `tests/test-prose-rag-adapter.sh` (temp PATH, a stub binary that echoes its argv and a canary env; cases: `PROSE_RAG_BIN` set to a stub → stub runs with the args; `PROSE_RAG_BIN` set to a non-executable → falls through; stub on PATH → runs; neither: `hook` exit 0 with empty output, `index` without corpus exit 0 with the message, `query x` exit 1 with the install hint naming `src/prose-rag`; the shim never references `lib/prose-rag/rust`: `grep -c 'lib/prose-rag' bin/prose-rag` is 0). Register the test in `.github/workflows/test.yml`. Acceptance: the new test green; `bash tests/test-kit-contract.sh` green after its references are updated.

### Phase 2: Core

- [ ] TASK-002: retire the crate and fix the docs. `git rm -r lib/prose-rag/rust`; `lib/prose-rag/README.md` and `SPEC.md` describe the adapter and point at context-kit (no personal paths); `kit.toml` comment; `docs/CHANGELOG.md` Unreleased entry; every doc under `docs/verification/` that quotes the old build line gets one sentence "superseded by the adapter (SPEC-250)" rather than a rewrite; `lib/config/module-registry.md` `PROSE_RAG_BIN` row default text matches; regenerate `docs/FEATURES.md`. Acceptance: `bash tests/test-meta.sh` and `bash tests/test-no-personal-paths.sh` green; `ls lib/prose-rag/rust` fails; `git grep -n 'prose-rag-rs'` finds only historical verification docs.

## After state

- [ ] `PROSE_RAG_BIN=/path/to/stub bash bin/prose-rag query x` runs the stub. (Today: ignored.)
- [ ] With `prose-rag` on PATH and no env, `bash bin/prose-rag query x` runs it. (Today: "engine not built".)
- [ ] `ls lib/prose-rag/rust` fails. (Today: a 116K crate.)
- [ ] `bash bin/config seams` and `bash bin/prose-rag` agree on which binary runs (same env, same PATH).

## Acceptance Criteria (global)

- [ ] All tasks pass their individual acceptance criteria
- [ ] No regressions: `bash tests/test-kit-contract.sh && bash tests/test-meta.sh && bash tests/test-no-personal-paths.sh` green

## Verification

```
bash tests/test-prose-rag-adapter.sh && bash tests/test-kit-contract.sh && bash tests/test-meta.sh && bash tests/test-no-personal-paths.sh
```

## Edge Cases

1. `PROSE_RAG_BIN` points at a directory: falls through to PATH (a directory is `-x` but not `-f`).
2. `PROSE_RAG_BIN` set but empty: treated as unset.
3. Neither binary and the hook verb: exit 0, no output, so a prompt never breaks.
4. `index --corpus <dir>` with no engine: the install hint, exit 1 (an explicit corpus means someone is driving interactively).
5. Arguments with spaces reach the binary intact (`exec "$bin" "$@"`).

## Out of Scope

- Any change to `hooks/prose-rag.sh` beyond what the shim's contract needs.
- The `kit-weekly` job's schedule.
- context-kit's own release.

## Decision Log

- DEC-001: resolution order `PROSE_RAG_BIN`, then PATH, matching `config seams`; one order, two readers.
- DEC-002: the install hint names context-kit's crate path relative to a context-kit checkout, never an absolute path.

## Open questions

(none)
