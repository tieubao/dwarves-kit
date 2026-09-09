#!/usr/bin/env bash
# test-board-promote.sh -- lib/board/bin/add-backlog (operator entry: `board promote`).
#
# Proves the judgment-free-URL guard: a staged block whose Intent is nothing but its
# own source link (Approach/Source hold the same URL) gets refused instead of promoted,
# with a one-line message naming the block and the intake door to use instead. A block
# that carries real reasoning in Intent still promotes normally, and refusal survives
# whitespace/trailing-slash differences between the two URL renderings.
#
# Run: bash tests/test-board-promote.sh

set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADD_BACKLOG="$KIT_DIR/lib/board/bin/add-backlog"

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
chk() {
  TOTAL=$((TOTAL+1))
  if [ "$2" -eq 0 ] 2>/dev/null; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1))
  else echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL+1)); fi
}
chk_has() { chk "$1" "$(printf '%s' "$2" | grep -qF -- "$3"; echo $?)"; }
chk_not_has() { chk "$1" "$(printf '%s' "$2" | grep -qF -- "$3"; [ $? -ne 0 ]; echo $?)"; }

TODAY="$(date +%Y-%m-%d)"   # fixtures must be fresh: promote refuses a stale block
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/dk-board-promote-test.XXXXXX")"
TMPD="$(cd "$TMPD" && pwd)"
trap 'rm -rf "$TMPD"' EXIT

new_board() {
  local f="$1"
  cat > "$f" <<'EOF'
| ID | Item | Notes | Status |
|---|---|---|---|
EOF
}

# ============================================================
echo "== positive: a bare-URL block (Intent == Approach) is refused, not promoted =="
# ============================================================
BOARD1="$TMPD/board1/BACKLOG.md"; mkdir -p "$(dirname "$BOARD1")"; new_board "$BOARD1"
STAGE1="$TMPD/board1/backlog-staging.md"
cat > "$STAGE1" <<EOF
# Backlog staging (auto)

## [staged] x.com
- Intent: https://x.com/someone/status/123
- Approach: https://x.com/someone/status/123
- Tags: #u-lo #f-hi
- Source: intake-sweep safari-collections $TODAY
EOF
OUT1="$(BACKLOG_STAGE_BACKLOG="$BOARD1" BACKLOG_STAGE_STAGING="$STAGE1" python3 "$ADD_BACKLOG" 1 2>&1)"; RC1=$?
chk "refused: exit 1 (nothing promoted)" "$([ "$RC1" -eq 1 ]; echo $?)"
chk_has "refused: names the block" "$OUT1" "x.com"
chk_has "refused: points at the intake door" "$OUT1" "digest / work-intake"
chk_has "refused: staging block still [staged]" "$(cat "$STAGE1")" "## [staged] x.com"
chk_not_has "refused: board has no new row" "$(cat "$BOARD1")" "ID-"

# ============================================================
echo "== negative: a block with real judgment in Intent promotes normally =="
# ============================================================
BOARD2="$TMPD/board2/BACKLOG.md"; mkdir -p "$(dirname "$BOARD2")"; new_board "$BOARD2"
STAGE2="$TMPD/board2/backlog-staging.md"
cat > "$STAGE2" <<EOF
# Backlog staging (auto)

## [staged] Ship the seam table report
- Intent: cut inherited Opus spend by routing Explore subagents to Haiku
- Approach: https://example.com/some-source-link
- Tags: #u-mid #f-hi
- Home: dwarves-kit
- Source: session $TODAY
EOF
OUT2="$(BACKLOG_STAGE_BACKLOG="$BOARD2" BACKLOG_STAGE_STAGING="$STAGE2" python3 "$ADD_BACKLOG" 1 2>&1)"; RC2=$?
chk "normal: exit 0" "$([ "$RC2" -eq 0 ]; echo $?)"
chk_has "normal: prints promoted" "$OUT2" "promoted ID-"
chk_has "normal: staging block flips to promoted" "$(cat "$STAGE2")" "## [promoted ID-"
chk_has "normal: board gained the row" "$(cat "$BOARD2")" "Ship the seam table report"

# ============================================================
echo "== whitespace/trailing-slash normalization still catches the refusal =="
# ============================================================
BOARD3="$TMPD/board3/BACKLOG.md"; mkdir -p "$(dirname "$BOARD3")"; new_board "$BOARD3"
STAGE3="$TMPD/board3/backlog-staging.md"
cat > "$STAGE3" <<EOF
# Backlog staging (auto)

## [staged] Animated Math
- Intent: https://www.youtube.com/watch?v=abc123/
- Approach:   https://www.youtube.com/watch?v=abc123
- Tags: #u-lo #f-hi
- Source: intake-sweep safari-collections $TODAY
EOF
OUT3="$(BACKLOG_STAGE_BACKLOG="$BOARD3" BACKLOG_STAGE_STAGING="$STAGE3" python3 "$ADD_BACKLOG" 1 2>&1)"; RC3=$?
chk "normalization: exit 1 (still refused)" "$([ "$RC3" -eq 1 ]; echo $?)"
chk_has "normalization: names the block" "$OUT3" "Animated Math"
chk_has "normalization: staging block still [staged]" "$(cat "$STAGE3")" "## [staged] Animated Math"

# ============================================================
echo "== mixed batch: refused block skipped, normal block still promotes (exit 0) =="
# ============================================================
BOARD4="$TMPD/board4/BACKLOG.md"; mkdir -p "$(dirname "$BOARD4")"; new_board "$BOARD4"
STAGE4="$TMPD/board4/backlog-staging.md"
cat > "$STAGE4" <<EOF
# Backlog staging (auto)

## [staged] x.com
- Intent: https://x.com/someone/status/999
- Approach: https://x.com/someone/status/999
- Tags: #u-lo #f-hi
- Source: intake-sweep safari-collections $TODAY

## [staged] Route Explore subagents to Haiku
- Intent: cut inherited Opus spend
- Approach: switch the agentModelOverrides default tier
- Tags: #u-mid #f-hi
- Home: dwarves-kit
- Source: session $TODAY
EOF
OUT4="$(BACKLOG_STAGE_BACKLOG="$BOARD4" BACKLOG_STAGE_STAGING="$STAGE4" python3 "$ADD_BACKLOG" all 2>&1)"; RC4=$?
chk "mixed: exit 0 (one promoted)" "$([ "$RC4" -eq 0 ]; echo $?)"
chk_has "mixed: refused the URL-only block" "$OUT4" "x.com"
chk_has "mixed: promoted the real one" "$OUT4" "promoted ID-"
chk_has "mixed: URL-only block stays [staged]" "$(cat "$STAGE4")" "## [staged] x.com"
chk_has "mixed: real block flips to promoted" "$(cat "$STAGE4")" "## [promoted ID-"

# ============================================================
echo "== ID-305 aging: a block staged past the window is refused, fresh ones promote =="
# ============================================================
# ID-294 measured 19 of 69 candidates finished inside a 16-day triage gap. The promote path
# never looked at the staging date, so decayed work landed on the board as new.
if date -v-1d >/dev/null 2>&1; then
  days_ago() { date -u -v-"$1"d +%Y-%m-%d; }
else
  days_ago() { date -u -d "-$1 days" +%Y-%m-%d; }
fi
OLD="$(days_ago 40)"; FRESH="$(days_ago 3)"
BOARD5="$TMPD/board5/BACKLOG.md"; mkdir -p "$(dirname "$BOARD5")"; new_board "$BOARD5"
STAGE5="$TMPD/board5/backlog-staging.md"
cat > "$STAGE5" <<EOF
# Backlog staging (auto)

## [staged] Long forgotten candidate
- Intent: real reasoning that has aged out
- Approach: do the thing
- Tags: #u-mid #f-hi
- Source: session $OLD

## [staged] Fresh candidate
- Intent: real reasoning staged this week
- Approach: do the other thing
- Tags: #u-mid #f-hi
- Source: session $FRESH

## [staged] Undated candidate
- Intent: real reasoning with no parseable date
- Approach: do the third thing
- Tags: #u-mid #f-hi
- Source: session (undated)
EOF
OUT5="$(BACKLOG_STAGE_BACKLOG="$BOARD5" BACKLOG_STAGE_STAGING="$STAGE5" python3 "$ADD_BACKLOG" all 2>&1)"
chk_has "aging: refuses the aged-out block" "$OUT5" "Long forgotten candidate"
chk_has "aging: the reason names the age and the override" "$OUT5" "BOARD_PROMOTE_STALE_OK=1"
chk_has "aging: aged-out block stays [staged]" "$(cat "$STAGE5")" "## [staged] Long forgotten candidate"
# NEGATIVE CONTROL: the check must catch age, not every block in the batch.
chk_has "aging NC: a fresh block still promotes" "$(cat "$STAGE5")" "## [promoted ID-"
chk_not_has "aging NC: the fresh block is not refused" "$OUT5" "Fresh candidate'"
chk_not_has "aging NC: an undated block is not refused (age unknown is not stale)" "$OUT5" "Undated candidate'"

BOARD6="$TMPD/board6/BACKLOG.md"; mkdir -p "$(dirname "$BOARD6")"; new_board "$BOARD6"
STAGE6="$TMPD/board6/backlog-staging.md"
cat > "$STAGE6" <<EOF
# Backlog staging (auto)

## [staged] Long forgotten candidate
- Intent: real reasoning that has aged out
- Approach: do the thing
- Tags: #u-mid #f-hi
- Source: session $OLD
EOF
OUT6="$(BOARD_PROMOTE_STALE_OK=1 BACKLOG_STAGE_BACKLOG="$BOARD6" BACKLOG_STAGE_STAGING="$STAGE6" python3 "$ADD_BACKLOG" all 2>&1)"
chk_has "aging: BOARD_PROMOTE_STALE_OK=1 promotes the same block" "$OUT6" "promoted ID-"

# ============================================================
echo "== ID-305 home resolution: a path cited against the wrong repo is refused =="
# ============================================================
# ID-294 candidate 35 targeted a hook in `dotfiles` that only ever lived in the kit.
HOMES="$TMPD/homes"; mkdir -p "$HOMES/dotfiles"; git -C "$HOMES/dotfiles" init -q 2>/dev/null
REPO7="$TMPD/repo7"; mkdir -p "$REPO7/_meta" "$REPO7/hooks"
git -C "$REPO7" init -q 2>/dev/null
echo "hook body" > "$REPO7/hooks/rustfmt-guard.sh"
new_board "$REPO7/_meta/BACKLOG.md"
cat > "$REPO7/_meta/backlog-staging.md" <<EOF
# Backlog staging (auto)

## [staged] Widen the rustfmt guard
- Intent: the guard in hooks/rustfmt-guard.sh only covers one path
- Approach: extend the glob
- Tags: #u-mid #f-hi
- Home: dotfiles
- Source: session $FRESH

## [staged] Widen the unwritten guard
- Intent: the future guard in hooks/not-yet-written.sh needs a glob
- Approach: write it
- Tags: #u-mid #f-hi
- Home: dotfiles
- Source: session $FRESH
EOF
OUT7="$(cd "$REPO7" && BACKLOG_PROMOTE_HOMES="$HOMES" BACKLOG_STAGE_BACKLOG="$REPO7/_meta/BACKLOG.md" \
  BACKLOG_STAGE_STAGING="$REPO7/_meta/backlog-staging.md" python3 "$ADD_BACKLOG" all 2>&1)"
chk_has "home: refuses the mis-homed block" "$OUT7" "Widen the rustfmt guard"
chk_has "home: the reason names the cited path" "$OUT7" "hooks/rustfmt-guard.sh"
# NEGATIVE CONTROL: a cited path that exists in NEITHER repo is future work, not a wrong home.
chk_not_has "home NC: a not-yet-written path is not refused" "$OUT7" "Widen the unwritten guard'"
chk_has "home NC: that block promotes" "$OUT7" "promoted ID-"
# NEGATIVE CONTROL: an unresolvable Home is unknown, not wrong.
cat > "$REPO7/_meta/backlog-staging.md" <<EOF
# Backlog staging (auto)

## [staged] Widen the rustfmt guard
- Intent: the guard in hooks/rustfmt-guard.sh only covers one path
- Approach: extend the glob
- Tags: #u-mid #f-hi
- Home: no-such-repo
- Source: session $FRESH
EOF
OUT8="$(cd "$REPO7" && BACKLOG_PROMOTE_HOMES="$HOMES" BACKLOG_STAGE_BACKLOG="$REPO7/_meta/BACKLOG.md" \
  BACKLOG_STAGE_STAGING="$REPO7/_meta/backlog-staging.md" python3 "$ADD_BACKLOG" all 2>&1)"
chk_has "home NC: an unresolvable Home promotes (unknown is not wrong)" "$OUT8" "promoted ID-"

echo ""
echo "== $TOTAL run, $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
