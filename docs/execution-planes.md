# Execution planes

The kit runs agents four different ways. Two of them live in the same directory and share
no code, which is the single most confusing thing in the layout. This doc is the map.

`docs/architecture.md` owns each component's internals. This doc owns the comparison: what
each plane is for, how they hand off, where they deliberately do not connect, and which one
to reach for.

## The four planes

```
                        ┌──────────────────────────────────────────┐
                        │  BOARD          rows, states, admission  │
                        │  lib/board/     runs no agent at all     │
                        └───────────────┬──────────────────────────┘
                                        │ a row carries #queue{repo=,pointer=}
                        ┌───────────────┴──────────────┐
                        ▼                              ▼
        ┌───────────────────────────┐   ┌──────────────────────────────┐
        │ ORCHESTRATOR              │   │ QUEUE                        │
        │ lib/queue/orchestrate.sh  │   │ lib/queue/queue.sh           │
        │                           │   │                              │
        │ headless `claude -p`      │   │ REAL interactive `claude`,   │
        │ one fresh session per     │   │ driven by typing into a      │
        │ sub-goal, waves of them   │   │ tmux window, one row at a    │
        │ running concurrently      │   │ time                         │
        └───────────────────────────┘   └──────────────────────────────┘
                        │                              │
                        └──────────────┬───────────────┘
                                       ▼
                        ┌──────────────────────────────┐
                        │ a branch, a PR, a journal row│
                        └──────────────────────────────┘

        ┌──────────────────────────────────────────────────────────┐
        │ GAUNTLET      tests/gauntlet/cleanroom/                   │
        │                                                           │
        │ a DISPOSABLE probe in a fresh Docker container each round.│
        │ Connects to none of the above. It measures an ARTIFACT,   │
        │ it does not execute work.                                 │
        └──────────────────────────────────────────────────────────┘
```

`lib/queue/orchestrate.sh` and `lib/queue/queue.sh` sit in one directory and are separate
engines. `queue.sh` never calls `orchestrate.sh`; its only mention of that file is a comment.
A queue-launched session may invoke the orchestrator as one of its own tool calls, which is
the whole relationship.

## Side by side

| | board | orchestrator | queue | gauntlet |
|---|---|---|---|---|
| Unit of work | a table row | a ROADMAP sub-goal | a tsv row | a probe card |
| Runs an agent | no | `claude -p`, headless | `claude`, interactive | a probe in a container |
| Concurrency | n/a | a wave, `WAVE_CAP` (2) | one row at a time | one probe per round |
| Auth | n/a | the host's session | the operator's live login | a spend-capped API key |
| Isolation | n/a | none, the real checkout | none, the real checkout | a fresh container per round |
| Mutates | the row | the code | the code | the artifact under test |
| Ends when | a human sets a state | every box is checked | the journal has a verdict | a probe passes unaided twice |

## What each is for

**Board.** The ledger and the admission gate. States run `queued → claimed → speccing →
validated → executing → shipped`, plus `parked` and `dropped`. It runs nothing. A row becomes
executable only when it carries a `#queue{repo=<name>,pointer=<path>}` token, and
`lib/board/parse-board.sh` is the sole authority that validates it: charset, repo
self-consistency, and path containment under `_meta/megagoals/*` or `.claude/goals/*`.

**Orchestrator.** Drives a mega-goal's sub-goals to completion. It picks the ready set,
injects the pointer prompt plus a capped `HANDOFF.md`, spawns a fresh headless session per
sub-goal, and waits. It never flips a checkbox itself: completion is grounded on the session
writing its own box, or for a `gate` sub-goal on a real PR existing. A wave admits sub-goals
greedily in roadmap order, but only where each declares its own `## Touches` and proves
disjoint against every already-admitted member.

**Queue.** Runs one prepared pointer at a time, overnight. It opens a tmux window, launches a
real interactive session, and types `/goal <pointer body>` into it. The header states why this
beats a headless worker: a headless token can expire or be killed independently, and the run
dies with it. Driving the operator's live session sidesteps that class, at the cost of running
under the operator's own authority.

**Gauntlet.** Not an executor. It converges an artifact, usually docs, until a fresh probe
agent can complete a fixed task using only that artifact. See the duality below.

## The gauntlet is the dual of `/goal`

```
  /goal and the executors               the gauntlet
  ──────────────────────────            ──────────────────────────
  ONE agent, persistent                 MANY probes, one per round
  context ACCUMULATES                   context FRESH, torn down
  mutates the WORK                      mutates the ARTIFACT
  the verifier stays fixed              the outcome contract stays fixed
```

The fresh room is the whole point. A persistent agent learns to compensate for a bad artifact,
which hides exactly the defect the gauntlet hunts. Three consequences follow, and each looks
like a mistake until the goal is clear:

- **The probe runs on a mid-tier model on purpose.** A stronger model succeeds despite a bad
  artifact and destroys the signal.
- **A pass must replicate.** The final green round repeats once, so two consecutive unaided
  passes are required.
- **An unanswerable probe question is a finding, not a support request.** The probe is never
  coached.

## How work flows

```
  an idea
     │  /kit:mega  or  /kit:assign          (a human runs one)
     ▼
  a goal pointer file           .claude/goals/<slug>.md  or  _meta/megagoals/*
     │                          context, task, scope fence, self-verification,
     │                          worktree discipline, done-means
     ├──────────────────────────────┐
     │ board row + #queue{} + #auto │      (a human tags the row)
     ▼                              ▼
  orchestrate.sh run <dir>      watch-board.sh --apply   →   queue.sh run
     │                                                          │
     └──────────────────┬───────────────────────────────────────┘
                        ▼
                  branch → PR (draft by default) → journal row
```

Every link marked with a human is a human. Nothing walks this path end to end on its own, and
the pointer file is the join: both executors need one, and only `/kit:assign` and `/kit:mega`
produce one. A staged candidate row is prose, so it is not runnable until it has been through
that step.

## What they share

Almost nothing, and the exceptions are worth knowing.

| Shared | Between | What it is |
|---|---|---|
| `lib/gate/gate-ledger.sh` | every plane | the telemetry rail; phases bracket their runs on it |
| `lib/queue/pane-tail.jq` | queue, gauntlet | a display filter for streamed transcripts, used by the gauntlet's local watch path |

That is the full list. The gauntlet shares no orchestration logic, no state, and nothing at all
with the board. The planes are independent engines on one shared ledger.

## Trust and isolation

This is where the planes differ most, and the difference is not documented anywhere else.

**The two executors run unsandboxed on the operator's machine**, in the real checkout, with
`--dangerously-skip-permissions`. That is a deliberate tradeoff, not an oversight: the queue's
own spec centres on avoiding a headless auth failure, and never discusses confinement.

Because nothing can intercept those writes, the compensating controls are **detection, not
prevention**. `QUEUE_PROTECTED_GLOBS` names paths an unattended run must not write
(`.claude/*`, `CLAUDE.md`, `AGENTS.md`, `.github/*`, `_meta/BACKLOG.md`). A write there does not
fail. It ends the row `gated` so a human sees it.

**The gauntlet is the opposite.** A fresh container per round, a tarball of committed state,
tool binaries baked into the image but never config or keys, and the probe key passed at run
time. On a remote runner the key is resolved by that host from a 1Password reference; it never
travels over ssh and never lands in shell history.

Untrusted input is fenced where it enters. A hand-authored tsv is exempt by design, because
operator authorship IS the trust boundary. A row from a board is not: `--from-boards` implies
`--sanitize-prompt`, which runs the free-text cell through an ordered pipeline (entity decode,
strip invisible codepoints, strip ANSI, delete HTML comments, strip code fences, neutralize
non-https URLs, size cap) and wraps it in explicit untrusted-text fences. It fails closed.

## Which one to reach for

| You want to | Use |
|---|---|
| track work and decide what is next | the board |
| drive a multi-step plan whose steps depend on each other | `/kit:mega`, then the orchestrator |
| run prepared, independent work unattended overnight | the queue |
| find out whether your docs actually work for a stranger | the gauntlet |
| execute one thing right now, watching it | `/goal` in your own session |

## Bounds, at a glance

Every plane fails closed. The knobs below are the ones worth knowing before starting a run;
`lib/config/module-registry.md` carries the full set with defaults.

| Plane | Stops on |
|---|---|
| orchestrator | `WAVE_CAP`, a non-disjoint `## Touches`, a `gate!` sub-goal halting the loop, a failing gate ledger refusing the merge |
| queue | `QUEUE_TIMEOUT_SECS` per row, two consecutive failures ending the night, stall quarantine, breaker cooldown, a tool-call ceiling |
| gauntlet | a hard round cap, a spend-capped key, an honest halt when severity stops falling |
