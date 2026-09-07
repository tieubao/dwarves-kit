#!/usr/bin/env bash
# test-staging-stage.sh -- SPEC-249 TASK-003: `python3 lib/learn/staging-format.py stage`,
# the one staging WRITER (dedupe + render_block + append in a single process). See
# `### Interfaces` `staging-format.py stage` in docs/specs/SPEC-249-estate-seams.md,
# edge cases 18, 19, 22, 23, DEC-007.
#
# Run: bash tests/test-staging-stage.sh

set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SF="$KIT_DIR/lib/learn/staging-format.py"

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
chk() {
  TOTAL=$((TOTAL+1))
  if [ "$2" -eq 0 ] 2>/dev/null; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1))
  else echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL+1)); fi
}
chk_has() { chk "$1" "$({ trap '' PIPE; printf '%s' "$2" 2>/dev/null || :; } | grep -qF -- "$3"; echo $?)"; }

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/dk-staging-stage-test.XXXXXX")"
TMPD="$(cd "$TMPD" && pwd)"
trap 'chmod -R u+w "$TMPD" 2>/dev/null; rm -rf "$TMPD"' EXIT

STAGE="$TMPD/backlog-staging.md"
TODAY="$(date +%Y-%m-%d)"

# ============================================================
echo "== happy path: creates the file with header, appends one block, round-trips via parse =="
# ============================================================
IN1='{"title":"Route Explore subagents to Haiku","intent":"cut inherited Opus spend","home":"dwarves-kit","staging":"'"$STAGE"'"}'
OUT1="$(printf '%s' "$IN1" | python3 "$SF" stage)"; RC1=$?
chk "happy: exit 0" "$([ "$RC1" -eq 0 ]; echo $?)"
chk "happy: staging file created" "$([ -f "$STAGE" ]; echo $?)"
chk_has "happy: header line present" "$(cat "$STAGE")" "# Backlog staging"
chk_has "happy: prints the staged title line" "$OUT1" "## [staged] Route Explore subagents to Haiku"

PARSED1="$(python3 "$SF" parse "$STAGE")"
chk_has "roundtrip: title" "$PARSED1" '"title": "Route Explore subagents to Haiku"'
chk_has "roundtrip: Home field" "$PARSED1" '"Home": "dwarves-kit"'
chk_has "roundtrip: Source cites today's date" "$PARSED1" "session $TODAY"

# ============================================================
echo "== dedupe: same title in different case/spacing/punctuation appends nothing =="
# ============================================================
BEFORE="$(shasum -a 256 "$STAGE" | cut -d' ' -f1)"
IN2='{"title":"route   EXPLORE Subagents to, Haiku!!","intent":"x","home":"h","staging":"'"$STAGE"'"}'
OUT2="$(printf '%s' "$IN2" | python3 "$SF" stage)"; RC2=$?
AFTER="$(shasum -a 256 "$STAGE" | cut -d' ' -f1)"
chk "dedupe: exit 0" "$([ "$RC2" -eq 0 ]; echo $?)"
chk_has "dedupe: prints already staged" "$OUT2" "already staged"
chk "dedupe: staging file byte-identical" "$([ "$BEFORE" = "$AFTER" ]; echo $?)"

# ============================================================
echo "== board dedupe: a title already on the board (Item cell) is refused the same way =="
# ============================================================
BOARD="$TMPD/BACKLOG.md"
cat > "$BOARD" <<'EOF'
| ID | Item | Notes | Status |
|---|---|---|---|
| ID-002 | Ship the seam table report | notes | queued |
EOF
BEFORE3="$(shasum -a 256 "$STAGE" | cut -d' ' -f1)"
IN3='{"title":"Ship   the, SEAM table report!!","intent":"x","home":"h","staging":"'"$STAGE"'","backlog":"'"$BOARD"'"}'
OUT3="$(printf '%s' "$IN3" | python3 "$SF" stage)"; RC3=$?
AFTER3="$(shasum -a 256 "$STAGE" | cut -d' ' -f1)"
chk "board dedupe: exit 0" "$([ "$RC3" -eq 0 ]; echo $?)"
chk_has "board dedupe: prints already staged" "$OUT3" "already staged"
chk "board dedupe: staging file byte-identical" "$([ "$BEFORE3" = "$AFTER3" ]; echo $?)"

# ============================================================
echo "== unwritable target: chmod 000 parent dir prints FAILED, exit 2, nothing written =="
# ============================================================
LOCKED="$TMPD/locked"; mkdir "$LOCKED"; chmod 000 "$LOCKED"
TARGET4="$LOCKED/backlog-staging.md"
IN4='{"title":"A candidate nobody can write","intent":"x","home":"h","staging":"'"$TARGET4"'"}'
OUT4="$(printf '%s' "$IN4" | python3 "$SF" stage)"; RC4=$?
chk "unwritable dir: exit 2" "$([ "$RC4" -eq 2 ]; echo $?)"
chk_has "unwritable dir: prints FAILED" "$OUT4" "FAILED"
chmod 700 "$LOCKED"
chk "unwritable dir: nothing written" "$([ ! -f "$TARGET4" ]; echo $?)"

# ============================================================
echo "== unwritable target: a path under a FILE (not a dir) prints FAILED, exit 2 =="
# ============================================================
NOTADIR="$TMPD/notadir"; touch "$NOTADIR"
TARGET5="$NOTADIR/backlog-staging.md"
IN5='{"title":"Another unwritable candidate","intent":"x","home":"h","staging":"'"$TARGET5"'"}'
OUT5="$(printf '%s' "$IN5" | python3 "$SF" stage)"; RC5=$?
chk "unwritable path-under-file: exit 2" "$([ "$RC5" -eq 2 ]; echo $?)"
chk_has "unwritable path-under-file: prints FAILED" "$OUT5" "FAILED"
chk "unwritable path-under-file: nothing written" "$([ ! -f "$TARGET5" ]; echo $?)"

# ============================================================
echo "== malformed JSON on stdin exits non-zero with a usage-style message =="
# ============================================================
OUT6="$(echo 'not json at all' | python3 "$SF" stage 2>&1)"; RC6=$?
chk "malformed JSON: exit non-zero" "$([ "$RC6" -ne 0 ]; echo $?)"
chk_has "malformed JSON: usage-style message" "$OUT6" "usage:"

echo ""
echo "== $TOTAL run, $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
