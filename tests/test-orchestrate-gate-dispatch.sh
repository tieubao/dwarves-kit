#!/usr/bin/env bash
# test-orchestrate-gate-dispatch.sh
# Pins the two orchestrate.sh defects a real 5-sub-goal run surfaced:
#   A. Merged-PR box reconciliation. A worker flips its ROADMAP box INSIDE its PR; the PR merges;
#      the driver read the LOCAL (behind) checkout and halted a healthy run with "did not check its
#      ROADMAP box". The driver must reconcile against origin/<default> before halting -- and only
#      accept a remote box whose line also carries a real `PR #<n>` (no-self-claim unchanged).
#   B. Gate sub-goal DISPATCH. The documented contract is that a `gate` sub-goal's worker DOES the
#      work, opens a DRAFT PR, marks it, and the loop holds for a HUMAN MERGE. The driver stopped
#      BEFORE running it, so the work never happened. MEGA_GATE_DISPATCH=0 restores the old posture.
# Follows the existing fixture pattern: a mega-goal dir + a fake `claude` on PATH via CLAUDE_CMD.
set -uo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORCH="$KIT/lib/queue/orchestrate.sh"
fails=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_FLAGS=""

# A mega-goal dir: SG-01 auto, SG-02 gate. Goal files declare a Branch: so _sg_pr_url has one.
mk_megagoal() {  # dir
  local d="$1"
  mkdir -p "$d/goals"
  cat > "$d/ROADMAP.md" <<'EOF'
# Mega-goal: gate-dispatch fixture
## Sub-goals
- [ ] SG-01 build the thing , auto , PR #__
- [ ] SG-02 wire the deploy , gate , PR #__
EOF
  echo "POINTER: resume from ROADMAP" > "$d/POINTER_PROMPT.md"
  printf '**Branch:** feat/sg-one\nDone = the thing builds\n' > "$d/goals/01-build.md"
  printf '**Branch:** feat/sg-two\nDone = the deploy is wired\n' > "$d/goals/02-wire.md"
}

# A fake `gh` whose `pr view <branch> --json url` answers from $GH_PRS ("<branch> <url>" per line).
mk_mock_gh() {
  cat > "$TMP/gh" <<'EOF'
#!/usr/bin/env bash
# args: pr view <branch> --json url -q .url
[ "${1:-}" = pr ] && [ "${2:-}" = view ] || exit 1
awk -v b="${3:-}" '$1==b {print $2; found=1} END{exit !found}' "$GH_PRS" 2>/dev/null
EOF
  chmod +x "$TMP/gh"
}

# ===================== A. merged-PR box reconciliation =====================
# A real two-repo fixture: `upstream` is the remote; `local` is the driver's checkout on master.
# The mock session commits + pushes the box flip (with `-- PR #629`) to the remote WITHOUT touching
# the local checkout -- exactly the merged-PR shape. The local box therefore reads unchecked.
mk_repo_pair() {  # base
  local base="$1"
  git init -q --bare "$base/upstream.git"
  git init -q "$base/seed"
  git -C "$base/seed" config user.email t@t.t; git -C "$base/seed" config user.name t
  mkdir -p "$base/seed/mega/goals"
  cat > "$base/seed/mega/ROADMAP.md" <<'EOF'
# Mega-goal: reconcile fixture
## Sub-goals
- [ ] SG-01 ported thing , auto , PR #__
EOF
  echo "POINTER: resume from ROADMAP" > "$base/seed/mega/POINTER_PROMPT.md"
  printf '**Branch:** feat/sg-one\nDone = ported\n' > "$base/seed/mega/goals/01-port.md"
  git -C "$base/seed" add -A >/dev/null
  git -C "$base/seed" commit -qm init
  git -C "$base/seed" branch -M master
  git -C "$base/seed" remote add origin "$base/upstream.git"
  git -C "$base/seed" push -q origin master
  git clone -q "$base/upstream.git" "$base/local"
  git -C "$base/local" config user.email t@t.t; git -C "$base/local" config user.name t
}

# The mock: pushes the flipped box to the remote, leaves the driver's checkout untouched.
# $FLIP_TAIL is what follows the id on the flipped line (with or without a PR #).
mk_mock_merge_pr() {
  cat > "$TMP/claude-mergepr" <<'EOF'
#!/usr/bin/env bash
# env: PAIR (fixture base), FLIP_TAIL
prompt=$(cat)
id=$(printf '%s' "$prompt" | grep -oE 'SG-[0-9]+' | head -1)
wt="$PAIR/pusher"
rm -rf "$wt"
git clone -q "$PAIR/upstream.git" "$wt"
git -C "$wt" config user.email t@t.t; git -C "$wt" config user.name t
awk -v id="$id" -v tail="$FLIP_TAIL" \
  '{ if ($0 ~ ("^- \\[ \\] " id " ")) print "- [x] " id " " tail; else print }' \
  "$wt/mega/ROADMAP.md" > "$wt/mega/ROADMAP.md.tmp" && mv "$wt/mega/ROADMAP.md.tmp" "$wt/mega/ROADMAP.md"
git -C "$wt" commit -qam "flip $id"
git -C "$wt" push -q origin master
EOF
  chmod +x "$TMP/claude-mergepr"
}
mk_mock_merge_pr

# --- A1: a remote box carrying `-- PR #629` is ACCEPTED (the false halt is gone) ---
P1="$TMP/pair1"; mkdir -p "$P1"; mk_repo_pair "$P1"
rc=0
( export PAIR="$P1" FLIP_TAIL="ported thing , auto , PR #__ -- PR #629"
  TIER4_CLOSE=0 CLAUDE_CMD="$TMP/claude-mergepr" bash "$ORCH" run "$P1/local/mega" ) \
  > "$TMP/rec1.out" 2>&1 || rc=$?
[ "$rc" = 0 ] && pass "A1: merged-PR box flip accepted; run exits 0 (no false halt)" \
  || { fail "A1: run exited $rc"; cat "$TMP/rec1.out"; }
grep -q 'reconcile' "$TMP/rec1.out" \
  && pass "A1: driver logs what it reconciled" || { fail "A1: no reconcile log line"; cat "$TMP/rec1.out"; }
grep -q 'did not check its ROADMAP box' "$TMP/rec1.out" \
  && { fail "A1: still halted on the stale local box"; cat "$TMP/rec1.out"; } \
  || pass "A1: no stale-box guardrail halt"
grep -q '^- \[x\] SG-01' "$P1/local/mega/ROADMAP.md" \
  && pass "A1: clean checkout was fast-forwarded to origin/master" \
  || { fail "A1: local checkout not fast-forwarded"; cat "$P1/local/mega/ROADMAP.md"; }

# --- A2 [NEGATIVE CONTROL]: a remote box with NO `PR #N` is REJECTED (no self-claim kept) ---
P2="$TMP/pair2"; mkdir -p "$P2"; mk_repo_pair "$P2"
rc=0
( export PAIR="$P2" FLIP_TAIL="ported thing , auto"
  TIER4_CLOSE=0 CLAUDE_CMD="$TMP/claude-mergepr" bash "$ORCH" run "$P2/local/mega" ) \
  > "$TMP/rec2.out" 2>&1 || rc=$?
{ [ "$rc" != 0 ] && grep -q 'did not check its ROADMAP box' "$TMP/rec2.out"; } \
  && pass "A2 (neg control): a bare remote box (no PR #N) still halts the loop" \
  || { fail "A2: bare remote box wrongly accepted (rc=$rc)"; cat "$TMP/rec2.out"; }

# --- A3 [NEGATIVE CONTROL]: a DIRTY tree is never force-pulled ---
P3="$TMP/pair3"; mkdir -p "$P3"; mk_repo_pair "$P3"
echo "operator work in progress" > "$P3/local/dirty.txt"
git -C "$P3/local" add dirty.txt
head_before=$(git -C "$P3/local" rev-parse HEAD)
rc=0
( export PAIR="$P3" FLIP_TAIL="ported thing , auto , PR #__ -- PR #700"
  TIER4_CLOSE=0 CLAUDE_CMD="$TMP/claude-mergepr" bash "$ORCH" run "$P3/local/mega" ) \
  > "$TMP/rec3.out" 2>&1 || rc=$?
{ [ "$rc" = 0 ] && grep -q 'not fast-forwardable' "$TMP/rec3.out" \
  && grep -q '^- \[x\] SG-01' "$P3/local/mega/ROADMAP.md"; } \
  && pass "A3: dirty tree read from origin; only the merged box line is mirrored locally" \
  || { fail "A3: dirty tree handling wrong (rc=$rc)"; cat "$TMP/rec3.out"; git -C "$P3/local" status --porcelain; }
# The point of the dirty path: the driver never force-pulls the operator's work away.
git -C "$P3/local" diff --cached --name-only | grep -q dirty.txt \
  && pass "A3 (neg control): the operator's staged work survives (no force-pull)" || fail "A3: staged work lost"
[ "$(git -C "$P3/local" rev-parse HEAD)" = "$head_before" ] \
  && pass "A3 (neg control): HEAD was NOT fast-forwarded over the dirty tree" \
  || fail "A3: dirty tree was force-pulled (HEAD moved)"

# --- A4 [NEGATIVE CONTROL]: no git repo at all -> the halt is unchanged ---
NG="$TMP/mg-nogit"; mk_megagoal "$NG"
cat > "$TMP/claude-noflip" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo "did work, forgot the box"
EOF
chmod +x "$TMP/claude-noflip"
rc=0
CLAUDE_CMD="$TMP/claude-noflip" bash "$ORCH" run "$NG" > "$TMP/rec4.out" 2>&1 || rc=$?
{ [ "$rc" != 0 ] && grep -q 'did not check its ROADMAP box' "$TMP/rec4.out"; } \
  && pass "A4 (neg control): outside a git repo the no-self-claim halt is byte-identical" \
  || { fail "A4: non-repo halt changed (rc=$rc)"; cat "$TMP/rec4.out"; }

# ===================== B. gate sub-goal dispatch =====================
mk_mock_gh
# The mock records every id it was handed and flips ONLY auto boxes (a gate worker must not flip).
cat > "$TMP/claude-gate" <<'EOF'
#!/usr/bin/env bash
# env: RUNLOG, GATE_RM, PROMPTDIR
prompt=$(cat)
id=$(printf '%s' "$prompt" | grep -oE 'SG-[0-9]+' | head -1)
echo "INVOKED $id" >> "$RUNLOG"
printf '%s' "$prompt" > "$PROMPTDIR/$id.prompt"
case "$id" in
  SG-02) : ;;   # gate sub-goal: opens a PR, never flips its own box
  *) awk -v id="$id" '{ if ($0 ~ ("^- \\[ \\] " id " ")) sub(/\[ \]/, "[x]"); print }' \
       "$GATE_RM" > "$GATE_RM.tmp" && mv "$GATE_RM.tmp" "$GATE_RM" ;;
esac
EOF
chmod +x "$TMP/claude-gate"

run_gate_fixture() {  # dir outfile [extra-env...]
  local d="$1" out="$2"; shift 2
  : > "$TMP/runlog"; mkdir -p "$TMP/prompts"
  RUNLOG="$TMP/runlog" GATE_RM="$d/ROADMAP.md" PROMPTDIR="$TMP/prompts" \
    GH_CMD="$TMP/gh" GH_PRS="$TMP/prs" TIER4_CLOSE=0 CLAUDE_CMD="$TMP/claude-gate" \
    env "$@" bash "$ORCH" run "$d" > "$out" 2>&1
}

# --- B1: default -> the gate sub-goal IS dispatched, then the loop holds on its PR ---
printf 'feat/sg-two https://github.com/o/r/pull/42\n' > "$TMP/prs"
DG="$TMP/mg-gate"; mk_megagoal "$DG"
rc=0; run_gate_fixture "$DG" "$TMP/b1.out" || rc=$?
[ "$rc" = 0 ] && pass "B1: gate dispatch exits 0 (clean human-hold)" \
  || { fail "B1: rc=$rc"; cat "$TMP/b1.out"; }
grep -q 'INVOKED SG-02' "$TMP/runlog" \
  && pass "B1: the gate sub-goal actually ran" || { fail "B1: gate sub-goal never dispatched"; cat "$TMP/runlog"; }
grep -q 'https://github.com/o/r/pull/42' "$TMP/b1.out" \
  && pass "B1: the STOP-for-human line carries the PR URL" || { fail "B1: no PR URL in the stop line"; cat "$TMP/b1.out"; }
grep -q 'STOP: SG-02 is a gate sub-goal' "$TMP/b1.out" \
  && pass "B1: STOP-for-human line present" || { fail "B1: no STOP line"; cat "$TMP/b1.out"; }
grep -q '^- \[ \] SG-02' "$DG/ROADMAP.md" \
  && pass "B1: the gate sub-goal's box is left for the human merge to check" || fail "B1: gate box flipped"

# --- B1b: the gate sub-goal's PROMPT carries the held-PR contract ---
{ grep -q 'HELD SUB-GOAL (gate)' "$TMP/prompts/SG-02.prompt" \
  && grep -qi 'draft' "$TMP/prompts/SG-02.prompt" \
  && grep -q 'mega-merge.sh mark' "$TMP/prompts/SG-02.prompt" \
  && grep -q 'Do NOT merge' "$TMP/prompts/SG-02.prompt"; } \
  && pass "B1b: gate prompt injects draft-PR + mark + do-not-merge + do-not-flip" \
  || { fail "B1b: gate prompt contract missing"; cat "$TMP/prompts/SG-02.prompt"; }
grep -q 'HELD SUB-GOAL' "$TMP/prompts/SG-01.prompt" \
  && fail "B1b (neg control): the auto sub-goal's prompt was polluted with the held contract" \
  || pass "B1b (neg control): the auto sub-goal's prompt is unchanged"

# --- B2 [NEGATIVE CONTROL]: gate session opened NO PR -> guardrail halt, same as an unflipped box ---
: > "$TMP/prs"
DG2="$TMP/mg-gate-nopr"; mk_megagoal "$DG2"
rc=0; run_gate_fixture "$DG2" "$TMP/b2.out" || rc=$?
{ [ "$rc" != 0 ] && grep -q 'opened no PR' "$TMP/b2.out"; } \
  && pass "B2 (neg control): a gate session with no PR halts the loop (no self-claim)" \
  || { fail "B2: no-PR case did not halt (rc=$rc)"; cat "$TMP/b2.out"; }

# --- B3: MEGA_GATE_DISPATCH=0 restores the stop-BEFORE-running behavior ---
printf 'feat/sg-two https://github.com/o/r/pull/42\n' > "$TMP/prs"
DG3="$TMP/mg-gate-off"; mk_megagoal "$DG3"
rc=0; run_gate_fixture "$DG3" "$TMP/b3.out" MEGA_GATE_DISPATCH=0 || rc=$?
{ [ "$rc" = 0 ] && grep -q 'open/await its PR for review' "$TMP/b3.out" \
  && ! grep -q 'INVOKED SG-02' "$TMP/runlog"; } \
  && pass "B3: MEGA_GATE_DISPATCH=0 stops before running the gate sub-goal (escape hatch)" \
  || { fail "B3: escape hatch wrong (rc=$rc)"; cat "$TMP/b3.out"; cat "$TMP/runlog"; }

# --- B4: gate! is dispatched too, then halts the whole loop ---
printf 'feat/sg-two https://github.com/o/r/pull/77\n' > "$TMP/prs"
DG4="$TMP/mg-gatebang"; mk_megagoal "$DG4"
sed -i.bak 's/, gate ,/, gate! ,/' "$DG4/ROADMAP.md"
rc=0; run_gate_fixture "$DG4" "$TMP/b4.out" || rc=$?
{ [ "$rc" = 0 ] && grep -q 'INVOKED SG-02' "$TMP/runlog" \
  && grep -q 'STOP (gate!)' "$TMP/b4.out" && grep -q 'pull/77' "$TMP/b4.out"; } \
  && pass "B4: gate! is dispatched, then halts the whole loop with its PR URL" \
  || { fail "B4: gate! dispatch wrong (rc=$rc)"; cat "$TMP/b4.out"; }
grep -q 'HELD SUB-GOAL (gate!)' "$TMP/prompts/SG-02.prompt" \
  && pass "B4: gate! prompt carries the held-PR contract" || fail "B4: gate! prompt contract missing"

# --- B5: gate! under WAVE_CAP=2 is dispatched first and nothing waves alongside it ---
printf 'feat/sg-one https://github.com/o/r/pull/88\n' > "$TMP/prs"
DG5="$TMP/mg-gatebang-wave"; mk_megagoal "$DG5"
cat > "$DG5/ROADMAP.md" <<'EOF'
# Mega-goal: gate! under a wave
## Sub-goals
- [ ] SG-01 halt-all , gate! , PR #__
- [ ] SG-02 wire the deploy , auto , PR #__
EOF
printf '**Branch:** feat/sg-one\nDone = halt\n\n## Touches\nlib/a/**\n' > "$DG5/goals/01-build.md"
printf '**Branch:** feat/sg-two\nDone = wired\n\n## Touches\nlib/b/**\n' > "$DG5/goals/02-wire.md"
rc=0; run_gate_fixture "$DG5" "$TMP/b5.out" WAVE_CAP=2 || rc=$?
{ [ "$rc" = 0 ] && grep -q 'INVOKED SG-01' "$TMP/runlog" && ! grep -q 'INVOKED SG-02' "$TMP/runlog" \
  && grep -q 'STOP (gate!)' "$TMP/b5.out"; } \
  && pass "B5: under WAVE_CAP=2 the gate! sub-goal runs and the wave quiesces around it" \
  || { fail "B5: gate! wave handling wrong (rc=$rc)"; cat "$TMP/b5.out"; cat "$TMP/runlog"; }

# --- B6: --dry-run names the dispatch-then-hold plan ---
DG6="$TMP/mg-gate-dry"; mk_megagoal "$DG6"
out=$(bash "$ORCH" run "$DG6" --dry-run 2>&1)
{ trap '' PIPE; printf '%s' "$out" 2>/dev/null || :; } | grep -q 'SG-02 (gate, dispatch then hold for human merge)' \
  && pass "B6: dry-run plan says 'gate, dispatch then hold for human merge'" \
  || { fail "B6: dry-run plan wrong"; printf '%s\n' "$out"; }
out=$(MEGA_GATE_DISPATCH=0 bash "$ORCH" run "$DG6" --dry-run 2>&1)
{ trap '' PIPE; printf '%s' "$out" 2>/dev/null || :; } | grep -q 'SG-02 (gate)' \
  && pass "B6 (neg control): MEGA_GATE_DISPATCH=0 dry-run keeps the plain '(gate)' label" \
  || { fail "B6 neg control wrong"; printf '%s\n' "$out"; }

echo
if [ "$fails" = 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; fi
exit "$fails"
