#!/usr/bin/env bash
# test-lane-escalation.sh -- SPEC-094, kit-hardening SG-06.
# Validates the spec->build-boundary lane re-classification: the `escalate` verb
# (up-only, advisory), the gate-ledger re-plan it drives (start --amend adds rigor),
# and the downgrade guard (a lighter re-class is refused -- the load-bearing
# negative control).
#
# Run: bash tests/test-lane-escalation.sh   (exit 0 = all AC green)

set -uo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LC="$KIT_DIR/lib/classify/lane-classify.sh"
GL="$KIT_DIR/lib/gate/gate-ledger.sh"
EX="$KIT_DIR/commands/execute.md"
FIX="$KIT_DIR/tests/fixtures/lane-escalation"

# Isolate the completeness.log writer so test fixtures never pollute the operator's real
# telemetry (SPEC-103 / ID-087). The `lane-classify check` at the AC2 downgrade guard below
# writes a LANE-CHECK line; without this export it would land in the real
# ~/.local/state/dwarves-kit/logs/completeness.log (the 12 leaked "jwt sessions" lines the
# SPEC-073 eval found). Mirrors tests/test-hooks.sh's file-wide export. Per-command
# `DWARVES_KIT_LOG_DIR="$LOG_DIR"` prefixes below intentionally override this for the ledger AC.
export DWARVES_KIT_LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dwarves-kit-lane-esc.XXXXXX")"

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

echo "=== lane-escalation (SPEC-094 AC1-AC6) ==="

# --- AC1: the verb exists and is wired into main() dispatch ---
grep -qE '^[[:space:]]*escalate\)[[:space:]]*escalate' "$LC"; assert "AC1: lane-classify.sh dispatches 'escalate'" $?
grep -qF 'escalate <current-lane> <spec-file>' "$LC"; assert "AC1: usage string documents the escalate signature" $?

# ============================================================
echo ""
echo "=== POSITIVE: tiny + emergent-scope spec escalates to full ==="
# ============================================================
OUT_POS="$(bash "$LC" escalate tiny "$FIX/heavy-scope-spec.md" 2>&1)"
EXIT_POS=$?
assert_contains "AC2: escalate tiny+heavy-scope-spec prints ESCALATE tiny -> full" "ESCALATE tiny -> full" "$OUT_POS"
assert "AC2: escalate exits 0 on ESCALATE" $([ "$EXIT_POS" -eq 0 ] && echo 0 || echo 1)

# ============================================================
echo ""
echo "=== DOWNGRADE GUARD [NEGATIVE CONTROL]: full + trivial spec never downgrades ==="
# ============================================================
OUT_NEG="$(bash "$LC" escalate full "$FIX/trivial-spec.md" 2>&1)"
EXIT_NEG=$?
assert_contains "AC3 [NEGATIVE CONTROL]: escalate full+trivial-spec HOLDs at full (never downgrades)" "HOLD full" "$OUT_NEG"
if { printf '%s' "$OUT_NEG" 2>/dev/null || :; } | grep -qE '^ESCALATE'; then
  assert "AC3 [NEGATIVE CONTROL]: no ESCALATE line ever appears for a lighter re-class" 1
else
  assert "AC3 [NEGATIVE CONTROL]: no ESCALATE line ever appears for a lighter re-class" 0
fi
assert "AC3: escalate exits 0 on HOLD too" $([ "$EXIT_NEG" -eq 0 ] && echo 0 || echo 1)

# same-lane control: normal spec text against a normal current lane also HOLDs (same
# rank, not just lighter -- "same or lighter" both refuse to escalate)
SAME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dwarves-kit-lane-esc.XXXXXX")"
printf '# Spec: bounded fix\n\n## Problem\nA bounded bug fix, nothing more.\n' > "$SAME_DIR/bug-spec.md"
OUT_SAME="$(bash "$LC" escalate bug "$SAME_DIR/bug-spec.md" 2>&1)"
assert_contains "AC3: same-rank re-class also HOLDs (bug vs bug-ranked text)" "HOLD bug" "$OUT_SAME"

# existing downgrade guard (lane_check / the 'check' verb) is untouched and still blocks
CHECK_OUT="$(bash "$LC" check tiny "add user authentication with jwt sessions" 2>&1)"
assert_contains "AC6: the pre-existing 'check' downgrade guard still fires (untouched)" "LANE-DOWNGRADE" "$CHECK_OUT"

# ============================================================
echo ""
echo "=== GATE-LEDGER RE-PLAN: start --amend re-plans up-only ==="
# ============================================================
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dwarves-kit-lane-esc-ledger.XXXXXX")"
RID="lane-esc-test-run"
DWARVES_KIT_LOG_DIR="$LOG_DIR" bash "$GL" start "$RID" tiny tiny feature feature testrepo >/dev/null 2>&1
REQ_TINY="$(bash "$GL" required tiny 2>/dev/null)"
REQ_FULL="$(bash "$GL" required full 2>/dev/null)"
N_TINY=$(printf '%s\n' "$REQ_TINY" | grep -c .)
N_FULL=$(printf '%s\n' "$REQ_FULL" | grep -c .)
if [ "$N_FULL" -gt "$N_TINY" ]; then
  assert "AC4: required(full) has strictly more gates than required(tiny)" 0
else
  assert "AC4: required(full) has strictly more gates than required(tiny)" 1
fi

DWARVES_KIT_LOG_DIR="$LOG_DIR" bash "$GL" start --amend "$RID" full tiny feature feature testrepo >/dev/null 2>&1
LEDGER_TAIL="$(DWARVES_KIT_LOG_DIR="$LOG_DIR" bash "$GL" show "$RID" 2>/dev/null | grep -E 'START|START-AMEND' | tail -1)"
assert_contains "AC4: last START-AMEND wins -- ledger's effective lane is now full" "lane=full" "$LEDGER_TAIL"
if { printf '%s' "$LEDGER_TAIL" 2>/dev/null || :; } | grep -q 'START-AMEND'; then
  assert "AC4: the amend line is recorded as START-AMEND, not a second plain START" 0
else
  assert "AC4: the amend line is recorded as START-AMEND, not a second plain START" 1
fi
FULL_LOG="$(DWARVES_KIT_LOG_DIR="$LOG_DIR" bash "$GL" show "$RID" 2>/dev/null | grep -c 'START')"
if [ "$FULL_LOG" -eq 2 ]; then
  assert "AC4: append-only stands (2 lines: START then START-AMEND, neither overwritten)" 0
else
  assert "AC4: append-only stands (2 lines: START then START-AMEND, neither overwritten)" 1
fi

# ============================================================
echo ""
echo "=== ADVISORY + RECORDED: escalate never halts; the wiring says so ==="
# ============================================================
bash "$LC" escalate tiny "$FIX/heavy-scope-spec.md" >/dev/null 2>&1
assert "AC5: escalate exits 0 on ESCALATE (advisory, never blocks)" $?
bash "$LC" escalate full "$FIX/trivial-spec.md" >/dev/null 2>&1
assert "AC5: escalate exits 0 on HOLD (advisory, never blocks)" $?

grep -qiE 'advisory' "$EX"; assert "AC5: commands/execute.md wiring documents advisory" $?
grep -qiE 'never a (mid-flight )?hard block|not a hard block' "$EX"; assert "AC5: commands/execute.md wiring documents 'not a hard block'" $?
grep -qF 'lib/classify/lane-classify.sh escalate' "$EX"; assert "AC5: commands/execute.md wires the escalate call" $?
grep -qF 'gate-ledger.sh start --amend' "$EX"; assert "AC5: commands/execute.md wires the up-only start --amend re-plan" $?
grep -qE "Lane:.*header" "$EX"; assert "AC5: commands/execute.md documents bumping the spec Lane: header" $?
grep -qiE 'never down' "$EX"; assert "AC5: commands/execute.md states the header bump is up-only (never down)" $?

# ============================================================
echo ""
echo "=== SCOPE EDGES: classify-time triggers untouched ==="
# ============================================================
CLASSIFY_OUT="$(bash "$LC" classify "add jwt authentication and a data-model migration" 2>&1)"
assert_contains "AC6: classify-time trigger (task text) still lands on full unchanged" "full" "$CLASSIFY_OUT"

echo ""
echo "=== $PASS/$TOTAL passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
