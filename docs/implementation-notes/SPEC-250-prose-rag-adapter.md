# Implementation notes: SPEC-250 prose-rag adapter

## 2026-09-07 23:40 TASK-001 adds a recursion guard the Interfaces section does not state

Context: the module installs `bin/prose-rag` as the operator's `prose-rag` CLI shim, so a consumer can put this file on PATH under that exact name. The spec's resolution order ends with `command -v prose-rag`.

Decision: set and export `PROSE_RAG_SHIM_ACTIVE=1` before either exec. A second entry skips resolution and falls through to the no-engine contract.

Why: without the marker, a shim that resolves itself execs forever in one process. The marker survives exec, so it terminates the loop with the documented exit instead.

Alternatives: compare the candidate path against the shim's own path. Rejected because the leaf is often a symlink and resolving it needs `readlink`, an external command the resolution path deliberately avoids.

Impact: the engine inherits one extra environment variable. Every stated exit and the resolution order are unchanged. `tests/test-prose-rag-adapter.sh` covers the case with a CPU cap, so a regression fails instead of hanging CI.

Open questions: none.

## 2026-09-07 23:40 TASK-001 narrows PATH in the test rather than emptying it

Context: the no-engine cases need a PATH with no `prose-rag` on it.

Decision: those cases run with `$TMPD/empty:/usr/bin:/bin`.

Why: an assignment on the command line applies before the command lookup, so a fully empty PATH stops the test from finding `bash` itself and every case fails for the wrong reason.

Alternatives: name the interpreter absolutely in each case. Rejected as less portable than a narrowed PATH.

Impact: the cases still prove "no engine installed" because neither `/usr/bin` nor `/bin` carries a `prose-rag`.

Open questions: none.

## 2026-09-07 23:40 TASK-001 strips prose-rag-rs from the kit contract

Context: C2 exempted `prose-rag-rs` from the wiring rule and C2b asserted that `bin/prose-rag` names it. The adapter names no vendored binary.

Decision: remove the exemption, the C2b assertion, and the stale C10 comment example.

Why: the spec's TASK-001 acceptance requires the contract green "after its references are updated", and TASK-002 requires `git grep prose-rag-rs` to find only historical verification docs.

Impact: `bash tests/test-kit-contract.sh` stays at 25 passed, 0 failed.

Open questions: none.

## 2026-09-07 23:55 TASK-002 also clears the module gitignore and the SPEC banner

Context: the spec names README.md, SPEC.md, kit.toml, the changelog, the verification sentences, the registry row, and the regenerated feature registry.

Decision: two files outside that list changed as well. `lib/prose-rag/.gitignore` loses its `rust/target/` and `bin/prose-rag-rs` entries, and the `SPEC.md` supersession banner gains one sentence pointing at context-kit.

Why: both named the deleted crate. An ignore rule for a path that cannot exist is a fossil, and the banner already carries the engine's supersession history.

Impact: no behavior. `git grep prose-rag-rs` now finds only this spec and this note.

Open questions: none.
