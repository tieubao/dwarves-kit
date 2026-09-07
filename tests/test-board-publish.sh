#!/usr/bin/env bash
# test-board-publish.sh -- `board publish`, the git leg of SPEC-002's
# intake -> publish -> relay sequencing (ops-toolkit ID-638).
#
# Proves:
#   AC1  a spoke-dirtied board file is committed (chore(board) subject) and
#        pushed to the remote; ONLY the board file is staged (other dirt stays)
#   AC2  no board changes -> no commit, exit 0
#   AC3  a worktree checkout path is refused (same fence as sync)
#   AC4  push failure (no remote) keeps the local commit, warns, exit 3
#   AC5  diverged remote, non-conflicting upstream edit -> rebase + push
#   AC6  diverged remote, conflicting board edit -> no markers, abort, rc 3
#   AC7  detached HEAD refused (exit 2)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BOARD_SH="$HERE/../lib/board/board.sh"
WORK="$(mktemp -d)"
trap 'command rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

mkrepo() {  # <dir> ; creates repo with _meta/BACKLOG.md + a bare origin
  local d="$1"
  git init -q -b main "$d"
  mkdir -p "$d/_meta"
  printf '| ID | Item | Notes & source | Status |\n|---|---|---|---|\n| ID-1 | thing | notes | queued |\n' > "$d/_meta/BACKLOG.md"
  git -C "$d" -c user.email=t@t -c user.name=t add -A
  git -C "$d" -c user.email=t@t -c user.name=t commit -qm init
  git init -q --bare "$d.remote"
  git -C "$d" remote add origin "$d.remote"
  git -C "$d" push -q -u origin main
}

echo "case AC1 (dirty board -> committed + pushed; other dirt untouched):"
mkrepo "$WORK/r1"
printf '| ID-2 | new row | from spoke | queued |\n' >> "$WORK/r1/_meta/BACKLOG.md"
echo scratch > "$WORK/r1/other.txt"
out="$(cd "$WORK/r1" && GIT_AUTHOR_EMAIL=t@t GIT_AUTHOR_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_COMMITTER_NAME=t \
  bash "$BOARD_SH" publish --backlog-file "$WORK/r1/_meta/BACKLOG.md" 2>&1)"
git -C "$WORK/r1" log -1 --format=%s | grep -q "chore(board): publish spoke updates" \
  && ok "board commit created" || bad "no publish commit: $(git -C "$WORK/r1" log -1 --format=%s)"
git -C "$WORK/r1.remote" log -1 --format=%s main 2>/dev/null | grep -q "chore(board)" \
  && ok "pushed to origin" || bad "remote missing the publish commit"
git -C "$WORK/r1" status --porcelain | grep -q "other.txt" \
  && ok "unrelated dirt left untouched" || bad "unrelated file was swept into the commit"
{ trap '' PIPE; echo "$out" 2>/dev/null || :; } | grep -q "pushed" && ok "reports pushed" || bad "no pushed report: $out"

echo "case AC2 (clean board -> no commit):"
before="$(git -C "$WORK/r1" rev-parse HEAD)"
out="$(cd "$WORK/r1" && bash "$BOARD_SH" publish --backlog-file "$WORK/r1/_meta/BACKLOG.md" 2>&1)"
[ "$(git -C "$WORK/r1" rev-parse HEAD)" = "$before" ] \
  && ok "HEAD unchanged" || bad "a commit appeared with no board changes"
{ trap '' PIPE; echo "$out" 2>/dev/null || :; } | grep -q "no board changes" && ok "honest no-op report" || bad "no no-op report: $out"

echo "case AC3 (worktree path refused):"
mkdir -p "$WORK/r2/.claude/worktrees/x/_meta"
printf '| ID | Item | Notes & source | Status |\n|---|---|---|---|\n' > "$WORK/r2/.claude/worktrees/x/_meta/BACKLOG.md"
out="$(bash "$BOARD_SH" publish --backlog-file "$WORK/r2/.claude/worktrees/x/_meta/BACKLOG.md" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "nonzero exit" || bad "worktree path accepted (rc=0)"
{ trap '' PIPE; echo "$out" 2>/dev/null || :; } | grep -q "refusing a worktree" && ok "refusal names the fence" || bad "no refusal message: $out"

echo "case AC4 (push failure -> commit kept, warn, exit 3):"
mkrepo "$WORK/r3"
command rm -rf "$WORK/r3.remote"   # kill the remote so push fails
printf '| ID-3 | another row | x | queued |\n' >> "$WORK/r3/_meta/BACKLOG.md"
out="$(cd "$WORK/r3" && GIT_AUTHOR_EMAIL=t@t GIT_AUTHOR_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_COMMITTER_NAME=t \
  bash "$BOARD_SH" publish --backlog-file "$WORK/r3/_meta/BACKLOG.md" 2>&1)"; rc=$?
[ "$rc" -eq 3 ] && ok "exit 3 on push failure (monitoring signal, commit preserved)" || bad "expected rc 3, got: $rc"
git -C "$WORK/r3" log -1 --format=%s | grep -q "chore(board)" \
  && ok "local commit kept" || bad "no local commit after push failure"
{ trap '' PIPE; echo "$out" 2>/dev/null || :; } | grep -q "WARN" && ok "push failure warns honestly" || bad "no push warning: $out"

echo "case AC5 (diverged remote, NON-conflicting upstream edit -> rebase + push):"
mkrepo "$WORK/r4"
git clone -q -b main "$WORK/r4.remote" "$WORK/r4b" && cd "$WORK/r4b" || bad "clone failed"
printf 'upstream note\n' >> "$WORK/r4b/README.md" 2>/dev/null || printf 'upstream note\n' > "$WORK/r4b/README.md"
git -C "$WORK/r4b" -c user.email=t@t -c user.name=t add -A
git -C "$WORK/r4b" -c user.email=t@t -c user.name=t commit -qm "upstream: unrelated"
git -C "$WORK/r4b" push -q origin main
printf '| ID-4 | diverge row | x | queued |\n' >> "$WORK/r4/_meta/BACKLOG.md"
out="$(cd "$WORK/r4" && GIT_AUTHOR_EMAIL=t@t GIT_AUTHOR_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_COMMITTER_NAME=t \
  bash "$BOARD_SH" publish --backlog-file "$WORK/r4/_meta/BACKLOG.md" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0 after rebase+push" || bad "rc=$rc: $out"
git -C "$WORK/r4.remote" log --format=%s main | grep -q "chore(board)" \
  && ok "publish commit reached the diverged remote" || bad "remote missing publish commit after rebase"

echo "case AC6 (diverged remote, CONFLICTING board edit -> no markers, abort, rc 3):"
mkrepo "$WORK/r5"
git clone -q -b main "$WORK/r5.remote" "$WORK/r5b"
# same line edited differently on both sides = guaranteed rebase conflict
sed -i '' 's/| ID-1 | thing | notes | queued |/| ID-1 | thing | notes | executing |/' "$WORK/r5b/_meta/BACKLOG.md"
git -C "$WORK/r5b" -c user.email=t@t -c user.name=t add -A
git -C "$WORK/r5b" -c user.email=t@t -c user.name=t commit -qm "upstream: conflicting board edit"
git -C "$WORK/r5b" push -q origin main
sed -i '' 's/| ID-1 | thing | notes | queued |/| ID-1 | thing | notes | parked |/' "$WORK/r5/_meta/BACKLOG.md"
out="$(cd "$WORK/r5" && GIT_AUTHOR_EMAIL=t@t GIT_AUTHOR_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_COMMITTER_NAME=t \
  bash "$BOARD_SH" publish --backlog-file "$WORK/r5/_meta/BACKLOG.md" 2>&1)"; rc=$?
[ "$rc" -eq 3 ] && ok "conflicting divergence exits 3" || bad "rc=$rc (want 3): $out"
grep -q '<<<<<<<' "$WORK/r5/_meta/BACKLOG.md" \
  && bad "CONFLICT MARKERS in the working board file" || ok "no conflict markers in the board file"
git -C "$WORK/r5" log -1 --format=%s | grep -qE "chore\(board\)|upstream" \
  && ok "checkout not wedged (HEAD readable, commit intact)" || bad "checkout in a broken state"
[ -z "$(git -C "$WORK/r5" ls-files -u)" ] && ok "no unmerged index entries" || bad "unmerged index left behind"

echo "case AC7 (detached HEAD refused):"
git -C "$WORK/r1" checkout -q --detach HEAD
printf '| ID-5 | detached row | x | queued |\n' >> "$WORK/r1/_meta/BACKLOG.md"
out="$(bash "$BOARD_SH" publish --backlog-file "$WORK/r1/_meta/BACKLOG.md" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ok "detached HEAD exits 2" || bad "rc=$rc (want 2)"
{ trap '' PIPE; echo "$out" 2>/dev/null || :; } | grep -q "detached HEAD" && ok "refusal names detached HEAD" || bad "no detached-HEAD message: $out"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
