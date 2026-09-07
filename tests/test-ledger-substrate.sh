#!/usr/bin/env bash
# test-ledger-substrate.sh -- SPEC-182 (kit-modularity SG-02): the ledger append substrate
# (lib/ledger/ledger.sh) + the KIT_LEDGER_DIR one-root wiring shared by the write and read
# planes. Pure bash, no uv/duckdb -- CI-safe.
#
# Covers: append+read+root round-trip; honest-empty read; a set-but-empty KIT_LEDGER_DIR is
# a clean fatal error (NOT a silent relative-path write); DWARVES_KIT_LOG_DIR back-compat;
# and the SHARED-ROOT NC (gate-ledger writes under KIT_LEDGER_DIR, the substrate reads the
# same root -- the two planes meet on one root).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LEDGER="$ROOT/lib/ledger/ledger.sh"
GATE_LEDGER="$ROOT/lib/gate/gate-ledger.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

echo "== substrate: append + read round-trip =="
TMP="$(mktemp -d)"
KIT_LEDGER_DIR="$TMP" bash "$LEDGER" append "runs/x.log" "first line"
KIT_LEDGER_DIR="$TMP" bash "$LEDGER" append "runs/x.log" "second | line"
GOT="$(KIT_LEDGER_DIR="$TMP" bash "$LEDGER" read "runs/x.log")"
assert_eq "round-trip returns both rows in order" "$GOT" "$(printf 'first line\nsecond | line')"

echo "== substrate: newlines collapse to one physical line per append =="
KIT_LEDGER_DIR="$TMP" bash "$LEDGER" append "runs/nl.log" "$(printf 'a\nb')"
NLINES="$(KIT_LEDGER_DIR="$TMP" bash "$LEDGER" read "runs/nl.log" | wc -l | tr -d ' ')"
assert_eq "an embedded newline does not forge a second ledger line" "$NLINES" "1"

echo "== substrate: ledger root prints the resolved root =="
GOTROOT="$(KIT_LEDGER_DIR="$TMP" bash "$LEDGER" root)"
assert_eq "root == KIT_LEDGER_DIR" "$GOTROOT" "$TMP"

echo "== NC honest-empty: reading a missing stream is empty + exit 0 =="
OUT="$(KIT_LEDGER_DIR="$TMP" bash "$LEDGER" read "runs/nope.log")"; rc=$?
if [ -z "$OUT" ] && [ "$rc" -eq 0 ]; then ok "missing stream -> empty, exit 0"; else bad "missing stream should be empty+0 (out='$OUT' rc=$rc)"; fi

echo "== NC empty-KIT_LEDGER_DIR: a set-but-empty root is a clean fatal error =="
ERR="$(KIT_LEDGER_DIR="" bash "$LEDGER" append "runs/boom.log" "x" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && { trap '' PIPE; printf '%s' "$ERR" 2>/dev/null || :; } | grep -qi "empty"; then
  ok "empty KIT_LEDGER_DIR -> nonzero exit + a clear 'empty' error (not a silent relative write)"
else
  bad "empty KIT_LEDGER_DIR should fatal cleanly (rc=$rc err='$ERR')"
fi
# and it must NOT have written a stray relative runs/ dir in cwd
if [ -e "runs/boom.log" ]; then bad "empty KIT_LEDGER_DIR wrote a stray relative runs/boom.log"; rm -rf runs 2>/dev/null; else ok "no stray relative path written on the empty-root error"; fi

echo "== NC back-compat: DWARVES_KIT_LOG_DIR still resolves when KIT_LEDGER_DIR is unset =="
TMP2="$(mktemp -d)"
( unset KIT_LEDGER_DIR; DWARVES_KIT_LOG_DIR="$TMP2" bash "$LEDGER" append "runs/bc.log" "compat" )
BC="$(cat "$TMP2/runs/bc.log" 2>/dev/null)"
assert_eq "DWARVES_KIT_LOG_DIR (legacy alias) writes under its root" "$BC" "compat"

echo "== NC precedence: KIT_LEDGER_DIR wins over DWARVES_KIT_LOG_DIR =="
TMP3="$(mktemp -d)"; TMP4="$(mktemp -d)"
KIT_LEDGER_DIR="$TMP3" DWARVES_KIT_LOG_DIR="$TMP4" bash "$LEDGER" append "runs/p.log" "wins"
if [ -f "$TMP3/runs/p.log" ] && [ ! -f "$TMP4/runs/p.log" ]; then ok "KIT_LEDGER_DIR takes precedence"; else bad "KIT_LEDGER_DIR should win over DWARVES_KIT_LOG_DIR"; fi

echo "== NC shared-root: gate-ledger writes, the substrate reads the SAME root =="
TMP5="$(mktemp -d)"
RID="substrate-shared-test"
KIT_LEDGER_DIR="$TMP5" bash "$GATE_LEDGER" record "$RID" build ran "wrote via gate-ledger" >/dev/null 2>&1
# the substrate reads the same runs/<rid>.log gate-ledger wrote (rid slug = runid())
SR="$(KIT_LEDGER_DIR="$TMP5" bash "$LEDGER" read "runs/$RID.log")"
if { trap '' PIPE; printf '%s' "$SR" 2>/dev/null || :; } | grep -q "| GATE | build | ran |"; then
  ok "the GATE line gate-ledger wrote is readable through the substrate on the same root"
else
  bad "shared-root broken: substrate read did not see gate-ledger's write (got '$SR')"
fi

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
