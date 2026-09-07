#!/usr/bin/env bash
# test-command-emit-sweep.sh -- SPEC-139, kit-run-integrity mega-goal sub-goal 05 (ID-256).
#
# RUN_REPORT.md (`/kit:mega`'s per-sub-goal gate matrix) can only show a phase as covered if
# SOME command actually calls `gate-ledger.sh` for it. A 2026-07-04 audit of every file under
# commands/ found 11 of 29 with a real gate-ledger call and 18 dark, with no distinction
# between "this phase genuinely has no ledger concern" and "nobody wired it yet" -- the
# RUN_REPORT under-counts silently either way. This sub-goal wires 9 of the 18 (the
# phase-owning ones: spec, spec-validate, verify, think, design, ui-design, docs, retro,
# explain) and documents the other 9 (utility commands) as an explicit exemption table in
# WORKFLOW.md's "## Command emit coverage (SPEC-139)" section -- the single source of truth,
# parsed here, no second copy.
#
# This file proves the FOREVER invariant, mirroring the no-orphan sweep pattern already
# established by tests/test-understanding-wiring.sh / tests/test-kri-wiring.sh /
# tests/test-docs-wiring.sh: every command in commands/ either mentions `gate-ledger` (a real
# emit) OR is named in WORKFLOW.md's exemption table (a documented, reasoned no-emit). A new
# command added later with neither is an ORPHAN -- caught by this test, not discovered months
# later when RUN_REPORT quietly under-counts it.
#
#   AC1  every command in commands/ (a) mentions gate-ledger, or (b) is in the exemption table
#   AC2  the exemption table names exactly the 11 expected utility commands (no silent drift)
#   AC3  each of the 9 newly-wired commands genuinely contains a gate-ledger record call
#        (not just present-by-coincidence in the loose AC1 check)
#   AC4  NEGATIVE CONTROL: a fixture command with NEITHER an emit NOR an exemption entry IS
#        flagged an orphan by the same sweep function, proving it actually catches the bug
#        class, not just that the real repo happens to be clean
#   AC5  the exemption table is load-bearing for `dispatch.md` specifically: dispatch.md has
#        ZERO gate-ledger mentions of its own, so removing its exemption-table entry would
#        turn it into an orphan -- proving the table is not decorative
#
# Run: bash tests/test-command-emit-sweep.sh   (exit 0 = all AC green)

set -uo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMMANDS_DIR="$KIT_DIR/commands"
WORKFLOW="$KIT_DIR/docs/WORKFLOW.md"  # bulk lives in docs/ (SPEC-185); root WORKFLOW.md is a thin stub

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert() { TOTAL=$((TOTAL+1)); if [ "$2" -eq 0 ]; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1)); else echo -e "  ${RED}FAIL${NC} $1 ${3:-}"; FAIL=$((FAIL+1)); fi; }
assert_eq() { TOTAL=$((TOTAL+1)); if [ "$2" = "$3" ]; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1)); else echo -e "  ${RED}FAIL${NC} $1 (expected '$3', got '$2')"; FAIL=$((FAIL+1)); fi; }

# ---------------------------------------------------------------------------------------
# exemption_list <workflow-md>: prints one bare command-name (no .md) per line, parsed from
# WORKFLOW.md's "## Command emit coverage" section table (single source of truth; the
# matrix_for_lane() precedent in lib/gate/gate-ledger.sh parses WORKFLOW.md the same way, no
# second copy of the mapping). A row is `| \`<name>.md\` | <reason> |` -- ANCHORED at the
# line start (the FIRST column only), so a rationale sentence that re-mentions its own or
# another command's filename in backticks (e.g. mega's/dispatch's own rows do, explaining
# themselves) is never double-counted or mistaken for a second exemption.
# ---------------------------------------------------------------------------------------
exemption_list() {
  local doc="$1"
  awk '/^## Command emit coverage/{f=1;next} f&&/^## /{exit} f' "$doc" \
    | grep -E '^\| *`[a-z][a-z0-9-]*\.md` *\|' \
    | sed -E 's/^\| *`([a-z][a-z0-9-]*)\.md`.*/\1/'
}

# sweep_check <commands-dir> <exemption-list-string>: prints one "ORPHAN: <name>.md" line per
# command with neither a gate-ledger mention nor an exemption entry; return code = orphan count.
sweep_check() {
  local dir="$1" exempt="$2" f base orphans=0
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    base="$(basename "$f" .md)"
    grep -qi 'gate-ledger' "$f" && continue
    { trap '' PIPE; printf '%s\n' "$exempt" 2>/dev/null || :; } | grep -qxF "$base" && continue
    echo "  ORPHAN: $base.md (no gate-ledger mention, not in the exemption table)"
    orphans=$((orphans + 1))
  done
  return "$orphans"
}

EXEMPT="$(exemption_list "$WORKFLOW")"

echo "=== AC1: no-orphan sweep -- every real commands/*.md either emits or is exempted ==="

ORPHAN_OUT="$(sweep_check "$COMMANDS_DIR" "$EXEMPT")"
ORPHAN_RC=$?
[ -n "$ORPHAN_OUT" ] && echo "$ORPHAN_OUT" >&2
if [ "$ORPHAN_RC" -eq 0 ]; then RC=0; else RC=1; fi
assert "every command in commands/ mentions gate-ledger OR is exempted (0 orphans)" $RC

TOTAL_COMMANDS=$(find "$COMMANDS_DIR" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')
echo "  (info) commands/ currently has $TOTAL_COMMANDS command files -- AC1 above is the real invariant; no hardcoded pin here per the repo's no-hardcoded-counts rule (a literal roster size goes stale on the next addition)"

echo ""
echo "=== AC2: the exemption table names exactly the 11 expected utility commands ==="

EXPECTED_EXEMPT="absorb
adopt
dispatch
draft-agent
feature-map
kit-health
mega
next
onboard
start
visual-team"

SORTED_EXPECTED="$(printf '%s\n' "$EXPECTED_EXEMPT" | sort)"
SORTED_ACTUAL="$(printf '%s\n' "$EXEMPT" | sort)"
assert_eq "exemption table = {absorb,adopt,dispatch,draft-agent,feature-map,kit-health,mega,next,onboard,start,visual-team}, no more no less" "$SORTED_ACTUAL" "$SORTED_EXPECTED"

echo ""
echo "=== AC3: each of the 9 newly-wired commands genuinely records its own phase ==="

declare -A NEW_PHASE=(
  [spec]='Spec'
  [spec-validate]='Validate'
  [verify]='verify'
  [think]='Think'
  [design]='Design'
  [ui-design]='UI design'
  [docs]='Docs'
  [retro]='Reflect'
  [explain]='explain'
)
for cmd in "${!NEW_PHASE[@]}"; do
  phase="${NEW_PHASE[$cmd]}"
  RC=0
  grep -qE "gate-ledger\.sh\"? *record <rid> [\"\`]?${phase}[\"\`]? ran" "$COMMANDS_DIR/$cmd.md" || RC=1
  assert "commands/$cmd.md records '$phase ran' via gate-ledger.sh (real call, not a loose match)" $RC
done

echo ""
echo "=== AC4: NEGATIVE CONTROL -- a fixture command with neither emit nor exemption IS caught ==="

FIXTURE_DIR="$(mktemp -d -t command-emit-sweep-fixture.XXXXXX)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

# one legit "emits" copy, one legit "exempt" copy, one fabricated bad command (SPEC-139's own
# c6fbd99-class bug: a new command lands with no emit and no exemption entry).
cp "$COMMANDS_DIR/review.md" "$FIXTURE_DIR/review.md"
cp "$COMMANDS_DIR/next.md" "$FIXTURE_DIR/next.md"
cat > "$FIXTURE_DIR/fixture-bad-command.md" <<'EOF'
---
description: "TEST FIXTURE ONLY: proves the sweep catches an unrecorded, unlisted command."
---
This fixture exists only to prove test-command-emit-sweep.sh's sweep function catches an
orphaned command. It must never appear in the real commands directory. It deliberately says
nothing about the audit ledger tool this whole test suite is about, by name, anywhere in this
file -- that omission is the point of the fixture.
EOF

FIXTURE_OUT="$(sweep_check "$FIXTURE_DIR" "$EXEMPT")"
FIXTURE_RC=$?
assert_eq "the sweep flags exactly 1 orphan in the fixture dir (the fabricated bad command)" "$FIXTURE_RC" "1"

if { trap '' PIPE; printf '%s\n' "$FIXTURE_OUT" 2>/dev/null || :; } | grep -qF "ORPHAN: fixture-bad-command.md"; then RC=0; else RC=1; fi
assert "the flagged orphan is specifically fixture-bad-command.md (not a false hit on the legit copies)" $RC

if { trap '' PIPE; printf '%s\n' "$FIXTURE_OUT" 2>/dev/null || :; } | grep -q "ORPHAN: review.md"; then RC=1; else RC=0; fi
assert "the legit 'emits' copy (review.md) is NOT flagged" $RC

if { trap '' PIPE; printf '%s\n' "$FIXTURE_OUT" 2>/dev/null || :; } | grep -q "ORPHAN: next.md"; then RC=1; else RC=0; fi
assert "the legit 'exempt' copy (next.md) is NOT flagged" $RC

echo ""
echo "=== AC5: the exemption table is load-bearing for dispatch.md (not decorative) ==="

RC=0
grep -qi 'gate-ledger' "$COMMANDS_DIR/dispatch.md" && RC=1
assert "dispatch.md has ZERO gate-ledger mentions of its own (the exemption entry is the ONLY thing keeping it non-orphan)" $RC

EXEMPT_WITHOUT_DISPATCH="$(printf '%s\n' "$EXEMPT" | grep -vxF 'dispatch')"
WITHOUT_OUT="$(sweep_check "$COMMANDS_DIR" "$EXEMPT_WITHOUT_DISPATCH")"
WITHOUT_RC=$?
assert_eq "removing dispatch's exemption entry alone makes the sweep flag exactly 1 new orphan (dispatch.md)" "$WITHOUT_RC" "1"

if { trap '' PIPE; printf '%s\n' "$WITHOUT_OUT" 2>/dev/null || :; } | grep -qF "ORPHAN: dispatch.md"; then RC=0; else RC=1; fi
assert "...and that orphan is specifically dispatch.md" $RC

echo ""
echo "=== Results ==="
echo -e "Passed: ${GREEN}${PASS}${NC} / ${TOTAL}"
if [ "$FAIL" -gt 0 ]; then
  echo -e "Failed: ${RED}${FAIL}${NC}"
  exit 1
else
  echo -e "${GREEN}All command-emit-sweep tests passed.${NC}"
  exit 0
fi
