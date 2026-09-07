#!/usr/bin/env bash
# test-advisor-ledger-emit.sh -- SPEC-145, gate-review-absorptions sub-goal 06.
#
# The advisor (ADR-0028 P5/P6) is reachable via /kit:review-team Step 2b and the mega.md
# convergence-gate step, but neither previously left a first-class `| GATE | advisor |` row --
# a 2026-07-04 audit found zero such rows across 96 rid logs even on runs whose free-text
# ACTION line described an advisor pass. This is a grep-based regression pin (mirrors
# tests/test-advisor.sh's style, no external dependency) so a future edit cannot silently drop
# the emit, its fail-open fallback, or the rid-convention statement from either dispatch site.
# The actual ledger-observatory kit_gates parse (proving the new phase value needs zero reader
# code change) is captured as a terminal-output artifact in
# docs/verification/advisor-visibility.md, not re-run here -- that tool lives in a sibling repo
# (ops-toolkit) not available in this repo's CI.
#
#   AC1  review-team.md Step 2b contains the advisor emit, with the exact mode=P5/findings=/
#        actor= grammar, and it is fail-open (a `||` fallback with a warning, never a bare call)
#   AC2  review-team.md states the rid convention (final sub-goal's rid in a mega context)
#   AC3  mega.md contains an explicit convergence-gate paragraph naming BOTH advisor modes
#        (P5 critique + P6 over-suggest), each with its own fail-open emit
#   AC4  mega.md's convergence-gate step is observability-only (no gate-requirement language)
#   AC5  agents/advisor.md documents the emit contract (grammar + fail-open + honest-zero)
#   AC6  NEGATIVE CONTROL: a fixture snippet with a BARE (non-fail-open) gate-ledger call is
#        correctly flagged by the same fail-open check this file applies to the real files,
#        proving the check catches the bug class, not just that the real repo happens to pass
#   AC7  the two committed fixture ledger logs exist and parse as plain GATE-line text (rid,
#        gate, outcome, reason all present) -- the offline half of the kit_gates proof
#   AC8  the WRITE side is actually exercised: `bash lib/gate/gate-ledger.sh record ... advisor ran
#        "mode=..."` (the real, unmodified verb, not just prose describing it) genuinely
#        produces the exact `| GATE | advisor | ran | mode=... |` line shape the two dispatch
#        sites depend on -- AC7 only proves hand-authored fixtures LOOK right; this proves the
#        live script agrees (test-coverage lens finding, SPEC-145 review)
#
# Run: bash tests/test-advisor-ledger-emit.sh   (exit 0 = all AC green)

set -uo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RT="$KIT_DIR/commands/review-team.md"
MEGA="$KIT_DIR/commands/mega.md"
ADV="$KIT_DIR/agents/advisor.md"
FIX_DIR="$KIT_DIR/tests/fixtures/advisor-ledger-emit/runs"

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert() { TOTAL=$((TOTAL+1)); if [ "$2" -eq 0 ]; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1)); else echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL+1)); fi; }

# fail_open_call <file>: 0 iff EVERY `gate-ledger.sh record ... advisor ran "mode=...` call
# site in the file is immediately followed (within the next 2 lines) by an `||` fallback that
# echoes a WARNING -- i.e. no call site is ever bare. Checks each match independently (no
# sticky state across matches), so a file with N call sites where only 1 lost its fallback
# still fails -- the exact regression a single global found/ok flag would hide (test-coverage
# lens finding, SPEC-145 review). Returns nonzero if zero call sites are found at all.
fail_open_call() {
  local f="$1" total=0 bad=0
  local lines; lines="$(grep -n 'gate-ledger\.sh record.*advisor ran.*mode=' "$f" | cut -d: -f1)"
  [ -n "$lines" ] || return 1
  local n
  while IFS= read -r n; do
    total=$((total + 1))
    # the fallback lives on this line or either of the next 2 (covers a `\`-continued
    # multi-line command whose `|| echo ... WARNING` sits one or two lines down)
    if ! sed -n "${n},$((n + 2))p" "$f" | grep -q '||' || ! sed -n "${n},$((n + 2))p" "$f" | grep -q 'WARNING'; then
      bad=$((bad + 1))
    fi
  done <<< "$lines"
  [ "$total" -gt 0 ] && [ "$bad" -eq 0 ]
}

echo "=== advisor-ledger-emit (SPEC-145 AC1-AC7) ==="

# AC1: review-team.md carries the emit, grammar, and is fail-open
grep -qE 'gate-ledger\.sh record "\$rid" advisor ran' "$RT"; assert "AC1: review-team.md Step 2b emits 'advisor ran'" $?
grep -qE 'mode=P5 findings=<N> actor=' "$RT"; assert "AC1: review-team.md emit uses the mode=P5 findings=<N> actor= grammar" $?
fail_open_call "$RT"; assert "AC1: review-team.md's advisor emit is fail-open (|| WARNING fallback)" $?

# AC2: rid convention documented
grep -qiE 'RID convention' "$RT"; assert "AC2: review-team.md states an RID convention" $?
grep -qiE 'FINAL sub-goal' "$RT"; assert "AC2: review-team.md names the final-sub-goal's-rid convention for mega context" $?

# AC3: mega.md convergence-gate paragraph, both modes, fail-open
# tr collapses hard-wrapped prose to one line first -- markdown prose line-wraps at any point
# mid-phrase, so a single-line grep on a multi-word phrase is fragile; normalize, then match.
MEGA_FLAT="$(tr '\n' ' ' < "$MEGA")"
grep -qiE 'convergence gate dispatches advisor' "$MEGA"; assert "AC3: mega.md names an explicit convergence-gate advisor dispatch" $?
{ printf '%s' "$MEGA_FLAT" 2>/dev/null || :; } | grep -qE 'P5[[:space:]]*\(critique\)'; assert "AC3: mega.md names P5 critique explicitly" $?
{ printf '%s' "$MEGA_FLAT" 2>/dev/null || :; } | grep -qE 'P6[[:space:]]*\(over-suggest\)'; assert "AC3: mega.md names P6 over-suggest explicitly" $?
grep -qE 'mode=P5 findings=<N> actor=' "$MEGA" && grep -qE 'mode=P6 findings=<N> actor=' "$MEGA"
assert "AC3: mega.md emits BOTH mode=P5 and mode=P6 rows" $?
fail_open_call "$MEGA"; assert "AC3: mega.md's advisor emit is fail-open (|| WARNING fallback)" $?

# AC4: observability-only, no gate-requirement language
grep -qiE 'observability only' "$MEGA"; assert "AC4: mega.md's convergence-gate step states observability-only" $?
if awk '/convergence gate dispatches advisor/{f=1} f&&/^\*\*Close the run visibly/{exit} f' "$MEGA" | grep -qiE 'measure-twice|required gate'; then
  assert "AC4: convergence-gate paragraph adds NO new required-gate language" 1
else
  assert "AC4: convergence-gate paragraph adds NO new required-gate language" 0
fi

# AC5: agents/advisor.md documents the contract
grep -qiE '## Ledger visibility' "$ADV"; assert "AC5: agents/advisor.md has a Ledger visibility section" $?
grep -qE 'mode=<P5\|P6> findings=<N> actor=' "$ADV"; assert "AC5: advisor.md names the exact emit grammar" $?
grep -qiE 'honest-zero|NC1' "$ADV"; assert "AC5: advisor.md states the honest-zero contract (NC1)" $?
grep -qiE 'FAIL-OPEN|NC2' "$ADV"; assert "AC5: advisor.md states the fail-open contract (NC2)" $?
grep -qiE 'FINAL sub-goal' "$ADV"; assert "AC5: advisor.md pins the final-sub-goal's-rid convention (its own claimed canonical home)" $?

# AC6: negative control -- the fail_open_call check itself catches a bare (non-fail-open) call
BAD_FIXTURE="$(mktemp "${TMPDIR:-/tmp}/dwarves-kit-advisor-bad.XXXXXX.md")"
trap 'rm -f "$BAD_FIXTURE"' EXIT
cat > "$BAD_FIXTURE" <<'EOF'
bash lib/gate/gate-ledger.sh record "$rid" advisor ran "mode=P5 findings=<N> actor=$(git config user.name)"
EOF
if fail_open_call "$BAD_FIXTURE"; then
  assert "AC6 NEGATIVE CONTROL: a bare (non-fail-open) advisor emit IS flagged" 1
else
  assert "AC6 NEGATIVE CONTROL: a bare (non-fail-open) advisor emit IS flagged" 0
fi

# AC7: the committed fixture ledger logs exist and are well-formed GATE-line text
[ -f "$FIX_DIR/advisor-visibility-fixture.log" ]; assert "AC7: fixture-with-advisor log exists" $?
[ -f "$FIX_DIR/no-advisor-fixture.log" ]; assert "AC7: fixture-without-advisor log exists" $?
grep -qE '\| GATE \| advisor \| ran \| mode=P5 findings=[0-9]+ actor=' "$FIX_DIR/advisor-visibility-fixture.log" 2>/dev/null
assert "AC7: fixture-with-advisor log has a well-formed mode=P5 GATE line" $?
grep -qE '\| GATE \| advisor \| ran \| mode=P6 findings=[0-9]+ actor=' "$FIX_DIR/advisor-visibility-fixture.log" 2>/dev/null
assert "AC7: fixture-with-advisor log has a well-formed mode=P6 GATE line" $?
if grep -q '| GATE | advisor |' "$FIX_DIR/no-advisor-fixture.log" 2>/dev/null; then
  assert "AC7: fixture-without-advisor log genuinely has NO advisor GATE line (the NC1 fixture)" 1
else
  assert "AC7: fixture-without-advisor log genuinely has NO advisor GATE line (the NC1 fixture)" 0
fi
grep -qE '\| GATE \| (build|review) \| ran \|' "$FIX_DIR/no-advisor-fixture.log" 2>/dev/null
assert "AC7: fixture-without-advisor log DID run other gates (it ran, just never dispatched advisor)" $?

# AC8: the WRITE side -- actually invoke the real, unmodified lib/gate/gate-ledger.sh record verb
# (not a hand-authored fixture) and confirm it produces the exact GATE-line shape the two
# dispatch sites depend on. AC7 alone only proves the fixtures LOOK right; this proves the
# live script agrees (test-coverage lens finding, SPEC-145 review).
AC8_LOGDIR="$(mktemp -d "${TMPDIR:-/tmp}/dwarves-kit-advisor-ac8.XXXXXX")"
trap 'rm -f "$BAD_FIXTURE"; rm -rf "$AC8_LOGDIR"' EXIT
AC8_RID="ac8-live-write-fixture"
if DWARVES_KIT_LOG_DIR="$AC8_LOGDIR" bash "$KIT_DIR/lib/gate/gate-ledger.sh" record "$AC8_RID" advisor ran "mode=P5 findings=2 actor=Test Actor" >/dev/null 2>&1; then
  assert "AC8: 'lib/gate/gate-ledger.sh record ... advisor ran' exits 0 for real" 0
else
  assert "AC8: 'lib/gate/gate-ledger.sh record ... advisor ran' exits 0 for real" 1
fi
AC8_LOG="$AC8_LOGDIR/runs/$AC8_RID.log"
[ -f "$AC8_LOG" ]; assert "AC8: the live record() call actually wrote a run-ledger file" $?
grep -qE '\| GATE \| advisor \| ran \| mode=P5 findings=2 actor=Test Actor' "$AC8_LOG" 2>/dev/null
assert "AC8: the live-written line matches the exact grammar the dispatch sites depend on" $?

echo ""
echo "=== $PASS/$TOTAL passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
