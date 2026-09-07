#!/usr/bin/env bash
# test-coverage-delta.sh -- SPEC-130 advisory coverage-delta gate.
# Proves: under-tested -> FLAG (names the file); well-tested -> quiet (the FALSE-POSITIVE
# negative control, load-bearing); docs/test/generated-only -> exempt; ADVISORY (every verdict
# exits 0, including the FLAG path); the real-runner hook; the ledger record. Uses throwaway git
# fixtures (the test-proof-dir-layout.sh idiom).
set -uo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$KIT/lib/gate/coverage-delta.sh"
fails=0
pass(){ echo "PASS $*"; }
fail(){ echo "FAIL $*"; fails=$((fails+1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT

# make_repo <dir>: a git repo with a committed baseline (one source file + one test file).
make_repo() {
  local d="$1"
  rm -rf "$d"; mkdir -p "$d/lib" "$d/tests"
  git -C "$d" init -q
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  git -C "$d" branch -m master 2>/dev/null || true
  echo "baseline() { echo hi; }" > "$d/lib/thing.sh"
  echo "test_thing() { thing; }"  > "$d/tests/test-thing.sh"
  echo "# readme"                 > "$d/README.md"
  echo "locked"                   > "$d/pnpm-lock.yaml"
  git -C "$d" add -A; git -C "$d" commit -qm base
}
base() { git -C "$1" merge-base HEAD master 2>/dev/null || git -C "$1" rev-parse HEAD; }

# --- T1: under-tested -> FLAG, and it NAMES the uncovered source file (AC1, AC5) ---
D="$WORK/t1"; make_repo "$D"
echo "changed() { echo behavior; }" >> "$D/lib/thing.sh"     # source moved, no test change
git -C "$D" add -A
OUT="$(bash "$GATE" check "$D" "$(base "$D")")"
if { printf '%s' "$OUT" 2>/dev/null || :; } | grep -q 'WARNING under-tested'; then pass "T1 under-tested diff is FLAGGED"; else fail "T1 expected WARNING, got: $OUT"; fi
if { printf '%s' "$OUT" 2>/dev/null || :; } | grep -q 'lib/thing.sh'; then pass "T1 warning NAMES the uncovered source file"; else fail "T1 warning did not name lib/thing.sh: $OUT"; fi

# --- T2: FALSE-POSITIVE NEGATIVE CONTROL (load-bearing): well-tested -> NOT flagged (AC2) ---
D="$WORK/t2"; make_repo "$D"
echo "changed() { echo behavior; }" >> "$D/lib/thing.sh"     # source moved
echo "test_changed() { changed; }"  >> "$D/tests/test-thing.sh"  # AND test moved
git -C "$D" add -A
OUT="$(bash "$GATE" check "$D" "$(base "$D")")"
if { printf '%s' "$OUT" 2>/dev/null || :; } | grep -q 'WARNING'; then fail "T2 (NC) well-tested diff wrongly FLAGGED: $OUT"; else pass "T2 (false-positive NC) well-tested diff does NOT trip"; fi
if { printf '%s' "$OUT" 2>/dev/null || :; } | grep -q '^\[coverage-delta\] ok'; then pass "T2 well-tested reports ok"; else fail "T2 expected ok, got: $OUT"; fi

# --- T3: docs-only -> exempt (AC3) ---
D="$WORK/t3"; make_repo "$D"
echo "more docs" >> "$D/README.md"
git -C "$D" add -A
OUT="$(bash "$GATE" check "$D" "$(base "$D")")"
if { printf '%s' "$OUT" 2>/dev/null || :; } | grep -q 'exempt'; then pass "T3 docs-only diff is exempt"; else fail "T3 expected exempt, got: $OUT"; fi

# --- T4: ADVISORY-CANNOT-BLOCK: the FLAG fixture still exits 0 (AC4) ---
D="$WORK/t4"; make_repo "$D"
echo "changed() { echo behavior; }" >> "$D/lib/thing.sh"     # this WILL flag
git -C "$D" add -A
bash "$GATE" check "$D" "$(base "$D")" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then pass "T4 a FLAGGED diff still exits 0 (advisory cannot block)"; else fail "T4 flagged diff exited $rc, must be 0"; fi

# --- T5: test-only -> exempt (AC3) ---
D="$WORK/t5"; make_repo "$D"
echo "test_extra() { :; }" >> "$D/tests/test-thing.sh"       # only test moved
git -C "$D" add -A
OUT="$(bash "$GATE" check "$D" "$(base "$D")")"
if { printf '%s' "$OUT" 2>/dev/null || :; } | grep -q 'exempt'; then pass "T5 test-only diff is exempt"; else fail "T5 expected exempt, got: $OUT"; fi

# --- T6: generated-only -> exempt (AC3, generated class) ---
D="$WORK/t6"; make_repo "$D"
echo "relocked" >> "$D/pnpm-lock.yaml"                       # only a lockfile moved
git -C "$D" add -A
OUT="$(bash "$GATE" check "$D" "$(base "$D")")"
if { printf '%s' "$OUT" 2>/dev/null || :; } | grep -q 'exempt'; then pass "T6 generated-only diff is exempt"; else fail "T6 expected exempt, got: $OUT"; fi

# --- T7: classification, one path per class (AC via `class` subcommand) ---
declare -a cases=("README.md:docs" "pnpm-lock.yaml:generated" "tests/test-x.sh:test" "src/latest-value.js:source")
for c in "${cases[@]}"; do
  p="${c%%:*}"; want="${c##*:}"; got="$(bash "$GATE" class "$p")"
  if [ "$got" = "$want" ]; then pass "T7 class $p -> $got"; else fail "T7 class $p: want $want got $got"; fi
done

# --- T8: diff-plumbing reuse: a STAGED-only (uncommitted) source change is seen (AC6) ---
D="$WORK/t8"; make_repo "$D"
echo "staged_change() { :; }" >> "$D/lib/thing.sh"
git -C "$D" add -A                                            # staged, NOT committed
OUT="$(bash "$GATE" check "$D" "$(base "$D")")"
if { printf '%s' "$OUT" 2>/dev/null || :; } | grep -q 'WARNING under-tested'; then pass "T8 staged-only source change is seen + flagged"; else fail "T8 staged change not seen: $OUT"; fi

# --- T9: real-runner hook: COVERAGE_DELTA_RUNNER used; non-zero runner still exit 0 (AC7) ---
D="$WORK/t9"; make_repo "$D"
echo "changed() { :; }" >> "$D/lib/thing.sh"; git -C "$D" add -A
RUNNER="$WORK/runner.sh"
printf '#!/usr/bin/env bash\necho "covered=3 uncovered=1"\nexit 7\n' > "$RUNNER"; chmod +x "$RUNNER"
OUT="$(COVERAGE_DELTA_RUNNER="$RUNNER" bash "$GATE" check "$D" "$(base "$D")")"; rc=$?
if { printf '%s' "$OUT" 2>/dev/null || :; } | grep -q 'runner runner.sh: covered=3 uncovered=1'; then pass "T9 runner hook verdict is used"; else fail "T9 runner verdict missing: $OUT"; fi
if [ "$rc" -eq 0 ]; then pass "T9 non-zero runner still leaves gate at exit 0"; else fail "T9 gate exited $rc with a non-zero runner, must be 0"; fi

# --- T10: ledger record: check --rid appends one GATE|coverage-delta|ran line (AC8) ---
D="$WORK/t10"; make_repo "$D"
echo "changed() { :; }" >> "$D/lib/thing.sh"; git -C "$D" add -A
LEDGER_ROOT="$WORK/ledger"; mkdir -p "$LEDGER_ROOT"
# point the kit log dir at a throwaway path so we can read what the gate wrote.
export DWARVES_KIT_LOG_DIR="$LEDGER_ROOT"
bash "$GATE" check "$D" "$(base "$D")" --rid cd-test-run >/dev/null 2>&1
LINE="$(grep -rh 'coverage-delta' "$LEDGER_ROOT" 2>/dev/null | head -1)"
if { printf '%s' "$LINE" 2>/dev/null || :; } | grep -qE '\| GATE \| coverage-delta \| ran \|'; then pass "T10 ledger has a GATE|coverage-delta|ran line"; else fail "T10 no coverage-delta GATE line found (got: '$LINE')"; fi
if { printf '%s' "$LINE" 2>/dev/null || :; } | grep -qE 'src=[0-9]+ test=[0-9]+'; then pass "T10 ledger line carries src=/test= counts"; else fail "T10 line missing src=/test=: '$LINE'"; fi
unset DWARVES_KIT_LOG_DIR

echo "---"
[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "FAILS: $fails"; exit 1; }
