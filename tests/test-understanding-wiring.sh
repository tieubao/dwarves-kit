#!/usr/bin/env bash
# test-understanding-wiring.sh -- SPEC-127, understanding-gate SG-06 (the FINAL, docs-last sub-goal).
#
# The kit shipped five understanding-axis artifacts across SG-01..05 (design record,
# significance-classify, /kit:explain, quiz-gate, weekend-batch) directly to master, each PR
# touching WORKFLOW.md/README.md piecemeal. This is the no-orphan sweep the mega-goal's own
# kill-resilience lesson (c6fbd99) demands: a doc claim with no dispatch path behind it is a
# BLOCKING finding, not a detail. This suite proves:
#
#   AC1  WORKFLOW.md + AGENTS.md declare the understanding axis; README notes /kit:explain
#   AC2  no-orphan sweep: each of the 5 artifacts has a LIVE dispatch/invocation path
#   AC3  significance-classify.sh's `record` verb, once the one honest exception with no live
#        caller, is now WIRED into /kit:ship Step 8 (SPEC-136, before the quiz-gate tap); this
#        AC proves the live dispatch path exists and precedes the tap call, not just that a
#        string matches somewhere
#   AC4  NEGATIVE CONTROL: a fabricated over-claim (a fake lib call, no caller, no honesty
#        marker) is CAUGHT by the same sweep mechanism used for AC2/AC3 -- proving the sweep can
#        actually catch the c6fbd99 bug class, not just that nothing untested exists
#
# Run: bash tests/test-understanding-wiring.sh   (exit 0 = all AC green)

set -uo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert() {
  # assert <label> <exit-code-to-check> [expected-code, default 0]
  local label="$1" rc="$2" want="${3:-0}"
  TOTAL=$((TOTAL+1))
  if [ "$rc" -eq "$want" ]; then
    echo -e "  ${GREEN}PASS${NC} $label"
    PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label (rc=$rc, want=$want)"
    FAIL=$((FAIL+1))
  fi
}

WORKFLOW="$KIT_DIR/docs/WORKFLOW.md"  # bulk lives in docs/ (SPEC-185); root WORKFLOW.md is a thin stub
AGENTS="$KIT_DIR/AGENTS.md"
README="$KIT_DIR/README.md"

# ---------------------------------------------------------------------------
# The sweep mechanism: claim_wired <doc> <claim_regex> <caller_regex> <search_paths...>
#
# A claim (a line in <doc> matching <claim_regex>, e.g. "run bash lib/x.sh verb") is judged:
#   0 = WIRED       -- <caller_regex> found somewhere under <search_paths> OTHER than <doc> itself
#   1 = SILENT ORPHAN -- no caller found, and no honesty marker near the claim (the BLOCKING case)
#   2 = CLAIM ABSENT -- <claim_regex> was not even found in <doc> (a different failure: the doc
#                       does not make this claim at all)
#   3 = HONEST GAP   -- no caller found, but the claim's own paragraph (+/-4 lines) already says
#                       so ("known wiring gap" / "no invoking command" / "not yet invoked" /
#                       "no live caller") -- an ACCEPTABLE, non-blocking outcome (SG-06's honesty
#                       bar: claim only what dispatches, or say plainly that it does not yet).
# ---------------------------------------------------------------------------
claim_wired() {
  local doc="$1" claim_re="$2" caller_re="$3"; shift 3
  grep -qE "$claim_re" "$doc" 2>/dev/null || return 2

  local hit
  for hit in "$@"; do
    if [ -f "$hit" ]; then
      [ "$(cd "$(dirname "$hit")" && pwd)/$(basename "$hit")" = "$doc" ] && continue
      grep -qE "$caller_re" "$hit" 2>/dev/null && return 0
    else
      # directory: search recursively, excluding the claim doc itself
      if grep -rlE "$caller_re" "$hit" 2>/dev/null | grep -vF "$doc" | grep -q .; then
        return 0
      fi
    fi
  done

  # No live caller anywhere. Is the gap stated honestly in the claim's own neighborhood?
  if grep -B4 -A4 -E "$claim_re" "$doc" 2>/dev/null \
      | grep -qiE 'known wiring gap|no invoking command|not yet invoked|no live caller'; then
    return 3
  fi
  return 1
}

echo "=== AC1: WORKFLOW.md + AGENTS.md declare the axis; README notes /kit:explain ==="

RC=0; grep -qE '^## The understanding axis' "$WORKFLOW" || RC=1
assert "WORKFLOW.md has a '## The understanding axis' section" $RC

RC=0; grep -A60 -E '^## The understanding axis' "$WORKFLOW" | grep -qiE 'ADR-0031' || RC=1
assert "the understanding-axis section names ADR-0031" $RC

RC=0
SECTION="$(grep -A60 -E '^## The understanding axis' "$WORKFLOW")"
{ trap '' PIPE; echo "$SECTION" 2>/dev/null || :; } | grep -qiE 'design record'      || RC=1
{ trap '' PIPE; echo "$SECTION" 2>/dev/null || :; } | grep -qiE 'explain'            || RC=1
{ trap '' PIPE; echo "$SECTION" 2>/dev/null || :; } | grep -qiE 'quiz-gate|quiz'     || RC=1
{ trap '' PIPE; echo "$SECTION" 2>/dev/null || :; } | grep -qiE 'weekend.?batch'     || RC=1
assert "section covers design-record + explain + quiz-gate + weekend-batch (BEFORE + AFTER + debt-budget model)" $RC

RC=0; grep -qiE 'ADR-0031' "$AGENTS" && grep -qiE 'advisory' "$AGENTS" || RC=1
assert "AGENTS.md notes the axis as advisory (ADR-0031)" $RC

RC=0; grep -qF '/kit:explain' "$README" || RC=1
assert "README.md lists /kit:explain" $RC

echo ""
echo "=== AC2: no-orphan sweep -- each of the 5 artifacts has a live dispatch path ==="

# 1. Design record: generated by /kit:spec's template, BLOCKING-enforced by /kit:spec-validate
#    Reviewer 6. Two independent facts, both must hold (generation + enforcement).
RC=0; grep -qE '^## Design' "$KIT_DIR/commands/spec.md" || RC=1
assert "Design record: /kit:spec's template carries a '## Design' section" $RC

RC=0
grep -qiE 'Reviewer 6' "$KIT_DIR/commands/spec-validate.md" || RC=1
grep -qiE 'BLOCKING' "$KIT_DIR/commands/spec-validate.md" || RC=1
assert "Design record: /kit:spec-validate Reviewer 6 is a BLOCKING enforcer (WIRED)" $RC

# 2. significance-classify: the `classify` verb is live (called by lib/gate/quiz-gate.sh); the
#    `record` verb (the ledger-persisting one) is now ALSO live -- wired into /kit:ship Step 8
#    (SPEC-136), immediately before the quiz-gate tap, closing the "silent wave, but LOGGED" gap.
claim_wired "$WORKFLOW" \
  'significance-classify\.sh classify' \
  'SIG_CLASSIFY.*classify|significance-classify\.sh"? *classify' \
  "$KIT_DIR/lib/gate/quiz-gate.sh"
RC=$?
assert "significance-classify: 'classify' verb WIRED via lib/gate/quiz-gate.sh" $RC 0

claim_wired "$WORKFLOW" \
  'significance-classify\.sh record' \
  'significance-classify\.sh"? *record' \
  "$KIT_DIR/commands" "$KIT_DIR/hooks"
RC=$?
assert "significance-classify: 'record' verb is WIRED via commands/ship.md (SPEC-136)" $RC 0

# 3. /kit:explain: the command file exists (plugin auto-registration, same convention as every
#    other /kit:* command -- no central manifest lists commands, see .claude-plugin/plugin.json).
RC=0; [ -s "$KIT_DIR/commands/explain.md" ] || RC=1
assert "/kit:explain: commands/explain.md exists and is non-empty (auto-registered)" $RC

RC=0; [ -x "$KIT_DIR/lib/explain.sh" ] || RC=1
assert "/kit:explain: lib/explain.sh exists and is executable" $RC

# 4. quiz-gate: /kit:ship's own Step 8 literally instructs running lib/gate/quiz-gate.sh tap on a
#    gate/gated-final PR -- this IS the live merge-boundary dispatch path (SG-04's wiring claim).
claim_wired "$WORKFLOW" \
  'Step 8 runs `lib/gate/quiz-gate\.sh tap`' \
  'lib/gate/quiz-gate\.sh tap' \
  "$KIT_DIR/commands/ship.md"
RC=$?
assert "quiz-gate: /kit:ship Step 8 invokes 'lib/gate/quiz-gate.sh tap' (WIRED)" $RC 0

# 5. weekend-batch: Han-invoked only (no scheduled job) via the ops-toolkit weekend-debt-paydown
#    skill; in THIS repo the collect/mark-paid verbs must actually exist as a live surface for
#    that skill to call, and WORKFLOW.md must document the cross-repo invoker honestly (not claim
#    an in-repo auto-fire that doesn't exist).
RC=0
grep -qE '^\s*collect\)' "$KIT_DIR/lib/learn/weekend-batch.sh" || RC=1
grep -qE '^\s*mark-paid\)' "$KIT_DIR/lib/learn/weekend-batch.sh" || RC=1
assert "weekend-batch: lib/learn/weekend-batch.sh exposes 'collect' + 'mark-paid' verbs" $RC

RC=0
grep -A60 -E '^## The understanding axis' "$WORKFLOW" | grep -qiE 'Han-invoked|Han invoked' || RC=1
grep -A60 -E '^## The understanding axis' "$WORKFLOW" | grep -qiE 'weekend-debt-paydown' || RC=1
assert "weekend-batch: WORKFLOW.md honestly scopes it Han-invoked (no scheduled job), names the ops-toolkit skill" $RC

echo ""
echo "=== AC3: wiring check -- commands/ship.md now calls significance-classify.sh record (SPEC-136) ==="

# Flipped from the prior "honest gap" assertion: SPEC-136 wired significance-classify.sh record
# into /kit:ship Step 8, immediately before the quiz-gate tap call. This is a genuine grep-based
# assertion against the real command file (mirrors how quiz-gate's own "Step 8 invokes tap" claim
# is asserted above), not a tautology restating claim_wired's own regex.
RC=0
if ! grep -rlE 'significance-classify\.sh"? *record' "$KIT_DIR/commands" "$KIT_DIR/hooks" 2>/dev/null | grep -q .; then
  RC=1  # no caller anywhere -- the gap would be back, and WORKFLOW.md's "wired" wording would be false
fi
assert "commands/*.md or hooks/*.sh calls significance-classify.sh record (live dispatch path)" $RC

RC=0
SHIP_MD="$KIT_DIR/commands/ship.md"
grep -qE 'significance-classify\.sh"? *record' "$SHIP_MD" || RC=1
assert "specifically commands/ship.md calls significance-classify.sh record" $RC

RC=0
# Ordering: the record call's line number must be BEFORE the quiz-gate tap call's line number,
# so the ledger marker really is written before the tap decision (not after, not unrelated).
RECORD_LINE="$(grep -nE 'significance-classify\.sh"? *record' "$SHIP_MD" | head -n1 | cut -d: -f1)"
TAP_LINE="$(grep -nE 'quiz-gate\.sh"? *tap' "$SHIP_MD" | head -n1 | cut -d: -f1)"
if [ -z "$RECORD_LINE" ] || [ -z "$TAP_LINE" ] || [ "$RECORD_LINE" -ge "$TAP_LINE" ]; then
  RC=1
fi
assert "the record call precedes the quiz-gate tap call in commands/ship.md (record line=$RECORD_LINE, tap line=$TAP_LINE)" $RC

echo ""
echo "=== AC4: NEGATIVE CONTROL -- a fabricated over-claim IS caught by the sweep ==="

FIXTURE="$(mktemp -t understanding-wiring-fixture.XXXXXX)"
trap 'rm -f "$FIXTURE"' EXIT
cat > "$FIXTURE" <<'EOF'
## The understanding axis (ADR-0031)

- **Fake gate (TEST FIXTURE, mirrors the c6fbd99 over-claim bug class):** at Ship, run
  `bash lib/kit-fixture-nonexistent-verb.sh persist <rid>` to write the fake marker. This is
  purely a test fixture; no such file or caller exists anywhere in the real kit.
EOF

# Sanity: the fake lib file genuinely does not exist anywhere in the real repo (else the NC
# would be testing nothing). Excludes this test script itself, which legitimately names the
# fixture string once (in the heredoc above and in this comment) without calling it.
RC=0
if grep -rl 'kit-fixture-nonexistent-verb' "$KIT_DIR/commands" "$KIT_DIR/hooks" "$KIT_DIR/lib" \
    "$WORKFLOW" "$AGENTS" "$README" 2>/dev/null | grep -q .; then
  RC=1
fi
assert "NC sanity: the fixture's fake artifact has zero real callers in the repo" $RC

claim_wired "$FIXTURE" \
  'kit-fixture-nonexistent-verb\.sh persist' \
  'kit-fixture-nonexistent-verb\.sh"? *persist' \
  "$KIT_DIR/commands" "$KIT_DIR/hooks" "$KIT_DIR/lib"
RC=$?
assert "NEGATIVE CONTROL: the sweep flags the fabricated over-claim as a SILENT ORPHAN (rc=1), not a false PASS" $RC 1

echo ""
echo "=== Results ==="
echo -e "Passed: ${GREEN}${PASS}${NC} / ${TOTAL}"
if [ "$FAIL" -gt 0 ]; then
  echo -e "Failed: ${RED}${FAIL}${NC}"
  exit 1
else
  echo -e "${GREEN}All understanding-wiring tests passed.${NC}"
  exit 0
fi
