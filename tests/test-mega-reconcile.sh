#!/usr/bin/env bash
# test-mega-reconcile.sh -- SPEC-096, kit-hardening SG-08.
# Validates the mega-lane reconcile: commands/mega.md mirrors the plan-for-mega-goal
# skill's decompose + front-load-checkpoint + per-run-merge-config beats, and
# lib/goal/mega-merge.sh's ship-layer auto-merge enforcement rides the ship-gate and never
# bypasses it (the load-bearing negative control), dry-run by default, with the
# per-run posture knob honored.
#
# Run: bash tests/test-mega-reconcile.sh   (exit 0 = all AC green)
set -uo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MEGA_MD="$KIT_DIR/commands/mega.md"
MM="$KIT_DIR/lib/goal/mega-merge.sh"
GL="$KIT_DIR/lib/gate/gate-ledger.sh"
PL="$KIT_DIR/lib/gate/proof-ledger.sh"

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert() { TOTAL=$((TOTAL+1)); if [ "$2" -eq 0 ]; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1)); else echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL+1)); fi; }
assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL+1))
  if { printf '%s' "$haystack" 2>/dev/null || :; } | grep -qF "$needle"; then
    echo -e "  ${GREEN}PASS${NC} $name"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $name"; FAIL=$((FAIL+1))
  fi
}

echo "=== mega-reconcile (SPEC-096 AC1-AC6) ==="

# ============================================================
echo ""
echo "=== AC1: mirror parity -- commands/mega.md exists + carries the 3 beats ==="
# ============================================================
[ -f "$MEGA_MD" ]; assert "AC1: commands/mega.md exists" $?
head -1 "$MEGA_MD" | grep -qF -- '---'; assert "AC1: mega.md starts with --- frontmatter" $?
grep -qE '^description:' "$MEGA_MD"; assert "AC1: mega.md frontmatter has a description field" $?
grep -qiE 'decompose' "$MEGA_MD"; assert "AC1: mega.md carries the decompose beat" $?
grep -qiE 'front-load|front-loaded' "$MEGA_MD"; assert "AC1: mega.md carries the front-load-checkpoint beat" $?
grep -qiE 'merge config|merge_autonomy|MEGA_MERGE_POSTURE' "$MEGA_MD"; assert "AC1: mega.md carries the per-run-merge-config beat" $?
grep -qiE 'plan-for-mega-goal' "$MEGA_MD"; assert "AC1: mega.md names the ops-toolkit plan-for-mega-goal skill as the mirror source" $?
grep -qiE 'mirror|does NOT fork' "$MEGA_MD"; assert "AC1: mega.md states it mirrors, not forks, the skill" $?
grep -qF 'lib/goal/mega-merge.sh' "$MEGA_MD"; assert "AC1: mega.md wires lib/goal/mega-merge.sh into the hand-off step" $?

# ============================================================
echo ""
echo "=== lib/goal/mega-merge.sh exists, is executable, dispatches gate + merge ==="
# ============================================================
[ -f "$MM" ] && [ -x "$MM" ]; assert "mega-merge.sh exists and is executable" $?
grep -qE '^[[:space:]]*gate\)[[:space:]]*gate' "$MM"; assert "mega-merge.sh dispatches 'gate'" $?
grep -qE '^[[:space:]]*merge\)[[:space:]]*merge' "$MM"; assert "mega-merge.sh dispatches 'merge'" $?

LOGDIR="$(mktemp -d)"   # isolate the ledger + override-log stores from the real ones
export DWARVES_KIT_LOG_DIR="$LOGDIR"

# Fake gh on PATH: leaves a marker file if actually invoked, so "did NOT call gh" is
# a real assertion, not just "the script printed DRY-RUN".
FAKEBIN="$(mktemp -d)"
GH_CALLED_MARKER="$LOGDIR/gh-was-called"
cat > "$FAKEBIN/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$GH_CALLED_MARKER"
exit 0
EOF
chmod +x "$FAKEBIN/gh"
export PATH="$FAKEBIN:$PATH"

# SPEC-100: mega-merge now checks a PR-state exclusion BEFORE the gate (via `gh pr view`).
# These tests use fake PR numbers, so inject a CLEAR PR-state stub -- otherwise the fake gh
# returns empty and the exclusion fail-closes, masking the gate/posture behavior under test.
# The exclusion itself is covered by tests/test-mega-merge.sh.
PRINFO_STUB="$FAKEBIN/prinfo-clear"
printf '#!/usr/bin/env bash\nprintf '"'"'false\\037\\037clear test PR\\n'"'"'\n' > "$PRINFO_STUB"
chmod +x "$PRINFO_STUB"
export MEGA_MERGE_PR_INFO_CMD="$PRINFO_STUB"

LANE=full
REQUIRED="$(bash "$GL" required "$LANE")"

# ============================================================
echo ""
echo "=== AC2: auto-merge past a GREEN gate ==="
# ============================================================
RID_GREEN="mega-reconcile-green"
bash "$GL" start "$RID_GREEN" "$LANE" "$LANE" feature feature testrepo >/dev/null 2>&1
while IFS= read -r phase; do
  [ -n "$phase" ] || continue
  bash "$GL" record "$RID_GREEN" "$phase" ran >/dev/null 2>&1
done <<< "$REQUIRED"

if bash "$MM" gate "$RID_GREEN" "$LANE" >/dev/null 2>&1; then
  assert "AC2: mega-merge.sh gate exits 0 once every required gate is recorded" 0
else
  assert "AC2: mega-merge.sh gate exits 0 once every required gate is recorded" 1
fi

rm -f "$GH_CALLED_MARKER"
MERGE_OUT_DEFAULT="$(bash "$MM" merge 999 "$RID_GREEN" "$LANE" 2>&1)"
MERGE_RC_DEFAULT=$?
assert_contains "AC4: merge on a passing gate WITHOUT --execute prints DRY-RUN" "DRY-RUN" "$MERGE_OUT_DEFAULT"
assert "AC4: merge on a passing gate WITHOUT --execute exits 0" $([ "$MERGE_RC_DEFAULT" -eq 0 ] && echo 0 || echo 1)
assert "AC4 [load-bearing]: merge WITHOUT --execute never actually calls gh" $([ -f "$GH_CALLED_MARKER" ] && echo 1 || echo 0)

rm -f "$GH_CALLED_MARKER"
MERGE_OUT_EXEC="$(bash "$MM" merge 999 "$RID_GREEN" "$LANE" --execute 2>&1)"
MERGE_RC_EXEC=$?
assert "AC2: merge on a passing gate WITH --execute exits 0" $([ "$MERGE_RC_EXEC" -eq 0 ] && echo 0 || echo 1)
assert "AC2: merge on a passing gate WITH --execute actually calls gh" $([ -f "$GH_CALLED_MARKER" ] && echo 0 || echo 1)
assert_contains "AC2: the executed call is a gh pr merge for the right PR" "999" "$(cat "$GH_CALLED_MARKER" 2>/dev/null || true)"

# ============================================================
echo ""
echo "=== AC3 [LOAD-BEARING NEGATIVE CONTROL]: one required gate missing -> never merges ==="
# ============================================================
RID_RED="mega-reconcile-red"
bash "$GL" start "$RID_RED" "$LANE" "$LANE" feature feature testrepo >/dev/null 2>&1
SKIP_PHASE=""
i=0
while IFS= read -r phase; do
  [ -n "$phase" ] || continue
  i=$((i+1))
  if [ "$i" -eq 1 ]; then SKIP_PHASE="$phase"; continue; fi   # deliberately skip the first required phase
  bash "$GL" record "$RID_RED" "$phase" ran >/dev/null 2>&1
done <<< "$REQUIRED"

if bash "$MM" gate "$RID_RED" "$LANE" >/dev/null 2>&1; then
  assert "AC3 [NEGATIVE CONTROL]: gate exits nonzero when '$SKIP_PHASE' is missing" 1
else
  assert "AC3 [NEGATIVE CONTROL]: gate exits nonzero when '$SKIP_PHASE' is missing" 0
fi

rm -f "$GH_CALLED_MARKER"
MERGE_OUT_RED="$(bash "$MM" merge 888 "$RID_RED" "$LANE" 2>&1)"
MERGE_RC_RED=$?
assert "AC3 [NEGATIVE CONTROL]: merge REFUSES (nonzero exit) on a failing gate" $([ "$MERGE_RC_RED" -ne 0 ] && echo 0 || echo 1)
assert_contains "AC3 [NEGATIVE CONTROL]: merge prints a BLOCKED message" "BLOCKED" "$MERGE_OUT_RED"
assert_contains "AC3: the BLOCKED message names the missing gate" "$SKIP_PHASE" "$MERGE_OUT_RED"
assert "AC3 [NEGATIVE CONTROL]: a failing gate never calls gh, even with --execute" \
  $([ -f "$GH_CALLED_MARKER" ] && echo 1 || echo 0)

rm -f "$GH_CALLED_MARKER"
bash "$MM" merge 888 "$RID_RED" "$LANE" --execute >/dev/null 2>&1
assert "AC3 [NEGATIVE CONTROL]: --execute cannot force a merge past a failing gate" \
  $([ -f "$GH_CALLED_MARKER" ] && echo 1 || echo 0)

# ============================================================
echo ""
echo "=== AC5: deploy/UAT terminus via lib/gate/proof-ledger.sh deployable (SG-07 reuse) ==="
# ============================================================
mkrepo() {
  local d="$1"
  rm -rf "$d"; mkdir -p "$d"
  git init -q -b master "$d"
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  git -C "$d" commit -q --allow-empty -m init
}

D_DEPLOY="$(mktemp -d)"; mkrepo "$D_DEPLOY"
B_DEPLOY="$(git -C "$D_DEPLOY" rev-parse HEAD)"
mkdir -p "$D_DEPLOY/deploy"
echo 'echo rollout' > "$D_DEPLOY/deploy/rollout.sh"
git -C "$D_DEPLOY" add -A; git -C "$D_DEPLOY" commit -qm "deploy: add rollout script"
DEPLOYABLE_OUT="$(bash "$PL" deployable "$D_DEPLOY" "$B_DEPLOY")"
assert "AC5: a deployable diff -> lib/gate/proof-ledger.sh deployable prints 'yes' (terminus engages)" \
  $([ "$DEPLOYABLE_OUT" = "yes" ] && echo 0 || echo 1)

D_INERT="$(mktemp -d)"; mkrepo "$D_INERT"
B_INERT="$(git -C "$D_INERT" rev-parse HEAD)"
echo '# just docs' > "$D_INERT/NOTES.md"
git -C "$D_INERT" add -A; git -C "$D_INERT" commit -qm "docs: add notes"
INERT_OUT="$(bash "$PL" deployable "$D_INERT" "$B_INERT")"
assert "AC5: an inert diff -> lib/gate/proof-ledger.sh deployable prints 'no' (terminus skipped)" \
  $([ "$INERT_OUT" = "no" ] && echo 0 || echo 1)

grep -qiE 'deployable|deploy/UAT terminus' "$MEGA_MD"; assert "AC5: mega.md documents the deploy/UAT terminus" $?
grep -qF 'lib/gate/proof-ledger.sh deployable' "$MEGA_MD"; assert "AC5: mega.md wires the SG-07 deployable verb verbatim" $?

# ============================================================
echo ""
echo "=== AC6: per-run merge config (MEGA_MERGE_POSTURE) honored ==="
# ============================================================
rm -f "$GH_CALLED_MARKER"
POSTURE_OUT="$(MEGA_MERGE_POSTURE=per-pr-review bash "$MM" merge 999 "$RID_GREEN" "$LANE" --execute 2>&1)"
POSTURE_RC=$?
assert_contains "AC6: MEGA_MERGE_POSTURE=per-pr-review dry-runs even WITH --execute on a passing gate" "DRY-RUN" "$POSTURE_OUT"
assert "AC6: per-pr-review posture exits 0 (advisory dry-run, not a block)" $([ "$POSTURE_RC" -eq 0 ] && echo 0 || echo 1)
assert "AC6: per-pr-review posture never calls gh even with --execute" $([ -f "$GH_CALLED_MARKER" ] && echo 1 || echo 0)

rm -f "$GH_CALLED_MARKER"
FLAG_OUT="$(bash "$MM" merge 999 "$RID_GREEN" "$LANE" --execute --posture=per-pr-review 2>&1)"
assert_contains "AC6: --posture= flag also honored (overrides default auto-to-final)" "DRY-RUN" "$FLAG_OUT"

grep -qiE 'MEGA_MERGE_POSTURE' "$MM"; assert "AC6: the posture knob is documented in mega-merge.sh" $?
grep -qiE 'auto-to-final' "$MEGA_MD" && grep -qiE 'per-pr-review' "$MEGA_MD"; assert "AC6: the posture knob is documented in mega.md" $?

echo ""
echo "=== $PASS/$TOTAL passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
