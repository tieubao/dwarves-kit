#!/usr/bin/env bash
# test-docs-wiring.sh (SPEC-120, executes ADR-0032's docs-last sub-goal)
#
# Two things this file proves, mirroring the kit-hardening c6fbd99 precedent
# (tests/test-right-arm-parity.sh): (1) WORKFLOW.md + AGENTS.md actually describe the
# delegate run model, the ledger-under-delegation guarantee, and the opt-in multiplexer
# (AC1-5); (2) every one of those documented capabilities has a LIVE dispatch path in
# lib/queue/orchestrate.sh / lib/gate/gate-ledger.sh -- a no-orphan sweep, one grep-verified call
# site per capability, not just a flag/env-var definition (AC6-9). AC10 is the load-
# bearing NEGATIVE CONTROL: a planted over-claim (multiplexer default-on) run through the
# SAME sweep function must be CAUGHT, proving the sweep is not a rubber stamp.
#
# Run: bash tests/test-docs-wiring.sh   (exit 0 = all AC green)

set -uo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$KIT_DIR/docs/WORKFLOW.md"  # bulk lives in docs/ (SPEC-185); root WORKFLOW.md is a thin stub
AGENTS="$KIT_DIR/AGENTS.md"
ORCH="$KIT_DIR/lib/queue/orchestrate.sh"
LEDGER="$KIT_DIR/lib/gate/gate-ledger.sh"
PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert() { TOTAL=$((TOTAL+1)); if [ "$2" -eq 0 ]; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1)); else echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL+1)); fi; }

echo "=== docs-wiring (SPEC-120 AC1-AC10) ==="

# --- the no-orphan sweep function ------------------------------------------------------
# _wired <corpus-file> <fixed-string>: 0 if the exact call-site string is present in the
# corpus file (the capability is LIVE-wired), 1 otherwise (orphan / over-claim). Uses
# fixed-string match (grep -F), same style as test-right-arm-parity.sh's AC checks, keyed
# on the CALL SITE (not a flag/env-var default line -- a renamed/removed call site must
# fail even if the env var default is untouched; Edge Case 1).
_wired() {  # corpus fixed_string
  grep -qF -- "$2" "$1" 2>/dev/null
}

echo "--- AC1-5: doc-presence (WORKFLOW.md / AGENTS.md carry the required vocabulary) ---"

[ -f "$WORKFLOW" ]; assert "AC1: WORKFLOW.md exists" $?
grep -qi 'mega-goal delegate execution' "$WORKFLOW"; assert "AC1: WORKFLOW.md has a Mega-goal delegate execution section" $?
grep -qi 'official outer loop' "$WORKFLOW"; assert "AC1: WORKFLOW.md states /goal stays the official outer loop" $?

grep -qi 'per-sub-goal model routing\|per-sub-goal.*routing' "$WORKFLOW"; assert "AC2: WORKFLOW.md describes per-sub-goal model routing" $?

grep -qi 'ledger-under-delegation' "$WORKFLOW"; assert "AC3: WORKFLOW.md names the ledger-under-delegation guarantee" $?
grep -qi 'stream-to-file\|stream-to-FILE' "$WORKFLOW"; assert "AC3: WORKFLOW.md describes token capture as stream-to-file" $?
grep -qi 'debt ledger' "$WORKFLOW"; assert "AC3: WORKFLOW.md describes the debt-ledger split" $?

grep -qi 'tier-4 close\|TIER4_CLOSE' "$WORKFLOW"; assert "AC4: WORKFLOW.md describes the mega TIER-4 close" $?
grep -qi 'no-orphan sweep' "$WORKFLOW"; assert "AC4: WORKFLOW.md names the no-orphan sweep as part of the close" $?
grep -qi 'holds the human gate\|HOLDS the human gate\|never auto-merges' "$WORKFLOW"; assert "AC4: WORKFLOW.md states the close holds the human gate (never auto-merges)" $?

grep -qi 'multiplexer' "$WORKFLOW"; assert "AC5: WORKFLOW.md documents the multiplexer" $?
grep -qi 'opt-in and off by default\|opt-in, off by default\|off by default' "$WORKFLOW"; assert "AC5: WORKFLOW.md states the multiplexer is opt-in/off-by-default" $?
# An affirmative over-claim line ("the multiplexer IS default-on") is a finding; a line that
# NAMES the over-claim only to forbid it (a negation word on the same line) is not -- the docs
# are expected to warn against this exact mistake by name (this section does, on purpose).
overclaim_hit=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  if ! { printf '%s' "$line" 2>/dev/null || :; } | grep -qiE 'not |never|n.t describe|opt-in|off by default'; then
    overclaim_hit=1
  fi
done < <(grep -inE 'multiplexer.{0,40}(default-on|on by default|enabled by default)' "$WORKFLOW")
assert "AC5: WORKFLOW.md does NOT affirmatively describe the multiplexer as default-on" "$overclaim_hit"

[ -f "$AGENTS" ]; assert "AC1: AGENTS.md exists" $?
grep -qi 'mega-goal delegate execution' "$AGENTS"; assert "AC1: AGENTS.md points at the delegate-execution section" $?

grep -qi 'read-only subagent panes\|subagent panes' "$WORKFLOW"
assert "AC11: WORKFLOW.md documents read-only subagent panes (SPEC-234)" $?

echo "--- AC6-9: no-orphan sweep (each documented capability has a LIVE call site) ------"

_wired "$ORCH" 'route_flags="$route_flags --model $rmodel"'
assert "AC6: Model: -> --model routing fires (live call site in lib/queue/orchestrate.sh)" $?

_wired "$ORCH" 'bash "$LIB_ROOT/gate/gate-ledger.sh" tokens'
assert "AC7: token capture records via gate-ledger.sh (live call site in lib/queue/orchestrate.sh)" $?
_wired "$LEDGER" "printf '%s | TOKENS | %s'"
assert "AC7: the TOKENS ledger marker is emitted (live call site in lib/gate/gate-ledger.sh)" $?

_wired "$ORCH" '_tier4_close "$dir" "$roadmap"'
assert "AC8: TIER-4 close is actually invoked from the run terminal (live call site in lib/queue/orchestrate.sh)" $?

_wired "$ORCH" '_pane_spawn "$megadir" "$id" "$wt" "$pfile" "$route_flags" "$donefile"'
assert "AC9: a pane spawns under MULTIPLEXER=1 (live call site in lib/queue/orchestrate.sh)" $?

# `panes` (SPEC-234) has no in-kit caller under DEFAULT (background-subagent) run mode -- the
# real invoker is the conductor's own prose in commands/mega.md, a named exemption from the
# usual "grep the .sh corpus" shape. The live-call-site half greps mega.md for the invocation
# plus the main() dispatch entry that makes `panes` actually reachable as a subcommand.
_wired "$KIT_DIR/commands/mega.md" 'orchestrate.sh panes'
assert "AC11: mega.md's conductor prose points at 'orchestrate.sh panes' (live invoker, named exemption)" $?
_wired "$ORCH" 'panes) cmd_panes "$@" ;;'
assert "AC11: panes has a live main() dispatch entry in lib/queue/orchestrate.sh" $?

echo "--- AC10 [NEGATIVE CONTROL, load-bearing]: an over-claim is CAUGHT by the sweep ---"

# The planted claim: "the multiplexer is enabled by default for every wave run" would only
# be true if MULTIPLEXER defaulted to 1. It does not (MULTIPLEXER="${MULTIPLEXER:-0}"), so
# the corpus fact this claim depends on must be independently confirmed ABSENT first --
# otherwise the negative control could silently rot into a false pass (spec Edge Case 2).
PLANTED_CLAIM='the multiplexer is enabled by default for every wave run'
FALSE_COROLLARY='MULTIPLEXER="${MULTIPLEXER:-1}"'

if _wired "$ORCH" "$FALSE_COROLLARY"; then
  # The corollary a default-on claim would require is actually present -- the negative
  # control has rotted (the real default changed); fail loudly instead of silently passing.
  assert "AC10: negative-control precondition holds (MULTIPLEXER does NOT default to 1 today)" 1
else
  assert "AC10: negative-control precondition holds (MULTIPLEXER does NOT default to 1 today)" 0
fi

if _wired "$ORCH" "$FALSE_COROLLARY"; then
  sweep_verdict=wired
else
  sweep_verdict=orphan
fi
if [ "$sweep_verdict" = orphan ]; then
  assert "AC10: the sweep CATCHES the planted over-claim ('$PLANTED_CLAIM')" 0
else
  assert "AC10: the sweep CATCHES the planted over-claim ('$PLANTED_CLAIM')" 1
fi

echo ""
echo "=== $PASS/$TOTAL passed ==="
[ "$FAIL" -eq 0 ]
