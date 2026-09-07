#!/usr/bin/env bash
# test-board.sh -- SPEC-146 (runner-fastpath sub-goal 04): lib/board/board.sh + lib/board/parse-board.sh.
#
# Proves:
#   AC1  pb_rows / pb_queue_rows (lib/board/parse-board.sh) extract + validate queue tokens correctly
#   AC2  a valid #queue{} token on a queued row resolves to a real allow-listed pointer path
#   AC3  a malformed token (missing key) is skipped, not emitted
#   AC4  a #queue{} token on a NON-queued row is silently ignored (out of scope, not an error)
#   AC5  single-repo board/next/set/states/priority all delegate correctly on a fixture
#   AC6  cross-repo `all board|next|states|priority overview|priority matrix` render correctly
#        on a 2-repo fixture registry
#
#   NC-a zero tokens              -> `queue` emits nothing on stdout, "0 rows" on stderr, exit 0
#   NC-b repo not in boards.txt   -> skipped with a logged reason (repo mismatch / spoofing)
#   NC-c pointer outside allow-listed dirs, incl. `../` traversal -> skipped with a reason
#   NC-d shell-metachar field     -> never reaches an exec boundary (charset-rejected AND a
#                                    static source-audit that neither lib file ever `eval`s or
#                                    `sh -c`'s parsed content)
#   NC-e RENDER NON-REGRESSION    -> board/next/priority[overview|matrix]/states against the REAL
#                                    ops-toolkit cockpit are byte-identical to the pre-migration
#                                    `_meta/board`/`_meta/board-all` output. The cockpit lives in a
#                                    sibling repo whose location is per-operator, so the test reads
#                                    $KIT_SIBLING_ROOT/ops-toolkit and hard-codes no home. SKIPS
#                                    (not fails) when that is unset or absent, which is the CI case
#                                    -- same precedent as test-weekend-batch.sh's dotfiles skip.
#
# Run: bash tests/test-board.sh   (exit 0 = all AC/NC green, including expected skips)

set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOARD="$KIT_DIR/lib/board/board.sh"
PARSE_BOARD="$KIT_DIR/lib/board/parse-board.sh"

PASS=0; FAIL=0; SKIP=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
assert() {
  TOTAL=$((TOTAL+1))
  if [ "$2" -eq 0 ] 2>/dev/null; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1))
  else echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL+1)); fi
}
skip() { TOTAL=$((TOTAL+1)); SKIP=$((SKIP+1)); echo -e "  ${YELLOW}SKIP${NC} $1"; }

TMPDIR_T="$(mktemp -d "${TMPDIR:-/tmp}/dk-board-test.XXXXXX")"
TMPDIR_T="$(cd "$TMPDIR_T" && pwd)"   # normalize away a double slash (macOS $TMPDIR often ends
                                       # in one), so string-prefix assertions below compare
                                       # apples to apples against board.sh's own canonicalization
trap 'rm -rf "$TMPDIR_T"' EXIT

# ---------------------------------------------------------------------------
# Fixture world: two "repos" (fixA, fixB), each a real git repo (so _repo_root_for's
# `git rev-parse --show-toplevel` resolves), each with its own _meta/BACKLOG.md, plus a
# registry (boards.txt) pointing at both.
# ---------------------------------------------------------------------------
FIXA="$TMPDIR_T/fixA"
FIXB="$TMPDIR_T/fixB"
mkdir -p "$FIXA/_meta/megagoals/mg1/goals" "$FIXA/.claude/goals" "$FIXB/_meta"
git init -q "$FIXA"; git -C "$FIXA" config user.email t@t; git -C "$FIXA" config user.name t
git init -q "$FIXB"; git -C "$FIXB" config user.email t@t; git -C "$FIXB" config user.name t

# a real allow-listed pointer target under both allow-listed dirs
echo "pointer target 1" > "$FIXA/_meta/megagoals/mg1/goals/g1.md"
echo "pointer target 2" > "$FIXA/.claude/goals/g2.md"

cat > "$FIXA/_meta/BACKLOG.md" <<'BOARD_A'
# Backlog

## Active queue

| ID | Title | Source | Target | Lane | Status |
|----|-------|--------|--------|------|--------|
| ID-001 | Do the thing #u-hi #f-hi | test | TBD | normal | queued |
| ID-002 | Runner-eligible (megagoals dir) #queue{repo=fixA,pointer=_meta/megagoals/mg1/goals/g1.md} | test | TBD | normal | queued |
| ID-003 | Runner-eligible (claude/goals dir) #queue{repo=fixA,pointer=.claude/goals/g2.md} | test | TBD | normal | queued |
| ID-004 | Traversal attempt #queue{repo=fixA,pointer=../../../etc/passwd} | test | TBD | normal | queued |
| ID-005 | Wrong-dir pointer #queue{repo=fixA,pointer=lib/board/board.sh} | test | TBD | normal | queued |
| ID-006 | Cross-repo spoof #queue{repo=fixB,pointer=_meta/megagoals/mg1/goals/g1.md} | test | TBD | normal | queued |
| ID-007 | Malformed (no pointer key) #queue{repo=fixA} | test | TBD | normal | queued |
| ID-008 | Non-queued with token #queue{repo=fixA,pointer=_meta/megagoals/mg1/goals/g1.md} | test | TBD | normal | claimed |
| ID-009 | Dangling pointer (never created) #queue{repo=fixA,pointer=_meta/megagoals/mg1/goals/nope.md} | test | TBD | normal | queued |
BOARD_A

cat > "$FIXB/_meta/BACKLOG.md" <<'BOARD_B'
# Backlog
## Active queue
| ID | Title | Source | Target | Lane | Status |
|----|-------|--------|--------|------|--------|
| DF-001 | Something #f-lo | test | TBD | tiny | queued |
BOARD_B

REGISTRY="$TMPDIR_T/boards.txt"
cat > "$REGISTRY" <<REG
fixA  $FIXA/_meta/BACKLOG.md
fixB  $FIXB/_meta/BACKLOG.md
REG

echo "=== AC1/AC2: pb_rows + pb_queue_rows extract and allow-list a valid token ==="
ROWS_OUT="$(bash "$PARSE_BOARD" rows "$FIXA/_meta/BACKLOG.md")"
# NOTE: the pattern is built via bash ANSI-C quoting ($'...') so the literal tab byte is
# embedded in the argv BEFORE grep sees it, rather than relying on grep's own '\t' escape
# handling in a -E pattern. That escape is a GNU-grep-only convenience (BSD grep on macOS
# interprets '\t' inside -E as a tab too, but GNU grep 3.x on Linux/CI does not -- it matches
# a literal 't'), which silently broke this assertion on ubuntu-latest while staying green on
# macos-latest. A real tab byte matches identically on both grep implementations.
assert "pb_rows sees ID-001 as queued" "$({ trap '' PIPE; printf '%s\n' "$ROWS_OUT" 2>/dev/null || :; } | grep -qE $'^ID-001\tqueued\t' && echo 0 || echo 1)"
assert "pb_rows sees ID-008 as claimed" "$({ trap '' PIPE; printf '%s\n' "$ROWS_OUT" 2>/dev/null || :; } | grep -qE $'^ID-008\tclaimed\t' && echo 0 || echo 1)"

QROWS="$(bash "$PARSE_BOARD" queue-rows "$FIXA/_meta/BACKLOG.md" fixA "$FIXA" 2>/dev/null)"
assert "ID-002 (megagoals dir) is allow-listed" "$({ trap '' PIPE; printf '%s\n' "$QROWS" 2>/dev/null || :; } | grep -q '^ID-002' && echo 0 || echo 1)"
assert "ID-003 (.claude/goals dir) is allow-listed" "$({ trap '' PIPE; printf '%s\n' "$QROWS" 2>/dev/null || :; } | grep -q '^ID-003' && echo 0 || echo 1)"
RESOLVED_002="$(printf '%s\n' "$QROWS" | awk -F'\t' '$1=="ID-002"{print $3}')"
assert "ID-002 resolves to the real canonical pointer file" "$([ "$RESOLVED_002" = "$FIXA/_meta/megagoals/mg1/goals/g1.md" ] && echo 0 || echo 1)"
assert "ID-002's repo-root column is the fixture repo root" "$(printf '%s\n' "$QROWS" | awk -F'\t' '$1=="ID-002"{print $2}' | grep -qx "$FIXA" && echo 0 || echo 1)"

echo ""
echo "=== AC3: malformed token (missing pointer=) is skipped, not emitted ==="
assert "ID-007 (no pointer key) never emitted" "$({ trap '' PIPE; printf '%s\n' "$QROWS" 2>/dev/null || :; } | grep -q '^ID-007' && echo 1 || echo 0)"
QERR="$(bash "$PARSE_BOARD" queue-rows "$FIXA/_meta/BACKLOG.md" fixA "$FIXA" 2>&1 >/dev/null)"
assert "ID-007's skip reason is logged" "$({ trap '' PIPE; printf '%s\n' "$QERR" 2>/dev/null || :; } | grep -q 'skip ID-007' && echo 0 || echo 1)"

echo ""
echo "=== AC4: a #queue{} token on a NON-queued row is silently ignored ==="
assert "ID-008 (claimed, has a token) never emitted" "$({ trap '' PIPE; printf '%s\n' "$QROWS" 2>/dev/null || :; } | grep -q '^ID-008' && echo 1 || echo 0)"

echo ""
echo "=== NC-a: zero tokens -> empty stdout, honest '0 rows' on stderr, exit 0 ==="
EMPTY_A="$TMPDIR_T/emptyA"
mkdir -p "$EMPTY_A/_meta"
git init -q "$EMPTY_A"; git -C "$EMPTY_A" config user.email t@t; git -C "$EMPTY_A" config user.name t
cat > "$EMPTY_A/_meta/BACKLOG.md" <<'BOARD_E'
# Backlog
## Active queue
| ID | Title | Source | Target | Lane | Status |
|----|-------|--------|--------|------|--------|
| ID-101 | No token here | test | TBD | normal | queued |
BOARD_E
EMPTY_REG="$TMPDIR_T/empty-boards.txt"
echo "emptyA  $EMPTY_A/_meta/BACKLOG.md" > "$EMPTY_REG"
Q_EMPTY_OUT="$(bash "$BOARD" queue --registry "$EMPTY_REG" 2>"$TMPDIR_T/empty.err")"; Q_EMPTY_RC=$?
assert "NC-a: exit 0 on zero tokens" "$([ "$Q_EMPTY_RC" -eq 0 ] && echo 0 || echo 1)"
assert "NC-a: stdout is empty" "$([ -z "$Q_EMPTY_OUT" ] && echo 0 || echo 1)"
assert "NC-a: stderr honestly reports '0 rows'" "$(grep -q '0 rows' "$TMPDIR_T/empty.err" && echo 0 || echo 1)"

echo ""
echo "=== NC-b: repo not in boards.txt (cross-repo spoof) -> skipped w/ reason ==="
Q_FULL_ERR="$(bash "$BOARD" queue --registry "$REGISTRY" 2>&1 >/dev/null)"
assert "NC-b: ID-006 (claims repo=fixB while living in fixA's board) is skipped" \
  "$({ trap '' PIPE; printf '%s\n' "$Q_FULL_ERR" 2>/dev/null || :; } | grep -q 'skip ID-006' && echo 0 || echo 1)"
assert "NC-b: the skip reason names the mismatch" \
  "$(printf '%s\n' "$Q_FULL_ERR" | grep 'ID-006' | grep -qi 'mismatch\|spoof' && echo 0 || echo 1)"
Q_FULL_OUT="$(bash "$BOARD" queue --registry "$REGISTRY" 2>/dev/null)"
assert "NC-b: ID-006 never appears in the emitted rows" "$({ trap '' PIPE; printf '%s\n' "$Q_FULL_OUT" 2>/dev/null || :; } | grep -q 'ID-006' && echo 1 || echo 0)"

echo ""
echo "=== NC-c: pointer outside allow-listed dirs, incl. '../' traversal -> skipped w/ reason ==="
assert "NC-c: ID-004 ('../../../etc/passwd') is skipped" \
  "$({ trap '' PIPE; printf '%s\n' "$Q_FULL_ERR" 2>/dev/null || :; } | grep -q 'skip ID-004' && echo 0 || echo 1)"
assert "NC-c: ID-004's reason names the traversal / disallowed component" \
  "$(printf '%s\n' "$Q_FULL_ERR" | grep 'ID-004' | grep -qi "\\.\\.\\|traversal\\|disallowed" && echo 0 || echo 1)"
assert "NC-c: ID-005 (lib/board/board.sh, a real file OUTSIDE the allow-listed dirs) is skipped" \
  "$({ trap '' PIPE; printf '%s\n' "$Q_FULL_ERR" 2>/dev/null || :; } | grep -q 'skip ID-005' && echo 0 || echo 1)"
assert "NC-c: ID-005's reason names 'outside allow-listed'" \
  "$(printf '%s\n' "$Q_FULL_ERR" | grep 'ID-005' | grep -qi 'outside allow-listed' && echo 0 || echo 1)"
assert "NC-c: neither ID-004 nor ID-005 ever appears in emitted rows" \
  "$({ trap '' PIPE; printf '%s\n' "$Q_FULL_OUT" 2>/dev/null || :; } | grep -qE 'ID-004|ID-005' && echo 1 || echo 0)"
assert "NC-c: ID-009's dangling (never-created) pointer is also skipped (defense in depth)" \
  "$({ trap '' PIPE; printf '%s\n' "$Q_FULL_ERR" 2>/dev/null || :; } | grep -q 'skip ID-009' && echo 0 || echo 1)"

echo ""
echo "=== NC-d: shell-metachar field is parsed as ONE literal argv element, never executed ==="
# A row whose pointer= value carries a shell metachar payload. Written via a separate fixture
# repo so a metachar-triggered failure here can never contaminate the other fixtures' assertions.
METAREPO="$TMPDIR_T/metarepo"
mkdir -p "$METAREPO/_meta/megagoals/mg1/goals"
git init -q "$METAREPO"; git -C "$METAREPO" config user.email t@t; git -C "$METAREPO" config user.name t
echo "target" > "$METAREPO/_meta/megagoals/mg1/goals/real.md"
CANARY="$TMPDIR_T/canary-should-never-exist"
# The pointer value below embeds a semicolon + a command that would touch $CANARY if it were
# ever handed to a shell for interpretation instead of treated as an opaque string.
PAYLOAD='_meta/megagoals/mg1/goals/real.md; touch '"$CANARY"
{
  echo '# Backlog'
  echo '## Active queue'
  echo '| ID | Title | Source | Target | Lane | Status |'
  echo '|----|-------|--------|--------|------|--------|'
  printf '| ID-901 | Metachar payload #queue{repo=metarepo,pointer=%s} | test | TBD | normal | queued |\n' "$PAYLOAD"
} > "$METAREPO/_meta/BACKLOG.md"
METAREG="$TMPDIR_T/meta-boards.txt"
echo "metarepo  $METAREPO/_meta/BACKLOG.md" > "$METAREG"

META_OUT="$(bash "$BOARD" queue --registry "$METAREG" 2>"$TMPDIR_T/meta.err")"
assert "NC-d: the canary file was NEVER created (metachar never reached a shell)" "$([ ! -e "$CANARY" ] && echo 0 || echo 1)"
assert "NC-d: ID-901 (metachar payload) never appears in emitted rows" "$({ trap '' PIPE; printf '%s\n' "$META_OUT" 2>/dev/null || :; } | grep -q 'ID-901' && echo 1 || echo 0)"
assert "NC-d: ID-901 is skipped for disallowed characters" "$(grep 'ID-901' "$TMPDIR_T/meta.err" | grep -qi 'disallowed characters' && echo 0 || echo 1)"

# Static source-audit: neither lib file ever hands a parsed value to a shell for
# interpretation (eval / sh -c / bash -c on a variable). This is the structural guarantee
# behind "never executed", independent of any one test payload.
STATIC_RC=0
for f in "$BOARD" "$PARSE_BOARD"; do
  grep -qE '(^|[^A-Za-z0-9_])eval[[:space:]]' "$f" && STATIC_RC=1
  grep -qE '\b(sh|bash)[[:space:]]+-c[[:space:]]+"\$' "$f" && STATIC_RC=1
done
assert "NC-d: static audit -- neither lib/board/board.sh nor lib/board/parse-board.sh ever eval/sh-c a parsed variable" "$([ "$STATIC_RC" -eq 0 ] && echo 0 || echo 1)"

echo ""
echo "=== AC5: single-repo board/next/set/states/priority delegate correctly ==="
BOARD_OUT="$(bash "$BOARD" board --backlog-file "$FIXB/_meta/BACKLOG.md")"
assert "single board renders DF-001 under queued" "$({ trap '' PIPE; printf '%s\n' "$BOARD_OUT" 2>/dev/null || :; } | grep -q 'DF-001' && echo 0 || echo 1)"
NEXT_OUT="$(bash "$BOARD" next --backlog-file "$FIXB/_meta/BACKLOG.md")"
assert "single next picks DF-001" "$([ "$NEXT_OUT" = "DF-001" ] && echo 0 || echo 1)"
bash "$BOARD" set --backlog-file "$FIXB/_meta/BACKLOG.md" DF-001 claimed "test claim" >/dev/null
assert "single set flips DF-001 to claimed" "$(grep 'DF-001' "$FIXB/_meta/BACKLOG.md" | grep -q 'claimed' && echo 0 || echo 1)"
STATES_OUT="$(bash "$BOARD" states --backlog-file "$FIXB/_meta/BACKLOG.md")"
assert "single states lists queued and shipped" "$({ trap '' PIPE; printf '%s\n' "$STATES_OUT" 2>/dev/null || :; } | grep -q 'queued' && { trap '' PIPE; printf '%s\n' "$STATES_OUT" 2>/dev/null || :; } | grep -q 'shipped' && echo 0 || echo 1)"
PRIO_OUT="$(bash "$BOARD" priority overview --backlog-file "$FIXA/_meta/BACKLOG.md")"
assert "single priority renders DO NOW section" "$({ trap '' PIPE; printf '%s\n' "$PRIO_OUT" 2>/dev/null || :; } | grep -q 'DO NOW' && echo 0 || echo 1)"

echo ""
echo "=== AC6: cross-repo all board|next|priority[overview|matrix]|states on the 2-repo registry ==="
ALL_BOARD="$(bash "$BOARD" all board --registry "$REGISTRY")"
assert "all board shows both repo headers" "$({ trap '' PIPE; printf '%s\n' "$ALL_BOARD" 2>/dev/null || :; } | grep -q '=== fixA ===' && { trap '' PIPE; printf '%s\n' "$ALL_BOARD" 2>/dev/null || :; } | grep -q '=== fixB ===' && echo 0 || echo 1)"
ALL_NEXT="$(bash "$BOARD" all next --registry "$REGISTRY")"
assert "all next shows fixA's and fixB's next item" "$({ trap '' PIPE; printf '%s\n' "$ALL_NEXT" 2>/dev/null || :; } | grep -q 'fixA' && { trap '' PIPE; printf '%s\n' "$ALL_NEXT" 2>/dev/null || :; } | grep -q 'fixB' && echo 0 || echo 1)"
ALL_PRIO="$(bash "$BOARD" all priority overview --registry "$REGISTRY")"
assert "all priority overview groups by repo" "$({ trap '' PIPE; printf '%s\n' "$ALL_PRIO" 2>/dev/null || :; } | grep -q '=== fixA ===' && echo 0 || echo 1)"
ALL_MATRIX="$(bash "$BOARD" all priority matrix --registry "$REGISTRY")"
assert "all priority matrix renders the pivot header" "$({ trap '' PIPE; printf '%s\n' "$ALL_MATRIX" 2>/dev/null || :; } | grep -q 'Priority matrix' && echo 0 || echo 1)"
ALL_STATES="$(bash "$BOARD" all states --registry "$REGISTRY")"
assert "all states renders per repo" "$({ trap '' PIPE; printf '%s\n' "$ALL_STATES" 2>/dev/null || :; } | grep -q '=== fixA ===' && echo 0 || echo 1)"

echo ""
echo "=== NC-e: RENDER NON-REGRESSION against the REAL ops-toolkit cockpit ==="
OPS="${KIT_SIBLING_ROOT:-}/ops-toolkit"
if [ -x "$OPS/_meta/board" ] && [ -x "$OPS/_meta/board-all" ] && [ -f "$OPS/_meta/BACKLOG.md" ]; then
  RP="$TMPDIR_T/render-proof"; mkdir -p "$RP"
  pair() {
    local label="$1" before="$2" after="$3"
    bash -c "$before" > "$RP/$label.before" 2>&1
    bash -c "$after"  > "$RP/$label.after"  2>&1
    if cmp -s "$RP/$label.before" "$RP/$label.after"; then
      assert "NC-e: $label byte-identical" 0
    else
      assert "NC-e: $label byte-identical" 1
      diff "$RP/$label.before" "$RP/$label.after" | head -10 >&2
    fi
  }
  pair "single-board"            "$OPS/_meta/board"                        "bash $BOARD board --backlog-file $OPS/_meta/BACKLOG.md"
  pair "single-next"             "$OPS/_meta/board next"                   "bash $BOARD next --backlog-file $OPS/_meta/BACKLOG.md"
  pair "single-priority-overview" "$OPS/_meta/board priority overview"     "bash $BOARD priority overview --backlog-file $OPS/_meta/BACKLOG.md"
  pair "single-states"           "$OPS/_meta/board states"                 "bash $BOARD states --backlog-file $OPS/_meta/BACKLOG.md"
  pair "all-board"               "$OPS/_meta/board-all"                    "bash $BOARD all board --repo-root $OPS"
  pair "all-next"                "$OPS/_meta/board-all next"               "bash $BOARD all next --repo-root $OPS"
  pair "all-priority-overview"   "$OPS/_meta/board-all priority overview"  "bash $BOARD all priority overview --repo-root $OPS"
  pair "all-priority-matrix"     "$OPS/_meta/board-all priority matrix"    "bash $BOARD all priority matrix --repo-root $OPS"
  pair "all-states"              "$OPS/_meta/board-all states"             "bash $BOARD all states --repo-root $OPS"
else
  skip "NC-e (ops-toolkit path absent -- $OPS; not present in CI, run locally to exercise)"
fi

echo ""
echo "=== Coverage delta ==="
BEFORE_COUNT=0   # no lib/board/board.sh, no lib/board/parse-board.sh, no tests/test-board.sh before SPEC-146
AFTER_COUNT="$TOTAL"
assert "coverage delta: board.sh/parse-board.sh checks went from $BEFORE_COUNT to $AFTER_COUNT in this suite" "$([ "$AFTER_COUNT" -gt "$BEFORE_COUNT" ] && echo 0 || echo 1)"

echo ""
echo "  ---------------------------------------------"
echo "  TOTAL: $TOTAL   PASS: $PASS   FAIL: $FAIL   SKIP: $SKIP"
[ "$FAIL" -eq 0 ] || exit 1
