#!/usr/bin/env bash
# test-every-step-review.sh -- SPEC-093, kit-hardening SG-05 (ADR-0028 P4).
# Proves: in the full lane every V-model phase maps to a review that RUNS and
# records to the gate-ledger; the ship-gate BLOCKS a push with a required
# phase-review missing (real gate-ledger negative control); enforcement is at
# ship, NOT a mid-flight hard block.
#
# Run: bash tests/test-every-step-review.sh   (exit 0 = all AC green)

set -uo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WF="$KIT_DIR/docs/WORKFLOW.md"  # bulk lives in docs/ (SPEC-185); root WORKFLOW.md is a thin stub
GL="$KIT_DIR/lib/gate/gate-ledger.sh"
PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert() { TOTAL=$((TOTAL+1)); if [ "$2" -eq 0 ]; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1)); else echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL+1)); fi; }

echo "=== every-step review (SPEC-093 AC1-AC3) ==="

# --- AC1: every full-lane phase maps to a review in WORKFLOW's every-step mapping ---
grep -qi 'Every-step review in the full-autonomous lane' "$WF"; assert "AC1: WORKFLOW has the every-step review mapping section" $?
# each review-bearing phase names a concrete review agent/command in the V-model + mapping
for pair in "spec-validate" "review-team" "task-verifier" "integration-verifier" "doc-verifier" "acceptance-verifier" "system-verifier" "brief-reviewer" "recheck-verifier" "advisor"; do
  grep -qi "$pair" "$WF"; assert "AC1: mapping wires a review: $pair" $?
done
# no review-bearing full-lane phase is skip: every 'required full' phase resolves in the plan
REQ=$(bash "$GL" required full 2>/dev/null | tr '\n' ' ')
[ -n "$REQ" ] && { trap '' PIPE; echo "$REQ" 2>/dev/null || :; } | grep -q 'spec' && { trap '' PIPE; echo "$REQ" 2>/dev/null || :; } | grep -q 'review' && { trap '' PIPE; echo "$REQ" 2>/dev/null || :; } | grep -q 'ship'
assert "AC1: full lane's required set includes spec+review+ship (no review phase skipped)" $?

# --- AC2 [NEGATIVE CONTROL]: ship-gate (gate-ledger check) BLOCKS a missing required review ---
# Real exercise of the enforcement path in an isolated ledger dir.
TMPLOG="$(mktemp -d "${TMPDIR:-/tmp}/every-step.XXXXXX")"
export DWARVES_KIT_LOG_DIR="$TMPLOG"
RID="everystep-negctl"
# record ALL required full gates EXCEPT 'review'
for g in $REQ; do
  [ "$g" = "review" ] && continue
  bash "$GL" record "$RID" "$g" ran "test" >/dev/null 2>&1
done
if bash "$GL" check full "$RID" >/dev/null 2>&1; then
  assert "AC2 [NEGATIVE CONTROL]: check PASSES with 'review' missing (SHOULD block)" 1
else
  assert "AC2 [NEGATIVE CONTROL]: check BLOCKS when required 'review' gate is missing" 0
fi
# now record the missing gate -> check must pass
bash "$GL" record "$RID" review ran "test" >/dev/null 2>&1
if bash "$GL" check full "$RID" >/dev/null 2>&1; then
  assert "AC2: check PASSES once every required phase-review is recorded" 0
else
  assert "AC2: check PASSES once every required phase-review is recorded" 1
fi
unset DWARVES_KIT_LOG_DIR
rm -rf "$TMPLOG" 2>/dev/null || true

# --- AC3: enforcement at ship, NOT a mid-flight hard block ---
grep -qiE 'Enforcement is at ship, never mid-flight' "$WF"; assert "AC3: WORKFLOW states enforcement at ship, never mid-flight" $?
grep -qiE 'advisory and does NOT halt|advisory.*does not halt|mid-flight.*advisory' "$WF"; assert "AC3: a failing phase-review mid-flight is advisory, does not halt the run" $?
# the four-hard-stops table must NOT have gained a phase-review / every-step blocker
if awk '/### The four hard stops/{f=1} f&&/^## /&&!/hard stops/{f=0} f' "$WF" | grep -qiE 'every-step|phase-review'; then
  assert "AC3: every-step review did NOT become a new hard stop" 1
else
  assert "AC3: every-step review did NOT become a new hard stop (still advisory + ship-gate only)" 0
fi

echo ""
echo "=== $PASS/$TOTAL passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
