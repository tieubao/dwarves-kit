#!/usr/bin/env bash
# test-proof-table-gen.sh -- the generated proof-of-done confirmation table (SPEC-132,
# reconciled to 01's real marker shape per SPEC-133).
#
# Pins: round-trip against a fixture ledger, additive-tolerance BOTH ways (01's real
# start/end caught=/dur_s= marker pair present vs. entirely absent), the hard "never
# overwrite the canonical proof-of-done.md" backstop (explicit path + the default path),
# the coverage-delta row with a known lane and with an unknown lane, and a fully empty
# ledger (no crash).
#
# Run: bash tests/test-proof-table-gen.sh
# Exit 0 = all pass. Exit 1 = failures.
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GEN="$KIT_DIR/lib/gate/proof-table-gen.sh"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
PASS=0; FAIL=0; TOTAL=0

ok()  { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}PASS${NC} $1"; }
bad() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo -e "  ${RED}FAIL${NC} $1"; }
expect()  { if { trap '' PIPE; printf '%s' "$3" 2>/dev/null || :; } | grep -qF "$2"; then ok "$1"; else bad "$1 (missing '$2' in: $3)"; fi; }
refute()  { if { trap '' PIPE; printf '%s' "$3" 2>/dev/null || :; } | grep -qF "$2"; then bad "$1 (unexpected '$2' present)"; else ok "$1"; fi; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/kit-proof-table-gen.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export DWARVES_KIT_LOG_DIR="$WORK/logs"
mkdir -p "$DWARVES_KIT_LOG_DIR/runs"
# SPEC-134/goal-11: the generator now confines its output under
# realpath(KIT_ROOT/docs/verification/generated). Point KIT_ROOT at a throwaway root so
# explicit out-paths land in a real docs/verification/generated (exercising the confinement)
# without polluting the actual repo. The wrapper honors this env override.
export KIT_ROOT="$WORK/kitroot"
RUNS="$KIT_ROOT/docs/verification/generated"
mkdir -p "$RUNS"

# ============================================================
echo "=== T1/T6: round-trip + coverage-delta (lane known) ==="
# ============================================================
RID1="fixture-known"
cat > "$DWARVES_KIT_LOG_DIR/runs/$RID1.log" <<'EOF'
2026-07-04T09:00:00Z | START | lane=normal classified=normal type=spec-feature repo=dwarves-kit
2026-07-04T09:00:01Z | GATE | spec | ran | spec authored
2026-07-04T09:00:02Z | GATE | build | ran | implemented
2026-07-04T09:00:03Z | GATE | ship | skipped | held for review
EOF
OUT1="$RUNS/out1.md"
RES1="$(bash "$GEN" "$RID1" "$OUT1" 2>&1)"; RC1=$?
assert_eq "T1: generator exits 0 on a populated fixture" "$RC1" "0"
BODY1="$(cat "$OUT1" 2>/dev/null)"
expect "T1: confirmation row for spec (phase/when/state/reason, round-trip)" "| 1 | spec | 2026-07-04T09:00:01Z | ran | spec authored |" "$BODY1"
expect "T1: confirmation row for build" "| 2 | build | 2026-07-04T09:00:02Z | ran | implemented |" "$BODY1"
expect "T1: confirmation row for ship (skipped state preserved)" "| 3 | ship | 2026-07-04T09:00:03Z | skipped | held for review |" "$BODY1"
refute "T1 (implies T3): no Caught/Duration columns when zero OUTCOME lines exist" "Duration (s)" "$BODY1"
expect "T6: coverage-delta covers spec+build" "Covered: build, spec" "$BODY1"
expect "T6: coverage-delta names ship as uncovered (required, only skipped)" "Uncovered: ship" "$BODY1"
expect "T6: acceptance row reflects lane=normal" "lane \`normal\`" "$BODY1"

# ============================================================
echo ""
echo "=== T2: additive-tolerance, OUTCOME markers present (SPEC-129 real 01 shape) ==="
# ============================================================
RID2="fixture-outcomes"
cat > "$DWARVES_KIT_LOG_DIR/runs/$RID2.log" <<'EOF'
2026-07-04T09:00:00Z | START | lane=normal classified=normal type=spec-feature repo=dwarves-kit
2026-07-04T09:00:01Z | GATE | spec | ran | spec authored
2026-07-04T09:00:02Z | GATE | build | ran | implemented
2026-07-04T09:00:01Z | OUTCOME | spec | start | at=1000
2026-07-04T09:00:01Z | OUTCOME | spec | end | at=1012 caught=false dur_s=12
2026-07-04T09:00:02Z | OUTCOME | build | start | at=2000
2026-07-04T09:00:02Z | OUTCOME | build | end | at=2043 caught=true dur_s=43
EOF
OUT2="$RUNS/out2.md"
bash "$GEN" "$RID2" "$OUT2" >/dev/null 2>&1
BODY2="$(cat "$OUT2" 2>/dev/null)"
expect "T2: Caught/Duration columns appear when OUTCOME lines exist" "Caught | Duration (s)" "$BODY2"
expect "T2: spec row populates caught=false dur=12 from real 01 start/end pair" "| 1 | spec | 2026-07-04T09:00:01Z | ran | spec authored | false | 12 |" "$BODY2"
expect "T2: build row populates caught=true dur=43 from real 01 start/end pair" "| 2 | build | 2026-07-04T09:00:02Z | ran | implemented | true | 43 |" "$BODY2"

# same fixture, add a phase with NO outcome line -> that row degrades to n/a per-row
RID2B="fixture-outcomes-partial"
cat > "$DWARVES_KIT_LOG_DIR/runs/$RID2B.log" <<'EOF'
2026-07-04T09:00:00Z | START | lane=normal classified=normal type=spec-feature repo=dwarves-kit
2026-07-04T09:00:01Z | GATE | spec | ran | spec authored
2026-07-04T09:00:03Z | GATE | ship | ran | opened PR
2026-07-04T09:00:01Z | OUTCOME | spec | start | at=500
2026-07-04T09:00:01Z | OUTCOME | spec | end | at=509 caught=false dur_s=9
EOF
OUT2B="$RUNS/out2b.md"
bash "$GEN" "$RID2B" "$OUT2B" >/dev/null 2>&1
BODY2B="$(cat "$OUT2B" 2>/dev/null)"
expect "T2: spec row still populates in the partial fixture" "| 1 | spec | 2026-07-04T09:00:01Z | ran | spec authored | false | 9 |" "$BODY2B"
expect "T2: per-row degrade -- a phase with no OUTCOME line gets n/a, not a crash" "| 2 | ship | 2026-07-04T09:00:03Z | ran | opened PR | n/a | n/a |" "$BODY2B"

# same shape, but the end line omits dur_s= (defensive case) -> duration falls back to
# the end.at - start.at epoch delta, the same arithmetic outcome()'s own emitter uses
RID2C="fixture-outcomes-fallback-duration"
cat > "$DWARVES_KIT_LOG_DIR/runs/$RID2C.log" <<'EOF'
2026-07-04T09:00:00Z | START | lane=normal classified=normal type=spec-feature repo=dwarves-kit
2026-07-04T09:00:01Z | GATE | spec | ran | spec authored
2026-07-04T09:00:01Z | OUTCOME | spec | start | at=100
2026-07-04T09:00:01Z | OUTCOME | spec | end | at=145 caught=true
EOF
OUT2C="$RUNS/out2c.md"
bash "$GEN" "$RID2C" "$OUT2C" >/dev/null 2>&1
BODY2C="$(cat "$OUT2C" 2>/dev/null)"
expect "T2: dur_s= absent -> duration derived from end.at - start.at epoch delta (45)" "| 1 | spec | 2026-07-04T09:00:01Z | ran | spec authored | true | 45 |" "$BODY2C"

# ============================================================
echo ""
echo "=== T3: additive-tolerance, OUTCOME markers entirely absent ==="
# ============================================================
# (RID1 above already has zero OUTCOME lines; reuse it to prove the whole-table grain)
expect "T3: whole-table grain -- no Caught/Duration header when 0 OUTCOME lines anywhere" "| # | Phase | When (ISO8601) | State | Reason |" "$BODY1"
refute "T3: no crash / no stray Caught column text on the no-outcome fixture" "Caught" "$BODY1"

# ============================================================
echo ""
echo "=== T4/T5: never overwrites the canonical proof-of-done.md ==="
# ============================================================
CANON="$WORK/docs/verification/proof-of-done.md"
mkdir -p "$(dirname "$CANON")"
printf 'HAND-AUTHORED CANONICAL -- do not touch\n' > "$CANON"
bash "$GEN" "$RID1" "$CANON" >/dev/null 2>&1
RC4=$?
assert_eq "T4: explicit canonical out-path is refused (non-zero exit)" "$RC4" "1"
CANON_BODY="$(cat "$CANON")"
assert_eq "T4: canonical file content is untouched after the refused call" "$CANON_BODY" "HAND-AUTHORED CANONICAL -- do not touch"

DEFAULT_OUT_LINE="$(bash "$GEN" "$RID1" 2>&1 | grep -oE 'wrote [^ ]+' | cut -d' ' -f2)"
expect "T5: default out-path lands under docs/verification/generated/" "docs/verification/generated/$RID1.md" "$DEFAULT_OUT_LINE"
rm -f "$RUNS/$RID1.md" 2>/dev/null || true   # generated artifact, not part of this test's fixture

# ============================================================
echo ""
echo "=== T7: coverage-delta, lane unknown (no START line) ==="
# ============================================================
RID7="fixture-no-start"
cat > "$DWARVES_KIT_LOG_DIR/runs/$RID7.log" <<'EOF'
2026-07-04T09:00:01Z | GATE | spec | ran | spec authored
EOF
OUT7="$RUNS/out7.md"
bash "$GEN" "$RID7" "$OUT7" >/dev/null 2>&1
RC7=$?
assert_eq "T7: generator exits 0 even with no START line" "$RC7" "0"
BODY7="$(cat "$OUT7" 2>/dev/null)"
expect "T7: lane reported as unknown, no crash" "n/a (no START line for this rid; lane unknown)" "$BODY7"
expect "T7: coverage-delta uncovered degrades to lane-unknown text" "Uncovered: n/a (lane unknown; no START line for this rid)" "$BODY7"

# ============================================================
echo ""
echo "=== T8: fully empty ledger (rid has no ledger file at all) ==="
# ============================================================
OUT8="$RUNS/out8.md"
bash "$GEN" "no-such-rid-ever" "$OUT8" >/dev/null 2>&1
RC8=$?
assert_eq "T8: generator exits 0 on a rid with no ledger file" "$RC8" "0"
BODY8="$(cat "$OUT8" 2>/dev/null)"
expect "T8: empty-ledger table is still well-formed (no-crash marker row)" "(none -- empty ledger)" "$BODY8"
expect "T8: empty-ledger still names the (n/a) acceptance criterion" "## 1. Acceptance criteria" "$BODY8"

echo ""
echo "=== Results ==="
echo -e "Passed: ${GREEN}$PASS${NC} / $TOTAL"
if [ "$FAIL" -gt 0 ]; then echo -e "${RED}$FAIL assertions failed.${NC}"; exit 1; fi
echo -e "${GREEN}proof-table-gen green.${NC}"
