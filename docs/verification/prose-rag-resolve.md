# Verification log: SPEC-251 prose-rag resolve

Spec: `docs/specs/SPEC-251-prose-rag-resolve.md`. Branch `fix/shim-skip-own-wrapper`, base 3dfd13b. Lane normal, proof class behavioral.

## Green run (lead, worktree at d22d5b1)

Command: `bash tests/test-prose-rag-adapter.sh && bash tests/test-config-seams.sh && bash tests/test-config-registry.sh && bash tests/test-kit-contract.sh && bash tests/test-meta.sh && bash tests/test-no-personal-paths.sh`
Exit: 0
Output (excerpt): `32 run, 32 passed, 0 failed`; `=== 51/51 passed ===`; `=== 23/23 passed ===`; `kit-contract: 25 passed, 0 failed`; `Passed: 840 / 840`; `Passed: 3 / 3`.
Verdict: PASS

## Primary flow (the real thing)

Command: on the operator's machine, with the kit's own `~/.local/bin/prose-rag` wrapper and context-kit's `~/.cargo/bin/prose-rag` both on PATH, `bash bin/prose-rag --help` prints the engine's usage and `bash bin/config seams` reports `PROSE_RAG_BIN binary ~/.cargo/bin/prose-rag filled`; with only the wrapper on a temp PATH the shim prints the install hint and the seams row reads `absent`.
Exit: 0 / 0 / 1 / 0
Verdict: PASS (task-verifier entry below)

## NEGATIVE CONTROL (lead, throwaway worktree at d22d5b1, removed after)

Command: `bash lib/gate/negctl.sh <throwaway> "bash tests/test-prose-rag-adapter.sh && bash tests/test-config-seams.sh" "sed -i '' 's/dwarves-kit CLI shim/dwarves-kit CLI shim-NEVER/' lib/prose-rag/resolve.sh"`
Exit: 0 green before; 1 under mutation; 0 after `git checkout HEAD -- lib/prose-rag/resolve.sh`
Output (excerpt): negctl `Verdict: PASS`; with the marker skip disabled the wrapper-alone and wrapper-first cases go red in both suites.
Verdict: RED-as-expected; the shared worktree was never mutated.

## Task verify (fresh context, task-verifier)

Command: the Verification line plus eight hand checks in a temp HOME and PATH (wrapper alone, wrapper before a stub, a symlink to the shim, the env override winning, a shim copy with no `lib/` beside it under `/bin/bash`, no `command -v` left in either reader, a canary stub that never printed during `config seams`, no dashes or personal paths in the diff)
Exit: 0
Output (excerpt): `VERDICT: PASS`, criteria 3/3; the resolver touches candidates only with `head -c`, `readlink`, `cd`/`pwd`, `basename`.
Verdict: PASS
