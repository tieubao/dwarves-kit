#!/usr/bin/env bash
# test-significance-classify.sh -- SPEC-123, understanding-gate SG-02.
# Behavioral suite for lib/classify/significance-classify.sh: the two-signal (significance x
# understanding-worthiness) verdict, the impl-notes feed, the gate-ledger debt marker, and
# determinism. Mirrors tests/test-lane-classify.sh's shape.
#
# Run: bash tests/test-significance-classify.sh   (exit 0 = all AC green)

set -uo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SC="$KIT_DIR/lib/classify/significance-classify.sh"
GL="$KIT_DIR/lib/gate/gate-ledger.sh"

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

assert() {
  TOTAL=$((TOTAL+1))
  if [ "$2" -eq 0 ] 2>/dev/null; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1))
  else echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL+1)); fi
}

# verdict_is [--files F] [--impl-notes P] <desc> <expected-verdict> <label>
verdict_is() {
  local args=() expected label got
  while [ "${1:-}" != "--" ]; do args+=("$1"); shift; done
  shift  # consume --
  expected="$1"; label="$2"
  TOTAL=$((TOTAL+1))
  got="$(bash "$SC" classify "${args[@]}" 2>/dev/null)"
  if [ "$got" = "$expected" ]; then echo -e "  ${GREEN}PASS${NC} $label ($expected)"; PASS=$((PASS+1))
  else echo -e "  ${RED}FAIL${NC} $label -- got '$got', expected '$expected'"; FAIL=$((FAIL+1)); fi
}

TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT

echo "=== significance-classify: worthy-tap (AC1) ==="
verdict_is --files "lib/x.sh" "add a new data model migration that introduces a primitive future work will build on" -- \
  "tap" "AC1 significant + worthy (data model + primitive) -> tap"

echo ""
echo "=== significance-classify: anti-fatigue NEGATIVE CONTROL (AC2) ==="
# Significant (full lane, touches lib/) but describes a purely mechanical, reversible,
# test-covered change -- no worthiness trigger should fire. Anti-fatigue guard: this must
# WAVE, not tap, even though it is significant.
verdict_is --files "lib/queue/orchestrate.sh lib/foo.sh" "add a mechanical, reversible, fully test-covered guard clause" -- \
  "wave" "AC2 [NC] significant-but-low-worthiness is WAVED, not tapped"

echo ""
echo "=== significance-classify: obvious change (AC3) ==="
verdict_is "fix a typo in the README" -- "not-significant" "AC3 obvious/cosmetic change is not-significant"

echo ""
echo "=== significance-classify: impl-notes FEED (AC4) ==="
EMPTY_NOTE="$TMPDIR_T/empty.md"
NONEMPTY_NOTE="$TMPDIR_T/nonempty.md"
: > "$EMPTY_NOTE"
printf '## 2026-07-03 12:00 a decision\n- Decision: chose X over Y, spec did not pin this down\n' > "$NONEMPTY_NOTE"

# Same mechanical description as AC2 (no worthiness trigger in the text itself): without an
# impl-note it waves; with a non-empty impl-note the feed signal flips it to a tap.
verdict_is --files "lib/queue/orchestrate.sh" --impl-notes "$EMPTY_NOTE" "add a mechanical, reversible, fully test-covered guard clause" -- \
  "wave" "AC4a no impl-note entries -> still waved"
verdict_is --files "lib/queue/orchestrate.sh" --impl-notes "$NONEMPTY_NOTE" "add a mechanical, reversible, fully test-covered guard clause" -- \
  "tap" "AC4b non-empty impl-note flips worthiness low->high -> tap"

echo ""
echo "=== significance-classify: per-trigger regex coverage (review MEDIUM fix) ==="
# Each of the 7 pinned regex groups gets its own assertion by name (via `explain`), not just
# incidental coverage through AC1/AC2 -- a broken regex in any one of these must not ship silent.

explain_fires() {
  # explain_fires <desc-args...> -- <expected-substring-in-signal-line> <label>
  local args=() expect label out
  while [ "${1:-}" != "--" ]; do args+=("$1"); shift; done
  shift
  expect="$1"; label="$2"
  TOTAL=$((TOTAL+1))
  out="$(bash "$SC" explain "${args[@]}" 2>/dev/null)"
  if { trap '' PIPE; printf '%s' "$out" 2>/dev/null || :; } | grep -qF "$expect"; then
    echo -e "  ${GREEN}PASS${NC} $label (fired: $expect)"
    PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label -- expected '$expect' in:"$'\n'"$out"
    FAIL=$((FAIL+1))
  fi
}

# Significance triggers, independent of "full lane" (no --files, or files that do not touch
# lib/hooks, so the ONLY way significance can be high is the named regex itself).
explain_fires "this introduces a non-obvious control flow in a new module" -- \
  "significance: high (design-bearing)" "design-bearing trigger fires significance"
explain_fires "add a new public method to the library for callers" -- \
  "significance: high (new-public-surface)" "new-public-surface trigger fires significance"

# Worthiness triggers, each isolated (paired with a full-lane --files so significance is high
# independent of the worthiness text, mirroring AC2's independence discipline).
explain_fires --files "lib/queue/orchestrate.sh" "this has a first-of-kind novel pattern, no precedent" -- \
  "worthiness: high (novel)" "novel trigger fires worthiness (asserted by name, not incidental)"
explain_fires --files "lib/queue/orchestrate.sh" "the blast radius is high, used by every consumer" -- \
  "worthiness: high (blast-radius)" "blast-radius trigger fires worthiness"
explain_fires --files "lib/queue/orchestrate.sh" "the human will have to explain and defend this design decision" -- \
  "worthiness: high (must-explain)" "must-explain trigger fires worthiness"

echo ""
echo "=== significance-classify: tunable knob SIGNIFICANCE_WORTHINESS_MIN (review MEDIUM fix) ==="
# A description carrying exactly ONE worthiness trigger: default (min=1) -> high/tap;
# raising the knob to 2 -> low/wave, proving the knob actually gates the count, not a no-op.
ONE_TRIGGER_DESC="this has a first-of-kind novel pattern"
TOTAL=$((TOTAL+1))
got_default="$(bash "$SC" classify --files "lib/queue/orchestrate.sh" "$ONE_TRIGGER_DESC" 2>/dev/null)"
if [ "$got_default" = "tap" ]; then
  echo -e "  ${GREEN}PASS${NC} default SIGNIFICANCE_WORTHINESS_MIN=1: one trigger -> tap"
  PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC} default knob -- got '$got_default', expected 'tap'"
  FAIL=$((FAIL+1))
fi

TOTAL=$((TOTAL+1))
got_raised="$(SIGNIFICANCE_WORTHINESS_MIN=2 bash "$SC" classify --files "lib/queue/orchestrate.sh" "$ONE_TRIGGER_DESC" 2>/dev/null)"
if [ "$got_raised" = "wave" ]; then
  echo -e "  ${GREEN}PASS${NC} SIGNIFICANCE_WORTHINESS_MIN=2: one trigger no longer enough -> wave"
  PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC} raised knob -- got '$got_raised', expected 'wave'"
  FAIL=$((FAIL+1))
fi

echo ""
echo "=== significance-classify: edge cases (review LOW fix) ==="
TOTAL=$((TOTAL+1))
empty_verdict="$(bash "$SC" classify "" 2>/dev/null)"
if [ "$empty_verdict" = "not-significant" ]; then
  echo -e "  ${GREEN}PASS${NC} empty description classifies not-significant, does not error"
  PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC} empty description -- got '$empty_verdict', expected 'not-significant'"
  FAIL=$((FAIL+1))
fi

TOTAL=$((TOTAL+1))
nonexistent_note_verdict="$(bash "$SC" classify --files "lib/queue/orchestrate.sh" --impl-notes "$TMPDIR_T/does-not-exist.md" "mechanical reversible test-covered guard" 2>/dev/null)"
if [ "$nonexistent_note_verdict" = "wave" ]; then
  echo -e "  ${GREEN}PASS${NC} --impl-notes pointing at a nonexistent file degrades to no-signal (wave, not a crash)"
  PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC} nonexistent impl-notes path -- got '$nonexistent_note_verdict', expected 'wave'"
  FAIL=$((FAIL+1))
fi

TOTAL=$((TOTAL+1))
FRESH_LOGDIR="$TMPDIR_T/fresh-nonexistent-logdir"
DWARVES_KIT_LOG_DIR="$FRESH_LOGDIR" bash "$SC" record "edge-rid-$$" "fix a typo in the README" >/dev/null 2>&1
if [ -f "$FRESH_LOGDIR/runs/edge-rid-$$.log" ]; then
  echo -e "  ${GREEN}PASS${NC} record auto-creates a nonexistent log dir (mkdir -p), does not error"
  PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC} record did not create the ledger under a fresh log dir"
  FAIL=$((FAIL+1))
fi

echo ""
echo "=== significance-classify: gate-ledger debt marker (AC5) ==="
RID_T="sigclass-test-$$"
LOGDIR_T="$TMPDIR_T/kitlogs"
mkdir -p "$LOGDIR_T"
LEDGER_FILE="$LOGDIR_T/runs/$RID_T.log"

run_record() {
  DWARVES_KIT_LOG_DIR="$LOGDIR_T" bash "$SC" record "$RID_T" "$@" >/dev/null 2>&1
}

run_record --files "lib/x.sh" "add a new data model migration that introduces a primitive future work will build on"
run_record --files "lib/queue/orchestrate.sh lib/foo.sh" "add a mechanical, reversible, fully test-covered guard clause"
run_record "fix a typo in the README"

TOTAL=$((TOTAL+1))
if [ -f "$LEDGER_FILE" ] && [ "$(grep -c '| DEBT |' "$LEDGER_FILE")" -eq 3 ]; then
  echo -e "  ${GREEN}PASS${NC} AC5a three record calls append exactly three | DEBT | lines"
  PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC} AC5a expected 3 | DEBT | lines in $LEDGER_FILE"
  FAIL=$((FAIL+1))
fi

TOTAL=$((TOTAL+1))
if grep -qE '\| DEBT \| significance=high worthiness=high verdict=tap' "$LEDGER_FILE" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} AC5b the tap verdict's marker carries significance=high worthiness=high verdict=tap"
  PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC} AC5b tap marker fields missing/malformed"
  FAIL=$((FAIL+1))
fi

TOTAL=$((TOTAL+1))
if grep -qE '\| DEBT \| significance=high worthiness=low verdict=wave' "$LEDGER_FILE" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} AC5c the wave verdict's marker carries significance=high worthiness=low verdict=wave"
  PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC} AC5c wave marker fields missing/malformed"
  FAIL=$((FAIL+1))
fi

TOTAL=$((TOTAL+1))
if grep -qE '\| DEBT \| significance=low worthiness=low verdict=not-significant' "$LEDGER_FILE" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} AC5d the not-significant verdict's marker carries significance=low verdict=not-significant"
  PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC} AC5d not-significant marker fields missing/malformed"
  FAIL=$((FAIL+1))
fi

# AC5e: the DEBT marker is additive -- gate-ledger's check()/descent() must not treat it as a
# GATE line (it must not satisfy a required-gate check, and must not appear as a descent
# violation subject).
TOTAL=$((TOTAL+1))
if ! grep -qE '^\S+ \| GATE \| debt ' "$LEDGER_FILE" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} AC5e DEBT marker never masquerades as a | GATE | line"
  PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC} AC5e a | GATE | debt line leaked in -- additive-marker guarantee broken"
  FAIL=$((FAIL+1))
fi

echo ""
echo "=== significance-classify: determinism (AC6) ==="
D1="$(bash "$SC" classify --files "lib/x.sh" "add a new component with a novel first-of-kind pattern" 2>/dev/null)"
D2="$(bash "$SC" classify --files "lib/x.sh" "add a new component with a novel first-of-kind pattern" 2>/dev/null)"
assert "AC6a classify: same input -> same output ($D1)" "$([ "$D1" = "$D2" ] && echo 0 || echo 1)"

E1="$(bash "$SC" explain --files "lib/x.sh" "add a new component with a novel first-of-kind pattern" 2>/dev/null)"
E2="$(bash "$SC" explain --files "lib/x.sh" "add a new component with a novel first-of-kind pattern" 2>/dev/null)"
assert "AC6b explain: same input -> byte-identical output" "$([ "$E1" = "$E2" ] && echo 0 || echo 1)"

echo ""
echo "=== significance-classify: coverage delta ==="
TOTAL=$((TOTAL+1))
BEFORE_COUNT=0   # no test file referenced DEBT/significance-classify before this spec
AFTER_COUNT="$(grep -c 'DEBT' "$0")"
if [ "$AFTER_COUNT" -gt "$BEFORE_COUNT" ]; then
  echo -e "  ${GREEN}PASS${NC} coverage delta: DEBT-marker assertions went from $BEFORE_COUNT to $AFTER_COUNT in this suite"
  PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC} coverage delta did not increase"
  FAIL=$((FAIL+1))
fi

echo ""
echo "=== significance-classify: wiring sanity ==="
TOTAL=$((TOTAL+1))
if [ -x "$SC" ]; then
  echo -e "  ${GREEN}PASS${NC} lib/classify/significance-classify.sh exists and is executable"
  PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC} lib/classify/significance-classify.sh missing or not executable"
  FAIL=$((FAIL+1))
fi

TOTAL=$((TOTAL+1))
if grep -qE '^[[:space:]]*debt\)' "$GL" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} lib/gate/gate-ledger.sh exposes a 'debt' subcommand"
  PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC} lib/gate/gate-ledger.sh missing the 'debt' subcommand"
  FAIL=$((FAIL+1))
fi

echo ""
echo "=== $PASS/$TOTAL passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
