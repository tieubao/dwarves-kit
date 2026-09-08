# Verification log: spec IDs in printed strings

Branch `fix/ids-in-printed-strings`, base 25177ab.

The house rule bans scattered spec and ticket tags in comments and prose. The worst instance
is a tag inside a string the code PRINTS: it reaches a human at a terminal who cannot open the
spec, and two of them fired on every push.

## Scope, and how it was bounded

Three read-only agents swept the repo. The printed-string subset was the one they were asked
to enumerate individually rather than classify, because it is small enough to fix completely
and highest value per edit. Twenty-two strings, across `hooks/`, `lib/gate/`, `lib/telemetry/`,
`lib/board/`, `lib/adopt.sh`, `lib/explain.sh`, `lib/queue/orchestrate.sh` and
`lib/skill-curator/`.

## Green run (90d28af)

Command: `bash tests/test-meta.sh && bash tests/test-hooks.sh && bash tests/test-docs-wiring.sh && bash tests/test-command-emit-sweep.sh && bash tests/test-wrap.sh && bash tests/test-lane-telemetry.sh && bash tests/test-board.sh && bash tests/test-adopt.sh && bash tests/test-explain.sh`
Exit: 0 for each suite
Output (excerpt): `All meta tests passed.`; `All tests passed.` (hooks); docs-wiring `25/25 passed`;
`All command-emit-sweep tests passed.`; `test-wrap: all 236 passed`; lane-telemetry, board,
adopt and explain each exit 0
Verdict: PASS

Every touched shell file parses (`bash -n`). A grep for an ID inside an `echo` or `printf` in
`hooks/` and `lib/` returns only test-progress echoes and the live `SPEC-%s` payload named below.

## What was deliberately NOT changed

- `lib/queue/orchestrate.sh` `printf 'This wave dispatch reserved SPEC-%s ...'`: the
  substitution is the actual reserved number the worker must act on. Live payload, not a
  citation. Only its decorative label line lost a tag.
- `lib/bench/tool.toml` and `lib/webcheck/tool.toml` `board = ["ID-420", ...]`: literal
  backlog-row keys the code reads to render a board section.
- `docs/verification/explain-command/sample-explainer.md`: the explain test regenerates this
  file against whatever sha is checked out. It is a dated record of a past run, so the
  regeneration was reverted rather than committed.

## The source, not just the symptom

`commands/next.md` instructed the model to append a `TASK-[ID]: no deviations` line to every
implementation-notes file it wrote, manufacturing the banned tag shape on every run. It now
asks for a plain `No deviations; matches the spec verbatim` line. Removing the emitter is what
stops this class regrowing.

## NEGATIVE CONTROL

Not applicable in the usual mutate-and-go-red form: no test asserts on these strings, which is
precisely why the tags survived this long. The check that has teeth is the grep recorded above,
and the honest statement is that a future edit could reintroduce a tag without any suite
noticing. A lint over printed strings would close that, and is not built here.

## Remaining, not done in this pass

The sweep found roughly 2,650 strip-class hits overall. This branch fixes 22 plus the emitter.
The rest is scoped in the session report: ~495 in living docs, ~578 in the prompt layer, ~925
non-string code comments, ~637 test comments.
