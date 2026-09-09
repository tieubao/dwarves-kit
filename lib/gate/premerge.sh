#!/usr/bin/env bash
# premerge.sh -- merge the default branch into the working branch before a PR opens (ID-653).
#
# GitHub's squash-merge does not honour .gitattributes merge=union. A branch that touched an
# append-only log (LAB_LOG.md, BACKLOG.md) after the default branch moved can show CONFLICTING
# on GitHub even though a plain local merge resolves cleanly. Running that merge locally, right
# before the PR opens, surfaces the conflict where it is cheap to fix and leaves GitHub nothing
# to disagree about.
#
# SAFE: `git merge` only, never a rebase, never a force-push -- history is never rewritten. A
# real conflict is left exactly as `git merge` leaves it: unmerged paths, non-zero exit, no side
# auto-picked. The caller resolves by hand and re-runs; nothing here chooses ours/theirs.
#
# QUIET WHEN CURRENT: a branch already an ancestor of the default branch, or already ahead of
# it with nothing new to take, fetches once and exits 0 with no output.
#
# Usage: premerge.sh check [<repo>]   -- default <repo> is the cwd
set -uo pipefail

PM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

cmd_check() {
  local repo="${1:-.}"
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "premerge: $repo is not a git repo" >&2; return 1
  }
  local branch
  branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  case "$branch" in
    ""|HEAD)
      return 0 ;;   # detached HEAD: no work branch to premerge, nothing to do
  esac

  local def
  def="$(bash "$PM_DIR/../wrap/wrap.sh" default-branch "$repo" 2>/dev/null)" || {
    echo "premerge: no default branch resolved for $repo; skipping the pre-PR merge" >&2
    return 0
  }
  [ "$branch" = "$def" ] && return 0   # on the default branch: no PR being opened

  git -C "$repo" fetch origin "$def" -q || {
    echo "premerge: fetch of origin/$def failed; skipping the pre-PR merge" >&2
    return 0
  }

  if git -C "$repo" merge-base --is-ancestor "origin/$def" HEAD 2>/dev/null; then
    return 0   # already current: silent no-op
  fi

  if git -C "$repo" merge --no-edit "origin/$def"; then
    echo "premerge: merged origin/$def into $branch"
    return 0
  fi
  echo "premerge: origin/$def does not merge cleanly into $branch; resolve the conflict, then re-run" >&2
  return 1
}

main() {
  local verb="${1:-}"; [ $# -gt 0 ] && shift
  case "$verb" in
    check) cmd_check "$@" ;;
    -h|--help|help|"") echo "usage: premerge.sh check [<repo>]" ;;
    *) echo "premerge: unknown verb '$verb' (try: premerge.sh --help)" >&2; return 64 ;;
  esac
}

main "$@"
