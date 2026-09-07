#!/usr/bin/env bash
# test-lane-telemetry.sh -- SPEC-099, kit-telemetry SG-04.
# Pins the `render` routing-diagram subcommand: a seeded corpus renders the
# task-type -> lane -> gate table + flow + counts; the filter narrows; an empty
# corpus degrades gracefully (no crash, no fake zeros).
#
# Run: bash tests/test-lane-telemetry.sh   (exit 0 = all green)

set -uo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LT="$KIT_DIR/lib/telemetry/lane-telemetry.sh"
GL="$KIT_DIR/lib/gate/gate-ledger.sh"

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
ok() { TOTAL=$((TOTAL+1)); if [ "$2" -eq 0 ]; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1)); else echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL+1)); fi; }
has() { { printf '%s' "$2" 2>/dev/null || :; } | grep -qF -- "$1"; }

# seeded corpus: a fixed DWARVES_KIT_LOG_DIR with three runs of distinct lane/type
export DWARVES_KIT_LOG_DIR="$(mktemp -d)/logs"
seed() {  # rid lane type
  bash "$GL" start "$1" "$2" "$2" "$3" "$3" testrepo >/dev/null 2>&1
  bash "$GL" record "$1" think ran x >/dev/null 2>&1
  bash "$GL" record "$1" build ran x >/dev/null 2>&1
}
seed r-full-a full spec-feature
seed r-full-b full eval
seed r-norm   normal doc

echo "=== lane-telemetry render (SPEC-099) ==="

OUT="$(NO_COLOR=1 bash "$LT" render 2>&1)"
has "Lane routing" "$OUT"; ok "render prints the routing header" $?
has "3 runs" "$OUT"; ok "render counts all seeded runs" $?
has "spec-feature" "$OUT"; ok "render shows a task-type row" $?
has "-> " "$OUT"; ok "render shows the type -> lane mapping" $?
has "routing flow" "$OUT"; ok "render draws the ASCII flow section" $?
has "gate coverage" "$OUT"; ok "render shows per-phase gate coverage" $?
# gate coverage counts both full runs' think = 2 (seeded think in all 3, so >=1)
has "think" "$OUT"; ok "render lists a covered gate phase" $?

# --- filter narrows to matching lane ---
OUTF="$(NO_COLOR=1 bash "$LT" render full 2>&1)"
has "filter=full" "$OUTF"; ok "render <filter> notes the active filter" $?
has "2 runs" "$OUTF"; ok "filter=full keeps only the 2 full-lane runs" $?
if has "normal" "$OUTF"; then ok "filter excludes the normal-lane run [NC]" 1; else ok "filter excludes the normal-lane run [NC]" 0; fi

# --- filter with no match ---
OUTN="$(NO_COLOR=1 bash "$LT" render nosuchlane 2>&1)"
has "no runs match" "$OUTN"; ok "filter with no match degrades gracefully" $?

# --- filter is a LITERAL substring, not a regex: metachars don't over-match or crash ---
OUTD="$(NO_COLOR=1 bash "$LT" render "." 2>&1)"
has "no runs match" "$OUTD"; ok "filter '.' is literal (no regex over-match)" $?
OUTB="$(NO_COLOR=1 bash "$LT" render "[" 2>&1)"
if { printf '%s' "$OUTB" 2>/dev/null || :; } | grep -qiE 'awk|character class|syntax'; then ok "filter '[' does not crash awk [NC]" 1; else ok "filter '[' does not crash awk [NC]" 0; fi

# --- gate coverage counts DISTINCT runs, not raw lines (a re-recorded phase counts once) ---
DD="$(mktemp -d)/logs"
DWARVES_KIT_LOG_DIR="$DD" bash "$GL" start rr full full spec-feature spec-feature rp >/dev/null 2>&1
DWARVES_KIT_LOG_DIR="$DD" bash "$GL" record rr think ran x >/dev/null 2>&1
DWARVES_KIT_LOG_DIR="$DD" bash "$GL" record rr think ran "retry" >/dev/null 2>&1   # same phase, same run, twice
OUTC="$(DWARVES_KIT_LOG_DIR="$DD" NO_COLOR=1 bash "$LT" render 2>&1)"
has "1 run," "$OUTC"; ok "single run pluralizes as 'run' not 'runs'" $?
# coverage line for think must read 1 (distinct runs), not 2 (raw lines)
if printf '%s' "$OUTC" | grep -E 'think +[2-9]' >/dev/null; then ok "gate coverage dedupes a re-recorded phase (think=1, not 2)" 1; else ok "gate coverage dedupes a re-recorded phase (think=1, not 2)" 0; fi

# --- filter matches lane OR type substring (DEC-002, intentional): a type substring hits too ---
DT="$(mktemp -d)/logs"
DWARVES_KIT_LOG_DIR="$DT" bash "$GL" start t1 normal normal full-stack full-stack rp >/dev/null 2>&1
DWARVES_KIT_LOG_DIR="$DT" bash "$GL" record t1 think ran x >/dev/null 2>&1
OUTT="$(DWARVES_KIT_LOG_DIR="$DT" NO_COLOR=1 bash "$LT" render full 2>&1)"
has "full-stack" "$OUTT"; ok "filter matches a TYPE substring too (DEC-002 lane-OR-type), not only lane" $?

# --- SPEC-110: token efficiency section + usage=? honest null + render --mermaid annotation ---
TT="$(mktemp -d)/logs"
DWARVES_KIT_LOG_DIR="$TT" bash "$GL" start ta full full spec-feature spec-feature rp >/dev/null 2>&1
DWARVES_KIT_LOG_DIR="$TT" bash "$GL" tokens ta in=1000 out=200 cache_read=5000 cache_create=0 >/dev/null 2>&1
DWARVES_KIT_LOG_DIR="$TT" bash "$GL" start tb normal normal spec-feature spec-feature rp >/dev/null 2>&1   # NO tokens -> usage=?
OUTT="$(DWARVES_KIT_LOG_DIR="$TT" NO_COLOR=1 bash "$LT" report 2>&1)"
has "token efficiency" "$OUTT"; ok "SPEC-110: report has a token efficiency section" $?
{ printf '%s' "$OUTT" 2>/dev/null || :; } | grep -qF "usage=?"; ok "SPEC-110: report shows usage=? for the uncaptured run (honest null, not zero)" $?
{ printf '%s' "$OUTT" 2>/dev/null || :; } | grep -qE 'full[[:space:]]+1200'; ok "SPEC-110: report shows the captured lane's median tokens-to-done" $?
OUTM="$(DWARVES_KIT_LOG_DIR="$TT" NO_COLOR=1 bash "$LT" render --mermaid 2>&1)"
{ printf '%s' "$OUTM" 2>/dev/null || :; } | grep -qF '```mermaid'; ok "SPEC-110: render --mermaid emits a mermaid block" $?
{ printf '%s' "$OUTM" 2>/dev/null || :; } | grep -qE 'lane_full.*1200 tok'; ok "SPEC-110: mermaid annotates the lane node with median tokens" $?
{ printf '%s' "$OUTM" 2>/dev/null || :; } | grep -qF 'usage=?'; ok "SPEC-110: mermaid shows usage=? for the uncaptured lane" $?
OUTA="$(DWARVES_KIT_LOG_DIR="$TT" NO_COLOR=1 bash "$LT" render 2>&1)"
{ { printf '%s' "$OUTA" 2>/dev/null || :; } | grep -q "Lane routing" && ! { printf '%s' "$OUTA" 2>/dev/null || :; } | grep -qF '```mermaid'; }; ok "SPEC-110 NC: ASCII render unchanged (no mermaid block without the flag)" $?

# --- graceful-empty NEGATIVE CONTROL: empty/fresh LOG_DIR ---
OUTE="$(DWARVES_KIT_LOG_DIR="$(mktemp -d)/empty" NO_COLOR=1 bash "$LT" render 2>&1)"
has "no runs recorded" "$OUTE"; ok "empty corpus renders an honest 'no runs recorded' [NC]" $?
if { printf '%s' "$OUTE" 2>/dev/null || :; } | grep -qiE 'error|not found|unbound|syntax'; then ok "empty render does not crash [NC]" 1; else ok "empty render does not crash [NC]" 0; fi

# --- ID-398: failure-policy breakdown in `report` ---
PD="$(mktemp -d)/logs"
DWARVES_KIT_LOG_DIR="$PD" bash "$GL" start pr1 full full spec-feature spec-feature rp >/dev/null 2>&1
DWARVES_KIT_LOG_DIR="$PD" bash "$GL" outcome pr1 build start >/dev/null 2>&1
DWARVES_KIT_LOG_DIR="$PD" bash "$GL" outcome pr1 build end caught=true policy=escalate >/dev/null 2>&1
DWARVES_KIT_LOG_DIR="$PD" bash "$GL" start pr2 full full spec-feature spec-feature rp >/dev/null 2>&1
DWARVES_KIT_LOG_DIR="$PD" bash "$GL" outcome pr2 build start >/dev/null 2>&1
DWARVES_KIT_LOG_DIR="$PD" bash "$GL" outcome pr2 build end caught=false policy=continue >/dev/null 2>&1
OUTP="$(DWARVES_KIT_LOG_DIR="$PD" NO_COLOR=1 bash "$LT" report 2>&1)"
has "failure policy" "$OUTP"; ok "ID-398: report has a failure-policy section" $?
{ printf '%s' "$OUTP" 2>/dev/null || :; } | grep -qE 'escalate[[:space:]]+1'; ok "ID-398: report counts an escalate outcome" $?
{ printf '%s' "$OUTP" 2>/dev/null || :; } | grep -qE 'continue[[:space:]]+1'; ok "ID-398: report counts a continue outcome" $?

# --- ID-398 NEGATIVE CONTROL: no policy= anywhere -> section omitted entirely ---
OUTNP="$(NO_COLOR=1 bash "$LT" report 2>&1)"   # the seeded corpus at the top of this file has no policy= fields
if { printf '%s' "$OUTNP" 2>/dev/null || :; } | grep -qF "failure policy"; then ok "ID-398 NC: no policy-carrying runs -> section omitted" 1; else ok "ID-398 NC: no policy-carrying runs -> section omitted" 0; fi

echo ""
echo "=== $PASS/$TOTAL passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
