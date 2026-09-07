#!/usr/bin/env bash
# test-outcome-emit-sweep.sh -- SPEC-193, harness-loop sub-goal 02.
#
# The standing coverage lint for SPEC-129's OUTCOME timing bracket: every `record <rid>
# <phase> ran ...` gate call site in commands/*.md must have a paired `outcome <rid> <phase>
# start` / `outcome <rid> <phase> end` bracket in the SAME file, or be named in the exemption
# list. This is the goal-file-mandated "standing test: a new gate call site without a paired
# OUTCOME bracket fails CI", built on the shared tests/lib/contract-lint.sh helper (SG-08's
# registry lint is expected to reuse that helper, not this test file).
#
#   AC1  every `record ... ran` site in commands/*.md has a paired `outcome ... end` (0 orphans)
#   AC2  ...and a paired `outcome ... start` (0 orphans)
#   AC3  each of the 22 SPEC-193-inventoried sites is individually asserted (start AND end,
#        exact phase string) -- not just the loose sweep, so a future edit that silently
#        renames a phase string (breaking the GATE/OUTCOME FIFO pairing in
#        lib/stats/src/stats/adapters.py::read_kit_gates) is caught here even though the loose
#        sweep alone would not catch a phase RENAME (only a phase's total absence)
#   AC4  NEGATIVE CONTROL: a fixture command with a `record ... ran` site and NO paired
#        `outcome` bracket IS flagged an orphan by the same sweep function
#   AC5  the `ship` exemption is load-bearing: commands/ship.md's own `record <rid> Ship ran`
#        line has NO `outcome ... Ship ...` bracket of its own (the live emit lives in
#        hooks/ship-gate.sh instead, SPEC-129's original wiring, same normalized phase key);
#        removing the exemption turns it into a false orphan
#
# Run: bash tests/test-outcome-emit-sweep.sh   (exit 0 = all AC green)

set -uo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMMANDS_DIR="$KIT_DIR/commands"
# shellcheck source=tests/lib/contract-lint.sh
. "$KIT_DIR/tests/lib/contract-lint.sh"

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert() { TOTAL=$((TOTAL+1)); if [ "$2" -eq 0 ]; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1)); else echo -e "  ${RED}FAIL${NC} $1 ${3:-}"; FAIL=$((FAIL+1)); fi; }
assert_eq() { TOTAL=$((TOTAL+1)); if [ "$2" = "$3" ]; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1)); else echo -e "  ${RED}FAIL${NC} $1 (expected '$3', got '$2')"; FAIL=$((FAIL+1)); fi; }

# A `record <rid|"$rid"|"$FINAL_RID"> <phase> ran` site; the phase (bare word or a quoted
# phrase, quotes kept) is the LAST capture group. Mirrors the exact shape every command file
# in this sweep uses (see docs/specs/SPEC-193-outcome-emit-sweep.md's inventory table).
SITE_PATTERN='s/.*gate-ledger\.sh"? +record +("\$[A-Za-z_]+"|<rid>) +("[^"]+"|[A-Za-z][A-Za-z_-]*) +ran.*/\2/p'
COV_END_TMPL='gate-ledger\.sh"? +outcome +("\$[A-Za-z_]+"|<rid>) +"?%PHASE%"? +end'
COV_START_TMPL='gate-ledger\.sh"? +outcome +("\$[A-Za-z_]+"|<rid>) +"?%PHASE%"? +start'

# `ship`'s bracket is emitted by hooks/ship-gate.sh (SPEC-129's original live emit), not by
# commands/ship.md itself; same normalized phase key ("Ship" -> "ship"), so it pairs correctly
# in the real ledger without a bracket instruction inside ship.md. See AC5.
EXEMPT="ship"

echo "=== AC1: no-orphan sweep -- every 'record ... ran' site has a paired 'outcome ... end' ==="
END_OUT="$(manifest_diff_by_phase "$COMMANDS_DIR" "*.md" "$SITE_PATTERN" "$COV_END_TMPL" "$EXEMPT")"
END_RC=$?
[ -n "$END_OUT" ] && echo "$END_OUT" >&2
assert "every 'record ... ran' site in commands/*.md has a paired 'outcome ... end' (0 orphans)" "$END_RC"

echo ""
echo "=== AC2: no-orphan sweep -- every 'record ... ran' site has a paired 'outcome ... start' ==="
START_OUT="$(manifest_diff_by_phase "$COMMANDS_DIR" "*.md" "$SITE_PATTERN" "$COV_START_TMPL" "$EXEMPT")"
START_RC=$?
[ -n "$START_OUT" ] && echo "$START_OUT" >&2
assert "every 'record ... ran' site in commands/*.md has a paired 'outcome ... start' (0 orphans)" "$START_RC"

echo ""
echo "=== AC3: the 22-site SPEC-193 inventory is exactly covered (per-site, exact phase) ==="

# file:phase pairs, one per inventoried site (SPEC-193's table). Phase strings match exactly
# what each command file's own `record` call passes (case/spacing as written).
SITES="execute.md:build
test-plan.md:test-plan
review.md:review
grill.md:grill
pitch.md:pitch
test-plan-review-team.md:test-plan
spec-validate.md:Validate
spec-validate.md:design-record
review-team.md:advisor
review-team.md:review
verify.md:verify
retro.md:Reflect
docs.md:Docs
explain.md:explain
devs-team.md:review
devs-team.md:design-critique
spec.md:Spec
design.md:Design
mega.md:advisor
think.md:Think
ui-design.md:UI design"

SITE_COUNT=0
while IFS=: read -r file phase; do
  [ -n "$file" ] || continue
  SITE_COUNT=$((SITE_COUNT + 1))
  esc="$(_regex_escape "$phase")"
  RC=0
  grep -qE "outcome +(\"\\\$[A-Za-z_]+\"|<rid>) +\"?${esc}\"? +start" "$COMMANDS_DIR/$file" || RC=1
  assert "$file: 'outcome ... $phase start' present" $RC
  RC=0
  grep -qE "outcome +(\"\\\$[A-Za-z_]+\"|<rid>) +\"?${esc}\"? +end" "$COMMANDS_DIR/$file" || RC=1
  assert "$file: 'outcome ... $phase end' present" $RC
done <<< "$SITES"

assert_eq "the inventory names exactly 21 file:phase rows (22 sites -- mega.md's advisor P5+P6 share one row, asserted once, both occurrences checked structurally by test-command-emit-sweep.sh's own AC and the mega.md prose itself)" "$SITE_COUNT" "21"

echo ""
echo "=== AC4: NEGATIVE CONTROL -- a fixture site with no paired bracket IS flagged ==="

FIXTURE_DIR="$(mktemp -d -t outcome-emit-sweep-fixture.XXXXXX)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

# one legit "bracketed" copy (real repo file), one fabricated bad command: has a `record ...
# ran` site with NO paired outcome bracket at all (the exact bug class this test exists to
# catch -- a new command lands with the GATE record but nobody wired the timing bracket).
cp "$COMMANDS_DIR/think.md" "$FIXTURE_DIR/think.md"
cat > "$FIXTURE_DIR/fixture-unbracketed.md" <<'EOF'
---
description: "TEST FIXTURE ONLY: proves the sweep catches a record-ran site with no OUTCOME bracket."
---
This fixture exists only to prove test-outcome-emit-sweep.sh's sweep function catches an
unbracketed gate call site. It must never appear in the real commands directory.

After the verdict, record it for lane telemetry, one line:
`bash lib/gate/gate-ledger.sh record <rid> fixture-phase ran "<verdict>"`.
EOF

FIXTURE_OUT="$(manifest_diff_by_phase "$FIXTURE_DIR" "*.md" "$SITE_PATTERN" "$COV_END_TMPL" "")"
FIXTURE_RC=$?
assert_eq "the sweep flags exactly 1 orphan in the fixture dir (the unbracketed fixture)" "$FIXTURE_RC" "1"

if { printf '%s\n' "$FIXTURE_OUT" 2>/dev/null || :; } | grep -qF "ORPHAN: fixture-unbracketed.md (fixture-phase)"; then RC=0; else RC=1; fi
assert "the flagged orphan is specifically fixture-unbracketed.md (fixture-phase)" $RC

if { printf '%s\n' "$FIXTURE_OUT" 2>/dev/null || :; } | grep -q "ORPHAN: think.md"; then RC=1; else RC=0; fi
assert "the legit bracketed copy (think.md) is NOT flagged" $RC

echo ""
echo "=== AC5: the 'ship' exemption is load-bearing (not decorative) ==="

RC=0
grep -qE "outcome +(\"\\\$[A-Za-z_]+\"|<rid>) +\"?[Ss]hip\"? +(start|end)" "$COMMANDS_DIR/ship.md" && RC=1
assert "commands/ship.md has NO outcome bracket of its own (the live emit is hooks/ship-gate.sh's, SPEC-129)" $RC

WITHOUT_OUT="$(manifest_diff_by_phase "$COMMANDS_DIR" "*.md" "$SITE_PATTERN" "$COV_END_TMPL" "")"
WITHOUT_RC=$?
RC=1; [ "$WITHOUT_RC" -ge 1 ] && RC=0
assert "removing the 'ship' exemption alone makes the sweep flag >=1 new orphan (ship.md)" "$RC"
if { printf '%s\n' "$WITHOUT_OUT" 2>/dev/null || :; } | grep -qF "ORPHAN: ship.md (Ship)"; then RC=0; else RC=1; fi
assert "...and that orphan is specifically ship.md (Ship)" $RC

echo ""
echo "=== Results ==="
echo -e "Passed: ${GREEN}${PASS}${NC} / ${TOTAL}"
if [ "$FAIL" -gt 0 ]; then
  echo -e "Failed: ${RED}${FAIL}${NC}"
  exit 1
else
  echo -e "${GREEN}All outcome-emit-sweep tests passed.${NC}"
  exit 0
fi
