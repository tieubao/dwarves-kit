#!/usr/bin/env bash
# test-gate-outcome.sh -- SPEC-129, kit-run-integrity SG-01.
# Validates the additive `| OUTCOME |` marker on gate-ledger.sh: a start/end timing bracket
# (duration derivable) + caught=<bool>, plus the round-trip reader and the live ship-gate
# emit. The load-bearing property is ADDITIVE-EQUIVALENCE: every existing reader is
# byte-identical with the OUTCOME marker present vs absent.
#
# Isolation: every case runs under a fresh DWARVES_KIT_LOG_DIR so the real machine corpus is
# never touched. Cross-platform: no BSD-only date/stat constructs (asserted by a grep guard).
#
# Run: bash tests/test-gate-outcome.sh   (exit 0 = all AC green)

set -uo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GL="$KIT_DIR/lib/gate/gate-ledger.sh"
LT="$KIT_DIR/lib/telemetry/lane-telemetry.sh"
SHIP="$KIT_DIR/hooks/ship-gate.sh"

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert() { TOTAL=$((TOTAL+1)); if [ "$2" -eq 0 ]; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1)); else echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL+1)); fi; }

TMPS=()
_mk() { local d; d="$(mktemp -d)"; TMPS+=("$d"); printf '%s' "$d"; }
cleanup() { local d; for d in "${TMPS[@]:-}"; do [ -n "$d" ] && rm -rf "$d" 2>/dev/null; done; }
trap cleanup EXIT

# run gate-ledger under an isolated log dir
LOGD=""
gl() { env DWARVES_KIT_LOG_DIR="$LOGD" bash "$GL" "$@"; }
new_log() { LOGD="$(_mk)/logs"; mkdir -p "$LOGD/runs"; }

echo "=== gate-outcome (SPEC-129 AC1-AC9) ==="

# ---------------------------------------------------------------------------
# AC1: round-trip -- emit start/end, read back caught + duration for a rid.
# ---------------------------------------------------------------------------
new_log
gl outcome rt ship start >/dev/null 2>&1
sleep 1
gl outcome rt ship end caught=true >/dev/null 2>&1
RT="$(gl outcome-read rt ship 2>/dev/null)"
{ trap '' PIPE; echo "$RT" 2>/dev/null || :; } | grep -q '^ship caught=true dur_s=' && assert "AC1 round-trip: reads back phase+caught+dur_s" 0 || assert "AC1 round-trip: reads back phase+caught+dur_s (got '$RT')" 1
DUR="$(echo "$RT" | sed -nE 's/.*dur_s=([0-9]+).*/\1/p')"
[ -n "$DUR" ] && [ "$DUR" -ge 1 ] 2>/dev/null && assert "AC1 duration derivable (dur_s>=1 after a 1s bracket)" 0 || assert "AC1 duration derivable (got dur_s='$DUR')" 1

# ---------------------------------------------------------------------------
# AC2: caught=true on a non-pass, caught=false on a clean pass.
# ---------------------------------------------------------------------------
new_log
gl outcome c1 review start >/dev/null 2>&1
gl outcome c1 review end caught=true >/dev/null 2>&1
gl outcome c1 build start >/dev/null 2>&1
gl outcome c1 build end caught=false >/dev/null 2>&1
gl outcome-read c1 review 2>/dev/null | grep -q 'caught=true'  && assert "AC2 caught=true recorded on a non-pass" 0 || assert "AC2 caught=true recorded on a non-pass" 1
gl outcome-read c1 build  2>/dev/null | grep -q 'caught=false' && assert "AC2 caught=false recorded on a clean pass" 0 || assert "AC2 caught=false recorded on a clean pass" 1

# ---------------------------------------------------------------------------
# AC3: caught defaults to false when omitted (clean pass is the safe default).
# ---------------------------------------------------------------------------
new_log
gl outcome d1 ship start >/dev/null 2>&1
gl outcome d1 ship end >/dev/null 2>&1
gl outcome-read d1 ship 2>/dev/null | grep -q 'caught=false' && assert "AC3 caught defaults to false when omitted" 0 || assert "AC3 caught defaults to false when omitted" 1

# ---------------------------------------------------------------------------
# AC4: bad caught value is rejected (rc 64), no line written.
# ---------------------------------------------------------------------------
new_log
gl outcome b1 ship start >/dev/null 2>&1
gl outcome b1 ship end caught=maybe >/dev/null 2>&1; rc=$?
[ "$rc" -eq 64 ] && assert "AC4 bad caught value rejected (rc 64)" 0 || assert "AC4 bad caught value rejected (rc=$rc)" 1
gl outcome b1 ship end caught=maybe >/dev/null 2>&1 || true
gl show b1 2>/dev/null | grep -q 'end |' && assert "AC4 rejected end wrote no line" 1 || assert "AC4 rejected end wrote no line" 0
# bad event rejected too
gl outcome b1 ship middle >/dev/null 2>&1; rc=$?
[ "$rc" -eq 64 ] && assert "AC4 bad event rejected (rc 64)" 0 || assert "AC4 bad event rejected (rc=$rc)" 1

# ---------------------------------------------------------------------------
# AC5: an `end` with no prior `start` is honest -- dur_s=0, not an error.
# ---------------------------------------------------------------------------
new_log
gl outcome o1 orphan end caught=true >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && assert "AC5 unbracketed end succeeds (rc 0)" 0 || assert "AC5 unbracketed end succeeds (rc=$rc)" 1
gl outcome-read o1 orphan 2>/dev/null | grep -q 'caught=true dur_s=0' && assert "AC5 unbracketed end -> dur_s=0 (honest)" 0 || assert "AC5 unbracketed end -> dur_s=0 (honest)" 1

# ---------------------------------------------------------------------------
# AC6: incomplete bracket (start, no end) reads back as "incomplete".
# ---------------------------------------------------------------------------
new_log
gl outcome i1 review start >/dev/null 2>&1
gl outcome-read i1 review 2>/dev/null | grep -q '^review incomplete' && assert "AC6 start-without-end reads as incomplete" 0 || assert "AC6 start-without-end reads as incomplete" 1

# ---------------------------------------------------------------------------
# AC7: ADDITIVE-EQUIVALENCE -- every existing reader is byte-identical with the
# OUTCOME marker present vs absent. Build a full run, capture readers, insert
# OUTCOME lines interleaved, re-capture, diff.
# ---------------------------------------------------------------------------
new_log
build_run() {   # $1 = rid ; seed a realistic full-lane run (START + gates + TOKENS + DEBT)
  local r="$1"
  gl start "$r" full full spec-feature spec-feature dwarves-kit >/dev/null 2>&1
  gl record "$r" grill ran "seeded" >/dev/null 2>&1
  gl record "$r" think ran "seeded" >/dev/null 2>&1
  gl record "$r" build ran "seeded" >/dev/null 2>&1
  gl record "$r" review ran "clean findings=0" >/dev/null 2>&1
  gl override "$r" spec "seeded override reason" >/dev/null 2>&1
  gl record "$r" ship ran "shipping pr=#1" >/dev/null 2>&1
  gl tokens "$r" in=100 out=50 cache_read=10 cache_create=5 >/dev/null 2>&1
  gl debt "$r" significance=high worthiness=high verdict=tap >/dev/null 2>&1
  gl action "$r" "escaped-from=SPEC-001" >/dev/null 2>&1
}
build_run base
# capture each existing reader BEFORE the OUTCOME marker exists
B_SHOW="$(gl show base 2>&1)"
B_CHECK="$(gl check full base 2>&1; echo rc=$?)"
B_DESCENT="$(gl descent base full 2>&1)"
B_PROGRESS="$(gl progress base full 2>&1)"
B_ROWS="$(env DWARVES_KIT_LOG_DIR="$LOGD" NO_COLOR=1 bash "$LT" 2>&1)"
# now inject OUTCOME lines directly into the ledger (interleaved, as a live emit would)
LEDGER_FILE="$LOGD/runs/base.log"
{
  echo "2026-07-04T00:00:00Z | OUTCOME | ship | start | at=1000"
  echo "2026-07-04T00:00:05Z | OUTCOME | ship | end | at=1005 caught=false dur_s=5"
  echo "2026-07-04T00:00:06Z | OUTCOME | review | start | at=1006"
  echo "2026-07-04T00:00:09Z | OUTCOME | review | end | at=1009 caught=true dur_s=3"
} >> "$LEDGER_FILE"
# re-capture each reader WITH the OUTCOME lines present
A_CHECK="$(gl check full base 2>&1; echo rc=$?)"
A_DESCENT="$(gl descent base full 2>&1)"
A_PROGRESS="$(gl progress base full 2>&1)"
A_ROWS="$(env DWARVES_KIT_LOG_DIR="$LOGD" NO_COLOR=1 bash "$LT" 2>&1)"

[ "$B_CHECK" = "$A_CHECK" ]       && assert "AC7 check() byte-identical with OUTCOME present" 0 || assert "AC7 check() byte-identical (B='$B_CHECK' A='$A_CHECK')" 1
[ "$B_DESCENT" = "$A_DESCENT" ]   && assert "AC7 descent() byte-identical with OUTCOME present" 0 || assert "AC7 descent() byte-identical" 1
[ "$B_PROGRESS" = "$A_PROGRESS" ] && assert "AC7 progress() byte-identical with OUTCOME present" 0 || assert "AC7 progress() byte-identical" 1
[ "$B_ROWS" = "$A_ROWS" ]         && assert "AC7 _rows()/lane-telemetry byte-identical with OUTCOME present" 0 || assert "AC7 _rows()/lane-telemetry byte-identical (diff below)
$(diff <(printf '%s' "$B_ROWS") <(printf '%s' "$A_ROWS"))" 1
# show() legitimately changes (the OUTCOME lines ARE new content); assert the ORIGINAL lines survive unchanged
echo "$B_SHOW" | while IFS= read -r line; do gl show base 2>&1 | grep -qF "$line" || exit 1; done && assert "AC7 show() preserves every pre-existing line" 0 || assert "AC7 show() preserves every pre-existing line" 1

# ---------------------------------------------------------------------------
# AC7b: additive property is SENSITIVE -- OUTCOME emitted via the REAL verb must not
# change descent() output. This is the NEGATIVE-CONTROL TARGET: descent() keys on
# $2=="GATE" and treats any gate line's phase as disposed. If the verb's marker field-2
# were flipped from OUTCOME to GATE, descent would pick up the outcome lines as gate rows
# and this assertion goes RED. grill is left UNDISPOSED so a flipped `think` outcome line
# manufactures a "think recorded before grill disposed" violation.
# ---------------------------------------------------------------------------
new_log
gl start nc full full spec-feature spec-feature dwarves-kit >/dev/null 2>&1
gl record nc build ran seeded >/dev/null 2>&1   # a LATE phase; grill/think left undisposed
NC_BEFORE="$(gl descent nc full 2>&1)"
gl outcome nc think start >/dev/null 2>&1
gl outcome nc think end caught=false >/dev/null 2>&1
NC_AFTER="$(gl descent nc full 2>&1)"
[ "$NC_BEFORE" = "$NC_AFTER" ] && assert "AC7b descent() unchanged by OUTCOME via the real verb (additive property; negative-control target)" 0 || assert "AC7b descent() unchanged by OUTCOME via the real verb (BEFORE!=AFTER)" 1

# ---------------------------------------------------------------------------
# AC8: PORTABILITY -- no BSD-only date/stat constructs in the changed code.
# ---------------------------------------------------------------------------
# Strip comment lines first: the file's own docstrings NAME the `date -d` trap they avoid.
if grep -vE '^[[:space:]]*#' "$GL" | grep -nE 'date -d|date -r|stat -f|sed -i '"''" >/dev/null 2>&1; then
  assert "AC8 gate-ledger.sh free of BSD-only date/stat/sed constructs" 1
else
  assert "AC8 gate-ledger.sh free of BSD-only date/stat/sed constructs" 0
fi
# the duration path uses `date +%s` (portable) only
grep -q 'now_epoch() { date +%s; }' "$GL" && assert "AC8 duration uses portable date +%s" 0 || assert "AC8 duration uses portable date +%s" 1

# ---------------------------------------------------------------------------
# AC9: LIVE PATH -- the ship-gate hook emits an OUTCOME bracket on block + pass.
# ---------------------------------------------------------------------------
# Verify the wiring exists in the hook (the emit is best-effort + side-effect-only, so the
# no-orphan check is: the hook references the `outcome` verb at its check boundary).
grep -q 'outcome "\$SLUG" ship start'  "$SHIP" && assert "AC9 ship-gate emits OUTCOME start at its gate boundary" 0 || assert "AC9 ship-gate emits OUTCOME start at its gate boundary" 1
grep -q 'outcome "\$SLUG" ship end caught=true'  "$SHIP" && assert "AC9 ship-gate emits caught=true on block" 0 || assert "AC9 ship-gate emits caught=true on block" 1
grep -q 'outcome "\$SLUG" ship end caught=false' "$SHIP" && assert "AC9 ship-gate emits caught=false on clean pass" 0 || assert "AC9 ship-gate emits caught=false on clean pass" 1

# ---------------------------------------------------------------------------
# AC10: ID-398 failure-policy vocabulary -- optional `policy=` on `outcome ... end`,
# round-tripped by outcome-read, validated as a closed enum, omitted stays additive.
# ---------------------------------------------------------------------------
new_log
gl outcome pv1 build start >/dev/null 2>&1
gl outcome pv1 build end caught=true policy=escalate >/dev/null 2>&1
gl outcome-read pv1 build 2>/dev/null | grep -q 'policy=escalate' && assert "AC10 policy=escalate round-trips via outcome-read" 0 || assert "AC10 policy=escalate round-trips via outcome-read" 1

new_log
gl outcome pv2 build start >/dev/null 2>&1
gl outcome pv2 build end caught=false policy=bogus >/dev/null 2>&1; rc=$?
[ "$rc" -eq 64 ] && assert "AC10 bad policy value rejected (rc 64)" 0 || assert "AC10 bad policy value rejected (rc=$rc)" 1

new_log
gl outcome pv3 build start >/dev/null 2>&1
gl outcome pv3 build end caught=false >/dev/null 2>&1
gl outcome-read pv3 build 2>/dev/null | grep -q 'policy=' && assert "AC10 omitted policy stays additive (no policy= token)" 1 || assert "AC10 omitted policy stays additive (no policy= token)" 0

echo ""
echo "=== $PASS/$TOTAL passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
