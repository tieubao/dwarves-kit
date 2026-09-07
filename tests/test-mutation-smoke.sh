#!/usr/bin/env bash
# test-mutation-smoke.sh -- the ADVISORY mutation smoke (lib/gate/mutation-smoke.sh, SPEC-131, SG-04).
#
# Over-test per the kit-run-integrity quality bar: bite/no-bite + the FALSE-POSITIVE negative
# control (a biting suite is NOT flagged, the load-bearing one) + advisory-cannot-block + a
# byte-identical tree after a run (no residue) + the runtime bound + the additive-marker safety.
#
# Fixtures use a controllable BASH suite as the "project test runner" (the strongest portable
# stand-in for a polyglot suite): a biting test asserts the mutated line's value, a non-biting
# test runs the line but asserts nothing the mutation breaks. Every ledger write is isolated into
# a mktemp DWARVES_KIT_LOG_DIR; fixture repos are mktemp, cleaned on EXIT.
#
# Run: bash tests/test-mutation-smoke.sh
# Exit 0 = all pass. Exit 1 = failures.
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SMOKE="$KIT_DIR/lib/gate/mutation-smoke.sh"
LEDGER="$KIT_DIR/lib/gate/gate-ledger.sh"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
PASS=0; FAIL=0; TOTAL=0
ok()  { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}PASS${NC} $1"; }
bad() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo -e "  ${RED}FAIL${NC} $1"; }
expect()  { if { printf '%s' "$3" 2>/dev/null || :; } | grep -qF "$2"; then ok "$1"; else bad "$1 (missing '$2' in: $3)"; fi; }
refute()  { if { printf '%s' "$3" 2>/dev/null || :; } | grep -qF "$2"; then bad "$1 (unexpected '$2')"; else ok "$1"; fi; }
eq()      { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3' got '$2')"; fi; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/kit-mut-smoke.XXXXXX")"
export DWARVES_KIT_LOG_DIR="$TMPROOT/logs"
trap 'rm -rf "$TMPROOT"' EXIT

git_init() { git -C "$1" init -q; git -C "$1" config user.email t@t.t; git -C "$1" config user.name t; }

# Build a fixture repo whose CHANGED HUNK adds a `+`-arithmetic line into code.sh, plus a test.sh
# of the requested flavor. Prints "<repo> <base-sha>".
# flavor: biting | nonbiting | baseline-red | many-biting
mk_fixture() {
  local flavor="$1" repo; repo="$(mktemp -d "$TMPROOT/repo.XXXXXX")"
  git_init "$repo"
  # BASE commit: code.sh with a placeholder body (no mutable operator yet).
  printf 'calc() {\n  echo 0\n}\n' > "$repo/code.sh"
  ( cd "$repo" && git add -A && git commit -qm base )
  local base; base="$( cd "$repo" && git rev-parse HEAD )"
  # CHANGE: add the mutable body line(s).
  case "$flavor" in
    many-biting)
      { printf 'calc() {\n'
        printf '  a=$(( 1 + 1 ))\n  b=$(( 2 + 2 ))\n  c=$(( 3 + 3 ))\n  d=$(( 4 + 4 ))\n  e=$(( 5 + 5 ))\n'
        printf '  echo $(( a + b + c + d + e ))\n}\n'
      } > "$repo/code.sh" ;;
    *)
      printf 'calc() {\n  echo $(( $1 + $2 ))\n}\n' > "$repo/code.sh" ;;
  esac
  # test.sh flavor.
  case "$flavor" in
    biting)       printf '. ./code.sh\n[ "$(calc 2 3)" = "5" ]\n' > "$repo/test.sh" ;;
    nonbiting)    printf '. ./code.sh\ncalc 2 3 >/dev/null 2>&1\ntrue\n' > "$repo/test.sh" ;;
    baseline-red) printf '. ./code.sh\n[ "$(calc 2 3)" = "999" ]\n' > "$repo/test.sh" ;;
    many-biting)  printf '. ./code.sh\n[ "$(calc)" = "30" ]\n' > "$repo/test.sh" ;;
  esac
  ( cd "$repo" && git add -A && git commit -qm change )
  printf '%s %s' "$repo" "$base"
}

run_smoke() {  # <repo> <base> <rid> [MAX]  -> runs the smoke, returns its exit code; sets OUT
  local repo="$1" base="$2" rid="$3" max="${4:-5}"
  OUT="$( cd "$repo" && MUTATION_SMOKE_TEST_CMD='bash test.sh' MUTATION_SMOKE_BASE="$base" \
         MUTATION_SMOKE_RID="$rid" MUTATION_SMOKE_MAX="$max" bash "$SMOKE" run 2>&1 )"
  return $?
}
ledger_of() { cat "$DWARVES_KIT_LOG_DIR/runs/$1.log" 2>/dev/null || true; }

# ============================================================
echo "=== T1: bite is observable -- a mutation makes a biting suite FAIL ==="
# ============================================================
read -r REPO BASE <<<"$(mk_fixture biting)"
# Directly apply one mutation and run the biting suite: it must go RED (exit != 0).
cp "$REPO/code.sh" "$REPO/code.sh.orig"
CAND="$( cd "$REPO" && MUTATION_SMOKE_BASE="$BASE" bash "$SMOKE" candidates )"
expect "T1 a mutable candidate exists in the changed hunk" "code.sh" "$CAND"
# mutate line 2 (the echo $(( $1 + $2 )) line) via the lib's own replace, then run the suite.
LN="$( printf '%s' "$CAND" | head -1 | cut -f2 )"
MUT="$( printf '%s' "$CAND" | head -1 | cut -f4 )"
( cd "$REPO" && { [ "$LN" -gt 1 ] && sed -n "1,$((LN-1))p" code.sh; printf '%s\n' "$MUT"; sed -n "$((LN+1)),\$p" code.sh; } > code.sh.new && mv code.sh.new code.sh )
if ( cd "$REPO" && bash test.sh ) >/dev/null 2>&1; then bad "T1 biting suite went RED under mutation"; else ok "T1 biting suite went RED under mutation (bite observable)"; fi
cp "$REPO/code.sh.orig" "$REPO/code.sh"

# ============================================================
echo "=== T2: a NON-biting suite is FLAGGED ==="
# ============================================================
read -r REPO BASE <<<"$(mk_fixture nonbiting)"
run_smoke "$REPO" "$BASE" nonbite; RC=$?
eq     "T2 advisory: flagged run still exits 0" "$RC" "0"
expect "T2 WARN emitted for a non-biting suite" "WARN: suite did NOT bite" "$OUT"
expect "T2 ledger records verdict=flag" "verdict=flag" "$(ledger_of nonbite)"

# ============================================================
echo "=== T3: FALSE-POSITIVE negative control -- a biting suite is NOT flagged (load-bearing) ==="
# ============================================================
read -r REPO BASE <<<"$(mk_fixture biting)"
run_smoke "$REPO" "$BASE" bite; RC=$?
eq     "T3 biting run exits 0" "$RC" "0"
refute "T3 no WARN for a biting suite" "WARN: suite did NOT bite" "$OUT"
expect "T3 ledger records verdict=clean (suite bit)" "verdict=clean" "$(ledger_of bite)"
refute "T3 ledger has NO flag verdict" "verdict=flag" "$(ledger_of bite)"

# ============================================================
echo "=== T4: clean tree after a run -- byte-identical, no residue (flag AND clean paths) ==="
# ============================================================
for flavor in nonbiting biting; do
  read -r REPO BASE <<<"$(mk_fixture "$flavor")"
  H0="$( shasum "$REPO/code.sh" | cut -d' ' -f1 )"
  run_smoke "$REPO" "$BASE" "tree-$flavor" >/dev/null
  H1="$( shasum "$REPO/code.sh" | cut -d' ' -f1 )"
  eq "T4 [$flavor] code.sh byte-identical after run" "$H1" "$H0"
  PORC="$( cd "$REPO" && git status --porcelain )"
  eq "T4 [$flavor] git tree clean after run (no residue)" "$PORC" ""
done

# ============================================================
echo "=== T5: advisory cannot block -- a flagged run never returns non-zero ==="
# ============================================================
read -r REPO BASE <<<"$(mk_fixture nonbiting)"
run_smoke "$REPO" "$BASE" adv; RC=$?
eq "T5 flagged smoke exit code is 0 (cannot block a push)" "$RC" "0"

# ============================================================
echo "=== T6: runtime bounded -- attempts capped at MUTATION_SMOKE_MAX, no full sweep ==="
# ============================================================
read -r REPO BASE <<<"$(mk_fixture many-biting)"   # 6 mutable lines, all caught
run_smoke "$REPO" "$BASE" bounded 2; RC=$?          # cap = 2
eq     "T6 bounded run exits 0" "$RC" "0"
expect "T6 stopped at the cap (2 attempts), did not sweep all 6" "attempts=2" "$(ledger_of bounded)"
expect "T6 verdict=clean after the cap (all attempted mutations caught)" "verdict=clean" "$(ledger_of bounded)"

# ============================================================
echo "=== T7: baseline-red SKIP -- no false flag when the suite is already failing ==="
# ============================================================
read -r REPO BASE <<<"$(mk_fixture baseline-red)"
run_smoke "$REPO" "$BASE" bred; RC=$?
eq     "T7 baseline-red run exits 0" "$RC" "0"
expect "T7 SKIP emitted (baseline not green)" "SKIP: baseline suite is not green" "$OUT"
expect "T7 ledger verdict=skip reason=baseline-red" "verdict=skip reason=baseline-red" "$(ledger_of bred)"
refute "T7 no flag on a red baseline" "verdict=flag" "$(ledger_of bred)"

# ============================================================
echo "=== T8: additive-marker safety -- a | MUTATION | line never fakes/satisfies a gate ==="
# ============================================================
# Empty ledger vs a MUTATION-only ledger must yield the IDENTICAL required-gate verdict.
EMPTY_OUT="$( bash "$LEDGER" check normal ms-empty 2>&1 || true )"
bash "$LEDGER" mutation ms-mut verdict=clean attempts=3 >/dev/null
MUT_OUT="$( bash "$LEDGER" check normal ms-mut 2>&1 || true )"
if bash "$LEDGER" check normal ms-mut >/dev/null 2>&1; then bad "T8 MUTATION-only ledger must NOT pass the gate check"; else ok "T8 MUTATION-only ledger still fails the required-gate check (exit non-zero)"; fi
expect "T8 spec gate still reported MISSING despite the MUTATION line" "MISSING-GATE: spec" "$MUT_OUT"
eq     "T8 MUTATION line changes nothing vs an empty ledger" "$MUT_OUT" "$EMPTY_OUT"

# ============================================================
echo "=== T9: no test runner -> SKIP (advisory, exit 0) ==="
# ============================================================
REPO="$(mktemp -d "$TMPROOT/norunner.XXXXXX")"; git_init "$REPO"
printf 'x=1\n' > "$REPO/code.sh"; ( cd "$REPO" && git add -A && git commit -qm base )
printf 'x=$(( 1 + 1 ))\n' > "$REPO/code.sh"; ( cd "$REPO" && git add -A && git commit -qm change )
BASE="$( cd "$REPO" && git rev-parse HEAD~1 )"
OUT="$( cd "$REPO" && MUTATION_SMOKE_BASE="$BASE" MUTATION_SMOKE_RID=norunner bash "$SMOKE" run 2>&1 )"; RC=$?
eq     "T9 no-runner run exits 0" "$RC" "0"
expect "T9 SKIP: no test runner detected" "SKIP: no test runner detected" "$OUT"
expect "T9 ledger verdict=skip reason=no-runner" "verdict=skip reason=no-runner" "$(ledger_of norunner)"

# ============================================================
echo "=== T10: portability -- sed-split rewrite is byte-exact at line 1 and the last line ==="
# ============================================================
PF="$TMPROOT/port.txt"; printf 'AAA\nBBB\nCCC\n' > "$PF"
# replace line 1 (BSD sed rejects address 0; the lib guards n==1) and the last line.
rewrite() { local f="$1" n="$2" new="$3" tmp="$TMPROOT/rw.$$"; { [ "$n" -gt 1 ] && sed -n "1,$((n-1))p" "$f"; printf '%s\n' "$new"; sed -n "$((n+1)),\$p" "$f"; } > "$tmp"; mv "$tmp" "$f"; }
rewrite "$PF" 1 'ZZZ'; eq "T10 line-1 rewrite" "$(cat "$PF")" "$(printf 'ZZZ\nBBB\nCCC')"
rewrite "$PF" 3 'QQQ'; eq "T10 last-line rewrite (rest intact)" "$(cat "$PF")" "$(printf 'ZZZ\nBBB\nQQQ')"

# ============================================================
echo "=== T11: scope -- a diff touching only tests/docs yields no candidates (SKIP) ==="
# ============================================================
REPO="$(mktemp -d "$TMPROOT/testsonly.XXXXXX")"; git_init "$REPO"
printf 'echo base\n' > "$REPO/test-foo.sh"; printf '# doc\n' > "$REPO/README.md"
( cd "$REPO" && git add -A && git commit -qm base )
printf 'x=$(( 1 + 1 ))\n' > "$REPO/test-foo.sh"; printf '# doc x=$(( 2 + 2 ))\n' > "$REPO/README.md"
( cd "$REPO" && git add -A && git commit -qm change )
BASE="$( cd "$REPO" && git rev-parse HEAD~1 )"
CAND="$( cd "$REPO" && MUTATION_SMOKE_BASE="$BASE" bash "$SMOKE" candidates )"
eq "T11 no candidates from a tests/docs-only diff" "$CAND" ""
OUT="$( cd "$REPO" && MUTATION_SMOKE_TEST_CMD='true' MUTATION_SMOKE_BASE="$BASE" MUTATION_SMOKE_RID=testsonly bash "$SMOKE" run 2>&1 )"; RC=$?
eq     "T11 tests/docs-only run exits 0" "$RC" "0"
expect "T11 ledger verdict=skip reason=no-candidates" "verdict=skip reason=no-candidates" "$(ledger_of testsonly)"

# ============================================================
echo ""
echo "  ---------------------------------------------"
echo -e "  TOTAL: $TOTAL   ${GREEN}PASS: $PASS${NC}   ${RED}FAIL: $FAIL${NC}"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
