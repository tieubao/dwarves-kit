#!/usr/bin/env bash
# test-gate-ledger-history.sh -- ID-444: `gate-ledger.sh history` CSV/JSON export.
# One row per run over all gate ledgers: rid, lane, repo, first/last ts, and the
# GATE ran/skipped counts, optionally lane-filtered.
#
# Isolation: every case runs under a fresh DWARVES_KIT_LOG_DIR so the real machine
# corpus is never touched. Ported from learning-kit/bin/study-history.
#
# Run: bash tests/test-gate-ledger-history.sh   (exit 0 = all AC green)

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

echo "=== gate-ledger history (ID-444) ==="

# ---------------------------------------------------------------------------
# C1: one row per run with lane + repo + ran/skipped counts.
# ---------------------------------------------------------------------------
new_log
gl start r1 full full spec spec dwarves-kit >/dev/null 2>&1
gl record r1 spec ran >/dev/null 2>&1
gl record r1 build ran >/dev/null 2>&1
gl record r1 review skipped >/dev/null 2>&1
gl start r2 study study lesson lesson learning-kit >/dev/null 2>&1
gl record r2 study ran >/dev/null 2>&1

OUT="$(gl history)"
{ trap '' PIPE; echo "$OUT" 2>/dev/null || :; } | grep -q '^rid,lane,repo,first_ts,last_ts,gates_ran,gates_skipped$' \
  && assert "C1 CSV header" 0 || assert "C1 CSV header (got: $(echo "$OUT" | head -1))" 1
{ trap '' PIPE; echo "$OUT" 2>/dev/null || :; } | grep -q '^r1,full,dwarves-kit,.*,2,1$' \
  && assert "C1 r1 row: lane=full, 2 ran 1 skipped" 0 || assert "C1 r1 row (got: $(echo "$OUT" | grep '^r1,'))" 1
{ trap '' PIPE; echo "$OUT" 2>/dev/null || :; } | grep -q '^r2,study,learning-kit,.*,1,0$' \
  && assert "C1 r2 row: lane=study, 1 ran 0 skipped" 0 || assert "C1 r2 row (got: $(echo "$OUT" | grep '^r2,'))" 1

# ---------------------------------------------------------------------------
# C2: --lane filters to that lane only.
# ---------------------------------------------------------------------------
FULL="$(gl history --lane full)"
{ trap '' PIPE; echo "$FULL" 2>/dev/null || :; } | grep -q '^r1,' && [ -z "$(echo "$FULL" | grep '^r2,')" ] \
  && assert "C2 --lane full excludes r2 (study)" 0 || assert "C2 --lane full excludes r2" 1
STUDY="$(gl history --lane study)"
{ trap '' PIPE; echo "$STUDY" 2>/dev/null || :; } | grep -q '^r2,' && [ -z "$(echo "$STUDY" | grep '^r1,')" ] \
  && assert "C2 --lane study excludes r1 (full)" 0 || assert "C2 --lane study excludes r1" 1

# ---------------------------------------------------------------------------
# C3: --json emits a JSON array with the same fields.
# ---------------------------------------------------------------------------
J="$(gl history --json)"
{ trap '' PIPE; echo "$J" 2>/dev/null || :; } | grep -q '"rid":"r1"' && { trap '' PIPE; echo "$J" 2>/dev/null || :; } | grep -q '"lane":"full"' \
  && { trap '' PIPE; echo "$J" 2>/dev/null || :; } | grep -q '"repo":"dwarves-kit"' && { trap '' PIPE; echo "$J" 2>/dev/null || :; } | grep -q '"gates_ran":2' \
  && { trap '' PIPE; echo "$J" 2>/dev/null || :; } | grep -q '"gates_skipped":1' \
  && assert "C3 JSON carries rid/lane/repo/counts" 0 || assert "C3 JSON fields (got: $J)" 1

# ---------------------------------------------------------------------------
# C4: negative control -- an empty runs dir still emits the CSV header (honest empty).
# ---------------------------------------------------------------------------
new_log
EMPTY="$(gl history)"
[ -n "$EMPTY" ] && { trap '' PIPE; echo "$EMPTY" 2>/dev/null || :; } | grep -q '^rid,lane,repo,first_ts,last_ts,gates_ran,gates_skipped$' \
  && assert "C4 empty dir -> header only (honest-empty)" 0 || assert "C4 empty dir -> header only" 1
EJ="$(gl history --json)"
[ "$(printf '%s' "$EJ" | tr -d '\n\t ')" = "[]" ] && assert "C4 empty dir --json -> []" 0 || assert "C4 empty dir --json -> [] (got: $EJ)" 1

# ---------------------------------------------------------------------------
# C5: unknown flag rejected (rc 64), matching the other verbs.
# ---------------------------------------------------------------------------
gl history --bogus >/dev/null 2>&1; rc=$?
[ "$rc" -eq 64 ] && assert "C5 unknown flag rejected (rc 64)" 0 || assert "C5 unknown flag rejected (rc=$rc)" 1

echo ""
echo "=== $PASS/$TOTAL passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
