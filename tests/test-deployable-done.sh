#!/usr/bin/env bash
# test-deployable-done.sh -- SPEC-095, kit-hardening SG-07.
# Validates conditional deployable-done: DEPLOYABLE work (proof-ledger's existing
# `stateful` class) cannot be marked done without a deploy-proof + UAT, enforced via the
# EXISTING ADR-0025 stateful proof-ledger.sh check() -- no new/tightened shared logic.
# AC1 (deployable blocked sans proof) is the load-bearing negative control.
#
# Run: bash tests/test-deployable-done.sh   (exit 0 = all AC green)
set -uo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$KIT_DIR/lib/gate/proof-ledger.sh"
AGENTS_MD="$KIT_DIR/AGENTS.md"
FIX="$KIT_DIR/tests/fixtures/deployable-done"

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert() { TOTAL=$((TOTAL+1)); if [ "$2" -eq 0 ]; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1)); else echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL+1)); fi; }

LOGDIR="$(mktemp -d)"   # isolate the override-log store from the real one

# mkrepo <dir> -- an adopted repo (docs/verification/README.md present) at an init commit.
mkrepo() {
  local d="$1"
  rm -rf "$d"; mkdir -p "$d/docs/verification"
  git init -q -b master "$d"
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  echo "# Verification log (proof of done)" > "$d/docs/verification/README.md"   # opt-in marker
  git -C "$d" add -A; git -C "$d" commit -qm init
}
base() { git -C "$1" rev-parse HEAD; }
run_classify() { bash "$LIB" classify "$1" "$2"; }
run_deployable() { bash "$LIB" deployable "$1" "$2"; }
run_check() { DWARVES_KIT_LOG_DIR="$LOGDIR" bash "$LIB" check "$1" "$2" "${3:-}"; }

echo "=== deployable-done (SPEC-095 AC1-AC5) ==="

# ============================================================
echo ""
echo "=== AC1 [LOAD-BEARING NEGATIVE CONTROL]: deployable diff, no proof -> BLOCKED ==="
# ============================================================
D1="$(mktemp -d)"; mkrepo "$D1"
B1="$(base "$D1")"
mkdir -p "$D1/deploy"
cp "$FIX/deploy-rollout.sh" "$D1/deploy/rollout.sh"
git -C "$D1" add -A; git -C "$D1" commit -qm "deploy: add rollout script"

assert "AC1: classify() puts the deploy/ change in the stateful class" \
  $([ "$(run_classify "$D1" "$B1")" = "stateful" ] && echo 0 || echo 1)
assert "AC1: deployable helper maps stateful -> yes" \
  $([ "$(run_deployable "$D1" "$B1")" = "yes" ] && echo 0 || echo 1)
if run_check "$D1" "$B1" "deploy-noproof" >/dev/null 2>&1; then
  assert "AC1: deployable diff with NO proof-of-done is BLOCKED by proof-ledger check" 1
else
  assert "AC1: deployable diff with NO proof-of-done is BLOCKED by proof-ledger check" 0
fi
MSG1="$(run_check "$D1" "$B1" "deploy-noproof" 2>&1 || true)"
assert "AC1: the block message names the stateful class + missing proof" \
  $({ trap '' PIPE; printf '%s' "$MSG1" 2>/dev/null || :; } | grep -qi "stateful" && { trap '' PIPE; printf '%s' "$MSG1" 2>/dev/null || :; } | grep -qi "proof" && echo 0 || echo 1)

# ============================================================
echo ""
echo "=== AC2: same deployable diff WITH a well-formed deploy-proof + UAT -> PASSES ==="
# ============================================================
D2="$(mktemp -d)"; mkrepo "$D2"
B2="$(base "$D2")"
mkdir -p "$D2/deploy"
cp "$FIX/deploy-rollout.sh" "$D2/deploy/rollout.sh"
git -C "$D2" add -A; git -C "$D2" commit -qm "deploy: add rollout script"
cp "$FIX/well-formed-proof.md" "$D2/docs/verification/deploy-proof-ok.md"
git -C "$D2" add -A; git -C "$D2" commit -qm "docs: add deploy-proof-ok verification"

grep -qi 'UAT' "$D2/docs/verification/deploy-proof-ok.md"; assert "AC2: fixture proof carries a UAT/acceptance line (contract, not a gate grep)" $?
if run_check "$D2" "$B2" "deploy-proof-ok" >/dev/null 2>&1; then
  assert "AC2: deployable diff WITH a well-formed rollback+Command/Exit proof PASSES" 0
else
  assert "AC2: deployable diff WITH a well-formed rollback+Command/Exit proof PASSES" 1
fi

# ============================================================
echo ""
echo "=== AC3 [inert unaffected]: a docs-only diff classifies inert and ships with no proof ==="
# ============================================================
D3="$(mktemp -d)"; mkrepo "$D3"
B3="$(base "$D3")"
mkdir -p "$D3/docs"
cp "$FIX/inert-notes.md" "$D3/docs/notes.md"
git -C "$D3" add -A; git -C "$D3" commit -qm "docs: add notes"

assert "AC3: classify() puts a docs-only diff in the inert class" \
  $([ "$(run_classify "$D3" "$B3")" = "inert" ] && echo 0 || echo 1)
assert "AC3: deployable helper maps inert -> no" \
  $([ "$(run_deployable "$D3" "$B3")" = "no" ] && echo 0 || echo 1)
if run_check "$D3" "$B3" "inert-notes" >/dev/null 2>&1; then
  assert "AC3: inert diff PASSES with no proof-of-done required" 0
else
  assert "AC3: inert diff PASSES with no proof-of-done required" 1
fi

# ============================================================
echo ""
echo "=== AC4 [override logs]: a logged override on the AC1 no-proof repo passes + is audited ==="
# ============================================================
D4="$(mktemp -d)"; mkrepo "$D4"
B4="$(base "$D4")"
mkdir -p "$D4/deploy"
cp "$FIX/deploy-rollout.sh" "$D4/deploy/rollout.sh"
git -C "$D4" add -A; git -C "$D4" commit -qm "deploy: add rollout script"
# ID-299: overrides are repo-scoped, so log the override FROM the repo it applies to.
OUT4="$( cd "$D4" && DWARVES_KIT_LOG_DIR="$LOGDIR" bash "$LIB" override deploy-noproof-override "emergency hotfix, deploy verified manually" 2>&1)"
assert "AC4: override command reports the trace log path" $({ trap '' PIPE; printf '%s' "$OUT4" 2>/dev/null || :; } | grep -qi "trace" && echo 0 || echo 1)
if run_check "$D4" "$B4" "deploy-noproof-override" >/dev/null 2>&1; then
  assert "AC4: deployable diff with a LOGGED override PASSES (no proof file needed)" 0
else
  assert "AC4: deployable diff with a LOGGED override PASSES (no proof file needed)" 1
fi
grep -qF "| deploy-noproof-override | OVERRIDE | emergency hotfix, deploy verified manually" "$LOGDIR/proof-overrides.log" 2>/dev/null
assert "AC4: the override is logged to the audit trail (slug + reason present)" $?

# --- cc-hyg-04: an override does NOT excuse application source code outside deploy/.
# (deploy scripts above stay override-able; a lib/ source change must not.)
D4B="$(mktemp -d)"; mkrepo "$D4B"
B4B="$(base "$D4B")"
mkdir -p "$D4B/lib"; printf 'echo broken\n' > "$D4B/lib/handler.sh"
git -C "$D4B" add -A; git -C "$D4B" commit -qm "feat(handler): urgent source change"
( cd "$D4B" && DWARVES_KIT_LOG_DIR="$LOGDIR" bash "$LIB" override src-noproof-override "urgent, trust me" >/dev/null 2>&1 )
if run_check "$D4B" "$B4B" "src-noproof-override" >/dev/null 2>&1; then
  assert "AC4b: override on NON-deploy source is still REJECTED (rtk-611 hole closed)" 1
else
  assert "AC4b: override on NON-deploy source is still REJECTED (rtk-611 hole closed)" 0
fi

# ============================================================
echo ""
echo "=== AC5 [contract]: AGENTS.md zone 3 carries the Deployable-done clause ==="
# ============================================================
grep -qi 'Deployable-done' "$AGENTS_MD"; assert "AC5: AGENTS.md has a 'Deployable-done' clause" $?
grep -qi 'deploy-proof' "$AGENTS_MD" && grep -qi 'UAT' "$AGENTS_MD"; assert "AC5: clause defines done = deploy-proof + UAT" $?
grep -A15 -i 'Deployable-done' "$AGENTS_MD" | grep -qi 'unchanged'; assert "AC5: clause states inert/library/refactor work is unchanged" $?
grep -A15 -i 'Deployable-done' "$AGENTS_MD" | grep -qi 'stateful'; assert "AC5: clause ties deployability to proof-ledger's stateful class" $?

echo ""
echo "=== $PASS/$TOTAL passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
