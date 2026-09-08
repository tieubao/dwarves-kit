#!/usr/bin/env bash
# board.sh -- the kit's cockpit board command (SPEC-146, runner-fastpath sub-goal 04;
# `mirror`/`status` added by SPEC-147, sub-goal 07; `writeback` added by SPEC-149, sub-goal 08).
#
# The SOLE cockpit board command: it ABSORBS the render logic that used to live in ops-toolkit's
# `_meta/board` (the `priority` quadrant awk, single-repo) and `_meta/board-all` (the `boards.txt`
# registry walk + `priority matrix` cross-repo pivot), ADDS a `queue` subcommand that emits an
# allow-listed overnight-runner queue, ADDS `mirror`/`status` (SPEC-147): a one-way git ->
# Hermes kanban bridge over opt-in repos + active mega-goals, native `hermes kanban` CLI only, and
# ADDS `writeback` (SPEC-149): the reverse leg -- a Hermes-side card status move flows back into a
# repo's BACKLOG.md as a reviewable, HELD `chore/board-sync` PR (never auto-merged), gated by the
# mirror snapshot's row_hash conflict rule (git wins, always). Base kanban render
# (board/next/set/states) is UNCHANGED and still delegates to `lib/board/backlog.sh` -- this file never
# reimplements it. The substantial `mirror`/`status` logic (extract/diff/plan/apply) lives in
# `lib/board/board-mirror.sh`; the substantial `writeback` logic (diff/apply/PR) lives in
# `lib/board/board-writeback.sh` (which itself reuses `lib/board/board-mirror.sh`'s extract/hash machinery) --
# the same delegation shape `queue` already has with `lib/board/parse-board.sh`.
#
# The kit itself carries NO personal data: the consumer registry (`boards.txt`), the repo it
# describes, and any future bridge opt-ins are CONSUMER config this tool reads at runtime via
# `--repo-root <path>` / the `REPO_ROOT` env var (the kit's existing consumer pattern -- see
# lib/learn/weekend-batch.sh's `_repo_root()` / `--repo-root`, lib/goal/mega-merge.sh's env-override
# precedent). Never invents a `CONSUMER_ROOT` var.
#
# Usage:
#   board.sh board  [--backlog-file <path>]                    single-repo kanban render
#   board.sh next   [--backlog-file <path>]                    first queued ID
#   board.sh set <ID> <state> [note] [--backlog-file <path>]   flip a row's state
#   board.sh states [--backlog-file <path>]                    legal state names
#   board.sh priority [counts|brief|overview|full] [--backlog-file <path>]
#                                                               single-repo urgency x fit quadrant
#   board.sh promote [<n>... | all | reject <n>...]             review + flush backlog-stage's
#                                                               staged candidates onto the board
#                                                               (the human gate; absorbed the
#                                                               retired `add-backlog` entry per
#                                                               ADR-0034 decision 7, no alias).
#                                                               Forwards to lib/board/bin/add-backlog
#                                                               verbatim, behavior unchanged.
#
#   board.sh all board|next|states [--repo-root <path>] [--registry <path>]
#                                                               cross-repo render, grouped by repo
#   board.sh all priority [counts|brief|overview|full] [--repo-root <path>] [--registry <path>]
#                                                               each repo's quadrant, grouped by repo
#   board.sh all priority matrix [--repo-root <path>] [--registry <path>]
#                                                               cross-repo urgency x repo pivot table
#
#   board.sh queue [--dry-run] [--repo-root <path>] [--registry <path>]
#                                                               walk the registry, parse every
#                                                               repo's BACKLOG.md via
#                                                               lib/board/parse-board.sh, emit
#                                                               slug<TAB>repo-path<TAB>pointer-path
#                                                               for every allow-listed `#queue{}`
#                                                               token on a `queued` row. `slug` is
#                                                               `<repo-name>__<ID>` (globally
#                                                               unique even though ID-NNN prefixes
#                                                               collide across some repos, see
#                                                               CLAUDE.md's dwarves-kit/ops-toolkit
#                                                               ID- note). `--dry-run` is accepted
#                                                               for forward-compat with a future
#                                                               write-capable extension; `queue`
#                                                               itself never mutates any BACKLOG.md
#                                                               regardless of the flag, so it is
#                                                               currently a documented no-op.
#
#   board.sh mirror [--dry-run] [--repo-root <path>] [--registry <path>] [--snapshot <path>]
#                    [--mega-board <name>] [--board-prefix <prefix>]
#                    [--remote <user@host>] [--remote-kit-path <path>] [--engine legacy|sync]
#                                                               `--engine sync` (ID-290, the
#                                                               SPEC-002 P2 cockpit channel) routes
#                                                               the deterministic extract+diff
#                                                               through lib/sync/cockpit.py; today
#                                                               it is dry-run-only (the plan), the
#                                                               live LOAD + writeback stay on the
#                                                               legacy engine (the default).
#                                                               project opt-in (`bridge=on`)
#                                                               cockpit boards + one card per
#                                                               ACTIVE mega-goal onto a Hermes
#                                                               kanban, idempotently. `--dry-run`
#                                                               prints the plan and applies
#                                                               nothing (no Hermes calls, no
#                                                               snapshot write). `--remote` ships
#                                                               the plan over ONE `ssh` call to a
#                                                               remote host's own board-mirror.sh
#                                                               apply-plan (argv vectors, never a
#                                                               templated shell string); default
#                                                               is local (`$HERMES_BIN`/`hermes`
#                                                               runs on this host). See
#                                                               `lib/board/board-mirror.sh` for the full
#                                                               ETL design + state-mapping table.
#   board.sh status [--repo-root <path>] [--registry <path>] [--snapshot <path>]
#                                                               mirror staleness: per opted-in
#                                                               repo, the snapshot's newest
#                                                               `seen_at` vs the BACKLOG.md's own
#                                                               last git-log touch time.
#
#   board.sh board  --with-mega [--mega-code-root <path>] [--backlog-file <path>]
#   board.sh status --with-mega [--mega-code-root <path>] [--repo-root <path>] [--registry <path>]
#                                                               OPT-IN (kit-modularity sub-goal
#                                                               08): appends a trailing
#                                                               "MEGA ROLLUP" section listing, for
#                                                               every ACTIVE mega under
#                                                               <repo-root>/_meta/megagoals/*/
#                                                               (>=1 unchecked sub-goal box), the
#                                                               `lib/mega/mega.sh status <slug>
#                                                               --rollup-only` line (roadmap-vs-git
#                                                               reconciliation, drift-flagged --
#                                                               never a re-render of the roadmap's
#                                                               own `[x]`/`[ ]` prose). DEFAULT OFF
#                                                               on both `board` and `status`: it
#                                                               makes real `gh` calls per
#                                                               sub-goal, so it must never run
#                                                               inside the byte-identical render
#                                                               non-regression NC (test-board.sh's
#                                                               NC-e) or slow down a plain render.
#                                                               `--mega-code-root <path>` overrides
#                                                               where the megas' OWN branches/PRs
#                                                               live (default: the same repo
#                                                               `--backlog-file`/`--repo-root`
#                                                               resolves to -- override it when a
#                                                               mega's ROADMAP.md lives in one repo
#                                                               but its sub-goals build in a
#                                                               DIFFERENT one, e.g. kit-modularity:
#                                                               ROADMAP in ops-toolkit, PRs/
#                                                               branches in dwarves-kit).
#
#   board.sh writeback [--dry-run] [--repo-root <path>] [--registry <path>] [--snapshot <path>]
#                       [--board-prefix <prefix>] [--branch <name>] [--pr-base <branch>]
#                                                               the reverse leg (SPEC-149): reads
#                                                               each opted-in repo's live Hermes
#                                                               board (`hermes kanban --board <b>
#                                                               list --json`) + the SPEC-147 mirror
#                                                               snapshot, builds a changeset of
#                                                               rows whose Hermes status moved,
#                                                               validates (opted-in repo, legal
#                                                               backlog.sh state, row_hash still
#                                                               matches the snapshot -- git wins on
#                                                               any mismatch), and applies matched
#                                                               rows' Status column via a fresh
#                                                               `chore/board-sync` branch (built in
#                                                               an isolated `git worktree`, never
#                                                               this repo's own checkout) + one
#                                                               attributed commit (`actor=hermes`)
#                                                               + `gh pr create` -- HELD, never
#                                                               auto-merged. `--dry-run` prints the
#                                                               changeset and applies nothing (no
#                                                               git branch/commit/push, no PR, no
#                                                               snapshot refresh; it STILL reads
#                                                               Hermes, since that read is exactly
#                                                               what a dry-run previews). Missing
#                                                               or corrupt `--snapshot` REFUSES ALL
#                                                               edits (explicit error, nonzero
#                                                               exit) rather than silently applying
#                                                               everything. See `lib/board/board-writeback.sh`
#                                                               for the full design (reverse state
#                                                               mapping, conflict rule, snapshot
#                                                               refresh semantics).
#
# Registry format (`boards.txt`): whitespace-delimited `<name> <path-to-BACKLOG.md> [bridge]`
# rows, `#` comments, `~` expands to $HOME. A THIRD field, `bridge`, opts a repo into `mirror`:
# exactly the literal token `on` opts in; absent, `off`, or any other value stays OUT (default
# OFF -- a repo must explicitly opt in; sensitive repos like `trading`/`family-office` must never
# be `on`). `board`/`next`/`priority`/`states`/`queue` never read this field (they only ever
# consumed the first two columns, per SPEC-146's own forward-compat design), so adding it is a
# zero-code-change, non-regressing registry format extension.
#
# --repo-root resolution precedence (cross-repo `all`/`queue`/`mirror`/`status` modes only): the
# `--repo-root` flag, else the `REPO_ROOT` env var, else `git rev-parse --show-toplevel` of the
# CURRENT cwd, else cwd itself. The single-repo subcommands never need --repo-root; the shim that
# calls them always passes an explicit --backlog-file instead.
#
# DWARVES_KIT overrides where lib/board/backlog.sh + lib/board/parse-board.sh + lib/board/board-mirror.sh are found
# relative to this file (they are always siblings in lib/, so this only matters if board.sh is
# copied standalone).

set -euo pipefail

BOARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKLOG_SH="$BOARD_DIR/backlog.sh"
PARSE_BOARD_SH="$BOARD_DIR/parse-board.sh"
BOARD_MIRROR_SH="$BOARD_DIR/board-mirror.sh"
BOARD_WRITEBACK_SH="$BOARD_DIR/board-writeback.sh"
COCKPIT_PY="$(cd "$BOARD_DIR/.." && pwd)/sync/cockpit.py"  # lib/sync/, the P2 sync-engine port (ID-290)
MEGA_SH="$(cd "$BOARD_DIR/.." && pwd)/mega/mega.sh"  # lib/mega/mega.sh, one level up from lib/board/

[ -f "$BACKLOG_SH" ]         || { echo "board: lib/board/backlog.sh not found at $BACKLOG_SH" >&2; exit 1; }
[ -f "$PARSE_BOARD_SH" ]     || { echo "board: lib/board/parse-board.sh not found at $PARSE_BOARD_SH" >&2; exit 1; }
[ -f "$BOARD_MIRROR_SH" ]    || { echo "board: lib/board/board-mirror.sh not found at $BOARD_MIRROR_SH" >&2; exit 1; }
[ -f "$BOARD_WRITEBACK_SH" ] || { echo "board: lib/board/board-writeback.sh not found at $BOARD_WRITEBACK_SH" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Flag parsing (shared): extracts --backlog-file / --repo-root / --registry / --dry-run plus the
# mirror-only flags (--snapshot / --mega-board / --board-prefix / --remote / --remote-kit-path)
# from anywhere in argv, leaving the rest in POSITIONAL in order. Re-callable per subcommand (each
# resets its own OPT_* vars first). The mirror-only flags are harmless no-ops for every OTHER
# subcommand (board/next/set/states/priority/all/queue never read them), so folding them into the
# one shared parser costs nothing and keeps a single flag-parsing surface (SPEC-146's own design).
# ---------------------------------------------------------------------------
OPT_BACKLOG_FILE=""; OPT_REPO_ROOT=""; OPT_REGISTRY=""; OPT_DRY_RUN=0
OPT_SNAPSHOT=""; OPT_MEGA_BOARD=""; OPT_BOARD_PREFIX=""; OPT_REMOTE=""; OPT_REMOTE_KIT_PATH=""
OPT_BRANCH=""; OPT_PR_BASE=""; OPT_WITH_MEGA=0; OPT_MEGA_CODE_ROOT=""
POSITIONAL=()
_parse_flags() {
  OPT_BACKLOG_FILE=""; OPT_REPO_ROOT=""; OPT_REGISTRY=""; OPT_DRY_RUN=0
  OPT_SNAPSHOT=""; OPT_MEGA_BOARD=""; OPT_BOARD_PREFIX=""; OPT_REMOTE=""; OPT_REMOTE_KIT_PATH=""
  OPT_BRANCH=""; OPT_PR_BASE=""; OPT_WITH_MEGA=0; OPT_MEGA_CODE_ROOT=""
  OPT_ENGINE="legacy"
  POSITIONAL=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --backlog-file)    OPT_BACKLOG_FILE="${2:-}"; shift 2 ;;
      --engine)          OPT_ENGINE="${2:-}"; shift 2 ;;
      --repo-root)       OPT_REPO_ROOT="${2:-}"; shift 2 ;;
      --registry)        OPT_REGISTRY="${2:-}"; shift 2 ;;
      --dry-run)         OPT_DRY_RUN=1; shift ;;
      --snapshot)        OPT_SNAPSHOT="${2:-}"; shift 2 ;;
      --mega-board)      OPT_MEGA_BOARD="${2:-}"; shift 2 ;;
      --board-prefix)    OPT_BOARD_PREFIX="${2:-}"; shift 2 ;;
      --remote)          OPT_REMOTE="${2:-}"; shift 2 ;;
      --remote-kit-path) OPT_REMOTE_KIT_PATH="${2:-}"; shift 2 ;;
      --branch)          OPT_BRANCH="${2:-}"; shift 2 ;;
      --pr-base)         OPT_PR_BASE="${2:-}"; shift 2 ;;
      --with-mega)       OPT_WITH_MEGA=1; shift ;;
      --mega-code-root)  OPT_MEGA_CODE_ROOT="${2:-}"; shift 2 ;;
      *) POSITIONAL+=("$1"); shift ;;
    esac
  done
}

# _mega_rollups <repo-root> <code-root> -- one `mega status <slug> --rollup-only` line per
# ACTIVE mega under <repo-root>/_meta/megagoals/*/ROADMAP.md (>=1 unchecked sub-goal box, same
# activeness convention lib/board/board-mirror.sh's own extract_megas already uses). Silent no-op
# (empty output) when there is no megagoals dir, no mega.sh, or a mega's status call errors --
# this is an OPT-IN surfacing feature (--with-mega), never a hard requirement of board render.
_mega_rollups() {  # <repo-root> <code-root>
  local repo_root="$1" code_root="$2" mg_root dir slug rf out
  mg_root="$repo_root/_meta/megagoals"
  [ -d "$mg_root" ] || return 0
  [ -f "$MEGA_SH" ] || return 0
  for dir in "$mg_root"/*/; do
    [ -d "$dir" ] || continue
    slug="$(basename "$dir")"
    rf="$dir/ROADMAP.md"
    [ -f "$rf" ] || continue
    grep -qE '^- \[ \]' "$rf" 2>/dev/null || continue   # skip fully-shipped / non-checkbox megas
    out="$(bash "$MEGA_SH" status "$slug" --megagoals-root "$mg_root" --code-root "$code_root" --rollup-only 2>/dev/null)" || true
    [ -n "$out" ] && printf '  %s\n' "$out"
  done
}

_default_repo_root() { git rev-parse --show-toplevel 2>/dev/null || pwd; }

_resolve_repo_root() {
  if [ -n "$OPT_REPO_ROOT" ]; then printf '%s\n' "$OPT_REPO_ROOT"; return; fi
  if [ -n "${REPO_ROOT:-}" ]; then printf '%s\n' "$REPO_ROOT"; return; fi
  _default_repo_root
}

# _repo_root_for <path-to-backlog-md> -- the git top-level containing that file, else its dir.
_repo_root_for() {
  local dir; dir="$(cd "$(dirname "$1")" && pwd)"
  git -C "$dir" rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "$dir"
}

# _iso_to_utc_z <ISO8601-with-offset> -- normalizes `git log --format=%cI`'s local-offset
# timestamp ("2026-07-05T04:42:21+07:00") to a UTC "Z" timestamp, so `status`'s string
# comparison against the snapshot's own UTC `seen_at` values is an apples-to-apples same-instant
# check, not a same-INSTANT-but-different-clock-face false positive. BSD `date -j -f '...%z'`
# (macOS) requires the offset WITHOUT a colon ("+0700"); git's ISO8601 format always has one, so
# it is stripped before parsing (verified empirically: BSD date rejects "+07:00" outright and,
# with `set -e` off, silently falls through, which is exactly the false-positive this function
# exists to prevent). GNU `date -d` (Linux/CI) accepts the colon form natively and is tried as a
# second path. If BOTH conversions fail, the original string is returned unmodified rather than
# aborting `status` (an honestly-imprecise staleness read beats no read at all).
_iso_to_utc_z() {
  local raw="$1" nocolon
  nocolon="$(printf '%s' "$raw" | sed -E 's/([+-][0-9]{2}):([0-9]{2})$/\1\2/')"
  date -u -j -f '%Y-%m-%dT%H:%M:%S%z' "$nocolon" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "$raw" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || printf '%s\n' "$raw"
}

# ---------------------------------------------------------------------------
# Priority render (single repo) -- verbatim port of the awk program from ops-toolkit's
# `_meta/board` `priority` branch. Byte-identical output is the load-bearing non-regression
# contract (SPEC-146 proof-of-done); do not "clean up" this awk without re-running that proof.
# ---------------------------------------------------------------------------
_priority_render() {  # <backlog-file> <mode>
  local file="$1" mode="${2:-overview}"
  case "$mode" in counts|brief|overview|full) ;; *) mode="overview" ;; esac
  awk -F'|' -v mode="$mode" '
    function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
    function shorten(t){ if(length(t)>52) return substr(t,1,49)"..."; return t }
    $0 ~ /^\| *[A-Z]+-[0-9]+ *\|/ {
      id=trim($2); title=shorten(trim($3)); status=trim($(NF-1)); line=$0
      split(status,a,/[ \[(]/); lead=a[1]
      if (lead=="executing"||lead=="claimed"||lead=="speccing"||lead=="validated"){
        inflight[++nf]=sprintf("  %-8s %s  [%s]", id, title, lead); next }
      if (lead!="queued") next
      u=(line~/#u-hi/)?"hi":(line~/#u-mid/)?"mid":(line~/#u-lo/)?"lo":"?"
      f=(line~/#f-hi/)?"hi":(line~/#f-mid/)?"mid":(line~/#f-lo/)?"lo":"?"
      stripped=line; gsub(/#[uf]-(hi|mid|lo)/,"",stripped)
      wt=""; if(match(stripped,/#[a-z][a-z0-9-]*/)) wt="  "substr(stripped,RSTART,RLENGTH)
      dl=""; if(tolower(line)~/deadline/) dl="  [deadline]"
      row=sprintf("  %-8s %s%s%s", id, title, wt, dl)
      if(u=="hi"&&f=="hi") t1[++n1]=row
      else if(u=="hi")     t2[++n2]=row
      else if(f=="hi")     t3[++n3]=row
      else                 t4[++n4]=row
      if(u=="?"||f=="?") unclass++
    }
    END{
      C=(mode=="counts"); B=(mode=="brief"); F=(mode=="full")
      if(nf>0){ printf "IN FLIGHT        %d\n", nf; if(!C){ for(i=1;i<=nf;i++) print inflight[i]; print "" } }
      printf "DO NOW           (u-hi  f-hi)         %d\n", n1+0; if(!C) for(i=1;i<=n1;i++) print t1[i]
      printf "URGENT, HARDER   (u-hi  f-mid|lo)     %d\n", n2+0; if(!C) for(i=1;i<=n2;i++) print t2[i]
      printf "QUICK WINS       (u-lo|mid  f-hi)     %d\n", n3+0; if(!C&&!B) for(i=1;i<=n3;i++) print t3[i]
      printf "THE REST         (other queued)       %d\n", n4+0
      if(!C&&!B){ cap=(F?0:15); lim=(cap>0&&n4>cap)?cap:n4
        for(i=1;i<=lim;i++) print t4[i]
        if(cap>0&&n4>cap) printf "  +%d more  (board priority full)\n", n4-cap }
      if(unclass>0&&!C) printf "\n(%d queued row(s) missing #u/#f -- classify them)\n", unclass
    }
  ' "$file"
}

# ---------------------------------------------------------------------------
# Priority matrix (cross-repo) -- verbatim port of `_meta/board-all`'s `priority matrix` branch.
# ---------------------------------------------------------------------------
_priority_matrix() {  # <registry-file>
  local registry="$1"
  {
    while read -r name path _rest; do
      [ -z "${name:-}" ] && continue
      case "$name" in \#*) continue ;; esac
      path="${path/#\~/$HOME}"
      [ -f "$path" ] || continue
      awk -F'|' -v repo="$name" '
        function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
        function letter(x){ return (x=="hi")?"h":(x=="mid")?"m":(x=="lo")?"l":"?" }
        $0 ~ /^\| *[A-Z]+-[0-9]+ *\|/ {
          id=trim($2); title=trim($3); status=trim($(NF-1)); line=$0
          split(status,a,/[ \[(]/); lead=a[1]
          if(lead=="executing"||lead=="claimed"||lead=="speccing"||lead=="validated"){ exec++; next }
          if(lead!="queued") next
          u=(line~/#u-hi/)?"hi":(line~/#u-mid/)?"mid":(line~/#u-lo/)?"lo":"?"
          f=(line~/#f-hi/)?"hi":(line~/#f-mid/)?"mid":(line~/#f-lo/)?"lo":"?"
          if(u=="hi") hi++; else if(u=="mid") mid++; else if(u=="lo") lo++; else unt++
          if(u!="?") printf "I\t%s\t%s\t%s\t[%s/%s]\t%s\n", repo, u, id, letter(u), letter(f), title
        }
        END{ printf "C\t%s\t%d\t%d\t%d\t%d\t%d\n", repo, hi+0,mid+0,lo+0,unt+0,exec+0 }
      ' "$path"
    done < "$registry"
  } | awk -F'\t' '
    $1=="C" { repo[++nr]=$2; H[$2]=$3; M[$2]=$4; L[$2]=$5; U[$2]=$6; X[$2]=$7
              tH+=$3; tM+=$4; tL+=$5; tU+=$6; tX+=$7
              if(length($2)>w) w=length($2)
              if($3+$4+$5+$6+$7>0) shown[$2]=1 ; next }
    $1=="I" { key=$2 SUBSEP $3; items[key]=items[key] sprintf("  %-8s %s  %s\n",$4,$5,$6) }
    END {
      if(w<6) w=6
      # --- matrix table ---
      printf "Priority matrix (queued rows, all repos) -- urgency x repo\n\n"
      printf "%-*s  %6s %6s %6s %9s %10s\n", w,"repo","HIGH u","MID u","LOW u","untagged","executing"
      for(i=1;i<=nr;i++){ r=repo[i]; if(!shown[r]) continue
        printf "%-*s  %6d %6d %6d %9d %10d\n", w,r,H[r],M[r],L[r],U[r],X[r] }
      printf "%-*s  %6d %6d %6d %9d %10d\n", w,"total queued",tH,tM,tL,tU,tX
      printf "\nLegend: [u/f] = urgency / fit. h=high, m=mid, l=low.\n"
      # --- lists by urgency tier ---
      split("hi mid lo",order," "); split("HIGH MID LOW",label," ")
      for(o=1;o<=3;o++){ tier=order[o]
        # tier total
        tot=0; for(i=1;i<=nr;i++){ r=repo[i]; tot += (tier=="hi"?H[r]:tier=="mid"?M[r]:L[r]) }
        printf "\n--\n%s urgency (%d rows)\n", label[o], tot
        for(i=1;i<=nr;i++){ r=repo[i]; key=r SUBSEP tier
          if(items[key]!=""){ printf "\n%s\n%s", r, items[key] } }
      }
    }
  '
}

# ---------------------------------------------------------------------------
# Single-repo dispatch (mirrors ops-toolkit's old `_meta/board`).
# ---------------------------------------------------------------------------
cmd_board_single() {
  _parse_flags "$@"
  local args=("${POSITIONAL[@]}")
  [ ${#args[@]} -gt 0 ] || args=(board)
  [ -n "$OPT_BACKLOG_FILE" ] || { echo "board: --backlog-file is required for single-repo commands" >&2; return 64; }
  [ -f "$OPT_BACKLOG_FILE" ] || { echo "board: no BACKLOG.md at $OPT_BACKLOG_FILE" >&2; return 1; }

  if [ "${args[0]}" = "priority" ]; then
    _priority_render "$OPT_BACKLOG_FILE" "${args[1]:-overview}"
    return 0
  fi
  local rc
  if BACKLOG_FILE="$OPT_BACKLOG_FILE" bash "$BACKLOG_SH" "${args[@]}"; then rc=0; else rc=$?; fi
  # --with-mega is OPT-IN and only fires for the default `board` render (never `next`/`set`/
  # `states`), so the byte-identical render non-regression NC (test-board.sh's NC-e, which never
  # passes --with-mega) is untouched by construction.
  if [ "$OPT_WITH_MEGA" -eq 1 ] && [ "${args[0]}" = "board" ]; then
    local repo_root; repo_root="$(_repo_root_for "$OPT_BACKLOG_FILE")"
    local code_root="${OPT_MEGA_CODE_ROOT:-$repo_root}"
    local rollups; rollups="$(_mega_rollups "$repo_root" "$code_root")"
    [ -n "$rollups" ] && printf '\nMEGA ROLLUP:\n%s\n' "$rollups"
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# Cross-repo dispatch (mirrors ops-toolkit's old `_meta/board-all`).
# ---------------------------------------------------------------------------
cmd_all() {
  _parse_flags "$@"
  local args=("${POSITIONAL[@]}")
  local repo_root; repo_root="$(_resolve_repo_root)"
  local registry="${OPT_REGISTRY:-$repo_root/_meta/boards.txt}"
  [ -f "$registry" ] || { echo "board all: no registry at $registry" >&2; return 1; }

  local sub="${args[0]:-board}"
  local mode="${args[1]:-overview}"

  if [ "$sub" = "priority" ] && [ "$mode" = "matrix" ]; then
    _priority_matrix "$registry"
    return 0
  fi

  if [ "$sub" = "priority" ]; then
    while read -r name path _rest; do
      [ -z "${name:-}" ] && continue
      case "$name" in \#*) continue ;; esac
      path="${path/#\~/$HOME}"
      if [ ! -f "$path" ]; then
        printf '\n=== %s ===\n(MISSING: %s)\n' "$name" "$path"
        continue
      fi
      local out; out="$(_priority_render "$path" "$mode" 2>&1 || true)"
      printf '\n=== %s ===\n%s\n' "$name" "$out"
    done < "$registry"
    return 0
  fi

  while read -r name path _rest; do
    [ -z "${name:-}" ] && continue
    case "$name" in \#*) continue ;; esac
    path="${path/#\~/$HOME}"
    if [ ! -f "$path" ]; then
      printf '\n=== %s ===\n(MISSING: %s)\n' "$name" "$path"
      continue
    fi
    local out; out="$(BACKLOG_FILE="$path" bash "$BACKLOG_SH" "$sub" 2>&1 || true)"
    if [ "$sub" = "next" ]; then
      printf '%-14s %s\n' "$name" "$out"
    else
      printf '\n=== %s ===\n%s\n' "$name" "$out"
    fi
  done < "$registry"
}

# ---------------------------------------------------------------------------
# queue -- the new overnight-runner feed (SPEC-146). Never mutates any BACKLOG.md.
# ---------------------------------------------------------------------------
cmd_queue() {
  _parse_flags "$@"
  local repo_root; repo_root="$(_resolve_repo_root)"
  local registry="${OPT_REGISTRY:-$repo_root/_meta/boards.txt}"
  [ -f "$registry" ] || { echo "queue: no registry at $registry" >&2; return 1; }

  # `queue` is read-only by construction (it never writes to any BACKLOG.md, unlike `set`), so
  # --dry-run has no additional effect today; it is accepted now as forward-compat surface for a
  # future write-capable extension (e.g. flipping a picked row to `claimed`), documented rather
  # than silently ignored.
  if [ "$OPT_DRY_RUN" -eq 1 ]; then
    echo "queue: --dry-run has no additional effect (queue never mutates any BACKLOG.md)" >&2
  fi

  local total=0
  while read -r name path _rest; do
    [ -z "${name:-}" ] && continue
    case "$name" in \#*) continue ;; esac
    path="${path/#\~/$HOME}"
    if [ ! -f "$path" ]; then
      echo "queue: skip repo '$name': registered BACKLOG.md missing at $path" >&2
      continue
    fi
    local rroot; rroot="$(_repo_root_for "$path")"
    while IFS=$'\t' read -r id rr resolved; do
      [ -n "$id" ] || continue
      printf '%s\t%s\t%s\n' "${name}__${id}" "$rr" "$resolved"
      total=$((total+1))
    done < <(bash "$PARSE_BOARD_SH" queue-rows "$path" "$name" "$rroot")
  done < "$registry"

  echo "queue: ${total} rows" >&2
  return 0
}

# ---------------------------------------------------------------------------
# mirror -- git<->Hermes kanban bridge, read-mirror leg (SPEC-147, runner-fastpath sub-goal 07).
# Delegates ALL substantial logic (extract/diff/plan/apply) to lib/board/board-mirror.sh, exactly the
# way `queue` above delegates parsing to lib/board/parse-board.sh; this function is the thin,
# human-facing wrapper: resolve config, get a plan, apply it (locally or over one `ssh` call),
# persist the snapshot incrementally as results stream back, print a summary. Never mutates any
# BACKLOG.md (mirror is one-way: git -> Hermes; SG-08 owns the reverse leg).
# ---------------------------------------------------------------------------
cmd_mirror() {
  _parse_flags "$@"
  local repo_root; repo_root="$(_resolve_repo_root)"
  local registry="${OPT_REGISTRY:-$repo_root/_meta/boards.txt}"
  local snapshot="${OPT_SNAPSHOT:-$repo_root/_meta/.board-mirror-snapshot.jsonl}"

  # SPEC-002 P2 port (ID-290): the sync-engine cockpit channel. Opt-in via
  # `--engine sync`; today it re-lands the DETERMINISTIC legs (multi-source
  # extract + the keyed row_hash-git-wins diff) as a dry-run plan. The live
  # LOAD leg (applying to a Hermes kanban) and two-way writeback stay on the
  # legacy engine below until the next slice, so a bare `--engine sync` without
  # --dry-run is refused rather than silently doing nothing.
  case "$OPT_ENGINE" in
    legacy|sync) : ;;
    *) echo "mirror: unknown --engine '$OPT_ENGINE' (expected legacy|sync)" >&2; return 64 ;;
  esac
  if [ "$OPT_ENGINE" = "sync" ]; then
    [ -f "$registry" ] || { echo "mirror: no registry at $registry" >&2; return 1; }
    if [ "$OPT_DRY_RUN" -ne 1 ]; then
      echo "mirror --engine sync: apply not yet ported; run with --dry-run for" \
           "the plan, or use the legacy engine (default) to apply." >&2
      return 64
    fi
    # --snapshot always passed (cockpit.py treats a missing file as empty prior
    # state), mirroring the legacy branch below for a symmetric read.
    local plan_args=(plan --registry "$registry" --snapshot "$snapshot")
    [ -n "$OPT_MEGA_BOARD" ]   && plan_args+=(--mega-board "$OPT_MEGA_BOARD")
    [ -n "$OPT_BOARD_PREFIX" ] && plan_args+=(--board-prefix "$OPT_BOARD_PREFIX")
    exec python3 "$COCKPIT_PY" "${plan_args[@]}"
  fi

  _legacy_bridge_note
  [ -f "$registry" ] || { echo "mirror: no registry at $registry" >&2; return 1; }

  local plan_args=(plan --registry "$registry" --snapshot "$snapshot")
  [ -n "$OPT_MEGA_BOARD" ]   && plan_args+=(--mega-board "$OPT_MEGA_BOARD")
  [ -n "$OPT_BOARD_PREFIX" ] && plan_args+=(--board-prefix "$OPT_BOARD_PREFIX")

  local plan; plan="$(mktemp "${TMPDIR:-/tmp}/board-mirror-plan.XXXXXX")"
  bash "$BOARD_MIRROR_SH" "${plan_args[@]}" > "$plan"

  if [ "$OPT_DRY_RUN" -eq 1 ]; then
    cat "$plan"
    rm -f "$plan"
    return 0
  fi

  if [ ! -s "$plan" ]; then
    echo "mirror: 0 changes" >&2
    rm -f "$plan"
    return 0
  fi

  local results
  if [ -n "$OPT_REMOTE" ]; then
    # ONE ssh call: the remote host execs its OWN copy of board-mirror.sh's apply-plan (argv
    # vectors decoded from the piped plan JSON, never a templated shell string -- card text stays
    # opaque data end to end). The remote host is expected to already have a dwarves-kit checkout
    # reachable at --remote-kit-path (default matches the existing DWARVES_KIT convention used by
    # ops-toolkit's own board-all shim); provisioning that checkout is a separate, later step.
    local remote_kit="${OPT_REMOTE_KIT_PATH:-\$HOME/.claude/dwarves-kit}"
    # shellcheck disable=SC2029  # intentional: ${remote_kit} expands client-side (it names the
    # remote path as a local variable); the remote command itself has no other variables to expand.
    results="$(ssh "$OPT_REMOTE" "bash ${remote_kit}/lib/board/board-mirror.sh apply-plan" < "$plan")"
  else
    results="$(bash "$BOARD_MIRROR_SH" apply-plan < "$plan")"
  fi
  rm -f "$plan"

  local created=0 changed=0 completed=0 errors=0
  local rline op origin hermes_id hermes_status status err
  while IFS= read -r rline; do
    [ -n "$rline" ] || continue
    status="$(printf '%s' "$rline" | jq -r '.status')"
    origin="$(printf '%s' "$rline" | jq -r '.origin')"
    op="$(printf '%s' "$rline" | jq -r '.op')"
    if [ "$status" != "ok" ]; then
      errors=$((errors+1))
      err="$(printf '%s' "$rline" | jq -r '.error // empty')"
      echo "mirror: ERROR $origin ($op): $err" >&2
      continue
    fi
    case "$op" in
      create)   created=$((created+1)) ;;
      change)   changed=$((changed+1)) ;;
      complete) completed=$((completed+1)) ;;
    esac
    hermes_id="$(printf '%s' "$rline" | jq -r '.hermes_id')"
    hermes_status="$(printf '%s' "$rline" | jq -r '.hermes_status')"
    echo "mirror: ${op} ${origin} -> ${hermes_id} (${hermes_status})" >&2
    # Persisted PER LINE, as results arrive (a mid-sync crash never loses a completed row).
    printf '%s' "$rline" | bash "$BOARD_MIRROR_SH" snapshot-upsert "$snapshot"
  done <<< "$results"

  echo "mirror: applied ${created} create, ${changed} change, ${completed} complete, ${errors} error(s)" >&2
  [ "$errors" -eq 0 ]
}

# ---------------------------------------------------------------------------
# status -- mirror staleness report (SPEC-147). Compares the snapshot's newest `seen_at` per
# opted-in repo against that repo's BACKLOG.md's own last git-log touch time; never touches
# Hermes or the snapshot file (read-only).
# ---------------------------------------------------------------------------
cmd_status() {
  _legacy_bridge_note
  _parse_flags "$@"
  local repo_root; repo_root="$(_resolve_repo_root)"
  local registry="${OPT_REGISTRY:-$repo_root/_meta/boards.txt}"
  local snapshot="${OPT_SNAPSHOT:-$repo_root/_meta/.board-mirror-snapshot.jsonl}"
  [ -f "$registry" ] || { echo "status: no registry at $registry" >&2; return 1; }

  local snap_tsv; snap_tsv="$(mktemp "${TMPDIR:-/tmp}/board-mirror-status.XXXXXX")"
  bash "$BOARD_MIRROR_SH" snapshot-read "$snapshot" > "$snap_tsv"

  local name path bridge rroot last_mirror last_touch changed=0 total_bridged=0 newest=""
  while read -r name path bridge _rest; do  # _rest: a 4th column (rail=) must not slurp into bridge (ops ID-633)
    [ -n "${name:-}" ] || continue
    case "$name" in \#*) continue ;; esac
    [ "${bridge:-}" = "on" ] || continue
    total_bridged=$((total_bridged+1))
    path="${path/#\~/$HOME}"
    if [ ! -f "$path" ]; then
      echo "status: ${name}: never mirrored (BACKLOG.md missing at $path)" >&2
      changed=$((changed+1))
      continue
    fi
    rroot="$(_repo_root_for "$path")"
    # Match by ORIGIN prefix ("<repo>:"), not by recorded board name: the board name can carry a
    # --board-prefix the registry's repo name never does, so origin is the robust join key.
    last_mirror="$(awk -F'\t' -v r="${name}:" 'index($1, r)==1{print $6}' "$snap_tsv" | sort | tail -n1)"
    last_touch="$(git -C "$rroot" log -1 --format=%cI -- "$path" 2>/dev/null || true)"
    [ -n "$last_touch" ] && last_touch="$(_iso_to_utc_z "$last_touch")"
    if [ -n "$last_mirror" ] && [ -n "$newest" ] && [ "$last_mirror" '>' "$newest" ]; then newest="$last_mirror"; fi
    [ -z "$newest" ] && [ -n "$last_mirror" ] && newest="$last_mirror"
    if [ -z "$last_mirror" ]; then
      echo "status: ${name}: never mirrored" >&2
      changed=$((changed+1))
    elif [ -n "$last_touch" ] && [ "$last_touch" '>' "$last_mirror" ]; then
      echo "status: ${name}: changed since last mirror (touched ${last_touch}, mirrored ${last_mirror})" >&2
      changed=$((changed+1))
    else
      echo "status: ${name}: up to date (mirrored ${last_mirror})" >&2
    fi
  done < "$registry"
  rm -f "$snap_tsv"

  echo "${changed} repos changed since last mirror, last synced ${newest:-never}"

  # --with-mega (OPT-IN, kit-modularity sub-goal 08): a trailing MEGA ROLLUP section, one line
  # per ACTIVE mega per registry repo. Off by default (real `gh` calls per sub-goal; must never
  # fire inside test-board-mirror.sh's fixture registry, which never passes this flag).
  if [ "$OPT_WITH_MEGA" -eq 1 ]; then
    echo ""
    echo "MEGA ROLLUP:"
    while read -r name path _rest; do
      [ -n "${name:-}" ] || continue
      case "$name" in \#*) continue ;; esac
      path="${path/#\~/$HOME}"
      [ -f "$path" ] || continue
      local mrepo_root mcode_root mrollups
      mrepo_root="$(_repo_root_for "$path")"
      mcode_root="${OPT_MEGA_CODE_ROOT:-$mrepo_root}"
      mrollups="$(_mega_rollups "$mrepo_root" "$mcode_root")"
      [ -n "$mrollups" ] && printf '%s\n' "$mrollups"
    done < "$registry"
  fi
}

# ---------------------------------------------------------------------------
# writeback -- git<->Hermes bridge, the WRITEBACK leg (SPEC-149, runner-fastpath sub-goal 08).
# Delegates ALL substantial logic (diff/validate/apply/PR) to lib/board/board-writeback.sh, the same
# thin-wrapper shape `mirror` above has with lib/board/board-mirror.sh: resolve config, get a validated
# changeset, apply it (branch+commit+push+PR per affected repo), refresh the snapshot per applied
# origin, print a summary. `--dry-run` computes the changeset (which DOES read Hermes -- that read
# is exactly what a preview needs) but applies nothing: no branch, no commit, no push, no PR, no
# snapshot write.
# ---------------------------------------------------------------------------
cmd_writeback() {
  _legacy_bridge_note
  _parse_flags "$@"
  local repo_root; repo_root="$(_resolve_repo_root)"
  local registry="${OPT_REGISTRY:-$repo_root/_meta/boards.txt}"
  local snapshot="${OPT_SNAPSHOT:-$repo_root/_meta/.board-mirror-snapshot.jsonl}"
  local branch="${OPT_BRANCH:-chore/board-sync}"
  [ -f "$registry" ] || { echo "writeback: no registry at $registry" >&2; return 1; }

  local diff_args=(diff --registry "$registry" --snapshot "$snapshot")
  [ -n "$OPT_BOARD_PREFIX" ] && diff_args+=(--board-prefix "$OPT_BOARD_PREFIX")

  local changeset; changeset="$(mktemp "${TMPDIR:-/tmp}/board-writeback-plan.XXXXXX")"
  # `if cmd; then rc=0; else rc=$?; fi` (NOT `if ! cmd; then rc=$?; fi`): bash sets `$?` to the
  # NEGATED (`!`-inverted) status inside an `if ! cmd; then` block, not cmd's own exit code (a real
  # bug this build's own smoke test caught -- `rc` always read back as 0). This is the same
  # command-substitution/exit-code gotcha lib/board/board-mirror.sh's `cmd_apply_plan` already documents
  # for its own `if out=$(...); then rc=0; else rc=$?; fi` pattern.
  local rc
  if bash "$BOARD_WRITEBACK_SH" "${diff_args[@]}" > "$changeset"; then rc=0; else rc=$?; fi
  if [ "$rc" -ne 0 ]; then
    rm -f "$changeset"
    return "$rc"
  fi

  if [ ! -s "$changeset" ]; then
    echo "writeback: 0 changes" >&2
    rm -f "$changeset"
    return 0
  fi

  if [ "$OPT_DRY_RUN" -eq 1 ]; then
    cat "$changeset"
    rm -f "$changeset"
    return 0
  fi

  local apply_args=(apply --branch "$branch")
  [ -n "$OPT_PR_BASE" ] && apply_args+=(--pr-base "$OPT_PR_BASE")

  local results
  results="$(bash "$BOARD_WRITEBACK_SH" "${apply_args[@]}" < "$changeset")"
  rm -f "$changeset"

  local rline
  while IFS= read -r rline; do
    [ -n "$rline" ] || continue
    printf '%s' "$rline" | bash "$BOARD_MIRROR_SH" snapshot-upsert "$snapshot"
  done <<< "$results"

  return 0
}

# board sync [--dry-run] [--sources a,b] ... -- two-way spoke sync (the `sync`
# module, lib/sync/). Consumer shims append --backlog-file; translate it to the
# engine's --backlog. Config resolution happens HERE per ADR-0034: a command
# reads [sync] keys via the ONE resolver at invocation and hands the python
# init: scaffold the board files adopt does not cover. `kit adopt` seeds
# .kit.toml and wires modules; the board itself (_meta/BACKLOG.md + the _meta/
# board shim) was a copy-by-hand step, which is exactly how a new repo ends up
# half-registered. Idempotent: existing files are never touched.
cmd_init() {
  local root; root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  local meta="$root/_meta"
  mkdir -p "$meta"
  if [ ! -f "$meta/BACKLOG.md" ]; then
    printf '# BACKLOG\n\n| ID | Item | Notes & source | Status |\n|---|---|---|---|\n' \
      > "$meta/BACKLOG.md"
    echo "created _meta/BACKLOG.md (empty board; \`board sync\` intakes open issues as rows)"
  else
    echo "kept existing _meta/BACKLOG.md"
  fi
  if [ ! -f "$meta/board" ]; then
    cat > "$meta/board" <<'SHIM'
#!/usr/bin/env bash
# _meta/board -- one-line shim exec'ing the dwarves-kit `board` command against
# THIS repo's own BACKLOG.md. Scaffolded by `board init`; logic lives in the kit.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
exec bash "${DWARVES_KIT:-$HOME/.claude/dwarves-kit}/bin/board" "${@:-board}" --backlog-file "$here/BACKLOG.md"
SHIM
    chmod +x "$meta/board"
    echo "created _meta/board shim"
  else
    echo "kept existing _meta/board"
  fi
  [ -f "$root/.kit.toml" ] && grep -q '^\[sync\]' "$root/.kit.toml" 2>/dev/null || {
    echo "next: add a [sync] section to .kit.toml, e.g."
    printf '  [sync]\n  apps = "github"\n'
  }
}

# capture: file ONE item from a working session -- a queued row on the board,
# pushed to the configured spokes immediately, and (when the github app is on)
# the new issue's URL printed and put on the clipboard. This is the
# harness-agnostic "file this" verb: Claude Code, Codex, pi and Hermes all just
# run `board capture "<title>" [-b <notes>]`.
cmd_capture() {
  local backlog="" title="" notes="" a
  while [ $# -gt 0 ]; do
    case "$1" in
      --backlog-file) backlog="${2:-}"; shift 2 ;;
      -b|--notes) notes="${2:-}"; shift 2 ;;
      *) if [ -z "$title" ]; then title="$1"; else title="$title $1"; fi; shift ;;
    esac
  done
  [ -n "$title" ] || { echo "usage: board capture \"<title>\" [-b <notes>]" >&2; exit 2; }
  backlog="${backlog:-$PWD/_meta/BACKLOG.md}"
  [ -f "$backlog" ] || { echo "board capture: no board at $backlog (run \`board init\`)" >&2; exit 2; }
  local bid
  bid="$(BOARD_SYNC_LIB="$BOARD_DIR/../sync" python3 - "$backlog" "$title" "$notes" <<'PY'
import os, sys
from pathlib import Path
sys.path.insert(0, os.environ["BOARD_SYNC_LIB"])
from sync_core import detect_prefix, next_id, escape
path = Path(sys.argv[1])
text = path.read_text()
prefix = detect_prefix(text)
bid = f"{prefix}-{next_id(text, prefix)}"
title, notes = sys.argv[2], sys.argv[3] or "filed via board capture"
row = f"| {bid} | {escape(' '.join(title.split()))} | {escape(notes)} | queued |\n"
lines = text.splitlines(keepends=True)
for i, ln in enumerate(lines):
    if ln.startswith("|---"):
        lines.insert(i + 1, row)
        break
else:
    sys.exit(f"no table header found in {path}")
path.write_text("".join(lines))
print(bid)
PY
)"
  # sync in a subshell: cmd_sync ends in exec and must not replace this shell.
  ( cmd_sync --backlog-file "$backlog" ) || true
  local rid=""
  rid="$(python3 - "$backlog" "$bid" <<'PY'
import json, re, sys
from pathlib import Path
slug = re.sub(r"[^a-zA-Z0-9]+", "-", str(Path(sys.argv[1]).resolve())).strip("-")
p = Path.home() / ".cache" / "backlog-sync" / slug / "github.state.json"
try:
    print(json.loads(p.read_text())["map"][sys.argv[2]]["rid"])
except Exception:
    pass
PY
)"
  echo "filed: $bid"
  if [ -n "$rid" ]; then
    local url
    url="$(cd "$(dirname "$backlog")/.." && gh issue view "$rid" --json url --jq .url 2>/dev/null || true)"
    if [ -n "$url" ]; then
      printf '%s' "$url" | pbcopy 2>/dev/null || true
      echo "issue: $url  (link on clipboard)"
      # enrich: what already exists nearby, so duplicates get merged early
      (cd "$(dirname "$backlog")/.." && gh issue list --state all --search "$title" \
        --limit 4 --json number,title \
        --jq '.[] | "  #\(.number) \(.title)"' 2>/dev/null | grep -v "^  #$rid " || true) \
        | sed '1s/^/related existing issues:\n/' | head -5
    fi
  else
    echo "note: no github spoke configured (or sync skipped); row is on the board"
  fi
}

# engine plain flags (the engine never reads TOML). User-passed flags land
# after the config-derived ones, so argparse lets them win.
cmd_sync() {
  local backlog="" fwd=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --backlog-file) backlog="${2:-}"; shift 2 ;;
      *) fwd+=("$1"); shift ;;
    esac
  done
  backlog="${backlog:-$PWD/_meta/BACKLOG.md}"
  [ -f "$backlog" ] || { echo "board sync: no backlog at $backlog" >&2; exit 2; }
  . "$BOARD_DIR/../config/kit-config.sh"
  # git-aware repo root: BACKLOG.md lives at _meta/ in some repos and at repo
  # root in others; _repo_root_for handles both
  KIT_PROJECT_ROOT="$(_repo_root_for "$backlog")"
  export KIT_PROJECT_ROOT
  local args=(--backlog "$backlog") v
  v="$(kit_config_get sync.apps "")"
  [ -n "$v" ] || v="$(kit_config_get sync.surfaces "")"  # legacy alias
  [ -n "$v" ] || v="$(kit_config_get sync.sources "")"   # older legacy alias
  if [ -z "$v" ]; then
    echo "board sync: no [sync] apps configured in $KIT_PROJECT_ROOT/.kit.toml" >&2
    printf '  add e.g.:\n  [sync]\n  apps = "reminders"\n' >&2
    exit 2
  fi
  args+=(--apps "$v")
  local app fk
  for app in reminders notion hermes multica github; do
    for fk in only_tags skip_tags intake; do
      v="$(kit_config_get "sync.${app}_${fk}" "")"
      [ -n "$v" ] && args+=(--filter "${app}:${fk}=${v}")
    done
  done
  v="$(kit_config_get sync.scope_exit_cap "")"; [ -n "$v" ] && args+=(--scope-exit-cap "$v")
  v="$(kit_config_get sync.reminders_list "")";  [ -n "$v" ] && args+=(--list "$v")
  v="$(kit_config_get sync.notion_db "")";       [ -n "$v" ] && args+=(--notion-db "$v")
  v="$(kit_config_get sync.notion_parent "")";   [ -n "$v" ] && args+=(--notion-parent "$v")
  # notion-taskboard: one-way, insert-only push to a foreign team board
  # (SPEC-003). Down-filter only (a write-only sink has no intake path); the
  # keys are TOML-friendly underscores but the engine's --filter app token
  # keeps the hyphenated adapter name.
  for fk in only_tags skip_tags; do
    v="$(kit_config_get "sync.notion_taskboard_${fk}" "")"
    [ -n "$v" ] && args+=(--filter "notion-taskboard:${fk}=${v}")
  done
  v="$(kit_config_get sync.notion_taskboard_db "")"
  [ -n "$v" ] && args+=(--notion-taskboard-db "$v")
  v="$(kit_config_get sync.notion_taskboard_status_map "")"
  [ -n "$v" ] && args+=(--notion-taskboard-status-map "$v")
  v="$(kit_config_get sync.notion_taskboard_status_default "")"
  [ -n "$v" ] && args+=(--notion-taskboard-status-default "$v")
  v="$(kit_config_get sync.notion_taskboard_priority_map "")"
  [ -n "$v" ] && args+=(--notion-taskboard-priority-map "$v")
  v="$(kit_config_get sync.notion_taskboard_weight_map "")"
  [ -n "$v" ] && args+=(--notion-taskboard-weight-map "$v")
  v="$(kit_config_get sync.notion_taskboard_owner "")"
  [ -n "$v" ] && args+=(--notion-taskboard-owner "$v")
  v="$(kit_config_get sync.notion_taskboard_props "")"
  [ -n "$v" ] && args+=(--notion-taskboard-props "$v")
  v="$(kit_config_get sync.notion_taskboard_types "")"
  [ -n "$v" ] && args+=(--notion-taskboard-types "$v")
  # notion-taskboard-pull: read-only intake FROM the same foreign team board
  # (SPEC-004). No filter keys: the source board's own Agent Queue checkbox is
  # the gate, and a second gate has no user.
  v="$(kit_config_get sync.notion_taskboard_pull_db "")"
  [ -n "$v" ] && args+=(--notion-taskboard-pull-db "$v")
  v="$(kit_config_get sync.notion_taskboard_pull_props "")"
  [ -n "$v" ] && args+=(--notion-taskboard-pull-props "$v")
  v="$(kit_config_get sync.notion_taskboard_pull_done_option "")"
  [ -n "$v" ] && args+=(--notion-taskboard-pull-done-option "$v")
  v="$(kit_config_get sync.github_repo "")";     [ -n "$v" ] && args+=(--github-repo "$v")
  v="$(kit_config_get sync.hermes_target "")";   [ -n "$v" ] && args+=(--hermes-target "$v")
  v="$(kit_config_get sync.hermes_home "")";     [ -n "$v" ] && args+=(--hermes-home "$v")
  v="$(kit_config_get sync.hermes_board "")";    [ -n "$v" ] && args+=(--hermes-board "$v")
  v="$(kit_config_get sync.hermes_assignee "")"; [ -n "$v" ] && args+=(--hermes-assignee "$v")
  v="$(kit_config_get sync.hermes_workspace "")"; [ -n "$v" ] && args+=(--hermes-workspace "$v")
  v="$(kit_config_get sync.multica_url "")";       [ -n "$v" ] && args+=(--multica-url "$v")
  v="$(kit_config_get sync.multica_workspace "")"; [ -n "$v" ] && args+=(--multica-workspace "$v")
  v="$(kit_config_get sync.multica_project "")";   [ -n "$v" ] && args+=(--multica-project "$v")
  # token goes through the env, never argv (ps leaks argv); Keychain-cached
  # 1P read per the runtime-secret rule, raw `op read` as the fallback.
  v="$(kit_config_get sync.multica_token_ref "")"
  if [ -n "$v" ] && [ -z "${MULTICA_TOKEN:-}" ]; then
    if command -v secret-cache-read >/dev/null 2>&1; then
      MULTICA_TOKEN="$(secret-cache-read --ttl 21600 MULTICA_TOKEN "$v")"
    else
      MULTICA_TOKEN="$(op read "$v")"
    fi
    export MULTICA_TOKEN
  fi
  exec python3 "$BOARD_DIR/../sync/backlog_sync.py" "${args[@]}" ${fwd[@]+"${fwd[@]}"}
}

# publish: the git leg of SPEC-002's intake -> publish -> relay sequencing.
# `board sync` mutates the board file in place; without this leg a scheduled
# runner (the estate's hourly sweeper) leaves every checkout permanently
# dirty, spoke writes invisible off-host and every ff-pull blocked
# (ops-toolkit ID-638). Stages ONLY the board file; other dirt is untouched.
#
# COMMIT-FIRST by design (battery 2026-09-01): committing before any pull
# means a rebase conflict can never stage conflict markers into the board
# file, and a failed rebase aborts back to the committed state instead of
# wedging the checkout. Exit codes: 0 published or clean no-op; 2 usage or
# fence refusal; 3 committed locally but NOT on the remote (push/rebase
# failure) -- callers treat 3 as a monitoring signal, the commit is safe.
cmd_publish() {
  local backlog="" push=1
  while [ $# -gt 0 ]; do case "$1" in
    --backlog-file) backlog="${2:-}"; shift 2 ;;
    --no-push) push=0; shift ;;
    *) echo "publish: unknown arg: $1" >&2; return 64 ;;
  esac; done
  backlog="${backlog:-$PWD/_meta/BACKLOG.md}"
  [ -f "$backlog" ] || { echo "board publish: no backlog at $backlog" >&2; return 2; }
  # physical path (pwd -P): the worktree fence must not be evadable through
  # a symlinked path, matching the sync engine's resolve() fence
  local absdir; absdir="$(cd "$(dirname "$backlog")" && pwd -P)"
  case "$absdir" in
    */.claude/worktrees/*)
      echo "board publish: refusing a worktree checkout ($backlog); publish" >&2
      echo "  runs from the canonical checkout only (same fence as sync)." >&2
      return 2 ;;
  esac
  local root; root="$(git -C "$absdir" rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "board publish: $backlog is not in a git repo" >&2; return 2; }
  local branch; branch="$(git -C "$root" symbolic-ref --quiet --short HEAD)" \
    || { echo "board publish: detached HEAD; refusing to publish" >&2; return 2; }
  local rel="${absdir}/$(basename "$backlog")"; rel="${rel#"$root"/}"
  # :(literal) everywhere: a board path with glob characters must never
  # widen the pathspec to unrelated files in an auto-pushed commit
  local spec=":(literal)$rel"
  if git -C "$root" diff --quiet -- "$spec" 2>/dev/null; then
    echo "board publish: no board changes in $rel"
    return 0
  fi
  # a scheduled runner must never hang on a credential or hostkey prompt
  local -a G=(git -c core.askPass=true -C "$root")
  export GIT_TERMINAL_PROMPT=0
  export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}"
  "${G[@]}" add -- "$spec"
  if ! "${G[@]}" commit --quiet -m "chore(board): publish spoke updates" -- "$spec"; then
    echo "board publish: commit failed for $rel" >&2
    return 1
  fi
  echo "board publish: committed $rel"
  [ "$push" -eq 1 ] || return 0
  # pinned refspec: only ever the current branch, never a surprise target
  if "${G[@]}" push --quiet origin "HEAD:refs/heads/$branch" 2>/dev/null; then
    echo "board publish: pushed"
    return 0
  fi
  # non-ff or auth failure: try one rebase, abort hard on any conflict so
  # the checkout is never left mid-rebase (the commit survives either way)
  if ! "${G[@]}" pull --rebase --autostash --quiet origin "$branch" 2>/dev/null \
      || [ -n "$("${G[@]}" ls-files -u -- "$spec" 2>/dev/null)" ]; then
    "${G[@]}" rebase --abort >/dev/null 2>&1 || true
    echo "board publish: WARN remote diverged and rebase did not apply cleanly;" >&2
    echo "  commit is local, checkout restored, will retry next publish" >&2
    return 3
  fi
  if "${G[@]}" push --quiet origin "HEAD:refs/heads/$branch" 2>/dev/null; then
    echo "board publish: pushed (after rebase)"
    return 0
  fi
  echo "board publish: WARN push failed (auth?); commit is local, next publish retries" >&2
  return 3
}

# bridge was folded into the sync module 2026-07-16; these verbs are the
# legacy cockpit engine until the SPEC-002 P2 port (kit board ID-290).
_legacy_bridge_note() {
  echo "note: mirror/status/writeback are the legacy cockpit engine (bridge)," >&2
  echo "      folded into the sync module; the port is tracked on the kit board." >&2
}

usage() { sed -n '2,166p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

main() {
  local first="${1:-}"
  case "$first" in
    all)    shift; cmd_all "$@" ;;
    queue)  shift; cmd_queue "$@" ;;
    mirror) shift; cmd_mirror "$@" ;;
    status) shift; cmd_status "$@" ;;
    writeback) shift; cmd_writeback "$@" ;;
    sync) shift; cmd_sync "$@" ;;
    publish) shift; cmd_publish "$@" ;;
    init) shift; cmd_init "$@" ;;
    capture) shift; cmd_capture "$@" ;;
    promote) shift; exec "$BOARD_DIR/bin/add-backlog" "$@" ;;
    -h|--help|help) usage ;;
    *) cmd_board_single "$@" ;;
  esac
}

main "$@"
