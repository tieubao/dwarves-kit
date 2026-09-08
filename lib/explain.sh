#!/usr/bin/env bash
# explain.sh -- the grounding + ordering engine behind /kit:explain (ADR-0031 §2, SPEC-124).
#
# Turns a merged change into a LITERATE-DIFF explainer skeleton: background -> goal + intuition
# -> a PROSE-ORDERED diff (reading order, NOT git alphabetical) -> a diagram. It is the mechanical,
# testable half of /kit:explain; commands/explain.md composes narrate-log (prose) + svg-knowledge-diagram
# (a richer figure) ON TOP of what this emits.
#
# THE HARD CONSTRAINT (Litt's caveat, the whole reason this lib exists as a separate plane):
# the ONLY input is a git ref. This lib never accepts a narrative / intent argument. Everything it
# emits traces to the ACTUAL diff (git show/diff) + recorded test results (docs/verification/). An
# agent's own story of what it did can never leak in, because there is no argument through which it
# could. If the artifact ever described the agent's intent instead of the diff, that would be a bug in
# a DIFFERENT layer, never here.
#
# Reading-order rank (spec SPEC-124): within a rank, git order is preserved.
#   rank 0  background     docs/, specs (SPEC-*), ADRs/decisions -- the context the reader needs first
#   rank 1  new concept    newly-ADDED files -- the thing introduced, before its wiring
#   rank 2  integration    modified non-test files -- how the new thing is wired in
#   rank 3  verification   test files -- read last
# git diff --name-only is alphabetical; this rank order interleaves differently. For any multi-rank
# change the two orders differ -- that difference IS the "prose ordering not alphabetical" guarantee.
#
# Usage:
#   explain.sh order   <ref>            reading-ordered changed-file list (one per line)
#   explain.sh mermaid <ref>            a syntactically valid ```mermaid change-map
#   explain.sh tests   <ref>            the recorded test verdict (or an honest absence marker)
#   explain.sh render  <ref> [--out F]  the full 4-section grounded explainer skeleton
#
# <ref> is a commit (SHA / HEAD / tag / branch) or a range (A..B). A commit diffs against its first
# parent; a merge uses first-parent; a root commit uses the empty tree.

set -uo pipefail

EMPTY_TREE=4b825dc642cb6eb9a060e54bf8d69288fbee4904

# _resolve <ref> -> prints "BASE\tHEAD" for git diff. Handles range, merge, root commit.
# Hard-fails on an unresolvable ref: without this, `set -uo pipefail` (no -e) would let a typo'd ref
# fall through to the empty-tree base and silently emit an empty "grounded" explainer (review finding).
_resolve() {
  local ref="$1" base head
  if [[ "$ref" == *..* ]]; then
    base="${ref%%..*}"; head="${ref##*..}"
    git rev-parse -q --verify "${base}^{commit}" >/dev/null 2>&1 || git rev-parse -q --verify "$base" >/dev/null 2>&1 || { echo "explain.sh: cannot resolve base ref '$base'" >&2; exit 3; }
    git rev-parse -q --verify "${head}^{commit}" >/dev/null 2>&1 || git rev-parse -q --verify "$head" >/dev/null 2>&1 || { echo "explain.sh: cannot resolve head ref '$head'" >&2; exit 3; }
    printf '%s\t%s\n' "$base" "$head"; return 0
  fi
  head="$ref"
  git rev-parse -q --verify "${head}^{commit}" >/dev/null 2>&1 || { echo "explain.sh: cannot resolve ref '$ref'" >&2; exit 3; }
  # first parent if it exists, else the empty tree (root commit)
  if git rev-parse -q --verify "${ref}^1" >/dev/null 2>&1; then
    base="${ref}^1"
  else
    base="$EMPTY_TREE"
  fi
  printf '%s\t%s\n' "$base" "$head"
}

# _rank <status> <path> -> 0..3 (see header). Precedence: background, then verification, then new, else integration.
# Globs are ANCHORED on the path segment / basename, not loose substrings, so `latest-value.js`
# or `aerospec.txt` do NOT misclassify as tests (review finding, SPEC-124 impl-notes).
_rank() {
  local status="$1" path="$2" lc bn
  lc="$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"
  bn="${lc##*/}"
  # rank 0: background (docs / specs / ADRs / decisions)
  if [[ "$lc" == docs/* || "$path" == *SPEC-* || "$lc" == *decisions/* || "$bn" == adr-* ]]; then
    echo 0; return
  fi
  # rank 3: verification (tests) -- anchored: a tests/ path segment, or a basename that is clearly a test.
  if [[ "$lc" == tests/* || "$lc" == */tests/* || "$lc" == */spec/* \
     || "$bn" == test-* || "$bn" == test_* || "$bn" == *_test.* || "$bn" == *.test.* || "$bn" == *.spec.* ]]; then
    echo 3; return
  fi
  # rank 1: newly-added concept
  if [[ "$status" == A* ]]; then echo 1; return; fi
  # rank 2: integration (modified / renamed / everything else)
  echo 2
}

# _namestatus <base> <head> -> normalized "STATUS\tPATH" lines (rename collapses to its new path).
_namestatus() {
  local base="$1" head="$2"
  git diff --name-status "$base" "$head" | while IFS=$'\t' read -r status a b; do
    if [[ "$status" == R* || "$status" == C* ]]; then
      printf '%s\t%s\n' "$status" "$b"      # renamed/copied: use the new path
    else
      printf '%s\t%s\n' "$status" "$a"
    fi
  done
}

# _change_shape <base> <head> -> a one-line goal DERIVED FROM THE DIFF (never the commit message):
# what files were added / modified / removed. This is the grounded answer to "what is this change FOR",
# and it cannot be fooled by a lying commit subject.
_change_shape() {
  local base="$1" head="$2" added="" modified="" removed=""
  while IFS=$'\t' read -r status path; do
    [ -z "$path" ] && continue
    case "$status" in
      A*) added="${added:+$added, }$path" ;;
      D*) removed="${removed:+$removed, }$path" ;;
      *)  modified="${modified:+$modified, }$path" ;;   # M / R / C / T
    esac
  done < <(_namestatus "$base" "$head")
  local parts=""
  [ -n "$added" ]    && parts="${parts:+$parts; }adds ${added}"
  [ -n "$modified" ] && parts="${parts:+$parts; }modifies ${modified}"
  [ -n "$removed" ]  && parts="${parts:+$parts; }removes ${removed}"
  echo "${parts:-no file changes}"
}

# order: emit changed files in reading order (stable within rank).
cmd_order() {
  local ref="$1" base head
  local _r; _r="$(_resolve "$ref")" || exit 3; IFS=$'\t' read -r base head <<<"$_r"
  # prefix each file with its rank + a sequence index, stable-sort, strip.
  local i=0
  _namestatus "$base" "$head" | while IFS=$'\t' read -r status path; do
    [ -z "$path" ] && continue
    printf '%s\t%06d\t%s\n' "$(_rank "$status" "$path")" "$i" "$path"
    i=$((i+1))
  done | sort -k1,1n -k2,2n | cut -f3-
}

# mermaid: a valid ```mermaid change-map. Buckets present in the change are chained (>=1 edge always).
cmd_mermaid() {
  local ref="$1" base head
  local _r; _r="$(_resolve "$ref")" || exit 3; IFS=$'\t' read -r base head <<<"$_r"

  # collect basenames per rank bucket
  local -a names=("Background (docs/specs)" "New (added)" "Integration (modified)" "Verification (tests)")
  local -a buckets=("" "" "" "")
  while IFS=$'\t' read -r status path; do
    [ -z "$path" ] && continue
    local r; r="$(_rank "$status" "$path")"
    local bn; bn="$(basename "$path")"
    bn="${bn//\"/\'}"   # a literal double-quote in a filename would break the quoted mermaid label
    if [ -z "${buckets[$r]}" ]; then buckets[$r]="$bn"; else buckets[$r]="${buckets[$r]}<br/>${bn}"; fi
  done < <(_namestatus "$base" "$head")

  echo '```mermaid'
  echo 'flowchart TD'
  # node ids for present buckets, in reading order
  local -a present_ids=() present_labels=()
  local r
  for r in 0 1 2 3; do
    if [ -n "${buckets[$r]}" ]; then
      present_ids+=("b$r")
      present_labels+=("${names[$r]}: ${buckets[$r]}")
    fi
  done
  # declare nodes
  local idx
  for idx in "${!present_ids[@]}"; do
    printf '  %s["%s"]\n' "${present_ids[$idx]}" "${present_labels[$idx]}"
  done
  # chain them (reading order). Guarantee >=1 edge even for a single bucket.
  if [ "${#present_ids[@]}" -le 1 ]; then
    printf '  reader(["reader"]) --> %s\n' "${present_ids[0]:-b2}"
    if [ "${#present_ids[@]}" -eq 0 ]; then printf '  b2["(no file changes)"]\n'; fi
  else
    for (( idx=0; idx<${#present_ids[@]}-1; idx++ )); do
      printf '  %s --> %s\n' "${present_ids[$idx]}" "${present_ids[$((idx+1))]}"
    done
  fi
  echo '```'
}

# tests: fold in the RECORDED test verdict from docs/verification/, never an invented one.
cmd_tests() {
  local ref="$1" base head repo_root vdir
  local _r; _r="$(_resolve "$ref")" || exit 3; IFS=$'\t' read -r base head <<<"$_r"
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  vdir="$repo_root/docs/verification"

  # locate a proof record for this change: a spec slug touched by the diff points at a proof dir.
  local slug proof=""
  slug="$(_namestatus "$base" "$head" | grep -oE 'SPEC-[0-9]+-[a-z0-9-]+' | head -1 | sed -E 's/^SPEC-[0-9]+-//')"
  if [ -n "$slug" ] && [ -d "$vdir/$slug" ]; then
    proof="$(ls "$vdir/$slug"/proof-of-done.md "$vdir/$slug"/runs/*.md 2>/dev/null | head -1)"
  fi
  # fallback: a proof file whose name matches the slug anywhere under docs/verification
  if [ -z "$proof" ] && [ -n "$slug" ]; then
    proof="$(find "$vdir" -type f -name '*.md' 2>/dev/null | grep -i "$slug" | head -1)"
  fi

  if [ -n "$proof" ] && [ -f "$proof" ]; then
    echo "Recorded test result (from ${proof#$repo_root/}):"
    # surface the recorded verdict lines only (grounded, not invented)
    grep -iE 'exit:|verdict|pass|fail|inconclusive|green|command:' "$proof" | head -8 | sed 's/^/  /'
  else
    echo "[no recorded test result for ${ref}]"
  fi
}

# render: the full 4-section grounded skeleton. Sections in reading order.
cmd_render() {
  local ref="$1"; shift
  local out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) out="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local base head subject shape
  local _r; _r="$(_resolve "$ref")" || exit 3; IFS=$'\t' read -r base head <<<"$_r"
  # The commit subject is the AUTHOR's narrative, NOT the diff. It is surfaced ONCE, explicitly
  # labeled UNVERIFIED, and NEVER used as the title or the goal -- else a lying message ("adds
  # multiply" over a diff that adds subtract) would teach the reader the wrong model (ADR-0031 §2,
  # the exact leak the review caught). The goal is DERIVED FROM THE DIFF via _change_shape.
  subject="$(git log -1 --format='%s' "$head" 2>/dev/null || echo "(no subject)")"
  shape="$(_change_shape "$base" "$head")"

  _render_body() {
    echo "# Explainer for \`${ref}\`"
    echo
    echo "> Literate-diff explainer (base \`${base}\`). Grounded in the ACTUAL diff + recorded test"
    echo "> results, NOT any agent/author narrative. Read top to bottom; the diff below is"
    echo "> in READING order, not git's alphabetical order. The commit message is shown as UNVERIFIED"
    echo "> metadata only; where it disagrees with the code, the code below is the source of truth."
    echo

    echo "## Background"
    echo
    echo "The context a reader needs before the change. Files that carry it (specs, ADRs, docs) come"
    echo "first in the reading order below. narrate-log supplies the prose arc; the grounded facts:"
    echo
    echo "- Files touched (reading order): $(cmd_order "$ref" | tr '\n' ' ')"
    echo "- Commit subject (UNVERIFIED author metadata, cross-check against the diff): ${subject}"
    echo

    echo "## Goal and intuition"
    echo
    echo "Concepts before code: what this change is FOR, read OFF THE DIFF (not the commit message)."
    echo "commands/explain.md enriches this via narrate-log, keeping every claim traceable to a hunk below."
    echo
    echo "- Goal (derived from the diff): ${shape}"
    echo

    echo "## The change, in reading order"
    echo
    echo "Each file in the order a human should read it (background -> new concept -> integration ->"
    echo "verification), with its actual hunk. This is a PROSE ordering; a raw \`git diff\` would list"
    echo "these alphabetically."
    echo
    local path
    while IFS= read -r path; do
      [ -z "$path" ] && continue
      echo "### ${path}"
      echo
      echo '```diff'
      git diff "$base" "$head" -- "$path"
      echo '```'
      echo
    done < <(cmd_order "$ref")

    echo "## Diagram"
    echo
    echo "The change map (mermaid, GitHub-native). commands/explain.md may replace this with a richer"
    echo "conceptual figure via svg-knowledge-diagram."
    echo
    cmd_mermaid "$ref"
    echo
    echo "### Recorded test result"
    echo
    cmd_tests "$ref"
  }

  if [ -n "$out" ]; then
    _render_body > "$out"
    echo "wrote $out"
  else
    _render_body
  fi
}

usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    order)   cmd_order "$@" ;;
    mermaid) cmd_mermaid "$@" ;;
    tests)   cmd_tests "$@" ;;
    render)  cmd_render "$@" ;;
    ""|-h|--help|help) usage ;;
    *) echo "explain.sh: unknown subcommand '$sub'" >&2; usage >&2; exit 2 ;;
  esac
}

main "$@"
