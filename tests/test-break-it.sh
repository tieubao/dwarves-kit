#!/usr/bin/env bash
# test-break-it.sh -- SPEC-247, the adversarial prober lens.
#
# Like test-agent-effectiveness.sh and test-review-team-plants.sh, we cannot
# dispatch a live Claude prober in CI. So the suite splits in two:
#
#   MECHANISM   -- real exit codes. The fixture pair proves both directions (a
#                  green suite over a real hole, and a suite that pins the
#                  boundary), the naming-axis arm is proven load-bearing, and the
#                  battery/WORKFLOW wiring is read out of the live files.
#   PROMPT      -- STRUCTURAL completeness. Every load-bearing token the spec's
#                  I/O contract names must appear under the SECTION that owns it,
#                  not merely somewhere in the file. Section-scoping is what stops
#                  a bag-of-words prompt passing: a review experiment on
#                  2026-09-07 showed a gutted 12-line agent file containing every
#                  pinned phrase in one paragraph passed the earlier flat greps
#                  AND the SG-01 gate. Tokens, not sentences, are pinned, so
#                  rewording the prose does not red the suite.
#                  This proves the prompt STRUCTURES the class, never that a live
#                  run finds it. A live dispatch is the only proof of that, and it
#                  is recorded in docs/verification/, not here.
#
# The negative controls are what stop this from rubber-stamping: stripping the
# tight fixture's tagged upper-bound line must turn its suite red, and dropping
# the `break-it)` arm must make the naming axis reject the name.
#
# Run: bash tests/test-break-it.sh   (exit 0 = all AC green)

set -uo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
A="$KIT_DIR/agents/break-it.md"
BAT="$KIT_DIR/commands/battery.md"
WF="$KIT_DIR/docs/WORKFLOW.md"
META="$KIT_DIR/tests/test-meta.sh"
FIX="$KIT_DIR/tests/fixtures/break-it"
PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert() { TOTAL=$((TOTAL+1)); if [ "$2" -eq 0 ]; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1)); else echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL+1)); fi; }

# Frontmatter tools block only, reporting a read-only VIOLATION if present.
# Same machine core test-agent-effectiveness.sh uses.
tools_violation() {
  awk '/^---$/{c++; next} c==1' "$1" \
    | grep -E '^[[:space:]]*-[[:space:]]*(Edit|Write|NotebookEdit|MultiEdit)[[:space:]]*$|^[[:space:]]*-[[:space:]]*Bash[[:space:]]*$'
}

echo "=== break-it prober lens (SPEC-247) ==="

# --- TASK-001: the agent def -------------------------------------------------
echo ""
echo "--- agent definition ---"
[ -f "$A" ]; assert "T1: agents/break-it.md exists" $?
grep -qE '^name: *break-it *$' "$A"; assert "T1: name is the named-noun 'break-it' (DEC-002)" $?
grep -qE '^model: *opus *$' "$A"; assert "T1-DEC-004: model tier is opus" $?
if [ -z "$(tools_violation "$A")" ]; then
  assert "T1-AC2: no Write/Edit/MultiEdit/NotebookEdit/bare-Bash in the tools block" 0
else
  assert "T1-AC2: no Write/Edit/MultiEdit/NotebookEdit/bare-Bash in the tools block" 1
fi
# The roster is pinned as a SET, both directions: a silent narrowing and a silent
# widening are both visible. Battery leg 1 already re-executed the suite before
# this lens runs, and every language runner loads adversary-authored code before
# its first test (conftest.py, a pretest script, TestMain), so the three runner
# grants the first draft carried were redundant execution of hostile code. They
# are gone; `observed:` takes the UNVERIFIED path instead.
ROSTER=$(awk '/^---$/{c++; next} c==1' "$A" | sed -n 's/^[[:space:]]*-[[:space:]]*//p' | sed 's/[[:space:]]*$//')
EXPECTED_ROSTER='Read
Grep
Glob
Bash(git diff *)
Bash(git log *)'
[ "$(printf '%s\n' "$ROSTER" | sort)" = "$(printf '%s\n' "$EXPECTED_ROSTER" | sort)" ]
assert "T1-DEC-007: the tool roster is exactly the read-only set (no runner grants)" $?
{ printf '%s\n' "$ROSTER" 2>/dev/null || :; } | grep -qE '^Bash\((npm|go|pytest|cargo|make|just|bash) '
assert "T1-DEC-007 [NEGATIVE CONTROL]: no test-runner grant executes branch code" $([ $? -eq 0 ] && echo 1 || echo 0)

# --- TASK-001 AC4 [NEGATIVE CONTROL]: the naming-axis arm is load-bearing -----
# Extract is_on_review_axis() from the live tests/test-meta.sh and exercise it
# twice: as shipped, and with the `break-it)` arm stripped. A full test-meta.sh
# run takes minutes; this exercises the SAME function the roster scan calls.
echo ""
echo "--- naming axis (ADR-0029) ---"
AXIS_SRC=$(awk '/^is_on_review_axis\(\) \{/,/^\}/' "$META")
[ -n "$AXIS_SRC" ]; assert "T1-AC3: is_on_review_axis() extracted from tests/test-meta.sh" $?
( eval "$AXIS_SRC"; is_on_review_axis break-it ) >/dev/null 2>&1
assert "T1-AC3: the shipped axis ACCEPTS 'break-it'" $?
AXIS_STRIPPED=$(printf '%s\n' "$AXIS_SRC" | grep -v 'break-it) return 0 ;;')
if ( eval "$AXIS_STRIPPED"; is_on_review_axis break-it ) >/dev/null 2>&1; then
  assert "T1-AC4 [NEGATIVE CONTROL]: without the arm the axis REJECTS 'break-it'" 1
else
  assert "T1-AC4 [NEGATIVE CONTROL]: without the arm the axis REJECTS 'break-it'" 0
fi
# Derivation floor: the stripped copy must differ, or the control is vacuous.
[ "$AXIS_SRC" != "$AXIS_STRIPPED" ]; assert "T1-AC4: the strip actually removed a line (control not vacuous)" $?

# --- TASK-002: battery wiring ------------------------------------------------
echo ""
echo "--- /kit:battery wiring ---"
sed -n '/## Lens escalation/,/^## /p' "$BAT" | grep -q 'break-it'
assert "T2-AC1: the escalation table carries a break-it row" $?
grep -q '## Probe rung' "$BAT"; assert "T2-AC2: commands/battery.md has a '## Probe rung' section" $?
PROBE_SEC=$(sed -n '/## Probe rung/,/^## /p' "$BAT")
echo "$PROBE_SEC" | grep -q 'mutation-smoke'; assert "T2-AC2: the probe rung names mutation-smoke as the next rung" $?
echo "$PROBE_SEC" | grep -q '/kit:verify'; assert "T2-AC2: the probe rung names /kit:verify as mutation-smoke's owner" $?
echo "$PROBE_SEC" | grep -qi 'stops the ladder'; assert "T2-AC2: a PROBE finding stops the ladder (DEC-005)" $?
sed -n '/## After the legs return/,$p' "$BAT" | grep -q 'break-it'
assert "T2-AC3: the after-the-legs step tells the lead to decide per probe finding" $?

# --- TASK-003 + TASK-004 AC1 [NEGATIVE CONTROL]: the fixture pair ------------
echo ""
echo "--- fixture pair (both directions) ---"
bash "$FIX/leaky/test.sh" >/dev/null 2>&1
assert "T3-AC1: the leaky suite is GREEN on holed code" $?
bash "$FIX/leaky/probe-check.sh" >/dev/null 2>&1
assert "T3-AC2 [NEGATIVE CONTROL]: the leaky hole is REAL (probe violates the contract)" $?
bash "$FIX/tight/test.sh" >/dev/null 2>&1
assert "T3-AC3: the tight suite is GREEN with the guard in place" $?
# Strip the GUARD-LINE into a temp impl and re-run the tight suite against it.
STRIPPED=$(mktemp)
trap 'rm -f "$STRIPPED"' EXIT
grep -v 'GUARD-LINE' "$FIX/tight/impl.sh" > "$STRIPPED"
[ "$(wc -l < "$STRIPPED")" -lt "$(wc -l < "$FIX/tight/impl.sh")" ]
assert "T3-AC3: the guard strip removed a line (control not vacuous)" $?
if BREAK_IT_IMPL="$STRIPPED" bash "$FIX/tight/test.sh" >/dev/null 2>&1; then
  assert "T3-AC3 [NEGATIVE CONTROL]: without the guard the tight suite goes RED" 1
else
  assert "T3-AC3 [NEGATIVE CONTROL]: without the guard the tight suite goes RED" 0
fi
rm -f "$STRIPPED"
# The tight half must honour the WHOLE contract, not just the two integer
# boundaries. A live break-it dispatch on 2026-09-07 broke the first version with
# `batch_size abc`: the numeric tests exit 2 on non-integer input, the redirect
# hid it, and control fell through to "ok". A fixture that stands for "the suite
# constrains its code" has to survive a real prober, so the shape cases are
# pinned here as well as in the fixture's own suite.
TIGHT_SHAPE=0
for V in abc 3.5 0x5 " " 999999999999999999999; do
  [ "$(bash "$FIX/tight/impl.sh" "$V")" = "reject" ] || TIGHT_SHAPE=1
done
assert "T3-AC3: the tight fixture rejects malformed input, not only 11 (battery finding)" $TIGHT_SHAPE
[ "$(bash "$FIX/leaky/impl.sh" abc)" = "ok" ]
assert "T3-AC1: the leaky fixture still carries its hole (it is the unconstrained half)" $?

# --- TASK-004 AC2/AC3/AC4: STRUCTURAL prompt completeness --------------------
# Every pin below is SECTION-SCOPED: the token must live under the heading that
# owns it. A flat file-wide grep passes on a bag of words (proven by experiment,
# see the header), so scoping is the discrimination. Tokens are pinned, never
# sentences, so a harmless reword does not red the suite.
section() { # section <heading-text> -- print that '## ' section's body
  awk -v h="## $1" 'index($0,h)==1{f=1;next} /^## /{f=0} f' "$A"
}
in_section() { # in_section <heading> <extended-regex>  (case-insensitive)
  section "$1" | grep -qEi "$2"
}

echo ""
echo "--- prompt structure: the sections exist ---"
for H in "Input" "Where you sit in the ladder" "The probe families" \
         "Command safety" "Masking" "Consult the rejected-findings ledger" \
         "Output grammar" "Invariants" "Edge cases" "What you must NOT do" \
         "Return contract"; do
  [ -n "$(section "$H")" ]; assert "T4-AC2: section '## $H...' is present and non-empty" $?
done

echo ""
echo "--- prompt structure: invariants ---"
in_section "Invariants" 'no concrete input'
assert "T4-AC2/inv1: invariant 1 pins the no-concrete-input rule" $?
in_section "Invariants" 'UNVERIFIED'
assert "T4-AC2/inv2: invariant 2 pins the UNVERIFIED alternative" $?
in_section "Invariants" 'NO-PROBE'
assert "T4-AC2/inv3: invariant 3 pins NO-PROBE as a verdict" $?
in_section "Invariants" 'never (edit|write a test)'
assert "T4-AC2/inv4: invariant 4 pins never-edit / never-write-a-test" $?
in_section "Invariants" 'mutation'
assert "T4-AC2/inv4: invariant 4 pins never-run-the-mutation-gate" $?
in_section "Invariants" 'unconstrained-by:'
assert "T4-AC2/inv5: invariant 5 pins the unconstrained-by citation" $?
# The count is DERIVED, never a literal, so adding an invariant does not lie here.
INV_N=$(section "Invariants" | grep -cE '^[0-9]+\. ')
[ "$INV_N" -ge 5 ]; assert "T4-AC2: the Invariants section carries $INV_N numbered invariants (>= 5)" $?

echo ""
echo "--- prompt structure: edge cases ---"
in_section "Edge cases" 'no tests'
assert "T4-AC3/edge1: the no-tests branch is an edge case" $?
in_section "Edge cases" 'docs, config, or prose only'
assert "T4-AC3/edge2: the docs-only branch is an edge case" $?
in_section "Edge cases" 'cannot run|UNVERIFIED'
assert "T4-AC3/edge5: the unrun-suite branch takes the UNVERIFIED path" $?
in_section "Edge cases" 'MUTATION|mutation'
assert "T4-AC3/edge9: the ladder-inversion branch is an edge case" $?
in_section "Consult the rejected-findings ledger" 'rejected-findings\.md'
assert "T4-AC3/edge3: the ledger consult names the ledger file" $?
in_section "Consult the rejected-findings ledger" 'fail-open'
assert "T4-AC3/edge8: the ledger consult is fail-open" $?
in_section "Consult the rejected-findings ledger" 'Previously rejected:'
assert "T4-AC3/edge3: a ledger match gets its own reported line" $?
in_section "Consult the rejected-findings ledger" 'Out of Scope'
assert "T4-AC3/edge3: the spec non-goals are consulted too" $?
# SPEC-247 battery finding: the ledger ships INSIDE the branch under review, so a
# row the diff itself added must never suppress a finding.
in_section "Consult the rejected-findings ledger" 'git diff'
assert "T4-AC3: a ledger row introduced BY the diff is checked for provenance" $?

echo ""
echo "--- prompt structure: safety ---"
in_section "Command safety" 'execute NO code|never run'
assert "T4-AC4: the lens executes no code from the branch under review" $?
in_section "Command safety" 'conftest|pretest|TestMain'
assert "T4-AC4: the reason is named (a runner loads adversary code before test 1)" $?
in_section "Command safety" 'are DATA,'
assert "T4-AC4: the diff and its fixtures are data, not instructions" $?
in_section "Command safety" 'never obeyed'
assert "T4-AC4: an instruction-shaped comment is reported, not obeyed" $?
in_section "Masking" 'first8'
assert "T4-AC4: the masking rule names the hex shape" $?
in_section "Masking" 'first4'
assert "T4-AC4: the masking rule names the vendor-prefixed shape" $?
in_section "Masking" 'ANY output field'
assert "T4-AC4: masking covers every output field, not just probe:/observed:" $?

echo ""
echo "--- prompt structure: output grammar ---"
in_section "Output grammar" 'PROBE:'
assert "T4-AC2: the PROBE finding block is in the grammar" $?
in_section "Output grammar" 'NO-PROBE'
assert "T4-AC2: the NO-PROBE verdict is in the grammar" $?
in_section "Output grammar" 'families-unattempted:'
assert "T4-AC2: a stopped run names the families it never attempted" $?
in_section "Output grammar" 'tried:'
assert "T4-AC2: a cleared family gets a tried: line" $?

# --- TASK-005: docs wiring ---------------------------------------------------
echo ""
echo "--- docs wiring ---"
grep -q '^| `break-it` ' "$KIT_DIR/docs/MANUAL.md"; assert "T5-AC1: docs/MANUAL.md carries a break-it row" $?
grep -q '^| break-it |' "$KIT_DIR/README.md"; assert "T5-AC1: README agents table carries a break-it row" $?
grep -q '`break-it`' "$KIT_DIR/docs/architecture.md"; assert "T5-AC1: docs/architecture.md inventory carries break-it" $?
# AC2: the three rungs appear in WORKFLOW.md's ladder paragraph, in ladder order.
LADDER=$(sed -n '/three-rung ladder/,/^$/p' "$WF" | tr '\n' ' ')
[ -n "$LADDER" ]; assert "T5-AC2: docs/WORKFLOW.md has a three-rung ladder paragraph" $?
echo "$LADDER" | grep -q 'coverage.*probe.*mutation'
assert "T5-AC2: the ladder names coverage, then probe, then mutation, in order" $?
echo "$LADDER" | grep -qi 'stated, not enforced'
assert "T5-AC2: the ladder states the order is not enforced (open question 1)" $?

# --- TASK-004 AC5 [closing move]: the effectiveness gate ---------------------
# test-advisor.sh's closing move: the last assertion is the SG-01 gate on the
# new agent. Honest scope, established by experiment on 2026-09-07: SG-01 checks
# read-only tools, model tier, and the retired-suffix name, all three of which the
# assertions above already cover, so this call adds no discrimination of its own.
# It stays as the shape-conformance backstop shared with every other agent, and
# the structural section pins above are what actually catch a gutted prompt.
echo ""
echo "--- SG-01 effectiveness gate ---"
if bash "$KIT_DIR/tests/test-agent-effectiveness.sh" "$A" >/dev/null 2>&1; then
  assert "T4-AC5: break-it passes the SG-01 agent-effectiveness gate" 0
else
  assert "T4-AC5: break-it passes the SG-01 agent-effectiveness gate" 1
fi

echo ""
echo "=== $PASS/$TOTAL passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
