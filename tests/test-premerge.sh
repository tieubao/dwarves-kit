#!/usr/bin/env bash
# test-premerge.sh -- ID-653: merge the default branch into the working branch before a PR
# opens, so a GitHub squash-merge never disagrees with a union-mergeable append-only log.
#
# Fixture: a bare "origin" whose default branch is main, and a work clone on a feature
# branch. Each case re-clones fresh so the cases stay independent.
#
# Run: bash tests/test-premerge.sh
#
# branch-guard: allow: every push here targets a throwaway bare repo under mktemp, never a
# real remote; the fixture needs a second clone pushing to simulate the default branch moving.

set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PM="$KIT_DIR/lib/gate/premerge.sh"

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
chk() {
  TOTAL=$((TOTAL+1))
  if [ "$2" -eq 0 ] 2>/dev/null; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1))
  else echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL+1)); fi
}
chk_has() { chk "$1" "$({ trap '' PIPE; printf '%s' "$2" 2>/dev/null || :; } | grep -qF -- "$3"; echo $?)"; }
chk_eq()  { chk "$1" "$([ "$2" = "$3" ]; echo $?)"; }

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/dk-premerge-test.XXXXXX")"
TMPD="$(cd "$TMPD" && pwd)"
trap 'rm -rf "$TMPD"' EXIT

git config --global init.defaultBranch main 2>/dev/null || true

# --------------------------------------------------------------------------- shared origin
ORIGIN="$TMPD/origin.git"
git init -q --bare -b main "$ORIGIN"

SEED="$TMPD/seed"
git clone -q "$ORIGIN" "$SEED" 2>/dev/null   # origin is still empty at this point; the clone warning is expected noise
( cd "$SEED" && git config user.email t@e && git config user.name t \
  && echo base > base.txt && git add base.txt && git commit -qm base \
  && git push -q origin main )

# clone_work <name> -- a fresh clone on a feature branch cut from main.
clone_work() {
  local name="$1"
  local wt="$TMPD/$name"
  git clone -q "$ORIGIN" "$wt"
  ( cd "$wt" && git config user.email t@e && git config user.name t && git switch -q -c feat/x )
  printf '%s\n' "$wt"
}

# advance_origin_main <content-line> <file> -- a second clone pushes directly to main.
advance_origin_main() {
  local file="$1"
  local line="$2"
  local other="$TMPD/advancer-$$-$RANDOM"
  git clone -q "$ORIGIN" "$other"
  ( cd "$other" && git config user.email o@e && git config user.name o \
    && printf '%s\n' "$line" > "$file" && git add "$file" && git commit -qm "advance $file" \
    && git push -q origin main )
  rm -rf "$other"
}

echo ""
echo "=== ID-653: premerge.sh check ==="
echo ""

# ---- Case A: branch already current with origin/main -> silent no-op, exit 0 ----
W="$(clone_work case-a)"
OUT="$(cd "$W" && bash "$PM" check . 2>&1)"; RC=$?
chk "already current: exit 0" "$([ "$RC" -eq 0 ]; echo $?)"
chk_eq "already current: no output at all" "" "$OUT"

# ---- Case B: origin/main moved, feature branch touched a different file -> clean merge ----
W="$(clone_work case-b)"
( cd "$W" && echo mine > mine.txt && git add mine.txt && git commit -qm "feature commit" )
FEAT_SHA="$(cd "$W" && git rev-parse HEAD)"
advance_origin_main theirs.txt "theirs" >/dev/null 2>&1
OUT="$(cd "$W" && bash "$PM" check . 2>&1)"; RC=$?
chk "clean merge: exit 0" "$([ "$RC" -eq 0 ]; echo $?)"
chk_has "clean merge: reports the merge" "$OUT" "premerge: merged origin/main into feat/x"
chk "clean merge: incoming file landed" "$([ -f "$W/theirs.txt" ]; echo $?)"
chk "clean merge: the feature commit still exists unchanged (no rewrite)" \
  "$(cd "$W" && git cat-file -e "$FEAT_SHA" 2>/dev/null; echo $?)"
PARENTS="$(cd "$W" && git log -1 --pretty=%P | wc -w | tr -d ' ')"
chk_eq "clean merge: HEAD is a real merge commit (2 parents), not a rebase" "2" "$PARENTS"

# ---- Case C: origin/main and the feature branch both touch the same line -> conflict, no auto-pick ----
W="$(clone_work case-c)"
( cd "$W" && printf 'mine\n' > base.txt && git add base.txt && git commit -qm "feature edits base.txt" )
advance_origin_main base.txt theirs >/dev/null 2>&1
OUT="$(cd "$W" && bash "$PM" check . 2>&1)"; RC=$?
chk "conflict: exit non-zero" "$([ "$RC" -ne 0 ]; echo $?)"
chk_has "conflict: message names the conflict, tells the caller to resolve" "$OUT" "does not merge cleanly"
chk_has "conflict: git left unmerged paths, nothing auto-committed" \
  "$(cd "$W" && git status --porcelain)" "UU base.txt"
chk_has "conflict: neither side silently won, markers are still in the file" \
  "$(cat "$W/base.txt")" "<<<<<<<"
chk_has "conflict: origin's side is present in the markers" "$(cat "$W/base.txt")" "theirs"
chk_has "conflict: the feature branch's own side is present in the markers" "$(cat "$W/base.txt")" "mine"

# ---- Case D: run from the default branch itself -> nothing to premerge, silent no-op ----
W="$(clone_work case-d)"
( cd "$W" && git switch -q main )
OUT="$(cd "$W" && bash "$PM" check . 2>&1)"; RC=$?
chk "on the default branch: exit 0" "$([ "$RC" -eq 0 ]; echo $?)"
chk_eq "on the default branch: no output" "" "$OUT"

# ---- Case E: not a git repo -> refuses, does not crash ----
NOTREPO="$TMPD/not-a-repo"
mkdir -p "$NOTREPO"
OUT="$(bash "$PM" check "$NOTREPO" 2>&1)"; RC=$?
chk "not a repo: exit non-zero" "$([ "$RC" -ne 0 ]; echo $?)"
chk_has "not a repo: says so" "$OUT" "is not a git repo"

# ---- Source pins: the safety claims are true of the code, not just this fixture ----
RC=0; grep -q -- '--force' "$PM" && RC=1
chk "source pin: premerge.sh never force-pushes" "$RC"
RC=0; grep -v '^[[:space:]]*#' "$PM" | grep -q 'rebase' && RC=1
chk "source pin: premerge.sh never invokes rebase outside a comment" "$RC"
RC=0; grep -qE -- '-X (ours|theirs)' "$PM" && RC=1
chk "source pin: premerge.sh never auto-picks a side on conflict" "$RC"

echo ""
echo "$PASS/$TOTAL passed"
[ "$FAIL" -eq 0 ]
