#!/usr/bin/env bash
# mega.sh -- `mega status <slug>` (kit-modularity sub-goal 08): reconciles a
# mega-goal's ROADMAP.md sub-goal claims against GIT TRUTH instead of trusting the roadmap's
# own prose. Bash + `gh` only -- no DuckDB (a keyed diff over a handful of sub-goals, not
# analytics; DuckDB stays the `stats` exception per the kit-modularity event-sourcing invariant).
#
# Verbs: `status` (roadmap-vs-git reconcile) · `review --html` (the sign-off dashboard) ·
# `report` (the RUN_REPORT telemetry generator: header + gate matrix + callable-stack
# skeleton from the rid ledgers; --out, --rid-map).
#
# A subsystem dir (SG-03's "2+-verb modules get a grouped `lib/<x>/<x>.sh`" rule): `mega` has
# two verbs (`status`, `review` -- SPEC-197 / harness-loop SG-07) and was promoted into
# `lib/mega/` (`lib/mega/mega.sh` + siblings, stable entry `bin/mega`) per ADR-0034 / ID-287.
# `review`'s substantial composition logic lives in the sibling `lib/mega/mega-review.py`
# (bash-launcher-to-python, the exact delegation shape `lib/gate/proof-table-gen.sh` ->
# `lib/gate/proof-table-gen.py` already established: bash 3.2 has no associative arrays, which
# the phase/token/PR joins need). Same shape as `lib/board/board.sh` delegating to
# `lib/board/board-mirror.sh` for its own heavier verbs. The single-verb orphans
# (`lib/adopt.sh` / `lib/explain.sh` / `lib/pitch.sh`) stay at root as ADR-0034 "deliberate
# orphans" pending their own ruling. `lib/precedent.sh` was promoted out of that set into
# `lib/precedent/precedent.sh` (SPEC-245: records + inventory surfaces, stable entry
# `bin/precedent`).
#
# WHY THIS EXISTS (provenance): a live session hit the SG-02 HANDOFF-vs-reality lie by hand --
# HANDOFF.md claimed "running" while the `kitmod-02` worktree sat at 0 commits, empty. A dumb
# reader that only echoes a roadmap's own `[x]`/`[ ]` boxes would have repeated that lie
# verbatim. This verb is the manual reconciliation (grep ROADMAP, walk branches, verify PRs)
# made mechanical: truth beats the roadmap's prose every time, and when they disagree the flag
# names which side is stale. NOT a live-process monitor (whether a `claude` session is running
# RIGHT NOW is the runner's own journal/RUNNER_DONE job); this only ever points at git + gh.
#
# ROADMAP sub-goal line grammar parsed (documented convention, no fixed schema -- same judgment
# call `lib/board/board-mirror.sh`'s `extract_megas` already documents for this same file).
# BOTH id forms are accepted: `SG-NN` is what `/kit:mega` scaffolds today (commands/mega.md),
# `NN-slug` is the older form every archived roadmap still carries.
#   - [x] SG-01 Collapse the module , auto , PR #190 merged cb64f15
#   - [x] 01-module-collapse (dwarves-kit), <prose>, PR #190 merged cb64f15 (<prose>)
#   - [ ] 04-install-wire (dwarves-kit), <prose>, PR #
#   - [~] 09-rehomed (dwarves-kit), rehomed into <other mega> (informational, never flagged)
# `[x]`/`[X]` = checked, `[ ]` = unchecked, `[~]` = rehomed/superseded (informational only, per
# DECISIONS.md's SG-01 outcome notes -- these are never drift-flagged even when git truth
# disagrees, because the roadmap is explicitly saying "this box means something else now").
#
# Git truth per sub-goal (gathered against --code-root, the repo the sub-goal's OWN branches/
# PRs live in -- for kit-modularity that is dwarves-kit, a DIFFERENT repo from --megagoals-root,
# which is wherever the mega's ROADMAP.md lives, e.g. ops-toolkit):
#   - PR state: `${GH_BIN:-gh} pr view <N> --json state -q .state` (MERGED/OPEN/CLOSED/missing).
#   - Branch: read the sub-goal's own goal file (`<megagoals-root>/<slug>/goals/<sub>.md`)'s
#     `**Branch:** <name>` line -- the authoritative name (no guessing a naming convention).
#     A sub-goal whose goal file is missing or carries no `**Branch:**` line has no git-truth
#     signal beyond the PR check (this is honest, not a failure).
#   - Commit count: `${GIT_BIN:-git} -C <code-root> rev-list --count <base>..<branch>` (base
#     defaults to `master`, `--base` overrides). Uses the BRANCH REF directly, not a worktree
#     path -- a worktree may have been cleaned up after a PR merges/closes while the branch ref
#     (or its remote-tracking counterpart) still exists, and the ref-based count is exactly as
#     valid a "0 commits" signal as walking a worktree directory would be, without depending on
#     the worktree still being present on disk. Tries the local branch ref first, then
#     `origin/<branch>` (a pushed branch with no local worktree at all).
#   - Open PR: `${GH_BIN:-gh} pr list --state open --json number,headRefName` filtered locally
#     by `headRefName == branch` (jq).
#
# Drift classes (the whole value of this tool -- a dumb `[x]`/`[ ]` echo is worthless):
#   ✓                 [x] and its PR#N verified MERGED.
#   CLAIM-UNVERIFIED  [x] but PR#N is NOT merged (open/closed/missing) -- roadmap ahead of
#                     reality, a green-wash. Never silently trusted.
#   MERGED-UNCHECKED  [ ] but its PR#N IS merged -- roadmap lagging reality.
#   STALLED           [ ] and the branch exists with 0 commits vs base AND no open PR -- a
#                     dispatched-but-empty run (the exact HANDOFF-vs-reality lie this verb
#                     exists to catch).
#   WIP               [ ] and the branch has >0 commits vs base, OR an open PR exists for it --
#                     real in-flight work, NOT stalled (a live worker mid-build is not a lie).
#   PENDING           [ ] and there is no branch, no PR at all -- not yet started; informational.
#   INFO              [~] -- rehomed/superseded, always informational, never flagged regardless
#                     of what git truth shows.
#
# Usage:
#   mega.sh status <slug> [--megagoals-root <path>] [--code-root <path>] [--base <branch>]
#                          [--rollup-only]
#     <slug>              the mega-goal's directory name under <megagoals-root>/
#     --megagoals-root    where `<slug>/ROADMAP.md` lives. Precedence: this flag >
#                         $MEGAGOALS_ROOT > `${REPO_ROOT}/_meta/megagoals` (REPO_ROOT is the
#                         kit's existing consumer-config env var, same seam `board`/`queue`
#                         already read) > `<git-toplevel-of-cwd>/_meta/megagoals`. The kit
#                         itself never hardcodes a personal path.
#     --code-root         the repo whose branches/worktrees/PRs are git truth for this mega's
#                         sub-goals. Precedence: this flag > $CODE_ROOT > `<git-toplevel-of-cwd>`
#                         (the natural default: you normally run `mega status` FROM the code
#                         repo the sub-goals build in).
#     --base              the PR base branch sub-goal commit counts are measured against.
#                         Default `master`.
#     --rollup-only       print ONLY the final rollup line (`N/M ok  M-N drift: ...`), no
#                         per-sub-goal detail -- the form `board`'s render wires in as a column.
#
#   mega.sh review <slug> --html [--megagoals-root <path>] [--code-root <path>] [--base <branch>]
#                          [--out <path>]
#     Composes ONE self-contained static HTML sign-off page (SPEC-197, harness-loop SG-07) from
#     THREE read-only sources: this `status` verb's own git-truth reconciliation, the gate/run
#     ledger (GATE/OUTCOME/TOKENS lines), and `gh pr view` (PR/CI/merge state) -- plus a
#     best-effort harness-wide footer (staged candidates, learned-ledger queued, unpaid debt).
#     `--html` is currently the ONLY surface and is required (no live/served variant; scope
#     fence, see the goal file). Default `--out`: `<megagoals-root>/<slug>/REVIEW.html` (next to
#     RUN_REPORT.md). A projection, never a stored source of truth (SPEC-182 discipline): safe
#     to re-run any time, nothing cached. The substantial logic lives in the sibling
#     `lib/mega/mega-review.py`; this verb is a thin bash launcher that resolves KIT_LOG_DIR the exact
#     way `lib/gate/proof-table-gen.sh` already does, then execs it.
#
#   mega.sh runs [--registry <path>] [--root <dir>]... [--out <path>]
#                [--max-embed-bytes <n>] [--total-embed-bytes <n>]
#     The ESTATE-WIDE sibling of `review` (SPEC-215): ONE self-contained static HTML page of run
#     cards over EVERY registered repo, composed from run reports (`_meta/megagoals/**/
#     RUN_REPORT.md`), proofs of done (`**/docs/proof-of-done.md`), and verification runs
#     (`docs/verification/**/runs/*.md`), with each report's own capture images embedded inline.
#     Same projection discipline as `review`: reads only, caches nothing, safe to re-run.
#     --registry   a `boards.txt`-format registry of repos to scan. Precedence: this flag >
#                  $KIT_BOARDS_REGISTRY > `<git-toplevel-of-cwd>/_meta/boards.txt`. Every row is
#                  scanned, including rows without the `bridge` column -- `bridge` gates a
#                  Hermes WRITE path, not reading a repo's own reports (SPEC-215 DEC-002).
#     --root       scan this repo root directly; repeatable, and bypasses the registry entirely.
#     --out        default `runs-dashboard.html` in the cwd.
#     Empty estate is NOT an error: an empty or artifact-free root renders a valid page carrying
#     an explicit empty-state banner and exits 0. Nothing is fabricated to fill it.
#     Logic lives in the sibling `lib/mega/runs-dashboard.py`; this verb is a thin launcher.
#
# GH_BIN / GIT_BIN override the `gh`/`git` binaries (tests point them at PATH-injected stubs
# that log argv and return canned JSON, per the suite's existing convention -- see
# `lib/board/board-writeback.sh`'s `GH_BIN`). No real network call is ever made by the test
# suite; every gh/git interaction here is a plain, stub-friendly subprocess call.

set -uo pipefail

GH_BIN="${GH_BIN:-gh}"
GIT_BIN="${GIT_BIN:-git}"

_default_repo_root() { "$GIT_BIN" rev-parse --show-toplevel 2>/dev/null || pwd; }

OPT_MEGAGOALS_ROOT=""; OPT_CODE_ROOT=""; OPT_BASE=""; OPT_ROLLUP_ONLY=0
OPT_HTML=0; OPT_OUT=""; OPT_RID_MAP=""
POSITIONAL=()
_parse_flags() {
  OPT_MEGAGOALS_ROOT=""; OPT_CODE_ROOT=""; OPT_BASE=""; OPT_ROLLUP_ONLY=0
  OPT_HTML=0; OPT_OUT=""; OPT_RID_MAP=""
  POSITIONAL=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --megagoals-root) OPT_MEGAGOALS_ROOT="${2:-}"; shift 2 ;;
      --rid-map)        OPT_RID_MAP="${2:-}"; shift 2 ;;
      --code-root)      OPT_CODE_ROOT="${2:-}"; shift 2 ;;
      --base)           OPT_BASE="${2:-}"; shift 2 ;;
      --rollup-only)    OPT_ROLLUP_ONLY=1; shift ;;
      --html)           OPT_HTML=1; shift ;;
      --out)            OPT_OUT="${2:-}"; shift 2 ;;
      *) POSITIONAL+=("$1"); shift ;;
    esac
  done
}

_resolve_megagoals_root() {
  if [ -n "$OPT_MEGAGOALS_ROOT" ]; then printf '%s\n' "$OPT_MEGAGOALS_ROOT"; return; fi
  if [ -n "${MEGAGOALS_ROOT:-}" ]; then printf '%s\n' "$MEGAGOALS_ROOT"; return; fi
  if [ -n "${REPO_ROOT:-}" ]; then printf '%s/_meta/megagoals\n' "$REPO_ROOT"; return; fi
  printf '%s/_meta/megagoals\n' "$(_default_repo_root)"
}

_resolve_code_root() {
  if [ -n "$OPT_CODE_ROOT" ]; then printf '%s\n' "$OPT_CODE_ROOT"; return; fi
  if [ -n "${CODE_ROOT:-}" ]; then printf '%s\n' "$CODE_ROOT"; return; fi
  _default_repo_root
}

# _sub_branch <megagoals-root> <slug> <sub-slug> -- reads the sub-goal's own goal file's
# `**Branch:** <name>` line. Empty output = no goal file / no Branch line (honest absence, not
# an error): the sub-goal then has no git-truth signal beyond its PR check.
_sub_branch() {
  local mroot="$1" slug="$2" sub="$3" gf
  gf="$mroot/$slug/goals/$sub.md"
  [ -f "$gf" ] || return 0
  grep -m1 -E '^\*\*Branch:\*\* ' "$gf" 2>/dev/null | sed -E 's/^\*\*Branch:\*\* *//'
}

# _pr_state <pr-number> -- MERGED/OPEN/CLOSED, or empty if unresolvable (missing/deleted PR,
# `gh` failure). Never treated as a hard error: an unresolvable PR# is exactly a
# CLAIM-UNVERIFIED signal for a [x] row (the roadmap cites a PR that can't be confirmed).
_pr_state() {
  local pr="$1"
  "$GH_BIN" pr view "$pr" --json state -q '.state' 2>/dev/null || true
}

# _commit_count <code-root> <base> <branch> -- commits on <branch> not on <base>. Tries the
# local branch ref, then `origin/<branch>` (a pushed-but-no-local-worktree branch). Empty
# output = branch does not exist anywhere reachable (honest absence).
_commit_count() {
  local root="$1" base="$2" branch="$3"
  if "$GIT_BIN" -C "$root" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1; then
    "$GIT_BIN" -C "$root" rev-list --count "$base..$branch" 2>/dev/null || true
    return
  fi
  if "$GIT_BIN" -C "$root" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null 2>&1; then
    "$GIT_BIN" -C "$root" rev-list --count "$base..origin/$branch" 2>/dev/null || true
  fi
}

# _open_pr_for <branch> -- the PR number of an OPEN pr whose head is <branch>, or empty.
_open_pr_for() {
  local branch="$1" out
  out="$("$GH_BIN" pr list --state open --json number,headRefName 2>/dev/null)" || return 0
  printf '%s' "$out" | jq -r --arg b "$branch" '.[] | select(.headRefName == $b) | .number' 2>/dev/null | head -n1
}

# _classify <box> <prnum> <prstate> <commit-count> <open-pr> -- one of:
#   ok | claim-unverified | merged-unchecked | stalled | wip | pending | info
_classify() {
  local box="$1" prnum="$2" prstate="$3" commits="$4" openpr="$5"
  case "$box" in
    x|X)
      if [ -n "$prnum" ] && [ "$prstate" = "MERGED" ]; then echo "ok"
      else echo "claim-unverified"
      fi
      ;;
    '~')
      echo "info"
      ;;
    *)
      if [ -n "$prnum" ] && [ "$prstate" = "MERGED" ]; then
        echo "merged-unchecked"
      elif [ -n "$commits" ] && [ "$commits" = "0" ] && [ -z "$openpr" ]; then
        echo "stalled"
      elif { [ -n "$commits" ] && [ "$commits" != "0" ]; } || [ -n "$openpr" ]; then
        echo "wip"
      else
        echo "pending"
      fi
      ;;
  esac
}

_label() {
  # DOWNSTREAM COUPLING (review finding, SPEC-197): `lib/mega/mega-review.py`'s `_STATUS_LINE_RE`
  # regex parses `cmd_status`'s stdout by matching this exact label set literally (shelled out
  # to, not reimplemented -- SPEC-197 DEC-003). A cosmetic rename here degrades `mega review`
  # to a silent, non-fatal honest-empty read for the affected rows (never a crash, per the
  # composer's own "never fatal" contract) rather than a loud break -- worth a grep for
  # `_STATUS_LINE_RE` in `lib/mega/mega-review.py` before renaming any of these strings.
  case "$1" in
    ok)                echo "OK" ;;
    claim-unverified)  echo "CLAIM-UNVERIFIED" ;;
    merged-unchecked)  echo "MERGED-UNCHECKED" ;;
    stalled)           echo "STALLED" ;;
    wip)               echo "WIP" ;;
    pending)           echo "PENDING" ;;
    info)              echo "INFO" ;;
    *)                 echo "UNKNOWN" ;;
  esac
}

_symbol() {
  case "$1" in
    ok)                printf '\xe2\x9c\x93' ;;   # checkmark
    claim-unverified)  printf '\xe2\x9a\xa0' ;;    # warning
    merged-unchecked)  printf '\xe2\x9a\xa0' ;;
    stalled)           printf '\xe2\x9a\xa0' ;;
    wip)               printf '~' ;;
    pending)           printf '.' ;;
    info)              printf '-' ;;
    *)                 printf '?' ;;
  esac
}

cmd_status() {
  _parse_flags "$@"
  local slug="${POSITIONAL[0]:-}"
  [ -n "$slug" ] || { echo "mega status: a <slug> is required" >&2; return 64; }

  local mroot croot base
  mroot="$(_resolve_megagoals_root)"
  croot="$(_resolve_code_root)"
  base="${OPT_BASE:-master}"

  local roadmap="$mroot/$slug/ROADMAP.md"
  [ -f "$roadmap" ] || { echo "mega status: no ROADMAP.md at $roadmap" >&2; return 1; }

  local total=0 ok_count=0 drift_count=0
  local -a detail_lines=()

  while IFS= read -r line; do
    # Two grammars are live. The current one `/kit:mega` scaffolds is `SG-NN <title>`
    # (commands/mega.md, and orchestrate.sh's own `_subgoals`); the older `NN-slug` form
    # is still in every archived roadmap. Matching only the old one made this auditor
    # silently find ZERO rows in a current roadmap and report nothing wrong, which is the
    # worst failure available to a reconciler: a checker that cannot see its input passes.
    [[ "$line" =~ ^-\ \[(.)\]\ (SG-[0-9]+|[0-9]+-[A-Za-z0-9_-]+) ]] || continue
    local box="${BASH_REMATCH[1]}" sub="${BASH_REMATCH[2]}"
    total=$((total + 1))

    local prnum="" sha=""
    if [[ "$line" =~ PR\ \#([0-9]+) ]]; then
      prnum="${BASH_REMATCH[1]}"
      if [[ "$line" =~ PR\ \#${prnum}\ merged\ ([0-9a-fA-F]{6,40}) ]]; then
        sha="${BASH_REMATCH[1]}"
      fi
    fi

    local branch commits="" openpr="" prstate=""
    branch="$(_sub_branch "$mroot" "$slug" "$sub")"
    [ -n "$prnum" ] && prstate="$(_pr_state "$prnum")"
    if [ -n "$branch" ]; then
      commits="$(_commit_count "$croot" "$base" "$branch")"
      openpr="$(_open_pr_for "$branch")"
    fi

    local cls; cls="$(_classify "$box" "$prnum" "$prstate" "$commits" "$openpr")"
    case "$cls" in
      ok) ok_count=$((ok_count + 1)) ;;
      claim-unverified|merged-unchecked|stalled) drift_count=$((drift_count + 1)) ;;
    esac

    local extra=""
    [ -n "$prnum" ] && extra="${extra} PR#${prnum}${prstate:+ (${prstate})}"
    [ -n "$branch" ] && extra="${extra} branch=${branch}"
    [ -n "$commits" ] && extra="${extra} commits=${commits}"
    [ -n "$openpr" ] && extra="${extra} open-PR#${openpr}"
    detail_lines+=("$(printf '  %s %-28s %s%s' "$(_symbol "$cls")" "$sub" "$(_label "$cls")" "$extra")")
  done < <(grep -E '^- \[.\] ' "$roadmap")

  [ "$total" -gt 0 ] || { echo "mega status: no sub-goal lines found in $roadmap" >&2; return 1; }

  local rollup
  if [ "$drift_count" -gt 0 ]; then
    rollup="$(printf '%s: %d/%d ok  \xe2\x9a\xa0 %d drift' "$slug" "$ok_count" "$total" "$drift_count")"
  else
    rollup="$(printf '%s: %d/%d ok' "$slug" "$ok_count" "$total")"
  fi

  if [ "$OPT_ROLLUP_ONLY" -eq 1 ]; then
    printf '%s\n' "$rollup"
    [ "$drift_count" -eq 0 ]
    return
  fi

  printf '%s\n' "${detail_lines[@]}"
  printf '%s\n' "$rollup"
  [ "$drift_count" -eq 0 ]
}

# cmd_review: the bash launcher half of `mega review --html <slug>` (SPEC-197). Resolves
# KIT_LOG_DIR the exact way `lib/gate/proof-table-gen.sh` already does (source
# lib/telemetry/kit-log-dir.sh, export the result) so there is ONE resolver, not a second copy,
# then execs the sibling `lib/mega/mega-review.py` (bash 3.2 has no associative arrays, the same
# reason proof-table-gen.sh delegates to its own .py). `--html` is required: it is currently the
# ONLY surface (scope fence -- no live/served variant).
cmd_review() {
  _parse_flags "$@"
  local slug="${POSITIONAL[0]:-}"
  [ -n "$slug" ] || { echo "mega review: a <slug> is required" >&2; return 64; }
  [ "$OPT_HTML" -eq 1 ] || { echo "mega review: --html is required (the only surface today)" >&2; return 64; }

  local mroot croot base
  mroot="$(_resolve_megagoals_root)"
  croot="$(_resolve_code_root)"
  base="${OPT_BASE:-master}"

  local self_dir; self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=lib/telemetry/kit-log-dir.sh
  source "$self_dir/../telemetry/kit-log-dir.sh" || { echo "mega review: lib/telemetry/kit-log-dir.sh missing or unreadable" >&2; return 1; }
  export KIT_LOG_DIR; KIT_LOG_DIR="$(kit_resolve_log_dir)" || return 1

  local -a py_args=("$slug" --megagoals-root "$mroot" --code-root "$croot" --base "$base")
  [ -n "$OPT_OUT" ] && py_args+=(--out "$OPT_OUT")
  python3 "$self_dir/mega-review.py" "${py_args[@]}"
}

# cmd_report: the bash launcher half of `mega report <slug>` -- the RUN_REPORT telemetry
# generator. Fold-in gap fix (Han 2026-07-12): the close contract required a gate matrix +
# callable stack "read from the rid ledger", but no code could render them; the presentation
# lived as conductor habit from the pre-fold era and died in the migration (harness-loop's
# matrix got rebuilt by hand). Same delegation shape as cmd_review: resolve KIT_LOG_DIR via
# the ONE resolver, exec the sibling .py. Read-only; --out is the only write, when passed.
cmd_report() {
  _parse_flags "$@"
  local slug="${POSITIONAL[0]:-}"
  [ -n "$slug" ] || { echo "mega report: a <slug> is required" >&2; return 64; }

  local mroot; mroot="$(_resolve_megagoals_root)"
  local self_dir; self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=lib/telemetry/kit-log-dir.sh
  source "$self_dir/../telemetry/kit-log-dir.sh" || { echo "mega report: lib/telemetry/kit-log-dir.sh missing or unreadable" >&2; return 1; }
  local log_dir; log_dir="$(kit_resolve_log_dir)" || return 1

  local -a py_args=("$slug" --megagoals-root "$mroot" --log-dir "$log_dir")
  [ -n "$OPT_OUT" ] && py_args+=(--out "$OPT_OUT")
  [ -n "$OPT_RID_MAP" ] && py_args+=(--rid-map "$OPT_RID_MAP")
  python3 "$self_dir/mega-report.py" "${py_args[@]}"
}

# `runs` is estate-wide, so it takes NO <slug> and none of `_parse_flags`'s per-mega flags. Its
# argv forwards straight through to the generator, which owns its own flag grammar.
cmd_runs() {
  local self_dir; self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  python3 "$self_dir/runs-dashboard.py" "$@"
}

usage() { sed -n '2,119p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

main() {
  local first="${1:-}"
  case "$first" in
    status) shift; cmd_status "$@" ;;
    review) shift; cmd_review "$@" ;;
    report) shift; cmd_report "$@" ;;
    runs)   shift; cmd_runs "$@" ;;
    -h|--help|help|"") usage ;;
    *) echo "mega.sh: unknown subcommand '$first'" >&2; usage >&2; return 64 ;;
  esac
}

main "$@"
