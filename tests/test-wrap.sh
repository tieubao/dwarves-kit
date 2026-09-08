#!/usr/bin/env bash
# test-wrap.sh -- SPEC-246 TASK-001: the whole acceptance matrix for `bin/wrap` and
# `lib/wrap/wrap.sh`.
#
# Fixture: three bare remotes whose default branches are `main`, `master` and `develop`,
# each with the branch set the gates discriminate on (merged-ancestor, unmerged, squash-ok,
# squash-stale, stacked-child, wt-clean, wt-dirty), clones with three secondary worktrees
# (clean, dirty, detached), a clone whose origin/HEAD dangles, and a repo with no remote.
# `gh` is a stub on PATH driven by env vars; it records every call so the merge case can
# assert the exact flags.
#
# Run: bash tests/test-wrap.sh

set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAP="$KIT_DIR/bin/wrap"

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
chk() {
  TOTAL=$((TOTAL+1))
  if [ "$2" -eq 0 ] 2>/dev/null; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1))
  else echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL+1)); fi
}
chk_has() { chk "$1" "$({ trap '' PIPE; printf '%s' "$2" 2>/dev/null || :; } | grep -qF -- "$3"; echo $?)"; }
chk_no()  { chk "$1" "$({ trap '' PIPE; printf '%s' "$2" 2>/dev/null || :; } | grep -qF -- "$3" && echo 1 || echo 0)"; }

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/dk-wrap-test.XXXXXX")"
TMPD="$(cd "$TMPD" && pwd)"
trap 'chmod -R u+w "$TMPD" 2>/dev/null; rm -rf "$TMPD"' EXIT

# Pin the operator config overlay at a path that does not exist, so the operator's REAL
# ~/.config/dwarves-kit/kit.toml can never reach a case that does not set it deliberately.
KIT_CONFIG_OPERATOR="$TMPD/no-operator-config"; export KIT_CONFIG_OPERATOR

# --------------------------------------------------------------------------- gh stub
mkdir -p "$TMPD/stub"
cat > "$TMPD/stub/gh" <<'STUB'
#!/usr/bin/env bash
# gh stub: answers exactly what wrap.sh asks and records every call.
printf '%s\n' "$*" >> "${GH_STUB_CALLS:-/dev/null}"
sub="${1:-}"; [ $# -gt 0 ] && shift
case "$sub" in
  auth)
    [ "${GH_STUB_UNAUTH:-0}" = "1" ] && exit 1
    exit 0 ;;
  pr)
    verb="${1:-}"; [ $# -gt 0 ] && shift
    case "$verb" in
      list)
        head=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --head) head="${2:-}"; shift 2 ;;
            *) shift ;;
          esac
        done
        if [ -n "$head" ]; then
          key="GH_STUB_MERGED_$(printf '%s' "$head" | tr -c 'A-Za-z0-9' '_')"
          eval "val=\"\${$key:-}\""
          [ -n "$val" ] || val="[]"
          printf '%s\n' "$val"
        else
          printf '%s\n' "${GH_STUB_OPEN_PRS:-[]}"
        fi
        exit 0 ;;
      view)
        n="${1:-}"; [ $# -gt 0 ] && shift
        fields=""
        while [ $# -gt 0 ]; do
          case "$1" in --json) fields="${2:-}"; shift 2 ;; *) shift ;; esac
        done
        case "$fields" in
          state,mergeCommit)
            default_state='{"state":"MERGED","mergeCommit":{"oid":"1a2b3c4d5e6f"}}'
            printf '%s\n' "${GH_STUB_VIEW_STATE:-$default_state}" ;;
          *)
            key="GH_STUB_PR_$n"; eval "val=\"\${$key:-}\""
            [ -n "$val" ] || val="{}"
            printf '%s\n' "$val" ;;
        esac
        exit 0 ;;
      merge) exit "${GH_STUB_MERGE_RC:-0}" ;;
    esac
    exit 1 ;;
esac
exit 1
STUB
chmod +x "$TMPD/stub/gh"
PATH="$TMPD/stub:$PATH"; export PATH
GH_STUB_CALLS="$TMPD/gh-calls.log"; export GH_STUB_CALLS; : > "$GH_STUB_CALLS"

# --------------------------------------------------------------------------- fixture
gitc() { git -C "$1" config user.email t@t; git -C "$1" config user.name t; git -C "$1" config commit.gpgsign false; }

build_remote() { # build_remote <name> <default branch>
  local name="$1" def="$2" work="$TMPD/work-$1" b
  mkdir -p "$work"
  git -C "$work" init -q
  gitc "$work"
  git -C "$work" symbolic-ref HEAD "refs/heads/$def"
  echo base > "$work/a.txt"; git -C "$work" add -A; git -C "$work" commit -qm base
  git -C "$work" branch merged-ancestor
  echo second >> "$work/a.txt"; git -C "$work" commit -qam second
  for b in unmerged squash-ok squash-stale stacked-child wt-clean wt-dirty; do
    git -C "$work" branch "$b"
    git -C "$work" checkout -q "$b"
    echo "$b" > "$work/$b.txt"; git -C "$work" add -A; git -C "$work" commit -qm "$b"
  done
  git -C "$work" checkout -q "$def"
  git clone -q --bare "$work" "$TMPD/bare-$name"
}

make_clone() { # make_clone <name> <remote name> <default branch> <checkout branch>
  local name="$1" rname="$2" def="$3" co="$4" clone="$TMPD/clone-$1" b
  git clone -q "$TMPD/bare-$rname" "$clone"
  gitc "$clone"
  git -C "$clone" remote set-head origin "$def" >/dev/null 2>&1
  for b in merged-ancestor unmerged squash-ok squash-stale stacked-child wt-clean wt-dirty; do
    git -C "$clone" branch "$b" "origin/$b" >/dev/null 2>&1
  done
  git -C "$clone" worktree add "$TMPD/wt-$name-clean" wt-clean >/dev/null 2>&1
  git -C "$clone" worktree add "$TMPD/wt-$name-dirty" wt-dirty >/dev/null 2>&1
  echo dirt > "$TMPD/wt-$name-dirty/dirt.txt"
  git -C "$clone" worktree add --detach "$TMPD/wt-$name-det" HEAD >/dev/null 2>&1
  git -C "$clone" checkout -q "$co"
}

set_stub() { # set_stub <remote name> <default branch>
  local bare="$TMPD/bare-$1" def="$2"
  export GH_STUB_MERGED_squash_ok="[{\"headRefOid\":\"$(git -C "$bare" rev-parse squash-ok)\",\"baseRefName\":\"$def\",\"mergedAt\":\"2026-01-01T00:00:00Z\"}]"
  export GH_STUB_MERGED_squash_stale="[{\"headRefOid\":\"1111111111111111111111111111111111111111\",\"baseRefName\":\"$def\",\"mergedAt\":\"2026-01-01T00:00:00Z\"}]"
  export GH_STUB_MERGED_stacked_child="[{\"headRefOid\":\"$(git -C "$bare" rev-parse stacked-child)\",\"baseRefName\":\"feat/parent\",\"mergedAt\":\"2026-01-01T00:00:00Z\"}]"
}

build_remote rmain main
build_remote rmaster master
build_remote rdev develop

export GH_STUB_OPEN_PRS='[{"number":7,"title":"wrap the session","headRefName":"feat/wrap"}]'
PR7_OID=deadbeefcafe1234567890abcdef1234567890ab
export GH_STUB_PR_7="{\"number\":7,\"title\":\"wrap the session\",\"headRefName\":\"feat/wrap\",\"headRefOid\":\"$PR7_OID\",\"baseRefName\":\"main\",\"mergeable\":\"MERGEABLE\",\"mergeStateStatus\":\"CLEAN\",\"reviewDecision\":\"APPROVED\",\"statusCheckRollup\":[{\"conclusion\":\"SUCCESS\"},{\"conclusion\":\"SKIPPED\"}]}"

# ===========================================================================
echo "=== scan: every verdict, for main, master and develop defaults ==="
# ===========================================================================
for pair in "rmain main" "rmaster master" "rdev develop"; do
  set -- $pair
  rname="$1"; def="$2"
  make_clone "scan-$def" "$rname" "$def" unmerged
  set_stub "$rname" "$def"
  out="$("$WRAP" scan "$TMPD/clone-scan-$def" 2>&1)"
  chk_has "scan/$def: ahead-behind line names origin/$def" "$out" "-- vs origin/$def: ahead="
  chk_has "scan/$def: merged-ancestor is SAFE-d" "$out" "merged-ancestor  [SAFE-d: ancestor of origin/$def]"
  chk_has "scan/$def: squash-ok is squash-merged" "$out" "squash-ok  [SQUASH-MERGED per gh: safe to -D]"
  chk_has "scan/$def: squash-stale is LEAVE" "$out" "squash-stale  [NOT merged / unknown: LEAVE]"
  chk_has "scan/$def: unmerged is LEAVE" "$out" "unmerged  [NOT merged / unknown: LEAVE]"
  chk_has "scan/$def: the open PR is listed" "$out" "#7 wrap the session [feat/wrap]"
  chk_has "scan/$def: checkout line" "$out" "-- checkout on: unmerged"
done

echo "=== scan: the gh calls carry the origin URL the repo actually has ==="
set_stub rmain main
SCAN_URL="$(git -C "$TMPD/clone-scan-main" remote get-url origin)"
: > "$GH_STUB_CALLS"
"$WRAP" scan "$TMPD/clone-scan-main" >/dev/null 2>&1
SCAN_CALLS="$(cat "$GH_STUB_CALLS")"
chk_has "scan: pr list names --repo and --head" "$SCAN_CALLS" \
  "pr list --repo ${SCAN_URL} --head squash-ok"
chk_has "scan: the open-PR query names --repo" "$SCAN_CALLS" "pr list --repo ${SCAN_URL} --author"

echo "=== scan: a non-repo argument is skipped, the repo after it still reports ==="
out="$("$WRAP" scan "$TMPD/not-a-repo" "$TMPD/clone-scan-main" 2>&1)"
chk_has "scan: non-repo prints the skip line" "$out" "not a git repo, skipped"
chk_has "scan: the following repo still reports" "$out" "-- vs origin/main: ahead="

# ===========================================================================
echo "=== apply dry-run: every SKIP reason, and no write ==="
# ===========================================================================
set_stub rmain main
DRY="$TMPD/clone-scan-main"
before_b="$(git -C "$DRY" branch --list)"
before_w="$(git -C "$DRY" worktree list)"
out="$("$WRAP" apply "$DRY" 2>&1)"; rc=$?
chk "apply dry-run exits 0" "$rc"
chk_has "apply dry-run: wt-clean skipped without --worktrees" "$out" "--worktrees not given"
chk_has "apply dry-run: the checked-out branch is skipped" "$out" "SKIP unmerged: currently checked out"
chk_has "apply dry-run: squash-stale names both short SHAs" "$out" "SKIP squash-stale: tip $(git -C "$DRY" rev-parse squash-stale | cut -c1-7) != merged PR head 1111111"
chk_has "apply dry-run: stacked-child names the other base" "$out" "SKIP stacked-child: merged into feat/parent, not the default branch"
chk_has "apply dry-run: pull skipped off the default branch" "$out" "SKIP pull: checkout on 'unmerged', not the default branch main"
chk_has "apply dry-run: the deletes are announced, not run" "$out" "[DRY-RUN] delete merged-ancestor"

out="$("$WRAP" apply --worktrees "$DRY" 2>&1)"; rc=$?
chk "apply dry-run --worktrees exits 0" "$rc"
chk_has "apply dry-run: the dirty worktree is skipped" "$out" "dirty (another session's work stays)"
chk_has "apply dry-run: the detached worktree is skipped" "$out" "detached HEAD (removal could orphan the commit)"
after_b="$(git -C "$DRY" branch --list)"
after_w="$(git -C "$DRY" worktree list)"
chk "apply without --apply changes no branch (byte-equal)" "$([ "$before_b" = "$after_b" ]; echo $?)"
chk "apply without --apply changes no worktree (byte-equal)" "$([ "$before_w" = "$after_w" ]; echo $?)"

# ===========================================================================
echo "=== apply --apply --worktrees: only the proven deletes, and a ff pull ==="
# ===========================================================================
make_clone apply-main rmain main main
# Advance the remote default branch so the pull has something to fast-forward to.
git clone -q "$TMPD/bare-rmain" "$TMPD/pusher"
gitc "$TMPD/pusher"
echo advance >> "$TMPD/pusher/a.txt"
git -C "$TMPD/pusher" commit -qam advance
git -C "$TMPD/pusher" push -q origin main
NEW_TIP="$(git -C "$TMPD/bare-rmain" rev-parse main)"

set_stub rmain main
APPLYREPO="$TMPD/clone-apply-main"
out="$("$WRAP" apply --apply --worktrees "$APPLYREPO" 2>&1)"; rc=$?
chk "apply --apply exits 0 on a healthy repo" "$rc"
branches="$(git -C "$APPLYREPO" for-each-ref --format='%(refname:short)' refs/heads/ | sort | tr '\n' ' ')"
chk "apply --apply deleted merged-ancestor and squash-ok only" \
  "$([ "$branches" = "main squash-stale stacked-child unmerged wt-clean wt-dirty " ]; echo $?)"
chk_no "apply --apply never touched the default branch" "$out" "delete main"
chk "apply --apply removed the clean worktree only" \
  "$([ ! -d "$TMPD/wt-apply-main-clean" ] && [ -d "$TMPD/wt-apply-main-dirty" ] && [ -d "$TMPD/wt-apply-main-det" ]; echo $?)"
chk "apply --apply fast-forwarded the default branch" \
  "$([ "$(git -C "$APPLYREPO" rev-parse HEAD)" = "$NEW_TIP" ]; echo $?)"

# ===========================================================================
echo "=== apply --apply: a non-ff default branch is FAILED, exit 2, never forced ==="
# ===========================================================================
make_clone apply-nonff rmaster master master
OLD_MASTER="$(git -C "$TMPD/clone-apply-nonff" rev-parse master)"
git clone -q "$TMPD/bare-rmaster" "$TMPD/rewriter"
gitc "$TMPD/rewriter"
git -C "$TMPD/rewriter" reset -q --hard HEAD~1
echo divergent > "$TMPD/rewriter/divergent.txt"
git -C "$TMPD/rewriter" add -A; git -C "$TMPD/rewriter" commit -qm divergent
git -C "$TMPD/rewriter" push -q --force origin HEAD:refs/heads/master
set_stub rmaster master
out="$("$WRAP" apply --apply "$TMPD/clone-apply-nonff" 2>&1)"; rc=$?
chk "apply --apply exits 2 when a write fails" "$([ "$rc" -eq 2 ]; echo $?)"
chk_has "apply --apply reports the failed pull" "$out" "FAILED pull --ff-only"
chk "apply --apply never reset the local default branch" \
  "$([ "$(git -C "$TMPD/clone-apply-nonff" rev-parse master)" = "$OLD_MASTER" ]; echo $?)"

# ===========================================================================
echo "=== apply: a tip that moved during the run is skipped, not deleted ==="
# ===========================================================================
make_clone tips rmain main unmerged
set_stub rmain main
TIPSREPO="$TMPD/clone-tips"
STALE_TIPS="$TMPD/stale-tips.txt"
git -C "$TIPSREPO" for-each-ref --format='%(refname:short) %(objectname)' refs/heads/ > "$STALE_TIPS"
# Rewrite merged-ancestor's recorded tip so the pre-delete re-check sees a moved branch.
sed 's/^merged-ancestor .*/merged-ancestor 2222222222222222222222222222222222222222/' \
  "$STALE_TIPS" > "$STALE_TIPS.new" && mv -f "$STALE_TIPS.new" "$STALE_TIPS"
out="$("$WRAP" apply --apply --tips-file "$STALE_TIPS" "$TIPSREPO" 2>&1)"
chk_has "apply: a moved tip is skipped" "$out" "SKIP merged-ancestor: tip moved during this run"
chk "apply: the moved-tip branch survives" \
  "$(git -C "$TIPSREPO" show-ref --verify --quiet refs/heads/merged-ancestor; echo $?)"
chk "apply: the unmoved squash-ok branch still went" \
  "$(git -C "$TIPSREPO" show-ref --verify --quiet refs/heads/squash-ok && echo 1 || echo 0)"

# ===========================================================================
echo "=== apply: index.lock age decides, and a non-repo never reaches a write ==="
# ===========================================================================
make_clone lock rmain main unmerged
set_stub rmain main
LOCKREPO="$TMPD/clone-lock"
touch -t 202601010000 "$LOCKREPO/.git/index.lock"
out="$("$WRAP" apply --apply "$LOCKREPO" 2>&1)"
chk_has "apply: a stale index.lock refuses every write" "$out" "index.lock held by another writer"
LOCK_BRANCHES="$(git -C "$LOCKREPO" for-each-ref --format='%(refname:short)' refs/heads/ | sort | tr '\n' ' ')"
chk "apply: a stale index.lock deleted nothing" \
  "$([ "$LOCK_BRANCHES" = "main merged-ancestor squash-ok squash-stale stacked-child unmerged wt-clean wt-dirty " ]; echo $?)"

# A young lock that clears within the window is ordinary traffic: release it after 2 s from
# the background and the write proceeds. A young lock that persists is a writer (next case).
rm -f "$LOCKREPO/.git/index.lock"; touch "$LOCKREPO/.git/index.lock"
( sleep 2; rm -f "$LOCKREPO/.git/index.lock" ) &
out="$("$WRAP" apply --apply "$LOCKREPO" 2>&1)"
wait
chk_no "apply: a fresh index.lock that clears does not refuse the write" "$out" "index.lock held by another writer"
chk "apply: a fresh index.lock that clears still deleted the proven branches" \
  "$(git -C "$LOCKREPO" show-ref --verify --quiet refs/heads/merged-ancestor && echo 1 || echo 0)"
touch "$LOCKREPO/.git/index.lock"
out="$("$WRAP" apply --apply "$LOCKREPO" 2>&1)"
chk_has "apply: a fresh index.lock that persists past the window refuses the write" "$out" "index.lock held by another writer"
rm -f "$LOCKREPO/.git/index.lock"

out="$("$WRAP" apply --apply "$TMPD/not-a-repo" "$LOCKREPO" 2>&1)"
chk_has "apply: a non-repo argument is skipped before any write" "$out" "not a git repo, skipped"
chk_has "apply: the repo after the non-repo still runs" "$out" "-- branches:"

# ===========================================================================
echo "=== apply: a broken origin URL fails the fetch and deletes nothing ==="
# ===========================================================================
make_clone brokenremote rmain main unmerged
set_stub rmain main
BROKEN="$TMPD/clone-brokenremote"
BROKEN_BEFORE="$(git -C "$BROKEN" for-each-ref --format='%(refname:short)' refs/heads/ | sort)"
git -C "$BROKEN" remote set-url origin /nonexistent
out="$("$WRAP" apply --apply "$BROKEN" 2>&1)"
chk_has "apply: the failed fetch is reported" "$out" "(fetch failed; every delete is skipped)"
chk_has "apply: the ancestor branch names the stale-data reason" "$out" \
  "SKIP merged-ancestor: fetch failed, stale ancestor data"
chk "apply: the broken-remote repo lost no branch" \
  "$([ "$BROKEN_BEFORE" = "$(git -C "$BROKEN" for-each-ref --format='%(refname:short)' refs/heads/ | sort)" ]; echo $?)"

# ===========================================================================
echo "=== gh absent: every non-ancestor is LEAVE, merge refuses ==="
# ===========================================================================
mkdir -p "$TMPD/nogh"
for t in bash env git jq sed awk grep date stat mktemp readlink mv rm cat tr sort head cut basename dirname chmod; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$TMPD/nogh/$t"
done
chk "the gh-free PATH really has no gh" "$(PATH="$TMPD/nogh" command -v gh >/dev/null 2>&1 && echo 1 || echo 0)"
out="$(PATH="$TMPD/nogh" "$WRAP" scan "$TMPD/clone-scan-main" 2>&1)"
chk_has "scan without gh: squash-ok falls back to LEAVE" "$out" "squash-ok  [NOT merged / unknown: LEAVE]"
chk_has "scan without gh: the PR line says so" "$out" "(gh unavailable)"
out="$(PATH="$TMPD/nogh" "$WRAP" merge "$TMPD/clone-scan-main" 2>&1)"; rc=$?
chk "merge without gh exits 1" "$([ "$rc" -eq 1 ]; echo $?)"
chk_has "merge without gh names the reason" "$out" "(gh unavailable)"

echo "=== gh unauthenticated: the same verdicts, merge still refuses ==="
out="$(GH_STUB_UNAUTH=1 "$WRAP" scan "$TMPD/clone-scan-main" 2>&1)"
chk_has "scan unauthenticated: squash-ok falls back to LEAVE" "$out" "squash-ok  [NOT merged / unknown: LEAVE]"
chk_has "scan unauthenticated: the PR line says so" "$out" "(gh unauthenticated)"
out="$(GH_STUB_UNAUTH=1 "$WRAP" merge "$TMPD/clone-scan-main" 2>&1)"; rc=$?
chk "merge unauthenticated exits 1" "$([ "$rc" -eq 1 ]; echo $?)"
chk_has "merge unauthenticated names the reason" "$out" "(gh unauthenticated)"

# ===========================================================================
echo "=== merge: dry-run lists the eligible PR, --apply merges exactly one ==="
# ===========================================================================
: > "$GH_STUB_CALLS"
out="$("$WRAP" merge "$TMPD/clone-scan-main" 2>&1)"; rc=$?
chk "merge dry-run exits 0" "$rc"
chk_has "merge dry-run lists the PR as eligible" "$out" "eligible #7 wrap the session [feat/wrap]"
chk "merge dry-run calls no pr merge" "$(grep -q '^pr merge' "$GH_STUB_CALLS" && echo 1 || echo 0)"

: > "$GH_STUB_CALLS"
out="$("$WRAP" merge --apply "$TMPD/clone-scan-main" 2>&1)"; rc=$?
chk "merge --apply exits 0" "$rc"
chk_has "merge --apply reports the merge SHA" "$out" "merged #7 1a2b3c4d5e6f"
chk "merge --apply called pr merge exactly once" "$([ "$(grep -c '^pr merge' "$GH_STUB_CALLS")" -eq 1 ]; echo $?)"
chk "merge --apply passed --squash" "$(grep -q '^pr merge 7 .*--squash' "$GH_STUB_CALLS"; echo $?)"
chk "merge --apply passed no --delete-branch" "$(grep -q -- '--delete-branch' "$GH_STUB_CALLS" && echo 1 || echo 0)"
chk "merge --apply passed no --auto" "$(grep -q -- '--auto' "$GH_STUB_CALLS" && echo 1 || echo 0)"
chk "merge --apply verified through pr view" "$(grep -q '^pr view 7 .*state,mergeCommit' "$GH_STUB_CALLS"; echo $?)"
MERGE_URL="$(git -C "$TMPD/clone-scan-main" remote get-url origin)"
MERGE_CALLS="$(cat "$GH_STUB_CALLS")"
chk_has "merge --apply pinned the head it gated on" "$MERGE_CALLS" \
  "pr merge 7 --repo ${MERGE_URL} --squash --match-head-commit ${PR7_OID}"
chk_has "merge: the detail read names --repo" "$MERGE_CALLS" "pr view 7 --repo ${MERGE_URL}"
chk "merge reads each PR detail exactly once" \
  "$([ "$(grep -c "^pr view 7 --repo ${MERGE_URL} --json number,title" "$GH_STUB_CALLS")" -eq 1 ]; echo $?)"

echo "=== merge: the checks gate refuses pending, failing, empty-and-unstable, and changes requested ==="
gate_verdict() { # gate_verdict <pr json>
  GH_STUB_OPEN_PRS='[{"number":9,"title":"gate case","headRefName":"feat/gate"}]' \
  GH_STUB_PR_9="$1" "$WRAP" merge "$TMPD/clone-scan-main" 2>&1
}
out="$(gate_verdict '{"number":9,"title":"gate case","headRefName":"feat/gate","headRefOid":"aa","baseRefName":"main","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"APPROVED","statusCheckRollup":[{"conclusion":"SUCCESS"},{"status":"PENDING"}]}')"
chk_has "merge: a pending check skips" "$out" "SKIP #9 gate case: checks are pending or failing"
out="$(gate_verdict '{"number":9,"title":"gate case","headRefName":"feat/gate","headRefOid":"aa","baseRefName":"main","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"APPROVED","statusCheckRollup":[{"conclusion":"FAILURE"}]}')"
chk_has "merge: a failing check skips" "$out" "SKIP #9 gate case: checks are pending or failing"
out="$(gate_verdict '{"number":9,"title":"gate case","headRefName":"feat/gate","headRefOid":"aa","baseRefName":"main","mergeable":"MERGEABLE","mergeStateStatus":"UNSTABLE","reviewDecision":"APPROVED","statusCheckRollup":[]}')"
chk_has "merge: an empty rollup on a non-CLEAN state skips" "$out" "SKIP #9 gate case: checks are pending or failing"
out="$(gate_verdict '{"number":9,"title":"gate case","headRefName":"feat/gate","headRefOid":"aa","baseRefName":"main","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"APPROVED","statusCheckRollup":null}')"
chk_has "merge: a null rollup on a CLEAN state stays eligible" "$out" "eligible #9 gate case [feat/gate]"
out="$(gate_verdict '{"number":9,"title":"gate case","headRefName":"feat/gate","headRefOid":"aa","baseRefName":"main","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"APPROVED","statusCheckRollup":[]}')"
chk_has "merge: an empty rollup on a CLEAN state stays eligible" "$out" "eligible #9 gate case [feat/gate]"
out="$(gate_verdict '{"number":9,"title":"gate case","headRefName":"feat/gate","headRefOid":"aa","baseRefName":"main","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"CHANGES_REQUESTED","statusCheckRollup":[{"conclusion":"SUCCESS"}]}')"
chk_has "merge: changes requested skips" "$out" "SKIP #9 gate case: changes requested"

echo "=== merge: unparseable PR JSON skips instead of passing the gate ==="
out="$(gate_verdict 'not json at all')"
chk_has "merge: unreadable JSON skips" "$out" "SKIP #9: unreadable PR JSON"

echo "=== merge: a stacked parent with an open dependent skips, naming the retarget rule ==="
STACK_OPEN='[{"number":7,"title":"parent","headRefName":"feat/wrap"},{"number":8,"title":"child","headRefName":"feat/child"}]'
STACK_8='{"number":8,"title":"child","headRefName":"feat/child","baseRefName":"feat/wrap","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"APPROVED","statusCheckRollup":[]}'
STACK_7='{"number":7,"title":"parent","headRefName":"feat/wrap","baseRefName":"main","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"APPROVED","statusCheckRollup":[]}'
out="$(GH_STUB_OPEN_PRS="$STACK_OPEN" GH_STUB_PR_7="$STACK_7" GH_STUB_PR_8="$STACK_8" "$WRAP" merge "$TMPD/clone-scan-main" 2>&1)"
chk_has "merge skips the stacked parent" "$out" "SKIP #7 parent: dependents open, retarget them first (SPEC-065)"
chk_has "merge skips the child whose base is not the default branch" "$out" "SKIP #8 child: base is feat/wrap, not the default branch main"

echo "=== merge: the post-merge state check fails closed ==="
: > "$GH_STUB_CALLS"
out="$(GH_STUB_VIEW_STATE='{"state":"OPEN","mergeCommit":null}' "$WRAP" merge --apply "$TMPD/clone-scan-main" 2>&1)"; rc=$?
chk "merge --apply exits 2 when the PR is not MERGED after the call" "$([ "$rc" -eq 2 ]; echo $?)"

# ===========================================================================
echo "=== default-branch: detection, fall-through, and the no-remote refusal ==="
# ===========================================================================
chk "default-branch prints main" "$([ "$("$WRAP" default-branch "$TMPD/clone-scan-main")" = "main" ]; echo $?)"
chk "default-branch prints master" "$([ "$("$WRAP" default-branch "$TMPD/clone-scan-master")" = "master" ]; echo $?)"
chk "default-branch prints develop" "$([ "$("$WRAP" default-branch "$TMPD/clone-scan-develop")" = "develop" ]; echo $?)"

git clone -q "$TMPD/bare-rmain" "$TMPD/clone-dangling"
gitc "$TMPD/clone-dangling"
git -C "$TMPD/clone-dangling" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/renamed-away
chk "default-branch falls through to main when origin/HEAD dangles" \
  "$([ "$("$WRAP" default-branch "$TMPD/clone-dangling")" = "main" ]; echo $?)"

mkdir -p "$TMPD/remoteless"
git -C "$TMPD/remoteless" init -q; gitc "$TMPD/remoteless"
echo x > "$TMPD/remoteless/x.txt"; git -C "$TMPD/remoteless" add -A; git -C "$TMPD/remoteless" commit -qm x
out="$("$WRAP" default-branch "$TMPD/remoteless" 2>&1)"; rc=$?
chk "default-branch exits 1 on a repo with no remote" "$([ "$rc" -eq 1 ]; echo $?)"

# ===========================================================================
echo "=== log: the activity line, its path rules and its text rules ==="
# ===========================================================================
LOGHOME="$TMPD/home"; mkdir -p "$LOGHOME"
mkdir -p "$TMPD/outside"
KITROOT="$TMPD/kitroot"; mkdir -p "$KITROOT"
LOGFILE="$LOGHOME/ACTIVITY.md"
printf 'first old line\n' > "$LOGFILE"
printf 'old\n' > "$TMPD/outside/ACTIVITY.md"

set_log_key() { printf '[wrap]\nactivity_log = "%s"\n' "$1" > "$KITROOT/kit.toml"; }
wrap_log() { HOME="$LOGHOME" KIT_CONFIG_ROOT="$KITROOT" "$WRAP" log "$@"; }

set_log_key "$LOGFILE"
out="$(wrap_log "wrap: landed the session" 2>&1)"; rc=$?
chk "log exits 0 with the key set" "$rc"
chk "log prepends the dated line as line 1" \
  "$([ "$(head -1 "$LOGFILE")" = "$(date +%F) · wrap: landed the session" ]; echo $?)"
chk "log keeps the old first line" "$(grep -qx 'first old line' "$LOGFILE"; echo $?)"

wrap_log --date 2026-01-02 "wrap: backdated" >/dev/null 2>&1
chk "log --date overrides the prefix" \
  "$([ "$(head -1 "$LOGFILE")" = "2026-01-02 · wrap: backdated" ]; echo $?)"

DATE_BEFORE="$(cat "$LOGFILE")"
out="$(wrap_log --date "$(printf '2026-01-01\nFORGED')" "wrap: forged date" 2>&1)"; rc=$?
chk "log refuses a multi-line --date (exit 1)" "$([ "$rc" -eq 1 ]; echo $?)"
chk "log names the --date format" "$({ trap '' PIPE; printf '%s' "$out" 2>/dev/null || :; } | grep -q 'wrap log: --date must be YYYY-MM-DD'; echo $?)"
chk "log wrote nothing on the forged date" "$([ "$DATE_BEFORE" = "$(cat "$LOGFILE")" ]; echo $?)"
out="$(wrap_log --date 2026-13-45 "wrap: impossible date" 2>&1)"; rc=$?
chk "log refuses an out-of-range --date (exit 1)" "$([ "$rc" -eq 1 ]; echo $?)"
chk "log wrote nothing on the out-of-range date" "$([ "$DATE_BEFORE" = "$(cat "$LOGFILE")" ]; echo $?)"

BEFORE="$(cat "$LOGFILE")"
# The dash is assembled from its bytes: a literal one in this file would violate the
# repo-wide formatting rule the verb under test enforces.
EM="$(printf '\xe2\x80\x94')"
out="$(wrap_log "wrap: an em dash ${EM} here" 2>&1)"; rc=$?
chk "log refuses an em dash (exit 1)" "$([ "$rc" -eq 1 ]; echo $?)"
chk "log wrote nothing on the em dash" "$([ "$BEFORE" = "$(cat "$LOGFILE")" ]; echo $?)"

out="$(wrap_log "$(printf 'wrap: two\nlines')" 2>&1)"; rc=$?
chk "log refuses a newline (exit 1)" "$([ "$rc" -eq 1 ]; echo $?)"
chk "log wrote nothing on the newline" "$([ "$BEFORE" = "$(cat "$LOGFILE")" ]; echo $?)"

LONG="wrap: $(head -c 320 < /dev/zero | tr '\0' 'x')"
out="$(wrap_log "$LONG" 2>&1)"; rc=$?
chk "log writes a 320-char text" "$rc"
chk "log warns over the 300-char budget" "$({ trap '' PIPE; printf '%s' "$out" 2>/dev/null || :; } | grep -q 'over the 300-char routine budget'; echo $?)"

set_log_key "$LOGHOME/no-such-file.md"
out="$(wrap_log "wrap: missing target" 2>&1)"; rc=$?
chk "log exits 1 on a missing file" "$([ "$rc" -eq 1 ]; echo $?)"
chk "log names the resolved path" "$({ trap '' PIPE; printf '%s' "$out" 2>/dev/null || :; } | grep -q 'no-such-file.md'; echo $?)"

set_log_key "$TMPD/outside/ACTIVITY.md"
out="$(wrap_log "wrap: outside home" 2>&1)"; rc=$?
chk "log exits 1 on an absolute path outside HOME" "$([ "$rc" -eq 1 ]; echo $?)"
chk "log left the outside file untouched" "$([ "$(cat "$TMPD/outside/ACTIVITY.md")" = "old" ]; echo $?)"

set_log_key "$LOGHOME/../outside/ACTIVITY.md"
out="$(wrap_log "wrap: dotdot" 2>&1)"; rc=$?
chk "log exits 1 on a .. path that escapes HOME" "$([ "$rc" -eq 1 ]; echo $?)"

set_log_key "relative/ACTIVITY.md"
out="$(wrap_log "wrap: relative" 2>&1)"; rc=$?
chk "log exits 1 on a relative path" "$([ "$rc" -eq 1 ]; echo $?)"

mkdir -p "$TMPD/projrepo"
printf '[wrap]\nactivity_log = "%s"\n' "$LOGHOME/PROJECT.md" > "$TMPD/projrepo/.kit.toml"
printf 'untouched\n' > "$LOGHOME/PROJECT.md"
printf '[wrap]\n' > "$KITROOT/kit.toml"
out="$(cd "$TMPD/projrepo" && HOME="$LOGHOME" KIT_CONFIG_ROOT="$KITROOT" "$WRAP" log "wrap: project toml" 2>&1)"; rc=$?
chk "log ignores a project .kit.toml key (exit 0)" "$rc"
chk "log says the line did not land" "$({ trap '' PIPE; printf '%s' "$out" 2>/dev/null || :; } | grep -q 'no wrap.activity_log key in the kit-root kit.toml; line not written'; echo $?)"
chk "log still prints the line it would have written" "$({ trap '' PIPE; printf '%s' "$out" 2>/dev/null || :; } | grep -q ' · wrap: project toml'; echo $?)"
chk "log left the project-named file untouched" "$([ "$(cat "$LOGHOME/PROJECT.md")" = "untouched" ]; echo $?)"

# The operator config overlay (SPEC-248) owns this key too: it is as trusted as the kit root,
# so its value overrides a kit-root value for the same key.
OPCONF="$TMPD/opconfig"; mkdir -p "$OPCONF"
printf 'operator base\n' > "$LOGHOME/OPERATOR.md"
printf 'kit-root base\n' > "$LOGHOME/KITROOT.md"
set_log_key "$LOGHOME/KITROOT.md"
printf '[wrap]\nactivity_log = "%s"\n' "$LOGHOME/OPERATOR.md" > "$OPCONF/kit.toml"
out="$(HOME="$LOGHOME" KIT_CONFIG_ROOT="$KITROOT" KIT_CONFIG_OPERATOR="$OPCONF" \
  "$WRAP" log "wrap: operator toml" 2>&1)"; rc=$?
chk "log exits 0 with the operator kit.toml key set" "$rc"
chk "log prepends to the operator-named file" \
  "$([ "$(head -1 "$LOGHOME/OPERATOR.md")" = "$(date +%F) · wrap: operator toml" ]; echo $?)"
chk "log left the kit-root-named file untouched (operator wins)" \
  "$([ "$(cat "$LOGHOME/KITROOT.md")" = "kit-root base" ]; echo $?)"

# The configured log sits inside a repo's main checkout; a session working in a worktree of
# that repo gets the same repo-relative file inside its worktree, so the line is committable.
LOGREPO="$LOGHOME/logrepo"
git init -q "$LOGREPO" && git -C "$LOGREPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
mkdir -p "$LOGREPO/_meta" && printf 'main copy
' > "$LOGREPO/_meta/LOG.md"
git -C "$LOGREPO" add _meta/LOG.md && git -C "$LOGREPO" -c user.name=t -c user.email=t@t commit -q -m log
git -C "$LOGREPO" worktree add -q -b side "$LOGHOME/logrepo-wt"
set_log_key "$LOGREPO/_meta/LOG.md"
( cd "$LOGHOME/logrepo-wt" && HOME="$LOGHOME" KIT_CONFIG_ROOT="$KITROOT" "$WRAP" log "wrap: from a worktree" >/dev/null 2>&1 )
chk "log from a worktree prepends to the worktree's copy" \
  "$([ "$(head -1 "$LOGHOME/logrepo-wt/_meta/LOG.md")" = "$(date +%F) · wrap: from a worktree" ]; echo $?)"
chk "log from a worktree leaves the main checkout's copy untouched" \
  "$([ "$(cat "$LOGREPO/_meta/LOG.md")" = "main copy" ]; echo $?)"
( cd "$LOGHOME" && HOME="$LOGHOME" KIT_CONFIG_ROOT="$KITROOT" "$WRAP" log "wrap: from outside" >/dev/null 2>&1 )
chk "log from outside the repo prepends to the configured file itself" \
  "$([ "$(head -1 "$LOGREPO/_meta/LOG.md")" = "$(date +%F) · wrap: from outside" ]; echo $?)"

# ===========================================================================
echo "=== knowledge-root: the key, the HOME fence, and the repo argument ==="
# ===========================================================================
KRHOME="$TMPD/kr-home"; mkdir -p "$KRHOME/root-ok"
KROUTSIDE="$TMPD/kr-outside"; mkdir -p "$KROUTSIDE"
KRKITROOT="$TMPD/kr-kitroot"; mkdir -p "$KRKITROOT"
KRREPO="$TMPD/kr-repo"; mkdir -p "$KRREPO"
git -C "$KRREPO" init -q; gitc "$KRREPO"

set_kr_key() { printf '[knowledge]\nroot = "%s"\n' "$1" > "$KRKITROOT/kit.toml"; }
kr() { HOME="$KRHOME" KIT_CONFIG_ROOT="$KRKITROOT" "$WRAP" knowledge-root "$@"; }

printf '[knowledge]\n' > "$KRKITROOT/kit.toml"
out="$(kr "$KRREPO" 2>&1)"; rc=$?
chk "knowledge-root: key empty exits 0" "$rc"
chk_has "knowledge-root: key empty prints the repo-local fallback" "$out" "$KRREPO/.claude/memory"
chk "knowledge-root: key empty creates nothing" "$([ ! -e "$KRREPO/.claude/memory" ]; echo $?)"

set_kr_key "$KRHOME/root-ok"
out="$(kr "$KRREPO" 2>&1)"; rc=$?
chk "knowledge-root: filled, under HOME, existing, exits 0" "$rc"
chk_has "knowledge-root: prints <root>/projects/<basename>" "$out" "root-ok/projects/kr-repo"
chk "knowledge-root: creates <root>/projects/<basename>" "$([ -d "$KRHOME/root-ok/projects/kr-repo" ]; echo $?)"

set_kr_key "$KRHOME/missing-root"
out="$(kr "$KRREPO" 2>&1)"; rc=$?
chk "knowledge-root: filled but missing still exits 0 (fallback, not an error)" "$rc"
chk_has "knowledge-root: filled but missing falls back on stdout" "$out" "$KRREPO/.claude/memory"
chk_has "knowledge-root: filled but missing names the reason on stderr" "$out" "knowledge-root:"
chk "knowledge-root: filled but missing creates nothing under the still-missing root" \
  "$([ ! -e "$KRHOME/missing-root" ]; echo $?)"

set_kr_key "$KROUTSIDE"
out="$(kr "$KRREPO" 2>&1)"; rc=$?
chk "knowledge-root: filled but outside HOME falls back, exit 0" "$rc"
chk_has "knowledge-root: outside HOME falls back on stdout" "$out" "$KRREPO/.claude/memory"
chk "knowledge-root: outside HOME creates nothing there" "$([ ! -e "$KROUTSIDE/projects" ]; echo $?)"

ln -s "$KROUTSIDE" "$KRHOME/link-outside"
set_kr_key "$KRHOME/link-outside"
out="$(kr "$KRREPO" 2>&1)"; rc=$?
chk "knowledge-root: a symlink resolving outside HOME falls back, exit 0" "$rc"
chk_has "knowledge-root: symlink-outside falls back on stdout" "$out" "$KRREPO/.claude/memory"
chk "knowledge-root: symlink-outside creates nothing under the real target" \
  "$([ ! -e "$KROUTSIDE/projects" ]; echo $?)"

# The fence resolves `<root>` only. `mkdir -p` walks straight through a symlink at
# `<root>/projects`, so the created directory lands wherever that symlink points.
KRESC="$TMPD/kr-escape"; mkdir -p "$KRESC"
mkdir -p "$KRHOME/root-esc"; ln -s "$KRESC" "$KRHOME/root-esc/projects"
set_kr_key "$KRHOME/root-esc"
out="$(kr "$KRREPO" 2>&1)"; rc=$?
chk "knowledge-root: a symlinked projects dir falls back, exit 0" "$rc"
chk_has "knowledge-root: symlinked projects falls back on stdout" "$out" "$KRREPO/.claude/memory"
chk "knowledge-root: creates nothing under the symlink target" \
  "$([ ! -e "$KRESC/kr-repo" ]; echo $?)"

# `config seams` calls a root equal to $HOME `filled`, so the consumer must accept it too:
# an advisor that disagrees with the thing it advises on is the bug this closes.
KRHOME_REAL="$(cd "$KRHOME" && pwd -P)"
set_kr_key "$KRHOME"
out="$(kr "$KRREPO" 2>&1)"; rc=$?
chk "knowledge-root: a root equal to HOME itself exits 0" "$rc"
chk_has "knowledge-root: HOME-as-root prints <HOME>/projects/<basename>" \
  "$out" "$KRHOME_REAL/projects/kr-repo"
chk "knowledge-root: HOME-as-root creates the directory" \
  "$([ -d "$KRHOME_REAL/projects/kr-repo" ]; echo $?)"

out="$(kr 2>&1)"; rc=$?
chk "knowledge-root: missing repo argument exits 64" "$([ "$rc" -eq 64 ]; echo $?)"

out="$(kr "$KRREPO/no-such-subdir/.." 2>&1)"; rc=$?
chk "knowledge-root: repo arg ending in /.. exits 64" "$([ "$rc" -eq 64 ]; echo $?)"

out="$(kr / 2>&1)"; rc=$?
chk "knowledge-root: repo arg resolving to / exits 64" "$([ "$rc" -eq 64 ]; echo $?)"

# The only write this verb does is `mkdir -p` under `<root>/projects/<base>`, which sits
# OUTSIDE `<repo>` entirely -- so a `<repo>` with no `.git` at all must not block it. The
# old `_write_guard "$repo_real"` call shelled out to `git -C "$repo" rev-parse`, which
# fails on a non-git dir and printed the misleading "index.lock held by another writer".
KRNONGIT="$TMPD/kr-nongit-repo"; mkdir -p "$KRNONGIT"
set_kr_key "$KRHOME/root-ok"
out="$(kr "$KRNONGIT" 2>&1)"; rc=$?
chk "knowledge-root: non-git repo dir, filled+existing root, exits 0" "$rc"
chk_has "knowledge-root: non-git repo prints <root>/projects/<basename>" \
  "$out" "root-ok/projects/kr-nongit-repo"
chk "knowledge-root: non-git repo creates <root>/projects/<basename>" \
  "$([ -d "$KRHOME/root-ok/projects/kr-nongit-repo" ]; echo $?)"
chk_no "knowledge-root: non-git repo never prints the index.lock message" \
  "$out" "index.lock held by another writer"

# ===========================================================================
echo "=== stage: default paths, dedupe, the fences, and the worktree copy ==="
# ===========================================================================
STAGEHOME="$TMPD/stage-home"; mkdir -p "$STAGEHOME"
mk_stage_repo() { # mk_stage_repo <name> -- prints the new repo's path
  local d="$TMPD/stage-$1"
  mkdir -p "$d"; git -C "$d" init -q; gitc "$d"
  git -C "$d" commit -q --allow-empty -m init
  printf '%s' "$d"
}

R1="$(mk_stage_repo one)"
out="$(cd "$R1" && "$WRAP" stage "My First Title" "the intent" "the home" 2>&1)"; rc=$?
chk "stage: default paths exits 0" "$rc"
chk "stage: creates _meta/backlog-staging.md" "$([ -f "$R1/_meta/backlog-staging.md" ]; echo $?)"
chk_has "stage: appends the rendered block" "$(cat "$R1/_meta/backlog-staging.md")" "## [staged] My First Title"

out="$(cd "$R1" && "$WRAP" stage "my   FIRST title!!" "x" "y" 2>&1)"; rc=$?
chk "stage: a dup differing in case/spacing/punctuation exits 0" "$rc"
chk_has "stage: the dup prints already staged" "$out" "already staged"
DUP_COUNT="$(grep -c '^## \[staged\]' "$R1/_meta/backlog-staging.md")"
chk "stage: the dup wrote no second block" "$([ "$DUP_COUNT" -eq 1 ]; echo $?)"

R2="$(mk_stage_repo two)"
mkdir -p "$STAGEHOME/override-home"
: > "$STAGEHOME/override-home/staging.md"
out="$(cd "$R2" && BACKLOG_STAGE_STAGING="$STAGEHOME/override-home/staging.md" HOME="$STAGEHOME" \
  "$WRAP" stage "Override Path Title" "i" "h" 2>&1)"; rc=$?
chk "stage: BACKLOG_STAGE_STAGING under HOME honoured, exit 0" "$rc"
chk_has "stage: writes the overridden path" \
  "$(cat "$STAGEHOME/override-home/staging.md")" "## [staged] Override Path Title"
chk "stage: never touches the repo default path" "$([ ! -e "$R2/_meta/backlog-staging.md" ]; echo $?)"

# The override reaches wrap through the environment, which a repo `.envrc` writes. An absent
# leaf under HOME is exactly the shape that would let it seed a staging block into an agent
# instruction file, so the override may only append to a file that already exists.
R2B="$(mk_stage_repo two-b)"
ABSENT="$STAGEHOME/override-home/absent-instructions.md"
out="$(cd "$R2B" && BACKLOG_STAGE_STAGING="$ABSENT" HOME="$STAGEHOME" \
  "$WRAP" stage "Injected Row" "i" "h" 2>&1)"; rc=$?
chk "stage: an env-override at an absent file refuses, exit 1" "$([ "$rc" -eq 1 ]; echo $?)"
chk_has "stage: names the existing-regular-file rule" "$out" "not an existing regular file"
chk "stage: the absent override path is still absent" "$([ ! -e "$ABSENT" ]; echo $?)"

R3="$(mk_stage_repo three)"
mkdir -p "$R3/_meta"; ln -s /etc/hosts "$R3/_meta/backlog-staging.md"
out="$(cd "$R3" && "$WRAP" stage "T" "i" "h" 2>&1)"; rc=$?
chk "stage: a symlinked target refuses, exit 1" "$([ "$rc" -eq 1 ]; echo $?)"
chk_has "stage: names the reason on stderr" "$out" "wrap stage:"
chk "stage: the symlink itself is left alone" "$([ -L "$R3/_meta/backlog-staging.md" ]; echo $?)"

R4="$(mk_stage_repo four)"
mkdir -p "$STAGEHOME/elsewhere" "$STAGEHOME/some-other-home"
out="$(cd "$R4" && BACKLOG_STAGE_STAGING="$STAGEHOME/elsewhere/staging.md" HOME="$STAGEHOME/some-other-home" \
  "$WRAP" stage "T" "i" "h" 2>&1)"; rc=$?
chk "stage: outside the repo and outside HOME refuses, exit 1" "$([ "$rc" -eq 1 ]; echo $?)"
chk "stage: nothing written outside" "$([ ! -e "$STAGEHOME/elsewhere/staging.md" ]; echo $?)"

out="$("$WRAP" stage "T" "i" "h" --repo "$TMPD/not-a-repo" 2>&1)"; rc=$?
chk "stage: a non-git --repo exits 64" "$([ "$rc" -eq 64 ]; echo $?)"

R5="$(mk_stage_repo five)"
mkdir -p "$R5/_meta"; : > "$R5/_meta/backlog-staging.md"; chmod 400 "$R5/_meta/backlog-staging.md"
out="$(cd "$R5" && "$WRAP" stage "T" "i" "h" 2>&1)"; rc=$?
chk "stage: an unwritable target relays FAILED, exit 2" "$([ "$rc" -eq 2 ]; echo $?)"
chk_has "stage: relays the FAILED line" "$out" "FAILED"
chmod 644 "$R5/_meta/backlog-staging.md"

R6MAIN="$TMPD/stage-six"
git init -q "$R6MAIN" && git -C "$R6MAIN" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
mkdir -p "$R6MAIN/_meta"
printf '# Backlog staging\n\n' > "$R6MAIN/_meta/backlog-staging.md"
git -C "$R6MAIN" add _meta/backlog-staging.md
git -C "$R6MAIN" -c user.name=t -c user.email=t@t commit -q -m stage
git -C "$R6MAIN" worktree add -q -b stage-side "$TMPD/stage-six-wt"
out="$(cd "$TMPD/stage-six-wt" && "$WRAP" stage --repo "$R6MAIN" "From The Worktree" "i" "h" 2>&1)"; rc=$?
chk "stage: run from a worktree exits 0" "$rc"
chk_has "stage: writes the worktree's own copy" \
  "$(cat "$TMPD/stage-six-wt/_meta/backlog-staging.md")" "## [staged] From The Worktree"
chk_no "stage: the main checkout's copy is left alone" \
  "$(cat "$R6MAIN/_meta/backlog-staging.md")" "## [staged] From The Worktree"

# The checks above run on the path BEFORE `_worktree_copy` swaps in the current worktree's own
# copy. A symlink at that copy redirects the append anywhere, so the refusal runs again after.
WTHOME="$TMPD/wt-home"; mkdir -p "$WTHOME"
CANARY="$TMPD/wt-canary.md"; printf 'canary untouched\n' > "$CANARY"
R7MAIN="$WTHOME/stage-seven"
git init -q "$R7MAIN" && git -C "$R7MAIN" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
mkdir -p "$R7MAIN/_meta"
printf '# Backlog staging\n\n' > "$R7MAIN/_meta/backlog-staging.md"
git -C "$R7MAIN" add _meta/backlog-staging.md
git -C "$R7MAIN" -c user.name=t -c user.email=t@t commit -q -m stage
git -C "$R7MAIN" worktree add -q -b stage-evil "$WTHOME/stage-seven-wt"
rm -f "$WTHOME/stage-seven-wt/_meta/backlog-staging.md"
ln -s "$CANARY" "$WTHOME/stage-seven-wt/_meta/backlog-staging.md"
CANARY_BEFORE="$(shasum -a 256 "$CANARY" | cut -d' ' -f1)"
out="$(cd "$WTHOME/stage-seven-wt" && HOME="$WTHOME" "$WRAP" stage --repo "$R7MAIN" "Redirected Row" "i" "h" 2>&1)"; rc=$?
chk "stage: a symlinked worktree copy refuses, exit 1" "$([ "$rc" -eq 1 ]; echo $?)"
chk_has "stage: names the symlink on stderr" "$out" "is a symlink"
chk "stage: the canary outside HOME is byte-identical" \
  "$([ "$CANARY_BEFORE" = "$(shasum -a 256 "$CANARY" | cut -d' ' -f1)" ]; echo $?)"

# Same shape for `wrap log`: the configured activity_log is fenced, its worktree copy is not.
LOGWTKIT="$TMPD/wt-kitroot"; mkdir -p "$LOGWTKIT"
LOGCANARY="$TMPD/wt-log-canary.md"; printf 'log canary untouched\n' > "$LOGCANARY"
R8MAIN="$WTHOME/log-eight"
git init -q "$R8MAIN" && git -C "$R8MAIN" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
mkdir -p "$R8MAIN/_meta"
printf 'main copy\n' > "$R8MAIN/_meta/LOG.md"
git -C "$R8MAIN" add _meta/LOG.md
git -C "$R8MAIN" -c user.name=t -c user.email=t@t commit -q -m log
git -C "$R8MAIN" worktree add -q -b log-evil "$WTHOME/log-eight-wt"
rm -f "$WTHOME/log-eight-wt/_meta/LOG.md"
ln -s "$LOGCANARY" "$WTHOME/log-eight-wt/_meta/LOG.md"
printf '[wrap]\nactivity_log = "%s"\n' "$R8MAIN/_meta/LOG.md" > "$LOGWTKIT/kit.toml"
LOGCANARY_BEFORE="$(shasum -a 256 "$LOGCANARY" | cut -d' ' -f1)"
out="$(cd "$WTHOME/log-eight-wt" && HOME="$WTHOME" KIT_CONFIG_ROOT="$LOGWTKIT" "$WRAP" log "wrap: redirected" 2>&1)"; rc=$?
chk "log: a symlinked worktree copy refuses, exit 1" "$([ "$rc" -eq 1 ]; echo $?)"
chk_has "log: names the symlink on stderr" "$out" "is a symlink"
chk "log: the canary outside HOME is byte-identical" \
  "$([ "$LOGCANARY_BEFORE" = "$(shasum -a 256 "$LOGCANARY" | cut -d' ' -f1)" ]; echo $?)"

# A symlink at a PARENT directory of the worktree copy escapes a leaf-only refusal and a
# prefix fence run on the unresolved string: `wt/_meta` pointing at a directory outside HOME
# still leaves `wt/_meta/<file>` looking like a plain file under the worktree. Both verbs must
# resolve the copied path before they fence it.
PDHOME="$TMPD/pd-home"; mkdir -p "$PDHOME"
PDOUT="$TMPD/pd-outside/_meta"; mkdir -p "$PDOUT"
printf 'staging canary untouched\n' > "$PDOUT/backlog-staging.md"
printf 'log canary untouched\n' > "$PDOUT/LOG.md"
R9MAIN="$PDHOME/pd-main"
git init -q "$R9MAIN" && git -C "$R9MAIN" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
mkdir -p "$R9MAIN/_meta"
printf '# Backlog staging\n\n' > "$R9MAIN/_meta/backlog-staging.md"
printf 'main copy\n' > "$R9MAIN/_meta/LOG.md"
git -C "$R9MAIN" add _meta
git -C "$R9MAIN" -c user.name=t -c user.email=t@t commit -q -m meta
git -C "$R9MAIN" worktree add -q -b pd-side "$PDHOME/pd-wt"
rm -rf "$PDHOME/pd-wt/_meta"
ln -s "$TMPD/pd-outside/_meta" "$PDHOME/pd-wt/_meta"
git -C "$PDHOME/pd-wt" add _meta 2>/dev/null
git -C "$PDHOME/pd-wt" -c user.name=t -c user.email=t@t commit -q -m symlinked-meta 2>/dev/null
PD_STAGE_BEFORE="$(shasum -a 256 "$PDOUT/backlog-staging.md" | cut -d' ' -f1)"
PD_LOG_BEFORE="$(shasum -a 256 "$PDOUT/LOG.md" | cut -d' ' -f1)"

out="$(cd "$PDHOME/pd-wt" && HOME="$PDHOME" "$WRAP" stage --repo "$R9MAIN" "Parent Symlink Row" "i" "h" 2>&1)"; rc=$?
chk "stage: a parent-dir symlink on the worktree copy refuses, exit 1" "$([ "$rc" -eq 1 ]; echo $?)"
chk_has "stage: names a reason on stderr" "$out" "wrap stage:"
chk "stage: the staging canary outside HOME is byte-identical" \
  "$([ "$PD_STAGE_BEFORE" = "$(shasum -a 256 "$PDOUT/backlog-staging.md" | cut -d' ' -f1)" ]; echo $?)"

PDKIT="$TMPD/pd-kitroot"; mkdir -p "$PDKIT"
printf '[wrap]\nactivity_log = "%s"\n' "$R9MAIN/_meta/LOG.md" > "$PDKIT/kit.toml"
out="$(cd "$PDHOME/pd-wt" && HOME="$PDHOME" KIT_CONFIG_ROOT="$PDKIT" "$WRAP" log "wrap: parent symlink" 2>&1)"; rc=$?
chk "log: a parent-dir symlink on the worktree copy refuses, exit 1" "$([ "$rc" -eq 1 ]; echo $?)"
chk_has "log: names a reason on stderr" "$out" "wrap log:"
chk "log: the log canary outside HOME is byte-identical" \
  "$([ "$PD_LOG_BEFORE" = "$(shasum -a 256 "$PDOUT/LOG.md" | cut -d' ' -f1)" ]; echo $?)"

# ===========================================================================
echo "=== help and usage ==="
# ===========================================================================
out="$("$WRAP" --help 2>&1)"; rc=$?
chk "--help exits 0" "$rc"
for verb in scan apply merge log default-branch knowledge-root stage; do
  chk_has "--help names $verb" "$out" "$verb"
done
out="$("$WRAP" scan 2>&1)"; rc=$?
chk "scan with no argument exits 64" "$([ "$rc" -eq 64 ]; echo $?)"
out="$("$WRAP" apply 2>&1)"; rc=$?
chk "apply with no repo exits 64" "$([ "$rc" -eq 64 ]; echo $?)"
out="$("$WRAP" merge 2>&1)"; rc=$?
chk "merge with no repo exits 64" "$([ "$rc" -eq 64 ]; echo $?)"
out="$("$WRAP" log 2>&1)"; rc=$?
chk "log with no text exits 64" "$([ "$rc" -eq 64 ]; echo $?)"
out="$("$WRAP" knowledge-root 2>&1)"; rc=$?
chk "knowledge-root with no repo exits 64" "$([ "$rc" -eq 64 ]; echo $?)"
out="$("$WRAP" stage 2>&1)"; rc=$?
chk "stage with no args exits 64" "$([ "$rc" -eq 64 ]; echo $?)"
out="$("$WRAP" bogus 2>&1)"; rc=$?
chk "an unknown verb exits 64" "$([ "$rc" -eq 64 ]; echo $?)"

# ------------------------------------------------------- autonomy knobs (wrap.*)
# The three knobs `commands/wrap.md` reads at step -1. They govern a write each, so the
# fence that matters is the third block: a project `.kit.toml` rides inside a pull request
# and must never widen what wrap does to the machine running it.
echo
echo "=== autonomy knobs ==="
# shellcheck source=/dev/null
. "$KIT_DIR/lib/config/kit-config.sh"
KNOB_OP="$TMPD/knob-operator"; KNOB_PROJ="$TMPD/knob-project"
mkdir -p "$KNOB_OP" "$KNOB_PROJ"
printf '[wrap]\nmerge_own_prs = false\ntidy_worktrees = false\nbuild_candidates = false\n' > "$KNOB_OP/kit.toml"
printf '[wrap]\nmerge_own_prs = false\ntidy_worktrees = false\nbuild_candidates = false\n' > "$KNOB_PROJ/.kit.toml"
for knob in merge_own_prs tidy_worktrees build_candidates; do
  v="$(KIT_CONFIG_ROOT="$KIT_DIR" kit_config_get_root "wrap.$knob" true)"
  chk "wrap.$knob ships as true" "$([ "$v" = "true" ]; echo $?)"
  v="$(KIT_CONFIG_OPERATOR="$KNOB_OP" kit_config_get_root "wrap.$knob" true)"
  chk "wrap.$knob honours the operator kit.toml" "$([ "$v" = "false" ]; echo $?)"
  v="$(KIT_PROJECT_ROOT="$KNOB_PROJ" kit_config_get_root "wrap.$knob" true)"
  chk "wrap.$knob ignores a project .kit.toml" "$([ "$v" = "true" ]; echo $?)"
done
for knob in merge_own_prs tidy_worktrees build_candidates; do
  chk_has "commands/wrap.md reads wrap.$knob" "$(cat "$KIT_DIR/commands/wrap.md")" "wrap.$knob"
  chk_has "kit.toml declares $knob" "$(cat "$KIT_DIR/kit.toml")" "$knob"
done

# ------------------------------------------------- main-checkout resolver recipe
# `commands/wrap.md` step 5 prescribes one recipe for turning the session cwd into the
# repo argument `wrap apply` needs: `--git-common-dir` minus the trailing `/.git`. Run from
# a worktree the naive `$PWD` yields the feature branch, `apply` takes its non-default-branch
# path, and the checkout never pulls. This asserts the recipe, not the model following it.
echo
echo "=== main-checkout resolver ==="
RES="$TMPD/resolver"; mkdir -p "$RES"
(
  cd "$RES" || exit 1
  git init -q -b main . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git worktree add -q wt -b feature >/dev/null 2>&1
) >/dev/null 2>&1
main_real="$(cd "$RES" && pwd -P)"
resolved="$(git -C "$RES/wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
resolved="${resolved%/.git}"
resolved="$(cd "$resolved" 2>/dev/null && pwd -P)"
chk "the recipe resolves a worktree to the main checkout" "$([ "$resolved" = "$main_real" ]; echo $?)"
chk "the main checkout is on the default branch, so apply pulls" \
  "$([ "$(git -C "$main_real" branch --show-current)" = "main" ]; echo $?)"
chk "the naive cwd would have been the feature branch" \
  "$([ "$(git -C "$RES/wt" branch --show-current)" = "feature" ]; echo $?)"
chk_has "commands/wrap.md prescribes the recipe" "$(cat "$KIT_DIR/commands/wrap.md")" "--git-common-dir"

# ------------------------------------------------------------- report lint
# The `Needs you` admission test, mechanised. The first case is the REAL defect that
# started this work: a green own PR parked behind "say go and I merge it".
echo
echo "=== report lint ==="
LINT="$KIT_DIR/lib/wrap/report-lint.sh"
_report() { printf '## Wrap: t\n\n%s\n\n**What happened**\n- %s\n' "$1" "${2:-body}"; }

out="$(_report '🔴 **Needs you:**
a. REVIEW then merge #523. Say go and I merge it.' | bash "$LINT" 2>&1)"; rc=$?
chk "the original defect fails the lint" "$([ "$rc" -eq 1 ]; echo $?)"
chk_has "the finding names the offending item" "$out" "asks permission instead of naming a blocker"

out="$(_report '✅ **Needs you:** NOTHING' 'say go and I merge it' | bash "$LINT" 2>&1)"; rc=$?
chk "NOTHING passes, and What happened is never judged" "$([ "$rc" -eq 0 ]; echo $?)"

out="$(_report '🔴 **Needs you:**
a. UNBLOCK the deploy. It is blocked on a credential only you can read.' | bash "$LINT" 2>&1)"; rc=$?
chk "a real blocker passes" "$([ "$rc" -eq 0 ]; echo $?)"

out="$(_report '🔴 **Needs you:**
a. RUN gh pr merge 12 --squash.' | bash "$LINT" 2>&1)"; rc=$?
chk "a self-runnable command with no blocker warns, does not fail" "$([ "$rc" -eq 0 ]; echo $?)"
chk_has "the warn names the command class" "$out" "names a command the kit can run"

out="$(_report '🔴 **Needs you:**
a. RUN gh pr merge 12 once security signs off; it is blocked on their approval.' | bash "$LINT" 2>&1)"; rc=$?
chk_no "a stated blocker clears the warn" "$out" "names a command the kit can run"

out="$(printf 'no needs-you section at all\n' | bash "$LINT" 2>&1)"; rc=$?
chk "a report with no Needs you block is clean" "$([ "$rc" -eq 0 ]; echo $?)"

rc=0; bash "$LINT" /nonexistent-report-file >/dev/null 2>&1 || rc=$?
chk "a missing file exits 2" "$([ "$rc" -eq 2 ]; echo $?)"

chk_has "commands/wrap.md wires the lint into step 9" "$(cat "$KIT_DIR/commands/wrap.md")" "lib/wrap/report-lint.sh"

echo
if [ "$FAIL" -gt 0 ]; then echo "test-wrap: $PASS passed, $FAIL FAILED of $TOTAL" >&2; exit 1; fi
echo "test-wrap: all $PASS passed"
