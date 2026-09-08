#!/usr/bin/env bash
# gate-ledger.sh -- lane-aware gate ledger + action log + ship-completeness check.
#
# The single source for "which gates a lane requires" is the WORKFLOW.md lane×phase
# matrix; this parses it at runtime (no second copy), mirroring lib/gate/dispatch-gate.sh's
# hands-off extraction. A matrix cell of `measure-twice` => the gate is REQUIRED for
# that lane. Records are append-only, operator-readable, and redacted (no command
# bodies). See docs/decisions/0024-gate-ledger-and-ship-enforcement.md.
#
# Subcommands:
#   required <lane>                     print the lane's required (measure-twice) gate keys
#   start    <rid> <chosen-lane> <classified-lane> <chosen-type> [classified-type] [repo]   record routing facts (SPEC-061/062)
#   start --amend <same args>           sanctioned correction; readers take the last AMEND (SPEC-077)
#   record   <rid> <phase> <ran|skipped> [reason]   append a gate decision (a `grill`+`skipped`
#                                       reason MUST start with reason=<home-turf|density-low|
#                                       operator-wave>, SPEC-138; every other phase/state is free text)
#   action   <rid> <text>              append an action-log line
#   debt     <rid> significance=<low|high> worthiness=<low|high> verdict=<tap|wave|not-significant> [reason=...]
#                                       append an understanding-debt verdict (ADR-0031, SPEC-123);
#                                       additive marker, ignored by check()/override()/descent()
#   debt-response <rid> <engage|defer|wave> [reason]  append the HUMAN's ★-tap choice (ADR-0031 §3,
#                                       SG-04); additive `| DEBT |` marker, same ignore rules as debt
#   outcome  <rid> <phase> <start|end> [caught=<true|false>] [policy=<close|escalate|continue>]
#                                       record a gate's OUTCOME as an ADDITIVE marker (SPEC-129):
#                                       a start/end timing bracket (duration derivable) +
#                                       caught=<bool> + an optional named failure-policy (ID-398,
#                                       docs/patterns/failure-policy.md); ignored by
#                                       check()/override()/descent()/_rows() (key on $2==GATE)
#   outcome-read <rid> [phase]         read the outcome + duration back for a rid (round-trip)
#   config   <rid> [model=] [effort=] [kit_version=] [modules=] [lane=] [task_type=] [suite_hash=] [session_id=] [phase=]
#                                       record a run's config dimensions as an ADDITIVE marker
#                                       (ID-420, bench-plane prerequisite); repeat with a
#                                       different phase= for per-stage model stamping
#   override <rid> <phase> <reason>    record a human override for a gate
#   check    <lane> <rid>              exit 0 if every required gate has a ran|override entry; else 1
#   show     <rid>                     print the run's ledger
#   plan     <lane>                    the lane's ordered phase checklist (SPEC-063)
#   progress <rid> <lane>              plan x ledger -> "step k/n" + checklist (SPEC-063)
#   rid                                the canonical run id for the cwd: branch slug (SPEC-070)
#   descent  <rid> <lane>              plan-order timeline check; violations detected, never blocked (SPEC-076)
#   history  [--lane L] [--json]       one row per run: lane, repo, ran/skipped counts (ID-444)
#   report   --period week|month [--lane L]   markdown table of runs in the window + totals (ID-445)
set -euo pipefail

GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_ROOT="$(cd "$GATE_DIR/.." && pwd)"  # the lib/ dir; cross-subsystem siblings resolve as "$LIB_ROOT/<subsystem>/<file>"
KIT_ROOT="$(cd "$GATE_DIR/../.." && pwd)"  # repo root = two levels above lib/<subsystem>/
WORKFLOW="${GATE_LEDGER_WORKFLOW:-$KIT_ROOT/docs/WORKFLOW.md}"  # bulk lives in docs/ (SPEC-185); root WORKFLOW.md is a thin stub
# Durable run-telemetry root (SPEC-097): resolve + one-time additive migration out of the
# ~/.claude/dwarves-kit reinstall blast zone. One resolver, no hard-coded default here.
# shellcheck source=lib/telemetry/kit-log-dir.sh
source "$LIB_ROOT/telemetry/kit-log-dir.sh" || { echo "FATAL: lib/telemetry/kit-log-dir.sh missing or unreadable" >&2; exit 1; }
# The ONE append substrate (SPEC-182): row-append + root-location live here, not re-implemented
# below. gate-ledger's writes route through ledger_append; reads still use ledger_file()'s path.
# shellcheck source=lib/ledger/ledger.sh
source "$LIB_ROOT/ledger/ledger.sh" || { echo "FATAL: lib/ledger/ledger.sh missing or unreadable" >&2; exit 1; }
kit_migrate_log_dir || true
LOG_DIR="$(kit_resolve_log_dir)" || exit 1
RUNS_DIR="$LOG_DIR/runs"

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
# Machine-readable epoch seconds for duration math (SPEC-129). `date +%s` is identical on
# GNU (ubuntu) and BSD (macOS); we deliberately do NOT parse the ISO8601 now() back to epoch
# (that is the `date -d` vs `date -jf` portability trap the kit CI fails on). Duration is a
# pure integer subtraction of two epochs carried explicitly on the OUTCOME start/end lines.
now_epoch() { date +%s; }

# Collapse newlines/carriage-returns in operator/LLM-supplied free text to spaces before it
# is written to the append-only ledger (security review B1). Without this, a reason/action
# containing an embedded newline splits into extra pipe-delimited lines that readers
# (check/progress/descent + the SPEC-097 override guard) cannot distinguish from real GATE
# lines -- a prompt-injection -> ledger-forgery -> gate-bypass chain (a forged `| ran |`
# line makes check() believe a required gate ran). One ledger line per call, always.
oneline() { printf '%s' "${*:-}" | tr '\n\r' '  '; }

# TTY-gated colors (SPEC-069): escape codes emit ONLY on an interactive stdout with
# NO_COLOR unset, so every piped consumer (300+ test pins, scripts) sees plain bytes.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_DONE=$'\033[32m'; C_CUR=$'\033[1;33m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_DONE=""; C_CUR=""; C_DIM=""; C_BOLD=""; C_OFF=""
fi
runid() { printf '%s' "$1" | tr '/ ' '--' | tr -cd '[:alnum:]._-'; }
ledger_file() {
  # Guard (SPEC-070 review S1): a slug of only special chars normalizes to "",
  # which would silently merge audit trails into a hidden RUNS_DIR/.log.
  local safe; safe="$(runid "$1")"
  [ -n "$safe" ] || { echo "ledger_file: rid '$1' normalizes to an empty filename" >&2; return 1; }
  printf '%s/%s.log' "$RUNS_DIR" "$safe"
}

# Append ONE line to this rid's run ledger, ROUTED through the substrate (SPEC-182): the
# substrate owns "compute root + mkdir + append", so gate-ledger no longer re-implements it.
# The stream is always `runs/<safe>.log`, the same file ledger_file() names for reads.
append_run_line() {
  local safe; safe="$(runid "$1")"
  [ -n "$safe" ] || { echo "append_run_line: rid '$1' normalizes to an empty filename" >&2; return 1; }
  ledger_append "runs/$safe.log" "$2"
}

# Stable key for a phase name: drop "(...)", lowercase, spaces -> dashes.
# "Design (opt-in)"->design, "Design critique (opt-in)"->design-critique,
# "Test plan (opt-in)"->test-plan, "Debug (off-cycle)"->debug, "UI design"->ui-design.
normalize_phase() {
  # collapse newlines first (security review, defense-in-depth): a phase arg with an embedded
  # newline would otherwise emit a second physical ledger line. Unreachable today (all callers
  # pass a hardcoded phase literal), but the guard is one tr and matches oneline()'s intent.
  local p
  p="$(printf '%s' "$1" | tr '\n\r' '  ' | sed -E 's/\([^)]*\)//g' | tr 'A-Z' 'a-z' \
    | sed -E 's/^[[:space:]]+|[[:space:]]+$//g; s/[[:space:]]+/-/g')"
  # Alias command-name drift: agents recording ad-hoc sometimes use the command name
  # ("execute") instead of the matrix gate it owns ("build"), leaving check() blind to a
  # build that ran (seen 2026-07-21, finance-warehouse run). "verify" is NOT aliased to
  # "review": /kit:verify (right-arm re-run) and /kit:review (code review) are distinct gates.
  # "battery" is /kit:battery's own beat: distinct attribution in stats, but it satisfies
  # the same review gate the ship-gate checks (it IS the fresh-context review).
  case "$p" in execute) p=build ;; battery) p=review ;; esac
  printf '%s' "$p"
}

# print "<rawphase>\t<cell>" for each matrix row under the given lane column.
# Empty output => the lane column was not found (unknown lane).
matrix_for_lane() {
  awk -v lane="$1" '
    /^## Lane.*depth matrix/ {inmx=1; next}
    inmx && /^## / {exit}
    inmx && /^\| *Phase *\|/ {
      n=split($0, h, "|");
      for (i=1;i<=n;i++){gsub(/^ +| +$/,"",h[i]); if(h[i]==lane) col=i}
      next
    }
    inmx && col>0 && /^\|/ {
      if ($0 ~ /^\| *-+/) next;
      split($0, c, "|");
      ph=c[2]; gsub(/^ +| +$/,"",ph);
      cell=c[col]; gsub(/^ +| +$/,"",cell);
      if (ph!="" && ph!="Phase") print ph "\t" cell;
    }
  ' "$WORKFLOW"
}

required() {
  local lane="${1:-}"; [ -n "$lane" ] || { echo "usage: required <lane>" >&2; return 64; }
  local rows ph cell
  rows="$(matrix_for_lane "$lane")"
  [ -n "$rows" ] || { echo "unknown lane '$lane' (not a column in the WORKFLOW matrix)" >&2; return 1; }
  while IFS=$'\t' read -r ph cell; do
    [ "$cell" = "measure-twice" ] && printf '%s\n' "$(normalize_phase "$ph")"
  done <<< "$rows"
  return 0
}

# START records the run's routing facts for lane telemetry (SPEC-061): the lane the
# operator chose, the classifier's suggestion, the work type, and the repo. One line per
# run, written at assign/start time; lib/telemetry/lane-telemetry.sh aggregates these read-side.
start() {
  # --amend (SPEC-077 / ID-072): a sanctioned correction. Writes START-AMEND; every
  # reader takes the LAST START-AMEND, else the FIRST plain START. Append-only stands.
  local marker=START uprefix=start
  if [ "${1:-}" = "--amend" ]; then marker=START-AMEND; uprefix="start --amend"; shift; fi
  local rid="${1:-}" lane="${2:-}" classified="${3:-}" type="${4:-}" ctype="${5:-}" repo="${6:-}"
  if [ -z "$rid" ] || [ -z "$lane" ] || [ -z "$classified" ] || [ -z "$type" ]; then
    echo "usage: $uprefix <rid> <chosen-lane> <classified-lane> <chosen-type> [classified-type] [repo]" >&2; return 64
  fi
  [ -n "$repo" ] || repo="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")"
  # the KV blob is space-split read-side; a space in any value corrupts the parse
  repo="$(printf '%s' "$repo" | tr ' ' '-')"
  type="$(printf '%s' "$type" | tr ' ' '-')"
  ctype="$(printf '%s' "$ctype" | tr ' ' '-')"
  lane="$(printf '%s' "$lane" | tr ' ' '-')"
  classified="$(printf '%s' "$classified" | tr ' ' '-')"
  mkdir -p "$RUNS_DIR"
  local line
  line="$(printf '%s | %s | lane=%s classified=%s type=%s' "$(now)" "$marker" "$lane" "$classified" "$type")"
  [ -n "$ctype" ] && line="$line ctype=$ctype"
  append_run_line "$rid" "$(printf '%s repo=%s' "$line" "$repo")"
}

record() {
  local rid="${1:-}" raw="${2:-}" state="${3:-}"; shift 3 2>/dev/null || { echo "usage: record <rid> <phase> <ran|skipped> [reason]" >&2; return 64; }
  case "$state" in ran|skipped) ;; *) echo "state must be ran|skipped" >&2; return 64;; esac
  local phase; phase="$(normalize_phase "$raw")"
  local reason; reason="$(oneline "$@")"
  # Grill unknown-density conditioning (SPEC-138): a grill SKIP must carry a reason= token from
  # the closed enum below, as the FIRST word of its reason text, so the kit's least-used,
  # highest-leverage gate (82% skipped over a 63-run probe) is auditable, not free text. The
  # sibling harness-observatory `kit_gates` reader treats this field as opaque text either way
  # (DECISIONS.md "01-kit-gates-lens"); the enum is enforced HERE, at write time, so a malformed
  # skip is refused before it ever lands, not caught later at analysis time. Every other
  # (phase, state) combination -- including grill+ran, and skipped on any OTHER phase -- is
  # behaviorally identical to before this change.
  if [ "$phase" = "grill" ] && [ "$state" = "skipped" ]; then
    # CLOSED enum, not a prefix match (security review MEDIUM finding): the bare token
    # ("reason=home-turf") or the token followed by its documented ":" delimiter
    # ("reason=home-turf: <why>") both match; a look-alike like "reason=home-turfish-nonsense"
    # does NOT, since it is neither exactly the token nor token+":".
    case "$reason" in
      reason=home-turf|reason=home-turf:*) ;;
      reason=density-low|reason=density-low:*) ;;
      reason=operator-wave|reason=operator-wave:*) ;;
      *)
        echo "record: a grill skip needs reason=<home-turf|density-low|operator-wave> (bare, or followed by ':') as its reason (got: '${reason:-<empty>}')" >&2
        return 64
        ;;
    esac
  fi
  mkdir -p "$RUNS_DIR"
  append_run_line "$rid" "$(printf '%s | GATE | %s | %s | %s' "$(now)" "$phase" "$state" "$reason")"
}

action() {
  local rid="${1:-}"; shift 2>/dev/null || { echo "usage: action <rid> <text>" >&2; return 64; }
  mkdir -p "$RUNS_DIR"
  append_run_line "$rid" "$(printf '%s | ACTION | %s' "$(now)" "$(oneline "$@")")"
}

# tokens: record a run's token usage as an ADDITIVE marker (SPEC-110). Emits a `| TOKENS |` line
# that check()/override()/descent()/_rows() all ignore (they key on $2=="GATE"|START|ACTION), so a
# token line can never fake a gate. Values are sanitized to non-negative integers.
#
# `phase=` (rung-4 redteam cost checkpoint) is an OPTIONAL, purely additive key: when given, the
# TOKENS line is scoped to one gate phase (e.g. `phase=redteam`) instead of the whole rid. The
# `kit_gates` reader (lib/stats read_kit_gates, dwarves-kit lib/stats) pairs a phase-scoped TOKENS
# line to its GATE row the SAME way it already pairs an `| OUTCOME |` bracket: FIFO per (rid,
# phase), so a `cost=` value lands on the matching gate row instead of only the rid-wide total
# lane-telemetry's `_token_agg` already reads. Omitting `phase=` reproduces the exact pre-existing
# line shape (no behavior change for any existing caller).
# Usage: tokens <rid> in=N out=N cache_read=N cache_create=N [cost=N] [phase=P]
tokens() {
  local rid="${1:-}"; shift 2>/dev/null || { echo "usage: tokens <rid> in=N out=N cache_read=N cache_create=N [cost=N] [phase=P]" >&2; return 64; }
  [ -n "$rid" ] || { echo "tokens requires a rid" >&2; return 64; }
  local intok=0 outtok=0 cread=0 ccreate=0 cost="" phase="" kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in
      in)           intok="$(printf '%s' "$v" | tr -cd '0-9')"; intok="${intok:-0}" ;;
      out)          outtok="$(printf '%s' "$v" | tr -cd '0-9')"; outtok="${outtok:-0}" ;;
      cache_read)   cread="$(printf '%s' "$v" | tr -cd '0-9')"; cread="${cread:-0}" ;;
      cache_create) ccreate="$(printf '%s' "$v" | tr -cd '0-9')"; ccreate="${ccreate:-0}" ;;
      cost)         cost="$(printf '%s' "$v" | tr -cd '0-9.')" ;;   # decimal dollars: digits + dot(s); display-only, never summed
      phase)        phase="$(normalize_phase "$v")" ;;             # same normalizer the GATE/OUTCOME phase key uses
    esac
  done
  mkdir -p "$RUNS_DIR"
  local line; line="$(printf 'in=%s out=%s cache_read=%s cache_create=%s' "$intok" "$outtok" "$cread" "$ccreate")"
  [ -n "$cost" ] && line="$line cost=$cost"
  [ -n "$phase" ] && line="$line phase=$phase"
  append_run_line "$rid" "$(printf '%s | TOKENS | %s' "$(now)" "$line")"
}

# debt: record an understanding-debt verdict as an ADDITIVE marker (ADR-0031, SPEC-123),
# the exact `| TOKENS |` shape reused for a second concern: a `| DEBT |` line that check()/
# override()/descent()/_rows() all ignore (they key on $2=="GATE"|START|ACTION), so a debt
# line can never fake a gate or be mistaken for one. Written by `lib/classify/significance-classify.sh
# record` (the worker side, ADR-0032 section 3: "the worker session writes the significance/
# worthiness marker"); the human-facing ★-tap nudge (engage/defer/wave) is a LATER, SEPARATE
# `| DEBT |` line appended by the conductor-side nudge (SG-04) -- this command only ever
# writes the classifier's verdict, never a human response.
#
# response=<engage|defer|wave> (SPEC-126, understanding-gate SG-05): an OPTIONAL additive key,
# the three-way human disposition ADR-0031's Refinement point 3 names. First written by
# `lib/learn/weekend-batch.sh mark-paid` (response=engage, closing the loop so a paid item is never
# re-collected); SG-04's future ★-tap nudge is a second, later caller of the SAME field --
# there is exactly one place a human response is recorded, never two.
# Usage: debt <rid> significance=<low|high> worthiness=<low|high> verdict=<tap|wave|not-significant> [response=<engage|defer|wave>] [reason=...]
debt() {
  local rid="${1:-}"; shift 2>/dev/null || { echo "usage: debt <rid> significance=<low|high> worthiness=<low|high> verdict=<tap|wave|not-significant> [response=<engage|defer|wave>] [reason=...]" >&2; return 64; }
  [ -n "$rid" ] || { echo "debt requires a rid" >&2; return 64; }
  local sig="" wor="" verdict="" response="" reason="" kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in
      significance) sig="$v" ;;
      worthiness)   wor="$v" ;;
      verdict)      verdict="$v" ;;
      response)     response="$v" ;;
      # Security LOW (TIER-4 close): a reason value containing a literal "=" can smuggle a
      # fake control token (e.g. "reason=response=engage") past a naive downstream KV-parse
      # (weekend-batch.sh's _kv, which greps the whole line). Belt-and-suspenders alongside
      # the struct-prefix cut in weekend-batch.sh: neuter it here at the source by replacing
      # "=" with ":" (matches the pre-existing "sig:full-lane" reason-text convention), so a
      # reason can never contain a real KEY=value control token.
      reason)       reason="$(oneline "$v" | tr '=' ':')" ;;
    esac
  done
  case "$sig" in low|high) ;; *) echo "debt: significance must be low|high (got '$sig')" >&2; return 64;; esac
  case "$wor" in low|high) ;; *) echo "debt: worthiness must be low|high (got '$wor')" >&2; return 64;; esac
  case "$verdict" in tap|wave|not-significant) ;; *) echo "debt: verdict must be tap|wave|not-significant (got '$verdict')" >&2; return 64;; esac
  if [ -n "$response" ]; then
    case "$response" in engage|defer|wave) ;; *) echo "debt: response must be engage|defer|wave (got '$response')" >&2; return 64;; esac
  fi
  mkdir -p "$RUNS_DIR"
  local line; line="$(printf 'significance=%s worthiness=%s verdict=%s' "$sig" "$wor" "$verdict")"
  [ -n "$response" ] && line="$line response=$response"
  [ -n "$reason" ] && line="$line reason=$reason"
  append_run_line "$rid" "$(printf '%s | DEBT | %s' "$(now)" "$line")"
}

# debt-response: record the HUMAN's ★-tap choice as the SEPARATE `| DEBT |` line the debt() header
# anticipates (ADR-0031 §3, SG-04). Where debt() writes the CLASSIFIER's verdict (worker side), this
# writes the conductor-side human response to a `tap`: engage (pull the quiz) / defer (weekend batch,
# SG-05) / wave (accept the debt knowingly). All three are logged , the only real failure is UNTRACKED
# debt, so waving is a first-class RECORDED choice, never a hard block. Same additive shape: check()/
# override()/descent()/_rows() ignore `| DEBT |`, so a response line can never fake or mask a gate.
#
# FORWARD-CARRY (TIER-4 close finding): SG-02's classifier (`debt()`) writes a FAT line
# (significance=/worthiness=/verdict=); this command historically wrote a THIN line (response= only,
# no sig/wor/verdict). The ledger is last-line-wins for readers, so any consumer that re-emits the
# LAST debt line's sig/wor/verdict through the fat `debt` verb (e.g. weekend-batch.sh mark-paid) saw
# empty enums and crashed -- and at the time this fix landed, `significance-classify record` (the
# fat writer) was unwired anywhere, making a thin-only debt-response the DEFAULT path, not an edge
# case. SPEC-136 later wired `record` into `/kit:ship` Step 8 (before the quiz-gate tap), so a live
# gate/gated-final ship now writes the fat line first; this forward-carry stays load-bearing for
# any rid predating that wiring and for non-gate ships (record's scope is gate/gated-final only,
# unchanged by SPEC-136). Fix: look back at the ledger for THIS rid's last FAT line (one carrying
# verdict=) and, if found, re-emit its sig/wor/verdict alongside response= -- making the response
# line self-describing without inventing data. If no fat line exists (a non-gate ship, or a rid
# from before SPEC-136), write the thin line as before; blank stays blank.
# Usage: debt-response <rid> <engage|defer|wave> [reason]
debt_response() {
  local rid="${1:-}" response="${2:-}"; shift 2 2>/dev/null || { echo "usage: debt-response <rid> <engage|defer|wave> [reason]" >&2; return 64; }
  [ -n "$rid" ] || { echo "debt-response requires a rid" >&2; return 64; }
  case "$response" in engage|defer|wave) ;; *) echo "debt-response: response must be engage|defer|wave (got '$response')" >&2; return 64;; esac
  # Security LOW (TIER-4 close), same guard as debt(): neuter a "=" in reason so it can never
  # smuggle a control token past a naive downstream KV-parse.
  local reason; reason="$(oneline "$@" | tr '=' ':')"
  mkdir -p "$RUNS_DIR"
  local f; f="$(ledger_file "$rid")" || return 1
  local sig="" wor="" verdict="" last_fat
  if [ -f "$f" ]; then
    last_fat="$(grep '| DEBT |' "$f" 2>/dev/null | grep 'verdict=' | tail -n1)" || true
    if [ -n "$last_fat" ]; then
      sig="$(printf '%s' "$last_fat" | grep -oE 'significance=[^ ]+' | head -n1 | cut -d= -f2-)" || true
      wor="$(printf '%s' "$last_fat" | grep -oE 'worthiness=[^ ]+' | head -n1 | cut -d= -f2-)" || true
      verdict="$(printf '%s' "$last_fat" | grep -oE 'verdict=[^ ]+' | head -n1 | cut -d= -f2-)" || true
    fi
  fi
  local line
  if [ -n "$verdict" ]; then
    line="$(printf 'significance=%s worthiness=%s verdict=%s response=%s' "$sig" "$wor" "$verdict" "$response")"
  else
    line="response=$response"
  fi
  [ -n "$reason" ] && line="$line reason=$reason"
  mkdir -p "$RUNS_DIR"
  append_run_line "$rid" "$(printf '%s | DEBT | %s' "$(now)" "$line")"
}

# outcome: record a gate's OUTCOME as an ADDITIVE marker (SPEC-129) beside TOKENS + DEBT.
# Emits a `| OUTCOME |` line that check()/override()/descent()/_rows()/_token_agg()/the
# ship-gate all IGNORE (they key on $2=="GATE"|START|START-AMEND|TOKENS|ACTION|DEBT), so an
# outcome line can never fake, mask, or be mistaken for a gate. Mirrors the `| GATE |` field
# layout (field 3 = phase, field 4 = event=start|end). A start/end pair BRACKETS the gate;
# duration is the epoch delta between them (now_epoch = date +%s, portable macOS + ubuntu --
# no date -d/-r, no stat). `caught=` is derived at the CALL SITE from the gate's own recorded
# state (non-pass -> true, clean pass -> false; open-fork 2 default) -- the verb only
# validates + records it, never re-computes it. The timing bracket is unconditional.
# `policy=` (ID-398) is an OPTIONAL, ADDITIVE third field naming which of the kit's three
# failure policies (close/escalate/continue, docs/patterns/failure-policy.md) this outcome
# was: omitted by a caller that doesn't classify one, so old callers and old ledger lines
# are unaffected.
# Usage: outcome <rid> <phase> <start|end> [caught=<true|false>] [policy=<close|escalate|continue>]
outcome() {
  local rid="${1:-}" raw="${2:-}" event="${3:-}"; shift 3 2>/dev/null || { echo "usage: outcome <rid> <phase> <start|end> [caught=<true|false>] [policy=<close|escalate|continue>]" >&2; return 64; }
  [ -n "$rid" ] || { echo "outcome requires a rid" >&2; return 64; }
  local phase; phase="$(normalize_phase "$raw")"
  [ -n "$phase" ] || { echo "outcome requires a phase" >&2; return 64; }
  case "$event" in start|end) ;; *) echo "outcome: event must be start|end (got '$event')" >&2; return 64;; esac
  mkdir -p "$RUNS_DIR"
  local f; f="$(ledger_file "$rid")" || return 1
  local epoch; epoch="$(now_epoch)"
  if [ "$event" = "start" ]; then
    append_run_line "$rid" "$(printf '%s | OUTCOME | %s | start | at=%s' "$(now)" "$phase" "$epoch")"
    return 0
  fi
  # event=end: caught defaults to false (a clean pass is the safe default); duration is
  # derived from THIS rid+phase's last start bracket (0 if none, so an unbracketed end stays
  # honest rather than erroring).
  local caught=false policy="" kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in caught) caught="$v" ;; policy) policy="$v" ;; esac
  done
  case "$caught" in true|false) ;; *) echo "outcome: caught must be true|false (got '$caught')" >&2; return 64;; esac
  case "$policy" in ""|close|escalate|continue) ;; *) echo "outcome: policy must be close|escalate|continue (got '$policy')" >&2; return 64;; esac
  local start_epoch="" dur=0
  if [ -f "$f" ]; then
    start_epoch="$(awk -F' [|] ' -v p="$phase" '
      $2=="OUTCOME" && $3==p && $4=="start" {
        n=split($5,a," "); for(i=1;i<=n;i++){split(a[i],kv2,"="); if(kv2[1]=="at") v=kv2[2]}
      } END{print v}' "$f")"
    if [ -n "$start_epoch" ] && printf '%s' "$start_epoch" | grep -qE '^[0-9]+$'; then
      dur=$((epoch - start_epoch)); [ "$dur" -ge 0 ] || dur=0
    fi
  fi
  local line; line="$(printf '%s | OUTCOME | %s | end | at=%s caught=%s dur_s=%s' "$(now)" "$phase" "$epoch" "$caught" "$dur")"
  [ -n "$policy" ] && line="$line policy=$policy"
  append_run_line "$rid" "$line"
}

# outcome-read: read a gate's OUTCOME back (SPEC-129 round-trip). For each completed
# start/end bracket (or the one given phase), print "<phase> caught=<bool> dur_s=<N>" from
# the LAST end line for that phase (last-end-wins, agreeing with the ledger's append-only
# semantics), plus a trailing " policy=<val>" (ID-398) only when that end line carried one --
# an old or policy-less line reads back byte-identical to before. A phase with a start but
# no end prints "<phase> incomplete". Read-only.
# Usage: outcome-read <rid> [phase]
outcome_read() {
  local rid="${1:-}" want="${2:-}"
  [ -n "$rid" ] || { echo "usage: outcome-read <rid> [phase]" >&2; return 64; }
  local f; f="$(ledger_file "$rid")" || return 1
  [ -f "$f" ] || { echo "(no ledger for '$rid')" >&2; return 1; }
  local filter=""
  [ -n "$want" ] && filter="$(normalize_phase "$want")"
  awk -F' [|] ' -v want="$filter" '
    $2=="OUTCOME" && $4=="start" { started[$3]=1; if(!($3 in ord)) ord[$3]=++seq }
    $2=="OUTCOME" && $4=="end" {
      n=split($5,a," "); c=""; d=""; p2=""
      for(i=1;i<=n;i++){split(a[i],kv,"="); if(kv[1]=="caught")c=kv[2]; if(kv[1]=="dur_s")d=kv[2]; if(kv[1]=="policy")p2=kv[2]}
      caught[$3]=c; dur[$3]=d; policy[$3]=p2; ended[$3]=1; if(!($3 in ord)) ord[$3]=++seq
    }
    END {
      for (p in ord) {
        if (want!="" && p!=want) continue
        if (p in ended) {
          line = sprintf("%s caught=%s dur_s=%s", p, caught[p], dur[p])
          if (policy[p] != "") line = line " policy=" policy[p]
          printf "%d\t%s\n", ord[p], line
        } else printf "%d\t%s incomplete\n", ord[p], p
      }
    }' "$f" | sort -n | cut -f2-
}

override() {
  local rid="${1:-}" raw="${2:-}"; shift 2 2>/dev/null || { echo "usage: override <rid> <phase> <reason>" >&2; return 64; }
  local reason; reason="$(oneline "$@")"; [ -n "$reason" ] || { echo "override requires a reason" >&2; return 64; }
  local phase; phase="$(normalize_phase "$raw")"
  local f; f="$(ledger_file "$rid")"
  # Blanket-override guard (SPEC-097): a reason already used to override a DIFFERENT phase
  # in this run is one pasted across all gates, which defeats the per-gate audit trail --
  # reject it (exit 65). Re-applying the same reason to the SAME phase (idempotent re-run)
  # is fine. Split on ' | ' so fields line up with the write format below.
  if [ -f "$f" ] && awk -F' [|] ' -v p="$phase" -v r="$reason" '
        $2=="GATE" && $4=="override" && $3!=p {
          rr=$5; for (i=6; i<=NF; i++) rr=rr " | " $i   # reason may contain " | "
          if (rr==r) found=1
        }
        END { exit !found }' "$f"; then
    echo "override rejected: reason already used for another gate in run '$rid' -- each gate override needs its own reason" >&2
    return 65
  fi
  mkdir -p "$RUNS_DIR"
  append_run_line "$rid" "$(printf '%s | GATE | %s | override | %s' "$(now)" "$phase" "$reason")"
}

show() { local f; f="$(ledger_file "${1:-}")"; if [ -f "$f" ]; then cat "$f"; else echo "(no ledger for '${1:-}')" >&2; return 1; fi; }

# exit 0 if every required (measure-twice) gate has a ran|override entry; else 1 + list gaps.
check() {
  local lane="${1:-}" rid="${2:-}"; [ -n "$lane" ] && [ -n "$rid" ] || { echo "usage: check <lane> <rid>" >&2; return 64; }
  # FAIL CLOSED on an unknown lane (security review, TIER-4): `required` returns nonzero for a
  # lane that is not a WORKFLOW matrix column (a typo, or "mega"). Reading its EMPTY stream in
  # the loop below would leave missing=0 and vacuously PASS -- so an unknown lane would let
  # mega-merge auto-merge (and ship-gate pass) with zero gates enforced. Distinguish it from a
  # VALID lane that legitimately has zero measure-twice gates (e.g. `tiny`): `required` exits 0
  # there with empty output, which correctly passes.
  local req
  if ! req="$(required "$lane" 2>/dev/null)"; then
    echo "check: unknown lane '$lane' (not a WORKFLOW matrix column: tiny|normal|full|bug|backfill); refusing, fail-closed" >&2
    return 1
  fi
  local f; f="$(ledger_file "$rid")"
  local missing=0 phase
  while IFS= read -r phase; do
    [ -n "$phase" ] || continue
    if [ ! -f "$f" ] || ! awk -F' [|] ' -v p="$phase" '$2=="GATE" && $3==p && ($4=="ran"||$4=="override"){f=1} END{exit !f}' "$f"; then
      echo "MISSING-GATE: $phase (required for lane '$lane'; no ran/override entry in the ledger)" >&2
      missing=1
    fi
  done <<< "$req"
  return "$missing"
}

# plan: the lane's ordered phase checklist, derived from the WORKFLOW matrix (skip cells
# omitted; measure-twice = required, run-lite = lite). grill is prepended as the universal
# intake phase (SPEC-058; tiny lane exempt). This is what /kit:assign prints right after a
# lane is committed, so the operator sees the road before the run starts (SPEC-063).
plan() {
  local lane="${1:-}"; [ -n "$lane" ] || { echo "usage: plan <lane>" >&2; return 64; }
  # Overlay lanes: a vertical kit (learning-kit etc.) drops <lane>.plan into
  # ~/.config/dwarves-kit/lanes.d/ ("N. phase level" lines, same shape as this
  # verb's output). Drop-in wins over "unknown lane", never over a matrix lane.
  local rows; rows="$(matrix_for_lane "$lane")"
  if [ -z "$rows" ]; then
    local dropin="${DWARVES_KIT_LANES_D:-$HOME/.config/dwarves-kit/lanes.d}/$lane.plan"
    if [ -f "$dropin" ]; then
      grep -E '^[[:space:]]*[0-9]+\.[[:space:]]' "$dropin"
      return 0
    fi
  fi
  [ -n "$rows" ] || { echo "unknown lane '$lane' (not a column in the WORKFLOW matrix; no lanes.d drop-in)" >&2; return 1; }
  local i=0 ph cell mark
  if [ "$lane" != "tiny" ]; then
    i=1; printf '%2d. %-18s %s\n' 1 "grill" "intake (universal)"
  fi
  while IFS=$'\t' read -r ph cell; do
    case "$cell" in
      measure-twice) mark="required" ;;
      run-lite)      mark="lite" ;;
      *) continue ;;
    esac
    i=$((i+1))
    printf '%2d. %-18s %s\n' "$i" "$(normalize_phase "$ph")" "$mark"
  done <<< "$rows"
}

# progress: plan x ledger -> one status line + checklist. A phase counts done when the
# ledger carries ANY entry for it (ran, skipped-with-reason, override); the current step
# is the first phase without one. Commands print this at phase entry (SPEC-063).
progress() {
  local rid="${1:-}" lane="${2:-}"
  [ -n "$rid" ] && [ -n "$lane" ] || { echo "usage: progress <rid> <lane>" >&2; return 64; }
  local f; f="$(ledger_file "$rid")"
  local total=0 done_n=0 cur="" cur_idx=0 list="" ooo=0
  local idx ph rest
  while IFS= read -r pline; do
    idx="${pline%%.*}"; idx="$(printf '%s' "$idx" | tr -d ' ')"
    ph="$(printf '%s' "$pline" | awk '{print $2}')"
    total=$((total+1))
    # disposed = ran / override / skipped WITH a reason; a bare skip stays visible as a gap
    if [ -f "$f" ] && awk -F' [|] ' -v p="$ph" '$2=="GATE" && $3==p && ($4!="skipped" || (NF>=5 && $5!="")) {found=1} END{exit !found}' "$f"; then
      # SPEC-071 / ID-050: a phase disposed AFTER the current pointer gets its own
      # marker (*), so an out-of-order ✓ can't mislead the at-a-glance read.
      if [ -n "$cur" ]; then
        done_n=$((done_n+1)); ooo=1; list="$list ${C_DONE}*$ph${C_OFF}"
      else
        done_n=$((done_n+1)); list="$list ${C_DONE}✓$ph${C_OFF}"
      fi
    elif [ -z "$cur" ]; then
      cur="$ph"; cur_idx="$idx"; list="$list ${C_CUR}▶$ph${C_OFF}"
    else
      list="$list ${C_DIM}·$ph${C_OFF}"
    fi
  done < <(plan "$lane")
  [ "$total" -gt 0 ] || return 1
  if [ -z "$cur" ]; then
    printf '%s%s · %s · complete (%d/%d)%s\n' "$C_DONE" "$rid" "$lane" "$done_n" "$total" "$C_OFF"
  else
    printf '%s%s · %s · step %s/%d (%s)%s\n' "$C_BOLD" "$rid" "$lane" "$cur_idx" "$total" "$cur" "$C_OFF"
  fi
  printf ' %s\n' "$list"
  [ "$ooo" -eq 1 ] && printf '%s  (* = disposed out of order)%s\n' "$C_DIM" "$C_OFF"
  return 0
}

# Descent check (SPEC-076 / ID-068): the lane's plan order IS the V-model descent
# order. Replay the ledger timeline; a phase recorded while an EARLIER plan phase is
# still undisposed at that moment is a descent violation. Detection only: exit 0
# always (ADR-0024, mid-flight never blocks); ship-gate surfaces the count as an
# advisory. Disposal semantics agree with progress(): ran / override / skipped WITH
# a non-empty reason dispose; a bare skip does not.
descent() {
  local rid="${1:-}" lane="${2:-}"
  [ -n "$rid" ] && [ -n "$lane" ] || { echo "usage: descent <rid> <lane>" >&2; return 64; }
  local f; f="$(ledger_file "$rid")" || return 0
  [ -f "$f" ] || { echo "descent clean (no ledger)"; return 0; }
  # phase + depth pairs: run-lite/intake phases are implicit checkpoints (review
  # HIGH: an unrecorded run-lite phase must not produce false violations); only
  # measure-twice (printed as "required") phases gate the descent when unrecorded.
  local plan_list; plan_list="$(plan "$lane" | awk '{print $2"="$3}' | tr '\n' ' ')" || return 0
  [ -n "$plan_list" ] || { echo "descent clean (no plan)"; return 0; }
  local out
  out="$(awk -F' [|] ' -v plan="$plan_list" '
    BEGIN {
      n=split(plan, R, " ")
      for (i=1;i<=n;i++) if (R[i]!="") {
        split(R[i], kv, "="); P[i]=kv[1]; order[kv[1]]=i
        if (kv[2]=="lite") disposed[kv[1]]=1   # run-lite only; grill (intake) + required phases stay real checkpoints
      }
    }
    $2=="GATE" {
      p=$3; if (!(p in order)) next
      for (j=1; j<order[p]; j++) if (P[j]!="" && !(P[j] in disposed) && !((p SUBSEP P[j]) in seen)) {
        printf "DESCENT: %s recorded before %s disposed\n", p, P[j]
        seen[p SUBSEP P[j]]=1   # dedup: one line per (phase, gap) pair
      }
      if ($4!="skipped" || (NF>=5 && $5!="")) disposed[p]=1
    }' "$f")"
  if [ -n "$out" ]; then printf '%s\n' "$out"; else echo "descent clean"; fi
  return 0
}

# The canonical run id (SPEC-070 / ID-059): the current branch with its leading
# `type/` segment stripped, the EXACT transform ship-gate keys its ledger check by
# (`${branch#*/}` here == `${BRANCH#*/}` in hooks/ship-gate.sh; agreement-pinned in tests/test-meta.sh).
# One rid from assign to ship means no mirror records. Fails loudly off a work
# branch: a wrong rid recorded silently is worse than no rid.
rid() {
  local branch slug
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  case "$branch" in
    ""|HEAD|master|main)
      echo "rid: not on a work branch (got '${branch:-none}'); create the branch first, then derive the rid" >&2
      return 1 ;;
  esac
  slug="${branch#*/}"
  if [ -z "$slug" ] || [ -z "$(runid "$slug")" ]; then
    echo "rid: branch '$branch' strips to an empty slug" >&2
    return 1
  fi
  # Emit the runid-normalized form (review S2): the visible key equals the
  # ledger filename stem, so forensic review never chases two spellings.
  printf '%s\n' "$(runid "$slug")"
}

# mutation: record the ADVISORY mutation-smoke's verdict (SPEC-131, kit-run-integrity SG-04) as
# an ADDITIVE marker -- the exact `| TOKENS |`/`| DEBT |` shape reused for a third concern: a
# `| MUTATION |` line that check()/override()/descent()/_rows() all ignore (they key on
# $2=="GATE"|START|ACTION), so a mutation verdict can never fake, satisfy, or mask a gate. This is
# the additive property the kit relies on; no reader changes. The smoke is warn-only (gate-zero),
# so this marker is a record of what it FOUND, never a gate the ship path enforces. Independent of
# SG-01's `caught=` GATE-line marker -- a different surface (this is a whole new marker verb).
# Usage: mutation <rid> verdict=<flag|clean|skip> [file=... line=... op=... attempts=N reason=...]
mutation() {
  local rid="${1:-}"; shift 2>/dev/null || { echo "usage: mutation <rid> verdict=<flag|clean|skip> [k=v ...]" >&2; return 64; }
  [ -n "$rid" ] || { echo "mutation requires a rid" >&2; return 64; }
  local verdict="" rest="" kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    # every value is single-token (space-split read-side); collapse spaces + neuter embedded "="
    # in free text so a value can never smuggle a second KV or split the ledger line. The "="->":"
    # step (SPEC-134) matches debt()'s pre-existing neutering and makes this line's comment true.
    v="$(printf '%s' "$v" | tr '\n\r' '  ' | tr ' ' '_' | tr '=' ':')"
    case "$k" in
      verdict) verdict="$v" ;;
      *)       rest="$rest $k=$v" ;;
    esac
  done
  case "$verdict" in flag|clean|skip) ;; *) echo "mutation: verdict must be flag|clean|skip (got '$verdict')" >&2; return 64;; esac
  mkdir -p "$RUNS_DIR"
  append_run_line "$rid" "$(printf '%s | MUTATION | verdict=%s%s' "$(now)" "$verdict" "$rest")"
}

# config_stamp: record a run's configuration dimensions as an ADDITIVE marker
# (ID-420, bench-plane prerequisite: DECISION-BRIEF-bench-plane.md §1), the exact
# `| TOKENS |`/`| DEBT |`/`| MUTATION |` shape reused for a fourth concern: a
# `| CONFIG |` line that check()/override()/descent()/_rows() all ignore (same
# key-on-$2 convention), so a config line can never fake or mask a gate. Every
# value passes through oneline() (embedded newlines/pipes collapsed) before it
# is written, matching every other free-text field in this file.
#
# `phase=` (optional, same idiom as tokens()'s phase=) scopes one CONFIG line to
# a single stage, so a caller emits one line per stage for "model-per-stage"
# instead of one flat rid-wide line; omitting it stamps the whole run.
# kit_version defaults to $KIT_ROOT/VERSION when omitted (the running kit's own
# version, not a value the caller should normally need to pass). suite_hash
# stays empty for real work by contract (only a bench replay sets it, per the
# brief's "null for real work" line) -- this function never invents one.
# Usage: config <rid> [model=M] [effort=E] [kit_version=V] [modules=M1,M2,...]
#               [lane=L] [task_type=T] [suite_hash=H] [session_id=S] [phase=P]
config_stamp() {
  local rid="${1:-}"; shift 2>/dev/null || {
    echo "usage: config <rid> [model=M] [effort=E] [kit_version=V] [modules=M1,M2,...] [lane=L] [task_type=T] [suite_hash=H] [session_id=S] [phase=P]" >&2
    return 64
  }
  [ -n "$rid" ] || { echo "config requires a rid" >&2; return 64; }
  local model="" effort="" kver="" modules="" lane="" ttype="" shash="" sid="" phase="" kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in
      model)       model="$(oneline "$v")" ;;
      effort)      effort="$(oneline "$v")" ;;
      kit_version) kver="$(oneline "$v")" ;;
      modules)     modules="$(oneline "$v")" ;;
      lane)        lane="$(oneline "$v")" ;;
      task_type)   ttype="$(oneline "$v")" ;;
      suite_hash)  shash="$(oneline "$v")" ;;
      session_id)  sid="$(oneline "$v")" ;;
      phase)       phase="$(normalize_phase "$v")" ;;
    esac
  done
  if [ -z "$kver" ]; then
    kver="$(cat "$KIT_ROOT/VERSION" 2>/dev/null)" || kver=""
    [ -n "$kver" ] || kver="unknown"
  fi
  [ -n "$sid" ] || sid="${CLAUDE_SESSION_ID:-}"
  mkdir -p "$RUNS_DIR"
  local line; line="kit_version=$kver"
  [ -n "$model" ]   && line="$line model=$model"
  [ -n "$effort" ]  && line="$line effort=$effort"
  [ -n "$modules" ] && line="$line modules=$modules"
  [ -n "$lane" ]    && line="$line lane=$lane"
  [ -n "$ttype" ]   && line="$line task_type=$ttype"
  [ -n "$shash" ]   && line="$line suite_hash=$shash"
  [ -n "$sid" ]     && line="$line session_id=$sid"
  [ -n "$phase" ]   && line="$line phase=$phase"
  append_run_line "$rid" "$(printf '%s | CONFIG | %s' "$(now)" "$line")"
}

# Usage: history [--lane L] [--json] : one row per run over all gate ledgers.
# Ported from learning-kit/bin/study-history (ID-444): aggregates every
# runs/<rid>.log START line's lane + repo with its GATE ran/skipped counts.
history() {
  local lane_opt="" fmt=csv arg
  while [ $# -gt 0 ]; do case "$1" in
    --json) fmt=json ;;
    --lane) lane_opt="${2:-}"; shift ;;
    *) echo "usage: history [--lane L] [--json]" >&2; return 64 ;;
  esac; shift; done
  [ -d "$RUNS_DIR" ] || return 0
  local rows="" f rid runlane repo t0 t1 ran skipped
  for f in "$RUNS_DIR"/*.log; do
    [ -f "$f" ] || continue
    grep -q '| START |' "$f" || continue
    runlane="$(grep -m1 '| START |' "$f" | grep -o 'lane=[^ ]*' | head -1 | cut -d= -f2)"
    if [ -n "$lane_opt" ] && [ "${runlane:-}" != "$lane_opt" ]; then continue; fi
    rid="$(basename "$f" .log)"
    repo="$(grep -m1 '| START |' "$f" | grep -o 'repo=[^ ]*' | head -1 | cut -d= -f2)"
    t0="$(head -1 "$f" | cut -d' ' -f1)"
    t1="$(tail -1 "$f" | cut -d' ' -f1)"
    ran="$(grep -c '| GATE | .* | ran |' "$f" 2>/dev/null || true)"
    skipped="$(grep -c '| GATE | .* | skipped |' "$f" 2>/dev/null || true)"
    rows="${rows}${rid},${runlane},${repo},${t0},${t1},${ran},${skipped}\n"
  done
  if [ "$fmt" = csv ]; then
    printf 'rid,lane,repo,first_ts,last_ts,gates_ran,gates_skipped\n'
    printf '%b' "$rows"
  else
    printf '%b' "$rows" | awk -F, 'BEGIN{print "["} NR>1{print ","} NR>=1{printf "{\"rid\":\"%s\",\"lane\":\"%s\",\"repo\":\"%s\",\"first_ts\":\"%s\",\"last_ts\":\"%s\",\"gates_ran\":%s,\"gates_skipped\":%s}",$1,$2,$3,$4,$5,$6,$7} END{print "\n]"}'
  fi
}

# _cutoff_iso <days> -- "now minus <days> days" as an ISO8601 Z timestamp. Portable: BSD `date`
# (macOS) needs `-v-Nd`; GNU `date` (Linux/CI) needs `-d "-N days"`. ISO8601 Z timestamps sort
# correctly as PLAIN STRINGS, so filtering below is a string compare, never a date parse.
# Same idiom as lib/learn/weekend-batch.sh's helper of the same name (kept local, not shared,
# since it is six lines and the two callers have no other coupling).
_cutoff_iso() {
  local days="$1"
  if date -v-1d >/dev/null 2>&1; then
    date -u -v-"${days}"d +%Y-%m-%dT%H:%M:%SZ
  else
    date -u -d "-${days} days" +%Y-%m-%dT%H:%M:%SZ
  fi
}

# Usage: report --period week|month [--lane L] : cross-cutting markdown table of runs whose
# first ledger line falls in the window, with GATE ran/skipped totals. ID-445 absorb: the
# smallest useful version over gate-ledger's own runs/ corpus (mega.sh cmd_report is a
# different, per-mega-goal report and does not satisfy this).
report() {
  local period="" lane_opt=""
  while [ $# -gt 0 ]; do case "$1" in
    --period) period="${2:-}"; shift ;;
    --lane) lane_opt="${2:-}"; shift ;;
    *) echo "usage: report --period week|month [--lane L]" >&2; return 64 ;;
  esac; shift; done
  local days
  case "$period" in
    week)  days=7 ;;
    month) days=30 ;;
    *) echo "usage: report --period week|month [--lane L]" >&2; return 64 ;;
  esac
  local since; since="$(_cutoff_iso "$days")"
  printf '# Gate-ledger report (%s, since %s)\n\n' "$period" "$since"
  [ -d "$RUNS_DIR" ] || { printf 'No runs recorded.\n'; return 0; }
  local f rid runlane repo t0 ran skipped rows="" total_runs=0 total_ran=0 total_skipped=0
  for f in "$RUNS_DIR"/*.log; do
    [ -f "$f" ] || continue
    grep -q '| START |' "$f" || continue
    t0="$(head -1 "$f" | cut -d' ' -f1)"
    [ -n "$t0" ] && { [ "$t0" '>' "$since" ] || [ "$t0" = "$since" ]; } || continue
    runlane="$(grep -m1 '| START |' "$f" | grep -o 'lane=[^ ]*' | head -1 | cut -d= -f2)"
    if [ -n "$lane_opt" ] && [ "${runlane:-}" != "$lane_opt" ]; then continue; fi
    rid="$(basename "$f" .log)"
    repo="$(grep -m1 '| START |' "$f" | grep -o 'repo=[^ ]*' | head -1 | cut -d= -f2)"
    ran="$(grep -c '| GATE | .* | ran |' "$f" 2>/dev/null || true)"
    skipped="$(grep -c '| GATE | .* | skipped |' "$f" 2>/dev/null || true)"
    rows="${rows}| ${rid} | ${runlane} | ${repo} | ${ran} | ${skipped} |\n"
    total_runs=$((total_runs + 1)); total_ran=$((total_ran + ran)); total_skipped=$((total_skipped + skipped))
  done
  if [ "$total_runs" -eq 0 ]; then
    printf 'No runs in this window.\n'
    return 0
  fi
  printf '| rid | lane | repo | gates_ran | gates_skipped |\n|---|---|---|---|---|\n'
  printf '%b' "$rows"
  printf '\n**Totals:** %d runs, %d gates ran, %d gates skipped\n' "$total_runs" "$total_ran" "$total_skipped"
}


cmd="${1:-}"; shift 2>/dev/null || true
case "$cmd" in
  required) required "$@" ;;
  start)    start "$@" ;;
  record)   record "$@" ;;
  action)   action "$@" ;;
  tokens)   tokens "$@" ;;
  debt)     debt "$@" ;;
  debt-response) debt_response "$@" ;;
  outcome)      outcome "$@" ;;
  outcome-read) outcome_read "$@" ;;
  mutation) mutation "$@" ;;
  config)   config_stamp "$@" ;;
  override) override "$@" ;;
  check)    check "$@" ;;
  show)     show "$@" ;;
  plan)     plan "$@" ;;
  progress) progress "$@" ;;
  rid)      rid "$@" ;;
  descent)  descent "$@" ;;
  history) history "$@" ;;
  report)  report "$@" ;;
  *) echo "usage: gate-ledger.sh {required|start|record|action|tokens|debt|debt-response|outcome|outcome-read|mutation|config|override|check|show|plan|progress|rid|descent|history|report} ..." >&2; exit 64 ;;
esac
