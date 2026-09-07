# Implementation notes: SPEC-251 prose-rag resolve

## 2026-09-08 00:30 Two deltas from the spec

Context: the spec puts the resolver in `lib/prose-rag/resolve.sh` and has `bin/prose-rag`
source it relative to its own location.

Decision 1: `bin/prose-rag` tests the resolver with `[ -r ]` before sourcing it, and defines
a `prose_rag_resolve` that returns 1 when the file is absent.

Why: Apple's `/bin/bash` (3.2) EXITS the whole shell when `source` cannot find the file,
inside `if !` or not. The suite already copies the shim to a temp dir and asserts the install
hint plus exit 1 there; that copy has no `lib/` beside it, so an unguarded source killed the
shim before it printed anything. `hook` must also stay silent, which rules out letting bash
print its own "No such file" line.

Alternatives: source unguarded and drop the copied-shim case (loses a real contract); ship
the resolver inline in both readers (the drift class the spec forbids).

Impact: `lib/config/config.sh` uses the same order for the same reason. A copy of the shim
taken out of a kit checkout now degrades to the documented no-engine exits.

Decision 2: `tests/test-prose-rag-adapter.sh`'s "no reference to `lib/prose-rag`" assertion
now excludes `lib/prose-rag/resolve.sh` and gained a `command -v prose-rag` count of 0.

Why: the spec requires the shim to source the resolver from `lib/`, which contradicts the
literal old assertion. The intent behind it was "never reaches for the ENGINE under lib, never
builds"; the narrowed grep plus the `cargo build` check preserve exactly that.

Open questions: none.
