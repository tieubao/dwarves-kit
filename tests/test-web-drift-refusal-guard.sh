#!/usr/bin/env bash
# test-web-drift-refusal-guard.sh -- ID-484: web-drift's boardless-consumer refusal guard.
#
# web-drift is a prose SKILL.md (no lib/ script), so this test extracts the ACTUAL guard line
# verbatim from skills/web-drift/SKILL.md's fenced code block and runs it for real against two
# temp target repos: one with a kit board (must pass through) and one without (must refuse,
# name the fix, exit 1). This proves the shipped doc text is real, executable logic, not
# unverified prose, and pins it so an edit to the guard cannot silently drift from what is
# documented without the test's extraction breaking too.
#
# Run: bash tests/test-web-drift-refusal-guard.sh   (exit 0 = all AC green)

set -uo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$KIT_DIR/skills/web-drift/SKILL.md"

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert() { TOTAL=$((TOTAL+1)); if [ "$2" -eq 0 ]; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1)); else echo -e "  ${RED}FAIL${NC} $1 ${3:-}"; FAIL=$((FAIL+1)); fi; }

TMPS=()
_mk() { local d; d="$(mktemp -d)"; TMPS+=("$d"); printf '%s' "$d"; }
cleanup() { local d; for d in "${TMPS[@]:-}"; do [ -n "$d" ] && rm -rf "$d" 2>/dev/null; done; }
trap cleanup EXIT

echo "=== web-drift refusal guard (ID-484) ==="

# ---------------------------------------------------------------------------
# Extract the guard line: the "test -f _meta/BACKLOG.md ..." statement inside the fenced code
# block right after the "Refusal guard" heading. A missing extraction is itself a failure (the
# doc drifted out from under this test), not a silent skip.
# ---------------------------------------------------------------------------
GUARD_LINE="$(awk '/Refusal guard \(ID-484\)/{f=1} f && /^   test -f _meta\/BACKLOG\.md/{print; exit}' "$SKILL" | sed -E 's/^[[:space:]]+//')"

[ -n "$GUARD_LINE" ] && assert "extracted the guard line from skills/web-drift/SKILL.md" 0 \
  || { assert "extracted the guard line from skills/web-drift/SKILL.md" 1; echo "$PASS/$TOTAL passed, $FAIL failed"; exit 1; }

case "$GUARD_LINE" in *"bin/board init"*) R=0 ;; *) R=1 ;; esac
assert "guard names the fix (bin/board init)" $R "-- got: $GUARD_LINE"

# ---------------------------------------------------------------------------
# C1: a target repo WITH a kit board passes the guard (exit 0, no REFUSE line).
# ---------------------------------------------------------------------------
BOARDED="$(_mk)"; mkdir -p "$BOARDED/_meta"
printf '# BACKLOG\n\n| ID | Item | Notes & source | Status |\n|---|---|---|---|\n' > "$BOARDED/_meta/BACKLOG.md"
OUT1="$(cd "$BOARDED" && eval "$GUARD_LINE" 2>&1)"; rc1=$?
[ "$rc1" -eq 0 ] && assert "C1 boarded consumer: guard passes (exit 0)" 0 || assert "C1 boarded consumer: guard passes (rc=$rc1)" 1
{ trap '' PIPE; echo "$OUT1" 2>/dev/null || :; } | grep -q REFUSE && assert "C1 boarded consumer: no REFUSE line" 1 || assert "C1 boarded consumer: no REFUSE line" 0

# ---------------------------------------------------------------------------
# C2 NEGATIVE CONTROL: a target repo with NO _meta/BACKLOG.md refuses (exit 1) and names the fix.
# ---------------------------------------------------------------------------
BOARDLESS="$(_mk)"
OUT2="$(cd "$BOARDLESS" && eval "$GUARD_LINE" 2>&1)"; rc2=$?
[ "$rc2" -eq 1 ] && assert "C2 NC: boardless consumer refuses the run (exit 1)" 0 || assert "C2 NC: boardless consumer refuses (rc=$rc2)" 1
{ trap '' PIPE; echo "$OUT2" 2>/dev/null || :; } | grep -q '^REFUSE:' && assert "C2 NC: refusal names REFUSE + the fix" 0 || assert "C2 NC: refusal names REFUSE (got: $OUT2)" 1
{ trap '' PIPE; echo "$OUT2" 2>/dev/null || :; } | grep -q "bin/board init" && assert "C2 NC: refusal names the fix (bin/board init)" 0 || assert "C2 NC: refusal names the fix" 1

echo ""
echo "=== $PASS/$TOTAL passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
