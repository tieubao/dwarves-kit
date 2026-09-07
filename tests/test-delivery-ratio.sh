#!/usr/bin/env bash
# test-delivery-ratio.sh -- the ADVISORY delivery-ratio verb on proof-ledger.sh.
# It splits a branch's ADDED lines into real-deliverable vs proof/ceremony and prints
# a NOTICE/THIN-WARN/OK line. It is ADVISORY: it must NEVER exit nonzero (no blocking).
# Run: bash tests/test-delivery-ratio.sh
set -uo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PL="$KIT_DIR/lib/gate/proof-ledger.sh"
pass=0; fail=0
assert() { if [ "$2" -eq 0 ]; then echo "  PASS $1"; pass=$((pass+1)); else echo "  FAIL $1"; fail=$((fail+1)); fi; }

# a throwaway git repo with a base commit + one branch commit staged by the caller.
mkrepo() { local d; d="$(mktemp -d)"; git -C "$d" init -q; git -C "$d" config user.email t@t; git -C "$d" config user.name t; \
  echo seed > "$d/seed"; git -C "$d" add -A; git -C "$d" commit -qm base; echo "$d"; }

echo "=== delivery-ratio (advisory) ==="

# CASE 1 THIN: 6 real lines under 220 proof lines (the #197-shape hollow signature).
D1="$(mkrepo)"; mkdir -p "$D1/lib/gate" "$D1/docs/proof"
printf 'a\nb\nc\nd\ne\nf\n' > "$D1/lib/gate/thing.sh"
seq 220 > "$D1/docs/proof/kitmod.md"
git -C "$D1" add -A; git -C "$D1" commit -qm work
OUT1="$(bash "$PL" delivery-ratio "$D1" HEAD~1)"; RC1=$?
echo "  case1: $OUT1"
{ trap '' PIPE; printf '%s' "$OUT1" 2>/dev/null || :; } | grep -q 'real=6 proof=220'; assert "CASE1: counts 6 real / 220 proof" $?
{ trap '' PIPE; printf '%s' "$OUT1" 2>/dev/null || :; } | grep -q 'THIN-WARN'; assert "CASE1: flags THIN-WARN (real<40 AND proof>=3x)" $?
assert "CASE1: exit 0 (advisory never blocks)" $RC1

# CASE 2 OK: substantial real code (60 lines) with proportionate proof.
D2="$(mkrepo)"; mkdir -p "$D2/lib" "$D2/tests"
seq 60 > "$D2/lib/feature.sh"; seq 30 > "$D2/tests/test-feature.sh"
git -C "$D2" add -A; git -C "$D2" commit -qm work
OUT2="$(bash "$PL" delivery-ratio "$D2" HEAD~1)"
echo "  case2: $OUT2"
{ trap '' PIPE; printf '%s' "$OUT2" 2>/dev/null || :; } | grep -q 'real=60 proof=30'; assert "CASE2: counts 60 real / 30 proof (tests=proof)" $?
{ trap '' PIPE; printf '%s' "$OUT2" 2>/dev/null || :; } | grep -qE '\| OK'; assert "CASE2: substantial real change => OK" $?

# CASE 3 NOTICE: docs/proof-only branch (real=0) -- fine for a docs sub-goal, suspect for a build claim.
D3="$(mkrepo)"; mkdir -p "$D3/docs/verification"
seq 40 > "$D3/docs/verification/x.md"
git -C "$D3" add -A; git -C "$D3" commit -qm work
OUT3="$(bash "$PL" delivery-ratio "$D3" HEAD~1)"
echo "  case3: $OUT3"
{ trap '' PIPE; printf '%s' "$OUT3" 2>/dev/null || :; } | grep -q 'real=0 proof=40'; assert "CASE3: counts 0 real / 40 proof" $?
{ trap '' PIPE; printf '%s' "$OUT3" 2>/dev/null || :; } | grep -q 'NOTICE'; assert "CASE3: docs-only => NOTICE (not a hard verdict)" $?

# CASE 4 [HONEST LIMIT, documented]: a 47-line append (the real #195 shape) is NOT flagged
# because real(47) >= floor(40). Line-count cannot tell a thin-for-a-"rewrite" 47-line append
# from a genuine 47-line change; this is why the verb is a VISIBILITY nudge, not a verdict.
D4="$(mkrepo)"; mkdir -p "$D4/docs/proof"
seq 47 > "$D4/README.md"; seq 228 > "$D4/docs/proof/x.md"
git -C "$D4" add -A; git -C "$D4" commit -qm work
OUT4="$(bash "$PL" delivery-ratio "$D4" HEAD~1)"
echo "  case4 (known blind spot): $OUT4"
{ trap '' PIPE; printf '%s' "$OUT4" 2>/dev/null || :; } | grep -qE '\| OK'; assert "CASE4: 47-real append reads OK (documented blind spot: floor=40)" $?

echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
