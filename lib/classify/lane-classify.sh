#!/usr/bin/env bash
# lane-classify.sh -- deterministic task-type -> risk-lane classifier.
#
# Turns a one-line task description into one of the WORKFLOW.md risk lanes
# (tiny | normal | full | bug | backfill) so the intake path (/kit:assign) and the
# dispatch path (/kit:dispatch) can auto-choose the lane instead of relying on ad-hoc
# judgment. Pure bash + grep; no binary.
#
# Flag-scoring model (absorbed from hoangnb24/repository-harness FEATURE_INTAKE, 2026-06-10;
# see docs/specs/SPEC-050 + docs/absorption/2026-06-10-repository-harness.md). Named risk flags
# are matched against the description:
#   - HARD-gate flags: any one hit -> `full` (mirrors the harness auto-escalate list + the
#     WORKFLOW full-lane triggers, PLUS a `kit-machinery` flag, the gap that misclassified the
#     adopt + install PRs as `normal` on 2026-06-10).
#   - SOFT flags: counted; 4+ -> `full`, 2-3 -> `normal` (noted as near-full).
# `explain` prints which flags fired so a classification (and any override) is auditable, not a
# black box. This SUGGESTS a lane; it never blocks ("Detect, don't dictate").
#
# Precedence (first match wins): backfill > tiny > hard-gate > bug > soft-count > normal. tiny
# stays above the hard-gate so "a typo about auth" is still a typo; backfill stays first so a
# keyword inside a doc task (e.g. "write its AGENTS.md") does not escalate.
#
# The `check` subcommand adds the floor guard (SPEC-053): given the lane actually CHOSEN
# plus the task text, it warns (advisory, exit 0) when the choice is lighter than the
# suggestion, so an under-sized full/bug task does not slip through /kit:assign unnoticed.
#
# Usage:
#   lane-classify.sh classify "<desc>"                 -> prints the lane, exit 0
#   lane-classify.sh explain  "<desc>"                 -> prints the lane + reason + fired flags
#   lane-classify.sh check <chosen-lane> "<desc>"      -> warn+log if chosen < floor, exit 0
#   lane-classify.sh escalate <current-lane> <spec-file>  -> up-only spec->build re-classify
#                                                            (ESCALATE <cur> -> <heavier> | HOLD <cur>), exit 0
#   lane-classify.sh deescalate <chosen-lane> [--rid <rid>] [--root <path>] [--base <ref>] [--floor <N>]
#                                                        -> down-only SHIP-time size nudge (SPEC-141):
#                                                           advisory line + ledger action, never blocks, exit 0
#   lane-classify.sh lanes                              -> prints the 5 lane names
#   lane-classify.sh flags                              -> prints the flag names

set -euo pipefail

# Durable run-telemetry root (SPEC-097): the LANE-CHECK downgrade writer below must land
# in the same durable dir lane-telemetry.sh reads from, or downgrades go split-brain
# (written to the legacy path, invisible to the migrated reader).
LC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_ROOT="$(cd "$LC_DIR/.." && pwd)"  # the lib/ dir; cross-subsystem siblings resolve as "$LIB_ROOT/<subsystem>/<file>"
# shellcheck source=lib/telemetry/kit-log-dir.sh
source "$LIB_ROOT/telemetry/kit-log-dir.sh" || { echo "FATAL: lib/telemetry/kit-log-dir.sh missing or unreadable" >&2; exit 1; }
# deescalate()'s ledger write only (SPEC-141); no other verb in this file touches gate-ledger.
GATE_LEDGER="$LIB_ROOT/gate/gate-ledger.sh"

# Hard-gate flags (any hit -> full). name <-> regex, index-aligned.
_hard_name=(auth data-model audit-security external-provider public-contract weaken-validation kit-machinery)
_hard_re=(
  'auth[a-z]*|login|logout|password|jwt|\bsession(s)?\b|refresh token|permission|\brole(s)?\b|tenant'
  'migrat|schema|data[ -]model|uniqueness|retention|data loss|delete[s]? .*data|drop (table|column)'
  'audit|privacy|sensitive data|access log|secret|token|crypto|encrypt|\bsecurity\b|harden|vulnerab|exploit|injection|\bxss\b|\bcsrf\b|rate.?limit'
  'external (api|provider|service)|payment|billing|webhook|provider sdk|\bqueue(s)?\b|email send'
  'api contract|response envelope|public (api|contract)|client[ -]visible|breaking change'
  'weaken[s]? .*validation|remove[s]? .*validation|disabl[a-z]* .*(check|guard|validation)'
  'hooks/|hooks\.json|\bhook(s)?\b.{0,30}(kit|machinery|enforcement|gate-ledger|ship-gate|lane-classify)|the kit.{0,30}\bhook(s)?\b|gate-ledger|ship-gate|lane-classify|lane-telemetry|mega-merge|stack-merge|proof-ledger|kit-log-dir|orchestrate\.sh|role-classify|goal-drafts|proof-gate|task-type-classify|backlog\.sh|goal-registry|dispatch-gate|install\.sh|adopt\.sh|workflow\.md|adopt @|/?kit:adopt|adopt(s|ed|ing)? .{0,30}(agents?\.md|contract|kit|loader|marker|workflow|gate)|gate machinery|the kit.{0,12}(lane|gate|machinery|classifier)'
)
# Soft flags (counted; 4+ -> full, 2-3 -> normal-noted). name <-> regex, index-aligned.
_soft_name=(cross-platform existing-behavior weak-proof multi-domain concurrency)
_soft_re=(
  'cross[ -]platform|desktop.*mobile|native shell|deep link'
  'existing behavio|already (implemented|test-covered|shipped)|change[s]? .*(existing|current) behavio'
  'no tests?|missing tests?|untested|unclear test|weak (proof|coverage)'
  'multi[ -]domain|more than one .*domain|two domains'
  'concurren|race condition|\bparallel\b|locking|index\.lock'
)

# A name array out of sync with its regex array would mislabel `explain` output silently
# (review: parallel-array footgun). Fail loud at load instead.
[ "${#_hard_name[@]}" -eq "${#_hard_re[@]}" ] && [ "${#_soft_name[@]}" -eq "${#_soft_re[@]}" ] \
  || { echo "lane-classify: flag name/regex arrays are misaligned (bug)" >&2; exit 70; }

LANE=""; REASON=""; FIRED=""

# Edit-vs-mention signal (SPEC-105 / ID-088). FILES = the change's touched files (space-
# separated); FILES_SET = 1 when the caller passed --files (even empty). Default: no files
# supplied -> the kit-machinery hard-gate keeps its legacy text-only behavior (a mention
# escalates), so nothing regresses for callers that pass none. Set per-invocation by
# _extract_files below; a fresh CLI process starts at the defaults.
FILES=""; FILES_SET=0; REMAIN=()

# _files_touch_machinery -- true if any touched file is under lib/ or hooks/, the kit's
# enforcement layer (SPEC-069's own definition of the machinery surface). This is the FILE
# fact that separates an EDIT to a machinery lib from a mere textual MENTION of its basename.
_files_touch_machinery() {
  # Quote the split (read -ra, not a bare `for f in $FILES`) so a path with a space or a
  # literal glob char is not word-split / pathname-expanded (TIER-4 security nit). NOTE for the
  # future caller that wires --files: source the list from a trusted `git diff --name-only`, not
  # a model-authored free-text claim, or a curated/incomplete list could under-gate a real edit.
  local f _files=()
  IFS=' ' read -ra _files <<< "$FILES"
  for f in ${_files[@]+"${_files[@]}"}; do
    case "$f" in
      lib/*|hooks/*|*/lib/*|*/hooks/*) return 0 ;;
    esac
  done
  return 1
}

# _extract_files "$@" -- pull an optional `--files <list>` / `--files=<list>` out of the args,
# set FILES + FILES_SET, and leave the remaining (description) args in REMAIN. Anywhere in the
# arg list; the value is one shell word (quote a multi-file list at the call site).
_extract_files() {
  FILES=""; FILES_SET=0; REMAIN=()
  local a skip=0
  for a in "$@"; do
    if [ "$skip" = 1 ]; then FILES="$a"; skip=0; continue; fi
    case "$a" in
      --files)   FILES_SET=1; skip=1 ;;
      --files=*) FILES_SET=1; FILES="${a#--files=}" ;;
      *)         REMAIN+=("$a") ;;
    esac
  done
}

# classify_core "<desc>" -- sets LANE, REASON, FIRED. The single source of truth both
# `classify` and `explain` read. Reads the FILES/FILES_SET globals for the edit-vs-mention
# discriminator (SPEC-105); callers that don't set them get the legacy text-only path.
classify_core() {
  local lc; lc="$(printf '%s' "$*" | tr '[:upper:]' '[:lower:]')"
  LANE=""; REASON=""; FIRED=""

  # 1. backfill: brownfield operating-layer documentation (first, so an in-doc keyword like
  #    "write its AGENTS.md" does not pull the task into the kit-machinery hard-gate).
  if printf '%s' "$lc" | grep -qE 'backfill|operating[ -]layer|brownfield|document the existing|writes?\b.{0,12}(agents|claude)\.md'; then
    # SPEC-074 review HIGH: a backfill phrase that ALSO carries a hard-gate subject
    # ("write its AGENTS.md and disable the safety hooks") must not be down-laned;
    # the pure doc case carries no hard keyword and stays backfill.
    local j
    for j in "${!_hard_re[@]}"; do
      if printf '%s' "$lc" | grep -qE "${_hard_re[$j]}"; then
        LANE=full; REASON="backfill phrase + hard-gate subject (${_hard_name[$j]})"; FIRED="${_hard_name[$j]}"; return 0
      fi
    done
    LANE=backfill; REASON="brownfield operating-layer docs"; FIRED=backfill; return 0
  fi

  # 2. tiny: pure cosmetic, regardless of subject (a typo about auth is still a typo).
  if printf '%s' "$lc" | grep -qE 'typo|whitespace|re-?word|copy[ -]?edit|comment|rename|formatting|one[ -]liner?|wording|doc(s)? fix|fix .*(typo|wording|comment)'; then
    LANE=tiny; REASON="pure cosmetic"; FIRED=tiny; return 0
  fi

  # 3. hard-gate flags -> full.
  local i hard=""
  for i in "${!_hard_re[@]}"; do
    if [ "${_hard_name[$i]}" = kit-machinery ]; then
      # Edit-vs-mention (SPEC-105 / ID-088): kit-machinery is a proxy for "touches the
      # enforcement surface", which is a FILE fact, not a semantic one (unlike auth /
      # data-model, which are risky by subject regardless of files). When the caller supplied
      # --files, the FILE is authoritative: escalate on an actual EDIT to lib/ or hooks/, NOT
      # on a description that merely names a basename. No --files -> legacy text-only (a mention
      # escalates), so nothing regresses.
      if [ "$FILES_SET" = 1 ]; then
        _files_touch_machinery && hard="$hard kit-machinery"
      elif printf '%s' "$lc" | grep -qE "${_hard_re[$i]}"; then
        hard="$hard kit-machinery"
      fi
      continue
    fi
    if printf '%s' "$lc" | grep -qE "${_hard_re[$i]}"; then hard="$hard ${_hard_name[$i]}"; fi
  done
  if [ -n "$hard" ]; then
    LANE=full; REASON="hard-gate flag(s):$hard"; FIRED="${hard# }"; return 0
  fi

  # 3b. doc-bootstrap (SPEC-072 / ID-064), deliberately AFTER the hard-gate pass:
  # markdown-only or doc-tree bootstrap work is tiny, but these anchors describe the
  # SUBJECT of the work, not a cosmetic surface, so a README about auth tokens or
  # gate machinery must let the hard-gate win first (review HIGH, SPEC-072).
  if printf '%s' "$lc" | grep -qE 'markdown[ -]only|bootstrap .{0,40}(readme|notes|reading list|learning track)'; then
    LANE=tiny; REASON="doc bootstrap (markdown-only / doc-tree), no hard-gate subject"; FIRED=doc-bootstrap; return 0
  fi

  # 4. bug: a defect, not a new feature.
  if printf '%s' "$lc" | grep -qE '\bbug\b|regression|failing test|broken|crash|defect|hotfix|stack ?trace|exception|fix the|fix a |repro'; then
    LANE=bug; REASON="defect / regression"; FIRED=bug; return 0
  fi

  # 5. soft-flag count: 4+ -> full, 2-3 -> normal (near-full), else default normal.
  local soft="" n=0
  for i in "${!_soft_re[@]}"; do
    if printf '%s' "$lc" | grep -qE "${_soft_re[$i]}"; then soft="$soft ${_soft_name[$i]}"; n=$((n + 1)); fi
  done
  if [ "$n" -ge 4 ]; then LANE=full;   REASON="$n soft flags (>=4):$soft"; FIRED="${soft# }"; return 0; fi
  if [ "$n" -ge 2 ]; then LANE=normal; REASON="$n soft flags (2-3, near full):$soft"; FIRED="${soft# }"; return 0; fi
  LANE=normal; REASON="bounded feature/fix (default)"; FIRED="${soft# }"; FIRED="${FIRED:-none}"; return 0
}

# Risk rank for the floor check (SPEC-053). Under-sizing (a lighter lane than the text
# implies) is the only dangerous direction; over-sizing is always safe ("when in doubt,
# heavier"). normal/bug/backfill share rank 2 (same ceremony weight); full is the headline
# floor. An unrecognized lane returns -1 so lane_check can flag it distinctly.
lane_rank() {
  case "$1" in
    tiny)                echo 1;;
    normal|bug|backfill) echo 2;;
    full)                echo 3;;
    *)                   echo -1;;
  esac
}

# Advisory floor check: compare the lane a human/LLM CHOSE against the deterministic
# suggestion for the same text. Warn (stderr) + log (completeness.log) ONLY when the
# chosen lane is lighter than the floor. Never blocks; always exits 0 ("Detect, don't
# dictate"). This is the guard the classify-then-route audit found missing: classify
# suggests, but nothing caught an under-sized choice.
lane_check() {
  local chosen desc suggested cr sr log_dir desc_trunc
  chosen="${1:-}"; shift 2>/dev/null || true
  desc="$*"
  [ -n "$chosen" ] || { echo "usage: lane-classify.sh check <chosen-lane> \"<description>\"" >&2; return 64; }

  cr="$(lane_rank "$chosen")"
  if [ "$cr" -lt 0 ]; then
    echo "LANE-UNKNOWN: '$chosen' is not a lane (tiny|normal|full|bug|backfill); not checked" >&2
    return 0
  fi

  classify_core "$desc"
  suggested="$LANE"
  sr="$(lane_rank "$suggested")"

  if [ "$cr" -lt "$sr" ]; then
    echo "LANE-DOWNGRADE: chosen=$chosen suggested=$suggested -- the task text matches a heavier lane; size up or say why" >&2
    desc_trunc="$(printf '%s' "$desc" | tr '\n' ' ' | cut -c1-100)"
    # NB (arch review): unlike the other 5 corpus libs (which migrate at load), lane-classify
    # migrates HERE, at the downgrade-write path -- classify/explain run far more often WITHOUT
    # a downgrade, so deferring the mkdir/stat to the actual write is a small deliberate win.
    kit_migrate_log_dir || true
    log_dir="$(kit_resolve_log_dir)"
    mkdir -p "$log_dir" 2>/dev/null || true
    printf '%s | LANE-CHECK | downgrade | chosen=%s suggested=%s | %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$chosen" "$suggested" "$desc_trunc" \
      >> "$log_dir/completeness.log" 2>/dev/null || true
  fi
  return 0
}

# Spec->build-boundary re-classification (SPEC-094, ADR-0028 refinement point 4,
# kit-hardening SG-06). `check` above compares the CHOSEN lane against the original
# task TEXT at intake; `escalate` compares the lane RECORDED at intake against the
# SPEC's own text at the point the spec is validated and build is about to start --
# the first point emergent scope (auth / data-model / migration the one-line task
# description never carried) is concrete. Up-only: a heavier spec-implied lane
# escalates; a same-or-lighter one HOLDS (the downgrade guard -- reuses lane_rank,
# same as lane_check, so a lighter re-class can never win). Advisory: prints the
# decision and exits 0 always ("Detect, don't dictate"; ADR-0024 mid-flight never
# hard-blocks). It does NOT mutate the gate-ledger or the spec file itself -- the
# caller (commands/execute.md Prerequisites) does the recording on ESCALATE.
escalate() {
  local current="${1:-}" spec_file="${2:-}" cr spec_lane sr
  if [ -z "$current" ] || [ -z "$spec_file" ]; then
    echo "usage: lane-classify.sh escalate <current-lane> <spec-file>" >&2; return 64
  fi
  [ -f "$spec_file" ] || { echo "escalate: spec file '$spec_file' not found" >&2; return 64; }

  cr="$(lane_rank "$current")"
  if [ "$cr" -lt 0 ]; then
    echo "LANE-UNKNOWN: '$current' is not a lane (tiny|normal|full|bug|backfill); not checked" >&2
    return 0
  fi

  classify_core "$(cat "$spec_file")"
  spec_lane="$LANE"
  sr="$(lane_rank "$spec_lane")"

  if [ "$sr" -gt "$cr" ]; then
    printf 'ESCALATE %s -> %s\n' "$current" "$spec_lane"
  else
    printf 'HOLD %s\n' "$current"
  fi
  return 0
}

# --- ship-time de-escalation (SPEC-141): the size-floor sibling of escalate() above. ---
# escalate() is TEXT-based and up-only, at the spec->build boundary. deescalate() is
# DIFF-SIZE-based and down-only, at the SHIP boundary: when the lane actually SHIPPED was
# normal/full but the final diff stayed under a changed-lines floor, this is a NUDGE for next
# time's classification habit, never a re-classification of the run that already shipped
# (mirrors quiz-gate.sh's always-exit-0, never-block posture). Only an escalated lane
# (normal/full) can ever be found "too heavy after all" -- tiny/bug/backfill never fire,
# mirroring lane_rank's "over-sizing is always safe" stance (nothing here ever calls a bug or
# backfill run oversized).
#
# Base resolution mirrors hooks/ship-gate.sh / lib/gate/coverage-delta.sh's _resolve_base
# (origin/HEAD symref -> origin/main -> main -> origin/master -> master).
_deesc_default_branch() {
  local root="$1" ref
  ref="$(git -C "$root" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"
  if [ -n "$ref" ]; then printf '%s\n' "$ref"; return; fi
  local c
  for c in origin/main main origin/master master; do
    git -C "$root" rev-parse --verify -q "$c" >/dev/null 2>&1 && { printf '%s\n' "$c"; return; }
  done
  printf '%s\n' master
}
_deesc_resolve_base() {
  local root="$1" def
  def="$(_deesc_default_branch "$root")"
  git -C "$root" merge-base HEAD "$def" 2>/dev/null || git -C "$root" rev-parse HEAD 2>/dev/null || true
}

# Total added+deleted lines: committed base..HEAD + any uncommitted working-tree delta.
# DELIBERATELY a 2-source sum, NOT the 3-way union coverage-delta.sh/proof-ledger.sh use
# (base..HEAD + working-tree + --cached): `git diff HEAD` (working tree vs HEAD) already
# folds in the staged delta, so adding `--cached` again would double-count every staged line.
# That double-count is harmless for those two gates (it biases them toward MORE warnings,
# their safe direction); it would bias THIS gate the wrong way (under-nudging a genuinely
# small diff). See docs/specs/SPEC-141-lane-de-escalation.md "Design" for the full note.
_deesc_changed_lines() {
  local root="$1" base="$2" total=0 a d
  while IFS=$'\t' read -r a d _rest; do
    [ "$a" = "-" ] && a=0; [ "$d" = "-" ] && d=0
    total=$((total + a + d))
  done < <(
    { git -C "$root" diff --numstat "$base"..HEAD -- . 2>/dev/null
      git -C "$root" diff --numstat HEAD -- . 2>/dev/null
    } 2>/dev/null
  )
  printf '%s' "$total"
}

# Usage: deescalate <chosen-lane> [--rid <rid>] [--root <path>] [--base <ref>] [--floor <N>]
# ALWAYS exits 0. Prints nothing and writes nothing unless the lane is normal/full AND the
# diff is under the floor (LANE_DEESCALATE_FLOOR env var, default 20 -- see WORKFLOW.md
# "Lane x phase depth matrix" for the rationale). The --rid ledger write is best-effort
# (`|| true`): a write failure can never affect this command's own exit code.
deescalate() {
  local chosen="${1:-}"; shift 2>/dev/null || true
  [ -n "$chosen" ] || {
    echo "usage: lane-classify.sh deescalate <chosen-lane> [--rid <rid>] [--root <path>] [--base <ref>] [--floor <N>]" >&2
    return 64
  }
  local rid="" root="" base="" floor="${LANE_DEESCALATE_FLOOR:-20}"
  local a skip=""
  for a in "$@"; do
    if [ -n "$skip" ]; then
      case "$skip" in rid) rid="$a";; root) root="$a";; base) base="$a";; floor) floor="$a";; esac
      skip=""; continue
    fi
    case "$a" in
      --rid)     skip=rid ;;
      --rid=*)   rid="${a#--rid=}" ;;
      --root)    skip=root ;;
      --root=*)  root="${a#--root=}" ;;
      --base)    skip=base ;;
      --base=*)  base="${a#--base=}" ;;
      --floor)   skip=floor ;;
      --floor=*) floor="${a#--floor=}" ;;
    esac
  done

  # Lane guard: only normal/full can ever be found oversized for a small diff.
  case "$chosen" in normal|full) ;; *) return 0 ;; esac

  [ -n "$root" ] || root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  [ -n "$base" ] || base="$(_deesc_resolve_base "$root")"
  [ -n "$base" ] || return 0   # no resolvable base (e.g. no commits yet) -- nothing to measure

  [[ "$floor" =~ ^[0-9]+$ ]] || floor=20

  local lines; lines="$(_deesc_changed_lines "$root" "$base")"
  [[ "$lines" =~ ^[0-9]+$ ]] || return 0

  if [ "$lines" -lt "$floor" ]; then
    printf 'LANE-DEESCALATE: shipped as %s but the diff stayed tiny-sized (%s changed line(s) < floor=%s); consider `tiny` lane next time\n' \
      "$chosen" "$lines" "$floor"
    if [ -n "$rid" ]; then
      bash "$GATE_LEDGER" action "$rid" "lane-deescalate chosen=$chosen lines=$lines floor=$floor verdict=misroute-tiny" >/dev/null 2>&1 || true
    fi
  fi
  return 0
}

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    classify) _extract_files "$@"; classify_core ${REMAIN[@]+"${REMAIN[@]}"}; printf '%s\n' "$LANE";;
    explain)  _extract_files "$@"; classify_core ${REMAIN[@]+"${REMAIN[@]}"}; printf '%s\nreason: %s\nflags: %s\n' "$LANE" "$REASON" "${FIRED:-none}";;
    check)    _extract_files "$@"; lane_check ${REMAIN[@]+"${REMAIN[@]}"};;
    escalate)   escalate "$@";;
    deescalate) deescalate "$@";;
    lanes)    printf 'tiny\nnormal\nfull\nbug\nbackfill\n';;
    flags)    printf '%s\n' "${_hard_name[@]}" "${_soft_name[@]}";;
    *) echo "usage: lane-classify.sh {classify [--files \"<paths>\"] \"<desc>\"|explain [--files ...] \"<desc>\"|check [--files ...] <chosen-lane> \"<desc>\"|escalate <current-lane> <spec-file>|deescalate <chosen-lane> [--rid <rid>] [--root <path>] [--base <ref>] [--floor <N>]|lanes|flags}" >&2; return 64;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
