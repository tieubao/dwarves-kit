#!/bin/bash
# test-picture-section.sh -- Proves the ID-454 `## Picture` presence check (spec's PRE-build
# twin of ID-395's post-build visual proof).
#
# `/kit:spec-validate`'s Reviewer 4 addition is prompt text, not code, so this harness cannot
# drive the live LLM judgment. What it CAN prove, honestly, is the STRUCTURAL contract Reviewer
# 4 is specified to enforce: given a spec's own `Lane:` header and its `## Picture` section
# body, does the presence verdict match what commands/spec-validate.md's new bullet specifies?
# This mirrors tests/test-design-record.sh's pattern exactly (same limitation, same shape).
#
# Run: bash tests/test-picture-section.sh
# Exit 0 = all tests pass. Exit 1 = failures found.

KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$KIT_DIR/tests/fixtures/picture-section"
PASS=0
FAIL=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_eq() {
  local NAME="$1" EXPECTED="$2" ACTUAL="$3"
  TOTAL=$((TOTAL + 1))
  if [ "$ACTUAL" = "$EXPECTED" ]; then
    echo -e "  ${GREEN}PASS${NC} $NAME"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} $NAME (expected '$EXPECTED', got '$ACTUAL')"
    FAIL=$((FAIL + 1))
  fi
}

# ------------------------------------------------------------------
# Reviewer 4's Picture presence check, reproduced as a pure function.
# ------------------------------------------------------------------

spec_lane() {
  # Same parse hooks/ship-gate.sh already uses: first word after "Lane:".
  grep -m1 -iE '^Lane:' "$1" 2>/dev/null | sed -E 's/^[Ll]ane:[[:space:]]*//; s/[[:space:]].*$//'
}

picture_section_body() {
  # Everything between the literal "## Picture" heading and the next "## " heading.
  awk '
    /^## Picture$/ { flag=1; next }
    /^## /         { flag=0 }
    flag           { print }
  ' "$1"
}

picture_section_body_nonblank() {
  picture_section_body "$1" | sed '/^[[:space:]]*$/d'
}

reviewer4_picture_verdict() {
  # Returns PASS or FLAG, mirroring commands/spec-validate.md Reviewer 4's Picture-presence
  # bullet: required (non-empty) on full lane, encouraged-only everywhere else.
  local f="$1" lane body
  lane="$(spec_lane "$f")"
  body="$(picture_section_body_nonblank "$f")"
  if [ "$lane" = "full" ] && [ -z "$body" ]; then
    echo FLAG
    return
  fi
  echo PASS
}

# ============================================================
echo "=== ID-454: Picture presence fixtures ==="
# ============================================================

EMPTY_FULL="$FIXTURES/full-lane-empty.md"
FILLED_FULL="$FIXTURES/full-lane-filled.md"
EMPTY_NORMAL="$FIXTURES/normal-lane-empty.md"
PROTOTYPE_FULL="$FIXTURES/full-lane-prototype-pointer.md"

for f in "$EMPTY_FULL" "$FILLED_FULL" "$EMPTY_NORMAL" "$PROTOTYPE_FULL"; do
  [ -f "$f" ] || { echo "FIXTURE MISSING: $f"; exit 1; }
done

echo ""
echo "--- NEGATIVE CONTROL: full-lane spec with an EMPTY Picture section ---"
LANE_1="$(spec_lane "$EMPTY_FULL")"
VERDICT_1="$(reviewer4_picture_verdict "$EMPTY_FULL")"
assert_eq "fixture 1 is Lane: full" "full" "$LANE_1"
assert_eq "fixture 1's Picture section is empty" "" "$(picture_section_body_nonblank "$EMPTY_FULL")"
assert_eq "Reviewer 4 FLAGS a full-lane spec with an empty Picture section" "FLAG" "$VERDICT_1"

echo ""
echo "--- POSITIVE: full-lane spec WITH an ASCII diagram ---"
LANE_2="$(spec_lane "$FILLED_FULL")"
VERDICT_2="$(reviewer4_picture_verdict "$FILLED_FULL")"
assert_eq "fixture 2 is Lane: full" "full" "$LANE_2"
assert_eq "fixture 2's Picture section is non-empty" "0" "$([ -z "$(picture_section_body_nonblank "$FILLED_FULL")" ] && echo 1 || echo 0)"
assert_eq "Reviewer 4 PASSES a full-lane spec with a filled Picture section" "PASS" "$VERDICT_2"

echo ""
echo "--- PROPORTIONALITY CONTROL: normal-lane spec, empty Picture is not required ---"
LANE_3="$(spec_lane "$EMPTY_NORMAL")"
VERDICT_3="$(reviewer4_picture_verdict "$EMPTY_NORMAL")"
assert_eq "fixture 3 is Lane: normal" "normal" "$LANE_3"
assert_eq "fixture 3's Picture section is empty" "" "$(picture_section_body_nonblank "$EMPTY_NORMAL")"
assert_eq "Reviewer 4 PASSES a normal-lane spec with an empty Picture section" "PASS" "$VERDICT_3"

echo ""
echo "--- ID-448 ROUTING: full-lane UI-shaped spec points Picture at a prototype branch ---"
LANE_4="$(spec_lane "$PROTOTYPE_FULL")"
BODY_4="$(picture_section_body_nonblank "$PROTOTYPE_FULL")"
VERDICT_4="$(reviewer4_picture_verdict "$PROTOTYPE_FULL")"
assert_eq "fixture 4 is Lane: full" "full" "$LANE_4"
RC=0; { trap '' PIPE; echo "$BODY_4" 2>/dev/null || :; } | grep -qF 'prototype/' || RC=1
assert_eq "fixture 4's Picture section names a prototype/<name> branch" 0 $RC
assert_eq "Reviewer 4 PASSES a full-lane spec whose Picture points at a prototype run" "PASS" "$VERDICT_4"

# ============================================================
echo ""
echo "=== Structural wiring: the 2 surfaces ID-454 touches ==="
# ============================================================

SPEC_MD="$KIT_DIR/commands/spec.md"
VALIDATE_MD="$KIT_DIR/commands/spec-validate.md"

RC=0; grep -qE '^## Picture$' "$SPEC_MD" || RC=1
assert_eq "commands/spec.md template has a top-level ## Picture heading" 0 $RC

RC=0; grep -qF '## Design' "$SPEC_MD" | head -1; awk '/^## Picture$/{p=1} p&&/^## Design$/{print "ok"; exit}' "$SPEC_MD" | grep -qF ok || RC=1
assert_eq "commands/spec.md's ## Picture sits before ## Design" 0 $RC

RC=0; grep -qiE 'full.{0,10}lane' "$SPEC_MD" || RC=1
assert_eq "commands/spec.md's Picture section names the full-lane bar" 0 $RC

RC=0; grep -qiE 'never mermaid' "$SPEC_MD" || RC=1
assert_eq "commands/spec.md's Picture section forbids mermaid" 0 $RC

RC=0; grep -qF 'kit:prototype' "$SPEC_MD" || RC=1
assert_eq "commands/spec.md's Picture section names the /kit:prototype routing" 0 $RC

RC=0; grep -qF 'Picture presence' "$VALIDATE_MD" || RC=1
assert_eq "commands/spec-validate.md Reviewer 4 names the Picture presence check" 0 $RC

RC=0; grep -qF 'Picture agrees with the task list' "$VALIDATE_MD" || RC=1
assert_eq "commands/spec-validate.md Reviewer 4 names the picture-vs-task-list lens question" 0 $RC

# NEGATIVE CONTROL: Reviewer 6 stays the only BLOCKING reviewer (Picture never introduces a
# second one).
RC=0
PICTURE_BLOCK="$(awk '/Picture presence/{flag=1} flag{print} flag&&/^- /&&!/Picture/{exit}' "$VALIDATE_MD")"
{ trap '' PIPE; echo "$PICTURE_BLOCK" 2>/dev/null || :; } | grep -qiE 'BLOCKING' && RC=1
assert_eq "Reviewer 4's Picture bullets carry no BLOCKING marker (Reviewer 6 stays the only one)" 0 $RC

RC=0; grep -qE 'Reviewer 6.*BLOCKING' "$VALIDATE_MD" || RC=1
assert_eq "Reviewer 6 is still the one reviewer marked BLOCKING" 0 $RC

# ============================================================
echo ""
echo "=== Results ==="
# ============================================================
echo -e "Passed: ${GREEN}${PASS}${NC} / ${TOTAL}"
if [ "$FAIL" -gt 0 ]; then
  echo -e "Failed: ${RED}${FAIL}${NC}"
  exit 1
else
  echo -e "${GREEN}All picture-section tests passed.${NC}"
  exit 0
fi
