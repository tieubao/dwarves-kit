#!/usr/bin/env bash
# lib/gate/negctl.sh (and the proof-ledger.sh `negctl` forwarder): the mechanised negative
# control. Asserts on throwaway git repos: a real mutation goes GREEN -> RED -> GREEN and
# prints the block check() reads; a vacuous mutation is FAIL; a dirty tree is REFUSED
# before anything runs; the restore covers staged edits and paths with spaces; untracked
# leftovers are a FAIL; a FAIL block never satisfies check(); the tree is clean after
# every case. Battery findings 2026-09-04 (verifier N2, security 1-2, reviewer H1/M3/M4).
#
# Run: bash tests/test-proof-negctl.sh   Pass: "test-proof-negctl: all N passed", exit 0.
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
NC="$DIR/lib/gate/negctl.sh"
PL="$DIR/lib/gate/proof-ledger.sh"
pass=0; fail=0
ok(){ echo "  ok: $*"; pass=$((pass+1)); }
no(){ echo "  FAIL: $*" >&2; fail=$((fail+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkrepo() {  # $1 = dir; a lib with add() and a test that needs add 2 2 = 4
  mkdir -p "$1/sub dir"
  printf 'add() { echo $(( $1 + $2 )); }\n' > "$1/lib.sh"
  printf 'mul() { echo $(( $1 * $2 )); }\n' > "$1/sub dir/lib file.sh"
  printf '#!/usr/bin/env bash\nsource ./lib.sh\nsource "./sub dir/lib file.sh"\n[ "$(add 2 2)" = "4" ] && [ "$(mul 2 3)" = "6" ]\n' > "$1/test.sh"
  git -C "$1" init -q && git -C "$1" add -A && git -C "$1" -c user.name=t -c user.email=t@t commit -q -m seed
}
clean() { [ -z "$(git -C "$1" status --porcelain --untracked-files=all)" ]; }
REPO="$TMP/r"; mkrepo "$REPO"

echo "[1] real mutation: GREEN -> RED -> GREEN, PASS block, tree clean after"
OUT="$(bash "$NC" "$REPO" "bash test.sh" "sed -i.bak 's/+/-/' lib.sh && rm -f lib.sh.bak" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && grep -q '^Verdict: PASS$' <<<"$OUT" && grep -qi 'Negative control' <<<"$OUT" \
   && grep -q '^Exit: 0 (green before' <<<"$OUT" && grep -qE '^Exit: [1-9][0-9]* \(under mutation' <<<"$OUT" && clean "$REPO"; then
  ok "PASS block printed, tree clean"
else no "rc=$RC tree=$(git -C "$REPO" status --porcelain) out=$OUT"; fi

echo "[2] the proof-ledger.sh negctl verb forwards to the same script"
OUT="$(bash "$PL" negctl "$REPO" "bash test.sh" "sed -i.bak 's/+/-/' lib.sh && rm -f lib.sh.bak" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && grep -q '^Verdict: PASS$' <<<"$OUT" && clean "$REPO"; then ok "forwarder works"; else no "rc=$RC out=$OUT"; fi

echo "[3] vacuous mutation (test stays green) is FAIL, exit 1, tree restored"
OUT="$(bash "$NC" "$REPO" "bash test.sh" "printf '\n# comment\n' >> lib.sh" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && grep -q 'Verdict: FAIL: test stayed green' <<<"$OUT" && clean "$REPO"; then ok "vacuous control rejected"; else no "rc=$RC out=$OUT"; fi

echo "[4] dirty tracked file (unstaged AND staged): REFUSED before any step, exit 2, edits survive"
echo "# uncommitted work" >> "$REPO/lib.sh"
OUT1="$(bash "$NC" "$REPO" "bash test.sh" "sed -i.bak 's/+/-/' lib.sh" 2>&1)"; RC1=$?
git -C "$REPO" add lib.sh
OUT2="$(bash "$NC" "$REPO" "bash test.sh" "sed -i.bak 's/+/-/' lib.sh" 2>&1)"; RC2=$?
if [ "$RC1" -eq 2 ] && [ "$RC2" -eq 2 ] && grep -q 'REFUSED' <<<"$OUT1$OUT2" && grep -q '# uncommitted work' "$REPO/lib.sh" && ! grep -q 'Command:' <<<"$OUT1$OUT2"; then
  ok "refused both ways, uncommitted line survives"
else no "rc=$RC1/$RC2 out=$OUT1 // $OUT2"; fi
git -C "$REPO" reset -q --hard HEAD

echo "[5] mutation that changes nothing tracked is FAIL with its own reason (first failure wins)"
OUT="$(bash "$NC" "$REPO" "bash test.sh" "true" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && grep -q 'changed no tracked file' <<<"$OUT" && ! grep -q 'Verdict: FAIL: test stayed green' <<<"$OUT"; then ok "no-op mutation named as such"; else no "rc=$RC out=$OUT"; fi

echo "[6] a path with spaces is restored (verifier N2): mutate 'sub dir/lib file.sh'"
OUT="$(bash "$NC" "$REPO" "bash test.sh" "sed -i.bak 's/\*/+/' 'sub dir/lib file.sh' && rm -f 'sub dir/lib file.sh.bak'" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && grep -q '^Verdict: PASS$' <<<"$OUT" && clean "$REPO"; then ok "space-named path restored, PASS"; else no "rc=$RC tree=$(git -C "$REPO" status --porcelain) out=$OUT"; fi

echo "[7] a STAGED mutation is in the restore set (security 1)"
OUT="$(bash "$NC" "$REPO" "bash test.sh" "sed -i.bak 's/+/-/' lib.sh && rm -f lib.sh.bak && git add lib.sh" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && grep -q '^Changed: lib.sh' <<<"$OUT" && clean "$REPO"; then ok "staged edit seen and restored"; else no "rc=$RC tree=$(git -C "$REPO" status --porcelain) out=$OUT"; fi

echo "[8] a mutation that leaves an untracked file behind is FAIL, never PASS (security 2, reviewer M4)"
OUT="$(bash "$NC" "$REPO" "bash test.sh" "sed -i.bak 's/+/-/' lib.sh" 2>&1)"; RC=$?   # .bak left behind
rm -f "$REPO/lib.sh.bak"
if [ "$RC" -ne 0 ] && grep -q 'tree differs from the pre-run snapshot' <<<"$OUT" && grep -q 'Delta: .*lib.sh.bak' <<<"$OUT" && ! grep -q '^Verdict: PASS' <<<"$OUT"; then
  ok "untracked leftover named in the verdict"
else no "rc=$RC out=$OUT"; fi

echo "[9] a negctl FAIL block does NOT satisfy proof-ledger check() (reviewer H1)"
PR="$TMP/p"; mkrepo "$PR"
# The base ref must be the branch `git init` actually made. Hardcoding `master` here read as
# a passing gate on any machine whose init.defaultBranch is `main`: check() fails open on an
# unresolvable base by contract, so BOTH the FAIL block and the PASS block returned 0 and the
# assertion never reached the gate at all. Ask the repo for its own default branch instead.
BASE="$(git -C "$PR" symbolic-ref --short HEAD)"
git -C "$PR" checkout -q -b feat
printf 'x\n' >> "$PR/lib.sh"; mkdir -p "$PR/docs/verification"
{ echo "# proof"; echo "Command: bash test.sh"; echo "Exit: 0 (green before mutation)"; echo "## Negative control (negctl)"; echo "Verdict: FAIL: test stayed green under the mutation (the check is vacuous)"; } > "$PR/docs/verification/x.md"
git -C "$PR" add -A && git -C "$PR" -c user.name=t -c user.email=t@t commit -q -m "feat: change"
bash "$PL" check "$PR" "$BASE" >/dev/null 2>&1; RC_FAIL=$?
sed -i.bak 's/^Verdict: FAIL.*/Verdict: PASS/' "$PR/docs/verification/x.md" && rm -f "$PR/docs/verification/x.md.bak"
git -C "$PR" -c user.name=t -c user.email=t@t commit -q -am "proof pass"
bash "$PL" check "$PR" "$BASE" >/dev/null 2>&1; RC_PASS=$?
if [ "$RC_FAIL" -ne 0 ] && [ "$RC_PASS" -eq 0 ]; then ok "FAIL block blocked (rc=$RC_FAIL), PASS block accepted"; else no "check rc FAIL-block=$RC_FAIL PASS-block=$RC_PASS"; fi

echo "[9b] an unresolvable base fails OPEN, and that is not a gate pass"
# Pins the behaviour that hid [9] for four commits. check() returns 0 on a base that is not a
# commit (documented fail-open: a gate bug must never block unrelated work). Naming it here
# stops the next reader mistaking a disarmed gate for a satisfied one. hooks/ship-gate.sh
# resolves the base through merge-base and only calls check() with a real commit, so the
# fail-open is unreachable from the shipping path.
bash "$PL" check "$PR" no-such-branch-here >/dev/null 2>&1; RC_OPEN=$?
if [ "$RC_OPEN" -eq 0 ]; then ok "unresolvable base returns 0 by contract, gate never ran"; else no "expected fail-open 0, got $RC_OPEN"; fi

echo "[10] usage on missing args names the verb (non-vacuous: not the unknown-verb 64)"
OUT="$(bash "$NC" "$REPO" 2>&1)"; RC=$?
if [ "$RC" -eq 64 ] && grep -q 'usage: negctl.sh <root>' <<<"$OUT"; then ok "exit 64 with negctl usage"; else no "rc=$RC out=$OUT"; fi

echo
if [ "$fail" -gt 0 ]; then echo "test-proof-negctl: $pass passed, $fail FAILED" >&2; exit 1; fi
echo "test-proof-negctl: all $pass passed"
