#!/usr/bin/env bash
# test-wave-rid-check.sh (ID-099)
# Pins the WAVE (parallel) path's START/rid emission. Before this fix, `_wave_run`'s spawn loop
# emitted ONLY an `executing` event and never called `_emit_start`, so a wave dispatch left ZERO
# START/rid records -- invisible to lane-telemetry, even though the serial path (cmd_run) already
# derives+records one via `_emit_start`. This suite is the wave-path twin of that serial coverage.
#
# All via the CLAUDE_CMD mock seam (no live LLM), a real throwaway `git init` repo (so _wave_run
# stands up REAL worktrees), and a real gate-ledger ledger dir via DWARVES_KIT_LOG_DIR.
set -uo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORCH="$KIT/lib/queue/orchestrate.sh"
GLEDGER="$KIT/lib/gate/gate-ledger.sh"
# shellcheck source=../lib/queue/orchestrate.sh
source "$ORCH"   # guard in orchestrate.sh keeps main from running when sourced; exposes _wave_run etc.

fails=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mk_git_mega() {  # repo-root
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name test
  git -C "$repo" commit -q --allow-empty -m init
}

make_goal() {  # megadir id glob branch-slug
  local mg="$1" id="$2" glob="$3" bslug="$4"
  mkdir -p "$mg/goals"
  {
    printf '# %s: sub-goal\n' "$id"
    printf '**Branch:** feat/%s\n' "$bslug"
    printf '\n## Touches\n- %s\n' "$glob"
  } > "$mg/goals/${id#SG-}-${id}.md"
}

# A goal file with NO **Branch:** header at all -- the no-derivable-rid case.
make_goal_no_branch() {  # megadir id glob
  local mg="$1" id="$2" glob="$3"
  mkdir -p "$mg/goals"
  {
    printf '# %s: sub-goal (no branch header)\n' "$id"
    printf '\n## Touches\n- %s\n' "$glob"
  } > "$mg/goals/${id#SG-}-${id}.md"
}

# Mock claude: emits a minimal stream-json transcript, then flips the named sub-goal's box in the
# SHARED roadmap via the locked flip CLI (mirrors test-wave-token-capture.sh's mock).
cat > "$TMP/claude-ridchk" <<'MOCK'
#!/usr/bin/env bash
prompt=$(cat)
id=$(printf '%s' "$prompt" | grep -oE 'SG-[0-9]+' | head -1)
cat <<JSON
{"type":"system","subtype":"init","note":"ridchk session start $id"}
{"type":"result","subtype":"success","message":{"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
JSON
bash "$ORCH" flip "$MEGADIR" "$id" >/dev/null 2>&1
MOCK
chmod +x "$TMP/claude-ridchk"

START_LINES_FOR() {  # logdir rid
  local logdir="$1" rid="$2"
  grep -c '| START |' "$logdir/runs/$rid.log" 2>/dev/null || echo 0
}

# ============ POSITIVE: 2-sub-goal wave -> TWO START records (previously zero) ============
WR="$TMP/wave-rid-repo"; mk_git_mega "$WR"
WM="$WR/mega"; mkdir -p "$WM"
cat > "$WM/ROADMAP.md" <<'EOF'
# Mega-goal: wave-rid-check
## Sub-goals
- [ ] SG-01 alpha , auto , PR #__
- [ ] SG-02 beta , auto , PR #__
EOF
echo "POINTER: resume from ROADMAP" > "$WM/POINTER_PROMPT.md"
make_goal "$WM" SG-01 "lib/ridchk-a/**" "rid-check-sg-01"
make_goal "$WM" SG-02 "lib/ridchk-b/**" "rid-check-sg-02"

LOGDIR_POS="$TMP/logs-pos"; mkdir -p "$LOGDIR_POS"
wrc=0
( export ORCH="$ORCH" MEGADIR="$WM" CLAUDE_FLAGS="" WAVE_CAP=2 CLAUDE_CMD="$TMP/claude-ridchk" \
    DWARVES_KIT_LOG_DIR="$LOGDIR_POS"
  _wave_run "$WM" "$WM/ROADMAP.md" ) > "$TMP/pos.out" 2>&1 || wrc=$?

S1=$(START_LINES_FOR "$LOGDIR_POS" "rid-check-sg-01")
S2=$(START_LINES_FOR "$LOGDIR_POS" "rid-check-sg-02")

if [ "$wrc" = 0 ] && [ "$S1" -ge 1 ] && [ "$S2" -ge 1 ]; then
  pass "wave-rid-check POSITIVE: both wave sub-goals recorded a START line (SG-01=$S1 SG-02=$S2), where the pre-fix wave path recorded zero"
else
  fail "wave-rid-check POSITIVE: rc=$wrc SG-01-START=$S1 SG-02-START=$S2"
  echo "--out--"; cat "$TMP/pos.out"
fi

echo "RUN-TABLE (wave START records, positive):"
echo "  SG-01 rid=rid-check-sg-01: $(grep '| START |' "$LOGDIR_POS/runs/rid-check-sg-01.log" 2>/dev/null | head -1)"
echo "  SG-02 rid=rid-check-sg-02: $(grep '| START |' "$LOGDIR_POS/runs/rid-check-sg-02.log" 2>/dev/null | head -1)"

# ============ NEGATIVE CONTROL A: SAME wave scenario, fix stubbed out -> ZERO START lines ============
# Demonstrates the fix's CAUSAL effect (not just post-fix presence): with the wave-path START
# emission disabled, the same 2-sub-goal wave run must produce NO START lines at all, even though
# the wave otherwise completes normally (box still flips). NC_SKIP_WAVE_START=1 is a test-only
# escape hatch wired into orchestrate.sh's wave spawn loop for exactly this purpose (mirrors
# NC_SKIP_WAVE_TOKENS from test-wave-token-capture.sh, ID-094).
WR2="$TMP/wave-rid-repo-nc"; mk_git_mega "$WR2"
WM2="$WR2/mega"; mkdir -p "$WM2"
cat > "$WM2/ROADMAP.md" <<'EOF'
# Mega-goal: wave-rid-check-nc
## Sub-goals
- [ ] SG-01 alpha , auto , PR #__
- [ ] SG-02 beta , auto , PR #__
EOF
echo "POINTER: resume from ROADMAP" > "$WM2/POINTER_PROMPT.md"
make_goal "$WM2" SG-01 "lib/ridchk-a/**" "rid-check-nc-sg-01"
make_goal "$WM2" SG-02 "lib/ridchk-b/**" "rid-check-nc-sg-02"

LOGDIR_NC="$TMP/logs-nc"; mkdir -p "$LOGDIR_NC"
ncrc=0
( export ORCH="$ORCH" MEGADIR="$WM2" CLAUDE_FLAGS="" WAVE_CAP=2 CLAUDE_CMD="$TMP/claude-ridchk" \
    DWARVES_KIT_LOG_DIR="$LOGDIR_NC" NC_SKIP_WAVE_START=1
  _wave_run "$WM2" "$WM2/ROADMAP.md" ) > "$TMP/nc.out" 2>&1 || ncrc=$?

N1=$(START_LINES_FOR "$LOGDIR_NC" "rid-check-nc-sg-01")
N2=$(START_LINES_FOR "$LOGDIR_NC" "rid-check-nc-sg-02")
box1=$(_sg_line "$WM2/ROADMAP.md" SG-01); box2=$(_sg_line "$WM2/ROADMAP.md" SG-02)
both_flipped=0
{ { printf '%s' "$box1" 2>/dev/null || :; } | grep -q '^\- \[x\]' && { printf '%s' "$box2" 2>/dev/null || :; } | grep -q '^\- \[x\]'; } && both_flipped=1

if [ "$ncrc" = 0 ] && [ "$N1" = 0 ] && [ "$N2" = 0 ] && [ "$both_flipped" = 1 ]; then
  pass "wave-rid-check NEGATIVE CONTROL A: pre-fix-equivalent code (START call stubbed) completes the SAME wave (both boxes flip) but records ZERO START lines -- causal effect demonstrated"
else
  fail "wave-rid-check NEGATIVE CONTROL A: expected 0 START lines + both boxes flipped, got SG-01=$N1 SG-02=$N2 both_flipped=$both_flipped rc=$ncrc"
  echo "--out--"; cat "$TMP/nc.out"
fi

# ============ NEGATIVE CONTROL B: no-derivable-rid dispatch is LOUDLY flagged, not silent ============
# A goal file with no `**Branch:**` header can't derive a rid. `_emit_start` (shared by both paths,
# untouched by this fix) WARNs to stderr and skips the START write -- advisory, never a silent
# no-op and never an abort of the wave itself (pinned: stays advisory, ID-099 scope explicitly
# excludes turning this into a hard block).
WR3="$TMP/wave-rid-repo-norid"; mk_git_mega "$WR3"
WM3="$WR3/mega"; mkdir -p "$WM3"
cat > "$WM3/ROADMAP.md" <<'EOF'
# Mega-goal: wave-rid-check-norid
## Sub-goals
- [ ] SG-01 alpha , auto , PR #__
EOF
echo "POINTER: resume from ROADMAP" > "$WM3/POINTER_PROMPT.md"
make_goal_no_branch "$WM3" SG-01 "lib/ridchk-norid/**"

LOGDIR_NORID="$TMP/logs-norid"; mkdir -p "$LOGDIR_NORID"
nrrc=0
( export ORCH="$ORCH" MEGADIR="$WM3" CLAUDE_FLAGS="" WAVE_CAP=2 CLAUDE_CMD="$TMP/claude-ridchk" \
    DWARVES_KIT_LOG_DIR="$LOGDIR_NORID"
  _wave_run "$WM3" "$WM3/ROADMAP.md" ) > "$TMP/norid.out" 2>&1 || nrrc=$?

box3=$(_sg_line "$WM3/ROADMAP.md" SG-01)
box3_flipped=0; { printf '%s' "$box3" 2>/dev/null || :; } | grep -q '^\- \[x\]' && box3_flipped=1
warned=0; grep -q "WARN: SG-01 goal file has no '\*\*Branch:\*\*' header" "$TMP/norid.out" && warned=1
# No ledger dir for this run at all (no rid was ever derivable to key a file by).
ledger_files=$(find "$LOGDIR_NORID/runs" -type f 2>/dev/null | wc -l | tr -d ' ')

if [ "$nrrc" = 0 ] && [ "$box3_flipped" = 1 ] && [ "$warned" = 1 ] && [ "$ledger_files" = 0 ]; then
  pass "wave-rid-check NEGATIVE CONTROL B: no-derivable-rid wave dispatch still completes (box flips) and is LOUDLY WARNed on stderr, not silently untracked; zero ledger files written for it (advisory, no wrong-rid write either)"
else
  fail "wave-rid-check NEGATIVE CONTROL B: expected rc=0 flipped=1 warned=1 ledger_files=0, got rc=$nrrc flipped=$box3_flipped warned=$warned ledger_files=$ledger_files"
  echo "--out--"; cat "$TMP/norid.out"
fi

echo "----"
[ "$fails" = 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
