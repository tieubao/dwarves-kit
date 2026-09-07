#!/usr/bin/env bash
# test-agent-effectiveness.sh -- SPEC-088, kit-hardening SG-01.
# Validates the agent-effectiveness read-only validator across AC1-AC5.
#
# Like test-review-team-plants.sh, we cannot dispatch a live Claude reviewer in
# CI, so AC1/AC2 test PROMPT COMPLETENESS: each planted-bad fixture literally
# carries its defect (a grep proves the fixture REPRESENTS the class), and the
# validator prompt carries the lens vocabulary needed to NAME that class. AC3
# (read-only tools), AC4 (fail-safe posture), and AC5 (diff-keyed wiring) are
# fully deterministic greps. A real negative control (the same read-only check
# that PASSES the validator FAILS a planted over-grant fixture) is asserted so
# the test can distinguish a good agent from a bad one, not just rubber-stamp.
#
# Run: bash tests/test-agent-effectiveness.sh   (exit 0 = all AC green)

set -uo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$KIT_DIR/tests/fixtures/agent-effectiveness"
AGENT="$KIT_DIR/agents/agent-effectiveness.md"
WIRING="$KIT_DIR/commands/draft-agent.md"
PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert() { TOTAL=$((TOTAL+1)); if [ "$2" -eq 0 ]; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1)); else echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL+1)); fi; }

# Extract only the YAML frontmatter tools block of an agent file (between the two
# --- markers), then report a read-only VIOLATION (a write-capable or bare-Bash
# tool) if present. This is the machine core of the Tools lens.
tools_violation() {
  awk '/^---$/{c++; next} c==1' "$1" \
    | grep -E '^[[:space:]]*-[[:space:]]*(Edit|Write|NotebookEdit|MultiEdit)[[:space:]]*$|^[[:space:]]*-[[:space:]]*Bash[[:space:]]*$'
}

# --- GATE MODE (SG-03/04 reuse): `test-agent-effectiveness.sh <agent-path>` runs
# the DETERMINISTIC lens subset (the parts of the 4 lenses machine-checkable in CI:
# read-only tools for a reviewer, valid model tier, on-axis name) against ONE agent
# and exits 0 iff it passes. This is the CI proxy for "gated by the 01 validator" a
# meta-agent-scaffolded review agent passes through; the full four-lens judgment is
# the LLM agent's job at runtime, this catches the mechanical defects. ---
if [ "${1:-}" != "" ] && [ -f "${1:-}" ]; then
  A="$1"; N=$(basename "$A" .md)
  echo "=== agent-effectiveness GATE: $A ==="
  [ -z "$(tools_violation "$A")" ]; assert "gate: $N declares read-only tools only" $?
  MODEL=$(awk -F': *' '/^---$/{c++; if(c==2)exit} c==1 && /^model:/{print $2; exit}' "$A" | tr -d '[:space:]')
  { trap '' PIPE; echo "$MODEL" 2>/dev/null || :; } | grep -qE '^(sonnet|haiku|opus)$'; assert "gate: $N model tier valid ($MODEL)" $?
  if { trap '' PIPE; echo "$N" 2>/dev/null || :; } | grep -qE -- '-checker$|-auditor$|^reviewer$|-validate$'; then
    assert "gate: $N name is not a retired review suffix" 1
  else
    assert "gate: $N name is not a retired review suffix" 0
  fi
  echo ""; echo "=== $PASS/$TOTAL passed, $FAIL failed ==="
  [ "$FAIL" -eq 0 ]; exit $?
fi

echo "=== agent-effectiveness validator (SPEC-088 AC1-AC5) ==="

# --- AC3: the validator uses ONLY read-only tools (deterministic) ------------
[ -f "$AGENT" ]; assert "AC3: agents/agent-effectiveness.md exists" $?
if [ -f "$AGENT" ] && [ -z "$(tools_violation "$AGENT")" ]; then
  assert "AC3: validator declares read-only tools only (no Edit/Write/NotebookEdit/bare-Bash)" 0
else
  assert "AC3: validator declares read-only tools only (no Edit/Write/NotebookEdit/bare-Bash)" 1
fi

# --- AC1 [negative control]: planted-bad flagged, one fixture per lens -------
# Each check has two halves: (a) the fixture REALLY carries the defect, and
# (b) the validator prompt carries the lens language to catch that class.

# Lens 1: tools over-grant. NEGATIVE CONTROL: tools_violation (the AC3 core)
# passes the validator above and MUST fire on this planted fixture.
if [ -n "$(tools_violation "$FIX/bad-tools-overgrant.md")" ]; then
  assert "AC1/tools [NEGATIVE CONTROL]: planted over-grant fixture flagged by read-only check (Write/Edit/Bash present)" 0
else
  assert "AC1/tools [NEGATIVE CONTROL]: planted over-grant fixture flagged by read-only check" 1
fi
grep -qi 'over-grant' "$AGENT"; assert "AC1/tools: validator prompt carries the over-grant lens" $?
grep -qi 'minimal.*sufficient\|minimal-yet-sufficient' "$AGENT"; assert "AC1/tools: validator prompt states minimal-and-sufficient" $?

# Lens 2: description misfire.
grep -qiE 'helps with stuff|reviews things' "$FIX/bad-desc-misfire.md"; assert "AC1/desc: planted misfire fixture has a too-vague description" $?
grep -qi 'misfire' "$AGENT"; assert "AC1/desc: validator prompt carries the misfire lens" $?
grep -qi 'too broad\|too narrow\|would miss' "$AGENT"; assert "AC1/desc: validator prompt checks both broad and narrow" $?

# Lens 3: instruction contradiction.
grep -qi 'read-only' "$FIX/bad-instr-contradict.md" && grep -qi 'apply the fix\|rewrite the offending' "$FIX/bad-instr-contradict.md"
assert "AC1/instr: planted contradiction fixture says read-only AND apply-the-fix" $?
grep -qi 'contradict' "$AGENT"; assert "AC1/instr: validator prompt carries the contradiction lens" $?
grep -qi 'ambigu' "$AGENT"; assert "AC1/instr: validator prompt carries the ambiguity lens" $?

# Lens 4: tier mismatch (opus for a mechanical string check).
grep -qE '^model:[[:space:]]*opus' "$FIX/bad-tier-mismatch.md" && grep -qi 'mechanical\|deterministic\|string-presence\|string presence' "$FIX/bad-tier-mismatch.md"
assert "AC1/tier: planted tier fixture is opus for a mechanical check" $?
grep -qi 'over-tiered\|under-tiered' "$AGENT"; assert "AC1/tier: validator prompt carries the tier lens" $?
grep -qiE 'file:line' "$AGENT"; assert "AC1: validator reports defects with file:line evidence" $?

# --- AC2: no false positives on a good agent / the real roster --------------
if [ -z "$(tools_violation "$FIX/good.md")" ]; then
  assert "AC2: good fixture has clean read-only tools (would not be over-grant-flagged)" 0
else
  assert "AC2: good fixture has clean read-only tools" 1
fi
grep -qi 'do not cry wolf\|both failure modes\|no real defect is a PASS\|CORRECT, not an over-grant' "$AGENT"
assert "AC2: validator prompt guards against false positives on a good agent" $?
# The hand-authored read-only roster must not trip the over-grant core (AC2 in practice).
ROSTER_OK=0
for a in task-verifier doc-verifier integration-verifier; do
  [ -f "$KIT_DIR/agents/$a.md" ] && [ -n "$(tools_violation "$KIT_DIR/agents/$a.md")" ] && ROSTER_OK=1
done
assert "AC2: real read-only roster agents (task/doc/integration) carry no over-grant" $ROSTER_OK

# --- AC4 [fail-safe]: infra failure -> UNVALIDATED, never a silent pass ------
grep -q 'UNVALIDATED' "$AGENT"; assert "AC4: validator has an UNVALIDATED verdict" $?
grep -qi 'never.*silent.*pass\|not a pass\|never a silent pass' "$AGENT"; assert "AC4: UNVALIDATED is explicitly not a pass (fail-safe)" $?
grep -qi 'live-risk' "$AGENT"; assert "AC4: an unvalidated agent is treated as live-risk" $?

# --- AC5 [gated]: diff-keyed wiring at the agent-author phase ----------------
[ -f "$WIRING" ]; assert "AC5: commands/draft-agent.md exists (agent-author phase)" $?
grep -qi 'agent-effectiveness' "$WIRING"; assert "AC5: draft-agent dispatches agent-effectiveness" $?
grep -qi 'diff-keyed\|only it\|ONLY it\|not every agent every run' "$WIRING"; assert "AC5: the dispatch is diff-keyed (new/changed agent only)" $?
grep -qi 'advisory' "$WIRING"; assert "AC5: the dispatch is advisory, never a mid-flight block" $?

echo ""
echo "=== $PASS/$TOTAL passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
