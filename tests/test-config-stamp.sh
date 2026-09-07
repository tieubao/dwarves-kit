#!/usr/bin/env bash
# test-config-stamp.sh -- ID-420, bench-plane prerequisite (DECISION-BRIEF-bench-plane.md §1).
# Validates the additive `| CONFIG |` marker on gate-ledger.sh: model/effort/kit_version/
# modules/lane/task_type/suite_hash/session_id dimensions, optional phase= scoping for
# "model-per-stage", and the same ADDITIVE-EQUIVALENCE property every other marker
# (TOKENS/DEBT/OUTCOME/MUTATION) already holds: every existing reader is byte-identical
# with CONFIG lines present vs absent.
#
# Isolation: every case runs under a fresh DWARVES_KIT_LOG_DIR so the real machine corpus is
# never touched.
#
# Run: bash tests/test-config-stamp.sh   (exit 0 = all AC green)

set -uo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GL="$KIT_DIR/lib/gate/gate-ledger.sh"
LT="$KIT_DIR/lib/telemetry/lane-telemetry.sh"

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert() { TOTAL=$((TOTAL+1)); if [ "$2" -eq 0 ]; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1)); else echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL+1)); fi; }

TMPS=()
_mk() { local d; d="$(mktemp -d)"; TMPS+=("$d"); printf '%s' "$d"; }
cleanup() { local d; for d in "${TMPS[@]:-}"; do [ -n "$d" ] && rm -rf "$d" 2>/dev/null; done; }
trap cleanup EXIT

LOGD=""
gl() { env DWARVES_KIT_LOG_DIR="$LOGD" bash "$GL" "$@"; }
new_log() { LOGD="$(_mk)/logs"; mkdir -p "$LOGD/runs"; }

echo "=== config-stamp (ID-420 AC1-AC6) ==="

# ---------------------------------------------------------------------------
# AC1: every dimension round-trips through show().
# ---------------------------------------------------------------------------
new_log
gl config c1 model=opus effort=high kit_version=9.9.9 modules=board,stats lane=full task_type=spec-feature suite_hash=abc123 session_id=sess-1 >/dev/null 2>&1
LINE="$(gl show c1 2>&1 | grep '| CONFIG |')"
{ trap '' PIPE; echo "$LINE" 2>/dev/null || :; } | grep -q 'model=opus'          && assert "AC1 model round-trips"          0 || assert "AC1 model round-trips (got '$LINE')"          1
{ trap '' PIPE; echo "$LINE" 2>/dev/null || :; } | grep -q 'effort=high'         && assert "AC1 effort round-trips"         0 || assert "AC1 effort round-trips"         1
{ trap '' PIPE; echo "$LINE" 2>/dev/null || :; } | grep -q 'kit_version=9.9.9'   && assert "AC1 kit_version round-trips"    0 || assert "AC1 kit_version round-trips"    1
{ trap '' PIPE; echo "$LINE" 2>/dev/null || :; } | grep -q 'modules=board,stats' && assert "AC1 modules round-trips"        0 || assert "AC1 modules round-trips"        1
{ trap '' PIPE; echo "$LINE" 2>/dev/null || :; } | grep -q 'lane=full'           && assert "AC1 lane round-trips"           0 || assert "AC1 lane round-trips"           1
{ trap '' PIPE; echo "$LINE" 2>/dev/null || :; } | grep -q 'task_type=spec-feature' && assert "AC1 task_type round-trips"   0 || assert "AC1 task_type round-trips"      1
{ trap '' PIPE; echo "$LINE" 2>/dev/null || :; } | grep -q 'suite_hash=abc123'   && assert "AC1 suite_hash round-trips"     0 || assert "AC1 suite_hash round-trips"     1
{ trap '' PIPE; echo "$LINE" 2>/dev/null || :; } | grep -q 'session_id=sess-1'   && assert "AC1 session_id round-trips"     0 || assert "AC1 session_id round-trips"     1

# ---------------------------------------------------------------------------
# AC2: kit_version defaults to $KIT_ROOT/VERSION when the caller omits it.
# ---------------------------------------------------------------------------
new_log
gl config c2 model=sonnet >/dev/null 2>&1
LINE="$(gl show c2 2>&1 | grep '| CONFIG |')"
REAL_VER="$(cat "$KIT_DIR/VERSION" 2>/dev/null)"
{ trap '' PIPE; echo "$LINE" 2>/dev/null || :; } | grep -q "kit_version=$REAL_VER" && assert "AC2 kit_version defaults to VERSION file" 0 || assert "AC2 kit_version defaults to VERSION file (got '$LINE', want '$REAL_VER')" 1

# ---------------------------------------------------------------------------
# AC3: suite_hash is never invented -- absent unless the caller passes it.
# ---------------------------------------------------------------------------
new_log
gl config c3 model=sonnet >/dev/null 2>&1
gl show c3 2>&1 | grep '| CONFIG |' | grep -q 'suite_hash=' && assert "AC3 suite_hash absent for real work (omitted by caller)" 1 || assert "AC3 suite_hash absent for real work (omitted by caller)" 0

# ---------------------------------------------------------------------------
# AC4: phase= scoping lets one rid carry a different model per stage ("model-per-stage").
# ---------------------------------------------------------------------------
new_log
gl config c4 model=opus phase=think >/dev/null 2>&1
gl config c4 model=sonnet phase=build >/dev/null 2>&1
SHOW="$(gl show c4 2>&1)"
echo "$SHOW" | grep 'CONFIG' | grep -q 'phase=think model=opus\|model=opus phase=think' && assert "AC4 think stage stamped opus" 0 || assert "AC4 think stage stamped opus (got: $SHOW)" 1
echo "$SHOW" | grep 'CONFIG' | grep -q 'phase=build model=sonnet\|model=sonnet phase=build' && assert "AC4 build stage stamped sonnet" 0 || assert "AC4 build stage stamped sonnet (got: $SHOW)" 1

# ---------------------------------------------------------------------------
# AC5: ADDITIVE-EQUIVALENCE -- every existing reader is byte-identical with the
# CONFIG marker present vs absent (same property test-gate-outcome.sh AC7 proves
# for OUTCOME). Build a full run, capture readers, inject CONFIG lines, re-capture, diff.
# ---------------------------------------------------------------------------
new_log
build_run() {
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
B_CHECK="$(gl check full base 2>&1; echo rc=$?)"
B_DESCENT="$(gl descent base full 2>&1)"
B_PROGRESS="$(gl progress base full 2>&1)"
B_ROWS="$(env DWARVES_KIT_LOG_DIR="$LOGD" NO_COLOR=1 bash "$LT" 2>&1)"
gl config base model=opus effort=high kit_version=1.0.0 modules=board lane=full task_type=spec-feature session_id=s1 phase=think >/dev/null 2>&1
gl config base model=sonnet phase=build >/dev/null 2>&1
A_CHECK="$(gl check full base 2>&1; echo rc=$?)"
A_DESCENT="$(gl descent base full 2>&1)"
A_PROGRESS="$(gl progress base full 2>&1)"
A_ROWS="$(env DWARVES_KIT_LOG_DIR="$LOGD" NO_COLOR=1 bash "$LT" 2>&1)"
[ "$B_CHECK" = "$A_CHECK" ]       && assert "AC5 check() byte-identical with CONFIG present" 0 || assert "AC5 check() byte-identical (B='$B_CHECK' A='$A_CHECK')" 1
[ "$B_DESCENT" = "$A_DESCENT" ]   && assert "AC5 descent() byte-identical with CONFIG present" 0 || assert "AC5 descent() byte-identical" 1
[ "$B_PROGRESS" = "$A_PROGRESS" ] && assert "AC5 progress() byte-identical with CONFIG present" 0 || assert "AC5 progress() byte-identical" 1
[ "$B_ROWS" = "$A_ROWS" ]         && assert "AC5 _rows()/lane-telemetry byte-identical with CONFIG present" 0 || assert "AC5 _rows()/lane-telemetry byte-identical (diff below)
$(diff <(printf '%s' "$B_ROWS") <(printf '%s' "$A_ROWS"))" 1

# ---------------------------------------------------------------------------
# AC6: negative-control target -- if `config` ever emitted `| GATE |` instead of
# `| CONFIG |`, descent() would misread it as a real gate row and this goes RED.
# ---------------------------------------------------------------------------
new_log
gl start nc full full spec-feature spec-feature dwarves-kit >/dev/null 2>&1
gl record nc build ran seeded >/dev/null 2>&1   # a LATE phase; grill/think left undisposed
NC_BEFORE="$(gl descent nc full 2>&1)"
gl config nc model=opus phase=think >/dev/null 2>&1
NC_AFTER="$(gl descent nc full 2>&1)"
[ "$NC_BEFORE" = "$NC_AFTER" ] && assert "AC6 descent() unchanged by CONFIG via the real verb (additive property; negative-control target)" 0 || assert "AC6 descent() unchanged by CONFIG via the real verb (BEFORE!=AFTER)" 1

echo ""
echo "=== $PASS/$TOTAL passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
