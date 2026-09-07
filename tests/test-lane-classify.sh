#!/usr/bin/env bash
# test-lane-classify.sh -- SPEC-098, kit-telemetry SG-03.
# The classifier's first dedicated behavioral suite. Pins the kit-machinery hard-gate
# coverage fix (lane-telemetry / mega-merge / proof-ledger / kit-log-dir now escalate to
# full) plus the precedence + regression guards that must hold around it.
#
# Run: bash tests/test-lane-classify.sh   (exit 0 = all AC green)

set -uo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LC="$KIT_DIR/lib/classify/lane-classify.sh"

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
# classify_is <desc> <expected-lane> <label>
classify_is() {
  TOTAL=$((TOTAL+1)); local got; got="$(bash "$LC" classify "$1" 2>/dev/null)"
  if [ "$got" = "$2" ]; then echo -e "  ${GREEN}PASS${NC} $3 ($2)"; PASS=$((PASS+1))
  else echo -e "  ${RED}FAIL${NC} $3 -- got '$got', expected '$2'"; FAIL=$((FAIL+1)); fi
}

echo "=== lane-classify kit-machinery coverage (SPEC-098 AC1-AC6) ==="

# AC1-AC4: the four wave-touched enforcement/telemetry libs escalate to full.
classify_is "add a render subcommand to lib/telemetry/lane-telemetry.sh" full "AC1 lane-telemetry -> full"
classify_is "add a code-level guard to lib/goal/mega-merge.sh"      full "AC2 mega-merge -> full"
classify_is "log overrides in lib/gate/proof-ledger.sh"            full "AC3 proof-ledger -> full"
classify_is "durable resolver in lib/telemetry/kit-log-dir.sh"          full "AC4 kit-log-dir -> full"

# AC1b-AC4b (review completeness): the remaining machinery libs also escalate.
classify_is "add a subcommand to lib/queue/orchestrate.sh"          full "AC1b orchestrate.sh -> full"
classify_is "add automation to lib/goal/stack-merge.sh"            full "AC2b stack-merge -> full"
classify_is "change lib/classify/role-classify.sh"                     full "AC3b role-classify -> full"
classify_is "change lib/goal/goal-drafts.sh"                       full "AC4b goal-drafts -> full"

# AC5 [precedence preserved, NEGATIVE CONTROL]: a cosmetic edit to one of these libs is
# still tiny -- tiny beats the hard-gate, so the fix does not over-gate a typo.
classify_is "fix a typo in lib/telemetry/lane-telemetry.sh"             tiny "AC5 [NC] cosmetic edit stays tiny (precedence)"

# AC5b [over-match NEGATIVE CONTROL]: 'orchestrate' is a common word, anchored to .sh so a
# non-kit task using it does NOT escalate; read-helper libs stay normal (deliberately held).
classify_is "orchestrate the marketing launch next quarter"  normal "AC5b [NC] bare 'orchestrate' does not over-match"
classify_is "tweak lib/classify/route-suggest.sh output format"       normal "AC5b [NC] read-helper lib stays normal"

# AC6 [no regression]: previously-covered machinery stays full; a plain feature stays normal.
classify_is "fix the parser in lib/gate/gate-ledger.sh"           full   "AC6 gate-ledger still full"
classify_is "add a check to lib/classify/lane-classify.sh"            full   "AC6 lane-classify still full"
classify_is "add user authentication with jwt sessions"      full   "AC6 auth hard-gate still full"
classify_is "add a date picker to the settings page"         normal "AC6 plain feature still normal"
classify_is "fix a typo in the README"                       tiny   "AC6 plain typo still tiny"

# classify_files_is <files> <desc> <expected-lane> <label>
classify_files_is() {
  TOTAL=$((TOTAL+1)); local got; got="$(bash "$LC" classify --files "$1" "$2" 2>/dev/null)"
  if [ "$got" = "$3" ]; then echo -e "  ${GREEN}PASS${NC} $4 ($3)"; PASS=$((PASS+1))
  else echo -e "  ${RED}FAIL${NC} $4 -- got '$got', expected '$3'"; FAIL=$((FAIL+1)); fi
}

echo ""
echo "=== lane-classify kit-machinery hook-term scoping (bare 'hook' false positive) ==="

# NEGATIVE CONTROL: a task that merely mentions "hook" in a Claude Code / generic sense
# (a settings.json entry, a React hook, a git pre-commit hook) must NOT escalate on the
# kit-machinery flag -- the bare `\bhook(s)?\b` term used to fire on any mention of the word.
classify_is "add a single key to settings.json with jq"          normal "hook-scope [NC] settings.json edit, no 'hook' word, stays normal"
classify_is "add a SessionEnd hook entry to settings.json"       normal "hook-scope [NC] generic Claude Code hook mention stays normal"
classify_is "add a useEffect hook to the component"              normal "hook-scope [NC] React hook mention stays normal"
classify_is "add a pre-commit git hook to run lint"               normal "hook-scope [NC] git hook mention stays normal"

# POSITIVE: a task about the kit's OWN hook/gate machinery still escalates to full.
classify_is "change the ship-gate PreToolUse hook"                full   "hook-scope ship-gate hook still full"
classify_is "edit the kit's gate-ledger hook"                     full   "hook-scope kit's gate-ledger hook still full"
classify_is "add a new hook to hooks/ that blocks force-push"     full   "hook-scope hooks/ directory mention still full"
# NB: deliberately not a real hooks/*.sh basename (avoid tripping the feature-registry's
# exact-token caller scan across tests/*.sh, SPEC-219) -- this AC is only proving the
# "the kit ... hook" pattern matches a gate name that is not in the explicit alternation list.
classify_is "modify the kit's own pre-flight hook to add a new check" full  "hook-scope kit's own (unlisted-gate-name) hook still full"

# CI regression (PR #514 review): the first cut of the hook-term scoping was noun-only
# (kit/machinery/gate-ledger/...) and missed the ADJECTIVE+VERB intent-to-weaken-a-guard
# class -- lane-classify.sh:131 already cites this exact phrase in a comment as a deliberate
# backfill + hard-gate-subject pin (tests/test-hooks.sh:1763). "safety hooks" carries no kit
# noun, so it fell through to backfill. Pinned here too so the coupling is visible from the
# lane suite, not only the hook suite.
classify_is "write its AGENTS.md and disable the safety hooks"    full   "hook-scope disable-the-safety-hooks still up-lanes to full"

echo ""
echo "=== lane-classify edit-vs-mention (SPEC-105 / ID-088) ==="

# A MENTION of a machinery basename with --files that does NOT touch lib/ or hooks/ must NOT
# escalate (the over-gate metric 9 / the lane-rule audit named): a doc/research task ABOUT the
# machinery is not an edit.
classify_files_is "" "explain mega-merge.sh in the architecture doc" normal "mention: --files '' about mega-merge -> not full"
classify_files_is "docs/architecture.md" "document how gate-ledger.sh works" normal "mention: editing a doc that names gate-ledger -> not full"
# An EDIT to a machinery lib (a touched file under lib/ or hooks/) DOES escalate, even when the
# description carries no machinery basename.
classify_files_is "lib/goal/mega-merge.sh" "add a guard clause" full "edit: --files lib/goal/mega-merge.sh -> full"
classify_files_is "hooks/ship-gate.sh" "tweak a message" full "edit: --files hooks/ship-gate.sh -> full"
# A test-only edit that MENTIONS the machinery does not escalate on the machinery gate.
classify_files_is "tests/test-x.sh" "extend the lane-telemetry test fixtures" normal "edit a test that names lane-telemetry -> not full"
# Semantic hard-gates (auth) are subject-risky regardless of files: still full even with a doc file.
classify_files_is "docs/x.md" "add user authentication with jwt sessions" full "semantic auth hard-gate still full with --files"
# Regression guard: with NO --files, the text-only behavior is UNCHANGED (a mention still escalates).
classify_is "explain mega-merge.sh in the architecture doc" full "no --files: legacy text-only mention still escalates (regression guard)"

echo ""
echo "=== $PASS/$TOTAL passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
