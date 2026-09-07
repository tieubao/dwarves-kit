# Proof of done: prose-rag floor calibration, north-star alignment wiring, brief-on-file check

**Change class:** behavioral (`lib/prose-rag/rust/src/main.rs`); advisory/prompt-wiring
(`commands/think.md`, `commands/spec-validate.md`, `commands/absorb.md`, `commands/assign.md`).

Superseded on the prose-rag half by the adapter (SPEC-250): the crate under
`lib/prose-rag/rust` is retired and the engine lives in context-kit.

**Claim:** three independent, small fixes:

1. `prose-rag query`'s relevance floor is overridable via `--floor` (already existed) or the
   new `PROSE_RAG_FLOOR` env var, 0.32 default unchanged; usage text now says table-shaped
   notes may need a lower value.
2. The PHILOSOPHY.md §6 north-star alignment question is wired into `/kit:think`'s forcing
   set, `/kit:spec-validate`'s Reviewer 5, and `/kit:absorb`'s scoring + proposal step, all
   advisory only.
3. `/kit:assign` checks for an existing `docs/briefs/DECISION-BRIEF.md` (or slug-matched
   variant) before drafting a goal and offers to reuse it; decline is a no-op.

## Acceptance criteria

| # | Criterion | Result |
|---|---|---|
| 1 | `PROSE_RAG_FLOOR` env overrides the query floor default; `--floor` still wins over the env | PASS |
| 2 | Default floor unchanged at 0.32 when neither is set | PASS |
| 3 | Usage text names the env var + the table-shaped-notes calibration concern | PASS |
| 4 | `commands/think.md` forcing set carries the north-star alignment question | PASS |
| 5 | `commands/spec-validate.md` Reviewer 5 carries the alignment question, advisory | PASS |
| 6 | `commands/absorb.md` checks §6 before the verdict, advisory (never rejects/auto-absorbs) | PASS |
| 7 | `commands/assign.md` checks for an existing DECISION-BRIEF before drafting the goal | PASS |
| 8 | Full `tests/test-meta.sh` suite: no NEW failures vs the pre-change baseline | PASS |

## Confirmation run

| Check | Command | Exit | Verdict |
|---|---|---|---|
| Rust build | `cargo build --release` (in `lib/prose-rag/rust`) | 0 | PASS |
| Rust unit tests | `cargo test --release` | 0 | PASS (10/10) |
| Full meta suite, before this branch | `bash tests/test-meta.sh` | 0 | 808/815 (7 pre-existing registry-drift failures, known baseline) |
| Full meta suite, after this branch | `bash tests/test-meta.sh` | 0 | 808/815 (same 7 pre-existing failures, no new ones) |

## Run detail

```
running 10 tests
test tests::chunker_matches_python_shape ... ok
test tests::fnv_stable ... ok
test tests::chunker_boundary_and_remainder ... ok
test tests::chunker_windows_long_sections ... ok
test tests::recall_gate ... ok
test tests::long_section_windows_instead_of_truncating ... ok
test tests::search_ranks_by_dot ... ok
test tests::embedder_decode_rows_f32_and_f16 ... ok
test tests::index_roundtrip_and_corruption ... ok
test tests::gather_files_source_naming_parity ... ok

test result: ok. 10 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out
```

Mechanical wiring checks (grep for the new markers, this branch vs `origin/master`):

```
$ grep -c "north-star" commands/think.md               -> 1  (baseline: 0)
$ grep -c "Alignment (advisory)" commands/spec-validate.md -> 1  (baseline: 0)
$ grep -c "north-star criteria" commands/absorb.md      -> 1  (baseline: 0)
$ grep -c "Brief-on-file check" commands/assign.md      -> 1  (baseline: 0)
```

## NEGATIVE CONTROL

1. **prose-rag floor (runtime).** Swapped `src/main.rs` back to the `origin/master` version,
   rebuilt, and ran `prose-rag query` (no args, triggers usage): the old binary's usage text
   has no mention of `PROSE_RAG_FLOOR` (3 lines only, exit 2). Restored the new `src/main.rs`,
   rebuilt, reran the same command: usage now carries the 4th line naming the env var and the
   calibration concern (exit 2, same trigger path, different output -- confirms the change is
   load-bearing on the binary, not just the source).
2. **Command wiring (mechanical).** `git show origin/master:<file> | grep -c <marker>` returns
   0 for all four markers above; the working tree returns 1 for each -- confirms each wiring
   point is new, not pre-existing text the grep would have matched anyway.

**Verdict: PASS.**
