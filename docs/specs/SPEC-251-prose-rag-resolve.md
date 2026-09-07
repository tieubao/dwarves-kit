# Spec: prose-rag resolve, one resolver that skips the kit's own wrapper
Generated: 2026-09-08
Status: APPROVED
Lane: normal
References: `bin/prose-rag` (SPEC-250 adapter; keep its exit contract and the `PROSE_RAG_SHIM_ACTIVE` guard); `lib/config/config.sh` `_seam_resolve` binary branch (the second reader of the same order); `install.sh` `kit_write_cli_shim` (writes `~/.local/bin/prose-rag` with the marker line `# dwarves-kit CLI shim`, the wrapper both readers must skip).

## Problem

`install.sh` puts a wrapper named `prose-rag` on PATH that execs `bin/prose-rag`. On a machine without context-kit's binary, `command -v prose-rag` finds that wrapper: the shim execs it, the recursion guard stops the loop, and the operator gets the install hint (correct), but `bin/config seams` reports `PROSE_RAG_BIN binary <wrapper path> filled` (wrong: nothing can serve recall). When the real binary sits later on PATH than the wrapper, the shim never reaches it. Found on the operator's own machine after SPEC-250 shipped.

## Solution

### Approaches considered

1. **One resolver in `lib/prose-rag/resolve.sh`, sourced by both readers.** `prose_rag_resolve` prints the first real engine: `$PROSE_RAG_BIN` when it is a regular executable file; else the first `prose-rag` on PATH that is a regular executable file and not a kit wrapper (its first 200 bytes contain `dwarves-kit CLI shim`) and not this shim itself (realpath equal to `bin/prose-rag`). Tradeoff: a second file to source; the two readers stop drifting.
2. **Rename the installer wrapper** (drop `prose-rag` from `KIT_CLI_NAMES`). Tradeoff: breaks `prose-rag` on PATH for operators who rely on the kit wrapper today, and the seams check still needs a skip rule for stale wrappers.
3. **Duplicate the loop in both files.** Tradeoff: the drift class SPEC-249 DEC-007 forbids.

### Chosen approach + why

Approach 1. The resolution order is one contract with two readers; it belongs in one function.

### Extensibility & boundaries

A future engine name is one more candidate in the resolver. Unit: `lib/prose-rag/resolve.sh` (pure resolution, no exec), testable with stubs on a temp PATH.

## Picture

```
 $PROSE_RAG_BIN ── regular executable? ──▶ that
      else walk PATH for `prose-rag`:
        skip: not a regular executable file
        skip: first 200 bytes contain "dwarves-kit CLI shim"   (install.sh wrapper)
        skip: realpath == this kit's bin/prose-rag              (the shim itself)
        take: the first survivor
      none ──▶ print nothing, return 1

 bin/prose-rag ──source──▶ prose_rag_resolve ──▶ exec or the no-engine contract
 config.sh _seam_resolve (binary) ──source──▶ prose_rag_resolve ──▶ filled <path> | absent
```

## Design

obvious: extract the lookup both readers already do into one sourced function and add two skip rules.

## Technical Design

### Interfaces (I/O contract)

`lib/prose-rag/resolve.sh` defines `prose_rag_resolve [name]` (default name `prose-rag`): prints one absolute path and returns 0, or prints nothing and returns 1. Reads only `PROSE_RAG_BIN` and `PATH`. Never executes a candidate. Idempotent source guard like `lib/ledger/ledger.sh`. `bin/prose-rag` sources it (relative to its own location) and execs the result, keeping the `PROSE_RAG_SHIM_ACTIVE` guard as a second line of defence. `config.sh` binary branch: with `PROSE_RAG_BIN` set, unchanged (`filled` when a regular executable, else `unresolved`); with it unset, `prose_rag_resolve` → `filled <path>` or `absent` with `(not on PATH)`.

## Task Breakdown

### Phase 1: Foundation

- [x] TASK-001: DONE (commit: d22d5b1, verified). the resolver, both readers, and tests. Add `lib/prose-rag/resolve.sh`; `bin/prose-rag` and `lib/config/config.sh` source it; `tests/test-prose-rag-adapter.sh` gains: the kit wrapper alone on a temp PATH → the install hint, exit 1, no loop (under `ulimit -t 10`); the wrapper FIRST and a real stub SECOND on PATH → the stub runs; a symlink named `prose-rag` to this shim on PATH → skipped. `tests/test-config-seams.sh` gains: wrapper alone on PATH → `absent`; wrapper then real stub → `filled` with the stub's path; `PROSE_RAG_BIN` still wins. `tests/test-config-registry.sh` stays green (no new env names). Acceptance: `bash tests/test-prose-rag-adapter.sh && bash tests/test-config-seams.sh && bash tests/test-config-registry.sh && bash tests/test-kit-contract.sh && bash tests/test-meta.sh && bash tests/test-no-personal-paths.sh` green; `docs/FEATURES.md` regenerated if the registry changes; `lib/prose-rag/README.md` names the resolver.

## After state

- [x] With only the kit wrapper on PATH, `bash bin/config seams` shows `PROSE_RAG_BIN ... absent`. (Today: `filled` with the wrapper path.)
- [x] With the wrapper before the real binary on PATH, `bash bin/prose-rag query x` runs the real binary. (Today: the hint.)
- [x] `grep -c 'command -v prose-rag' bin/prose-rag lib/config/config.sh` is 0 (both source the resolver).

## Acceptance Criteria (global)

- [x] All tasks pass their acceptance criteria
- [x] No regressions in the Verification line

## Verification

```
bash tests/test-prose-rag-adapter.sh && bash tests/test-config-seams.sh && bash tests/test-config-registry.sh && bash tests/test-kit-contract.sh && bash tests/test-meta.sh && bash tests/test-no-personal-paths.sh
```

## Edge Cases

1. A Mach-O or ELF binary named `prose-rag`: the 200-byte marker check reads binary bytes safely (`head -c 200 | grep -a -q`), no false skip.
2. `PROSE_RAG_BIN` set to the kit wrapper explicitly: honoured as today (the operator asked for it); the shim's guard still prevents a loop.
3. A PATH entry that does not exist or is unreadable: skipped silently.
4. PATH with an empty entry (`a::b`): the empty entry is skipped, never treated as cwd.
5. Name with spaces in a PATH dir: quoted throughout.

## Out of Scope

- Renaming or removing the installer wrapper.
- Any change to `hooks/prose-rag.sh`.

## Decision Log

- DEC-001: skip by marker line plus realpath, not by path prefix (`~/.local/bin`), because an operator may install the real binary there too.

## Open questions

(none)
