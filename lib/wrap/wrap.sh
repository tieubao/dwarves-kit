#!/usr/bin/env bash
# wrap.sh -- the landing step after ship (SPEC-246). One pass over every repo a session
# touched, with seven verbs:
#
#   wrap.sh scan  <repo> [<repo>...]                        report only, exit 0
#   wrap.sh apply [--apply] [--worktrees] <repo> [...]      dry-run by default
#   wrap.sh merge [--apply] <repo>                          merges ONE own green PR
#   wrap.sh log   "<slug>: <one sentence>" [--date YYYY-MM-DD]
#   wrap.sh default-branch <repo>                           prints the detected name
#   wrap.sh knowledge-root <repo>                           SPEC-249: the fenced knowledge dir
#   wrap.sh stage "<title>" "<intent>" "<home>" [--repo <repo>]  SPEC-249: stage a candidate
#   wrap.sh --help
#
#   internal, a test seam: apply --tips-file <path> replaces the run's own tip snapshot
#
# The write set is closed: branch delete under two proofs, worktree remove under
# --worktrees, pull --ff-only on the default branch, the activity-log prepend, the
# knowledge-root project directory, the staging-file append, and one gh pr merge. Every
# other action is a report line. The verbs never switch a branch, never touch a dirty
# file, never force, and never retry a failed git call.
#
# Ported from the operator's repo-wrapup scripts. The default branch is DETECTED, never
# assumed to be main.
# `-e` is deliberately absent. The `run()` helper captures the exit code of every write
# itself, reports the failure once and sets FAILURES; under `-e` the shell would exit at
# the first failed write and the remaining repos would never report.
set -uo pipefail

# A git call must never block on a credential prompt inside an unattended wrap.
export GIT_TERMINAL_PROMPT=0

# An index.lock at least this old belongs to a foreign writer, not to ordinary git traffic.
LOCK_STALE_SECS=5
# A routine activity line stays inside this many characters. Over it, `log` warns and writes.
LOG_LINE_BUDGET=300

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_ROOT="$(cd "$SELF_DIR/.." && pwd)"
# The one staging-block writer (SPEC-249 TASK-003/004): `stage` shells out to it rather
# than growing a second copy of the dedupe/render/append grammar in bash.
STAGING_FORMAT_PY="$LIB_ROOT/learn/staging-format.py"
# shellcheck source=lib/config/kit-config.sh
source "$LIB_ROOT/config/kit-config.sh" || { echo "FATAL: lib/config/kit-config.sh missing or unreadable" >&2; exit 1; }

_usage() { sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# --------------------------------------------------------------------------- helpers

_is_repo() { [ -e "$1/.git" ] || git -C "$1" rev-parse --git-dir >/dev/null 2>&1; }

_origin_url() { git -C "$1" remote get-url origin 2>/dev/null; }

_ref_exists() { git -C "$1" show-ref --verify --quiet "$2"; }

# _default_branch <repo> -- origin/HEAD when it resolves to a live remote ref, else main,
# else master. Exit 1 when none resolves; the caller skips that repo.
_default_branch() {
  local repo="$1" ref name
  ref="$(git -C "$repo" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)"
  if [ -n "$ref" ]; then
    name="${ref#refs/remotes/origin/}"
    if [ "$name" != "$ref" ] && _ref_exists "$repo" "refs/remotes/origin/$name"; then
      printf '%s\n' "$name"; return 0
    fi
  fi
  for name in main master; do
    if _ref_exists "$repo" "refs/remotes/origin/$name"; then printf '%s\n' "$name"; return 0; fi
  done
  return 1
}

# _gh_state -- ok | unavailable | unauthenticated. Read once per verb run.
_gh_state() {
  command -v gh >/dev/null 2>&1 || { printf 'unavailable\n'; return 0; }
  gh auth status >/dev/null 2>&1 || { printf 'unauthenticated\n'; return 0; }
  printf 'ok\n'
}

_gh_note() {
  case "$1" in
    unavailable)     printf '(gh unavailable)\n' ;;
    unauthenticated) printf '(gh unauthenticated)\n' ;;
  esac
}

# GNU stat first: on GNU, `-f` means file-system status and prints a mount point with exit 0,
# so a BSD-first order parses garbage on Linux. BSD stat rejects `-c` and falls through.
_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

_fmode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }

_short() { printf '%s' "${1:0:7}"; }

# _squash_json <repo-url> <branch> -- the merged-PR list gh reports for that head.
_squash_json() {
  gh pr list --repo "$1" --head "$2" --state merged --json headRefOid,baseRefName,mergedAt 2>/dev/null
}

# _squash_verdict <json> <local tip> <default branch> -- one of:
#   OK            a merged PR into the default branch has this exact tip
#   TIP <sha>     merged into the default branch, but from a different tip
#   BASE <name>   merged into another branch
#   NONE          no merged PR for this head (also the answer for unusable JSON)
_squash_verdict() {
  local json="$1" tip="$2" def="$3" out
  out="$(printf '%s' "$json" | jq -r --arg tip "$tip" --arg def "$def" '
    [.[] | select(.mergedAt != null)] as $m
    | if ($m | length) == 0 then "NONE"
      elif ([$m[] | select(.baseRefName == $def and .headRefOid == $tip)] | length) > 0 then "OK"
      elif ([$m[] | select(.baseRefName == $def)] | length) > 0
        then "TIP " + ([$m[] | select(.baseRefName == $def)][0].headRefOid)
      else "BASE " + ($m[0].baseRefName) end' 2>/dev/null)"
  [ -n "$out" ] || out="NONE"
  printf '%s\n' "$out"
}

# --------------------------------------------------------------------------- scan

_scan_repo() {
  local repo="$1" ghs="$2"
  _is_repo "$repo" || { echo "== ${repo}: not a git repo, skipped"; return 0; }
  echo "===================================================================="
  echo "== ${repo}"
  git -C "$repo" fetch --prune -q 2>/dev/null || echo "  (fetch failed; counts may be stale)"

  local def
  def="$(_default_branch "$repo")" || {
    echo "-- no default branch resolved (origin/HEAD, origin/main and origin/master all absent); skipped"
    return 0
  }

  local cur; cur="$(git -C "$repo" branch --show-current 2>/dev/null)"
  echo "-- checkout on: ${cur:-<detached>}"

  local ahead behind
  ahead="$(git -C "$repo" rev-list --count "origin/${def}..HEAD" 2>/dev/null)"
  behind="$(git -C "$repo" rev-list --count "HEAD..origin/${def}" 2>/dev/null)"
  case "$ahead" in ''|*[!0-9]*) ahead='?' ;; esac
  case "$behind" in ''|*[!0-9]*) behind='?' ;; esac
  echo "-- vs origin/${def}: ahead=${ahead} behind=${behind}"

  echo "-- dirty files (do NOT assume they are yours):"
  local st; st="$(git -C "$repo" status --short 2>/dev/null)"
  if [ -n "$st" ]; then printf '%s\n' "$st" | sed -n 1,10p | sed 's/^/     /'
  else echo "     (clean)"; fi

  echo "-- worktrees:"
  git -C "$repo" worktree list 2>/dev/null | sed 's/^/     /'

  echo "-- local branches (an ancestor of origin/${def} is SAFE-d; a squash merge needs the gh proof):"
  local b tip json verdict
  for b in $(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads/); do
    case "$b" in "$def"|main|master) continue ;; esac
    if git -C "$repo" merge-base --is-ancestor "$b" "origin/${def}" 2>/dev/null; then
      echo "     ${b}  [SAFE-d: ancestor of origin/${def}]"
      continue
    fi
    if [ "$ghs" != "ok" ]; then
      echo "     ${b}  [NOT merged / unknown: LEAVE]"
      continue
    fi
    tip="$(git -C "$repo" rev-parse "$b" 2>/dev/null)"
    json="$(_squash_json "$(_origin_url "$repo")" "$b")"
    verdict="$(_squash_verdict "$json" "$tip" "$def")"
    case "$verdict" in
      OK) echo "     ${b}  [SQUASH-MERGED per gh: safe to -D]" ;;
      *)  echo "     ${b}  [NOT merged / unknown: LEAVE]" ;;
    esac
  done

  echo "-- open PRs authored by me:"
  case "$ghs" in
    ok)
      gh pr list --repo "$(_origin_url "$repo")" --author "@me" --state open \
        --json number,title,headRefName 2>/dev/null \
        | jq -r '.[] | "     #\(.number) \(.title) [\(.headRefName)]"' 2>/dev/null \
        || echo "     (gh query failed)"
      ;;
    *) echo "     $(_gh_note "$ghs")" ;;
  esac
}

cmd_scan() {
  [ $# -ge 1 ] || { echo "usage: wrap.sh scan <repo> [<repo>...]" >&2; return 64; }
  local ghs repo; ghs="$(_gh_state)"
  for repo in "$@"; do _scan_repo "$repo" "$ghs"; done
  echo "===================================================================="
  echo "Report only. Deletion, merging and pulling stay a judgment call."
  return 0
}

# --------------------------------------------------------------------------- apply

APPLY=0
WORKTREES=0
MODE="DRY-RUN"
FAILURES=0
TIPS_FILE=""
TIPS_OVERRIDE=""

# _write_guard <repo> -- 0 when the checkout is free to write, 1 when another writer holds
# it. An index.lock at least LOCK_STALE_SECS old is foreign; a younger one is normal git
# traffic, proven by a passing status call. An unresolvable git dir refuses the write.
_write_guard() {
  # A young index.lock is ordinary git traffic and clears within the stale window; one that
  # persists past it is a writer. Polling the file itself is portable: a `git status` probe
  # contends for the same lock on some git builds and fails for the wrong reason.
  local repo="$1" gd lock age m now waited=0
  gd="$(git -C "$repo" rev-parse --path-format=absolute --git-dir 2>/dev/null)" || return 1
  [ -n "$gd" ] || return 1
  lock="${gd}/index.lock"
  while [ -e "$lock" ]; do
    now="$(date +%s)"; m="$(_mtime "$lock")"
    case "$m" in ''|*[!0-9]*) return 1 ;; esac
    age=$(( now - m ))
    [ "$age" -lt "$LOCK_STALE_SECS" ] || return 1
    [ "$waited" -lt "$LOCK_STALE_SECS" ] || return 1
    sleep 1; waited=$(( waited + 1 ))
  done
  return 0
}

# run <repo> <verdict> <command...> -- print the verdict, execute only under --apply.
# A failed write is reported once and turns the run's exit code into 2. Nothing is retried.
run() {
  local repo="$1" verdict="$2"; shift 2
  if ! _write_guard "$repo"; then
    echo "     SKIP ${verdict}: index.lock held by another writer"
    return 0
  fi
  echo "     [${MODE}] ${verdict}"
  [ "$APPLY" = 1 ] || return 0
  "$@"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "     FAILED ${verdict}: exit ${rc}"
    FAILURES=1
  fi
  return 0
}

_scanned_tip() { awk -v b="$1" '$1 == b { print $2 }' "$TIPS_FILE"; }

# A worktree path may carry a newline, so the record stream is NUL-delimited: `--porcelain -z`
# terminates every attribute with NUL, which keeps the path whole.
_apply_worktrees() {
  local repo="$1" main_wt rec wt wt_c
  echo "-- worktrees:"
  main_wt="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  main_wt="${main_wt%/.git}"; main_wt="${main_wt%/}"
  main_wt="$(cd "$main_wt" 2>/dev/null && pwd -P)"
  while IFS= read -r -d '' rec; do
    case "$rec" in "worktree "*) wt="${rec#worktree }" ;; *) continue ;; esac
    wt_c="$(cd "$wt" 2>/dev/null && pwd -P)"
    if [ -z "$wt_c" ]; then echo "     SKIP ${wt}: unresolvable"; continue; fi
    [ "$wt_c" = "$main_wt" ] && continue
    if [ "$WORKTREES" != 1 ]; then
      echo "     SKIP ${wt}: --worktrees not given (the operator must ask for worktree cleanup)"
    elif [ -n "$(git -C "$wt" status --short 2>/dev/null)" ]; then
      echo "     SKIP ${wt}: dirty (another session's work stays)"
    elif [ -z "$(git -C "$wt" branch --show-current 2>/dev/null)" ]; then
      echo "     SKIP ${wt}: detached HEAD (removal could orphan the commit)"
    else
      run "$repo" "remove worktree ${wt} (clean; the branch survives removal)" \
        git -C "$repo" worktree remove "$wt"
    fi
  done < <(git -C "$repo" worktree list --porcelain -z 2>/dev/null)
}

_apply_branches() {
  local repo="$1" def="$2" cur="$3" fetch_ok="$4" ghs="$5"
  echo "-- branches:"
  local b tip scanned json verdict
  for b in $(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads/); do
    case "$b" in "$def"|main|master) echo "     SKIP ${b}: default or protected branch name"; continue ;; esac
    if [ "$b" = "$cur" ]; then echo "     SKIP ${b}: currently checked out"; continue; fi
    if git -C "$repo" worktree list --porcelain 2>/dev/null | grep -qx "branch refs/heads/${b}"; then
      echo "     SKIP ${b}: held by a worktree"; continue
    fi
    if [ "$fetch_ok" != 1 ]; then
      echo "     SKIP ${b}: fetch failed, stale ancestor data"; continue
    fi
    tip="$(git -C "$repo" rev-parse "$b" 2>/dev/null)"
    scanned="$(_scanned_tip "$b")"
    if [ -n "$scanned" ] && [ "$tip" != "$scanned" ]; then
      echo "     SKIP ${b}: tip moved during this run ($(_short "$scanned") -> $(_short "$tip"))"; continue
    fi
    if git -C "$repo" merge-base --is-ancestor "$b" "origin/${def}" 2>/dev/null; then
      run "$repo" "delete ${b} (ancestor of origin/${def})" git -C "$repo" branch -d "$b"
      continue
    fi
    if [ "$ghs" != "ok" ]; then
      echo "     SKIP ${b}: $(_gh_note "$ghs"), no squash proof available"; continue
    fi
    json="$(_squash_json "$(_origin_url "$repo")" "$b")"
    verdict="$(_squash_verdict "$json" "$tip" "$def")"
    case "$verdict" in
      OK)
        run "$repo" "delete ${b} (squash-merged into ${def}, tip matches the PR head)" \
          git -C "$repo" branch -D "$b" ;;
      TIP\ *)
        echo "     SKIP ${b}: tip $(_short "$tip") != merged PR head $(_short "${verdict#TIP }") (unpushed commits, leave it)" ;;
      BASE\ *)
        echo "     SKIP ${b}: merged into ${verdict#BASE }, not the default branch" ;;
      *)
        echo "     SKIP ${b}: no merged PR found for this head" ;;
    esac
  done
}

_apply_repo() {
  local repo="$1" ghs="$2"
  _is_repo "$repo" || { echo "== ${repo}: not a git repo, skipped"; return 0; }
  echo "== ${repo}"
  local fetch_ok=1
  git -C "$repo" fetch --prune -q 2>/dev/null || { fetch_ok=0; echo "     (fetch failed; every delete is skipped)"; }

  local def
  def="$(_default_branch "$repo")" || {
    echo "     SKIP ${repo}: no default branch resolved (origin/HEAD, origin/main and origin/master all absent)"
    return 0
  }
  local cur; cur="$(git -C "$repo" branch --show-current 2>/dev/null)"

  # Tip snapshot for this repo, taken once, compared right before each delete. --tips-file
  # substitutes a prepared snapshot so a test can stage a tip that moved mid-run.
  local own_snapshot=1
  if [ -n "$TIPS_OVERRIDE" ]; then
    TIPS_FILE="$TIPS_OVERRIDE"; own_snapshot=0
  else
    TIPS_FILE="$(mktemp)"
    git -C "$repo" for-each-ref --format='%(refname:short) %(objectname)' refs/heads/ > "$TIPS_FILE" 2>/dev/null
  fi

  _apply_worktrees "$repo"
  _apply_branches "$repo" "$def" "$cur" "$fetch_ok" "$ghs"

  echo "-- pull:"
  if [ "$cur" = "$def" ]; then
    run "$repo" "pull --ff-only (checkout on ${cur})" git -C "$repo" pull --ff-only
  else
    echo "     SKIP pull: checkout on '${cur:-<detached>}', not the default branch ${def}"
    run "$repo" "fetch origin ${def}:${def} (ff-only by nature)" git -C "$repo" fetch origin "${def}:${def}"
  fi

  [ "$own_snapshot" = 1 ] && rm -f "$TIPS_FILE"
  TIPS_FILE=""
}

cmd_apply() {
  # Indexed assignment plus a counter, not `arr+=()` with `${#arr[@]}`: an empty array reads
  # as unbound under `set -u` in bash 3.2, which is what macOS ships.
  local arg count=0 i=1 want_tips=0
  local repos
  for arg in "$@"; do
    case "$arg" in
      --apply) APPLY=1 ;;
      --worktrees) WORKTREES=1 ;;
      --tips-file=*) TIPS_OVERRIDE="${arg#--tips-file=}" ;;
      --tips-file) want_tips=1 ;;
      -*) echo "wrap.sh apply: unknown flag '$arg'" >&2; return 64 ;;
      *) if [ "$want_tips" = 1 ]; then TIPS_OVERRIDE="$arg"; want_tips=0
         else count=$(( count + 1 )); repos[count]="$arg"; fi ;;
    esac
  done
  [ "$want_tips" = 0 ] || { echo "wrap.sh apply: --tips-file needs a path" >&2; return 64; }
  if [ -n "$TIPS_OVERRIDE" ] && [ ! -f "$TIPS_OVERRIDE" ]; then
    echo "wrap.sh apply: --tips-file '${TIPS_OVERRIDE}' is not an existing file" >&2; return 64
  fi
  [ "$count" -ge 1 ] || { echo "usage: wrap.sh apply [--apply] [--worktrees] <repo> [<repo>...]" >&2; return 64; }
  [ "$APPLY" = 1 ] && MODE="APPLY"
  local ghs; ghs="$(_gh_state)"
  while [ "$i" -le "$count" ]; do _apply_repo "${repos[$i]}" "$ghs"; i=$(( i + 1 )); done
  echo "== ${MODE} complete. PR merges, deploy dispatch and board rows stay with the command."
  [ "$FAILURES" = 0 ] || return 2
  return 0
}

# --------------------------------------------------------------------------- merge

# _pr_detail <url> <number> -- the fields every merge gate reads.
_pr_detail() {
  gh pr view "$2" --repo "$1" \
    --json number,title,headRefName,headRefOid,baseRefName,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup 2>/dev/null
}

# _pr_gate <json> <default branch> -- "OK" or "SKIP <reason>". mergeStateStatus carries the
# unresolved-conversation signal: gh pr view has no reviewThreads field, and BLOCKED is the
# state GitHub reports for an unresolved thread or an unmet review requirement. Anything but
# a clean state fails closed here. An empty or null rollup proves nothing on its own, so it
# passes only when GitHub itself reports the merge state as CLEAN.
_pr_gate() {
  printf '%s' "$1" | jq -r --arg def "$2" '
    def checks: (.statusCheckRollup // []);
    if (.baseRefName != $def) then "SKIP base is \(.baseRefName), not the default branch \($def)"
    elif (.mergeable != "MERGEABLE") then "SKIP not mergeable (\(.mergeable // "unknown"))"
    elif ((checks | length) == 0 and ((.mergeStateStatus // "") != "CLEAN"))
      then "SKIP checks are pending or failing"
    elif ((checks | map(select(((.conclusion // .state // "") | ascii_upcase) as $c
                               | $c != "SUCCESS" and $c != "SKIPPED")) | length) > 0)
      then "SKIP checks are pending or failing"
    elif (.reviewDecision == "CHANGES_REQUESTED") then "SKIP changes requested"
    elif ((.mergeStateStatus // "CLEAN") as $m
          | $m != "CLEAN" and $m != "HAS_HOOKS" and $m != "UNSTABLE")
      then "SKIP merge state \(.mergeStateStatus) (an unresolved thread or a blocked merge)"
    else "OK" end' 2>/dev/null
}

cmd_merge() {
  local do_apply=0 arg repo="" count=0
  for arg in "$@"; do
    case "$arg" in
      --apply) do_apply=1 ;;
      -*) echo "wrap.sh merge: unknown flag '$arg'" >&2; return 64 ;;
      *) count=$(( count + 1 )); repo="$arg" ;;
    esac
  done
  [ "$count" -eq 1 ] || { echo "usage: wrap.sh merge [--apply] <repo>" >&2; return 64; }
  _is_repo "$repo" || { echo "wrap.sh merge: ${repo} is not a git repo" >&2; return 64; }

  local ghs; ghs="$(_gh_state)"
  if [ "$ghs" != "ok" ]; then _gh_note "$ghs"; return 1; fi

  local def; def="$(_default_branch "$repo")" || { echo "no default branch resolved for ${repo}" >&2; return 1; }
  local url; url="$(_origin_url "$repo")"

  local numbers; numbers="$(gh pr list --repo "$url" --author "@me" --state open \
    --json number,title,headRefName 2>/dev/null | jq -r '.[].number' 2>/dev/null)"
  [ -n "$numbers" ] || { echo "no open PRs authored by the operator on ${url}"; return 0; }

  # Exactly one detail read per PR. The full JSON goes to its own temp file and the
  # eligibility loop reads it back, because the dependents gate needs every base first.
  local jsondir; jsondir="$(mktemp -d)"
  local cache="${jsondir}/index"
  local n detail base head
  for n in $numbers; do
    detail="$(_pr_detail "$url" "$n")"
    printf '%s' "$detail" > "${jsondir}/pr-${n}.json"
    base="$(printf '%s' "$detail" | jq -r '.baseRefName // ""' 2>/dev/null)"
    head="$(printf '%s' "$detail" | jq -r '.headRefName // ""' 2>/dev/null)"
    printf '%s\t%s\t%s\n' "$n" "$head" "$base" >> "$cache"
  done

  local first_eligible="" verdict title
  for n in $numbers; do
    detail="$(cat "${jsondir}/pr-${n}.json" 2>/dev/null)"
    verdict="$(_pr_gate "$detail" "$def")"
    if [ -z "$verdict" ]; then
      echo "SKIP #${n}: unreadable PR JSON"
      continue
    fi
    title="$(printf '%s' "$detail" | jq -r '.title // ""' 2>/dev/null)"
    head="$(printf '%s' "$detail" | jq -r '.headRefName // ""' 2>/dev/null)"
    if [ "$verdict" = "OK" ] && awk -F'\t' -v h="$head" -v n="$n" '$3 == h && $1 != n { found = 1 } END { exit !found }' "$cache"; then
      verdict="SKIP dependents open, retarget them first (SPEC-065)"
    fi
    if [ "$verdict" = "OK" ]; then
      echo "eligible #${n} ${title} [${head}]"
      [ -n "$first_eligible" ] || first_eligible="$n"
    else
      echo "SKIP #${n} ${title}: ${verdict#SKIP }"
    fi
  done

  local head_oid=""
  [ -n "$first_eligible" ] && head_oid="$(jq -r '.headRefOid // ""' "${jsondir}/pr-${first_eligible}.json" 2>/dev/null)"
  rm -rf "$jsondir"

  [ "$do_apply" = 1 ] || { echo "dry run; pass --apply to merge one PR."; return 0; }
  [ -n "$first_eligible" ] || { echo "nothing eligible to merge."; return 0; }
  [ -n "$head_oid" ] || {
    echo "FAILED merge #${first_eligible}: no head SHA to pin the merge to" >&2; return 2; }

  # Squash only, one PR per call, never --delete-branch (a worktree may hold the branch)
  # and never --auto (an armed auto-merge lands a later push, SPEC-065 trap).
  # --match-head-commit pins the merge to the head the gates just read, so a push that
  # lands between the gate and the merge aborts the call instead of shipping unreviewed.
  gh pr merge "$first_eligible" --repo "$url" --squash --match-head-commit "$head_oid"
  local rc=$?
  if [ "$rc" -ne 0 ]; then echo "FAILED merge #${first_eligible}: exit ${rc}" >&2; return 2; fi

  local after state sha
  after="$(gh pr view "$first_eligible" --repo "$url" --json state,mergeCommit 2>/dev/null)"
  state="$(printf '%s' "$after" | jq -r '.state // ""' 2>/dev/null)"
  sha="$(printf '%s' "$after" | jq -r '.mergeCommit.oid // ""' 2>/dev/null)"
  if [ "$state" != "MERGED" ]; then
    echo "FAILED merge #${first_eligible}: state is '${state:-unknown}', not MERGED" >&2
    return 2
  fi
  echo "merged #${first_eligible} ${sha}"
  return 0
}

# --------------------------------------------------------------------------- log

# _realpath_f <path> -- absolute path with every symlink on it resolved. The directory must
# exist; the leaf need not.
_realpath_f() {
  local p="$1" dir base tgt n=0
  dir="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || return 1
  base="$(basename "$p")"
  while [ -L "$dir/$base" ] && [ "$n" -lt 16 ]; do
    tgt="$(readlink "$dir/$base")"
    case "$tgt" in /*) ;; *) tgt="${dir}/${tgt}" ;; esac
    dir="$(cd "$(dirname "$tgt")" 2>/dev/null && pwd -P)" || return 1
    base="$(basename "$tgt")"
    n=$(( n + 1 ))
  done
  printf '%s/%s\n' "${dir%/}" "$base"
}

# _home_fence <path> [<label>] -- 0 when <path> is the physical $HOME or sits under it.
# The fence resolves its own argument: a caller that forgets to resolve first would otherwise
# fence a string whose parent directory is a symlink pointing anywhere on disk. $HOME itself
# is accepted so this fence agrees with `_under_home`, the parity `config seams` reports on.
# Prints the reason and returns 1 otherwise.
_home_fence() {
  local p="$1" label="${2:-wrap}" home_real real
  home_real="$(cd "$HOME" 2>/dev/null && pwd -P)" \
    || { echo "${label}: cannot resolve HOME" >&2; return 1; }
  real="$(_realpath_f "$p")" || { echo "${label}: cannot resolve '${p}'" >&2; return 1; }
  case "$real" in
    "$home_real"|"$home_real"/*) return 0 ;;
    *) echo "${label}: '${real}' is outside HOME (${home_real})" >&2; return 1 ;;
  esac
}

# _refuse_symlink <path> [<label>] -- 1 when <path> is a symlink. A symlink at a write target
# redirects the append to whatever it points at, so every write path refuses one.
_refuse_symlink() {
  local p="$1" label="${2:-wrap}"
  [ -L "$p" ] || return 0
  echo "${label}: '${p}' is a symlink" >&2
  return 1
}

# _worktree_copy <file>: the configured log names one fixed file, usually inside a repo's
# main checkout. A session that works in a git worktree of that same repo cannot commit a
# line written to the main checkout (its branch is not the session's), so when the current
# directory is a worktree sharing the file's repo, the same repo-relative path inside the
# current worktree is the target. Prints the path to use; the input when nothing applies.
_worktree_copy() {
  local file="$1" fdir fcommon ftop cur_common cur_top rel
  fdir="$(dirname "$file")"
  fcommon="$(git -C "$fdir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || { printf '%s' "$file"; return 0; }
  ftop="$(git -C "$fdir" rev-parse --show-toplevel 2>/dev/null)" || { printf '%s' "$file"; return 0; }
  cur_common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || { printf '%s' "$file"; return 0; }
  cur_top="$(git rev-parse --show-toplevel 2>/dev/null)" || { printf '%s' "$file"; return 0; }
  [ "$fcommon" = "$cur_common" ] || { printf '%s' "$file"; return 0; }
  [ "$ftop" != "$cur_top" ] || { printf '%s' "$file"; return 0; }
  rel="${file#"$ftop"/}"
  # `[ -f ]` follows symlinks, so this gate accepts a symlink whose target is a regular file
  # anywhere on disk. The returned path is a NEW path no earlier check saw: every caller must
  # re-run its symlink refusal and its fence on the value this prints.
  [ -f "$cur_top/$rel" ] || { printf '%s' "$file"; return 0; }
  printf '%s' "$cur_top/$rel"
}

cmd_log() {
  local date_str text="" arg have_text=0
  date_str="$(date +%F)"
  while [ $# -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --date) [ $# -ge 2 ] || { echo "usage: wrap.sh log [--date YYYY-MM-DD] \"<slug>: <one sentence>\"" >&2; return 64; }
              date_str="$2"; shift 2 ;;
      *) [ "$have_text" = 0 ] || { echo "wrap.sh log: one text argument only" >&2; return 64; }
         text="$arg"; have_text=1; shift ;;
    esac
  done
  [ "$have_text" = 1 ] && [ -n "$text" ] || { echo "usage: wrap.sh log [--date YYYY-MM-DD] \"<slug>: <one sentence>\"" >&2; return 64; }

  # The date prefixes a line in a file the kit writes. Anything but a plain YYYY-MM-DD, a
  # second line or an out-of-range field included, refuses before any write.
  case "$date_str" in
    [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]) ;;
    *) echo "wrap log: --date must be YYYY-MM-DD" >&2; return 1 ;;
  esac

  case "$text" in
    *$'\n'*|*$'\r'*|*$'\t'*)
      echo "wrap log: the text carries a control character; one line, no tabs" >&2; return 1 ;;
  esac
  case "$text" in
    *$'\xe2\x80\x94'*|*$'\xe2\x80\x93'*)
      echo "wrap log: the text carries an em or en dash; use a comma, a colon or a new sentence" >&2; return 1 ;;
  esac

  local line="${date_str} · ${text}"

  local target; target="$(kit_config_get_root wrap.activity_log "")"
  if [ -z "$target" ]; then
    printf '%s\n' "$line"
    echo "wrap log: no wrap.activity_log key in the kit-root kit.toml; line not written" >&2
    return 0
  fi

  case "$target" in
    "~"/*) target="${HOME}/${target#\~/}" ;;
    /*) ;;
    *) echo "wrap log: wrap.activity_log must be an absolute or ~-prefixed path, got '${target}'" >&2; return 1 ;;
  esac

  local resolved
  resolved="$(_realpath_f "$target")" || { echo "wrap log: cannot resolve '${target}'" >&2; return 1; }
  _home_fence "$resolved" "wrap log" || return 1
  [ -f "$resolved" ] || { echo "wrap log: '${resolved}' is not an existing regular file" >&2; return 1; }

  # The worktree copy is a different path, gated only by `[ -f ]`, so it gets the same
  # refusal and the same fence before anything is written to it. The refusal covers the leaf;
  # resolving the whole path covers a symlink at any parent directory, which would otherwise
  # carry the write outside HOME while the string still reads as being under the worktree.
  resolved="$(_worktree_copy "$resolved")"
  _refuse_symlink "$resolved" "wrap log" || return 1
  resolved="$(_realpath_f "$resolved")" \
    || { echo "wrap log: cannot resolve the worktree copy" >&2; return 1; }
  _home_fence "$resolved" "wrap log" || return 1
  [ -f "$resolved" ] || { echo "wrap log: '${resolved}' is not an existing regular file" >&2; return 1; }

  local n=${#line}
  [ "$n" -gt "$LOG_LINE_BUDGET" ] && echo "wrap log: note: ${n} chars, over the ${LOG_LINE_BUDGET}-char routine budget" >&2

  local tmp mode; tmp="$(mktemp)"
  printf '%s\n' "$line" > "$tmp"
  cat "$resolved" >> "$tmp"
  mode="$(_fmode "$resolved")"
  case "$mode" in ''|*[!0-7]*) mode="" ;; esac
  [ -n "$mode" ] && chmod "$mode" "$tmp"   # mktemp opens 0600; carry the target's mode over
  mv -f "$tmp" "$resolved"
  printf '%s\n' "$line"
  return 0
}

# --------------------------------------------------------------------------- knowledge-root

# cmd_knowledge_root <repo> -- SPEC-249 TASK-004. Prints one absolute directory and always
# exits 0: `knowledge.root` empty or any failure resolving/fencing/creating it falls back to
# `<repo>/.claude/memory`, never an error. The `<repo>` argument itself is validated (must
# exist, basename must not be `.`/`..`/empty) and THAT failure is the one case that is a
# real usage error (exit 64), since there is no repo to fall back under.
cmd_knowledge_root() {
  [ $# -eq 1 ] || { echo "usage: wrap.sh knowledge-root <repo>" >&2; return 64; }
  local repo="$1" repo_real trimmed base
  repo_real="$(cd "$repo" 2>/dev/null && pwd -P)" \
    || { echo "usage: wrap.sh knowledge-root <repo>" >&2; return 64; }
  trimmed="${repo_real%/}"
  base="${trimmed##*/}"
  case "$base" in
    .|..|"") echo "usage: wrap.sh knowledge-root <repo>" >&2; return 64 ;;
  esac

  local fallback="${repo_real}/.claude/memory"
  local root; root="$(kit_config_get_root knowledge.root "")"
  if [ -z "$root" ]; then
    printf '%s\n' "$fallback"
    return 0
  fi

  # Same `~` expansion rule cmd_log applies to wrap.activity_log.
  case "$root" in
    "~"/*) root="${HOME}/${root#\~/}" ;;
  esac

  # The dir variant of _realpath_f: `cd && pwd -P` follows every symlink on the path and
  # collapses it to the physical directory, or fails when the directory does not exist.
  local resolved
  resolved="$(cd "$root" 2>/dev/null && pwd -P)"
  if [ -z "$resolved" ]; then
    echo "knowledge-root: '${root}' is not an existing directory, using ${fallback}" >&2
    printf '%s\n' "$fallback"
    return 0
  fi

  if ! _home_fence "$resolved" knowledge-root; then
    echo "knowledge-root: using ${fallback}" >&2
    printf '%s\n' "$fallback"
    return 0
  fi

  if ! _write_guard "$repo_real"; then
    echo "knowledge-root: index.lock held by another writer, using ${fallback}" >&2
    printf '%s\n' "$fallback"
    return 0
  fi

  # Only `<root>` was fenced above. `mkdir -p` walks through a symlink at `projects` or at the
  # leaf without complaint, so both are refused before the create, and the created directory is
  # re-resolved and re-fenced after it.
  local projects="${resolved}/projects"
  local target="${projects}/${base}"
  if ! _refuse_symlink "$projects" knowledge-root || ! _refuse_symlink "$target" knowledge-root; then
    echo "knowledge-root: using ${fallback}" >&2
    printf '%s\n' "$fallback"
    return 0
  fi
  if ! mkdir -p "$target" 2>/dev/null; then
    echo "knowledge-root: could not create '${target}', using ${fallback}" >&2
    printf '%s\n' "$fallback"
    return 0
  fi
  local target_real
  target_real="$(cd "$target" 2>/dev/null && pwd -P)"
  if [ -z "$target_real" ] || ! _home_fence "$target_real" knowledge-root; then
    echo "knowledge-root: using ${fallback}" >&2
    printf '%s\n' "$fallback"
    return 0
  fi
  printf '%s\n' "$target_real"
  return 0
}

# --------------------------------------------------------------------------- stage

# cmd_stage "<title>" "<intent>" "<home>" [--repo <repo>] -- SPEC-249 TASK-004. Resolves the
# staging file the same way cmd_log resolves its target (dir realpath, symlink refusal, a
# HOME/repo fence, `_worktree_copy`), then hands the write itself to the one place the
# staging-block grammar and its dedupe rule live: `staging-format.py stage`.
cmd_stage() {
  local repo="" arg count=0
  local pos1="" pos2="" pos3=""
  while [ $# -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --repo)
        [ $# -ge 2 ] || {
          echo 'usage: wrap.sh stage "<title>" "<intent>" "<home>" [--repo <repo>]' >&2
          return 64
        }
        repo="$2"; shift 2 ;;
      *)
        count=$(( count + 1 ))
        case "$count" in 1) pos1="$arg" ;; 2) pos2="$arg" ;; 3) pos3="$arg" ;; esac
        shift ;;
    esac
  done
  [ "$count" -eq 3 ] || {
    echo 'usage: wrap.sh stage "<title>" "<intent>" "<home>" [--repo <repo>]' >&2
    return 64
  }
  local title="$pos1" intent="$pos2" home="$pos3"

  local repo_top
  if [ -n "$repo" ]; then
    repo_top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)"
  else
    repo_top="$(git rev-parse --show-toplevel 2>/dev/null)"
  fi
  [ -n "$repo_top" ] || {
    echo 'usage: wrap.sh stage "<title>" "<intent>" "<home>" [--repo <repo>]' >&2
    return 64
  }
  repo_top="$(cd "$repo_top" 2>/dev/null && pwd -P)" \
    || { echo "wrap stage: cannot resolve the repo toplevel" >&2; return 64; }

  local staging="${BACKLOG_STAGE_STAGING:-${repo_top}/_meta/backlog-staging.md}"
  local backlog="${BACKLOG_STAGE_BACKLOG:-${repo_top}/_meta/BACKLOG.md}"

  # The staging path's parent directory must resolve. Only the default parent (the repo's
  # own `_meta/`) is created on demand; an env-override parent must already exist.
  local staging_dir; staging_dir="$(dirname "$staging")"
  if [ -z "${BACKLOG_STAGE_STAGING:-}" ]; then
    mkdir -p "$staging_dir" 2>/dev/null \
      || { echo "wrap stage: cannot create ${staging_dir}" >&2; return 1; }
  fi
  local staging_dir_real
  staging_dir_real="$(cd "$staging_dir" 2>/dev/null && pwd -P)" \
    || { echo "wrap stage: '${staging_dir}' does not resolve" >&2; return 1; }

  local leaf; leaf="$(basename "$staging")"
  local resolved="${staging_dir_real%/}/${leaf}"

  # Never a symlink; absent or an existing regular file only.
  _refuse_symlink "$resolved" "wrap stage" || return 1
  if [ -e "$resolved" ] && [ ! -f "$resolved" ]; then
    echo "wrap stage: '${resolved}' is not a regular file" >&2; return 1
  fi

  # Inside the repo toplevel by default; under HOME when the env override chose the path. The
  # override comes from the environment, which a repo `.envrc` writes, so it may only append to
  # a file that already exists: create-on-absent under HOME would let it seed a new block into
  # any absent path, an agent instruction file included. Only the repo default creates.
  if [ -n "${BACKLOG_STAGE_STAGING:-}" ]; then
    _home_fence "$resolved" "wrap stage" || return 1
    [ -f "$resolved" ] \
      || { echo "wrap stage: '${resolved}' is not an existing regular file" >&2; return 1; }
  else
    case "$resolved" in
      "$repo_top"/*) ;;
      *) echo "wrap stage: '${resolved}' is outside the repo (${repo_top})" >&2; return 1 ;;
    esac
  fi

  if ! _write_guard "$repo_top"; then
    echo "wrap stage: index.lock held by another writer" >&2; return 1
  fi

  # The worktree copy is a path none of the checks above saw, and `_worktree_copy` gates it
  # only with `[ -f ]`, which follows a symlink. Re-run the refusal and the fence on it. The
  # refusal covers the leaf; resolving the whole path covers a symlink at any parent directory
  # (`<worktree>/_meta` pointing off disk), which the prefix rules below would otherwise pass
  # because the unresolved string still starts with the worktree toplevel.
  local pre_copy="$resolved"
  resolved="$(_worktree_copy "$resolved")"
  if [ "$resolved" != "$pre_copy" ]; then
    _refuse_symlink "$resolved" "wrap stage" || return 1
    resolved="$(_realpath_f "$resolved")" \
      || { echo "wrap stage: cannot resolve the worktree copy" >&2; return 1; }
    [ -f "$resolved" ] \
      || { echo "wrap stage: '${resolved}' is not a regular file" >&2; return 1; }
    if [ -n "${BACKLOG_STAGE_STAGING:-}" ]; then
      _home_fence "$resolved" "wrap stage" || return 1
    else
      # The copy lives in the CURRENT worktree, which is a different toplevel of the same repo.
      # Both toplevels are compared as realpaths, matching the resolved copy.
      local cur_top
      cur_top="$(git rev-parse --show-toplevel 2>/dev/null)" \
        && cur_top="$(cd "$cur_top" 2>/dev/null && pwd -P)"
      case "$resolved" in
        "$repo_top"/*) ;;
        "${cur_top:-/dev/null/never}"/*) ;;
        *) echo "wrap stage: '${resolved}' is outside the repo (${repo_top})" >&2; return 1 ;;
      esac
    fi
  fi

  [ -f "$STAGING_FORMAT_PY" ] \
    || { echo "wrap stage: staging-format.py missing at ${STAGING_FORMAT_PY}" >&2; return 1; }

  # Build the JSON with sys.argv, never string interpolation: title/intent/home are
  # session text and must never be able to forge a stdin field.
  python3 -c '
import json, sys
title, intent, home, staging, backlog = sys.argv[1:6]
json.dump(
    {"title": title, "intent": intent, "home": home, "staging": staging, "backlog": backlog},
    sys.stdout,
)
' "$title" "$intent" "$home" "$resolved" "$backlog" \
    | python3 "$STAGING_FORMAT_PY" stage
  return $?
}

# --------------------------------------------------------------------------- default-branch

cmd_default_branch() {
  [ $# -eq 1 ] || { echo "usage: wrap.sh default-branch <repo>" >&2; return 64; }
  _is_repo "$1" || { echo "wrap.sh default-branch: $1 is not a git repo" >&2; return 1; }
  local def
  def="$(_default_branch "$1")" || { echo "wrap.sh default-branch: no default branch resolved for $1" >&2; return 1; }
  printf '%s\n' "$def"
  return 0
}

# --------------------------------------------------------------------------- entry

main() {
  local verb="${1:-}"
  [ $# -gt 0 ] && shift
  case "$verb" in
    scan)           cmd_scan "$@" ;;
    apply)          cmd_apply "$@" ;;
    merge)          cmd_merge "$@" ;;
    log)            cmd_log "$@" ;;
    default-branch) cmd_default_branch "$@" ;;
    knowledge-root) cmd_knowledge_root "$@" ;;
    stage)          cmd_stage "$@" ;;
    -h|--help|help|"") _usage; return 0 ;;
    *) echo "wrap: unknown verb '$verb' (try: wrap --help)" >&2; return 64 ;;
  esac
}

main "$@"
