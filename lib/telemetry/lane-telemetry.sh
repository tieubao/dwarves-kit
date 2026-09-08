#!/usr/bin/env bash
# lane-telemetry.sh -- the read side of lane effectiveness (SPEC-061).
#
# The kit records run facts in append-only ledgers (lib/gate/gate-ledger.sh -> logs/runs/<rid>.log,
# lane downgrades -> logs/completeness.log) but until SPEC-061 nothing AGGREGATED them, so
# lane misfires died in chat instead of becoming classifier fixes + pins. This is the
# aggregator: pure bash/awk over the existing pipe-delimited logs, no new store, no daemon.
# Advisory: it reports, /kit:retro disposes (Detect, don't dictate).
#
# Usage:
#   lane-telemetry.sh report      -> per-lane + per-type aggregates over every run ledger
#   lane-telemetry.sh misfires    -> the runs where chosen lane != classified lane, plus
#                                    completeness.log LANE-CHECK lines: the feed for keyword fixes
#   lane-telemetry.sh render      -> task-type -> lane -> gate routing diagram + run counts
#                                    (SPEC-099 / ID-150); ASCII, graceful-empty, no new dep
#   lane-telemetry.sh trace <rid> -> one run's full story, formatted for review (SPEC-063)
#
# Line formats consumed (produced by gate-ledger.sh):
#   TS | START | lane=<chosen> classified=<suggested> type=<t> [ctype=<suggested-type>] repo=<r>
#   TS | ACTION | ... escaped-from=<spec-slug> ...   (SPEC-062: a bug run indicting a shipped spec)
#   TS | GATE | <phase> | ran|skipped|override | <reason>
#   TS | OUTCOME | <phase> | end | at=<epoch> caught=<bool> [policy=<close|escalate|continue>]
#                                    (ID-398: `report`'s failure-policy breakdown, when present)
# A run with no START line surfaces as lane "?" (an untracked run is itself a signal).
#
# DWARVES_KIT_LOG_DIR overrides the log root (tests point it at a fixture copy).
set -euo pipefail

KIT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_ROOT="$(cd "$KIT_LIB/.." && pwd)"  # the lib/ dir; cross-subsystem siblings resolve as "$LIB_ROOT/<subsystem>/<file>"
# Durable run-telemetry root (SPEC-097): resolve + one-time additive migration.
# shellcheck source=lib/telemetry/kit-log-dir.sh
source "$KIT_LIB/kit-log-dir.sh" || { echo "FATAL: lib/telemetry/kit-log-dir.sh missing or unreadable" >&2; exit 1; }
kit_migrate_log_dir || true
LOG_DIR="$(kit_resolve_log_dir)"
RUNS_DIR="$LOG_DIR/runs"
COMPLETENESS="$LOG_DIR/completeness.log"

# TTY-gated colors (SPEC-069): plain bytes whenever piped or NO_COLOR is set.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[1;31m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_BOLD=""; C_OFF=""
fi

# Boardless runs (SPEC-069): a run ledger whose repo matches the cwd repo but whose rid
# the board never mentions. Detection only; the board file is the repo's own.
_boardless() {
  local root board myrepo f rid tok matched
  # worktree-safe (review A1): --git-common-dir resolves the MAIN checkout even from a
  # .claude/worktrees/<branch> session, where --show-toplevel's basename is the branch.
  local common; common="$(git rev-parse --git-common-dir 2>/dev/null || true)"
  [ -n "$common" ] || return 0
  root="$(cd "$(dirname "$common")" 2>/dev/null && pwd)" || return 0
  board="$root/_meta/BACKLOG.md"; [ -f "$board" ] || return 0
  myrepo="$(basename "$root")"
  for f in "$RUNS_DIR"/*.log; do
    [ -e "$f" ] || continue
    rid="$(basename "$f" .log)"
    grep -qF -- "repo=$myrepo" "$f" 2>/dev/null || continue
    # On-board if the board names the run by rid (the `[run <rid>]` convention), OR by any
    # ID-NNN / PR #N token the run's own ledger carries (SPEC-073 metric 9a: real board rows
    # key on ID/PR, not the raw rid, so a raw-rid-only match false-flagged tracked runs).
    grep -qF -- "$rid" "$board" 2>/dev/null && continue
    matched=""
    while IFS= read -r tok; do
      [ -n "$tok" ] || continue   # while-read (not for): a "PR #N" token carries a space
      grep -qF -- "$tok" "$board" 2>/dev/null && { matched=1; break; }
    done < <(grep -oE 'ID-[0-9]+|PR #[0-9]+' "$f" 2>/dev/null | sort -u)
    [ -n "$matched" ] || printf '%s\n' "$rid"
  done
}

# Shipped-incomplete (SPEC-069): a shipped run that would NOT pass its own ship-gate, i.e.
# a REQUIRED (measure-twice) gate lacks a ran/override entry. Reads lane from the START line,
# asks gate-ledger check. INTENTIONAL SEAM (review A4): this is lane-telemetry's ONE runtime
# call into gate-ledger, delegated to avoid duplicating the lane->phase map (WORKFLOW matrix
# parsing). It uses `check` (the same required-gate contract hooks/ship-gate.sh enforces), so
# run-lite phases -- e.g. `ui-design` on a non-UI full-lane run -- never trip it (SPEC-073
# metric 9b); a test pin asserts the detector calls `check` so a rename breaks the build.
_shipped_incomplete() {
  local f rid lane
  for f in "$RUNS_DIR"/*.log; do
    [ -e "$f" ] || continue
    grep -q '| GATE | ship | ran' "$f" 2>/dev/null || continue
    rid="$(basename "$f" .log)"
    lane="$( { grep '| START-AMEND |' "$f" 2>/dev/null | tail -1; grep -m1 '| START |' "$f" 2>/dev/null; } | head -1 | grep -oE 'lane=[^ ]+' | head -1 | cut -d= -f2 || true)"
    [ -n "$lane" ] || continue
    bash "$LIB_ROOT/gate/gate-ledger.sh" check "$lane" "$rid" >/dev/null 2>&1 \
      || printf '%s (%s)\n' "$rid" "$lane"
  done
}

# one TSV row per run: rid repo lane classified type ctype ran skip ovr mis tmis ship review first last
_rows() {
  local f rid
  for f in "$RUNS_DIR"/*.log; do
    [ -e "$f" ] || continue
    rid="$(basename "$f" .log)"
    awk -v rid="$rid" '
      BEGIN { FS=" \\| " }
      NR==1 { first=$1 }
      { last=$1 }
      $2=="START" && !started {
        started=1
        n=split($3, kv, " ")
        for (i=1; i<=n; i++) { split(kv[i], p, "="); m[p[1]]=p[2] }
      }
      $2=="START-AMEND" {   # sanctioned correction: last amend wins (SPEC-077)
        started=1   # review F1: an amend also closes the plain-START first-wins window
        n=split($3, kv, " ")
        for (i=1; i<=n; i++) { split(kv[i], p, "="); m[p[1]]=p[2] }
      }
      $2=="GATE" && $4=="ran"      { ran++ }
      $2=="GATE" && $4=="skipped"  { skip++ }
      $2=="GATE" && $4=="override" { ovr++ }
      $2=="GATE" && $3=="review" && $4=="ran" { review=$5; for (i=6; i<=NF; i++) review = review " | " $i }
      $2=="GATE" && $3=="ship"   && $4=="ran" { ship=1 }
      END {
        lane=(m["lane"]==""?"?":m["lane"]); cls=(m["classified"]==""?"?":m["classified"])
        type=(m["type"]==""?"?":m["type"]); repo=(m["repo"]==""?"?":m["repo"])
        ctype=(m["ctype"]==""?"?":m["ctype"])
        mis=(lane!="?" && cls!="?" && lane!=cls) ? 1 : 0
        tmis=(type!="?" && ctype!="?" && type!=ctype) ? 1 : 0
        if (review=="") review="-"
        gsub(/\t/, " ", review)
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%s\t%s\n", \
          rid, repo, lane, cls, type, ctype, ran+0, skip+0, ovr+0, mis, tmis, ship+0, review, first, last
      }' "$f"
  done
}

# _review_agg: review-economics counters over runs that recorded at least one review round
# (ID-392, per docs/briefs/DECISION-BRIEF-review-economics.md). Read-side only, over the
# ledger lines SPEC-061 (`| GATE | review | ran |`) and SPEC-129 (`| OUTCOME | review | end |
# caught=.. dur_s=..`) already write -- no new write verb, no new store. One TSV row per
# reviewed run: <rid>\t<rounds>\t<last-caught>\t<total-review-dur_s>\t<shipped 0|1>.
# `rounds` = count of review GATE ran lines (a rework round-trip is a review that ran again
# after a prior one); `last-caught` = the LAST OUTCOME|review|end caught= value (false = the
# verdict was SHIP, matching the caught= convention commands/review.md already writes);
# dur_s sums EVERY review-phase OUTCOME bracket for the run (cumulative reviewer time across
# rework rounds, not just the last one). A run with no review GATE line is excluded (nothing
# to measure); `caught=""` (a rounds>0 run whose OUTCOME never closed) stays honestly unfirst-pass.
_review_agg() {
  local f rid
  for f in "$RUNS_DIR"/*.log; do
    [ -e "$f" ] || continue
    rid="$(basename "$f" .log)"
    awk -v rid="$rid" '
      BEGIN { FS=" \\| " }
      $2=="GATE" && $3=="review" && $4=="ran" { rounds++ }
      $2=="OUTCOME" && $3=="review" && $4=="end" {
        n=split($5, kv, " ")
        for (i=1; i<=n; i++) { split(kv[i], p, "="); if (p[1]=="caught") caught=p[2]; if (p[1]=="dur_s") dur+=p[2]+0 }
      }
      $2=="GATE" && $3=="ship" && $4=="ran" { ship=1 }
      END {
        if (rounds+0 > 0) printf "%s\t%d\t%s\t%d\t%d\n", rid, rounds+0, (caught==""?"?":caught), dur+0, ship+0
      }' "$f"
  done
}

# "<spec>\t<bug-rid>" per escaped-from ACTION marker (SPEC-062: test-design quality feed)
_escapes() {
  local f rid
  for f in "$RUNS_DIR"/*.log; do
    [ -e "$f" ] || continue
    rid="$(basename "$f" .log)"
    awk -v rid="$rid" 'BEGIN { FS=" \\| " }
      $2=="ACTION" && $3 ~ /escaped-from=/ {
        s=$3; sub(/.*escaped-from=/, "", s); sub(/[ ].*/, "", s)
        printf "%s\t%s\n", s, rid
      }' "$f"
  done
}

# _token_agg: per-lane token aggregates over runs carrying a `| TOKENS |` line (SPEC-110).
# Joins each run's TOKENS totals to its lane via _rows (rid->lane), then per lane emits a TSV:
#   <lane>\t<runs_with_tokens>\t<median_tokens_to_done>\t<cache_eff_pct>
# plus one summary line: __ALL__\t<runs_total>\t<runs_with_tokens>\t<usage_unknown>\t<rework_pct>.
# Median via a portable insertion sort (macOS BWK awk has no asort). Runs with no TOKENS line are
# counted as usage-unknown and EXCLUDED from medians (never zero-filled). No thresholds pinned.
_token_agg() {
  local rows; rows="$(_rows)"
  [ -n "$rows" ] || return 0
  { printf '%s\n' "$rows" | awk 'BEGIN{FS="\t"}{print $1"\t"$3}' | while IFS=$'\t' read -r rid lane; do
      [ -n "$rid" ] || continue
      f="$RUNS_DIR/$rid.log"; [ -f "$f" ] || continue
      awk -F' [|] ' -v lane="$lane" '
        $2=="TOKENS"{ n=split($3,a," "); for(i=1;i<=n;i++){split(a[i],p,"="); s[p[1]]+=p[2]} has=1 }
        END{ if(has) printf "%s\t%d\t%d\t%d\t1\n", lane, s["in"]+s["out"], s["cache_read"], s["in"];
             else printf "%s\t0\t0\t0\t0\n", lane }' "$f"
    done
  } | awk -F'\t' '
    { lane=$1; todone=$2; cr=$3; inp=$4; has=$5; total++
      if(has){ withtok++; cnt[lane]++; vals[lane SUBSEP cnt[lane]]=todone; crsum[lane]+=cr; insum[lane]+=inp;
               allto+=todone; if(lane=="bug") bugto+=todone }
      else unknown++ }
    END{
      for(l in cnt){ m=cnt[l];
        for(i=2;i<=m;i++){ key=vals[l SUBSEP i]; j=i-1;
          while(j>=1 && vals[l SUBSEP j]>key){ vals[l SUBSEP (j+1)]=vals[l SUBSEP j]; j-- } vals[l SUBSEP (j+1)]=key }
        if(m%2==1) med=vals[l SUBSEP ((m+1)/2)]; else med=int((vals[l SUBSEP (m/2)]+vals[l SUBSEP (m/2+1)])/2);
        eff=(insum[l]+crsum[l])>0 ? int(100*crsum[l]/(insum[l]+crsum[l])) : 0;
        printf "%s\t%d\t%d\t%d\n", l, cnt[l], med, eff }
      rework=allto>0 ? int(100*bugto/allto) : 0;
      printf "__ALL__\t%d\t%d\t%d\t%d\n", total, withtok, unknown, rework }'
}

# _policy_agg: failure-policy breakdown (ID-398, docs/patterns/failure-policy.md) over every
# `| OUTCOME | <phase> | end | ... policy=<close|escalate|continue>` line in every run ledger.
# Runs/lines with no policy= are simply not counted (graceful-empty, no fake zeros): a corpus
# with zero policy-carrying lines prints nothing and report() omits the section entirely.
_policy_agg() {
  local f
  for f in "$RUNS_DIR"/*.log; do
    [ -e "$f" ] || continue
    awk -F' [|] ' '
      $2=="OUTCOME" && $4=="end" {
        n=split($5,a," ")
        for(i=1;i<=n;i++){split(a[i],kv,"="); if(kv[1]=="policy" && kv[2]!="") print kv[2]}
      }' "$f"
  done | sort | uniq -c | awk '{printf "%s\t%s\n", $2, $1}'
}

report() {
  [ -d "$RUNS_DIR" ] || { echo "(no runs dir at $RUNS_DIR)"; return 0; }
  local rows; rows="$(_rows)"
  [ -n "$rows" ] || { echo "(no run ledgers)"; return 0; }
  printf '%s\n' "$rows" | awk '
    BEGIN { FS="\t" }
    {
      runs[$3]++; types[$5]++; ran[$3]+=$7; skip[$3]+=$8; ovr[$3]+=$9
      mis[$3]+=$10; ships[$3]+=$12; total++; lmis+=$10; ttmis+=$11; tships+=$12
      if ($3=="?") untracked++
    }
    END {
      printf "runs: %d   lane-misrouted: %d   type-misrouted: %d   shipped: %d   untracked (no START): %d\n\n", \
        total, lmis, ttmis, tships, untracked+0
      printf "%-12s %5s %5s %6s %5s %5s %6s\n", "lane", "runs", "mis", "gates", "skip", "ovr", "ships"
      for (l in runs) printf "%-12s %5d %5d %6d %5d %5d %6d\n", l, runs[l], mis[l], ran[l], skip[l], ovr[l], ships[l]
      printf "\n%-14s %5s\n", "type", "runs"
      for (t in types) printf "%-14s %5d\n", t, types[t]
    }'
  local bl; bl="$(_boardless | grep -c . || true)"
  [ "${bl:-0}" -gt 0 ] && printf '%sboardless runs (ledgered but never on the board): %s%s\n' "$C_RED" "$bl" "$C_OFF"
  local esc; esc="$(_escapes)"
  if [ -n "$esc" ]; then
    echo ""
    echo "escaped defects (bug runs tracing to a shipped spec's test plan):"
    printf '%s\n' "$esc" | awk 'BEGIN{FS="\t"} { printf "  %s <- %s\n", $1, $2 }'
  fi
  echo ""
  echo "runs (rid  repo  lane<-classified  type<-ctype  review  first..last):"
  printf '%s\n' "$rows" | awk 'BEGIN{FS="\t"} { printf "  %-28s %-12s %s<-%s  %s<-%s  %-24s %s .. %s\n", $1, $2, $3, $4, $5, $6, $13, $14, $15 }'

  # Token efficiency (SPEC-110): only over runs carrying a TOKENS line; a no-capture run is an
  # honest usage=? and is EXCLUDED from medians (never a fake zero). No thresholds until a
  # ~5-run baseline forms (the SPEC-073 pattern).
  local tagg; tagg="$(_token_agg)"
  echo ""
  if [ -n "$tagg" ]; then
    local summ rtot rtok runk rework
    summ="$(printf '%s\n' "$tagg" | awk -F'\t' '$1=="__ALL__"')"
    rtot=$(printf '%s' "$summ" | cut -f2); rtok=$(printf '%s' "$summ" | cut -f3)
    runk=$(printf '%s' "$summ" | cut -f4); rework=$(printf '%s' "$summ" | cut -f5)
    printf '  token efficiency (%s/%s runs captured; %s usage=? [no stream capture]):\n' "${rtok:-0}" "${rtot:-0}" "${runk:-0}"
    if [ "${rtok:-0}" -gt 0 ]; then
      printf '    %-12s %10s %8s\n' "lane" "med-tok" "cache"
      printf '%s\n' "$tagg" | awk -F'\t' '$1!="__ALL__"{ printf "    %-12s %10d %7d%%\n", $1, $3, $4 }' | sort
      printf '    rework share (bug-lane tokens / total, run-granularity v1): %s%%\n' "${rework:-0}"
    fi
    printf '    (no thresholds pinned; baseline forms after ~5 captured runs)\n'
  fi

  # Failure-policy breakdown (ID-398, docs/patterns/failure-policy.md): only over OUTCOME
  # end lines that carried a policy= field; silent when none did (graceful-empty).
  local pagg; pagg="$(_policy_agg)"
  if [ -n "$pagg" ]; then
    echo ""
    echo "  failure policy (close/escalate/continue):"
    printf '%s\n' "$pagg" | awk -F'\t' '{ printf "    %-10s %5d\n", $1, $2 }'
  fi

  # Review economics (ID-392, DECISION-BRIEF-review-economics.md): first-pass acceptance,
  # rework round-trips, reviewer minutes, escape rate. Same read-side-only shape as the token
  # section above -- over the review GATE/OUTCOME lines already written, no new store. Time-
  # to-merge is not duplicated here: the per-run first..last window above already carries it
  # (BSD awk has no mktime, the same portability limit SPEC-061 named for duration math).
  local ragg; ragg="$(_review_agg)"
  echo ""
  if [ -n "$ragg" ]; then
    printf '%s\n' "$ragg" | awk -F'\t' '
      { total++; rounds=$2; caught=$3; dur=$4
        if (rounds==1 && caught=="false") fp++
        if (rounds>1) rework++
        roundsum+=rounds; sumdur+=dur }
      END {
        printf "  review economics (%d reviewed run%s):\n", total, (total==1?"":"s")
        printf "    first-pass acceptance: %d/%d (%d%%)\n", fp+0, total, int(100*fp/total)
        printf "    rework round-trips: avg %.1f review round(s)/run; %d run(s) needed >1 round\n", roundsum/total, rework+0
        printf "    reviewer time: %.1f min (sum of review-phase OUTCOME brackets)\n", sumdur/60
      }'
  else
    echo "  review economics: (no review rounds recorded yet)"
  fi
  local shipped_n esc_n
  shipped_n="$(printf '%s\n' "$rows" | awk -F'\t' '{s+=$12} END{print s+0}')"
  esc_n="$(printf '%s\n' "$esc" | grep -c . || true)"
  if [ "${shipped_n:-0}" -gt 0 ]; then
    printf '    escape rate: %d/%d shipped run(s) later traced an escaped defect (%d%%)\n' \
      "${esc_n:-0}" "$shipped_n" "$((100 * ${esc_n:-0} / shipped_n))"
  fi
}

misfires() {
  local any=0
  if [ -d "$RUNS_DIR" ]; then
    local lines
    lines="$(_rows | awk 'BEGIN{FS="\t"} $10==1 { printf "  %s: chosen=%s classified=%s (type=%s repo=%s)\n", $1, $3, $4, $5, $2 }')"
    if [ -n "$lines" ]; then
      echo "routing misfires (chosen lane != classified):"
      printf '%s\n' "$lines"; any=1
    fi
    lines="$(_rows | awk 'BEGIN{FS="\t"} $11==1 { printf "  %s: type=%s classified-type=%s (lane=%s repo=%s)\n", $1, $5, $6, $3, $2 }')"
    if [ -n "$lines" ]; then
      echo "type misfires (chosen type != classified):"
      printf '%s\n' "$lines"; any=1
    fi
  fi
  local bl_list; bl_list="$(_boardless)"
  if [ -n "$bl_list" ]; then
    echo "boardless runs (work that never touched the board):"
    printf '%s\n' "$bl_list" | sed 's/^/  /'; any=1
  fi
  local si_list; si_list="$(_shipped_incomplete)"
  if [ -n "$si_list" ]; then
    echo "shipped-incomplete runs (a ship gate over un-disposed phases):"
    printf '%s\n' "$si_list" | sed 's/^/  /'; any=1
  fi
  if [ -f "$COMPLETENESS" ] && grep -q 'LANE-CHECK' "$COMPLETENESS" 2>/dev/null; then
    echo "floor-check downgrades (completeness.log):"
    grep 'LANE-CHECK' "$COMPLETENESS" | sed 's/^/  /'; any=1
  fi
  [ "$any" -eq 1 ] || echo "(no misfires recorded)"
  return 0
}

# trace: one run's ledger rendered as a reviewable story (SPEC-063): routing header with
# misfire flags, then the humanized timeline (gates with state + reason, actions, with
# escaped-from indictments called out).
trace() {
  local rid="${1:-}"; [ -n "$rid" ] || { echo "usage: trace <rid>" >&2; return 64; }
  local f="$RUNS_DIR/$rid.log"
  [ -f "$f" ] || { echo "(no ledger for '$rid' at $f)" >&2; return 1; }
  awk -v rid="$rid" -v red="$C_RED" -v off="$C_OFF" '
    BEGIN { FS=" \\| " }
    {
      ts=$1; sub(/T/, " ", ts); sub(/Z$/, "", ts)
      if (first=="") first=$1
      last=$1
    }
    $2=="START" {
      starts++
      if (m["lane"] != "") next   # first plain START wins; later plain ones flag MULTI-START
      n=split($3, kv, " ")
      for (i=1; i<=n; i++) { split(kv[i], p, "="); m[p[1]]=p[2] }
      next
    }
    $2=="START-AMEND" {   # sanctioned correction (SPEC-077): last amend wins, no MULTI-START flag
      amended++
      n=split($3, kv, " ")
      for (i=1; i<=n; i++) { split(kv[i], p, "="); m[p[1]]=p[2] }
      next
    }
    $2=="GATE" {
      reason=$5; for (i=6; i<=NF; i++) reason = reason " | " $i
      lines[++ln] = sprintf("  %s  %-10s %-9s %s", ts, $3, $4, reason)
      next
    }
    $2=="ACTION" {
      reason=$3; for (i=4; i<=NF; i++) reason = reason " | " $i
      flag=""
      if (reason ~ /escaped-from=/) flag="  << indicts a shipped spec test plan"
      lines[++ln] = sprintf("  %s  %-10s %-9s %s%s", ts, "action", "-", reason, flag)
      next
    }
    { lines[++ln] = sprintf("  %s  %s", ts, $0) }
    END {
      lane=(m["lane"]==""?"?":m["lane"]); cls=(m["classified"]==""?"?":m["classified"])
      type=(m["type"]==""?"?":m["type"]); ctype=(m["ctype"]==""?"?":m["ctype"])
      repo=(m["repo"]==""?"?":m["repo"])
      lflag=(lane!="?" && cls!="?" && lane!=cls) ? "  " red "<< LANE MISFIRE" off : ""
      tflag=(type!="?" && ctype!="?" && type!=ctype) ? "  " red "<< TYPE MISFIRE" off : ""
      msflag=(starts>1 ? sprintf("   << MULTI-START (n=%d; %s)", starts, (amended>0 ? "lane from last amend" : "first wins")) : "")
      printf "run: %s   repo: %s%s%s\n", rid, repo, msflag, (amended>0 ? sprintf("   (amended x%d, last wins)", amended) : "")
      printf "  lane: %s (classified: %s)%s\n", lane, cls, lflag
      printf "  type: %s (classified: %s)%s\n", type, ctype, tflag
      printf "  window: %s .. %s\n\n", first, last
      for (i=1; i<=ln; i++) print lines[i]
    }' "$f"
}

# render: the task-type -> lane -> gate routing DIAGRAM with run counts over the durable
# ledgers (SPEC-099 / ID-150). ASCII + markdown only, no new dependency, renders over ssh.
# Reuses _rows() (no second parser); degrades gracefully to an honest "no runs recorded"
# on an empty/fresh install rather than crashing or printing fake zeros.
render() {
  # SPEC-110: a leading --mermaid/mermaid selects the mermaid output MODE, consumed BEFORE the
  # substring-filter positional so `render [filter]` (ASCII) stays byte-compatible.
  local mode=ascii
  case "${1:-}" in --mermaid|mermaid) mode=mermaid; shift ;; esac
  local filter="${1:-}"   # optional: keep only runs whose lane OR type contains this string
  if [ ! -d "$RUNS_DIR" ]; then
    echo "Lane routing: no runs recorded yet (no ledger dir at $RUNS_DIR)."
    return 0
  fi
  local rows; rows="$(_rows)"
  if [ -n "$filter" ]; then
    # LITERAL substring match (index), not a regex (~), so a filter like "." or "[" is a
    # plain string, never an awk regex that over-matches or crashes (review robustness).
    rows="$(printf '%s\n' "$rows" | awk -v f="$filter" 'BEGIN{FS="\t"} index($3,f)>0 || index($5,f)>0')"
  fi
  if [ -z "$rows" ]; then
    [ -n "$filter" ] && echo "Lane routing: no runs match '$filter'." || echo "Lane routing: no runs recorded yet."
    return 0
  fi

  # SPEC-110 mermaid mode: a GitHub-native task-type -> lane graph, each lane node annotated with
  # its median tokens-to-done (usage=? when no run in that lane was captured). Per lane/per run,
  # NOT per-phase (usage is per-session). Additive: the ASCII mode below is untouched.
  if [ "$mode" = mermaid ]; then
    # Per-lane medians as a SINGLE-LINE `lane=med;` map (macOS BWK awk rejects a newline in a -v
    # string, so tagg's multi-line form cannot be passed directly).
    local medmap; medmap="$(_token_agg | awk -F'\t' '$1!="__ALL__" && $1!=""{printf "%s=%s;", $1, $3}')"
    echo "Lane routing (mermaid; lane nodes annotated with median tokens-to-done):"
    echo '```mermaid'
    echo 'graph TD'
    printf '%s\n' "$rows" | awk -F'\t' -v medmap="$medmap" '
      BEGIN{ n=split(medmap,pairs,";"); for(i=1;i<=n;i++){ if(pairs[i]!=""){ split(pairs[i],kv,"="); med[kv[1]]=kv[2] } } }
      function nid(s){ gsub(/[^a-zA-Z0-9]/,"_",s); return s }   # mermaid IDs: alnum + underscore only
      { lanes[$3]=1; edge[$5 SUBSEP $3]=1 }
      END{
        for(l in lanes){ lab=(l in med)? l " ~" med[l] " tok" : l " (usage=?)";
          printf "  lane_%s[\"%s\"]\n", nid(l), lab }
        for(e in edge){ split(e,a,SUBSEP); printf "  type_%s([\"%s\"]) --> lane_%s\n", nid(a[1]), a[1], nid(a[2]) }
      }'
    echo '```'
    return 0
  fi

  local n first last
  n="$(printf '%s\n' "$rows" | grep -c .)"
  first="$(printf '%s\n' "$rows" | awk 'BEGIN{FS="\t"}{print $14}' | sort | head -1)"
  last="$(printf '%s\n' "$rows" | awk 'BEGIN{FS="\t"}{print $15}' | sort | tail -1)"
  local runword="runs"; [ "$n" = "1" ] && runword="run"
  printf '%sLane routing%s  (%s %s%s, window %s .. %s)\n\n' "$C_BOLD" "$C_OFF" "$n" "$runword" "${filter:+, filter=$filter}" "$first" "$last"

  # type -> lane aggregate table (sorted)
  printf '  %-16s     %-9s %5s  %-13s %6s\n' "task-type" "lane" "runs" "gates r/s/o" "ships"
  printf '  %s\n' "-------------------------------------------------------------"
  printf '%s\n' "$rows" | awk 'BEGIN{FS="\t"}
    { k=$5 SUBSEP $3; cnt[k]++; ran[k]+=$7; skip[k]+=$8; ovr[k]+=$9; ship[k]+=$12 }
    END { for (k in cnt) { split(k,a,SUBSEP);
      printf "  %-16s ->  %-9s %5d  %-13s %6d\n", a[1], a[2], cnt[k], ran[k]"/"skip[k]"/"ovr[k], ship[k] } }' \
    | sort

  # ASCII flow: for each lane, the task-types that routed into it + run count
  echo ""
  printf '  routing flow (task-type -> lane -> gates):\n\n'
  printf '%s\n' "$rows" | awk 'BEGIN{FS="\t"}
    { laneruns[$3]++
      if (index(SUBSEP seen[$3] SUBSEP, SUBSEP $5 SUBSEP)==0) {
        types[$3]=types[$3] (types[$3]?", ":"") $5; seen[$3]=seen[$3] SUBSEP $5 } }
    END { for (l in laneruns) printf "    %-40s --> %-9s (%d run%s)\n",
            substr(types[l],1,40), l, laneruns[l], (laneruns[l]==1?"":"s") }' \
    | sort -t'>' -k2

  # gate coverage across the (possibly filtered) runs: per phase, how many runs recorded it ran
  echo ""
  printf '  gate coverage (runs recording each phase as ran):\n'
  local files=()
  local rid
  while IFS= read -r rid; do [ -n "$rid" ] && [ -f "$RUNS_DIR/$rid.log" ] && files+=("$RUNS_DIR/$rid.log"); done \
    < <(printf '%s\n' "$rows" | awk 'BEGIN{FS="\t"}{print $1}')
  local cov=""
  # count DISTINCT runs recording each phase (dedupe per rid=FILENAME + phase), not raw
  # lines: a phase re-recorded within one run (a retry) must not inflate past the run count.
  [ "${#files[@]}" -gt 0 ] && cov="$(awk -F' [|] ' '$2=="GATE" && $4=="ran"{ gsub(/^ | $/,"",$3);
      k=FILENAME SUBSEP $3; if (!(k in seen)) { seen[k]=1; c[$3]++ } }
    END{ for (p in c) printf "    %-16s %d\n", p, c[p] }' "${files[@]}" 2>/dev/null | sort -k2 -rn)"
  [ -n "$cov" ] && printf '%s\n' "$cov" || echo "    (none)"

  echo ""
  printf '  legend: gates r/s/o = ran / skipped / override summed over those runs;\n'
  printf '          "?" lane/type = runs with no START line (untracked).\n'
  return 0
}

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    report)   report ;;
    misfires) misfires ;;
    render)   render "$@" ;;
    trace)    trace "$@" ;;
    *) echo "usage: lane-telemetry.sh {report|misfires|render|trace <rid>}" >&2; return 64 ;;
  esac
}

main "$@"
