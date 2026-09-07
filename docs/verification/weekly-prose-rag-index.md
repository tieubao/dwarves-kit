# Proof of done: weekly prose-rag index (kit-weekly job + corpus-config guard)

Branch: `feat/weekly-prose-rag-index`. Stateful change: a new `jobs.txt` job, a
consumer-env source in the `kit-weekly` dispatcher, and an unconfigured-corpus
guard in the engine + `bin/prose-rag` wrapper.

Superseded by the adapter (SPEC-250): the vendored crate and its build line are gone,
and the engine binary now comes from context-kit.

## Acceptance criteria

1. `prose-rag index` with no `PROSE_RAG_CORPUS` and no `--corpus` skips clean:
   exit 0, message, index db byte-identical (never clobbered to empty).
2. Configured-but-empty corpus stays a real error (exit 1).
3. `kit-weekly` sources `~/.config/kit-weekly/env` when present; the shipped
   `prose-rag-index` jobs line is silent-green for unconfigured consumers and
   indexes for configured ones.

## Confirmation runs

### Engine suites (green run)

```
Command: cd lib/prose-rag/rust && cargo build --release && bash tests/smoke.sh
Exit: 0
ok 14 - unconfigured corpus skips clean (exit 0, db untouched)
ok 15 - configured-but-empty corpus errors (exit 1)
smoke: all 15 passed

Command: cargo test --release
Exit: 0
test result: ok. 10 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out
```

Check 14 is the negative control for the clobber risk: it `cmp`s the db before
and after the unconfigured run (byte-identical required). Check 15 is the
negative control for over-silencing: a configured-but-empty corpus must still
fail loudly.

### Dispatcher end-to-end (isolated `$HOME`, jobs file with only the new line)

```
Command: HOME="$T" KIT_WEEKLY_JOBS="$T/jobs.txt" deploy/macos/kit-weekly   # no consumer env
Exit: 0
prose-rag: no corpus configured (set PROSE_RAG_CORPUS or pass --corpus); nothing indexed
kit-weekly: 'prose-rag-index' ok
kit-weekly: done (ran=1 skipped=0 failed=0)

Command: HOME="$T" KIT_WEEKLY_JOBS="$T/jobs.txt" deploy/macos/kit-weekly   # $T/.config/kit-weekly/env sets PROSE_RAG_CORPUS + PROSE_RAG_DB
Exit: 0
prose-rag: embedding 1 chunks from 1 changed files (0 removed, 1 total files)...
prose-rag: indexed 1 chunks (1 files) -> $T/index.bin
kit-weekly: 'prose-rag-index' ok
kit-weekly: done (ran=1 skipped=0 failed=0)
```

## Reproduce

```
cd lib/prose-rag/rust && cargo build --release && bash tests/smoke.sh && cargo test --release
T=$(mktemp -d); printf 'prose-rag-index bin/prose-rag index\n' > "$T/jobs.txt"
HOME="$T" KIT_WEEKLY_JOBS="$T/jobs.txt" deploy/macos/kit-weekly
```

## Rollback

Revert the commit (single commit on the branch). Runtime rollback without a
revert: delete the `prose-rag-index` line from `deploy/macos/jobs.txt` (the
dispatcher takes effect next weekly run; no daemon reload needed, the plist is
untouched). The consumer file `~/.config/kit-weekly/env` is machine-side and
inert once the jobs line is gone.
