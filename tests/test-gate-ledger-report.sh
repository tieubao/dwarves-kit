#!/usr/bin/env bash
# test-gate-ledger-report.sh -- ID-445: `gate-ledger.sh report --period week|month` cross-cutting
# markdown report. Aggregates runs/*.log whose START falls in the window into a table + totals.
#
# Isolation: every case runs under a fresh DWARVES_KIT_LOG_DIR so the real machine corpus is
# never touched.
#
# Run: bash tests/test-gate-ledger-report.sh   (exit 0 = all AC green)

set -uo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GL="$KIT_DIR/lib/gate/gate-ledger.sh"

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

echo "=== gate-ledger report (ID-445) ==="

# ---------------------------------------------------------------------------
# C1: a run inside the window shows up in the table with its ran/skipped counts.
# ---------------------------------------------------------------------------
new_log
gl start r1 full full spec spec dwarves-kit >/dev/null 2>&1
gl record r1 spec ran >/dev/null 2>&1
gl record r1 build ran >/dev/null 2>&1
gl record r1 review skipped >/dev/null 2>&1

OUT="$(gl report --period week)"
{ trap '' PIPE; echo "$OUT" 2>/dev/null || :; } | grep -q '^| rid | lane | repo | gates_ran | gates_skipped |$' \
  && assert "C1 markdown table header" 0 || assert "C1 markdown table header (got: $(echo "$OUT" | sed -n '3p'))" 1
{ trap '' PIPE; echo "$OUT" 2>/dev/null || :; } | grep -q '^| r1 | full | dwarves-kit | 2 | 1 |$' \
  && assert "C1 r1 row: 2 ran 1 skipped" 0 || assert "C1 r1 row (got: $(echo "$OUT" | grep '| r1 |'))" 1
{ trap '' PIPE; echo "$OUT" 2>/dev/null || :; } | grep -q '\*\*Totals:\*\* 1 runs, 2 gates ran, 1 gates skipped' \
  && assert "C1 totals line" 0 || assert "C1 totals line (got: $(echo "$OUT" | grep Totals))" 1

# ---------------------------------------------------------------------------
# C2: --lane filters to that lane only.
# ---------------------------------------------------------------------------
gl start r2 study study lesson lesson learning-kit >/dev/null 2>&1
gl record r2 study ran >/dev/null 2>&1
FULL="$(gl report --period week --lane full)"
{ trap '' PIPE; echo "$FULL" 2>/dev/null || :; } | grep -q '| r1 |' && [ -z "$(echo "$FULL" | grep '| r2 |')" ] \
  && assert "C2 --lane full excludes r2 (study)" 0 || assert "C2 --lane full excludes r2" 1

# ---------------------------------------------------------------------------
# C3: a run OLDER than the window is excluded (backdate its START line's timestamp).
# ---------------------------------------------------------------------------
new_log
gl start rold full full spec spec dwarves-kit >/dev/null 2>&1
gl record rold spec ran >/dev/null 2>&1
OLD_ISO="$(date -v-40d -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-40 days' +%Y-%m-%dT%H:%M:%SZ)"
sed -i.bak "1s/^[^ ]*/$OLD_ISO/" "$LOGD/runs/rold.log" && rm -f "$LOGD/runs/rold.log.bak"
OUT3="$(gl report --period month)"
{ trap '' PIPE; echo "$OUT3" 2>/dev/null || :; } | grep -q 'No runs in this window' \
  && assert "C3 40-day-old run excluded from a 30-day window" 0 || assert "C3 40-day-old run excluded (got: $OUT3)" 1

# ---------------------------------------------------------------------------
# C4: negative control -- an empty runs dir still emits a report header, honest-empty.
# ---------------------------------------------------------------------------
new_log
EMPTY="$(gl report --period month)"
{ trap '' PIPE; echo "$EMPTY" 2>/dev/null || :; } | grep -q '^# Gate-ledger report (month, since' \
  && { trap '' PIPE; echo "$EMPTY" 2>/dev/null || :; } | grep -q 'No runs in this window' \
  && assert "C4 empty dir -> honest-empty report" 0 || assert "C4 empty dir -> honest-empty report (got: $EMPTY)" 1

# ---------------------------------------------------------------------------
# C5: unknown/missing --period rejected (rc 64), matching the other verbs.
# ---------------------------------------------------------------------------
gl report --period year >/dev/null 2>&1; rc=$?
[ "$rc" -eq 64 ] && assert "C5 unknown period rejected (rc 64)" 0 || assert "C5 unknown period rejected (rc=$rc)" 1
gl report >/dev/null 2>&1; rc=$?
[ "$rc" -eq 64 ] && assert "C5b missing --period rejected (rc 64)" 0 || assert "C5b missing --period rejected (rc=$rc)" 1

echo ""
echo "=== $PASS/$TOTAL passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
