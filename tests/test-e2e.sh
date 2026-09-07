#!/usr/bin/env bash
# test-e2e.sh -- the golden run (SPEC-067 / ID-055).
#
# One simulated run walks the WHOLE loop, board pull -> classify -> START -> grill ->
# phase gates -> ship -> check, against a temp repo + temp log dir, then asserts that
# the three read surfaces AGREE about what happened:
#   gate-ledger  (check passes; progress reads complete n/n)
#   lane-telemetry (report counts the run + the ship; trace renders the story; no misfires)
#   backlog      (the board row walked queued -> claimed -> shipped)
# Unit pins prove each part in isolation; THIS catches cross-lib wiring drift (a column
# shift, a renamed phase, a format change one consumer missed).
set -uo pipefail
# -e intentionally omitted: assertions use ok()/bad() wrappers; a bare command that must
# not fail gets an explicit || guard (a swallowed failure would mint false PASSes).

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
PASS=0; FAIL=0; TOTAL=0

ok()   { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}PASS${NC} $1"; }
bad()  { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo -e "  ${RED}FAIL${NC} $1"; }
expect() {  # <name> <needle> <haystack>  (grep -q = BRE: parens in needles are LITERAL)
  if { trap '' PIPE; printf '%s' "$3" 2>/dev/null || :; } | grep -q "$2"; then ok "$1"; else bad "$1 (missing '$2')"; fi
}

echo "=== golden run: one task end to end (SPEC-067) ==="

# --- a temp world: repo + logs ---
WORLD=$(mktemp -d "${TMPDIR:-/tmp}/dwarves-kit-e2e.XXXXXX")
trap 'rm -rf "$WORLD"' EXIT   # always under $TMPDIR, never the repo
export DWARVES_KIT_LOG_DIR="$WORLD/logs"
REPO="$WORLD/repo"
mkdir -p "$REPO/_meta" "$REPO/docs/verification"
git -C "$WORLD" init -q "$REPO"; git -C "$REPO" config user.email t@t.t; git -C "$REPO" config user.name t
touch "$REPO/docs/verification/README.md"
cat > "$REPO/_meta/BACKLOG.md" <<'BOARD'
## Active queue

| ID | What | Status |
|---|---|---|
| ID-001 | add a --version flag to the demo tool | queued |
BOARD

BACKLOG() { BACKLOG_FILE="$REPO/_meta/BACKLOG.md" bash "$KIT_DIR/lib/board/backlog.sh" "$@"; }
GL() { bash "$KIT_DIR/lib/gate/gate-ledger.sh" "$@"; }
LT() { bash "$KIT_DIR/lib/telemetry/lane-telemetry.sh" "$@"; }

# --- 1. board pull ---
NEXT=$(BACKLOG next)
expect "board: next picks the queued row" "^ID-001$" "$NEXT"
BACKLOG set ID-001 claimed "e2e" >/dev/null
expect "board: claimed" "claimed" "$(BACKLOG board)"

TASK="add a --version flag to the demo tool"

# --- 2. classify both axes ---
# NOTE: the original fixture said "demo CLI" and the type classifier returned data-tool
# (the bare \bcli\b anchor steals feature-work-ON-a-cli). Real finding, filed as ID-057
# per the telemetry disposition contract; the golden run uses a clean phrase.
LANE=$(bash "$KIT_DIR/lib/classify/lane-classify.sh" classify "$TASK")
TYPE=$(bash "$KIT_DIR/lib/classify/task-type-classify.sh" classify "$TASK")
expect "classify: lane" "^tiny$\|^normal$" "$LANE"
expect "classify: type is spec-feature" "^spec-feature$" "$TYPE"
LANE="normal"   # chosen (a flag still wants a spec + tests in this demo)

# --- 3. START + the road ---
GL start e2e-demo "$LANE" "$LANE" "$TYPE" "$TYPE" e2e-repo >/dev/null || { bad "GL start failed"; exit 1; }
expect "plan: announces the road" "grill" "$(GL plan "$LANE")"
expect "progress: opens at step 1" "step 1/9 (grill)" "$(GL progress e2e-demo "$LANE")"

# --- 4. walk the phases ---
# (SPEC-122 adds a "Design record" row, run-lite for normal lane, between spec and
# test-plan in plan order -- the normal-lane plan grows from 8 to 9 steps)
GL record e2e-demo grill ran "2 questions resolved" >/dev/null
GL record e2e-demo think ran "intent confirmed" >/dev/null
GL record e2e-demo spec ran "spec written" >/dev/null
GL record e2e-demo design-record ran "obvious: <why> collapse noted (SPEC-122)" >/dev/null
expect "progress: mid-run pointer" "step 5/9 (test-plan)" "$(GL progress e2e-demo "$LANE")"
GL record e2e-demo test-plan skipped "lite; matrix in spec" >/dev/null
GL record e2e-demo build ran "flag implemented, tests green" >/dev/null
GL record e2e-demo review ran "SHIP findings=0" >/dev/null
GL record e2e-demo docs ran "README flag table" >/dev/null
GL record e2e-demo ship ran "shipping pr=#1" >/dev/null

# --- 5. the three surfaces agree ---
if GL check "$LANE" e2e-demo >/dev/null 2>&1; then ok "gate-ledger: check passes"; else bad "gate-ledger: check failed"; fi
expect "progress: complete" "complete (9/9)" "$(GL progress e2e-demo "$LANE")"
REPORT=$(LT report)
expect "telemetry: the run is counted" "runs: 1" "$REPORT"
expect "telemetry: the ship is counted" "shipped: 1" "$REPORT"
expect "telemetry: no misroutes" "lane-misrouted: 0   type-misrouted: 0" "$REPORT"
expect "telemetry: review verdict surfaces" "SHIP findings=0" "$REPORT"
expect "misfires: clean run reports none" "(no misfires recorded)" "$(LT misfires)"
TRACE=$(LT trace e2e-demo)
expect "trace: routing header" "lane: normal (classified: normal)" "$TRACE"
expect "trace: ship line in the story" "shipping pr=#1" "$TRACE"
BACKLOG set ID-001 shipped "pr=#1" >/dev/null
expect "board: shipped" "shipped" "$(BACKLOG board)"

# --- 6. drift control: a misrouted run is SEEN by all read surfaces ---
GL start e2e-drift tiny full eval spec-feature e2e-repo >/dev/null || { bad "GL start (drift) failed"; exit 1; }
expect "telemetry: misroute visible in report" "lane-misrouted: 1" "$(LT report)"
expect "telemetry: misroute named in misfires" "e2e-drift: chosen=tiny classified=full" "$(LT misfires)"
expect "trace: misfire flagged" "<< LANE MISFIRE" "$(LT trace e2e-drift)"

echo ""
echo "=== Results ==="
echo -e "Passed: ${GREEN}$PASS${NC} / $TOTAL"
if [ "$FAIL" -gt 0 ]; then echo -e "${RED}$FAIL e2e assertions failed.${NC}"; exit 1; fi
echo -e "${GREEN}Golden run green.${NC}"
