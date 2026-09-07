# Verification log: SPEC-250 prose-rag adapter

Spec: `docs/specs/SPEC-250-prose-rag-adapter.md`. Branch `feat/prose-rag-adapter`, base 8e4eb46. Lane normal, proof class behavioral.

## Green run (lead, worktree at 7e56773)

Command: `bash tests/test-prose-rag-adapter.sh && bash tests/test-kit-contract.sh && bash tests/test-meta.sh && bash tests/test-no-personal-paths.sh`
Exit: 0
Output (excerpt): `24 run, 24 passed, 0 failed`; `kit-contract: 25 passed, 0 failed`; `Passed: 840 / 840`; `Passed: 3 / 3`.
Verdict: PASS

## Primary flow (the real thing, not a proxy)

Command: with context-kit's binary on PATH and no env, `bash bin/prose-rag query x` runs that binary; with `PROSE_RAG_BIN=<stub>` the stub runs with its arguments; with neither, `hook` exits 0 silently, `index` without a corpus exits 0 with the "nothing indexed" line, `query x` exits 1 naming `src/prose-rag`; the shim placed on PATH as `prose-rag` with no engine exits 1 promptly (the `PROSE_RAG_SHIM_ACTIVE` recursion guard, implementation note a).
Exit: 0 / 0 / 0 / 0 / 1 / 1 as listed
Verdict: PASS (task-verifier, fresh context; see the entry below)

## NEGATIVE CONTROL (lead, throwaway worktree at 7e56773, removed after)

Command: `bash lib/gate/negctl.sh <throwaway> "bash tests/test-prose-rag-adapter.sh" "sed -i '' 's/PROSE_RAG_BIN/PROSE_RAG_BIN_DISABLED/g' bin/prose-rag"`
Exit: 0 green before; 1 under mutation; 0 after `git checkout HEAD -- bin/prose-rag`
Output (excerpt): negctl `Verdict: PASS`; with the env override ignored the `PROSE_RAG_BIN` cases go red.
Verdict: RED-as-expected; the shared worktree was never mutated.

## Task verify (fresh context, task-verifier)

Command: the Verification line plus eleven hand checks in a temp dir (env override, directory fall-through, PATH stub with spaced args, the three no-engine exits, the recursion case under `ulimit -t 10`, crate absent, shim never names `lib/prose-rag`, seams report and shim agree on the binary, workflow step registered, no dashes or personal paths in the diff)
Exit: 0
Output (excerpt): `VERDICT: PASS`, criteria 9/9; the `PROSE_RAG_SHIM_ACTIVE` guard is load-bearing because `install.sh` writes `~/.local/bin/prose-rag` as a wrapper that execs this shim.
Verdict: PASS
