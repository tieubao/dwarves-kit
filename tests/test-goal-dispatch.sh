#!/usr/bin/env bash
# test-goal-dispatch.sh -- SPEC-204: lib/goal/goal.sh dispatch behavior.
# One case per reviewed test-plan matrix row (SPEC-204 ## Test plan, SOLID verdict).
#
# Run: bash tests/test-goal-dispatch.sh   (exit 0 = all green)

set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOAL="$KIT_DIR/lib/goal/goal.sh"

PASS=0; FAIL=0; SKIP=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
assert() {
  TOTAL=$((TOTAL+1))
  if [ "$2" -eq 0 ] 2>/dev/null; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1))
  else echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL+1)); fi
}
skip() { TOTAL=$((TOTAL+1)); SKIP=$((SKIP+1)); echo -e "  ${YELLOW}SKIP${NC} $1"; }

cd "$KIT_DIR"

echo "=== row 1: draft dir -- happy-path, AC-1, regression ==="
assert "row1: goal.sh draft dir == goal-drafts.sh dir (byte-identical)" \
  "$(cmp <(bash "$GOAL" draft dir) <(bash lib/goal/goal-drafts.sh dir) >/dev/null 2>&1 && echo 0 || echo 1)"

echo "=== row 2: drafts dir (alias) -- happy-path, AC-2 ==="
assert "row2: goal.sh drafts dir == goal.sh draft dir (byte-identical)" \
  "$(cmp <(bash "$GOAL" drafts dir) <(bash "$GOAL" draft dir) >/dev/null 2>&1 && echo 0 || echo 1)"

echo "=== row 3: registry list -- happy-path, AC-3 ==="
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
assert "row3: registry list forwards + prints '(no running goals)'" \
  "$(GOAL_REGISTRY_DIR="$d" bash "$GOAL" registry list | grep -qx '(no running goals)' && echo 0 || echo 1)"
rm -rf "$d"; trap - EXIT

echo "=== row 4: merge (no subcmd) -- happy-path, AC-4 ==="
# NOTE: capture to a var first, then grep it -- goal.sh merge's own exit code is a nonzero
# 64 (its usage branch), and this file runs under `set -o pipefail`; piping the bash call
# straight into `grep -q` would make the PIPELINE's reported exit status 64 (pipefail picks
# the last non-zero code anywhere in the pipe, not grep's own 0-on-match), which silently
# breaks the `&& echo 0` that follows even when grep genuinely matched.
row4_out="$(bash "$GOAL" merge 2>&1)"
assert "row4: goal.sh merge prints mega-merge.sh's own usage" \
  "$(grep -q '^usage: mega-merge.sh' <<<"$row4_out" && echo 0 || echo 1)"

echo "=== row 5: stack-merge (no subcmd) -- happy-path, AC-5 ==="
row5_out="$(bash "$GOAL" stack-merge 2>&1)"
assert "row5: goal.sh stack-merge prints stack-merge.sh's own usage" \
  "$(grep -q '^usage: stack-merge.sh' <<<"$row5_out" && echo 0 || echo 1)"

echo "=== row 6: handoff --help -- happy-path, AC-6 (hop 1) ==="
assert "row6: goal.sh handoff --help surfaces the Python argparse banner" \
  "$(bash "$GOAL" handoff --help 2>&1 | grep -q 'usage: handoff-gen' && echo 0 || echo 1)"

echo "=== row 7: goal.sh (no args) -- boundary/edge, AC-7 ==="
assert "row7: no-args usage is byte-identical to comment-stripped lines 2-13" \
  "$(cmp <(bash "$GOAL") <(sed -n '2,13p' "$GOAL" | sed 's/^# \{0,1\}//') >/dev/null 2>&1 && echo 0 || echo 1)"

echo "=== row 8: -h / --help / help byte-identical -- boundary/edge, AC-8 ==="
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
bash "$GOAL" --help > "$d/h1"; bash "$GOAL" -h > "$d/h2"; bash "$GOAL" help > "$d/h3"
assert "row8: --help/-h/help all byte-identical" \
  "$(cmp "$d/h1" "$d/h2" >/dev/null 2>&1 && cmp "$d/h2" "$d/h3" >/dev/null 2>&1 && echo 0 || echo 1)"
rm -rf "$d"; trap - EXIT

echo "=== row 9: quoting-boundary adversarial arg through draft -- boundary/edge, AC-1 ==="
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
out="$(GOAL_DRAFTS_DIR="$d" bash "$GOAL" draft 'list extra-words' 2>&1)"; ec=$?
assert "row9: single-token forwarding lands on goal-drafts.sh's catch-all (usage, exit 64)" \
  "$([ "$out" = 'usage: goal-drafts.sh {archive [--dry-run]|list|dir}' ] && [ "$ec" -eq 64 ] && echo 0 || echo 1)"
rm -rf "$d"; trap - EXIT

echo "=== row 10: bogus-verb + whitespace-only verb -- boundary/edge, AC-9 ==="
# same pipefail hazard as row 4/5: goal.sh exits 1 on an unrecognized verb, so capture
# stderr to a var first rather than piping straight into grep.
row10_a="$(bash "$GOAL" bogus-verb 2>&1 1>/dev/null)"
row10_b="$(bash "$GOAL" ' ' 2>&1 1>/dev/null)"
assert "row10: unrecognized verb error is exact + exit 1 (bogus-verb, whitespace)" \
  "$(grep -qx "goal: unknown verb 'bogus-verb' (try: goal --help)" <<<"$row10_a" \
     && grep -qx "goal: unknown verb ' ' (try: goal --help)" <<<"$row10_b" \
     && echo 0 || echo 1)"

echo "=== row 11: sibling script missing -- failure-injection, AC-11 (missing half) ==="
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
sed 's#goal-drafts\.sh#goal-drafts-NOPE.sh#' "$GOAL" > "$d/goal-missing.sh"
out="$(bash "$d/goal-missing.sh" draft dir 2>&1)"; ec=$?
assert "row11: missing sibling surfaces bash's own 'No such file or directory', exit 127" \
  "$(grep -q 'No such file or directory' <<<"$out" && [ "$ec" -eq 127 ] && echo 0 || echo 1)"
rm -rf "$d"; trap - EXIT

echo "=== row 12: sibling script unreadable (chmod 000) -- failure-injection, AC-11 (unreadable half) ==="
if [ "$(id -u)" -eq 0 ]; then
  skip "row12: skipped -- running as root, chmod 000 is not enforced against root"
else
  d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
  cp "$GOAL" lib/goal/goal-drafts.sh "$d/"
  chmod 000 "$d/goal-drafts.sh"
  out="$(bash "$d/goal.sh" draft dir 2>&1)"; ec=$?
  assert "row12: unreadable sibling surfaces bash's own 'Permission denied', exit 126" \
    "$({ trap '' PIPE; echo "$out" 2>/dev/null || :; } | grep -q 'Permission denied' && [ "$ec" -eq 126 ] && echo 0 || echo 1)"
  rm -rf "$d"; trap - EXIT
fi

echo "=== row 13: every forwarding branch uses exec -- regression, AC-10 (hop-1 structural) ==="
# Assert the INVARIANT the row is named for, not a snapshot of how many branches exist.
# The count was pinned at 5 and a sixth branch was added, so a passing structure read as a
# regression. Derive both numbers and require they agree: every forwarding branch execs,
# and at least one exists so the check cannot pass vacuously on an empty match.
_fwd_exec="$(grep -cE '^\s+\S+\)\s+exec bash "\$GOAL_DIR' "$GOAL")"
_fwd_all="$(grep -cE '^\s+\S+\)\s+(exec )?bash "\$GOAL_DIR' "$GOAL")"
assert "row13: every forwarding branch uses exec (${_fwd_exec}/${_fwd_all})" \
  "$([ "$_fwd_exec" -ge 1 ] && [ "$_fwd_exec" -eq "$_fwd_all" ] && echo 0 || echo 1)"

echo "=== row 14: handoff-gen's own internal forwarding uses exec -- regression, AC-6 (hop 2), AC-10 ==="
assert "row14: lib/goal/handoff-gen execs python3 at column 0" \
  "$(grep -q '^exec python3' lib/goal/handoff-gen && echo 0 || echo 1)"

echo "=== row 15: verb string contains shell metacharacters -- security/abuse, AC-9 ==="
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
pwned="$d/pwned"
bash "$GOAL" "bad;touch $pwned" >/dev/null 2>&1
assert "row15: metachar verb is matched as one literal case pattern, never executed" \
  "$([ ! -e "$pwned" ] && echo 0 || echo 1)"
rm -rf "$d"; trap - EXIT

echo "=== row 16: forwarded arg contains shell metacharacters -- security/abuse, AC-1 ==="
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
pwned2="$d/pwned2"
bash "$GOAL" draft "; touch $pwned2" >/dev/null 2>&1
assert "row16: metachar forwarded arg reaches the sibling as inert argv, never executed" \
  "$([ ! -e "$pwned2" ] && echo 0 || echo 1)"
rm -rf "$d"; trap - EXIT

echo "=== row 17: merge bogus-subcmd vs direct mega-merge.sh bogus-subcmd -- regression, AC-10 (fidelity) ==="
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
bash "$GOAL" merge bogus-subcmd > "$d/via" 2>&1; via=$?
bash lib/goal/mega-merge.sh bogus-subcmd > "$d/direct" 2>&1; direct=$?
assert "row17: via-goal.sh and direct mega-merge.sh are byte-identical, both exit 64" \
  "$(cmp "$d/via" "$d/direct" >/dev/null 2>&1 && [ "$via" -eq 64 ] && [ "$direct" -eq 64 ] && echo 0 || echo 1)"
rm -rf "$d"; trap - EXIT

echo "=== row 18: EXIT-trap discriminator, merge's real exec vs a plain nested call -- regression, AC-10 ==="
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
cp -R lib "$d/"
awk '{ if ($0 == "main \"$@\"") print "trap '"'"'echo EXEC_DISCRIMINATOR_FIRED >&2'"'"' EXIT"; print }' "$d/lib/goal/goal.sh" > "$d/lib/goal/goal-trapped.sh"
if ! grep -q 'EXEC_DISCRIMINATOR' "$d/lib/goal/goal-trapped.sh"; then
  assert "row18: SETUP FAILED -- trap not injected into scratch goal-trapped.sh" 1
else
  out="$(bash "$d/lib/goal/goal-trapped.sh" merge bogus-subcmd 2>&1)"
  assert "row18: real exec discards the EXIT trap before it can fire (no marker)" \
    "$(grep -q EXEC_DISCRIMINATOR_FIRED <<<"$out" && echo 1 || echo 0)"
fi
rm -rf "$d"; trap - EXIT

echo "=== row 19: goal.sh \"\" extra args here -- boundary/edge, AC-7 (adjacent) ==="
assert "row19: empty-string verb + trailing args prints usage, byte-identical to row 7" \
  "$(cmp <(bash "$GOAL" "" extra args here) <(sed -n '2,13p' "$GOAL" | sed 's/^# \{0,1\}//') >/dev/null 2>&1 && echo 0 || echo 1)"

echo "=== row 20: registry claim <slug> <lane> <glob1> <glob2> <glob3> -- regression, AC-3, AC-1 (forwarding depth) ==="
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
out="$(GOAL_REGISTRY_DIR="$d" bash "$GOAL" registry claim testslug backend "glob/a/**" "glob/b/**" "glob/c/**")"; ec=$?
assert "row20: 3 trailing tokens forward intact through registry -> touches= line + success message" \
  "$([ "$ec" -eq 0 ] && [ "$out" = "CLAIMED testslug (lane=backend)" ] && grep -qxF 'touches=glob/a/** glob/b/** glob/c/**' "$d/testslug.goal" && echo 0 || echo 1)"
rm -rf "$d"; trap - EXIT

echo ""
echo "  ---------------------------------------------"
echo "  TOTAL: $TOTAL   PASS: $PASS   FAIL: $FAIL   SKIP: $SKIP"
[ "$FAIL" -eq 0 ] || exit 1
