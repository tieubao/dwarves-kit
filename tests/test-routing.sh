#!/usr/bin/env bash
# test-routing.sh -- data-driven model routing suggester (token-optim-v3 SG-06).
# Verifies lib/classify/route-suggest.sh against v2 SG-09's ledger schema:
#   - rich data: suggests the measured-cheapest model that PASSED at parity
#   - failing-but-cheaper arm is NOT suggested (infinite-cost / anti-cherry-pick guard)
#   - thin data (one model measured): ABSTAINS instead of overfitting
#
# Run: bash tests/test-routing.sh   (exit 0 = pass, 1 = fail)

KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RS="$KIT_DIR/lib/classify/route-suggest.sh"
FIX="$KIT_DIR/tests/fixtures/routing"
PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
ok()  { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}PASS${NC} $1"; }
bad() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo -e "  ${RED}FAIL${NC} $1"; }
chk() { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }

echo "=== route-suggest exists + executable ==="
[ -f "$RS" ]; chk "lib/classify/route-suggest.sh exists" $?

echo ""
echo "=== rich data: suggest measured-cheapest-at-parity ==="
OUT=$(bash "$RS" "$FIX/rich-ledger.tsv" code-add-flag); RC=$?
echo "  -> $OUT"
[ "$RC" -eq 0 ]; chk "rich: exit 0 (a suggestion was made)" $?
{ trap '' PIPE; echo "$OUT" 2>/dev/null || :; } | grep -q '^SUGGEST'; chk "rich: line is SUGGEST" $?
{ trap '' PIPE; echo "$OUT" 2>/dev/null || :; } | grep -q 'model=haiku'; chk "rich: suggests haiku (cheapest PASS: 322602 < opus 901000)" $?
# negative control: the cheaper-but-FAILING sonnet arm (90000 tok) must not win
{ trap '' PIPE; echo "$OUT" 2>/dev/null || :; } | grep -q 'model=sonnet' && bad "rich: failing sonnet NOT suggested" || ok "rich: failing sonnet NOT suggested (infinite-cost guard)"
{ trap '' PIPE; echo "$OUT" 2>/dev/null || :; } | grep -q 'effort=abstain'; chk "rich: effort abstained (not in SG-09 schema)" $?

echo ""
echo "=== thin data: abstain, do not overfit ==="
OUT2=$(bash "$RS" "$FIX/thin-ledger.tsv" mini-mega); RC2=$?
echo "  -> $OUT2"
[ "$RC2" -eq 2 ]; chk "thin: exit 2 (abstained)" $?
{ trap '' PIPE; echo "$OUT2" 2>/dev/null || :; } | grep -q '^ABSTAIN'; chk "thin: line is ABSTAIN" $?
{ trap '' PIPE; echo "$OUT2" 2>/dev/null || :; } | grep -q 'thin-data'; chk "thin: reason names thin-data" $?

echo ""
echo "=== no passing data: abstain ==="
OUT3=$(bash "$RS" "$FIX/rich-ledger.tsv" no-such-task); RC3=$?
echo "  -> $OUT3"
[ "$RC3" -eq 2 ] && { trap '' PIPE; echo "$OUT3" 2>/dev/null || :; } | grep -q 'no-passing-data'; chk "unknown task: abstains with no-passing-data" $?

echo ""
echo "=== missing ledger file: abstain (no crash) ==="
OUT4=$(bash "$RS" "$FIX/does-not-exist.tsv" any-task); RC4=$?
echo "  -> $OUT4"
[ "$RC4" -eq 2 ] && { trap '' PIPE; echo "$OUT4" 2>/dev/null || :; } | grep -q 'no-ledger'; chk "missing ledger: abstains with no-ledger" $?

echo ""
echo "=== exact multi-model tie: deterministic (alphabetical) winner ==="
TIE="$(mktemp "${TMPDIR:-/tmp}/tie-ledger.XXXXXX")"
# haiku and sonnet both PASS at the SAME token count. The tie-break contract: the winner is the
# alphabetically-first tier, and the basis string is emitted in that same sorted order.
printf 'code-add-flag\tb-haiku\tpass\t500000\t40\t900\t450000\t49060\t5\t0.1\thaiku-4-5\ts1\n'  > "$TIE"
printf 'code-add-flag\tb-sonnet\tpass\t500000\t40\t900\t450000\t49060\t5\t0.2\tsonnet-4-6\ts2\n' >> "$TIE"
T1=$(bash "$RS" "$TIE" code-add-flag)
echo "  -> $T1"
# Contract assertion: winner == alphabetically-first of the tied tiers (not a hash-order accident).
{ trap '' PIPE; echo "$T1" 2>/dev/null || :; } | grep -q 'model=haiku'; chk "tie: alphabetically-first tier (haiku) wins" $?
# Direct sort-ran proof: basis lists tiers in sorted order, so 'haiku=' precedes 'sonnet='. Without
# the sort the basis follows assoc-array hash order (haiku AFTER sonnet on this host) -> this FAILs.
{ trap '' PIPE; echo "$T1" 2>/dev/null || :; } | grep -qE 'haiku=[0-9]+tok, sonnet=[0-9]+tok'; chk "tie: basis emitted in sorted (haiku-before-sonnet) order , proves the sort ran" $?
rm -f "$TIE"

echo ""
echo "=== malformed/short row: skipped, no arithmetic crash ==="
BAD="$(mktemp "${TMPDIR:-/tmp}/bad-ledger.XXXXXX")"
printf 'code-add-flag\tb-haiku\tpass\t300000\t40\t900\t250000\t49060\t5\t0.1\thaiku-4-5\ts1\n' > "$BAD"
printf 'code-add-flag\tb-haiku\tpass\n' >> "$BAD"   # short row: no numeric total_tokens column
OUT5=$(bash "$RS" "$BAD" code-add-flag 2>&1); RC5=$?
echo "  -> $OUT5"
{ trap '' PIPE; echo "$OUT5" 2>/dev/null || :; } | grep -qiE 'unary operator|integer expression'; if [ $? -eq 0 ]; then bad "malformed row: no bash arithmetic error"; else ok "malformed row: no bash arithmetic error (skipped)"; fi
rm -f "$BAD"

echo ""
echo "=== $PASS/$TOTAL passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
