#!/usr/bin/env bash
# test-quiz-gate.sh -- SPEC-125, understanding-gate SG-04.
# Proves the ★-tap NUDGE (ADR-0031 §2/§3): a 5-question quiz built from the ACTUAL diff+tests,
# wired at the merge boundary keyed on the SPEC-123 verdict, three logged responses, routed to
# deep-understand, and NEVER must-pass.
#   AC1  a high×high change generates exactly 5 quiz questions FROM the actual diff + test results
#   AC2  the three responses (engage/defer/wave) each land in the debt ledger
#   AC3  engage routes through deep-understand's mastery-gate engine (dispatch, not a reimplementation)
#   AC4  GROUNDED NC: a narrative that contradicts the diff -> the quiz is built from the DIFF
#   AC5  WIRING NC: the tap FIRES on `tap`, is ABSENT on `wave` AND on `not-significant` (+ non-gate)
#   AC6  NEVER must-pass: a waved change still merges (no verb blocks; every advisory path exits 0)
#
# Run: bash tests/test-quiz-gate.sh   (exit 0 = all AC green)
set -uo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
QG="$KIT_DIR/lib/gate/quiz-gate.sh"
GL="$KIT_DIR/lib/gate/gate-ledger.sh"

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert() { TOTAL=$((TOTAL+1)); if [ "$2" -eq 0 ] 2>/dev/null; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1)); else echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL+1)); fi; }

gitq() { git -C "$1" "${@:2}"; }
mkrepo() { local d="$1"; mkdir -p "$d"; git init -q -b master "$d"; gitq "$d" config user.email t@t; gitq "$d" config user.name t; }

LOGDIR="$(mktemp -d)"
trap 'rm -rf "$LOGDIR"' EXIT
export DWARVES_KIT_LOG_DIR="$LOGDIR"

# ---------------------------------------------------------------------------
# Fixture A: a multi-rank change (background doc + new file + modified file + test) with a recorded
# proof under docs/verification/, so `questions` has real files, real added lines, and a real verdict.
# ---------------------------------------------------------------------------
DA="$(mktemp -d)"; mkrepo "$DA"
printf 'let a = 1;\n' > "$DA/alpha.js"
gitq "$DA" add -A; gitq "$DA" commit -qm "init base"
mkdir -p "$DA/docs/verification/widget" "$DA/tests"
printf '# Guide\nBackground for the reader.\n'        > "$DA/docs/guide.md"          # rank 0
printf 'function widget(){ return 42; }\n'            > "$DA/widget.js"              # rank 1 new
printf 'let a = 1;\nlet a2 = widget(); // wired in\n' > "$DA/alpha.js"              # rank 2 integration
printf 'echo widget test\n'                            > "$DA/tests/test-widget.sh"  # rank 3
printf '| AC1 | widget returns 42 | PASS |\nExit: 0\n' > "$DA/docs/verification/widget/proof-of-done.md"
# name the spec slug so explain.sh tests can locate the proof dir
mkdir -p "$DA/docs/specs"; printf '# SPEC-widget\n' > "$DA/docs/specs/SPEC-900-widget.md"
gitq "$DA" add -A; gitq "$DA" commit -qm "wire widget helper into alpha"
REFA="$(gitq "$DA" rev-parse HEAD)"

echo "=== AC1: exactly 5 diff-grounded quiz questions ==="
QOUT="$( cd "$DA" && bash "$QG" questions "$REFA" )"
NQ=$(printf '%s\n' "$QOUT" | grep -c '^Q[1-5]\.')
assert "AC1 exactly 5 questions (Q1..Q5), got $NQ" "$([ "$NQ" -eq 5 ] && echo 0 || echo 1)"
# ...and each of Q1..Q5 appears exactly once (a duplicated label + a dropped one would still count 5)
EACH_ONCE=0; for n in 1 2 3 4 5; do
  [ "$(printf '%s\n' "$QOUT" | grep -c "^Q$n\.")" -eq 1 ] || EACH_ONCE=1
done
assert "AC1 each of Q1..Q5 appears exactly once (no dup/drop)" "$EACH_ONCE"
# grounded: a question names a real changed file
assert "AC1 questions reference a real changed file (widget.js)" \
  "$({ trap '' PIPE; printf '%s' "$QOUT" 2>/dev/null || :; } | grep -q 'widget.js' && echo 0 || echo 1)"
# grounded in ADDED LINES, not the commit message: the added identifier `widget` appears
assert "AC1 questions quote the actual added code (names 'widget')" \
  "$({ trap '' PIPE; printf '%s' "$QOUT" 2>/dev/null || :; } | grep -q 'function widget' && echo 0 || echo 1)"
# grounded in the RECORDED test verdict (not invented)
assert "AC1 questions carry the recorded test verdict (PASS from the proof)" \
  "$({ trap '' PIPE; printf '%s' "$QOUT" 2>/dev/null || :; } | grep -qi 'PASS\|Exit: 0' && echo 0 || echo 1)"

echo "=== AC2: three responses each land in the debt ledger ==="
RID="ac2-rid-$$"
bash "$QG" respond "$RID" engage --ref "$REFA" >/dev/null 2>&1
bash "$QG" respond "$RID" defer  >/dev/null 2>&1
bash "$QG" respond "$RID" wave   >/dev/null 2>&1
LF="$LOGDIR/runs/$(printf '%s' "$RID" | tr '/ ' '--').log"
NRESP=$( [ -f "$LF" ] && grep -c '| DEBT | response=' "$LF" || echo 0 )
assert "AC2 three | DEBT | response= lines written, got $NRESP" "$([ "$NRESP" -eq 3 ] && echo 0 || echo 1)"
assert "AC2 engage logged"  "$(grep -q '| DEBT | response=engage' "$LF" && echo 0 || echo 1)"
assert "AC2 defer logged"   "$(grep -q '| DEBT | response=defer'  "$LF" && echo 0 || echo 1)"
assert "AC2 wave logged"    "$(grep -q '| DEBT | response=wave'   "$LF" && echo 0 || echo 1)"
# BEHAVIORAL additive-marker guard: a ledger of ONLY debt-response lines must NOT satisfy any required
# gate. Run the real gate-ledger check() against a lane with required gates; it must still report the
# gates MISSING (the DEBT lines did not fake a `| GATE | ran`). This exercises check()'s reader, not the
# writer's format -- a regression widening check()'s awk predicate to match DEBT would fail HERE.
CHK="$( bash "$GL" check full "$RID" 2>&1 )"; CHK_RC=$?
assert "AC2 a DEBT-only ledger fails gate check (response lines never satisfy a required gate)" \
  "$([ "$CHK_RC" -ne 0 ] && { trap '' PIPE; printf '%s' "$CHK" 2>/dev/null || :; } | grep -q 'MISSING-GATE' && echo 0 || echo 1)"

echo "=== AC3: engage routes through deep-understand (dispatch, not reimplementation) ==="
ROUT="$( cd "$DA" && bash "$QG" respond "engage-rid-$$" engage --ref "$REFA" )"
assert "AC3 engage output names the deep-understand engine" \
  "$({ trap '' PIPE; printf '%s' "$ROUT" 2>/dev/null || :; } | grep -q 'deep-understand' && echo 0 || echo 1)"
assert "AC3 engage output names the AskUserQuestion mastery gate" \
  "$({ trap '' PIPE; printf '%s' "$ROUT" 2>/dev/null || :; } | grep -qi 'AskUserQuestion' && echo 0 || echo 1)"
# defer / wave do NOT route to deep-understand (only engage does)
DWAVE="$( bash "$QG" respond "wave-rid-$$" wave )"
assert "AC3 wave does NOT route to deep-understand" \
  "$({ trap '' PIPE; printf '%s' "$DWAVE" 2>/dev/null || :; } | grep -q 'deep-understand' && echo 1 || echo 0)"
# the kit does NOT reimplement a quiz scorer: quiz-gate.sh has no answer-key / grading logic
assert "AC3 quiz-gate.sh reimplements no scorer (no answer-key/grade/score logic)" \
  "$(grep -qiE 'answer[_ -]?key|def .*score|grade_quiz|correct_answer|is_correct' "$QG" && echo 1 || echo 0)"
# the command surface names the routing target too (live dispatch path)
assert "AC3 commands/quiz-gate.md names deep-understand (live dispatch path)" \
  "$(grep -q 'deep-understand' "$KIT_DIR/commands/quiz-gate.md" && echo 0 || echo 1)"

echo "=== AC4: GROUNDED negative control (narrative differs from the diff) ==="
# Fixture B: the diff adds `subtract`; the commit BODY and an untracked file claim `multiply`. `questions`
# takes the ref ONLY -- there is no narrative channel -- so the quiz must name `subtract`, never `multiply`.
DB="$(mktemp -d)"; mkrepo "$DB"
printf '// calc\n' > "$DB/calc.js"; gitq "$DB" add -A; gitq "$DB" commit -qm "init calc"
printf '// calc\nfunction subtract(a, b) { return a - b; }\n' > "$DB/calc.js"      # DIFF truth: subtract
printf 'This change adds a multiply function.\n' > "$DB/AGENT_NARRATIVE.txt"       # untracked lie
gitq "$DB" add calc.js
gitq "$DB" commit -qm "update calc helper" -m "Adds a multiply operation as requested."   # body lies
REFB="$(gitq "$DB" rev-parse HEAD)"
QB="$( cd "$DB" && bash "$QG" questions "$REFB" )"
assert "AC4 quiz describes the DIFF (names 'subtract')" \
  "$({ trap '' PIPE; printf '%s' "$QB" 2>/dev/null || :; } | grep -q 'subtract' && echo 0 || echo 1)"
assert "AC4 quiz does NOT parrot the false narrative ('multiply')" \
  "$({ trap '' PIPE; printf '%s' "$QB" 2>/dev/null || :; } | grep -qi 'multiply' && echo 1 || echo 0)"
# MINOR-4: Fixture B has a code change but NO recorded proof -> Q4 must fall back to the honest
# "[no recorded test result]" string, never an invented verdict (the honesty guarantee).
assert "AC4 no recorded proof -> Q4 says '[no recorded test result]' (does not invent a verdict)" \
  "$({ trap '' PIPE; printf '%s' "$QB" 2>/dev/null || :; } | grep -q '\[no recorded test result' && echo 0 || echo 1)"

echo "=== Edges: docs/tests-only change + a range ref ==="
# MAJOR-2: a change touching ONLY docs/ + tests/ has no primary code file -> Q3 fires the
# "touches only docs/tests" branch (not a doc mis-labeled as the primary code file).
DD="$(mktemp -d)"; mkrepo "$DD"
printf 'seed\n' > "$DD/seed.txt"; gitq "$DD" add -A; gitq "$DD" commit -qm "seed"
mkdir -p "$DD/docs" "$DD/tests"
printf '# Doc\nnew doc line\n'   > "$DD/docs/note.md"
printf 'echo doc-only test\n'    > "$DD/tests/test-note.sh"
gitq "$DD" add -A; gitq "$DD" commit -qm "docs and tests only"
REFD="$(gitq "$DD" rev-parse HEAD)"
QD="$( cd "$DD" && bash "$QG" questions "$REFD" )"
assert "Edge docs/tests-only: still exactly 5 questions" \
  "$([ "$(printf '%s\n' "$QD" | grep -c '^Q[1-5]\.')" -eq 5 ] && echo 0 || echo 1)"
assert "Edge docs/tests-only: Q3 fires the 'touches only docs/tests' branch (no mis-labeled primary)" \
  "$({ trap '' PIPE; printf '%s' "$QD" 2>/dev/null || :; } | grep -qi 'only docs/tests' && echo 0 || echo 1)"

# MINOR-3: a range ref (A..B) is the code's other resolve branch; assert it grounds the same as a SHA.
BASEA="$(gitq "$DA" rev-parse "${REFA}^1")"
QRANGE="$( cd "$DA" && bash "$QG" questions "${BASEA}..${REFA}" )"
assert "Edge range ref (A..B): 5 questions, still names the real changed file (widget.js)" \
  "$([ "$(printf '%s\n' "$QRANGE" | grep -c '^Q[1-5]\.')" -eq 5 ] && { trap '' PIPE; printf '%s' "$QRANGE" 2>/dev/null || :; } | grep -q 'widget.js' && echo 0 || echo 1)"

echo "=== AC5: WIRING negative control (fires on tap, absent on wave / not-significant / non-gate) ==="
TAP_DESC="add a new data model migration that introduces a primitive future work will build on"    # -> tap
WAVE_DESC="add a mechanical, reversible, fully test-covered guard clause with two viable approaches" # -> wave
NS_DESC="fix a typo in the README"                                                                   # -> not-significant
T_TAP="$( bash "$QG" tap wr-tap  --files "lib/x.sh" "$TAP_DESC" )"
T_WAVE="$( bash "$QG" tap wr-wave --files "lib/queue/orchestrate.sh lib/foo.sh" "$WAVE_DESC" )"
T_NS="$(   bash "$QG" tap wr-ns   "$NS_DESC" )"
T_NONGATE="$( bash "$QG" tap wr-ng --pr-kind normal --files "lib/x.sh" "$TAP_DESC" )"
# sanity: the classifier actually produces the three verdicts we rely on
V_TAP="$(  bash "$KIT_DIR/lib/classify/significance-classify.sh" classify --files "lib/x.sh" "$TAP_DESC" )"
V_WAVE="$( bash "$KIT_DIR/lib/classify/significance-classify.sh" classify --files "lib/queue/orchestrate.sh lib/foo.sh" "$WAVE_DESC" )"
V_NS="$(   bash "$KIT_DIR/lib/classify/significance-classify.sh" classify "$NS_DESC" )"
assert "AC5 classifier sanity: tap/$V_TAP wave/$V_WAVE ns/$V_NS" \
  "$([ "$V_TAP" = tap ] && [ "$V_WAVE" = wave ] && [ "$V_NS" = not-significant ] && echo 0 || echo 1)"
assert "AC5 tap FIRES on a tap-verdict gate PR (nudge printed)" \
  "$({ trap '' PIPE; printf '%s' "$T_TAP" 2>/dev/null || :; } | grep -q '★ worth understanding' && echo 0 || echo 1)"
assert "AC5 tap ABSENT on a wave-verdict change (anti-fatigue)" \
  "$([ -z "$T_WAVE" ] && echo 0 || echo 1)"
assert "AC5 tap ABSENT on a not-significant change" \
  "$([ -z "$T_NS" ] && echo 0 || echo 1)"
assert "AC5 tap ABSENT on a non-gate PR even when the verdict is tap" \
  "$([ -z "$T_NONGATE" ] && echo 0 || echo 1)"

echo "=== AC6: NEVER must-pass (a waved change still merges; nothing blocks) ==="
bash "$QG" respond "ac6-rid-$$" wave >/dev/null 2>&1; RC_WAVE=$?
assert "AC6 respond wave exits 0 (advisory, not a block)" "$RC_WAVE"
bash "$QG" tap "ac6-tap-$$" --files "lib/x.sh" "$TAP_DESC" >/dev/null 2>&1; RC_TAP=$?
assert "AC6 tap exits 0 (never blocks the merge)" "$RC_TAP"
# no hook blocks a merge/push on the quiz: quiz-gate is referenced by NO hook as a gate
HOOK_BLOCK=$(grep -rl 'quiz-gate' "$KIT_DIR/hooks/" 2>/dev/null | wc -l | tr -d ' ')
assert "AC6 no hook blocks merge on the quiz (0 hook refs to quiz-gate, got $HOOK_BLOCK)" \
  "$([ "$HOOK_BLOCK" -eq 0 ] && echo 0 || echo 1)"

# ---------------------------------------------------------------------------
# Capture the fixture-A quiz as the proof artifact.
# ---------------------------------------------------------------------------
PROOF_DIR="$KIT_DIR/docs/verification/quiz-gate"
mkdir -p "$PROOF_DIR"
{ printf '# Sample quiz (fixture A, ref %s)\n\n' "$REFA"; printf '%s\n' "$QOUT"; } > "$PROOF_DIR/sample-quiz.md"

echo ""
echo "  ---------------------------------------------"
echo "  TOTAL: $TOTAL   PASS: $PASS   FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
