#!/usr/bin/env bash
# test-lane-deescalate.sh -- SPEC-141, kit-run-integrity sub-goal 07 (ID-257 kit half).
# Proves: a normal/full ship whose diff stayed under the floor FIRES the advisory nudge +
# appends the ledger action line; a diff at/over the floor stays silent (the FALSE-POSITIVE
# negative control, load-bearing); tiny/bug/backfill never fire regardless of size; the
# NO-BLOCK negative control (load-bearing, absolute) -- the fire path's exit code is 0, even
# when the ledger write itself fails. Uses throwaway git fixtures (the test-coverage-delta.sh
# idiom) so no real repo state is touched.
#
# Run: bash tests/test-lane-deescalate.sh   (exit 0 = all AC green)

set -uo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LC="$KIT_DIR/lib/classify/lane-classify.sh"
GL="$KIT_DIR/lib/gate/gate-ledger.sh"

# Isolate the gate-ledger writer from the operator's real telemetry (mirrors
# test-lane-escalation.sh's DWARVES_KIT_LOG_DIR export) -- CI-portability: every ledger
# read/write below is scoped to a fixture dir, never the machine-local
# ~/.local/state/dwarves-kit ledger, so the suite is identical on a fresh CI checkout.
export DWARVES_KIT_LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dwarves-kit-lane-deesc.XXXXXX")"

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert() { TOTAL=$((TOTAL+1)); if [ "$2" -eq 0 ]; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1)); else echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL+1)); fi; }
assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL+1))
  if { printf '%s' "$haystack" 2>/dev/null || :; } | grep -qF "$needle"; then
    echo -e "  ${GREEN}PASS${NC} $name"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $name"; FAIL=$((FAIL+1))
  fi
}
assert_empty() {
  local name="$1" haystack="$2"
  TOTAL=$((TOTAL+1))
  if [ -z "$haystack" ]; then
    echo -e "  ${GREEN}PASS${NC} $name"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $name (expected empty, got: '$haystack')"; FAIL=$((FAIL+1))
  fi
}

# make_repo <dir>: a git repo with one committed baseline file.
make_repo() {
  local d="$1"
  rm -rf "$d" 2>/dev/null || true
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  git -C "$d" branch -m master 2>/dev/null || true
  echo "baseline" > "$d/a.txt"
  git -C "$d" add -A; git -C "$d" commit -qm base
}
base_of() { git -C "$1" rev-parse HEAD; }

echo "=== lane-deescalate (SPEC-141 AC1-AC9) ==="

# --- AC-wiring: the verb exists and is dispatched ---
grep -qE '^[[:space:]]*deescalate\)[[:space:]]*deescalate' "$LC"; assert "wiring: lane-classify.sh dispatches 'deescalate'" $?
grep -qF 'deescalate <chosen-lane>' "$LC"; assert "wiring: usage string documents the deescalate signature" $?

# ============================================================
echo ""
echo "=== T1/T2: FIRE -- normal lane, diff under the floor -> advisory + ledger line ==="
# ============================================================
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dwarves-kit-lane-deesc-fix.XXXXXX")"
D="$WORK/t1"; make_repo "$D"
echo "one more line" >> "$D/a.txt"
git -C "$D" add -A; git -C "$D" commit -qm small
BASE="$(git -C "$D" rev-parse HEAD~1)"
OUT="$(bash "$LC" deescalate normal --root "$D" --base "$BASE" 2>&1)"
EXIT=$?
assert_contains "T1: fire prints LANE-DEESCALATE naming the lane" "LANE-DEESCALATE: shipped as normal" "$OUT"
assert_contains "T1: fire names the changed-line count" "changed line(s)" "$OUT"
assert "T1: fire still exits 0" $([ "$EXIT" -eq 0 ] && echo 0 || echo 1)

RID="lane-deesc-fire-test"
bash "$LC" deescalate normal --root "$D" --base "$BASE" --rid "$RID" >/dev/null 2>&1
LEDGER_LINE="$(bash "$GL" show "$RID" 2>/dev/null | grep 'lane-deescalate' | tail -1)"
assert_contains "T2: fire appends one ledger ACTION line" "| ACTION | lane-deescalate" "$LEDGER_LINE"
assert_contains "T2: ledger line carries chosen=normal" "chosen=normal" "$LEDGER_LINE"
assert_contains "T2: ledger line carries verdict=misroute-tiny" "verdict=misroute-tiny" "$LEDGER_LINE"

# ============================================================
echo ""
echo "=== T3: FALSE-POSITIVE NEGATIVE CONTROL (load-bearing): diff >= floor -> silent ==="
# ============================================================
D="$WORK/t3"; make_repo "$D"
for i in $(seq 1 30); do echo "line $i" >> "$D/b.txt"; done
git -C "$D" add -A; git -C "$D" commit -qm big
BASE="$(git -C "$D" rev-parse HEAD~1)"
OUT="$(bash "$LC" deescalate normal --root "$D" --base "$BASE" --floor 20 2>&1)"
assert_empty "T3 (NC): a >=floor diff prints NOTHING" "$OUT"
RID3="lane-deesc-nofire-test"
bash "$LC" deescalate normal --root "$D" --base "$BASE" --floor 20 --rid "$RID3" >/dev/null 2>&1
LEDGER3="$(bash "$GL" show "$RID3" 2>/dev/null | grep -c 'lane-deescalate' || true)"
assert "T3 (NC): a >=floor diff writes NO ledger line" $([ "${LEDGER3:-0}" -eq 0 ] && echo 0 || echo 1)

# ============================================================
echo ""
echo "=== T4: LANE GUARD -- tiny/bug/backfill never fire, even for a 1-line diff ==="
# ============================================================
D="$WORK/t4"; make_repo "$D"
echo "one more line" >> "$D/a.txt"
git -C "$D" add -A; git -C "$D" commit -qm small
BASE="$(git -C "$D" rev-parse HEAD~1)"
for LANE in tiny bug backfill; do
  OUT="$(bash "$LC" deescalate "$LANE" --root "$D" --base "$BASE" 2>&1)"
  assert_empty "T4: lane=$LANE never fires regardless of size" "$OUT"
done

# ============================================================
echo ""
echo "=== T5/T6: NO-BLOCK NEGATIVE CONTROL (load-bearing, absolute) ==="
# ============================================================
D="$WORK/t5"; make_repo "$D"
echo "one more line" >> "$D/a.txt"
git -C "$D" add -A; git -C "$D" commit -qm small
BASE="$(git -C "$D" rev-parse HEAD~1)"
bash "$LC" deescalate normal --root "$D" --base "$BASE" >/dev/null 2>&1
assert "T5: the FIRE case's own exit code is 0 (never blocks)" $?

# a ledger write failure (unwritable log dir) must never change the command's own exit.
UNWRITABLE="$(mktemp -d "${TMPDIR:-/tmp}/dwarves-kit-lane-deesc-ro.XXXXXX")"
chmod 000 "$UNWRITABLE"
DWARVES_KIT_LOG_DIR="$UNWRITABLE/nope" bash "$LC" deescalate normal --root "$D" --base "$BASE" --rid "ledger-fail-test" >/dev/null 2>&1
assert "T6: a ledger-write failure still leaves exit 0" $?
chmod 755 "$UNWRITABLE"

# ============================================================
echo ""
echo "=== T7: full lane also fires (not just normal) ==="
# ============================================================
D="$WORK/t7"; make_repo "$D"
echo "one more line" >> "$D/a.txt"
git -C "$D" add -A; git -C "$D" commit -qm small
BASE="$(git -C "$D" rev-parse HEAD~1)"
OUT="$(bash "$LC" deescalate full --root "$D" --base "$BASE" 2>&1)"
assert_contains "T7: full lane fires the same as normal" "LANE-DEESCALATE: shipped as full" "$OUT"

# ============================================================
echo ""
echo "=== T8: the floor is overridable ==="
# ============================================================
D="$WORK/t8"; make_repo "$D"
for i in $(seq 1 10); do echo "line $i" >> "$D/b.txt"; done   # 10 changed lines
git -C "$D" add -A; git -C "$D" commit -qm ten
BASE="$(git -C "$D" rev-parse HEAD~1)"
OUT_TIGHT="$(bash "$LC" deescalate normal --root "$D" --base "$BASE" --floor 5 2>&1)"   # 10 >= 5 -> silent
OUT_LOOSE="$(bash "$LC" deescalate normal --root "$D" --base "$BASE" --floor 50 2>&1)"  # 10 < 50 -> fires
assert_empty "T8: a tight floor (5) does not fire on a 10-line diff" "$OUT_TIGHT"
assert_contains "T8: a loose floor (50) fires on the same 10-line diff" "LANE-DEESCALATE" "$OUT_LOOSE"

# ============================================================
echo ""
echo "=== T9: doc wiring -- WORKFLOW.md + commands/ship.md name the floor ==="
# ============================================================
grep -qF 'LANE_DEESCALATE_FLOOR' "$KIT_DIR/docs/WORKFLOW.md"; assert "T9: WORKFLOW.md names the LANE_DEESCALATE_FLOOR tunable" $?
grep -qE 'default \*\*20\*\*|default 20' "$KIT_DIR/docs/WORKFLOW.md"; assert "T9: WORKFLOW.md states the default (20)" $?
grep -qF 'lib/classify/lane-classify.sh deescalate' "$KIT_DIR/commands/ship.md"; assert "T9: commands/ship.md wires the deescalate call" $?
grep -qiE 'never blocks|advisory only' "$KIT_DIR/commands/ship.md" | head -1 >/dev/null
grep -A2 'Lane de-escalation nudge' "$KIT_DIR/commands/ship.md" | grep -qiE 'exit-0 always|never blocks'
assert "T9: commands/ship.md documents the nudge as never-blocking" $?

echo ""
echo "=== $PASS/$TOTAL passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
