#!/usr/bin/env bash
# orchestrate.sh -- drive a mega-goal as ONE fresh `claude -p` session per sub-goal, so the
# loop lives in this dumb (non-LLM) driver and no session accumulates more than one sub-goal's
# context (SPEC-087, ADR-0027). Each `claude -p` is a new session, so the `/clear` between
# sub-goals is free; the kit never self-`/clear`s. Each sub-goal session writes HANDOFF.md for
# the next, and the orchestrator injects it (re-discovery becomes a read). The driver MUST stay
# non-LLM: an LLM orchestrator spawning a subagent per sub-goal would re-accumulate every return
# and become the new marathon (DEC-004).
#
# Usage:
#   orchestrate.sh next <megagoal-dir>             print the next unchecked sub-goal + policy
#   orchestrate.sh run  <megagoal-dir> [--dry-run] [--step] [--stream]
#       --dry-run  print the plan only (no claude)
#       --step     pause for the operator after each sub-goal (resume on Enter, q to stop)
#       --stream   stream each session live (stream-json) + capture to .orchestrate/<id>.stream.jsonl
#       --capture-tokens  stream each session SILENTLY to .orchestrate/<id>.stream.jsonl for token
#                  usage extraction (SPEC-117); the conductor stays lean (no tee). Also CAPTURE_TOKENS=1.
#       --board=roadmap|kanban|both  surface progress as a per-mega-goal kanban (SG-10); default
#                  detects (backlog.sh present -> both, else roadmap). Event-sourced + derived;
#                  ROADMAP.md stays canonical, the repo-wide BACKLOG cockpit is never touched.
#   --step/--stream are opt-in; default behavior is unchanged (SG-01, SPEC-087 Mechanism A).
#   Env (SG-11 robustness, advisory): WATCHDOG_STALL_SECS>0 backgrounds each session + flags it
#   `stalled` after that many seconds with no output (WATCHDOG_POLL_SECS poll interval); never
#   kills. Default 0 = off (synchronous path unchanged). A dead/incomplete session never advances
#   its box (`[guardrail]` halt); a sub-goal with no goals/ file warns before launch.
#
# <megagoal-dir> holds: ROADMAP.md (sub-goal lines `- [ ] SG-NN ... , auto|gate , ...`),
# POINTER_PROMPT.md (static resume prompt), HANDOFF.md (feed-forward, written by each sub-goal).
# Grounded completion: a sub-goal session MUST flip its ROADMAP checkbox to [x]; the
# orchestrator advances only then (no self-claim). When the local box is unchecked it reconciles
# against `origin/<default>` first, so a box flipped inside a now-merged PR still counts (a remote
# box counts only when its line also carries a real `PR #<n>`).
#
# Gate sub-goals (env MEGA_GATE_DISPATCH=1 default): a `gate` / `gate!` sub-goal is DISPATCHED like
# an `auto` one, its prompt carries the held-PR contract (open the PR as a DRAFT, `mega-merge.sh
# mark` it, never merge it, never flip the box), and the loop HOLDS afterwards for the human merge,
# grounded on the PR existing. MEGA_GATE_DISPATCH=0 restores the old stop-before-running behavior.
#
# TIER-4 mega-close (SPEC-118/ID-093, env TIER4_CLOSE=1 default): when EVERY box is checked, the run
# does a real mega-level close over the ASSEMBLED WAVE -- a mechanical no-orphan sweep (a dispatchable
# agent defined-but-never-dispatched is BLOCKING, the c6fbd99 class) + THREE independent fresh-context
# verifier sessions (integration-verifier / review-team incl. security / advisor both modes, one
# process each) whose verdicts are fail-closed AGGREGATED (any single dissent blocks the close) --
# THEN it HOLDS the final human gate (never auto-merges past it). TIER4_CLOSE=0 restores the bare
# "done"-and-return; TIER4_CORPUS overrides the no-orphan sweep root (default: the megadir's git
# repo root).
#
# Multiplexer panes (SPEC-119, env MULTIPLEXER=0 default -- OPT-IN, ADR-0032 s4): when a wave
# actually admits >=1 sub-goal concurrently (WAVE_CAP>1 + disjoint `## Touches`), MULTIPLEXER=1
# spawns each wave session into its own tmux window (`tmux new-window`) instead of a plain
# background job, so an operator can `tmux capture-pane` its live output or `tmux send-keys` into
# it (watch + intervene across tabs). Off by default: `_wave_run`'s spawn/reap take the exact
# pre-existing kill-0/wait path and $TMUX_CMD is never invoked. TMUX_CMD mirrors CLAUDE_CMD's mock
# seam; TMUX_SESSION overrides the derived per-megagoal tmux session name.
#
# Pane viewer push (SPEC-121, env PANE_VIEWER=auto default): the push half of the multiplexer --
# on wave spawn, ONE viewer tab/surface (cmux/kitty/wezterm/ghostty/iterm/terminal, auto-detected)
# opens in the operator's terminal app already attached to the wave's tmux session. `none` = the
# pull behavior above exactly; headless (no TTY / nothing detected) degrades silently to pull.
# See the PANE_VIEWER env block below.
#
# Subagent panes (SPEC-234, `orchestrate.sh panes <megadir> <target>...`): the DEFAULT mega-goal
# run mode dispatches sub-goals as background SUBAGENTS via the conductor's own Agent tool
# (commands/mega.md "Run mode"), a path this driver never sees, so there is no dispatch loop to
# hook. `panes` is a one-shot subcommand the conductor shells out to after dispatching: for each
# resolved subagent transcript (a jsonl path, a directory of them, or `--latest` to derive the
# conductor's own subagents dir) it grows a READ-ONLY tmux window that tails the transcript
# through a small jq formatter (`$PANE_TAIL_JQ`). Read-only by construction (`tail | jq`, no
# shell in the pane) -- steering a subagent still routes through the conductor (SendMessage),
# never the pane. Always rc 0; skips warn on stderr and land in a `[panes] spawned N, skipped M`
# summary.
#
# The `claude` invocation is `$CLAUDE_CMD` (default: claude), so tests mock it and operators
# tune the permission flags.
set -uo pipefail

CLAUDE_CMD="${CLAUDE_CMD:-claude}"
# Permission posture for the unattended sub-goal session (SPEC-087 "Session invocation"). Default
# is full access so the session can edit/commit/push/open-PR without a permission wall stalling
# the loop; override with a tighter `--allowedTools` allowlist or an agentkernel sandbox via
# CLAUDE_CMD. Word-split intentionally (operator config, not user data). Tests set CLAUDE_FLAGS=""
# so the mock's prompt stays the last arg.
CLAUDE_FLAGS="${CLAUDE_FLAGS:---dangerously-skip-permissions}"

# Hot-handoff size cap (SPEC-087 Mechanism B, two-tier). The HOT HANDOFF.md is injected in full,
# so it must stay small or it recreates the marathon. Over the cap -> inject head + a notice and
# point at the file. The WARM DECISIONS.md ledger is never injected in full (pointer only).
HANDOFF_MAX_LINES="${HANDOFF_MAX_LINES:-80}"

# Deterministic handoff (token-optim-v3 SG-02). Off (0) by default -> the per-session invocation
# stays byte-identical and the LLM session writes its own HANDOFF.md/DECISIONS.md (unchanged). On
# (1) -> the session is captured to stream-json and, after grounded completion, the two-tier
# handoff is REGENERATED deterministically from that transcript by lib/goal/handoff-gen (SPEC-087 Mech
# B fields preserved; no LLM in the handoff path). Always-produced + reproducible beats
# occasionally-excellent-but-skippable.
DETERMINISTIC_HANDOFF="${DETERMINISTIC_HANDOFF:-0}"

# Lean token capture under delegation (SPEC-117, executes ADR-0032 section 3). Off (0) by default.
# On (1, via CAPTURE_TOKENS=1 or the --capture-tokens flag) -> the delegated child streams to a FILE
# (`claude -p --stream > .orchestrate/<id>.stream.jsonl`) purely so the post-session token hook can
# extract usage; the conductor reads only the box-flip, NEVER the child transcript. It is a THIRD,
# DECOUPLED trigger for the SAME silent `> "$slog"` stream-to-file branch that DETERMINISTIC_HANDOFF
# uses -- NOT `--stream` (that tees the transcript to the conductor = the ADR-0032 section 1 forbidden
# bloat path) and NOT coupled to handoff regeneration. Read as a GLOBAL (like DETERMINISTIC_HANDOFF,
# not a positional arg) so it inherits into the wave subshell on fork with no `_run_one_session`
# signature change and no `_wave_run` call-site touch. The serial token hook is already `$slog`-gated,
# so this needs no hook change; the wave-path per-sub-goal ledger extraction (ID-094) recomputes the
# same deterministic stream path in the reap loop, since `_run_one_session`'s `_ROS_SLOG` global does
# not cross the wave's forked-subshell boundary back to the caller.
CAPTURE_TOKENS="${CAPTURE_TOKENS:-0}"

# Kanban renderer reused by the board-view (SG-10). Resolved next to this script; override in
# tests. When absent, board mode fail-safes to roadmap-only so a kit without the tooling runs.
ORCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_ROOT="$(cd "$ORCH_DIR/.." && pwd)"  # the lib/ dir; cross-subsystem siblings resolve as "$LIB_ROOT/<subsystem>/<file>"
BACKLOG_LIB="${BACKLOG_LIB:-$LIB_ROOT/board/backlog.sh}"

# Multi-vendor dispatch adapter (ID-390): vendor -> headless argv + prompt-delivery mode.
# SOURCED, unlike dispatch-gate.sh which must be a subprocess because its `set -euo` would leak `-e`
# into this driver's deliberate `set -uo` posture. harness.sh is `set -uo` too, so it composes
# cleanly and the functions stay callable without a fork per dispatch.
# shellcheck source=./harness.sh
. "$ORCH_DIR/harness.sh"

# Config layer (SPEC-187 / SG-03, executes ADR-0032 section 6): `[mega]` keys resolve
# project .kit.toml > kit-root kit.toml > the hardcoded default baked into each `${VAR:-...}`
# below, and the ENV VAR always wins over all three (an operator's `WAVE_CAP=5` in the
# shell overrides even a project config). Sourced once, here, so every `${X:-$(kit_config_get
# ...)}` below can call `kit_config_get` unconditionally; the guard in kit-config.sh makes a
# double-source a no-op (idempotent), so a caller that already sourced it (e.g. a wrapper
# script) pays no cost.
CONFIG_LIB="${CONFIG_LIB:-$LIB_ROOT/config/kit-config.sh}"
# shellcheck source=lib/config/kit-config.sh
[ -f "$CONFIG_LIB" ] && . "$CONFIG_LIB"

# _kit_bool01 <val> <default01> -- normalize a TOML `true`/`false` (or already-0/1) config
# value to the `0`/`1` shape orchestrate.sh's env-var knobs use; anything else (unset, typo)
# falls back to the caller's default01. Kept tiny and local to this file since kit-config.sh
# itself is TOML-value-shape-agnostic (it just returns the raw string).
_kit_bool01() {
  case "$1" in
    true|1) printf '1' ;;
    false|0) printf '0' ;;
    *) printf '%s' "$2" ;;
  esac
}

# Loop robustness (SG-11, advisory). WATCHDOG_STALL_SECS=0 (default) keeps the synchronous run
# path UNCHANGED. >0 backgrounds each session and polls every WATCHDOG_POLL_SECS: if the session
# emits no output for WATCHDOG_STALL_SECS while its process is still alive, it is flagged
# `stalled` (event + warn) -- never killed (flag, don't kill). Liveness is a `kill -0` probe (no
# daemon, per the pi-swarm thesis).
WATCHDOG_STALL_SECS="${WATCHDOG_STALL_SECS:-0}"
WATCHDOG_POLL_SECS="${WATCHDOG_POLL_SECS:-30}"

# Flip-lock stale-reclaim threshold (SPEC-106 TASK-002 / DEC-009). The box-flip mutual-exclusion
# primitive is a `mkdir` lock (atomic on POSIX; flock is absent on macOS and unused in this repo).
# A lock whose recorded holder PID is DEAD (crashed) is reclaimed immediately; a lock with no
# readable PID (a racy just-created lock) is reclaimed only after this many seconds. Default 120.
# FLIP_LOCK_POLL_SECS is the short retry sleep while the lock is held by a live holder.
FLIP_LOCK_STALE_SECS="${FLIP_LOCK_STALE_SECS:-120}"
FLIP_LOCK_POLL_SECS="${FLIP_LOCK_POLL_SECS:-0.1}"

# Wavefront concurrency cap (SPEC-106 DEC-002/009; default flipped to 2 in the ID-090 activation).
# Default 2 = waves ON: dep-independent sub-goals that BOTH declare disjoint `## Touches` run
# concurrently. A mega-goal whose sub-goals declare NO `## Touches` still runs fully serially
# (admitted=0 -> serial fallthrough), so the flip is a no-op for Touches-less mega-goals except that
# a `depends`-declaring one is now dep-aware (halts rather than running a dep-blocked sub-goal). Set
# WAVE_CAP=1 to force the old always-serial loop. A non-numeric or <1 value is REJECTED at cmd_run
# entry (NOT silently coerced), per DEC-009 / Edge case 4. Defaulted here so the top-of-loop `-ge 2`
# test is `set -u`-safe.
# SG-03: env wins outright; else the config layer's [mega].wave_cap (project > kit-root);
# else the hardcoded 2 below (kit_config_get's own caller-default arg).
WAVE_CAP="${WAVE_CAP:-$(kit_config_get mega.wave_cap 2)}"

# Wave-convergence merge hook (SPEC-106 TASK-004c). After a wave lands its sub-goals on their worktree
# branches, their merges back to the mega-goal base MUST happen ONE AT A TIME under the flip lock (see
# `_wave_converge`); the actual merge goes through THIS mockable hook. Default is the real path
# (`lib/goal/mega-merge.sh merge`, whose semantics stay untouched , convergence only SEQUENCES calls to it),
# invoked with mega-merge's real `<pr> <rid> <lane>` arity (ID-090). It only fires for a sub-goal that
# has a real recorded PR#; a placeholder `#__` is skipped, so a wave with no real PRs converges to a
# clean no-op. Tests set WAVE_MERGE_CMD to a mock that records merge ordering. Word-split intentionally
# (operator config, not user data), mirroring CLAUDE_FLAGS. Override the lane via WAVE_MERGE_LANE.
WAVE_MERGE_CMD="${WAVE_MERGE_CMD:-$LIB_ROOT/goal/mega-merge.sh merge}"

# Multiplexer panes (SPEC-119, executes ADR-0032 section 4). Opt-in (default 0/off): when a wave
# runs (MULTIPLEXER=1, WAVE_CAP>1, sub-goals declaring disjoint Touches so >=1 is actually
# admitted concurrently), each spawned wave session runs inside a tmux window instead of a plain
# background job, so the operator can `tmux capture-pane`/`send-keys` it (watch + intervene across
# tabs, ADR-0032 s4). OFF by default: `_wave_run`'s spawn/reap take the exact pre-existing
# kill-0/wait code path and $TMUX_CMD is never invoked (the off-path-unchanged property this
# sub-goal's Proof is built on). TMUX_CMD mirrors CLAUDE_CMD's mock seam (tests point it at a fake
# `tmux` so no real tmux server is needed in CI). TMUX_SESSION overrides the derived per-megagoal
# tmux session name (default: sanitized from the megadir path, see _mux_session_name).
# SG-03: env wins; else [mega].multiplexer (project > kit-root, "true"/"false" normalized);
# else off (0).
MULTIPLEXER="${MULTIPLEXER:-$(_kit_bool01 "$(kit_config_get mega.multiplexer)" 0)}"
TMUX_CMD="${TMUX_CMD:-tmux}"

# Pane viewer push (SPEC-121). SPEC-119's panes are PULL-only (the operator must know the tmux
# session name and attach by hand); PANE_VIEWER is the PUSH half: on wave spawn, open ONE viewer
# surface in the operator's own terminal app, already attached to the wave's tmux session (one
# surface per wave session per run, never one per worker -- noise control; tmux's own window keys
# do the per-worker drill-down). Default `auto` (push is the DEFAULT, operator decision
# 2026-07-03): detect the running viewer -- cmux env (CMUX_WORKSPACE_ID) first, then
# $TERM_PROGRAM (iTerm.app/ghostty/WezTerm/Apple_Terminal), then $KITTY_WINDOW_ID -- and
# SILENTLY degrade to today's pull behavior when nothing is detected or stderr is not a TTY, so
# headless CI stays byte-identical. `none` = pull exactly; an explicit viewer name skips
# detection (operator intent; still best-effort). Unknown values are REJECTED at cmd_run
# pre-flight (allowlist below), never coerced. VIEWER_CMD mirrors TMUX_CMD's mock seam: when
# set, the whole viewer argv is handed to it instead of exec'd, so tests need no GUI and the
# off paths get a poisonable negative control. A viewer failure warns and degrades; it NEVER
# fails the wave. Zero-code alternative (documented, not built): an iTerm2 operator can
# `tmux -CC attach -t <session>` for native-tab control mode with no orchestrator wiring.
PANE_VIEWER="${PANE_VIEWER:-auto}"
VIEWER_CMD="${VIEWER_CMD:-}"
PANE_VIEWER_ALLOWED="auto cmux kitty wezterm ghostty iterm terminal none"

# Subagent pane formatter (SPEC-234, the `panes` subcommand). `cmd_panes` resolves this HERE,
# caller-side, and hands it to the pane as an argv token, never an env read inside the pane --
# exported env does not cross the tmux server boundary, so an env-only seam would be a
# false-green in direct-call tests. Default: the formatter shipped next to this script.
PANE_TAIL_JQ="${PANE_TAIL_JQ:-$ORCH_DIR/pane-tail.jq}"

# TIER-4 mega-close (SPEC-118/ID-093, executes ADR-0032 section 5). Default ON (1): when EVERY
# sub-goal box is checked, `cmd_run` runs a real mega-level close over the ASSEMBLED WAVE instead of
# just printing "done" -- a mechanical no-orphan sweep (a dispatchable AGENT defined-but-never-
# dispatched is a BLOCKING finding, the kit-hardening c6fbd99 class) THEN THREE independent
# fresh-context `claude -p` verifier sessions (integration-verifier vs the mega OBJECTIVE /
# review-team incl. the security lens / the advisor in both modes, one process each) whose verdicts
# are fail-closed aggregated, THEN it HOLDS the final human gate (it NEVER auto-merges past it --
# gated-final).
# TIER4_CLOSE=0 restores the bare "done"-and-return (the escape hatch an unrelated all-auto-completion
# test uses so the close fires only in its own dedicated test). TIER4_CORPUS overrides the no-orphan
# sweep root (default: the megadir's git repo root); unset AND unresolvable -> the sweep is SKIPPED
# with a WARN (there is no corpus to sweep, so it must not manufacture a false halt).
# SG-03: env wins; else [mega].tier4_close (project > kit-root, "true"/"false" normalized);
# else on (1).
TIER4_CLOSE="${TIER4_CLOSE:-$(_kit_bool01 "$(kit_config_get mega.tier4_close)" 1)}"

# Gate-sub-goal DISPATCH (default 1). The documented contract (commands/mega.md Step 5, the
# plan-for-mega-goal skill) is that a `gate` sub-goal's worker DOES the work, opens its PR as a
# DRAFT, marks it via `mega-merge.sh mark`, and the loop then stops for a HUMAN MERGE. The driver
# used to stop BEFORE running it ("open/await its PR for review"), so a gate sub-goal was never
# dispatched and its work never happened -- the loop asked a human to review a PR nobody had
# opened. With this on, a `gate`/`gate!` sub-goal is dispatched exactly like an `auto` one, its
# prompt carries the held-PR contract, and the hold happens AFTER the session, keyed on the PR
# existing. MEGA_GATE_DISPATCH=0 restores the old stop-before-running behavior.
MEGA_GATE_DISPATCH="${MEGA_GATE_DISPATCH:-1}"

# `gh` seam for the gate hold's PR lookup, mirroring CLAUDE_CMD's mock seam so tests need no
# network and no GitHub auth.
GH_CMD="${GH_CMD:-gh}"

_say() { printf '%s\n' "$*"; }

# Portable file mtime (epoch secs). GNU `stat -c` FIRST: it errors cleanly on BSD/macOS, so the
# `stat -f` fallback runs there; the reverse order is unsafe because GNU `stat -f` SUCCEEDS with
# filesystem text (starting "File:"), starving the fallback and poisoning `$(( ))`. Digit-guarded
# so any non-numeric stat output yields empty rather than breaking arithmetic. Empty if absent.
_mtime() {
  local m
  m=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null)
  case "$m" in ''|*[!0-9]*) return 0 ;; *) printf '%s' "$m" ;; esac
}

# ---- Portable mkdir-based mutual exclusion (SPEC-106 TASK-002 / DEC-009) ----------------------
# `mkdir "$lockdir"` is the atomic acquire (NOT `flock`: absent on macOS, zero repo usage). The
# holder writes its PID to "$lockdir/pid"; `_lock` blocks/retries with a short sleep until it wins.
# A STALE lock is reclaimed ONLY when: [ -n "$lockdir" ] AND the recorded PID fails `kill -0` (the
# holder crashed) OR the lock age exceeds FLIP_LOCK_STALE_SECS AND that PID is dead. Reclaim is
# `rmdir` after moving the pid file aside -- NEVER `rm -rf` (rmdir refuses a non-empty/odd path).

# 0 = stale (reclaimable) / 1 = fresh. A LIVE holder PID is never stale (the holder is working);
# a DEAD recorded PID is stale (crash); an unreadable/absent PID is stale only past the timeout so
# a lock created microseconds ago (mkdir done, pid not yet written) is never yanked out of a race.
_lock_stale() {  # lockdir
  local lockdir="$1" pid age now mt
  [ -n "$lockdir" ] || return 1
  [ -d "$lockdir" ] || return 1
  pid=$( [ -f "$lockdir/pid" ] && tr -dc '0-9' < "$lockdir/pid" 2>/dev/null )  # guard the open: benign mkdir-before-pid-write race must not leak stderr
  if [ -n "$pid" ]; then
    kill -0 "$pid" 2>/dev/null && return 1   # holder alive -> not stale
    return 0                                  # recorded holder dead -> reclaim (crashed)
  fi
  now=$(date +%s); mt=$(_mtime "$lockdir"); [ -n "$mt" ] || return 1
  age=$((now - mt))
  [ "$age" -ge "$FLIP_LOCK_STALE_SECS" ] && return 0 || return 1
}

# Reclaim a stale lock: move the stale pid file aside (never `rm`), then `rmdir` the emptied dir.
_lock_reclaim() {  # lockdir
  local lockdir="$1"
  [ -n "$lockdir" ] || return 1
  [ -e "$lockdir/pid" ] && mv -f "$lockdir/pid" "${TMPDIR:-/tmp}/flip-stale-pid.$$.$RANDOM" 2>/dev/null
  rmdir "$lockdir" 2>/dev/null
}

# Acquire the lock (blocks until held), writing our PID into it; reclaims a crashed holder.
_lock() {  # lockdir
  local lockdir="$1"
  [ -n "$lockdir" ] || { echo "_lock: empty lockdir" >&2; return 64; }
  mkdir -p "$(dirname "$lockdir")" 2>/dev/null || true
  while :; do
    if mkdir "$lockdir" 2>/dev/null; then
      printf '%s\n' "$$" > "$lockdir/pid"
      return 0
    fi
    if _lock_stale "$lockdir"; then _lock_reclaim "$lockdir"; continue; fi
    sleep "$FLIP_LOCK_POLL_SECS"
  done
}

# Release a lock we hold (or an empty one); never yank a different LIVE holder's lock.
_unlock() {  # lockdir
  local lockdir="$1" pid
  [ -n "$lockdir" ] || return 0
  [ -d "$lockdir" ] || return 0
  pid=$( [ -f "$lockdir/pid" ] && tr -dc '0-9' < "$lockdir/pid" 2>/dev/null )  # guard the open: benign mkdir-before-pid-write race must not leak stderr
  if [ -z "$pid" ] || [ "$pid" = "$$" ]; then
    [ -e "$lockdir/pid" ] && mv -f "$lockdir/pid" "${TMPDIR:-/tmp}/flip-own-pid.$$.$RANDOM" 2>/dev/null
    rmdir "$lockdir" 2>/dev/null
  fi
}

# Emit "id<TAB>policy<TAB>checked(0|1)" per sub-goal line, in ROADMAP order.
# Policy is the comma-separated field that EQUALS auto|gate|gate! after trim (not a regex hit on the
# description, so "(gate review)" or "gate-aware" do not false-match). `gate!` (SPEC-106 TASK-007) is
# the global-stop policy; the `!` survives tolower and the exact-match compare, so it is kept distinct
# from plain `gate` (chain-stop). Unknown -> gate (fail-safe: a malformed line stops the loop for a
# human rather than silently auto-running). The trailing `|| true` keeps a no-match grep from escaping
# under `set -o pipefail`.
_subgoals() {
  local roadmap="$1"
  grep -E '^- \[[ xX]\] SG-[0-9]+' "$roadmap" 2>/dev/null | while IFS= read -r line; do
    local id policy checked=0
    id=$(printf '%s' "$line" | grep -oE 'SG-[0-9]+' | head -1)
    [ -n "$id" ] || continue
    policy=$(printf '%s' "$line" | awk -F',' '{for(i=1;i<=NF;i++){f=$i; gsub(/^[ \t]+|[ \t]+$/,"",f); lf=tolower(f); if(lf=="auto"||lf=="gate"||lf=="gate!"){print lf; exit}}}')
    case "$line" in
      '- ['[xX]']'*) checked=1 ;;
    esac
    printf '%s\t%s\t%s\n' "$id" "${policy:-gate}" "$checked"
  done || true
}

# Next unchecked sub-goal as "id<TAB>policy", or empty.
_next() { _subgoals "$1" | awk -F'\t' '$3==0 {print $1"\t"$2; exit}'; }

# Wavefront ready set (SPEC-106 TASK-001): every sub-goal that is unchecked AND has no blocking
# deps, in ROADMAP order, as "id<TAB>policy" (the _subgoals shape minus the checked column).
# Ready = checked==0 AND `_sg_deps_blocked` empty (reuses the existing dep parser at L133; no
# reimplementation). PURE READ helper: it changes NO scheduling (nothing calls it into the run
# loop yet). Backward-compat invariant: on a no-deps ROADMAP nothing blocks, so it returns ALL
# unchecked sub-goals and its FIRST line equals `_next`'s pick (the size-1 superset invariant ,
# `_next` is `_ready_set | head -1` semantically). Process-sub (not a pipe) so the caller's shell
# owns the loop, matching _derive_board L172.
_ready_set() {
  local roadmap="$1" id policy checked line
  while IFS=$'\t' read -r id policy checked; do
    [ "$checked" = 0 ] || continue
    line=$(_sg_line "$roadmap" "$id")
    [ -z "$(_sg_deps_blocked "$roadmap" "$line")" ] && printf '%s\t%s\n' "$id" "$policy"
  done < <(_subgoals "$roadmap")
}

# ---- Merged-PR box reconciliation + gate-hold PR lookup ---------------------------------------
# The repo's default branch, from `origin/HEAD` when the remote HEAD ref is present, else whichever
# of main/master the remote actually carries. Empty when neither resolves (no remote, bare checkout).
_default_branch() {  # repo
  local repo="$1" d
  d=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
  [ -n "$d" ] && { printf '%s' "${d#origin/}"; return 0; }
  for d in main master; do
    git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$d" && { printf '%s' "$d"; return 0; }
  done
}

# A view of ROADMAP.md that reflects `origin/<default>`, for the grounded-completion box check.
# A sub-goal worker commonly flips its own box INSIDE its PR; once that PR merges, the box is
# checked on the remote while this driver's local checkout is still behind, and the box check below
# called a healthy session a liar (observed on a real 5-sub-goal run). Prints the path to READ:
#   * the LOCAL roadmap, after a `git fetch` + `--ff-only` merge, when the megagoal sits in a repo
#     whose checkout is ON the default branch with a CLEAN tree (never force-pull a dirty tree);
#   * a TEMP copy read out of `origin/<default>` when the tree is dirty (check only, no mutation);
#   * nothing at all when there is no repo / no remote / the checkout is on a feature branch.
# The caller deletes a temp path; a returned path equal to $roadmap is the live file. STDOUT carries
# the path and NOTHING else (the caller reads it through a command substitution), so the two log
# lines below go to stderr.
_roadmap_remote_view() {  # dir roadmap
  local dir="$1" roadmap="$2" repo branch def rel tmp
  repo=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 0
  [ -n "$repo" ] || return 0
  def=$(_default_branch "$repo"); [ -n "$def" ] || return 0
  branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)
  [ "$branch" = "$def" ] || return 0
  git -C "$repo" fetch --quiet origin "$def" 2>/dev/null || return 0
  # Repo-relative path of the ROADMAP, derived by prefix-stripping PHYSICAL paths rather than by
  # `git ls-files <abspath>`: on macOS the megadir often arrives via the /var -> /private/var symlink,
  # which git rejects as "outside repository" even though it is not.
  rel=$(cd "$(dirname "$roadmap")" 2>/dev/null && pwd -P)/$(basename "$roadmap")
  rel="${rel#"$repo"/}"
  case "$rel" in /*) return 0 ;; esac   # not under the repo root: nothing to reconcile against
  # Untracked files are EXCLUDED from the dirty test: the driver itself writes BOARD.md and
  # .orchestrate/ into the megagoal dir, so `--porcelain` alone would call every run dirty and the
  # fast-forward would never happen. `merge --ff-only` still refuses on its own if the fast-forward
  # would clobber an untracked file, and the `git show` path below catches that refusal.
  if [ -z "$(git -C "$repo" status --porcelain --untracked-files=no 2>/dev/null)" ] \
     && git -C "$repo" merge --ff-only "origin/$def" >/dev/null 2>&1; then
    echo "[orchestrate] [reconcile] fast-forwarded $def to origin/$def before the box check." >&2
    printf '%s' "$roadmap"; return 0
  fi
  tmp=$(mktemp) || return 0
  if git -C "$repo" show "origin/$def:$rel" > "$tmp" 2>/dev/null; then
    echo "[orchestrate] [reconcile] tree not fast-forwardable; reading ROADMAP.md from origin/$def for the box check only." >&2
    printf '%s' "$tmp"; return 0
  fi
  rm -f "$tmp"
}

# The PR URL for a sub-goal's declared branch, or empty. This is how a GATE sub-goal's completion is
# grounded: it must NOT flip its own box (a human merges its PR), so the evidence that its session
# actually finished is that a PR exists. Mockable via GH_CMD; any failure (no gh, no auth, no PR)
# yields empty, which the caller treats exactly like an unflipped box.
_sg_pr_url() {  # dir id
  local dir="$1" id="$2" branch url
  branch=$(_sg_branch "$(_goalfile "$dir" "$id")" "$id")
  [ -n "$branch" ] || return 0
  # shellcheck disable=SC2086 # GH_CMD is operator config; word-splitting is intended (mirrors CLAUDE_FLAGS).
  url=$($GH_CMD pr view "$branch" --json url -q .url 2>/dev/null | head -1)
  case "$url" in http*) printf '%s' "$url" ;; esac
}

# ---- SG-10 board-view / event-sourced status -----------------------------------------------
# Event-sourced status (pi-swarm borrow): the loop APPENDS status events; the board is DERIVED
# by replay (last event per sub-goal wins), NEVER mutated in place -> a crashed/concurrent
# session cannot corrupt a checkbox. ROADMAP.md + the goal files stay canonical; the board is a
# regenerated view-sync. SG-11's watchdog reuses this file (mtime + last status) as its signal.
_events_file() { printf '%s/.orchestrate/events.log\n' "$1"; }

_emit_event() {  # dir id status [note]
  local dir="$1" id="$2" status="$3" note="${4:-}" ef
  # Review-fix FIX 3 (DEC-009): truncate comfortably under PIPE_BUF (512B) so the atomic-append
  # guarantee concurrent wave sessions rely on is structural, not by-convention.
  note=${note:0:400}
  ef=$(_events_file "$dir"); mkdir -p "$(dirname "$ef")"
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$id" "$status" "$note" >> "$ef"
}

# Last event for a sub-goal by replay, as "status<TAB>note" (empty if none).
_event_status() {  # dir id
  local ef; ef=$(_events_file "$1")
  [ -f "$ef" ] || return 0
  awk -F'\t' -v id="$2" '$2==id{s=$3; n=$4} END{ if(s!="") printf "%s\t%s", s, n }' "$ef"
}

# Raw ROADMAP line for a sub-goal id (or empty).
_sg_line() { grep -E "^- \[[ xX]\] $2 " "$1" 2>/dev/null | head -1; }

# Human title from a ROADMAP line: text after "SG-NN " up to the first " , " policy separator.
_sg_title() {  # raw-line id
  printf '%s' "$1" | sed -E "s/^- \[[ xX]\] $2 //; s/ , .*$//" | cut -c1-60
}

# Blocking deps: SG-NN tokens in the line's `depends ...` tail that are NOT yet checked (space-
# separated, empty if none). Non-SG deps (e.g. #81 = a prerequisite PR) are out of board scope.
_sg_deps_blocked() {  # roadmap raw-line
  local roadmap="$1" line="$2" deps d blockers=""
  deps=$(printf '%s' "$line" | grep -oE 'depends[^,]*' | grep -oE 'SG-[0-9]+' || true)
  for d in $deps; do
    _subgoals "$roadmap" | awk -F'\t' -v i="$d" '$1==i && $3==1{f=1} END{exit !f}' || blockers="$blockers $d"
  done
  printf '%s' "${blockers# }"
}

# Dependents test (SPEC-106 TASK-005): does any OTHER sub-goal's `depends` list name <id>?
# Exit 0 iff <id> HAS DEPENDENTS (something feeds forward FROM it), else nonzero. Reuses the same
# `depends SG-NN` token parse as _sg_deps_blocked (no new format). Read-only. This is the WRITE-side
# key: a sub-goal writes HANDOFF-<id>.md only when this holds; a leaf / linear-tail has none and
# keeps writing plain HANDOFF.md, so the no-deps mega-goal stays byte-identical.
_sg_dependents() {  # roadmap id
  local roadmap="$1" id="$2" other _p _c line deps d
  while IFS=$'\t' read -r other _p _c; do
    [ "$other" = "$id" ] && continue
    line=$(_sg_line "$roadmap" "$other")
    deps=$(printf '%s' "$line" | grep -oE 'depends[^,]*' | grep -oE 'SG-[0-9]+' || true)
    for d in $deps; do
      [ "$d" = "$id" ] && return 0
    done
  done < <(_subgoals "$roadmap")
  return 1
}

# Derive the per-mega-goal BOARD.md (kanban table in backlog.sh's row format, so backlog.sh
# renders it and the cockpit format stays consistent). State = shipped if the box is checked,
# else the replayed event status, else dep-analysis (queued=ready / parked=blocked). The
# ready/blocked/stalled nuance rides as status PROSE (backlog.sh supports it). Prints the path.
_derive_board() {  # dir roadmap
  local dir="$1" roadmap="$2"
  local board="$dir/BOARD.md"
  {
    printf '# Board (derived view): %s\n\n' "$(basename "$dir")"
    printf '> DERIVED by "orchestrate.sh --board" from ROADMAP.md + .orchestrate/events.log. Do NOT\n'
    printf '> hand-edit: ROADMAP.md + the goal files are canonical; this is a regenerated view-sync.\n'
    printf '> Per-mega-goal only; the repo-wide BACKLOG cockpit is never touched.\n\n'
    printf '## Active queue\n\n'
    printf '| ID | Item | Notes & source | Status |\n'
    printf '|----|------|----------------|--------|\n'
    local id policy checked line title es estatus enote status blockers
    while IFS=$'\t' read -r id policy checked; do
      line=$(_sg_line "$roadmap" "$id"); title=$(_sg_title "$line" "$id")
      es=$(_event_status "$dir" "$id")
      estatus=$(printf '%s' "$es" | cut -f1); enote=$(printf '%s' "$es" | cut -f2)
      if [ "$checked" = 1 ]; then
        status="shipped"
      elif [ "$estatus" = executing ] || [ "$estatus" = stalled ]; then
        status="executing"
        [ "$estatus" = stalled ] && status="executing [stalled${enote:+: $enote}]"
      else
        blockers=$(_sg_deps_blocked "$roadmap" "$line")
        if [ -n "$blockers" ]; then status="parked [blocked: needs $blockers]"; else status="queued [ready]"; fi
      fi
      printf '| %s | %s | %s | %s |\n' "$id" "${title:-?}" "$policy" "$status"
    done < <(_subgoals "$roadmap")
  } > "$board"
  printf '%s\n' "$board"
}

# Render the board surface to stdout for a mode. roadmap -> nothing (checkboxes ARE the view);
# kanban|both -> derive BOARD.md then render its columns via backlog.sh (fallback: cat the file).
_render_board() {  # dir roadmap mode
  local dir="$1" roadmap="$2" mode="$3" board
  case "$mode" in
    roadmap|"") return 0 ;;
    kanban|both)
      board=$(_derive_board "$dir" "$roadmap")
      _say "[board] derived per-mega-goal view -> $board (ROADMAP stays canonical)"
      if [ -f "$BACKLOG_LIB" ]; then
        BACKLOG_FILE="$board" bash "$BACKLOG_LIB" board 2>/dev/null || cat "$board"
      else
        cat "$board"
      fi ;;
    *) echo "unknown --board mode: '$mode' (want roadmap|kanban|both)" >&2; return 64 ;;
  esac
}

# Resolve the board mode: explicit wins; empty -> detect (backlog.sh present -> both, else
# roadmap so a kit without the kanban tooling still runs).
_resolve_board_mode() { if [ -n "$1" ]; then printf '%s' "$1"; elif [ -f "$BACKLOG_LIB" ]; then printf 'both'; else printf 'roadmap'; fi; }
# --------------------------------------------------------------------------------------------

# Resolve a sub-goal's goal file path (goals/<NN>-*.md), or empty.
_goalfile() {
  local dir="$1" id="$2" f
  for f in "$dir/goals/${id#SG-}-"*.md; do [ -f "$f" ] && { printf '%s\n' "$f"; return; }; done
}

# Wavefront admission gate (SPEC-106 TASK-003, DEC-007/011/012). PURE DECISION helper: it decides
# which ready sub-goals may run concurrently; it spawns NOTHING and is not yet wired into cmd_run
# (that is TASK-004). Reads the ready set (`_ready_set`), then admits GREEDILY in ROADMAP order , a
# candidate is admitted iff (a) its goal file declares its OWN `## Touches` section AND (b) it proves
# disjoint (dispatch-gate.sh, the ONE disjointness authority per DEC-001) against EVERY already-
# admitted member. Admission stops at WAVE_CAP (env, default 2 => waves on by default; WAVE_CAP=1
# forces the old always-serial admission of at most one `run`).
#
# Self-Touches is REQUIRED (DEC-012b): dispatch-gate admits the FIRST member vacuously (empty admitted
# set => nothing to prove disjoint against), so without demanding the candidate's own `## Touches` a
# Touches-less sub-goal would be wrongly admitted. A goal file with no `## Touches` => always `defer`
# (the Option-B opt-in gate).
#
# dispatch-gate.sh is REUSED as a SUBPROCESS (`bash "$gate" touches|disjoint ...`), NOT sourced: it
# runs `set -euo pipefail` at load, which would leak `-e` into this driver's deliberate `set -uo`
# posture (L33) and break the sourced test harness. The subprocess boundary contains that; a fork per
# pair is negligible for a wave-launch decision over a small ready set. `disjoint` exit 0 = provably
# disjoint (admit-eligible); any nonzero (1 overlap / 2 undeclared) = not disjoint => defer.
#
# Output: one `run<TAB>id` or `defer<TAB>id` line per ready sub-goal, in ROADMAP order. Wire format
# per SPEC-106 "Helper wire formats". bash-3.2 safe: no assoc-arrays; the admitted set is a plain
# array of goal-file paths, empty-guarded `${arr[@]+"${arr[@]}"}` (DEC-005, mega-merge.sh:224).
# Process-sub (not a pipe) feeds the loop so the admitted state lives in THIS shell, not a subshell.
_wave_gate() {  # megadir roadmap
  local megadir="$1" roadmap="$2"
  local cap="${WAVE_CAP:-1}"
  # Defensive numeric guard: a non-numeric/empty cap would make the `-lt` test emit a bash integer
  # error. The parse-time rejection of `<1`/non-numeric WAVE_CAP is TASK-004b's wiring boundary; this
  # helper only ever sees a validated cap in the wired path, so falling back to 1 here is belt-and-
  # braces for a direct call, never a substitute for that rejection.
  case "$cap" in ''|*[!0-9]*) cap=1 ;; esac
  local gate="$LIB_ROOT/gate/dispatch-gate.sh"
  local admitted_files=() admitted_n=0
  local id policy gf a decision ok
  while IFS=$'\t' read -r id policy; do
    [ -n "$id" ] || continue
    decision=defer
    # A `gate` / `gate!` sub-goal is NEVER admitted to a wave (SPEC-106 TASK-007, DEC-010). This is
    # what makes the wave-path chain-hold work: the gate sub-goal is not run, so anything that
    # `depends` on it stays dep-blocked (its chain holds), while INDEPENDENT ready sub-goals are still
    # admitted below. `gate!` (global stop) is caught earlier in cmd_run; deferring it here too is
    # belt-and-suspenders so a wave can never run either gate kind autonomously (the V-CRIT-7 fix).
    case "$policy" in gate|'gate!') printf '%s\t%s\n' defer "$id"; continue ;; esac
    gf=$(_goalfile "$megadir" "$id")
    # (a) self-Touches REQUIRED, and (b) room under the cap, and (c) disjoint vs every admitted member.
    if [ -n "$gf" ] && [ -n "$(bash "$gate" touches "$gf" 2>/dev/null)" ] && [ "$admitted_n" -lt "$cap" ]; then
      ok=1
      for a in ${admitted_files[@]+"${admitted_files[@]}"}; do
        bash "$gate" disjoint "$gf" "$a" >/dev/null 2>&1 || { ok=0; break; }
      done
      if [ "$ok" = 1 ]; then
        decision=run
        admitted_files+=("$gf")
        admitted_n=$((admitted_n + 1))
      fi
    fi
    printf '%s\t%s\n' "$decision" "$id"
  done < <(_ready_set "$roadmap")
}

# ID-096: the allowlisted `Model:` tier names -- the same short names the decompose-time model
# suggester's `tier_of()` normalizes to (haiku/sonnet/opus/fable). Kept as one constant so the
# allowlist and its error message never drift apart.
#
# `fable` added 2026-07-22: it shipped as a `claude --model` alias (the CLI's own --help lists
# "'fable', 'opus', or 'sonnet'") and is the operator's default daily driver, but this allowlist
# still predated it -- so a goal file saying `Model: fable` was REJECTED pre-flight and never
# dispatched. The allowlist is a typo guard, not a policy, and it has to track the CLI's aliases.
_ROUTE_MODEL_ALLOWLIST="opus sonnet haiku fable"

# Emit "model<TAB>effort" read from a goal file's `Model:`/`Effort:` lines (empty when absent).
# Bare `Key: value` header lines, not YAML; first match each, value trimmed. Absent field or
# absent file -> empty -> the orchestrator emits no flag and the session inherits its tier
# (SPEC-087 "Model / Effort routing"). The biggest $ lever: Opus only on the hard sub-goals.
#
# ID-096: pre-flight allowlist validation. Before this fix, an off-allowlist `Model:` value (a
# typo, e.g. `Model: sonet`) was passed VERBATIM into `--model <value>` and died mid-dispatch as an
# opaque `claude` CLI error deep inside a spawned session (or, worse under a wave, mid-drain with
# sibling sessions already in flight). Reject it HERE instead, before any session spawns: an
# off-allowlist value prints a clear error to stderr and returns 64 (the same "bad input" exit code
# `cmd_run`'s own WAVE_CAP/PANE_VIEWER pre-flight checks use), so a caller checking `_route`'s exit
# status (`local out; out=$(_route "$gf"); rc=$?`, an assignment's `$?` reflects the command
# substitution's own exit code) catches it before dispatch. Absent `Model:` (empty) is untouched,
# still the documented inherit fallback (SPEC-107), never rejected. Case-insensitive: `Opus`/`OPUS`
# match same as `opus` (goal files are hand-authored prose headers, not a strict schema).
#
# Membership is EXACT-TOKEN enumeration (iterate the allowlist, compare `==`), NOT a
# `case " $list " in *" $v "*` substring test. The substring idiom is the exact bug the
# `PANE_VIEWER` pre-flight in `cmd_run` calls out as a security P2 and fixes the same way: two
# adjacent allowed words joined by one space are a substring of the joined list, so a MULTI-WORD
# value like `Model: opus sonnet` would slip through (`" opus sonnet "` is a substring of
# `" opus sonnet haiku "`) and get passed verbatim to `--model "opus sonnet"`, dying deep in the
# spawned `claude -p` , precisely the failure ID-096 exists to stop.
# The set of NON-claude harnesses this kit installation permits, from `mega.enabled_agent_clis` (ID-390).
# DEFAULT EMPTY = claude-only: out of the box, multi-vendor dispatch is OFF, so a stray `Harness:
# codex` header errors clearly instead of surprise-spending on another vendor's account. An operator
# who has, say, codex installed and authenticated opts in by setting `enabled_agent_clis = "codex"`
# under `[mega]` in the KIT-ROOT kit.toml. Space-separated; the config resolver returns a bare
# string, not a TOML array, so this is a string list, not `["codex"]`.
#
# SECURITY (review CRITICAL, 2026-07-22): this reads the KIT-ROOT layer ONLY, deliberately NOT the
# normal `kit_config_get` (project `.kit.toml` > kit-root). The project `.kit.toml` is a git-tracked
# file that rides INSIDE the mega-goal branch being executed, so a hostile PR that adds `Harness:
# codex` to a goal file could, in the SAME PR, add `enabled_agent_clis = "codex"` to `.kit.toml` and
# self-authorize the vendor the operator never opted into. Reading kit-root only
# (`~/.claude/dwarves-kit/kit.toml`, the operator's machine install, never in any repo) closes that:
# enablement is an operator decision the PR cannot forge. Tradeoff: per-project enablement via a
# committed `.kit.toml` is intentionally UNSUPPORTED for this one knob (a committed file is
# PR-writable); this is the single place the normal project-wins precedence is inverted, on purpose.
_harness_allowed() { _kit_toml_get "$(kit_config_root)" mega enabled_agent_clis; }

# The goal file's `Harness:` header, lowercased, defaulting to `claude` (ID-390). This is the ONE
# place the vendor is decided; everything downstream branches on its result. Three outcomes:
#
#   absent header      -> `claude` -> every existing code path runs BYTE-IDENTICALLY (the backward-
#                         compat invariant this whole feature is built on; a mega-goal that never
#                         says `Harness:` cannot behave differently than before, and the 178
#                         pre-existing orchestrate assertions prove it).
#   unknown vendor      -> 64. Falling back to claude would silently run the sub-goal on the wrong
#                         (and wrong-priced) vendor -- the quiet substitution that makes a
#                         quota-routing feature untrustworthy. A typo is a pre-flight stop.
#   known but not enabled -> 64, DISTINCT message. The vendor is real but the OPERATOR'S kit install
#                         has not opted into it via `mega.enabled_agent_clis`. This is the gate Han asked for: the feature
#                         ships to every kit user but stays OFF until they deliberately enable a
#                         vendor they have actually set up. Same fail-closed posture as an unknown
#                         vendor -- never a silent claude fallback.
_harness_of() {  # goalfile
  local gf="${1:-}" h="" allowed tok ok
  [ -f "$gf" ] && h=$(grep -iE '^Harness:[[:space:]]*' "$gf" | head -1 | sed -E 's/^[^:]*:[[:space:]]*//; s/[[:space:]]+$//' | tr 'A-Z' 'a-z')
  [ -n "$h" ] || { printf 'claude\n'; return 0; }
  [ "$h" = claude ] && { printf 'claude\n'; return 0; }   # claude always allowed, never gated
  harness_known "$h" || {
    echo "orchestrate: unknown Harness: '$h' in $gf (known: $(harness_list | tr '\n' ' ')); rejecting pre-flight, not dispatching" >&2
    return 64; }
  allowed=$(_harness_allowed); ok=0
  for tok in $allowed; do [ "$tok" = "$h" ] && { ok=1; break; }; done
  [ "$ok" = 1 ] || {
    echo "orchestrate: Harness: '$h' in $gf is not enabled in this kit. Multi-vendor dispatch is opt-in: add it to mega.enabled_agent_clis in kit.toml (currently: ${allowed:-<none; claude-only>}). Not dispatching." >&2
    return 64; }
  printf '%s\n' "$h"
}

_route() {
  local gf="${1:-}" model="" effort="" model_lc tok ok harness
  if [ -f "$gf" ]; then
    model=$(grep -iE '^Model:[[:space:]]*' "$gf" | head -1 | sed -E 's/^[^:]*:[[:space:]]*//; s/[[:space:]]+$//')
    effort=$(grep -iE '^Effort:[[:space:]]*' "$gf" | head -1 | sed -E 's/^[^:]*:[[:space:]]*//; s/[[:space:]]+$//')
  fi
  # ID-390: the tier allowlist below is CLAUDE-ONLY. `opus`/`sonnet`/`haiku`/`fable` are Claude
  # alias names, so validating a codex sub-goal's `Model: gpt-5` against them would reject every
  # legitimate non-claude model. There is no honest cross-vendor tier mapping (gpt-5 is not "opus"),
  # so a non-claude harness passes its model through VERBATIM and that vendor's own CLI is what
  # rejects a typo. A bad harness name still hard-stops here (see _harness_of).
  harness=$(_harness_of "$gf") || {
    # Uniform stdout on EVERY failure branch (review, 2026-07-22): the model-tier reject below prints
    # the `model\teffort` line before its `return 64`, so a caller that does `read model effort <
    # <(_route ...)` sees a consistent tab line whichever gate fired. Emit the same here so a
    # harness-gate failure is not the one branch that returns nothing.
    printf '%s\t%s\n' "$model" "$effort"; return 64; }
  # SECURITY (review HIGH, 2026-07-22): `Effort:` has no allowlist by design (no honest cross-vendor
  # effort mapping), but it MUST be character-validated. It is the one field that reaches an exec as
  # attacker-influenceable syntax on TWO paths: (a) codex splices it into `-c
  # model_reasoning_effort="<effort>"`, a TOML string an embedded `"` can break out of; (b) the
  # claude path word-splits `route_flags` (`--effort $reffort`) into the real `claude -p` argv, so a
  # value like `x --mcp-config /tmp/e.json` injects extra flags (the same argument-injection class
  # SPEC-119 closed for the tmux path). A charset gate at this ONE chokepoint closes both. `Model:`
  # needs no equivalent: claude models pass the exact-token tier allowlist below, and a non-claude
  # model becomes a single `harness_argv` array token (never word-split), so it has no injection
  # surface. Effort words for every vendor fit `[A-Za-z0-9_-]` (low/medium/high/xhigh/max/minimal/off).
  if [ -n "$effort" ] && ! printf '%s' "$effort" | grep -qE '^[A-Za-z0-9_-]+$'; then
    echo "orchestrate: invalid Effort: '$effort' in ${gf:-<no goal file>} (allowed chars: A-Za-z0-9_-); rejecting pre-flight, not dispatching" >&2
    printf '%s\t%s\n' "$model" "$effort"
    return 64
  fi
  # SG-03: the goal-file `Model:` field is UNCHANGED and still wins outright (Scope: "the
  # goal-file Model: parse ... still wins"). Only when the field is ABSENT does the run fall
  # back through the config layer's [mega].default_model (project .kit.toml > kit-root
  # kit.toml). No hardcoded value is baked in HERE: with no config file either, `model` stays
  # empty and the pre-existing "inherit the session's own tier" behavior is preserved byte-
  # for-byte (SPEC-087). The documented "hardcoded" floor of the four-layer chain is
  # kit.toml.example's own shipped `default_model = "sonnet"` line -- once an adopter installs
  # that file as their kit-root kit.toml, THIS lookup picks it up as the kit-root layer, same
  # as any other operator-set value.
  if [ -z "$model" ]; then
    model=$(kit_config_get mega.default_model)
  fi
  if [ -n "$model" ] && [ "$harness" = claude ]; then
    model_lc=$(printf '%s' "$model" | tr 'A-Z' 'a-z')
    ok=0
    for tok in $_ROUTE_MODEL_ALLOWLIST; do
      [ "$model_lc" = "$tok" ] && { ok=1; break; }
    done
    if [ "$ok" != 1 ]; then
        echo "orchestrate: invalid Model: tier '$model' in ${gf:-<no goal file>} (allowed: ${_ROUTE_MODEL_ALLOWLIST// /|}); rejecting pre-flight, not dispatching" >&2
        printf '%s\t%s\n' "$model" "$effort"
        return 64
    fi
  fi
  printf '%s\t%s\n' "$model" "$effort"
}

# Emit a gate-ledger START for a dispatched sub-goal (SPEC-101 / ID-085), the automated
# mirror of the `gate-ledger.sh start` that `commands/assign.md` makes for hand-run work.
# Without it, mega-dispatched runs are untracked (`?` lane/type) in lane-telemetry, the root
# cause of the SPEC-073 eval's NULL lane/type/skip/escape rates. Advisory + non-fatal: a
# missing goal file or a goal file with no `**Branch:**` WARNs and skips (a rid that does not
# match the session's real branch would only orphan the START). The rid is derived from the
# goal file's declared `**Branch:** <type>/<slug>` (branch does not exist yet at dispatch;
# gate-ledger keys the ledger by the rid string, and `runid` is idempotent, so the driver's
# raw slug and the session's later normalized rid resolve to one ledger file). chosen ==
# classified on both axes: the automated path takes the classifier verbatim (no human
# override), which is honest and never reads as a misroute.
# _rid_for: the canonical rid (branch slug) for a sub-goal, from its goal file's **Branch:** header.
# SHARED by _emit_start (writes the START line) and the SPEC-110 token hook (writes the TOKENS line)
# so both land in the SAME <rid>.log (spec-validate: no drift into separate ledger files). Empty
# output => no goal file or no **Branch:** header; the caller decides how to warn.
_rid_for() {  # dir id
  local dir="$1" id="$2" gf branch
  gf=$(_goalfile "$dir" "$id"); [ -n "$gf" ] || return 0
  branch=$(grep -iE '^\*\*Branch:\*\*' "$gf" | head -1 | sed -E 's/^\*\*[Bb]ranch:\*\*[[:space:]]*//; s/[[:space:]].*$//')
  [ -n "$branch" ] || return 0
  printf '%s\n' "${branch#*/}"   # strip the type/ prefix, matching gate-ledger.sh rid
}

# _record_tokens <dir> <id> <slog>: extract per-session token usage from a captured stream-json
# file and record a TOKENS ledger line for the sub-goal's rid (SPEC-110). SHARED by the serial
# per-sub-goal loop (cmd_run) AND the wave reap loop (_wave_run, ID-094) so both paths write to
# the exact same ledger stream via the exact same extraction. CAPTURE-GATED but the gate lives in
# the CALLER (an absent/empty $slog is also a harmless no-op here, so double-gating is safe, never
# load-bearing). Non-fatal: a parse miss must not stop the loop.
_record_tokens() {  # dir id slog
  local dir="$1" id="$2" slog="$3"
  [ -n "$slog" ] && [ -s "$slog" ] || return 0
  local trid tusage
  trid=$(_rid_for "$dir" "$id")
  [ -n "$trid" ] || return 0
  tusage=$(python3 "$LIB_ROOT/goal/handoff/handoff_gen.py" sum-usage "$slog" 2>/dev/null) || tusage=""
  [ -n "$tusage" ] || return 0
  # shellcheck disable=SC2086 # tusage is a controlled "in=N out=N cache_read=N cache_create=N" blob
  bash "$LIB_ROOT/gate/gate-ledger.sh" tokens "$trid" $tusage \
    && _say "[orchestrate] [telemetry] $id TOKENS recorded (rid=$trid: $tusage)."
}

_emit_start() {  # dir id
  local dir="$1" id="$2"
  local gf; gf=$(_goalfile "$dir" "$id")
  [ -n "$gf" ] || return 0   # no goal file already warns loudly in cmd_run
  local slug; slug=$(_rid_for "$dir" "$id")
  if [ -z "$slug" ]; then
    echo "[orchestrate] [telemetry] WARN: $id goal file has no '**Branch:**' header; cannot derive rid, skipping START (run will be '?' in lane-telemetry)." >&2
    return 0
  fi
  local title lane type
  title=$(_sg_title "$(_sg_line "$dir/ROADMAP.md" "$id")" "$id")
  lane=$(bash "$LIB_ROOT/classify/lane-classify.sh" classify "$title" 2>/dev/null | tail -1)
  type=$(bash "$LIB_ROOT/classify/task-type-classify.sh" classify "$title" 2>/dev/null | tail -1)
  [ -n "$lane" ] || lane=normal
  [ -n "$type" ] || type=spec-feature
  bash "$LIB_ROOT/gate/gate-ledger.sh" start "$slug" "$lane" "$lane" "$type" "$type" \
    && _say "[orchestrate] [telemetry] $id START recorded (rid=$slug lane=$lane type=$type)."
}

_build_prompt() {
  local dir="$1" id="$2" gate_policy="${3:-}"
  cat "$dir/POINTER_PROMPT.md" 2>/dev/null
  printf '\n\nNEXT SUB-GOAL: %s\n' "$id"
  # Held-PR contract for a `gate` / `gate!` sub-goal (MEGA_GATE_DISPATCH). The worker does the work
  # like any other sub-goal; what differs is the ending. Absent third arg -> nothing is printed and
  # an `auto` sub-goal's prompt stays byte-identical.
  if [ -n "$gate_policy" ]; then
    printf '\nHELD SUB-GOAL (%s): this sub-goal ends at a HUMAN MERGE, not at a merge you perform.\n' "$gate_policy"
    printf -- '- Do the work and verify it exactly as any other sub-goal.\n'
    printf -- '- Open the PR as a DRAFT (`gh pr create --draft ...`), then run `bash lib/goal/mega-merge.sh mark <pr>` so the do-not-merge label and the draft state are both set.\n'
    printf -- '- Do NOT merge the PR. Do NOT flip this sub-goal ROADMAP box. A human merges, and the merge is what checks the box.\n'
    printf -- '- The orchestrator grounds your completion on the PR EXISTING, so the PR is the deliverable.\n'
  fi
  # Inject the goal file's CONTENT (not just a path), so the session has the contract and
  # re-discovery is actually eliminated (SPEC-087 "Session invocation").
  local gf; gf=$(_goalfile "$dir" "$id")
  if [ -n "$gf" ]; then
    printf '\nGOAL FILE (%s, the contract for this sub-goal):\n' "$(basename "$gf")"
    cat "$gf"
  fi
  # Two-tier feed-forward (SPEC-087 Mechanism B):
  #   HOT  HANDOFF.md  -- overwritten each transition; injected in FULL but capped. Carries the
  #                      next action + read-pointers so re-discovery becomes a read.
  #   WARM DECISIONS.md -- append-only ledger of invariants + dead-ends; injected as a POINTER
  #                      only (path + size), read on demand, so it never bloats the prompt.
  # Per-edge feed-forward (SPEC-106 TASK-005): if <id> DECLARES deps, inject each dep-PARENT's
  # HANDOFF-<MM>.md (falling back to plain HANDOFF.md when the per-edge file is absent, so a chain
  # root that only wrote plain still feeds forward). A sub-goal with NO deps takes the ORIGINAL
  # plain path below UNCHANGED (byte-identical) -- do not fold the two together.
  local roadmap="$dir/ROADMAP.md" mydeps=""
  [ -f "$roadmap" ] && mydeps=$(printf '%s' "$(_sg_line "$roadmap" "$id")" | grep -oE 'depends[^,]*' | grep -oE 'SG-[0-9]+' || true)
  if [ -n "$mydeps" ]; then
    local mm hp lines
    printf '\nHOT HANDOFF from dep-parent(s) (verify before trusting):\n'
    for mm in $mydeps; do
      hp="$dir/HANDOFF-$mm.md"
      [ -s "$hp" ] || hp="$dir/HANDOFF.md"   # fallback: parent wrote plain HANDOFF.md, no per-edge file
      [ -s "$hp" ] || continue
      lines=$(wc -l < "$hp" | tr -d ' ')
      printf '\n-- from %s (%s):\n' "$mm" "$(basename "$hp")"
      if [ "$lines" -gt "$HANDOFF_MAX_LINES" ]; then
        head -n "$HANDOFF_MAX_LINES" "$hp"
        printf '[... %s truncated at %s/%s lines; read the file for the rest]\n' "$(basename "$hp")" "$HANDOFF_MAX_LINES" "$lines"
      else
        cat "$hp"
      fi
    done
  elif [ -s "$dir/HANDOFF.md" ]; then
    local lines; lines=$(wc -l < "$dir/HANDOFF.md" | tr -d ' ')
    printf '\nHOT HANDOFF from the previous sub-goal (verify before trusting):\n'
    if [ "$lines" -gt "$HANDOFF_MAX_LINES" ]; then
      head -n "$HANDOFF_MAX_LINES" "$dir/HANDOFF.md"
      printf '[... HANDOFF.md truncated at %s/%s lines; read the file for the rest]\n' "$HANDOFF_MAX_LINES" "$lines"
    else
      cat "$dir/HANDOFF.md"
    fi
  fi
  if [ -s "$dir/DECISIONS.md" ]; then
    local dlines; dlines=$(wc -l < "$dir/DECISIONS.md" | tr -d ' ')
    printf '\nWARM LEDGER: %s exists (%s lines) -- invariants + dead-ends. Read it on demand before re-deciding; it is NOT inlined here to keep this prompt lean.\n' "$dir/DECISIONS.md" "$dlines"
  fi
  # pi-swarm wording: the next session reads these records, not your transcript.
  # Per-edge WRITE target (SPEC-106 TASK-005): a sub-goal that HAS DEPENDENTS writes its own
  # HANDOFF-<id>.md so parallel siblings never clobber one hot file; a leaf / linear-tail keeps
  # writing plain HANDOFF.md, so the instruction stays byte-identical for the no-dependents case.
  local hf="HANDOFF.md"
  { [ -f "$roadmap" ] && _sg_dependents "$roadmap" "$id"; } && hf="HANDOFF-$id.md"
  printf '\nWhen you finish: report findings IN the records (overwrite %s with the next action + read-pointers as file:line; append durable invariants/dead-ends to DECISIONS.md), NOT only in your response text. The next sub-goal reads the files, not this transcript.\n' "$hf"
}

cmd_next() {
  local dir="${1:-}"
  [ -f "$dir/ROADMAP.md" ] || { echo "no ROADMAP.md in '$dir'" >&2; return 64; }
  _prune_streams "$dir"   # ID-095: age-cap sweep at the cheap, frequently-run "what's next" touchpoint
  local nx; nx=$(_next "$dir/ROADMAP.md")
  if [ -n "$nx" ]; then printf '%s\n' "$nx"; else _say "(none unchecked)"; fi
}

# cmd_flip <megadir> <id>: flip "- [ ] SG-NN" -> "- [x]" in the SHARED absolute-path
# `$megadir/ROADMAP.md` (never a per-sub-goal worktree copy: the driver only sees the shared one,
# SPEC-106 DEC-008), UNDER the flip lock, via write-temp-then-`mv` (atomic rename) so a concurrent
# reader/flip never sees a torn file. Idempotent: flipping an already-checked box is a no-op
# success. Unknown id -> nonzero + a clear message. NO scheduling is wired here (waves land later);
# this is the mutual-exclusion primitive the wave loop will call for grounded box-flips.
cmd_flip() {  # megadir id
  local megadir="${1:-}" id="${2:-}"
  [ -n "$megadir" ] && [ -n "$id" ] || { echo "usage: orchestrate.sh flip <megadir> <SG-NN>" >&2; return 64; }
  local roadmap="$megadir/ROADMAP.md"
  [ -f "$roadmap" ] || { echo "flip: no ROADMAP.md in '$megadir'" >&2; return 64; }
  [ -n "$(_sg_line "$roadmap" "$id")" ] || { echo "flip: unknown sub-goal '$id' in $roadmap" >&2; return 65; }

  local lockdir="$megadir/.orchestrate/flip.lock"
  _lock "$lockdir" || { echo "flip: could not acquire lock $lockdir" >&2; return 1; }

  # Re-read the line UNDER the lock: a sibling flip may have checked it since the pre-lock probe.
  local line rc=0
  line=$(_sg_line "$roadmap" "$id")
  case "$line" in
    '- ['[xX]']'*) _unlock "$lockdir"; return 0 ;;   # already checked -> idempotent no-op
  esac

  local tmp
  tmp=$(mktemp "$megadir/.roadmap.flip.XXXXXX" 2>/dev/null) || { _unlock "$lockdir"; echo "flip: mktemp failed" >&2; return 1; }
  if awk -v id="$id" '{ if ($0 ~ ("^- \\[ \\] " id " ")) sub(/\[ \]/, "[x]"); print }' "$roadmap" > "$tmp" && mv -f "$tmp" "$roadmap"; then
    _emit_event "$megadir" "$id" flip "box checked"
  else
    rc=1
    [ -e "$tmp" ] && mv -f "$tmp" "${TMPDIR:-/tmp}/flip-tmp.$$.$RANDOM" 2>/dev/null
    echo "flip: failed to write $roadmap" >&2
  fi
  _unlock "$lockdir"
  return "$rc"
}

# Pause after a completed sub-goal in --step mode. Reads ONE line from the driver's stdin (free:
# the prompt is fed to claude via a temp file, not here). Empty/y/c -> continue; q/n -> stop;
# EOF (no operator attached) -> stop (can't get consent, so don't march on). pi-swarm confirmAction.
_step_pause() {
  local id="$1" ans
  printf '[orchestrate] --step: %s done. [Enter]=continue  q=stop: ' "$id" >&2
  if ! IFS= read -r ans; then
    _say "[orchestrate] --step: stdin closed; stopping after $id."
    return 1
  fi
  case "$ans" in
    q|Q|n|N|quit|stop) _say "[orchestrate] --step: operator stopped after $id."; return 1 ;;
    *) return 0 ;;
  esac
}

# ---- Stream retention + redaction (ID-095) ----------------------------------------------------
# Verified reality (orchestrate-hardening NOTES advisor #3): `.orchestrate/*.stream.jsonl` files
# are NOT unbounded growth -- each is per-sub-goal-id and truncated (`: > "$slog"`) at the start of
# every run, so the SET is bounded by the sub-goal count, not by wall-clock time. The real risk is
# that a captured transcript (which can legitimately contain secret-shaped text -- an env var, a
# pasted token, an `op://` value a session echoed) SITS ON DISK indefinitely with no age cap and no
# redaction. Two independent, small mitigations, neither touching the stream FORMAT:
STREAM_RETENTION_DAYS="${STREAM_RETENTION_DAYS:-14}"

# Redact secret-shaped substrings from a captured stream/session-log file, IN PLACE, via a
# write-temp-then-`mv` (never `sed -i`: GNU vs BSD `-i` take incompatible args, and an in-place
# edit that dies mid-write must not truncate the original). Applied right after each write
# completes (both `_run_one_session`'s stream-json/plain paths and `_run_session_watchdog`'s
# capture path), so the window a secret sits UNREDACTED on disk is one session's write, not
# indefinite. Best-effort: a missing/empty file or a `mktemp`/`sed` failure is a silent no-op
# (redaction failing must never fail the sub-goal it is auxiliary to). Patterns cover the common
# API-key/token shapes (OpenAI/Anthropic/GitHub/GitLab/Slack `PREFIX-`/`PREFIX_` tokens, AWS access
# keys, bearer tokens) -- deliberately conservative (over-redact, never under-redact) since this is
# a leak-prevention control, not a display filter.
_redact_secrets_file() {  # file
  local f="$1" tmp
  [ -n "$f" ] && [ -s "$f" ] || return 0
  tmp=$(mktemp 2>/dev/null) || return 0
  if sed -E \
      -e 's/(sk|gho|ghp|ghu|ghs|ghr|glpat)[_-][A-Za-z0-9_-]{8,}/[REDACTED]/g' \
      -e 's/xox[baprs]-[A-Za-z0-9-]{8,}/[REDACTED]/g' \
      -e 's/AKIA[0-9A-Z]{16}/[REDACTED]/g' \
      -e 's/([Bb]earer)[[:space:]]+[A-Za-z0-9._-]{10,}/\1 [REDACTED]/g' \
      "$f" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

# Prune `.orchestrate/*.stream.jsonl` and `*.session.log` files older than $STREAM_RETENTION_DAYS
# (mtime-based; portable `find -mtime +N`, no GNU-only flags). Advisory sweep, called at natural
# low-frequency touchpoints (`cmd_next`, the read-only "what's next" check an operator runs often,
# and the start of a `cmd_run`), not a daemon -- a mega-goal dir that is never polled just keeps
# its (still-bounded-by-count) files a while longer, never a correctness issue. Silent on a missing
# `.orchestrate` dir (nothing to prune yet).
_prune_streams() {  # dir
  local dir="$1" n
  local logdir="$dir/.orchestrate"
  [ -d "$logdir" ] || return 0
  n=$(find "$logdir" -maxdepth 1 \( -name '*.stream.jsonl' -o -name '*.session.log' \) -mtime "+${STREAM_RETENTION_DAYS}" 2>/dev/null | wc -l | tr -d ' ')
  [ "${n:-0}" -gt 0 ] 2>/dev/null || return 0
  find "$logdir" -maxdepth 1 \( -name '*.stream.jsonl' -o -name '*.session.log' \) -mtime "+${STREAM_RETENTION_DAYS}" -exec rm -f {} + 2>/dev/null
  _say "[orchestrate] [retention] pruned $n stream/session file(s) older than ${STREAM_RETENTION_DAYS}d from $logdir"
}

# Run a session under the stall-watchdog (SG-11). Backgrounds claude (output -> a session log),
# polls liveness (`kill -0`, no daemon) + the log's mtime; after WATCHDOG_STALL_SECS of no new
# output while the process is still alive, emits a `stalled` event + WARN ONCE (advisory: never
# kills). Returns the session's exit code. The captured output is surfaced after completion.
#
# Token accounting (ID-097): before this fix, the watchdog branch NEVER exposed a slog to its
# caller, so `_record_tokens` always no-op'd on a stalled/watchdog-run session -- a stall was an
# accounting black hole, not just an event. Fix: when a capture was actually requested (`capture`
# param = 1, mirroring `_run_one_session`'s own stream/DETERMINISTIC_HANDOFF/CAPTURE_TOKENS gate),
# run claude with the SAME `--output-format stream-json` the non-watchdog capture path already
# uses, into the SAME deterministic filename (`$dir/.orchestrate/${id}.stream.jsonl`) the wave
# reap loop already recomputes -- no new format invented, no new file convention invented. The
# stall-watchdog only needs a file whose mtime advances; jsonl satisfies that exactly like the
# plain log did. Result exposed via the global `_WD_SLOG` (bash 3.2 has no other clean way to
# return a string from a backgrounded function). The DEFAULT (capture=0) path is byte-identical
# to before: plain `.session.log`, no slog surfaced, `_WD_SLOG` left empty.
_run_session_watchdog() {  # dir id pfile route_flags capture
  local dir="$1" id="$2" pfile="$3" rflags="$4" capture="${5:-0}"
  local logdir="$dir/.orchestrate"; mkdir -p "$logdir"
  local slog
  if [ "$capture" = 1 ]; then
    slog="$logdir/${id}.stream.jsonl"
  else
    slog="$logdir/${id}.session.log"
  fi
  : > "$slog"
  _say "[orchestrate] [watchdog] $id: output -> $slog (stall=${WATCHDOG_STALL_SECS}s, poll=${WATCHDOG_POLL_SECS}s; advisory, never kills)"
  if [ "$capture" = 1 ]; then
    # shellcheck disable=SC2086 # rflags + CLAUDE_FLAGS are operator/goal config; word-splitting is intended.
    { "$CLAUDE_CMD" -p $rflags --output-format stream-json --verbose $CLAUDE_FLAGS < "$pfile" > "$slog" 2>&1; } &
  else
    # shellcheck disable=SC2086 # rflags + CLAUDE_FLAGS are operator/goal config; word-splitting is intended.
    { "$CLAUDE_CMD" -p $rflags $CLAUDE_FLAGS < "$pfile" > "$slog" 2>&1; } &
  fi
  local spid=$! warned=0 now last age
  while kill -0 "$spid" 2>/dev/null; do
    sleep "$WATCHDOG_POLL_SECS"
    kill -0 "$spid" 2>/dev/null || break
    now=$(date +%s); last=$(_mtime "$slog"); [ -n "$last" ] || last=$now; age=$((now - last))
    if [ "$age" -ge "$WATCHDOG_STALL_SECS" ] && [ "$warned" = 0 ]; then
      warned=1
      _emit_event "$dir" "$id" stalled "no output for ${age}s (pid $spid alive)"
      echo "[orchestrate] [watchdog] WARN: $id stalled -- no output for ${age}s, pid $spid still alive. Not killing (advisory); tail $slog." >&2
    fi
  done
  wait "$spid"; local rc=$?
  _redact_secrets_file "$slog"   # ID-095: redact before it's surfaced (cat) or returned to the caller
  cat "$slog"
  _WD_SLOG=""
  [ "$capture" = 1 ] && _WD_SLOG="$slog"
  return "$rc"
}

# Run ONE sub-goal on a NON-CLAUDE harness (ID-390). Split out of `_run_one_session` rather than
# folded into its if/elif chain so the claude path keeps exactly the shape 178 existing assertions
# already pin; this function is only ever reached when a goal file explicitly says `Harness:`.
#
# Plain path ONLY, deliberately. The other two run-paths both require `--output-format stream-json
# --verbose`, which is a Claude-CLI spelling with no portable equivalent, so --stream / the
# deterministic handoff / lean token capture cannot work here. Those are OBSERVABILITY features, not
# correctness ones, so per the house convention (advisory failures WARN+continue; only
# grounded-completion / gate / nonzero-session failures halt) this WARNs once and degrades instead of
# refusing to dispatch -- a globally-set CAPTURE_TOKENS=1 must not become a wall that blocks every
# non-claude sub-goal. The WARN is what keeps it from being the silent accounting black hole ID-097
# closed on the watchdog path.
#
# Grounded completion is UNAFFECTED and still the real done-signal: the caller re-reads ROADMAP.md
# for the flipped checkbox regardless of vendor, so a non-claude session cannot self-claim done
# either. That property is vendor-independent by construction, which is precisely why it is the
# signal worth trusting.
_run_one_session_vendor() {  # dir id pfile harness stream
  local dir="$1" id="$2" pfile="$3" harness="$4" stream="$5"
  local rc=0 gf model effort pmode t route_out route_rc prompt
  local argv=()

  gf=$(_goalfile "$dir" "$id")
  # Check `_route`'s exit code (review, 2026-07-22): the old `... < <(_route) || true` swallowed a
  # routing failure and dispatched with empty model/effort -- a fail-open in a fail-closed feature.
  # `_route` rejects an unknown/not-enabled harness AND an off-charset Effort; any of those must
  # hard-stop here too, not degrade silently. (The wired path also gates via _harness_of upstream,
  # but this function must defend itself for any direct caller.)
  route_out=$(_route "$gf"); route_rc=$?
  [ "$route_rc" = 0 ] || { echo "[orchestrate] $id: routing rejected (see the 'orchestrate:' reason above); not dispatching to '$harness'." >&2; return 64; }
  IFS=$'\t' read -r model effort <<<"$route_out"

  # Degrade WARN. `WATCHDOG_STALL_SECS` is included (review): the vendor path cannot run the SG-11
  # stall watchdog either (it needs the same stream-json capture the vendor CLIs lack), so an
  # operator running with the watchdog on must be told this sub-goal is exempt -- not left to assume
  # every session is monitored. Same advisory-WARN posture as the other lost observability features.
  if [ "$stream" = 1 ] || [ "$DETERMINISTIC_HANDOFF" = 1 ] || [ "$CAPTURE_TOKENS" = 1 ] || [ "$WATCHDOG_STALL_SECS" -gt 0 ]; then
    echo "[orchestrate] WARN $id: harness '$harness' has no stream-json equivalent; running the plain path (no live tail, no deterministic handoff, no token capture, no stall watchdog for this sub-goal)." >&2
  fi

  while IFS= read -r t; do argv+=("$t"); done < <(harness_argv "$harness" "$model" "$effort")
  [ "${#argv[@]}" -gt 0 ] || { echo "[orchestrate] $id: harness '$harness' resolved to an empty argv; not dispatching" >&2; return 64; }
  pmode=$(harness_prompt_mode "$harness") || return 64

  _say "[orchestrate] $id -> harness '$harness' (${model:-default model}${effort:+, $effort}), prompt via $pmode"
  # The prompt is delivered per the adapter's declared mode. Getting this wrong does not error, it
  # runs the agent with an EMPTY prompt and exits 0 -- a clean-looking run that did nothing -- which
  # is why the mode is data the adapter owns rather than a guess made here.
  case "$pmode" in
    stdin) "${argv[@]}" < "$pfile" || rc=$? ;;
    argv)
      # Leading-newline guard (review HIGH, 2026-07-22): the prompt is a trailing positional here, so
      # if its first char is `-` (a benign `---` markdown rule atop POINTER_PROMPT.md, or a hostile
      # line) the vendor's arg parser reads it as an OPTION -- the silent "empty prompt, exit 0"
      # class, or worse an injected flag. Prepending a newline makes the arg never start with `-`; a
      # leading blank line is inert to an LLM. Verified on the installed pi + opencode. NOT `--`: pi
      # rejects the end-of-options sentinel (`Unknown option: --`), so the newline guard is the
      # portable equivalent. Ceiling: relies on the CLI treating `arg[0]=='-'` as an option marker
      # (both do); a future vendor that differs needs a per-vendor delivery branch.
      prompt=$'\n'"$(cat "$pfile")"
      "${argv[@]}" "$prompt" || rc=$? ;;
    *)     echo "[orchestrate] $id: unknown prompt mode '$pmode'" >&2; return 64 ;;
  esac
  _ROS_SLOG=""   # no transcript capture on this path; the caller's token/handoff hooks are slog-gated
  return "$rc"
}

# _run_one_session: run ONE sub-goal session via the correct mutually-exclusive run-path
# (SG-11 watchdog / --stream|DETERMINISTIC_HANDOFF stream-json / plain claude -p). Keyed on
# `dir id pfile route_flags stream` (stream is a cmd_run local, so it is passed explicitly).
# Returns the session exit code; exposes the stream-log path via the global _ROS_SLOG so the
# caller can wire post-session logic (grounded completion, deterministic handoff) to it. Extracted
# from cmd_run (TASK-000) so the serial and wave paths share ONE copy and the three run-paths are
# never forked. Zero behavior change vs the former inline block.
_run_one_session() {  # dir id pfile route_flags stream
  local dir="$1" id="$2" pfile="$3" route_flags="$4" stream="$5"
  # --stream (opt-in observability): emit stream-json and tee it to a per-sub-goal capture so
  # the operator sees a live tail AND the run is recorded. Off -> the default invocation is
  # byte-identical (no pipe, no tee). pipefail (set at top) keeps the `if ! ... | tee` honest.
  local rc=0 slog="" wd_capture=0

  # ID-390 multi-vendor branch. The harness is re-read from the goal file here rather than threaded
  # in as a 6th positional, because `route_flags` reaches this function through FOUR call sites
  # (serial cmd_run, the wave subshell, _pane_spawn, cmd_pane_exec) and widening all of them for one
  # string would be a far larger diff than one grep. A non-claude sub-goal takes the plain path only.
  local _h; _h=$(_harness_of "$(_goalfile "$dir" "$id")") || return 64
  if [ "$_h" != claude ]; then
    _run_one_session_vendor "$dir" "$id" "$pfile" "$_h" "$stream"
    return $?
  fi
  # Everything below is the ORIGINAL claude path, untouched: `$CLAUDE_CMD` stays the mock seam every
  # pre-existing test drives, so an absent `Harness:` header is byte-for-byte the old behavior.
  if [ "$WATCHDOG_STALL_SECS" -gt 0 ]; then
    # SG-11 watchdog path (opt-in). Token accounting (ID-097): mirror the same capture gate the
    # non-watchdog elif below uses, so a stall no longer silently drops the sub-goal's tokens (the
    # accounting-black-hole gap `_run_session_watchdog`'s own header comment used to describe).
    # `_WD_SLOG` (set by `_run_session_watchdog`) feeds `_ROS_SLOG` below exactly like the elif's
    # local `slog` does, so the CALLER (cmd_run's `_record_tokens "$dir" "$id" "$slog"`, and the
    # wave reap loop's recomputed `${id}.stream.jsonl` path) needs zero further changes.
    [ "$stream" = 1 ] || [ "$DETERMINISTIC_HANDOFF" = 1 ] || [ "$CAPTURE_TOKENS" = 1 ] && wd_capture=1
    _run_session_watchdog "$dir" "$id" "$pfile" "$route_flags" "$wd_capture" || rc=$?
    slog="$_WD_SLOG"
  elif [ "$stream" = 1 ] || [ "$DETERMINISTIC_HANDOFF" = 1 ] || [ "$CAPTURE_TOKENS" = 1 ]; then
    # Capture stream-json when the operator wants a live tail (--stream) OR the deterministic
    # handoff needs the transcript (DETERMINISTIC_HANDOFF=1) OR lean token capture is on
    # (CAPTURE_TOKENS=1, SPEC-117). The live `tee` to the terminal happens ONLY under --stream;
    # det-handoff and capture-tokens both take the SILENT `> "$slog"` branch below, so the child
    # transcript lands in the FILE only and never reaches the conductor's stdout (ADR-0032 s3).
    local logdir="$dir/.orchestrate"; mkdir -p "$logdir"
    slog="$logdir/${id}.stream.jsonl"
    # shellcheck disable=SC2086 # CLAUDE_FLAGS + route_flags are operator/goal config; word-splitting is intended.
    if [ "$stream" = 1 ]; then
      _say "[orchestrate] streaming $id -> $slog (live tail + captured)"
      "$CLAUDE_CMD" -p $route_flags --output-format stream-json --verbose $CLAUDE_FLAGS < "$pfile" | tee "$slog" || rc=$?
    else
      # ponytail: fd1-only redirect. The transcript (the ADR-0032 accumulation trap) is claude's
      # STDOUT and goes to the file; `--verbose` STDERR (diagnostic, no usage/turn content) is left
      # on fd2. Redirecting stderr too (`2>...`) is a deferred hardening for a stdout+stderr-merging
      # conductor invocation -- skipped because it would also silence real error output on this opt-in
      # path, and the driver is non-LLM bash so stderr is not an accumulation vector.
      "$CLAUDE_CMD" -p $route_flags --output-format stream-json --verbose $CLAUDE_FLAGS < "$pfile" > "$slog" || rc=$?
    fi
  else
    # shellcheck disable=SC2086 # CLAUDE_FLAGS + route_flags are operator/goal config; word-splitting is intended.
    "$CLAUDE_CMD" -p $route_flags $CLAUDE_FLAGS < "$pfile" || rc=$?
  fi
  # ID-095: redact secret-shaped substrings from the captured file before it's handed back (the
  # live `--stream` terminal tee above already happened by this point -- redacting the FILE closes
  # the at-rest exposure, the primary risk this fix targets; a live-tee filter would need a
  # process-substitution rewrite of the stream FORMAT plumbing, out of scope for this sweep).
  [ -n "$slog" ] && _redact_secrets_file "$slog"
  _ROS_SLOG="$slog"
  return "$rc"
}

# ---- Wavefront spawn/reap primitive (SPEC-106 TASK-004a, DEC-005) -----------------------------
# The concurrent-wave engine: take the admitted `run` set, run those sub-goals concurrently (each in
# its OWN worktree), reap on completion, drain safely on a sibling failure. bash-3.2 throughout: no
# assoc arrays (the reap map is index-aligned plain arrays), no `wait -n` (poll `kill -0` like
# `_run_session_watchdog`), no `flock`. Standalone-testable with a MOCK CLAUDE_CMD; wiring into
# cmd_run (size-dispatch on admitted count) is the NEXT task (TASK-004b), so `_wave_run` has ZERO
# call sites in the run loop after this task.

# A sub-goal's declared branch from its goal file's `**Branch:** <type>/<slug>` header (same parse
# as `_emit_start`), or a stable `wave/<id-lower>` fallback when absent so a worktree can still be
# stood up. One branch per sub-goal id => distinct branches => no "already checked out" clash.
_sg_branch() {  # goalfile id
  local gf="${1:-}" id="$2" branch=""
  [ -n "$gf" ] && [ -f "$gf" ] && branch=$(grep -iE '^\*\*Branch:\*\*' "$gf" | head -1 | sed -E 's/^\*\*[Bb]ranch:\*\*[[:space:]]*//; s/[[:space:]].*$//')
  [ -n "$branch" ] || branch="wave/$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')"
  printf '%s\n' "$branch"
}

# Atomically reserve ONE SPEC number for a wave sub-goal at dispatch (SPEC-128), so a
# concurrent wave cannot hand the same number to two workers. Delegates to `spec-next.sh
# reserve` (mkdir-mutex + reservation ledger folded into the scan). Best-effort by contract:
# on any failure it echoes nothing and returns nonzero, and the caller degrades to letting
# the worker compute its own number , the reservation is an optimization over a correct scan,
# never a new hard dependency that could wedge the wave. `$SPEC_NEXT_CMD` overrides the binary
# for tests (a mock). Echoes the reserved SPEC number (e.g. 128); empty on failure.
_wave_reserve_spec() {
  local sn="${SPEC_NEXT_CMD:-$LIB_ROOT/spec/spec-next.sh}" n
  [ -x "$sn" ] || [ -r "$sn" ] || return 1
  n="$(bash "$sn" reserve 2>/dev/null)" || return 1
  n="$(printf '%s' "$n" | grep -oE '^[0-9]+$' | head -1)"
  [ -n "$n" ] || return 1
  printf '%s\n' "$n"
}

# Create OR reuse a per-sub-goal worktree at <repo>/.claude/worktrees/<id> on <branch> (the repo-wide
# worktree location, per the global worktree rule). REUSE only on a clean crash-resume (edge 5): the
# path is already a REGISTERED git worktree, its tree is clean, AND it is on <branch>. Otherwise
# RECREATE. NEVER a blind `git worktree add` onto an existing path: a stale/dirty/mismatched worktree
# is dropped with `git worktree remove --force` (git's own remover, which refuses paths outside its
# admin list), and a leftover NON-worktree dir is moved aside (never `rm -rf`). Prunes stale admin
# entries first so a dir removed out-of-band cannot wedge `worktree add`. Echoes the worktree path;
# nonzero on failure.
_wave_worktree() {  # repo id branch
  local repo="$1" id="$2" branch="$3"
  local wt="$repo/.claude/worktrees/$id"
  git -C "$repo" worktree prune 2>/dev/null || true

  if [ -e "$wt/.git" ]; then
    # A linked worktree carries a `.git` FILE (a gitdir pointer). Clean + on <branch> => resume.
    local dirty cur
    dirty=$(git -C "$wt" status --porcelain 2>/dev/null)
    cur=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ -z "$dirty" ] && [ "$cur" = "$branch" ]; then
      printf '%s\n' "$wt"; return 0
    fi
    git -C "$repo" worktree remove --force "$wt" 2>/dev/null || true
  elif [ -e "$wt" ]; then
    # non-worktree collision at the path (leftover from a crash): move aside, never delete.
    mv -f "$wt" "${TMPDIR:-/tmp}/wave-wt-stale.$id.$$.$RANDOM" 2>/dev/null || true
  fi
  git -C "$repo" worktree prune 2>/dev/null || true

  mkdir -p "$repo/.claude/worktrees" 2>/dev/null || true
  # Reuse the branch if it already exists (a resume that lost only its checkout), else create it
  # off HEAD.
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$repo" worktree add "$wt" "$branch" >/dev/null 2>&1 || return 1
  else
    git -C "$repo" worktree add -b "$branch" "$wt" >/dev/null 2>&1 || return 1
  fi
  printf '%s\n' "$wt"
}

# ---- Multiplexer panes (SPEC-119, ADR-0032 s4) ------------------------------------------------
# The per-megagoal tmux session name a wave's panes live in: $TMUX_SESSION if the operator set
# one, else derived from the megadir's basename (sanitized to tmux-safe chars). Pure function.
_mux_session_name() {  # megadir
  [ -n "${TMUX_SESSION:-}" ] && { printf '%s\n' "$TMUX_SESSION"; return 0; }
  local base; base=$(basename "$(cd "$1" 2>/dev/null && pwd || printf '%s' "$1")")
  printf 'orch-%s\n' "$(printf '%s' "$base" | tr -c 'A-Za-z0-9_-' '-')"
}

# Spawn ONE wave sub-goal's REAL session inside a tmux window (visibility + intervention, ADR-0032
# s4) instead of a plain backgrounded job. `tmux new-window` cannot call a bash function in THIS
# process -- it execs a fresh command line -- so the pane re-enters `orchestrate.sh` via the hidden
# `_pane-exec` subcommand, which runs the exact same `_run_one_session` the plain path uses (no
# duplicated dispatch logic). Ensures the shared per-megagoal tmux session exists first (`has-session`
# else `new-session -d`, so the first pane doesn't need a pre-existing session). `tmux new-window`
# returns as soon as the window is created, before the pane's command exits, so a pid-based `wait`
# in the caller cannot observe its completion; the pane's command writes its exit code to
# `$donefile` instead (the caller's reap loop polls for that file). Mockable via `$TMUX_CMD`;
# nonzero on any tmux failure (missing binary, no server, etc.).
#
# spec-validate finding (Failure Mode Analyst): a sub-goal whose PREVIOUS wave attempt failed
# (session exited nonzero / crashed) leaves its named window sitting in the shared per-megagoal
# tmux session -- nothing kills a completed pane's window on the normal path (only `_wave_abort`
# kills windows, and only still-in-flight ones on an operator Ctrl-C). A retry (`_wave_gate`
# re-admits an unchecked box on the next `orchestrate.sh run`) would then `new-window -n "$id"`
# a SECOND window sharing that name, and tmux's `session:name` target resolution is not
# guaranteed to pick the new one -- `capture-pane`/`send-keys` could address the stale pane.
# Pre-clean idempotently (mirrors `_wave_worktree`'s reuse-clean-else-recreate stance for
# worktrees): a no-op `|| true` when no such window exists yet.
_pane_spawn() {  # megadir id wt pfile route_flags donefile
  local megadir="$1" id="$2" wt="$3" pfile="$4" route_flags="$5" donefile="$6"
  local mux; mux=$(_mux_session_name "$megadir")
  "$TMUX_CMD" has-session -t "$mux" 2>/dev/null || "$TMUX_CMD" new-session -d -s "$mux" -n _init 2>/dev/null || return 1
  "$TMUX_CMD" kill-window -t "$mux:$id" 2>/dev/null || true
  # SECURITY (SPEC-119 fix): pass the pane command as SEPARATE argv tokens after `--`, never a
  # single joined string. tmux hands a lone command STRING to `$SHELL -c`, a second shell parse
  # (an eval); with the multi-arg form it execs directly, no re-parse. `route_flags` is built from
  # the goal file's unsanitized `Model:`/`Effort:` header, so the joined form was a host command
  # injection reachable via a hostile mega-goal PR under MULTIPLEXER=1. It stays ONE argv token so
  # cmd_pane_exec still receives 5 positional args (route_flags splits later, non-mux path parity).
  "$TMUX_CMD" new-window -d -t "$mux" -n "$id" -c "$wt" -- \
    "$ORCH_DIR/orchestrate.sh" _pane-exec "$megadir" "$id" "$pfile" "$route_flags" "$donefile"
}

# Read a wave session's live pane output (the visibility half of the Proof: "a capture-pane read
# returns the wave session's live output"). `-p` prints to stdout; `-t <mux>:<id>` addresses the
# window by name (unique per megagoal wave, one window per sub-goal id).
_pane_capture() {  # megadir id
  local mux; mux=$(_mux_session_name "$1")
  "$TMUX_CMD" capture-pane -p -t "$mux:$2" 2>/dev/null
}

# Send keys into a wave session's pane (the control/intervene half of the Proof) -- e.g. an
# operator nudging a stuck session or Ctrl-C-ing it directly in its own pane.
_pane_send_keys() {  # megadir id keys...
  local megadir="$1" id="$2"; shift 2
  local mux; mux=$(_mux_session_name "$megadir")
  "$TMUX_CMD" send-keys -t "$mux:$id" "$@"
}

# ---- Pane viewer push (SPEC-121) ----------------------------------------------------------------
# The push half of SPEC-119's pull-only panes: on wave spawn, open ONE viewer tab/surface in the
# operator's terminal app, attached to the wave's tmux session. Three functions: a pure env
# detector, a mode resolver, and the best-effort opener. See the PANE_VIEWER env block up top.

# TTY probe, its own function so tests can override it after sourcing (CI has no TTY, so the
# positive auto-detect path would otherwise be untestable). Stderr, not stdout: an operator
# piping `run` output still has a terminal on stderr; a headless harness has neither.
_viewer_tty() { [ -t 2 ]; }

# Pure env sniff -> the running viewer's name, or nothing. Order is load-bearing: cmux embeds a
# terminal that sets $TERM_PROGRAM too, so the cmux env must win (SPEC-121 edge case 1).
_viewer_detect() {
  if [ -n "${CMUX_WORKSPACE_ID:-}" ]; then printf 'cmux\n'; return 0; fi
  case "${TERM_PROGRAM:-}" in
    iTerm.app)      printf 'iterm\n'; return 0 ;;
    ghostty)        printf 'ghostty\n'; return 0 ;;
    WezTerm)        printf 'wezterm\n'; return 0 ;;
    Apple_Terminal) printf 'terminal\n'; return 0 ;;
  esac
  [ -n "${KITTY_WINDOW_ID:-}" ] && { printf 'kitty\n'; return 0; }
  return 0
}

# PANE_VIEWER mode -> the effective viewer (or `none`). `auto` degrades SILENTLY to none when
# stderr is not a TTY or nothing is detected (headless CI byte-identical -- the named negative
# control). An explicit name is operator intent and skips the TTY gate (DEC-005). An unknown
# value maps to none here (defense-in-depth; cmd_run's pre-flight already rejected it loudly).
_viewer_resolve() {
  case "$PANE_VIEWER" in
    none) printf 'none\n' ;;
    auto)
      if _viewer_tty; then
        local d; d=$(_viewer_detect)
        printf '%s\n' "${d:-none}"
      else
        printf 'none\n'
      fi ;;
    cmux|kitty|wezterm|ghostty|iterm|terminal) printf '%s\n' "$PANE_VIEWER" ;;
    *) printf 'none\n' ;;
  esac
}

# Exec seam for the viewer argv, mirroring $TMUX_CMD/$CLAUDE_CMD: VIEWER_CMD set -> the mock
# receives the FULL argv (binary name first) so tests assert both the pick and the exact
# arguments; unset -> exec the argv DIRECTLY ("$@": no string join, no `$SHELL -c` re-parse --
# the SPEC-119 #143 exec-direct pattern). Missing real binary -> nonzero (caller warns).
_viewer_exec() {
  if [ -n "$VIEWER_CMD" ]; then "$VIEWER_CMD" "$@"; return $?; fi
  command -v "$1" >/dev/null 2>&1 || return 127
  "$@" </dev/null >/dev/null 2>&1
}

# Open ONE viewer surface attached to the wave's tmux session. Best-effort by contract: ALWAYS
# returns 0 (a viewer is a visibility affordance; its failure must never mark the wave failed,
# DEC-003). The exec itself is FIRE-AND-FORGET (backgrounded + disowned; review fix, architecture
# P1): the osascript paths can block indefinitely on a first-run macOS Automation permission
# dialog ("Terminal wants to control iTerm"), and a synchronous call here sits inside
# `_wave_run`'s spawn loop, where a hang would stall every subsequent sub-goal -- exactly the
# blocking-call class SG-11's watchdog exists for. `disown` drops the job from the shell's job
# table so `_wave_abort`'s bare `wait` can never block on a hung viewer either. Reuse guard: one
# attempt per tmux session name per run (`_VIEWER_OPENED`, a space-separated list -- bash 3.2 has
# no assoc arrays), success or not, so a persistently broken viewer warns once instead of once
# per wave. The guard key is a SANITIZED copy of the name (review fix: a raw operator
# $TMUX_SESSION with an embedded space must not taint the space-separated list), so once-per-run
# holds even for a name the charset gate below refuses. SECURITY: the session name is
# charset-gated to `[A-Za-z0-9_-]` before any argv is built -- `_mux_session_name` already
# sanitizes derived names, but an operator-set $TMUX_SESSION bypasses that sanitize, and two
# viewer sinks are string contexts downstream of us (cmux --command types into a shell; Terminal
# `do script` runs a shell line). The osascript paths pass the name as an osascript ARGV item
# (`on run argv`), never spliced into the AppleScript source. cmux: `new-surface` takes no
# command argument (CLI-verified), so the cmux path is `new-workspace --command`; `--focus
# false` is pinned -- `--focus true` into the controlling session's own pane is a known cmux
# RPC wedge.
_viewer_open() {  # megadir
  local viewer; viewer=$(_viewer_resolve)
  [ -n "$viewer" ] && [ "$viewer" != none ] || return 0
  local mux; mux=$(_mux_session_name "$1")
  local key; key=$(printf '%s' "$mux" | tr -c 'A-Za-z0-9_-' '-')
  case " ${_VIEWER_OPENED:-} " in *" $key "*) return 0 ;; esac
  _VIEWER_OPENED="${_VIEWER_OPENED:-}${_VIEWER_OPENED:+ }$key"
  case "$mux" in
    ''|*[!A-Za-z0-9_-]*)
      echo "[orchestrate] [viewer] session name '$mux' fails the [A-Za-z0-9_-] charset gate; refusing to hand it to a viewer (pull still works: tmux attach -t '<session>')." >&2
      return 0 ;;
  esac
  # Build the argv positionally (bash-3.2-friendly), then hand it to the backgrounded exec.
  case "$viewer" in
    cmux)     set -- cmux new-workspace --name "orch:$mux" --command "tmux attach -t $mux" --focus false ;;
    kitty)    set -- kitty @ launch --type=tab tmux attach -t "$mux" ;;
    wezterm)  set -- wezterm cli spawn -- tmux attach -t "$mux" ;;
    ghostty)  set -- open -na Ghostty --args -e tmux attach -t "$mux" ;;
    iterm)    set -- osascript -e 'on run argv' -e 'tell application "iTerm" to create window with default profile command ("tmux attach -t " & item 1 of argv)' -e 'end run' "$mux" ;;
    terminal) set -- osascript -e 'on run argv' -e 'tell application "Terminal" to do script ("tmux attach -t " & item 1 of argv)' -e 'end run' "$mux" ;;
    *) return 0 ;;
  esac
  (
    if _viewer_exec "$@"; then
      _say "[orchestrate] [viewer] opened a $viewer surface attached to tmux session '$mux' (PANE_VIEWER=$PANE_VIEWER)."
    else
      echo "[orchestrate] [viewer] $viewer open failed (rc $?); degrading to pull for this run (tmux attach -t '$mux' by hand still works)." >&2
    fi
  ) &
  disown 2>/dev/null || true
  return 0
}
# -----------------------------------------------------------------------------------------------

# ---- Subagent panes (SPEC-234) ------------------------------------------------------------------
# The DEFAULT mega-goal run mode dispatches sub-goals as parallel background SUBAGENTS via the
# conductor's own Agent tool (commands/mega.md "Run mode"), not through this driver's dispatch
# loop -- there is nothing here to hook (`_wave_run` only runs under DELEGATE mode). `panes` is a
# one-shot subcommand the conductor shells out to after dispatching, so a background subagent's
# live JSONL transcript (`~/.claude/projects/<slug>/<session>/subagents/agent-<id>.jsonl`) gets a
# READ-ONLY tmux pane the operator can watch (`tmux attach`). Read-only by construction (the
# pane's process tree is `tail | jq`, no shell, no REPL); steering still routes through the
# conductor (SendMessage), never the pane -- see SPEC-234 "Out of scope".

# Slugify a cwd the way the harness names `~/.claude/projects/<slug>` dirs: EACH '/' and '.'
# character becomes '-' individually (not collapsed) -- verified against a live worktree project
# dir (".claude/worktrees/x" -> "--claude-worktrees-x": the double dash is '/' then '.' adjacent).
_panes_project_slug() {  # path
  printf '%s' "$1" | tr '/.' '-'
}

# `--latest`: the conductor cannot name its own dispatched subagents' transcript paths (the Agent
# tool returns none, DEC-007), so this derives them -- slugify $PWD, then pick the newest-mtime
# `subagents/` dir among that project's session dirs. Pure + fake-$HOME testable (T4). Prints
# nothing (rc 0) on a clean miss (no such project/session yet) -- the caller warns and moves on,
# no error.
_panes_latest_subagents_dir() {
  local slug proj d mt newest="" newest_mt=0
  slug=$(_panes_project_slug "$PWD")
  proj="$HOME/.claude/projects/$slug"
  [ -d "$proj" ] || return 0
  for d in "$proj"/*/subagents; do
    [ -d "$d" ] || continue
    mt=$(_mtime "$d"); [ -n "$mt" ] || mt=0
    if [ -z "$newest" ] || [ "$mt" -gt "$newest_mt" ]; then newest="$d"; newest_mt="$mt"; fi
  done
  [ -n "$newest" ] && printf '%s\n' "$newest"
  return 0
}

# Expand a directory target into its `agent-*.jsonl` members, one per line (none found: warn,
# move on -- this is the ONLY place an empty-dir warning fires; it is separate from cmd_panes's
# own per-candidate skip tally below, since an empty dir resolves to zero candidates).
_panes_expand_dir() {  # dir
  local dir="$1" f any=0
  for f in "$dir"/agent-*.jsonl; do
    [ -e "$f" ] || continue
    any=1
    printf '%s\n' "$f"
  done
  [ "$any" = 1 ] || echo "[panes] $(_panes_show "$dir"): no agent-*.jsonl transcripts found (empty dir)" >&2
}

# Expand every `panes` <target> arg into candidate jsonl paths (one per line, UNVALIDATED --
# cmd_panes does the readable/regular/basename gate per candidate so every skip reason reports at
# one place). A directory expands via `_panes_expand_dir`; anything else (a file path, or an
# unexpanded `agent-*.jsonl` glob literal with no shell match) passes through untouched so
# cmd_panes's own existence check reports the clean skip.
_panes_resolve_targets() {  # target...
  local t dir
  for t in "$@"; do
    case "$t" in
      --latest)
        dir=$(_panes_latest_subagents_dir)
        if [ -z "$dir" ]; then
          echo "[panes] --latest: no subagents directory found under \$HOME/.claude/projects/<slug>/*/subagents; skipping" >&2
          continue
        fi
        _panes_expand_dir "$dir" ;;
      *)
        if [ -d "$t" ]; then _panes_expand_dir "$t"; else printf '%s\n' "$t"; fi ;;
    esac
  done
}

# Absolute-normalize an existing file path (a leading-dash or relative path must never reach a
# downstream command's arg parser as an untrusted argv token). Fails if its directory can't be
# resolved.
_panes_abspath() {  # file-path
  local d b ad
  d=$(dirname -- "$1"); b=$(basename -- "$1")
  ad=$(cd -- "$d" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$ad" "$b"
}

# `agent-<id>.jsonl` -> `sa-<id>`, charset-gated the same way `_mux_session_name` sanitizes a
# derived name (DEC-004: the `sa-` prefix namespaces subagent panes away from mega.md's `SG-NN`
# sub-goal windows, and guarantees the name is never all-digits, which tmux would resolve as a
# window INDEX rather than a name).
_panes_window_name() {  # jsonl-path
  local base id
  base=$(basename -- "$1"); id="${base#agent-}"; id="${id%.jsonl}"
  printf 'sa-%s\n' "$(printf '%s' "$id" | tr -c 'A-Za-z0-9_-' '-')"
}

# Render-side counterpart of the formatter's own viz strip (SPEC-119 pane-tail.jq): a target path
# is SUBAGENT-INFLUENCED data (the conductor names its own transcript files), so an operator
# WARNING that echoes it verbatim would put an attacker-chosen ESC/OSC byte sequence straight onto
# the operator's real terminal (window-NAME charset gates like `_panes_window_name` above already
# block this for tmux window names; this is the same gate for the plain `_say`/`echo` messages
# that were never charset-restricted). Strip to a safe display charset -- never used on an argv
# value handed to tmux/tail/jq, only on strings a human reads.
_panes_show() { printf '%s' "$1" | tr -c 'A-Za-z0-9_./ -' '?'; }

# `orchestrate.sh panes <megadir> <target>...` (public). Grows one read-only tmux window per
# resolved transcript under the megagoal's shared tmux session (same has-session/new-session
# dance as `_pane_spawn`); idempotent (`kill-window` best-effort precedes each `new-window`, so
# re-invoking for the same transcript pre-cleans and respawns its window). rc CONTRACT: ALWAYS
# 0 -- a pane is a visibility affordance; the most common real case (a just-dispatched subagent
# whose transcript doesn't exist yet) must not read as a failure to an LLM conductor. Every skip
# warns on stderr and is counted in the final summary line instead.
cmd_panes() {  # megadir target...
  local megadir="${1:-}"; shift 2>/dev/null || true
  if [ -z "$megadir" ] || [ "$#" -lt 1 ]; then
    {
      echo "usage: orchestrate.sh panes <megadir> <target>..."
      echo "  <target>: a jsonl file path | a directory (expands agent-*.jsonl) | --latest"
    } >&2
    return 0
  fi

  local formatter="$PANE_TAIL_JQ"
  # Same abspath normalization the jsonl target already gets (an argv token headed for tmux's
  # exec'd argv must never be a bare relative/leading-dash path); the formatter was missing this.
  local formatter_abs
  formatter_abs=$(_panes_abspath "$formatter") && formatter="$formatter_abs"
  local mux; mux=$(_mux_session_name "$megadir")
  local session_created=0
  if ! "$TMUX_CMD" has-session -t "$mux" 2>/dev/null; then
    "$TMUX_CMD" new-session -d -s "$mux" -n _init 2>/dev/null && session_created=1
  fi

  local jsonl abs win spawned=0 skipped=0
  while IFS= read -r jsonl; do
    [ -n "$jsonl" ] || continue
    # A symlink passes the `-f` test below (it follows the link), so without this check a symlink
    # target would count as "spawned" here while `_pane-tail`'s own `-L` gate then refuses it
    # invisibly inside the pane (ghost window + a summary line that lies about what ran).
    if [ -L "$jsonl" ]; then
      echo "[panes] skip: symlink, not a real transcript file: $(_panes_show "$jsonl")" >&2
      skipped=$((skipped + 1)); continue
    fi
    if [ ! -f "$jsonl" ] || [ ! -r "$jsonl" ]; then
      echo "[panes] skip: not a readable regular file: $(_panes_show "$jsonl")" >&2
      skipped=$((skipped + 1)); continue
    fi
    case "$(basename -- "$jsonl")" in
      agent-*.jsonl) : ;;
      *) echo "[panes] skip: basename does not match agent-*.jsonl: $(_panes_show "$jsonl")" >&2
         skipped=$((skipped + 1)); continue ;;
    esac
    if ! abs=$(_panes_abspath "$jsonl"); then
      echo "[panes] skip: could not resolve an absolute path: $(_panes_show "$jsonl")" >&2
      skipped=$((skipped + 1)); continue
    fi
    win=$(_panes_window_name "$abs")
    "$TMUX_CMD" kill-window -t "$mux:$win" 2>/dev/null || true
    if "$TMUX_CMD" new-window -d -t "$mux" -n "$win" -- \
        "$ORCH_DIR/orchestrate.sh" _pane-tail "$abs" "$formatter"; then
      spawned=$((spawned + 1))
      _say "[panes] spawned $win <- $(_panes_show "$(basename -- "$abs")")"
    else
      echo "[panes] skip: tmux new-window failed for $(_panes_show "$abs")" >&2
      skipped=$((skipped + 1))
    fi
  done < <(_panes_resolve_targets "$@")

  # SPEC-121 push, gated on session CREATION here (not `_viewer_open`'s own `_VIEWER_OPENED`
  # guard, which is process-local -- every `panes` call is a fresh process, so that guard cannot
  # dedupe ACROSS calls): a second `panes` call against an already-running session must not
  # re-open a viewer.
  [ "$session_created" = 1 ] && _viewer_open "$megadir"

  _say "[panes] spawned $spawned, skipped $skipped"
  return 0
}

# Hidden re-entry point for a `panes` window (SPEC-234): `tmux new-window` always execs a fresh
# command line, so the pane re-enters `orchestrate.sh` via this subcommand instead of the shell
# expressing `tail | jq` as a joined string (the SPEC-119 #143 exec-direct rule). Refuses
# non-regular / symlinked / wrong-basename transcripts and a missing/unreadable formatter itself
# (defense in depth -- `cmd_panes` already gates these, but a re-entry subcommand must not be
# repurposable to tail an arbitrary file). tmux closes a window whose command exits, so a refusal
# is invisible in the pane; these checks matter for an operator invoking `_pane-tail` by hand.
# `-n 200` (not `-n +1`): an idempotent respawn (kill-window + new-window on a re-invoked `panes`)
# would otherwise replay an entire long transcript into a fresh pane. `-R` on the jq side is
# load-bearing: jq's own parser ABORTS the whole process on one malformed or half-written line
# under structured input (`tail -F` can deliver one); raw mode + the formatter's own
# `fromjson? // empty` makes a bad line render nothing instead of killing the pipe. Deliberately
# absent from `main()`'s usage string, like `_pane-exec`.
cmd_pane_tail() {  # jsonl formatter
  local jsonl="${1:-}" formatter="${2:-}"
  if [ -z "$jsonl" ] || [ -z "$formatter" ]; then
    echo "usage: orchestrate.sh _pane-tail <jsonl> <formatter>" >&2
    return 64
  fi
  if [ -L "$jsonl" ]; then
    echo "[pane-tail] refusing: symlink, not a real transcript file: $(_panes_show "$jsonl")" >&2
    return 64
  fi
  if [ ! -f "$jsonl" ]; then
    echo "[pane-tail] refusing: not a regular file: $(_panes_show "$jsonl")" >&2
    return 64
  fi
  if [ ! -r "$jsonl" ]; then
    echo "[pane-tail] refusing: transcript not readable: $(_panes_show "$jsonl")" >&2
    return 64
  fi
  case "$(basename -- "$jsonl")" in
    agent-*.jsonl) : ;;
    *) echo "[pane-tail] refusing: basename does not match agent-*.jsonl: $(_panes_show "$jsonl")" >&2; return 64 ;;
  esac
  if [ ! -f "$formatter" ] || [ ! -r "$formatter" ]; then
    echo "[pane-tail] refusing: formatter missing or unreadable: $(_panes_show "$formatter")" >&2
    return 64
  fi
  echo "[panes] tailing $(_panes_show "$(basename -- "$jsonl")") -- read-only; steer via the conductor (SendMessage)"
  local program; program=$(cat "$formatter")
  tail -n 200 -F -- "$jsonl" | jq -R -r --unbuffered "$program"
}
# ---------------------------------------------------------------------------------------------

# Abort handler for `_wave_run`'s INT/TERM trap: kill every still-live wave job's PROCESS GROUP then
# reap, so an operator ctrl-C never leaves an orphaned `claude -p` (mock) grandchild. `_WAVE_PIDS`
# holds the backgrounded SUBSHELL WRAPPER pid (`( cd ... && _run_one_session ... ) &`), not the
# `claude -p` process itself -- a plain `kill "$p"` only signals the wrapper, so the grandchild
# reparents to init and survives (confirmed live; review-fix FIX 1). Each job was spawned under
# `set -m`, so its pgid == its pid; a NEGATIVE pid (`-"$p"`) signals the whole group instead. Falls
# back to a plain `kill "$p"` if the group signal fails (e.g. job control was unavailable at spawn
# time, or the job already exited on its own). `_WAVE_PIDS` is a GLOBAL (not a `_wave_run` local)
# precisely so this handler can reach it while `_wave_run` is on the stack. The empty-guard
# `${arr[@]+...}` keeps `set -u` happy when the trap fires before any PID is recorded.
_wave_abort() {
  local p ok=1
  for p in ${_WAVE_PIDS[@]+"${_WAVE_PIDS[@]}"}; do
    [ -n "$p" ] || continue   # SPEC-119: a muxed entry has no reapable pid; handled below instead
    kill -TERM -- -"$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null || ok=0
  done
  wait 2>/dev/null
  # SPEC-119: a muxed wave session's REAL process lives in a tmux pane, not this shell's job
  # table, so the pid loop above cannot reach it -- kill its window directly instead (best-effort;
  # a failure here does not flip `ok`, the pid-loop TERM confirmation is unrelated to pane cleanup).
  local n="${#_WAVE_DONEFILES[@]}" i mux
  if [ -n "${_WAVE_MUX_MEGADIR:-}" ] && [ "$n" -gt 0 ]; then
    mux=$(_mux_session_name "$_WAVE_MUX_MEGADIR")
    for i in $(seq 0 $((n - 1))); do
      [ -n "${_WAVE_DONEFILES[$i]:-}" ] || continue
      "$TMUX_CMD" kill-window -t "$mux:${_WAVE_IDS[$i]}" 2>/dev/null || true
    done
  fi
  # Review-fix FIX 8: clean up any prompt temp files an interrupted wave leaves behind (they hold
  # the injected HANDOFF content; a Ctrl-C otherwise leaks them into ${TMPDIR:-/tmp}).
  rm -f "${_WAVE_PFILES[@]+"${_WAVE_PFILES[@]}"}" 2>/dev/null
  # Only claim a clean kill when every group/plain TERM actually landed; a partial failure gets
  # softer wording instead of a confirmation that may be false (review-fix FIX 1).
  if [ "$ok" = 1 ]; then
    echo "[orchestrate] [wave] aborted; sent TERM to each wave job's process group (pgid==pid) and reaped -- grandchild sessions killed too, not just the subshell wrapper." >&2
  else
    echo "[orchestrate] [wave] aborted; reaped the wave PID set, but at least one TERM signal failed (process/group may already be gone)." >&2
  fi
  return 130
}

# _wave_run <megadir> <roadmap>: spawn the admitted wave, reap on completion, drain on sibling fail.
# Computes the admitted set via `_wave_gate` (its `run<TAB>id` lines). For each admitted sub-goal:
#   * skip an already-checked box (idempotent resume, invariant 1),
#   * stand up its worktree (`_wave_worktree`: reuse-clean-else-recreate, never blind add),
#   * build its prompt (`_build_prompt`) and BACKGROUND a session via `_run_one_session`,
#     cd'd INTO the worktree so siblings are genuinely isolated,
#   * record `pid -> sg-id` in the index-aligned reap map (`_WAVE_PIDS` / `wave_ids`).
# Then the REAP LOOP polls all live PIDs with `kill -0` (NOT `wait -n`, bash 4.3+). As each PID
# exits it is reaped with `wait` (retrieves the status bash cached for the finished job) and the
# GROUNDED completion check runs for THAT sub-goal: its box must be flipped in the SHARED
# $megadir/ROADMAP.md (read via `_subgoals`; the SESSION flips its own box, we only CHECK, never
# `cmd_flip` here).
#
# Failure semantics (invariant 5 / failure-modes table "Sibling session exits nonzero mid-wave"): a
# sub-goal that exits NONZERO or dies with its box UNFLIPPED marks the wave failed, but in-flight
# siblings are LET DRAIN to completion in their isolated worktrees (the reap loop never breaks early
# and never kills a healthy sibling); the run returns nonzero only AFTER every wave PID is reaped.
# The INT/TERM `trap` reaps+kills the whole PID set on an abort so nothing is orphaned.
#
# Returns 0 iff every admitted sub-goal completed with a flipped box; nonzero otherwise (incl. a
# worktree-setup failure). An empty admitted set (all deferred / all already checked) is a no-op 0.
_wave_run() {  # megadir roadmap
  local megadir="$1" roadmap="$2"
  local repo; repo=$(git -C "$megadir" rev-parse --show-toplevel 2>/dev/null)
  [ -n "$repo" ] || { echo "[orchestrate] [wave] '$megadir' is not inside a git repo; cannot stand up worktrees." >&2; return 64; }
  # Absolute mega-goal dir for the flip-contract injection: a wave session runs in a worktree (a
  # different cwd), so it must target the SHARED ROADMAP by absolute path, never a relative one.
  local mega_abs; mega_abs=$(cd "$megadir" 2>/dev/null && pwd); [ -n "$mega_abs" ] || mega_abs="$megadir"

  # Reap map = index-aligned plain arrays (bash 3.2 has no assoc arrays). `_WAVE_PIDS` is global so
  # `_wave_abort` can reach it; the rest are locals.
  _WAVE_PIDS=()
  # `_WAVE_LANDED` is GLOBAL (like `_WAVE_PIDS`): the wave-success path appends each grounded-complete
  # sub-goal id here so the caller (`cmd_run`) can hand the landed set to `_wave_converge` after the
  # wave drains. Reset per run so a prior wave's ids never leak. Empty-guarded at every read site.
  _WAVE_LANDED=()
  # `_WAVE_PFILES` is GLOBAL too (review-fix FIX 8): each spawned session's prompt temp file, so
  # `_wave_abort` can `rm -f` any still-live ones on an INT/TERM instead of leaking them into
  # ${TMPDIR:-/tmp}. Index-aligned with `_WAVE_PIDS` / `_WAVE_IDS`, same as the other reap-map arrays.
  _WAVE_PFILES=()
  # `_WAVE_IDS` / `_WAVE_DONEFILES` are GLOBAL (SPEC-119, same reason as `_WAVE_PIDS`): a muxed
  # entry has no reapable pid, so `_wave_abort` needs the sub-goal id (to address its tmux window)
  # and `_WAVE_DONEFILES[i]` non-empty is what marks index `i` as muxed vs plain-backgrounded.
  # `_WAVE_MUX_MEGADIR` lets the abort handler derive the tmux session name; harmless when unset
  # (the `n -gt 0` / non-empty-donefile guards make the whole block a no-op for a non-muxed wave).
  _WAVE_IDS=()
  _WAVE_DONEFILES=()
  _WAVE_MUX_MEGADIR="$megadir"
  local wave_done=()
  local wave_failed=0 spawned=0

  # Reap/kill the wave PID set on an abort so no `claude -p` (mock) child is orphaned. Cleared
  # before the normal return paths below.
  trap '_wave_abort' INT TERM

  local decision id gf branch wt route_flags rmodel reffort pfile pid donefile checked route_out route_rc
  while IFS=$'\t' read -r decision id; do
    [ "$decision" = run ] || continue
    # Idempotent resume: a box already checked is skipped, never re-run.
    checked=$(_subgoals "$roadmap" | awk -F'\t' -v i="$id" '$1==i {print $3}')
    [ "$checked" = 1 ] && { _say "[orchestrate] [wave] $id already checked; skipping (idempotent)."; continue; }

    gf=$(_goalfile "$megadir" "$id")
    branch=$(_sg_branch "$gf" "$id")
    if ! wt=$(_wave_worktree "$repo" "$id" "$branch"); then
      echo "[orchestrate] [wave] $id: worktree setup failed; marking wave failed." >&2
      # Review-fix FIX 6: every other _wave_run failure path emits an event (the replay source of
      # truth); this one previously only echoed to stderr.
      _emit_event "$megadir" "$id" blocked "wave: worktree setup failed"
      wave_failed=1
      continue
    fi

    # Per-sub-goal model/effort routing (matches cmd_run); absent hint -> no flag -> inherit.
    # ID-096: `route_out=$(_route "$gf")` assigns `$?` from `_route` itself (a simple command-
    # substitution assignment, unlike `< <(...)` process substitution above it, which reflects
    # `read`'s exit status instead) -- an off-allowlist `Model:` tier is rejected HERE, before this
    # sub-goal's session ever spawns, same as a worktree-setup failure just above.
    route_flags=""
    route_out=$(_route "$gf"); route_rc=$?
    IFS=$'\t' read -r rmodel reffort <<<"$route_out"
    if [ "$route_rc" != 0 ]; then
      # ID-390: generic like the serial path -- _route rejects both an off-allowlist model tier and
      # an unknown/not-enabled harness, each already reasoned to stderr.
      _emit_event "$megadir" "$id" blocked "wave: rejected pre-flight by routing (model tier or harness gate)"
      wave_failed=1
      continue
    fi
    [ -n "$rmodel" ] && route_flags="$route_flags --model $rmodel"
    [ -n "$reffort" ] && route_flags="$route_flags --effort $reffort"

    pfile=$(mktemp)
    _build_prompt "$megadir" "$id" > "$pfile"
    # Flip-contract injection (WAVE sessions only, ID-090 activation). A wave session runs in its
    # own worktree , a separate checkout , so editing ROADMAP.md there flips only the worktree's
    # copy, invisible to the driver, which reads the SHARED mega-goal-dir ROADMAP. Tell the session
    # to flip via the lock-guarded CLI against the shared ABSOLUTE path instead. Appended AFTER
    # `_build_prompt` so the SERIAL path's prompt is untouched (serial stays byte-identical).
    {
      printf '\n\n---\nWAVE SESSION , SHARED-ROADMAP FLIP CONTRACT (read carefully)\n'
      printf 'You run in an ISOLATED git worktree for sub-goal %s. Do the work here, then mark\n' "$id"
      printf 'completion by running EXACTLY this command (do NOT hand-edit ROADMAP.md , your worktree\n'
      printf 'copy is invisible to the orchestrator):\n\n    %s flip %s %s\n\n' "$ORCH_DIR/orchestrate.sh" "$mega_abs" "$id"
      printf 'It flips your box in the SHARED ROADMAP under a lock. The orchestrator advances only\n'
      printf 'once your box is flipped there (grounded completion; no self-claim).\n'
    } >> "$pfile"

    # Reserved SPEC number injection (SPEC-128). Claim a number atomically at DISPATCH , before
    # this worker (and its siblings) can race `spec-next next` at spec-time , and tell the worker
    # to use exactly it. Best-effort: a reserve failure leaves no block, and the worker falls back
    # to computing its own number (the reservation ledger it would then scan already folds in any
    # sibling claims, so even the fallback is collision-safe). Appended AFTER the flip-contract so
    # the serial path's prompt stays byte-identical (this whole block is WAVE-only).
    local reserved_spec
    if reserved_spec="$(_wave_reserve_spec)"; then
      {
        printf '\n\n---\nRESERVED SPEC NUMBER\n'
        printf 'This wave dispatch reserved SPEC-%s for your sub-goal. When you run /kit:spec (or\n' "$reserved_spec"
        printf 'call lib/spec/spec-next.sh), USE SPEC-%s , it is already claimed for you under a lock, so\n' "$reserved_spec"
        printf 'no sibling wave worker can take it. Do NOT re-derive a different number.\n'
      } >> "$pfile"
      _say "[orchestrate] [wave] $id reserved SPEC-$reserved_spec"
    else
      _say "[orchestrate] [wave] $id: SPEC reservation unavailable; worker will self-compute (degraded, still scan-safe)."
    fi
    _emit_event "$megadir" "$id" executing "wave (worktree $wt)"
    # ID-099: mirror the serial path's START/rid emission (cmd_run calls `_emit_start` right after
    # its own `executing` event, see line ~1811). Before this fix, `_wave_run`'s spawn loop emitted
    # ONLY `executing` and never `_emit_start`, so every wave dispatch was invisible to
    # lane-telemetry (zero START/rid records, even though the serial path tracked every run). Same
    # advisory behavior as serial: `_emit_start` itself WARNs-and-skips (does not abort the spawn)
    # when the goal file has no `**Branch:**` header to derive a rid from -- pinned to stay
    # advisory (a `?`-rid run is degraded-but-runnable, not corrupt), so no change needed here
    # beyond adding the call. NC_SKIP_WAVE_START=1 is a TEST-ONLY escape hatch (ID-099 negative
    # control, same pattern as NC_SKIP_WAVE_TOKENS above): it disables just this call so a test can
    # prove the causal effect (same wave scenario, but the pre-fix-equivalent code path records
    # ZERO START lines). Unset/0 in every real invocation; never documented as an operator flag.
    [ "${NC_SKIP_WAVE_START:-0}" = 1 ] || _emit_start "$megadir" "$id"

    if [ "$MULTIPLEXER" = 1 ]; then
      # SPEC-119: host the REAL session inside a tmux pane instead of a plain background job (the
      # off-by-default path below is untouched). `tmux new-window` returns as soon as the window is
      # created, before the pane's command exits, so there is no pid to `wait` on here -- the pane
      # writes its own exit code to $donefile instead (the reap loop polls it, see below).
      donefile=$(mktemp -u)
      if ! _pane_spawn "$megadir" "$id" "$wt" "$pfile" "$route_flags" "$donefile"; then
        echo "[orchestrate] [wave] [mux] $id: tmux pane spawn failed; marking wave failed." >&2
        _emit_event "$megadir" "$id" blocked "wave: tmux pane spawn failed"
        wave_failed=1
        rm -f "$pfile"
        continue
      fi
      pid=""
      _say "[orchestrate] [wave] [mux] spawned $id in tmux pane $(_mux_session_name "$megadir"):$id (worktree $wt)"
      # SPEC-121 push: open ONE viewer surface attached to this wave's tmux session. Reuse-guarded
      # inside (one surface per session per run) and best-effort (always rc 0) -- a viewer failure
      # never marks the wave failed. Scoped INSIDE the MULTIPLEXER=1 branch: with the multiplexer
      # off there is no tmux session to attach, so the default path stays byte-identical.
      _viewer_open "$megadir"
    else
      # Background the session INSIDE its worktree (genuine isolation). `_run_one_session` picks the
      # run-path (plain in the default/test posture); its `_ROS_SLOG` global is unused on the wave
      # path (deterministic-handoff regen is TASK-005), so losing it in the subshell is fine. The
      # session's exit code comes back via `wait` in the reap loop, NOT via the subshell here.
      #
      # Job control ON only around the spawn itself (review-fix FIX 1): under `set -m` a `&` job
      # becomes its OWN PROCESS GROUP (pgid == the job's pid), so `_wave_abort` can signal the WHOLE
      # group -- the backgrounded subshell wrapper AND its `claude -p` grandchild -- via a negative-pid
      # `kill`. Without this, `kill "$p"` reaches only the wrapper; the grandchild reparents to init and
      # survives an abort (confirmed live: the prior "no orphaned children" claim was false). Scoped
      # tightly (set +m right after `$!`) so monitor mode's job-control side effects never leak into the
      # rest of the spawn loop or the reap loop below. bash 3.2 macOS has no `setsid`; job control is
      # the only portable no-setsid way to get a fresh process group.
      set -m
      ( cd "$wt" 2>/dev/null && _run_one_session "$megadir" "$id" "$pfile" "$route_flags" 0 ) &
      pid=$!
      set +m
      donefile=""
      _say "[orchestrate] [wave] spawned $id (pid $pid) in $wt"
    fi
    _WAVE_PIDS+=("$pid")
    _WAVE_IDS+=("$id")
    _WAVE_DONEFILES+=("$donefile")
    _WAVE_PFILES+=("$pfile")
    wave_done+=(0)
    spawned=$((spawned + 1))
  done < <(_wave_gate "$megadir" "$roadmap")

  # Empty wave (nothing admitted, or every admitted box already checked): not a failure unless a
  # worktree setup already failed above.
  if [ "$spawned" = 0 ]; then
    trap - INT TERM
    return "$wave_failed"
  fi

  # Reap loop: poll ALL live PIDs with `kill -0` (the `_run_session_watchdog` pattern, NOT `wait -n`
  # which is bash 4.3+/absent on macOS). As each PID exits, reap it with `wait`, then run the
  # grounded box-flip check for THAT sub-goal. A nonzero exit OR an unflipped box marks the wave
  # failed but does NOT break the loop: in-flight siblings DRAIN to completion (never killed).
  # SPEC-119: a muxed index (`_WAVE_DONEFILES[i]` non-empty) has no reapable pid -- `tmux
  # new-window` already returned -- so that index polls for its donefile instead of `kill -0`.
  local remaining="$spawned" i rc box donefile mux
  while [ "$remaining" -gt 0 ]; do
    for i in $(seq 0 $((spawned - 1))); do
      [ "${wave_done[$i]}" = 1 ] && continue
      pid="${_WAVE_PIDS[$i]}"; id="${_WAVE_IDS[$i]}"; donefile="${_WAVE_DONEFILES[$i]}"
      if [ -n "$donefile" ]; then
        [ -f "$donefile" ] || continue          # still in-flight -> leave it alone
        rc=0; read -r rc < "$donefile" 2>/dev/null || rc=0
        rm -f "$donefile"
      else
        kill -0 "$pid" 2>/dev/null && continue   # still in-flight -> leave it alone (do not kill)
        rc=0; wait "$pid" 2>/dev/null || rc=$?    # exited -> reap the cached status
      fi
      wave_done[i]=1
      remaining=$((remaining - 1))
      rm -f "${_WAVE_PFILES[$i]}" 2>/dev/null
      box=$(_subgoals "$roadmap" | awk -F'\t' -v x="$id" '$1==x {print $3}')
      if [ "$rc" != 0 ]; then
        wave_failed=1
        _emit_event "$megadir" "$id" blocked "wave session exited nonzero ($rc)"
        echo "[orchestrate] [wave] $id session exited nonzero ($rc); draining siblings, then failing." >&2
      elif [ "$box" != 1 ]; then
        wave_failed=1
        _emit_event "$megadir" "$id" blocked "wave: box not flipped (no self-claim)"
        echo "[orchestrate] [wave] $id finished but did not flip its ROADMAP box; draining siblings, then failing." >&2
      else
        _emit_event "$megadir" "$id" shipped "wave: box checked"
        _WAVE_LANDED+=("$id")
        # ID-098: happy-path tmux cleanup. Before this fix, ONLY `_wave_abort` ever killed a
        # window (and only an in-flight one, on operator Ctrl-C) -- a clean, successful reap left
        # the completed pane sitting in the shared per-megagoal tmux session forever, so a
        # multi-wave run accumulated one stale window per landed sub-goal. `_pane_spawn` already
        # pre-cleans a PRIOR attempt's stale window before spawning a retry, so this is belt-and-
        # braces for the retry path too, not just tidiness. Muxed-only: a non-empty `$donefile`
        # here means this index was tmux-spawned (see the spawn loop above); the plain background-
        # job path has no window to kill. `|| true`: a missing window (already cleaned, or the
        # multiplexer was never on) is not a failure.
        if [ -n "$donefile" ]; then
          mux=$(_mux_session_name "$megadir")
          "$TMUX_CMD" kill-window -t "$mux:$id" 2>/dev/null || true
        fi
        # Token accounting (ID-094): closes the SPEC-117 declared gap ("the wave-path per-sub-goal
        # ledger extraction is a declared gap"). The serial path reads $slog off `_ROS_SLOG`, a
        # global `_run_one_session` sets directly in the caller's shell; the wave path backgrounds
        # `_run_one_session` in a FORKED SUBSHELL ("( cd "$wt" ... ) &" above), so that global never
        # crosses back. But `_run_one_session`'s stream path is DETERMINISTIC (`$dir/.orchestrate/
        # <id>.stream.jsonl`, $dir == $megadir here), so the reap loop can recompute the same path
        # instead of needing it handed back. Only recompute when a capture was actually requested
        # (mirrors _run_one_session's own capture gate at CAPTURE_TOKENS/DETERMINISTIC_HANDOFF);
        # `_record_tokens` is itself a no-op on an absent/empty file, so this is belt-and-braces, not
        # load-bearing, but avoids a pointless stat on the default (no-capture) path.
        # NC_SKIP_WAVE_TOKENS=1 is a TEST-ONLY escape hatch (ID-094 negative control): it disables
        # just this extraction call so a test can prove the causal effect (same wave scenario, same
        # captured child.jsonl, but the pre-fix-equivalent code path records ZERO ledger lines).
        # Unset/0 in every real invocation; never documented as an operator flag.
        if { [ "$CAPTURE_TOKENS" = 1 ] || [ "$DETERMINISTIC_HANDOFF" = 1 ]; } && [ "${NC_SKIP_WAVE_TOKENS:-0}" != 1 ]; then
          _record_tokens "$megadir" "$id" "$megadir/.orchestrate/${id}.stream.jsonl"
        fi
        _say "[orchestrate] [wave] $id complete (box checked)."
      fi
    done
    [ "$remaining" -gt 0 ] && sleep "${WAVE_POLL_SECS:-0.2}"
  done

  trap - INT TERM
  return "$wave_failed"
}
# -----------------------------------------------------------------------------------------------

# ---- Wave convergence sequencer (SPEC-106 TASK-004c, DEC-008) ----------------------------------
# After a wave lands its sub-goals on their worktree branches, their merges back to the mega-goal base
# MUST happen ONE AT A TIME (never concurrently), in ROADMAP order, each under the flip lock , so two
# same-base merges never race. This is a THIN SEQUENCER: it does NOT reimplement merging. Each merge
# goes through the MOCKABLE `$WAVE_MERGE_CMD` hook (default `lib/goal/mega-merge.sh merge`, whose merge
# SEMANTICS stay untouched per scope , we only sequence calls to it). Real gh-backed merge is DEFERRED
# to ID-090 (waves are off at the default WAVE_CAP=1, so this is never reached and the serial
# path stays byte-identical; a real merge also needs `gh` + real PRs).

# Files a wave branch changed vs the base: three-dot diff = changes on <branch> since its merge-base
# with <base>. Empty when the branch has no commits (e.g. a session that only flipped its box) or is
# absent (git errors, swallowed). Read-only.
_wave_branch_files() {  # repo base branch
  git -C "$1" diff --name-only "$2...$3" 2>/dev/null
}

# The PR number on a sub-goal's ROADMAP line (`... , PR #<n>`), or empty for a placeholder (`PR #__`)
# / absent. A sub-goal with no real PR cannot be merged yet, so `_wave_converge` SKIPS it (the real
# PR-open + merge wiring is ID-090), never fails on it.
_sg_pr() {  # roadmap id
  _sg_line "$1" "$2" | sed -nE 's/.*PR #([0-9]+).*/\1/p' | head -1
}

# _wave_converge <megadir> [<id>...]: sequence the merges of a landed wave. With explicit ids it merges
# exactly those; with none, it reads the just-landed set from the global `_WAVE_LANDED` (populated by
# `_wave_run`). Steps:
#   1. Order the target ids by ROADMAP position (NOT argv order) , merges land in ROADMAP order.
#   2. SAME-FILE cross-wave guard (belt-and-suspenders over dispatch-gate's PRE-admission disjointness,
#      the SPEC-106 risk row): diff each landed branch vs the base; if two branches changed the SAME
#      file, FLAG (event + message + nonzero) and REFUSE to merge , never silently land a clean-but-
#      wrong merge. A file appearing from >=2 branches (union `sort | uniq -d`) is the overlap.
#   3. Merge each in ROADMAP order, ONE AT A TIME under the flip lock, through `$WAVE_MERGE_CMD`. A
#      sub-goal with no real PR (placeholder `#__`) is SKIPPED (merge wiring deferred), not failed.
# bash-3.2: no assoc arrays (membership via a space-padded string match); arrays empty-guarded
# `${arr[@]+"${arr[@]}"}` (DEC-005, mega-merge.sh:224). Returns 0 iff every mergeable sub-goal's hook
# succeeded and no same-file overlap was found; nonzero on an overlap flag or a merge-hook failure.
_wave_converge() {  # megadir [id...]
  local megadir="$1"; shift 2>/dev/null || true
  local roadmap="$megadir/ROADMAP.md"
  [ -f "$roadmap" ] || { echo "[orchestrate] [converge] no ROADMAP.md in '$megadir'" >&2; return 64; }

  # Target set: explicit args, else the just-landed set from `_wave_run`.
  local targets=()
  if [ "$#" -gt 0 ]; then
    targets=("$@")
  else
    targets=( ${_WAVE_LANDED[@]+"${_WAVE_LANDED[@]}"} )
  fi
  [ "${#targets[@]}" -gt 0 ] || { _say "[orchestrate] [converge] no landed wave sub-goals to converge (no-op)."; return 0; }

  local repo; repo=$(git -C "$megadir" rev-parse --show-toplevel 2>/dev/null)
  [ -n "$repo" ] || { echo "[orchestrate] [converge] '$megadir' is not inside a git repo; cannot converge." >&2; return 64; }
  local base; base=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null); [ -n "$base" ] || base=HEAD

  # 1. Order the targets by ROADMAP position. Walk `_subgoals` (ROADMAP order) and keep those in the
  #    target set; membership via a space-padded string match (bash-3.2 has no assoc arrays).
  local want; want=" $(printf '%s ' "${targets[@]}")"   # split decl+assign so the printf status is not masked (SC2155)
  local ordered=() sgid _p _c                            # _p/_c: policy+checked fields read but unused here
  while IFS=$'\t' read -r sgid _p _c; do
    case "$want" in *" $sgid "*) ordered+=("$sgid") ;; esac
  done < <(_subgoals "$roadmap")
  [ "${#ordered[@]}" -gt 0 ] || { _say "[orchestrate] [converge] none of the requested ids are in the ROADMAP (no-op)."; return 0; }

  # 2. Same-file cross-wave guard. Each branch's file list is deduped (`sort -u`); across the union, a
  #    file that appears >=2 times (`uniq -d`) was touched by >=2 branches , the overlap.
  local id gf branch overlap
  overlap=$(
    for id in "${ordered[@]}"; do
      gf=$(_goalfile "$megadir" "$id")
      branch=$(_sg_branch "$gf" "$id")
      _wave_branch_files "$repo" "$base" "$branch" | sort -u
    done | sort | uniq -d
  )
  if [ -n "$overlap" ]; then
    _emit_event "$megadir" "wave" blocked "converge: same-file cross-wave edit"
    {
      echo "[orchestrate] [converge] SAME-FILE cross-wave edit detected across the landed wave; REFUSING to merge (a clean-but-wrong merge is the hazard dispatch-gate's disjointness guards against). Overlapping file(s):"
      printf '%s\n' "$overlap" | sed 's/^/    /'
    } >&2
    return 1
  fi

  # 3. Merge each in ROADMAP order, ONE AT A TIME under the flip lock, via the mockable hook.
  #    The default hook is `lib/goal/mega-merge.sh merge`, whose signature is `<pr> <rid> <lane>` (ID-090:
  #    the arity was `<pr> <id>` before). rid = the sub-goal's run id (its branch slug, from the goal
  #    file's `**Branch:**`); lane = the mega-goal's lane (`WAVE_MERGE_LANE`, default full , mega-goals
  #    run the full lane). Tests override `WAVE_MERGE_CMD` with a recorder, so the extra arg is inert.
  local lockdir="$megadir/.orchestrate/flip.lock"
  local pr rc branch rid lane="${WAVE_MERGE_LANE:-full}"
  for id in "${ordered[@]}"; do
    pr=$(_sg_pr "$roadmap" "$id")
    if [ -z "$pr" ]; then
      _say "[orchestrate] [converge] $id has no real PR yet (placeholder); skipping its merge (real PR/merge wiring is deferred)."
      continue
    fi
    branch=$(_sg_branch "$(_goalfile "$megadir" "$id")" "$id"); rid="${branch#*/}"; [ -n "$rid" ] || rid="$id"
    _lock "$lockdir" || { echo "[orchestrate] [converge] could not acquire the flip lock to merge $id" >&2; return 1; }
    rc=0
    # shellcheck disable=SC2086 # WAVE_MERGE_CMD is operator config; word-splitting is intended (mirrors CLAUDE_FLAGS).
    $WAVE_MERGE_CMD "$pr" "$rid" "$lane" || rc=$?
    _unlock "$lockdir"
    if [ "$rc" != 0 ]; then
      _emit_event "$megadir" "$id" blocked "converge: merge hook failed (PR #$pr, rc $rc)"
      echo "[orchestrate] [converge] $id merge hook failed (PR #$pr, rc $rc); stopping convergence (no self-claim)." >&2
      return "$rc"
    fi
    _emit_event "$megadir" "$id" merged "converge: PR #$pr merged (one-at-a-time under the flip lock)"
    _say "[orchestrate] [converge] $id merged (PR #$pr)."
  done
  return 0
}
# -----------------------------------------------------------------------------------------------

# ---- TIER-4 mega-close (SPEC-118/ID-093, executes ADR-0032 section 5) --------------------------
# Runs AFTER every sub-goal box is checked, over the ASSEMBLED WAVE -- it does NOT re-run each
# sub-goal's per-task V-model (that already fired). Three steps: (1) a mechanical no-orphan sweep,
# (2) THREE independent fresh-context `claude -p` verifier sessions (integration-verifier /
# review-team / advisor, one process each) fail-closed AGGREGATED (any dissent blocks), then
# (3) HOLD the human gate (never auto-merge). Replaces the "done"-and-return in cmd_run.

# _no_orphan_check <corpus>: mechanical sweep for the c6fbd99 orphan class. For each agents/<name>.md
# under <corpus>, the agent is DISPATCHED iff its <name> appears as a WHOLE WORD (grep -wF, so an agent
# named `advisor` does not false-match the word `advisory`, and the fixed-string form neutralizes any
# regex metachar) somewhere under commands/ or lib/, or in AGENTS.md / WORKFLOW.md. Zero dispatch refs
# => a BLOCKING orphan (defined + gated + rostered + documented but never DISPATCHED). agents/ itself is
# NOT searched (an agent is dispatched by a COMMAND, not by another agent), so an agent's own definition
# cannot self-satisfy the check. This is the agent-dispatch class ONLY -- the reliable, deterministic
# one; the softer flag/step/path wiring is the close SESSION's integration-verifier's job (its judgment
# lens, exactly as in c6fbd99). Prints one `[no-orphan] BLOCKING: ...` line per orphan. Returns 0 (clean)
# / 1 (>=1 orphan) / 2 (no corpus to sweep -- the caller treats 2 as a skip, never a halt).
_no_orphan_check() {  # corpus
  local corpus="${1:-}"
  [ -n "$corpus" ] && [ -d "$corpus/agents" ] || return 2   # nothing to sweep
  local found=0 af name hit
  for af in "$corpus"/agents/*.md; do
    [ -f "$af" ] || continue                                  # empty-glob guard (no agents/*.md)
    name=$(basename "$af" .md)
    # Search the dispatch corpus (commands/ + lib/ + the two workflow docs), NOT agents/. Missing
    # paths (a fixture without lib/ or AGENTS.md) just error to the swallowed stderr and are skipped.
    hit=$(grep -rlwF -- "$name" \
            "$corpus/commands" "$corpus/lib" "$corpus/AGENTS.md" "$corpus/WORKFLOW.md" "$corpus/docs/WORKFLOW.md" 2>/dev/null \
            | head -1)
    if [ -z "$hit" ]; then
      found=1
      printf '[no-orphan] BLOCKING: agent %s defined (agents/%s.md) but never dispatched (no whole-word reference in commands/, lib/, AGENTS.md, WORKFLOW.md, docs/WORKFLOW.md).\n' "$name" "$name"
    fi
  done
  [ "$found" = 0 ] && return 0 || return 1
}

# _tier4_objective <roadmap>: the mega-goal OBJECTIVE line -- the ROADMAP `**Destination:**` line
# if present, else the `# Mega-goal:` title line (fixtures carry the title; the real
# orchestrate-hardening ROADMAP carries Destination). Shared by all 3 verifier prompts below.
_tier4_objective() {  # roadmap
  local roadmap="$1" objective=""
  objective=$(grep -m1 -iE '^\*\*Destination:\*\*' "$roadmap" 2>/dev/null | sed -E 's/^\*\*[^*]*\*\*[[:space:]]*//')
  [ -n "$objective" ] || objective=$(grep -m1 -E '^# Mega-goal:' "$roadmap" 2>/dev/null | sed -E 's/^# Mega-goal:[[:space:]]*//')
  printf '%s' "$objective"
}

# _build_verifier_prompt <dir> <roadmap> <n>: compose the n-th (1..3) of THREE independent
# fresh-context verifier prompts for the TIER-4 close (ID-093). Splitting one single-prompt
# verifier (that ran all three checks itself, in one session) into three separate sessions means
# no single session's blind spot can silently pass the whole assembled wave -- each of the three
# reports its OWN verdict, and `_aggregate_tier4_verdicts` fails closed if any one dissents. Each
# prompt carries the SAME mega-goal OBJECTIVE and ends with the same structured verdict contract
# so the aggregator can parse all three uniformly regardless of which check a session ran.
_build_verifier_prompt() {  # dir roadmap n
  local dir="$1" roadmap="$2" n="$3" objective task
  objective=$(_tier4_objective "$roadmap")
  case "$n" in
    1) task='integration-verifier against the OBJECTIVE below (cross-sub-goal wiring + global acceptance).' ;;
    2) task='/kit:review-team INCLUDING the security-reviewer lens.' ;;
    3) task='the advisor in BOTH modes: critique (an extra uniform lens on top of the per-phase reviewers) AND over-suggest (additional ideas/sub-goals to improve the work).' ;;
  esac
  cat <<EOF
TIER-4 MEGA-CLOSE VERIFIER $n/3 for the mega-goal at: $dir

Every sub-goal box is checked. Verify the ASSEMBLED WAVE as a WHOLE. Do NOT re-run each sub-goal's
per-task V-model (that already fired); verify that the sub-goals WIRE TOGETHER and meet the OBJECTIVE.
This is ONE of three INDEPENDENT fresh-context verifier sessions; you do not see the other two
sessions' output, and they do not see yours. Run your check honestly on its own merits.

Mega-goal OBJECTIVE:
  $objective

Run, over the assembled result:
$task

End your report with EXACTLY one line, the last line of your output, one of:
  TIER4-VERDICT: PASS
  TIER4-VERDICT: DISSENT: <one-line reason>
Use DISSENT for any blocking finding severe enough that the mega-goal should not ship as-is. Do NOT
merge anything; the final human gate is HELD regardless of your verdict.
EOF
}

# _aggregate_tier4_verdicts <out1> <out2> <out3>: fail-closed aggregation over the three verifier
# outputs (ID-093). PASS only when all three sessions exited 0 (checked by the caller, which passes
# an already-nonzero session through as a synthetic DISSENT line) AND all three printed
# `TIER4-VERDICT: PASS` as their last matching verdict line. A single dissent -- one session, one
# blind spot averted -- is enough to fail closed; this is the whole point of the split (a single
# combined verifier could not surface a lone dissenting read, only its own one verdict). Prints one
# `[aggregate] verifier N: <verdict>` line per session, then the aggregate decision. Returns 0
# (aggregate PASS) / 1 (aggregate DISSENT: at least one verifier did not pass clean).
_aggregate_tier4_verdicts() {  # out1 out2 out3
  local i=0 f verdict any_dissent=0
  for f in "$@"; do
    i=$((i + 1))
    verdict=$(grep -oE 'TIER4-VERDICT:.*$' "$f" 2>/dev/null | tail -1)
    [ -n "$verdict" ] || verdict='TIER4-VERDICT: DISSENT: no verdict line found in verifier output'
    printf '[aggregate] verifier %s: %s\n' "$i" "$verdict"
    case "$verdict" in
      'TIER4-VERDICT: PASS') ;;
      *) any_dissent=1 ;;
    esac
  done
  if [ "$any_dissent" = 1 ]; then
    printf '[aggregate] DISSENT: at least one of the 3 verifiers did not PASS -- failing closed.\n'
    return 1
  fi
  printf '[aggregate] PASS: all 3 independent verifiers agree.\n'
  return 0
}

# _dispatch_tier4_verifiers <dir> <roadmap>: dispatch the THREE independent fresh-context verifier
# sessions (ID-093), each a separate `claude -p` process (never --stream to the conductor, ADR-0032
# section 1), capture each session's stdout to its own temp file, then aggregate. Returns
# `_aggregate_tier4_verdicts`'s rc; a nonzero session exit is folded in as a synthetic DISSENT line
# (a crashed/erroring verifier must never be silently treated as an implicit PASS). Temp files are
# cleaned up inline after the loop (NOT via a RETURN trap): a `trap ... RETURN` referencing a `local`
# array is a global return-trap under bash 3.2 (macOS system bash, no functrace) that fires with the
# array out of scope, and `"${arr[@]}"` on an empty array is a FATAL `set -u` unbound-variable there
# -- it flipped the whole run to rc 1 in macOS CI. The loop is fixed at 3 iterations, so `tmps`/`outs`
# are always populated at the cleanup/aggregate points; no empty-array expansion occurs.
_dispatch_tier4_verifiers() {  # dir roadmap
  local dir="$1" roadmap="$2" n pfile ofile rc arc
  local outs=()
  local tmps=()
  for n in 1 2 3; do
    pfile=$(mktemp); ofile=$(mktemp)
    tmps+=("$pfile" "$ofile")
    _build_verifier_prompt "$dir" "$roadmap" "$n" > "$pfile"
    _emit_event "$dir" close verifying "dispatching verifier $n/3"
    _say "[orchestrate] [close] dispatching verifier session $n/3 ($CLAUDE_CMD -p) ..."
    rc=0
    # shellcheck disable=SC2086 # CLAUDE_FLAGS is operator config; word-splitting is intended.
    "$CLAUDE_CMD" -p $CLAUDE_FLAGS < "$pfile" > "$ofile" 2>&1 || rc=$?
    if [ "$rc" != 0 ]; then
      printf 'TIER4-VERDICT: DISSENT: verifier %s session exited nonzero (%s)\n' "$n" "$rc" >> "$ofile"
    fi
    cat "$ofile"
    outs+=("$ofile")
  done
  arc=0
  _aggregate_tier4_verdicts "${outs[@]}" || arc=$?
  rm -f "${tmps[@]}"
  return "$arc"
}

# _tier4_close <dir> <roadmap>: the close STEP. no-orphan sweep -> verifier session -> HOLD the gate.
# Returns 0 (held clean, verifiers ran) / 1 (BLOCKED: an orphan, or a nonzero verifier session).
# NEVER merges (gated-final). Replaces the "done"-and-return.
_tier4_close() {  # dir roadmap
  local dir="$1" roadmap="$2"
  _emit_event "$dir" close running "TIER-4 mega-close over the assembled wave"
  _say "[orchestrate] [close] all sub-goals checked; running the TIER-4 mega-close over the assembled wave (no-orphan sweep + integration-verifier + review-team + advisor) BEFORE the human gate ..."

  # 1. Mechanical no-orphan sweep (fail-fast: a blocking orphan halts before an LLM session is spent).
  #    Corpus = TIER4_CORPUS, else the megadir's git repo root. Let `_no_orphan_check`'s own return
  #    code drive all three arms (0 clean / 1 orphan / 2 no-corpus) -- do NOT pre-guard the corpus here
  #    (that duplicated the callee's guard, made rc=2 dead, and would have silently mis-reported a
  #    would-be rc=2 as "clean"; the callee owns the "no corpus to sweep" decision).
  local corpus="${TIER4_CORPUS:-}"
  [ -n "$corpus" ] || corpus=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)

  # Render the mega-review dashboard (SPEC-197, harness-loop SG-07): ONE self-contained static
  # HTML sign-off page, composed from ledger + gh + proof data, generated next to RUN_REPORT.md
  # -- "the one surface with a guaranteed reader" the goal file names. Runs FIRST (before the
  # no-orphan sweep / verifier dispatch) so it reflects a snapshot as of close-time regardless of
  # how the rest of the close resolves; best-effort and NEVER fatal to the close (a render
  # failure is a WARN, the dashboard is a projection for the human gate, not a gate itself).
  local mega_slug mega_root
  mega_slug="$(basename "$dir")"
  mega_root="$(dirname "$dir")"
  if bash "$LIB_ROOT/mega/mega.sh" review "$mega_slug" --html --megagoals-root "$mega_root" --code-root "$corpus" >/dev/null 2>&1; then
    _say "[orchestrate] [close] mega-review dashboard rendered: $dir/REVIEW.html"
  else
    echo "[orchestrate] [close] WARN: mega-review dashboard render failed (non-fatal; re-run 'bash lib/mega/mega.sh review $mega_slug --html --megagoals-root $mega_root --code-root $corpus' to see the error)" >&2
  fi

  local orphans rc_no=0
  orphans=$(_no_orphan_check "$corpus") || rc_no=$?
  case "$rc_no" in
    1)  # >=1 orphan -> BLOCKING halt (fail-fast, before the LLM session).
      _emit_event "$dir" close blocked "no-orphan: an artifact was defined-but-never-dispatched"
      {
        echo "[orchestrate] [close] BLOCKING: the assembled wave has an orphan (defined-but-never-dispatched) artifact -- halting for human review (the c6fbd99 class; NOT held clean):"
        printf '%s\n' "$orphans" | sed 's/^/    /'
      } >&2
      return 1 ;;
    2)  # no corpus to sweep -> advisory skip (never a false halt; the verifier session + hold still run).
      echo "[orchestrate] [close] WARN: no corpus to sweep (TIER4_CORPUS unset and '$dir' has no resolvable git root with agents/); skipping the no-orphan sweep (advisory, not a halt)." >&2 ;;
    *)  # 0 = clean.
      _say "[orchestrate] [close] no-orphan sweep clean over $corpus (every agent has a live dispatch)." ;;
  esac

  # 2. Dispatch THREE independent fresh-context verifier sessions (ID-093: integration-verifier /
  #    review-team+security / advisor-both-modes, one process each, NEVER --stream to the
  #    conductor, ADR-0032 section 1) and fail-closed aggregate their verdicts. This replaces the
  #    old single combined-prompt session: one session's blind spot could pass the whole assembled
  #    wave silently; three independent reads mean a lone dissent surfaces instead of being averaged
  #    away inside one session's own judgment.
  _say "[orchestrate] [close] dispatching 3 independent verifier sessions ($CLAUDE_CMD -p x3) ..."
  local rc=0
  _dispatch_tier4_verifiers "$dir" "$roadmap" || rc=$?
  if [ "$rc" != 0 ]; then
    _emit_event "$dir" close blocked "verifier aggregate: at least one of 3 verifiers dissented"
    echo "[orchestrate] [close] BLOCKING: the 3-verifier aggregate DISSENTED (at least one of the 3 independent verifiers did not pass clean); halting for human review (not held clean)." >&2
    return 1
  fi

  # 3. HOLD the human gate -- all 3 verifiers ran and agreed; NEVER auto-merge past it (gated-final).
  _emit_event "$dir" close held "verifiers ran (no-orphan + 3 independent verifiers: integration-verifier + review-team + advisor, all PASS); HELD for the final human gate; NOT auto-merged"
  _say "[orchestrate] [close] TIER-4 mega-close complete: the no-orphan sweep + 3 independent verifier sessions (integration-verifier + review-team [security lens] + advisor [both modes]) all PASS over the assembled wave. HELD for the final human gate -- NOT auto-merged (gated-final). Review the held PR, then merge."
  return 0
}
# -----------------------------------------------------------------------------------------------

cmd_run() {
  local dir="" dry=0 step=0 stream=0 board_arg="" forced_pick=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run)  dry=1 ;;
      --step)     step=1 ;;
      --stream)   stream=1 ;;
      --capture-tokens) CAPTURE_TOKENS=1 ;;   # SPEC-117: lean token capture (silent stream-to-file); sets the global
      --board)    board_arg="both" ;;
      --board=*)  board_arg="${1#--board=}" ;;
      --*)        echo "unknown flag: $1" >&2; return 64 ;;
      *)          if [ -z "$dir" ]; then dir="$1"; else echo "unexpected arg: $1" >&2; return 64; fi ;;
    esac
    shift
  done
  [ -d "$dir" ] || { echo "no such megagoal dir: '$dir'" >&2; return 64; }
  local roadmap="$dir/ROADMAP.md"
  [ -f "$roadmap" ] || { echo "no ROADMAP.md in '$dir'" >&2; return 64; }
  # ID-095: age-cap sweep at the start of every REAL run, not just `next`. Skipped under --dry-run
  # (dry=1): a preview must stay non-mutating, it never touches disk beyond reading.
  [ "$dry" = 1 ] || _prune_streams "$dir"
  local board_mode; board_mode=$(_resolve_board_mode "$board_arg")
  case "$board_mode" in roadmap|kanban|both) ;; *) echo "unknown --board mode: '$board_mode' (want roadmap|kanban|both)" >&2; return 64 ;; esac

  # WAVE_CAP parse-time validation (SPEC-106 TASK-004b / DEC-009 / Edge case 4). Default 1 (waves
  # off). A non-numeric or <1 value is REJECTED with a clear error + nonzero exit here, NOT silently
  # coerced to 1 elsewhere, so a typo (`WAVE_CAP=0`, `WAVE_CAP=two`) fails loudly instead of quietly
  # running serial. The digit-class check rejects empty / non-numeric / negative (the sign char is a
  # non-digit); the `-lt 1` check then rejects 0.
  case "$WAVE_CAP" in
    ''|*[!0-9]*) echo "orchestrate: WAVE_CAP must be a positive integer >=1 (got: '$WAVE_CAP')" >&2; return 64 ;;
  esac
  [ "$WAVE_CAP" -lt 1 ] && { echo "orchestrate: WAVE_CAP must be >=1 (got: '$WAVE_CAP')" >&2; return 64; }

  # PANE_VIEWER pre-flight allowlist (SPEC-121, mirrors the WAVE_CAP rejection above): an unknown
  # value is REJECTED loudly here, never silently coerced to none -- a typo (`PANE_VIEWER=kity`)
  # must not quietly disable the push the operator asked for. EXACT-token enumeration, not a
  # substring test against the joined allowlist (review fix, security P2: `PANE_VIEWER="cmux
  # kitty"` passed the old `case " $list " in *" $v "*` membership idiom, because two adjacent
  # allowed words joined by one space are a substring of the list). $PANE_VIEWER_ALLOWED is only
  # the error message's rendering of this same set.
  case "$PANE_VIEWER" in
    auto|cmux|kitty|wezterm|ghostty|iterm|terminal|none) ;;
    *) echo "orchestrate: PANE_VIEWER must be one of: ${PANE_VIEWER_ALLOWED// /|} (got: '$PANE_VIEWER')" >&2; return 64 ;;
  esac

  if [ "$dry" = 1 ]; then
    _say "[plan] mega-goal: $dir"
    [ "$step" = 1 ]   && _say "  (--step: pause for the operator after each sub-goal)"
    [ "$stream" = 1 ] && _say "  (--stream: each session streamed live + captured to .orchestrate/<id>.stream.jsonl)"
    [ "$CAPTURE_TOKENS" = 1 ] && _say "  (--capture-tokens: each session streamed to .orchestrate/<id>.stream.jsonl for usage extraction; conductor stays lean)"
    local any=0
    while IFS=$'\t' read -r sg ppolicy; do
      any=1
      local rmodel reffort plabel="$ppolicy"
      IFS=$'\t' read -r rmodel reffort < <(_route "$(_goalfile "$dir" "$sg")")
      # Under MEGA_GATE_DISPATCH a gate sub-goal is RUN and only then held, so the plan must not
      # read as "skipped": name the dispatch and the hold in the same breath.
      if [ "$MEGA_GATE_DISPATCH" = 1 ]; then
        case "$ppolicy" in
          gate)    plabel="gate, dispatch then hold for human merge" ;;
          'gate!') plabel="gate!, dispatch then halt the whole loop for human merge" ;;
        esac
      fi
      _say "  -> $sg ($plabel)  [model: ${rmodel:-inherit}, effort: ${reffort:-inherit}]  [prompt: POINTER_PROMPT + goal-file + $([ -s "$dir/HANDOFF.md" ] && echo HANDOFF || echo no-handoff)]"
      [ "$ppolicy" = "gate!" ] && { _say "  == STOP at $sg (gate!: global halt for human review) =="; break; }
      [ "$ppolicy" = gate ] && { _say "  == STOP at $sg (gate: human review) =="; break; }
      [ "$step" = 1 ] && _say "     [--step] pause here for the operator before the next sub-goal"
    done < <(_subgoals "$roadmap" | awk -F'\t' '$3==0 {print $1"\t"$2}')
    [ "$any" = 1 ] || _say "  (no unchecked sub-goals)"
    # Preview the terminal action too (SPEC-118): with TIER4_CLOSE=1 a real run does NOT just print
    # "done" at the all-checked terminal -- it dispatches a live verifier session + a no-orphan sweep.
    # An operator previewing the plan must see that a `claude -p` session is about to fire.
    [ "$TIER4_CLOSE" = 1 ] \
      && _say "  -> (when all boxes are checked) TIER-4 mega-close: no-orphan sweep + 3 independent verifier sessions ($CLAUDE_CMD -p x3: integration-verifier / review-team / advisor, fail-closed aggregated), then HOLD the human gate [TIER4_CLOSE=1]"
    if [ "$board_mode" != roadmap ]; then
      _say ""; _say "[board mode: $board_mode]"
      _render_board "$dir" "$roadmap" "$board_mode"
    fi
    return 0
  fi

  while :; do
    # SPEC-106 TASK-004b size-dispatch (DEC-002/006/012): serial-vs-wave decided per cycle on the
    # ADMITTED count (post-`_wave_gate`), NOT the raw ready size (a no-deps mega-goal has ready size
    # N, so raw size can't gate the serial path). WAVE_CAP defaults to 1 (waves OFF) => this guard is
    # FALSE => the loop falls straight through to the byte-identical serial body below, exactly as the
    # pre-wavefront loop ran (the sacred invariant). Only WAVE_CAP>=2 even consults `_wave_gate`; only
    # `admitted>=2` (dep-free, Touches-declaring, provably-disjoint sub-goals) routes to `_wave_run`.
    # admitted<=1 falls through to the serial body on `_next`'s pick, byte-identical for that cycle.
    # `_wave_run` serializes its own flips under the flip lock and blocks until the wave drains, so we
    # `continue` to recompute the next cycle from the freshly re-read ROADMAP: one blocking wave per
    # cycle means no double-launch and no CAP overshoot across cycles. (Gate/`--step`/`--stream`/
    # `--board` on the wave path are TASK-005/007's scope; at the default CAP=1 they are untouched.)
    if [ "$WAVE_CAP" -ge 2 ]; then
      # gate! GLOBAL-STOP (SPEC-106 TASK-007 / DEC-010 / Edge case 8): a ready `gate!` sub-goal halts
      # the WHOLE loop for a human, even when independent ready sub-goals could still wave. Checked
      # BEFORE admission so nothing is admitted alongside it -- the wave quiesces entirely. This is
      # the wave-path twin of the serial `gate!` stop below; plain `gate` is NOT caught here (it is a
      # chain-stop: `_wave_gate` just never admits it, then it stops via the serial `_next` branch when
      # it becomes the pick). Clean human-stop: blocked event + message + return 0, exactly like the
      # pre-wavefront global `gate` stop.
      local gbang
      gbang=$(_ready_set "$roadmap" | awk -F'\t' '$2=="gate!"{print $1; exit}')
      if [ -n "$gbang" ]; then
        if [ "$MEGA_GATE_DISPATCH" = 1 ]; then
          # A gate! sub-goal is DISPATCHED (it does the work and opens the held PR) and only THEN
          # halts the loop. Force it as this cycle's serial pick so the wave still quiesces around
          # it -- nothing else is admitted alongside it, exactly as before; the only change is that
          # the gate! sub-goal's own work now happens instead of being skipped.
          forced_pick="$gbang"
        else
          _emit_event "$dir" "$gbang" blocked "gate!: global halt for human review"
          [ "$board_mode" != roadmap ] && _render_board "$dir" "$roadmap" "$board_mode" >/dev/null
          _say "[orchestrate] STOP (gate!): global halt for human review; $gbang is a gate! sub-goal. Resolve, then re-run."
          return 0
        fi
      fi
    fi

    # Wave admission. Skipped when a gate! sub-goal was forced as this cycle's pick above: the wave
    # quiesces around it, so nothing may be admitted alongside it.
    if [ "$WAVE_CAP" -ge 2 ] && [ -z "$forced_pick" ]; then
      local admitted_n
      admitted_n=$(_wave_gate "$dir" "$roadmap" | awk -F'\t' '$1=="run"{n++} END{print n+0}')
      if [ "$admitted_n" -ge 2 ]; then
        if _wave_run "$dir" "$roadmap"; then
          # Converge the landed wave (TASK-004c): merge its sub-goals ONE AT A TIME under the flip
          # lock, in ROADMAP order, via the mockable hook. A same-file cross-wave edit or a merge-hook
          # failure halts the loop (no self-claim). At the default WAVE_CAP=1 this block is unreachable,
          # so the serial path stays byte-identical.
          if ! _wave_converge "$dir" ${_WAVE_LANDED[@]+"${_WAVE_LANDED[@]}"}; then
            echo "[orchestrate] [wave] convergence flagged a same-file cross-wave conflict or a merge failure; halting (no self-claim)." >&2
            return 1
          fi
          continue
        fi
        echo "[orchestrate] [wave] a wave sub-goal did not complete (nonzero exit or unflipped box); halting (no self-claim)." >&2
        return 1
      fi
      # Wait-vs-complete termination guard (SPEC-106 TASK-006, Edge case 1). Reached only when
      # admitted<2 (no wave launched this cycle). If unchecked sub-goals REMAIN but the ready set is
      # EMPTY -- every remaining unchecked is dep-blocked, nothing is runnable, and no wave is in
      # flight (`_wave_run` blocks to drain before we get here) -- the dep-IGNORANT serial `_next`
      # below would wrongly RUN a dep-blocked sub-goal (proven: a mutual-dep cycle ran both boxes to
      # a false "done"). Halt for a human instead: a clear blocked message + NONZERO exit, never a
      # false-complete, never a spin. Guarded by `unchecked>0` so the legit all-checked completion
      # still falls through to `_next`'s empty -> "done" return-0 path. Only reachable on the wave
      # path (WAVE_CAP>=2); the serial default never enters this block, so serial stays byte-identical.
      local unchecked_n ready_n
      unchecked_n=$(_subgoals "$roadmap" | awk -F'\t' '$3==0 {n++} END{print n+0}')
      if [ "$unchecked_n" -gt 0 ]; then
        ready_n=$(_ready_set "$roadmap" | awk 'END{print NR+0}')
        if [ "$ready_n" -eq 0 ]; then
          _emit_event "$dir" "-" blocked "$unchecked_n unchecked, none runnable"
          [ "$board_mode" != roadmap ] && _render_board "$dir" "$roadmap" "$board_mode" >/dev/null
          echo "[orchestrate] [wave] blocked: $unchecked_n unchecked, none runnable (all remaining sub-goals are dep-blocked; no in-flight producer). Halting for human review (not a false-complete)." >&2
          return 1
        fi
        # Dep-blocked serial-fallthrough halt (review-fix FIX 2 / ID-090 item (d)). Reached only when
        # admitted<2 but ready_n>0: the code below falls through to `_next`'s pick, which is DEP-
        # IGNORANT (first unchecked ROADMAP line regardless of `depends`). If that pick is itself NOT
        # a member of the ready set (i.e. it IS dep-blocked -- proven live: a ROADMAP with an
        # unsatisfiable-dep sub-goal listed before independent ready ones got silently run/checked),
        # halt instead of falling through, same shape as the guard above. Entirely inside
        # WAVE_CAP>=2 so the serial `_next` pick below stays byte-identical. Membership is read from
        # awk's PRINTED output, not the pipe's exit status: `_ready_set`'s while-read loop always
        # returns nonzero on its own EOF, which under `pipefail` would corrupt an exit-code-based
        # check (pipefail reports the rightmost NONZERO stage, not simply the last stage).
        local fallthrough_pick found
        fallthrough_pick=$(_next "$roadmap" | cut -f1)
        found=$(_ready_set "$roadmap" | awk -F'\t' -v x="$fallthrough_pick" '$1==x{print "1"; exit}')
        if [ -n "$fallthrough_pick" ] && [ -z "$found" ]; then
          _emit_event "$dir" "$fallthrough_pick" blocked "dep-blocked, not in ready set"
          [ "$board_mode" != roadmap ] && _render_board "$dir" "$roadmap" "$board_mode" >/dev/null
          echo "[orchestrate] [wave] blocked: $fallthrough_pick is dep-blocked (not in ready set); halting for human review (not a false-complete)." >&2
          return 1
        fi
      fi
    fi

    local nx id policy
    if [ -n "$forced_pick" ]; then
      nx=$(_subgoals "$roadmap" | awk -F'\t' -v i="$forced_pick" '$1==i && $3==0 {print $1"\t"$2}')
      forced_pick=""
    else
      nx=$(_next "$roadmap")
    fi
    if [ -z "$nx" ]; then
      # All boxes checked. TIER-4 mega-close (SPEC-118) replaces the bare "done"-and-return: verify
      # the assembled wave (no-orphan sweep + integration-verifier + review-team + advisor) THEN HOLD
      # the human gate. TIER4_CLOSE=0 restores the old return (the unrelated-all-auto-test escape hatch).
      if [ "$TIER4_CLOSE" = 1 ]; then _tier4_close "$dir" "$roadmap"; return $?; fi
      _say "[orchestrate] all sub-goals checked; done."; return 0
    fi
    id=$(printf '%s' "$nx" | cut -f1); policy=$(printf '%s' "$nx" | cut -f2)

    # gate! GLOBAL-STOP on the serial path too (SPEC-106 TASK-007): when the pick is a `gate!`
    # sub-goal, halt the WHOLE loop for a human, preserving the pre-wavefront global `gate` stop
    # exactly (blocked event + message + return 0). Checked BEFORE plain `gate` since they are
    # distinct policy values. On WAVE_CAP=1 this is the ONLY gate! stop (the wave-block twin above
    # is skipped), and it is also the catch-all when the wave path falls through to `_next`.
    # A gate / gate! sub-goal is DISPATCHED like an auto one and HELD afterwards (MEGA_GATE_DISPATCH,
    # the default): its worker does the work, opens a DRAFT PR, marks it, and does NOT flip its box.
    # `gate_hold` carries the policy through the shared dispatch body below to the post-session hold.
    # MEGA_GATE_DISPATCH=0 restores the old stop-BEFORE-running behavior verbatim.
    local gate_hold=""
    if [ "$policy" = "gate!" ] || [ "$policy" = gate ]; then
      if [ "$MEGA_GATE_DISPATCH" = 1 ]; then
        gate_hold="$policy"
      elif [ "$policy" = "gate!" ]; then
        _emit_event "$dir" "$id" blocked "gate!: global halt for human review"
        [ "$board_mode" != roadmap ] && _render_board "$dir" "$roadmap" "$board_mode" >/dev/null
        _say "[orchestrate] STOP (gate!): global halt for human review; $id is a gate! sub-goal. Resolve, then re-run."
        return 0
      else
        _emit_event "$dir" "$id" blocked "gate: human review"
        [ "$board_mode" != roadmap ] && _render_board "$dir" "$roadmap" "$board_mode" >/dev/null
        _say "[orchestrate] STOP: $id is a gate sub-goal; open/await its PR for review, then re-run."
        # Advisory (ID-090 default flip): under the concurrent default (WAVE_CAP>=2) a `gate` holds only
        # its OWN dependent chain , independent branches with disjoint `## Touches` keep running in the
        # wave. If you meant "quiesce EVERYTHING for review", use `gate!` (global stop-all) instead. (On
        # a Touches-less mega-goal there is no concurrency, so this `gate` still stopped the whole loop.)
        [ "$WAVE_CAP" -ge 2 ] && echo "[orchestrate] [advisory] '$id' is a chain-stop \`gate\`; under WAVE_CAP=$WAVE_CAP independent Touches-disjoint branches keep running. Use \`gate!\` for a global stop-all." >&2
        return 0
      fi
    fi

    # Per-sub-goal model/effort routing (SPEC-087): read the goal file's hints and pass them as
    # flags, so this sub-goal runs on its own tier instead of inheriting Opus-for-everything.
    # Absent hint -> no flag -> inherit.
    # ID-096: reject an off-allowlist `Model:` tier pre-flight (same command-substitution exit-
    # code capture as the wave path above), same treatment as a `gate` sub-goal: halt the serial
    # loop for a human instead of dispatching a session that would die mid-`claude` on a typo.
    local rmodel reffort route_flags="" route_out route_rc
    route_out=$(_route "$(_goalfile "$dir" "$id")"); route_rc=$?
    IFS=$'\t' read -r rmodel reffort <<<"$route_out"
    if [ "$route_rc" != 0 ]; then
      # ID-390: _route now has TWO pre-flight rejections -- an off-allowlist claude `Model:` tier
      # AND a `Harness:` that is unknown or not enabled. Both already printed the precise reason to
      # stderr (the `orchestrate: ...` line), so this STOP stays GENERIC rather than hardcoding
      # "invalid Model: tier", which was a plain lie for a harness-gate rejection.
      _emit_event "$dir" "$id" blocked "rejected pre-flight by routing (model tier or harness gate)"
      [ "$board_mode" != roadmap ] && _render_board "$dir" "$roadmap" "$board_mode" >/dev/null
      _say "[orchestrate] STOP: $id rejected pre-flight by routing; see the 'orchestrate:' reason above. Fix the goal file, then re-run."
      return 0
    fi
    [ -n "$rmodel" ] && route_flags="$route_flags --model $rmodel"
    [ -n "$reffort" ] && route_flags="$route_flags --effort $reffort"
    # Guardrail (SG-11): a sub-goal with no goals/ file runs without its contract -- a re-discovery
    # hazard. Warn loudly (advisory; the loop still runs it on POINTER_PROMPT + handoff alone).
    if [ -z "$(_goalfile "$dir" "$id")" ]; then
      echo "[orchestrate] [guardrail] WARN: $id has no goals/ file; session runs without its contract (re-discovery hazard)." >&2
    fi
    _emit_event "$dir" "$id" executing "model=${rmodel:-inherit} effort=${reffort:-inherit}"
    # SPEC-101: record the run's routing facts so mega-dispatched runs are as measurable
    # as hand-run ones (assign.md makes this same START call). Before the session spawns,
    # so a run that dies mid-session is still tracked, not '?'.
    _emit_start "$dir" "$id"
    [ "$board_mode" != roadmap ] && _render_board "$dir" "$roadmap" "$board_mode" >/dev/null
    # ID-390: name the ACTUAL harness. This line hardcoded "$CLAUDE_CMD -p", which read as a plain
    # lie once a sub-goal could dispatch to codex ("running SG-01 ... (claude -p, model: gpt-5)").
    # An operator scanning a run log has to be able to see which vendor a sub-goal went to.
    local _rh; _rh=$(_harness_of "$(_goalfile "$dir" "$id")") || _rh="claude"
    _say "[orchestrate] running $id in a fresh session ($([ "$_rh" = claude ] && printf '%s -p' "$CLAUDE_CMD" || printf 'harness: %s' "$_rh"), model: ${rmodel:-inherit}, effort: ${reffort:-inherit}) ..."
    # Inject the prompt via a TEMP FILE on stdin, not a shell-interpolated argv arg (pi-swarm
    # borrow). Removes the backtick/${}/secret-guard bug class when the handoff body carries shell
    # metachars, and dodges ARG_MAX on a large injected handoff. `claude -p` reads the prompt from
    # stdin when no positional prompt is given.
    local pfile; pfile=$(mktemp)
    # Review-fix FIX 8: a Ctrl-C while this session is in flight otherwise leaves the prompt temp
    # file (it holds the injected HANDOFF content) sitting in ${TMPDIR:-/tmp}. The explicit `rm -f`
    # below covers the happy path; this trap covers an interrupt. Cheap to reset every cycle (only
    # EXIT trap this script sets on the serial path).
    trap 'rm -f "$pfile"' EXIT
    _build_prompt "$dir" "$id" "$gate_hold" > "$pfile"
    # Run the session via the extracted helper (TASK-000): it picks the correct run-path
    # (watchdog / --stream|det-handoff stream-json / plain) and returns the session exit code.
    # slog (the stream-log path, "" when no capture happened) comes back via _ROS_SLOG for the
    # grounded-completion + deterministic-handoff logic below.
    local rc=0 slog=""
    _run_one_session "$dir" "$id" "$pfile" "$route_flags" "$stream" || rc=$?
    slog="$_ROS_SLOG"
    rm -f "$pfile"
    trap - EXIT
    if [ "$rc" != 0 ]; then
      _emit_event "$dir" "$id" blocked "session exited nonzero ($rc)"
      [ "$board_mode" != roadmap ] && _render_board "$dir" "$roadmap" "$board_mode" >/dev/null
      echo "[orchestrate] session for $id exited nonzero; stopping." >&2
      return 1
    fi

    # Gate hold: the session ran; a human now merges. A gate sub-goal must NOT flip its own box, so
    # its completion is grounded on the PR EXISTING instead. No PR -> the same no-self-claim halt an
    # unflipped box gets: the session did not produce the one artifact the hold is about.
    if [ -n "$gate_hold" ]; then
      local prurl; prurl=$(_sg_pr_url "$dir" "$id")
      if [ -z "$prurl" ]; then
        _emit_event "$dir" "$id" blocked "$gate_hold: no PR opened (no self-claim)"
        [ "$board_mode" != roadmap ] && _render_board "$dir" "$roadmap" "$board_mode" >/dev/null
        echo "[orchestrate] [guardrail] $id is a $gate_hold sub-goal but opened no PR for its branch; halting (no self-claim, no advance on a dead/incomplete session)." >&2
        return 1
      fi
      _record_tokens "$dir" "$id" "$slog"
      _emit_event "$dir" "$id" blocked "$gate_hold: awaiting human merge ($prurl)"
      [ "$board_mode" != roadmap ] && _render_board "$dir" "$roadmap" "$board_mode" >/dev/null
      if [ "$gate_hold" = "gate!" ]; then
        _say "[orchestrate] STOP (gate!): global halt for human review; $id ran and opened $prurl. Merge it, then re-run."
      else
        _say "[orchestrate] STOP: $id is a gate sub-goal; it ran and opened $prurl for human review. Merge it, then re-run."
        [ "$WAVE_CAP" -ge 2 ] && echo "[orchestrate] [advisory] '$id' is a chain-stop \`gate\`; under WAVE_CAP=$WAVE_CAP independent Touches-disjoint branches keep running. Use \`gate!\` for a global stop-all." >&2
      fi
      return 0
    fi

    # grounded completion: advance only if the box actually flipped.
    local checked; checked=$(_subgoals "$roadmap" | awk -F'\t' -v i="$id" '$1==i {print $3}')
    if [ "$checked" != 1 ]; then
      # Merged-PR reconciliation before the halt (the false-halt fix). A worker commonly flips its box
      # INSIDE its PR; the PR merges, and this checkout is still behind, so the local box reads
      # unchecked and a healthy run halted. Consult the remote default branch. No-self-claim is
      # UNCHANGED: a remote box counts only when its line also carries a real `PR #<n>`, so a bare
      # checked box never advances the loop, on either side.
      local rview rline
      rview=$(_roadmap_remote_view "$dir" "$roadmap")
      if [ -n "$rview" ]; then
        rline=$(_sg_line "$rview" "$id")
        case "$rline" in
          '- ['[xX]']'*)
            if printf '%s' "$rline" | grep -qE 'PR #[0-9]+'; then
              checked=1
              _say "[orchestrate] [reconcile] $id box is checked on origin with $(printf '%s' "$rline" | grep -oE 'PR #[0-9]+' | head -1); accepting the merged-PR flip."
              # Mirror the merged flip into the LOCAL ROADMAP when the fast-forward could not run
              # (dirty tree). Without it `_next` re-picks this same sub-goal every cycle and the loop
              # spins forever. This writes the ONE box line the remote already carries, through the
              # same locked idempotent flip the loop uses -- it is a reconcile, never a claim, and it
              # never force-pulls anything else out of the operator's working tree.
              [ "$rview" = "$roadmap" ] || cmd_flip "$dir" "$id" >/dev/null 2>&1 || true
            fi ;;
        esac
        [ "$rview" = "$roadmap" ] || rm -f "$rview"
      fi
    fi
    if [ "$checked" != 1 ]; then
      _emit_event "$dir" "$id" blocked "box not flipped (no self-claim)"
      [ "$board_mode" != roadmap ] && _render_board "$dir" "$roadmap" "$board_mode" >/dev/null
      echo "[orchestrate] [guardrail] $id did not check its ROADMAP box; halting (no self-claim, no advance on a dead/incomplete session)." >&2
      return 1
    fi
    _emit_event "$dir" "$id" shipped "box checked"
    [ "$board_mode" != roadmap ] && _render_board "$dir" "$roadmap" "$board_mode" >/dev/null
    _say "[orchestrate] $id complete (box checked); advancing."

    # Deterministic handoff (SG-02): regenerate the two-tier handoff for the NEXT sub-goal from
    # this session's captured transcript, so the handoff is always produced and reproducible
    # rather than depending on the model having written a good one. Overwrites HANDOFF.md (hot)
    # and appends DECISIONS.md (warm, idempotent). Failure is non-fatal: the loop continues and
    # the session's own HANDOFF.md (if any) stands.
    if [ "$DETERMINISTIC_HANDOFF" = 1 ] && [ -s "$slog" ]; then
      local nx2 nid nraw ntitle
      nx2=$(_next "$roadmap")
      if [ -n "$nx2" ]; then
        nid=$(printf '%s' "$nx2" | cut -f1)
        nraw=$(_sg_line "$roadmap" "$nid"); ntitle=$(_sg_title "$nraw" "$nid")
        if "$LIB_ROOT/goal/handoff-gen" "$slog" --dir "$dir" --next-id "$nid" --next-title "$ntitle" --date "$(date -u +%F)"; then
          # Per-edge WRITE (SPEC-106 TASK-005): handoff-gen always writes $dir/HANDOFF.md; if the
          # JUST-completed $id HAS DEPENDENTS, rename it to the per-edge HANDOFF-<id>.md so parallel
          # siblings (CAP>1) never clobber one hot file. No dependents -> leave plain (byte-identical).
          if _sg_dependents "$roadmap" "$id"; then
            mv -f "$dir/HANDOFF.md" "$dir/HANDOFF-$id.md" 2>/dev/null || true
          fi
          _emit_event "$dir" "$id" handoff "deterministic -> $nid"
          _say "[orchestrate] deterministic handoff written for $nid (HANDOFF.md overwritten, DECISIONS.md appended)."
        else
          echo "[orchestrate] WARN: deterministic handoff generation failed for $id; the session's own HANDOFF.md (if any) stands." >&2
        fi
      fi
    fi
    # Token accounting (SPEC-110): whenever this session was CAPTURED to stream-json (--stream or
    # DETERMINISTIC_HANDOFF both set $slog), extract per-session usage and record a TOKENS ledger
    # line for this sub-goal's rid, so lane-telemetry can price the run. CAPTURE-GATED: the default
    # no-capture path leaves $slog empty and writes NO token line (honest usage=?, never a fake
    # zero). Additive marker; non-fatal (a parse miss must not stop the loop). SPEC-087 default
    # invocation is untouched (this runs only when a capture exists). Delegates to the shared
    # `_record_tokens` helper (ID-094) so the wave reap loop below writes to the identical stream.
    _record_tokens "$dir" "$id" "$slog"
    # --step: pause for the operator between sub-goals, but only when the NEXT one is auto (the
    # loop would actually run it). If next is a gate, the gate-stop below is the natural halt, so
    # don't double up with a pause first.
    if [ "$step" = 1 ]; then
      local nxt; nxt=$(_next "$roadmap")
      if [ -n "$nxt" ] && [ "$(printf '%s' "$nxt" | cut -f2)" = auto ]; then
        _step_pause "$id" || return 0
      fi
    fi
  done
}

# Hidden re-entry point for a tmux-hosted wave session (SPEC-119): `_pane_spawn` execs THIS
# subcommand as the pane's command line -- `tmux new-window` always execs a fresh command line, it
# cannot call a bash function living in the orchestrator's own process. Runs the EXACT same
# `_run_one_session` the plain background-job path uses (no duplicated dispatch logic), then writes
# its exit code to $donefile so `_wave_run`'s reap loop (which cannot `wait` on a grandchild in a
# different process tree) can poll for completion instead of `kill -0`/`wait`. Never invoked by an
# operator directly; deliberately absent from the `usage:` string in `main()` below.
cmd_pane_exec() {  # megadir id pfile route_flags donefile
  local megadir="$1" id="$2" pfile="$3" route_flags="$4" donefile="$5"
  _run_one_session "$megadir" "$id" "$pfile" "$route_flags" 0
  local rc=$?
  printf '%s\n' "$rc" > "$donefile"
  return "$rc"
}

main() {
  local cmd="${1:-}"; shift 2>/dev/null || true
  case "$cmd" in
    next) cmd_next "$@" ;;
    run)  cmd_run "$@" ;;
    flip) cmd_flip "$@" ;;
    _pane-exec) cmd_pane_exec "$@" ;;
    # Subagent panes (SPEC-234): read-only tmux tail windows over background-subagent transcripts.
    # `_pane-tail` is the hidden re-entry the pane's own command line runs, deliberately absent
    # from the usage string below, same as `_pane-exec`.
    panes) cmd_panes "$@" ;;
    _pane-tail) cmd_pane_tail "$@" ;;
    # Overnight queue LAUNCHER (SPEC-148): a thin alias for the sibling lib/queue/queue.sh, whose logic
    # lives entirely there (orchestrate.sh's own suite stays untouched). `orchestrate.sh queue
    # <src>` == `queue.sh run <src>`. It drives REAL interactive `/goal` sessions via terminal-mux
    # send-keys, NOT the headless `claude -p` per-sub-goal path the rest of this driver uses.
    queue) exec "$ORCH_DIR/queue.sh" run "$@" ;;
    *) echo "usage: orchestrate.sh {next|run|flip|panes|queue} <megagoal-dir|src> [<SG-NN>] [--dry-run] [--step] [--stream] [--capture-tokens] [--board=roadmap|kanban|both]" >&2; exit 64 ;;
  esac
}

# Only run main when executed, not when sourced (so tests can source and call the internal
# helpers, e.g. _ready_set, directly). Same guard as lib/gate/dispatch-gate.sh.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
