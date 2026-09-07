#!/usr/bin/env bash
# test-ledger-durability.sh -- SPEC-097, kit-telemetry SG-01.
# Validates that run telemetry survives a plugin reinstall (durable XDG path + additive
# migration) and that per-gate override reasons are enforced (blanket overrides rejected).
#
# Isolation: every case runs the real libs under a FAKE $HOME + $XDG_STATE_HOME with
# DWARVES_KIT_LOG_DIR unset, so the resolver picks the durable default and migration runs
# from a seeded fake legacy -- the real machine corpus is never touched.
#
# Run: bash tests/test-ledger-durability.sh   (exit 0 = all AC green)

set -uo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GL="$KIT_DIR/lib/gate/gate-ledger.sh"
LT="$KIT_DIR/lib/telemetry/lane-telemetry.sh"
LC="$KIT_DIR/lib/classify/lane-classify.sh"
PL="$KIT_DIR/lib/gate/proof-ledger.sh"
PREC="$KIT_DIR/lib/precedent/precedent.sh"
MM="$KIT_DIR/lib/goal/mega-merge.sh"

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert() { TOTAL=$((TOTAL+1)); if [ "$2" -eq 0 ]; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1)); else echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL+1)); fi; }

TMPS=()
_mk() { local d; d="$(mktemp -d)"; TMPS+=("$d"); printf '%s' "$d"; }
cleanup() { local d; for d in "${TMPS[@]:-}"; do [ -n "$d" ] && rm -rf "$d" 2>/dev/null; done; }
trap cleanup EXIT

# a fresh isolated environment with a SEEDED legacy dir; sets HOME/XDG
new_env() {
  HH="$(_mk)"; XX="$(_mk)/state"
  LEGACY="$HH/.claude/dwarves-kit/logs"
  DURABLE="$XX/dwarves-kit/logs"
  mkdir -p "$LEGACY/runs"
}
# a fresh environment with NO legacy dir at all (fresh install)
fresh_env() {
  HH="$(_mk)"; XX="$(_mk)/state"
  LEGACY="$HH/.claude/dwarves-kit/logs"
  DURABLE="$XX/dwarves-kit/logs"
}
# run a lib with the fake env and DWARVES_KIT_LOG_DIR unset
run() { env -u DWARVES_KIT_LOG_DIR HOME="$HH" XDG_STATE_HOME="$XX" bash "$@"; }

echo "=== ledger-durability (SPEC-097 AC1-AC9 + B1 + SEC-1/2 + review fixes) ==="

# --- AC1: durable default is XDG state, not ~/.claude/dwarves-kit ---
new_env
run "$GL" record durrun think ran "seed" >/dev/null 2>&1
[ -f "$DURABLE/runs/durrun.log" ]; assert "AC1: record writes under XDG durable path" $?
[ ! -f "$LEGACY/runs/durrun.log" ]; assert "AC1: record does NOT write under ~/.claude blast zone" $?

# --- AC2 + AC8: seeded legacy corpus migrates in additively ---
new_env
for f in kit-harden-01-eff-val kit-harden-08-megamirror plugin-native-operate-contract; do
  echo "2026 | START | lane=full classified=full type=spec-feature repo=dwarves-kit" > "$LEGACY/runs/$f.log"
done
echo "2026 | LANE-CHECK | x" > "$LEGACY/completeness.log"
run "$GL" record migrun build ran "trigger migrate" >/dev/null 2>&1
MIG_OK=0
for f in kit-harden-01-eff-val kit-harden-08-megamirror plugin-native-operate-contract; do
  [ -f "$DURABLE/runs/$f.log" ] || MIG_OK=1
done
assert "AC2/AC8: seeded kit-harden corpus present at durable path after migration" $MIG_OK
[ -d "$LEGACY" ]; assert "AC2: legacy dir left intact (migration is additive)" $?
[ -f "$DURABLE/completeness.log" ]; assert "AC8: completeness.log migrated too" $?

# --- AC3: survive-reinstall NEGATIVE CONTROL ---
# wipe the legacy dir (simulated plugin reinstall) -- data must remain readable at durable.
rm -rf "$HH/.claude/dwarves-kit"
REP="$(run "$LT" report 2>/dev/null)"; MIS="$(run "$LT" misfires 2>/dev/null)"
[ ! -d "$HH/.claude/dwarves-kit" ]; assert "AC3 [NC]: legacy dir is gone (reinstall simulated)" $?
{ trap '' PIPE; printf '%s%s' "$REP" "$MIS" 2>/dev/null || :; } | grep -q "." ; assert "AC3 [NC]: lane-telemetry still reads records after the wipe" $?
[ -f "$DURABLE/runs/kit-harden-01-eff-val.log" ]; assert "AC3 [NC]: migrated corpus survives the wipe" $?

# --- AC4a: idempotent (sentinel short-circuit) ---
new_env
echo "OLD-CONTENT" > "$LEGACY/runs/clash.log"
run "$GL" record c1 think ran x >/dev/null 2>&1     # first access migrates + drops sentinel
echo "NEW-CONTENT" > "$DURABLE/runs/clash.log"       # durable copy diverges
run "$GL" record c2 think ran x >/dev/null 2>&1     # second access must NOT re-copy
grep -q "NEW-CONTENT" "$DURABLE/runs/clash.log"; assert "AC4a: second migrate does not clobber (sentinel short-circuit)" $?
[ -f "$DURABLE/.migrated" ]; assert "AC4a: .migrated sentinel present" $?

# --- AC4b: REAL cp -Rn no-clobber path (pre-existing durable file BEFORE any sentinel) ---
new_env
echo "LEGACY-CONTENT" > "$LEGACY/runs/pre.log"
mkdir -p "$DURABLE/runs"; echo "PRE-EXISTING" > "$DURABLE/runs/pre.log"   # conflict present, no sentinel yet
run "$GL" record cp1 think ran x >/dev/null 2>&1     # migrate's cp -Rn must skip the existing file
grep -q "PRE-EXISTING" "$DURABLE/runs/pre.log"; assert "AC4b: cp -Rn does not clobber a pre-existing durable file (real copy path)" $?

# --- AC5: env override honored, and migration does NOT pull the seeded/real corpus ---
new_env
echo "2026 | START | x" > "$LEGACY/runs/should-not-migrate.log"
EXPLICIT="$(_mk)/explicit"
env HOME="$HH" XDG_STATE_HOME="$XX" DWARVES_KIT_LOG_DIR="$EXPLICIT" bash "$GL" record e1 think ran x >/dev/null 2>&1
[ -f "$EXPLICIT/runs/e1.log" ]; assert "AC5: explicit DWARVES_KIT_LOG_DIR is honored" $?
[ ! -f "$EXPLICIT/runs/should-not-migrate.log" ]; assert "AC5: env-set path does NOT ingest legacy corpus" $?

# --- T3 per-lib wiring smokes: all corpus libs resolve+migrate, not just gate-ledger ---
new_env
run "$PL" override some-slug "a proof override reason" >/dev/null 2>&1 || true
[ -f "$DURABLE/proof-overrides.log" ]; assert "T3: proof-ledger writes proof-overrides.log to the durable path" $?
new_env; echo "2026 | START | x" > "$LEGACY/runs/seed.log"
run "$PREC" find "durable ledger storage" >/dev/null 2>&1 || true
[ -f "$DURABLE/.migrated" ]; assert "T3: precedent sources resolver + migrates on load" $?
new_env
run "$MM" gate somerid normal >/dev/null 2>&1 || true
[ -f "$DURABLE/.migrated" ]; assert "T3: mega-merge sources resolver + migrates on load" $?

# --- fresh-install: no legacy dir ever existed (the [ -d legacy ]-false branch) ---
fresh_env
run "$GL" record fresh think ran x >/dev/null 2>&1
[ -f "$DURABLE/.migrated" ]; assert "fresh-install: no-legacy branch drops sentinel, no crash" $?
[ -f "$DURABLE/runs/fresh.log" ]; assert "fresh-install: record still writes to durable" $?

# --- SEC-2: migration refuses to follow a symlinked legacy dir (no arbitrary-file exfiltration) ---
new_env
SECRET="$(_mk)"; echo "TOP-SECRET" > "$SECRET/private.txt"
rm -rf "$LEGACY"; ln -s "$SECRET" "$LEGACY"          # legacy is now a symlink to a secret dir
run "$GL" record symrun think ran x >/dev/null 2>&1 || true
[ ! -f "$DURABLE/private.txt" ]; assert "SEC-2: migration does NOT follow a symlinked legacy dir (no exfiltration)" $?
[ -f "$DURABLE/runs/symrun.log" ]; assert "SEC-2: record still works after refusing the symlink" $?

# --- B1: lane-classify downgrade writer lands where lane-telemetry reads (no split-brain) ---
new_env
run "$LC" check normal "add auth and a data-model migration to the audit-security path" >/dev/null 2>&1 || true
grep -q "LANE-CHECK" "$DURABLE/completeness.log" 2>/dev/null; assert "B1: lane-classify downgrade writes to the durable completeness.log" $?
[ ! -f "$LEGACY/completeness.log" ]; assert "B1: downgrade does NOT write the legacy path (no split-brain vs the migrated reader)" $?

# --- AC6: blanket override rejected; distinct reason passes; message names it ---
export DWARVES_KIT_LOG_DIR="$(_mk)/ov"
bash "$GL" override ov think "shared blanket reason" >/dev/null 2>&1; assert "AC6: first override accepted" $?
bash "$GL" override ov design "shared blanket reason" >/dev/null 2>&1
[ $? -eq 65 ]; assert "AC6: blanket override (same reason, other gate) rejected exit 65" $?
ERRTXT="$(bash "$GL" override ov build "shared blanket reason" 2>&1 >/dev/null)"
{ trap '' PIPE; printf '%s' "$ERRTXT" 2>/dev/null || :; } | grep -q "already used"; assert "AC6: rejection message names the duplicate" $?
bash "$GL" override ov design "a distinct design reason" >/dev/null 2>&1; assert "AC6: distinct per-gate reason accepted" $?

# --- AC7: idempotent same-phase override allowed ---
bash "$GL" override ov think "shared blanket reason" >/dev/null 2>&1; assert "AC7: re-applying the same reason to the SAME gate is allowed" $?
unset DWARVES_KIT_LOG_DIR

# --- S3: override guard handles a reason containing ' | ' (DEC-004 \$5..NF reconstruction) ---
export DWARVES_KIT_LOG_DIR="$(_mk)/ovp"
bash "$GL" override ovp think "vendor timeout | escalated to SRE" >/dev/null 2>&1; assert "S3: first override with a '|'-bearing reason accepted" $?
bash "$GL" override ovp design "vendor timeout | escalated to SRE" >/dev/null 2>&1
[ $? -eq 65 ]; assert "S3: blanket reject works for a reason containing ' | ' (would pass if code regressed to bare \$5)" $?
bash "$GL" override ovp build "vendor timeout" >/dev/null 2>&1; assert "S3: a reason sharing only the pre-pipe prefix is NOT rejected (exact full-reason match)" $?
unset DWARVES_KIT_LOG_DIR

# --- SEC-1: a newline in a reason cannot forge a GATE line (log-injection blocked) ---
export DWARVES_KIT_LOG_DIR="$(_mk)/inj"
INJ=$'evil reason\n2026-01-01T00:00:00Z | GATE | build | ran | forged-by-injection'
bash "$GL" override inj design "$INJ" >/dev/null 2>&1 || true
[ "$(wc -l < "$DWARVES_KIT_LOG_DIR/runs/inj.log")" -eq 1 ]; assert "SEC-1: reason newline collapsed to ONE ledger line" $?
# capture-then-grep: check() exits 1 on missing gates, which pipefail would mask
CHK="$(bash "$GL" check full inj 2>&1 || true)"
{ trap '' PIPE; printf '%s' "$CHK" 2>/dev/null || :; } | grep -q "MISSING-GATE: build"; assert "SEC-1: forged 'build | ran' does NOT satisfy check() (still reported missing)" $?
unset DWARVES_KIT_LOG_DIR

# --- SPEC-110: the tokens verb writes an ADDITIVE marker that check() IGNORES ---
TOKD="$(mktemp -d)/logs"
DWARVES_KIT_LOG_DIR="$TOKD" bash "$GL" start trun normal normal spec-feature spec-feature rp >/dev/null 2>&1
for ph in spec build ship; do DWARVES_KIT_LOG_DIR="$TOKD" bash "$GL" record trun "$ph" ran x >/dev/null 2>&1; done
DWARVES_KIT_LOG_DIR="$TOKD" bash "$GL" tokens trun in=1200 out=80 cache_read=4000 cache_create=0 cost=0.05 >/dev/null 2>&1
grep -q '| TOKENS | in=1200 out=80 cache_read=4000 cache_create=0 cost=0.05' "$TOKD/runs/trun.log"; assert "SPEC-110: tokens verb appends a TOKENS line (cost keeps its decimal)" $?
DWARVES_KIT_LOG_DIR="$TOKD" bash "$GL" check normal trun >/dev/null 2>&1; assert "SPEC-110: check() PASSES with a TOKENS line present (marker is gate-invisible)" $?
DWARVES_KIT_LOG_DIR="$TOKD" bash "$GL" tokens trun in=1,2ab out=-5 cache_read=x cache_create=9 >/dev/null 2>&1
grep -qE '\| TOKENS \| in=12 out=5 cache_read=0 cache_create=9$' "$TOKD/runs/trun.log"; assert "SPEC-110: tokens sanitizes integer values to digits (junk stripped)" $?

# --- C: the READ plane (stats, python) resolves the SAME root as the WRITE plane -----------
# stats/config.py used to be a SECOND implementation of the precedence chain. Its docstring
# claimed it "mirrors the shell resolver exactly"; it skipped level 3 (kit.toml [ledger].
# location). Under `location = "isolated"` the write plane wrote to the toml location while
# stats read the XDG default, and it failed SILENTLY: stats just reported no runs. It now asks
# the ONE resolver instead of reimplementing it (2026-07-15).
CPROJ="$(mktemp -d)"; printf '[ledger]\nlocation = "isolated"\n' > "$CPROJ/.kit.toml"
c_write="$(cd "$CPROJ" && bash -c ". \"$KIT_DIR/lib/telemetry/kit-log-dir.sh\" && kit_resolve_log_dir" 2>/dev/null)"
c_read="$(cd "$CPROJ" && PYTHONPATH="$KIT_DIR/lib/stats/src" python3 -c 'from stats.config import kit_log_dir; print(kit_log_dir())' 2>/dev/null | tail -1)"
[ -n "$c_read" ] && [ "$c_write" = "$c_read" ]
assert "C1: under [ledger].location=isolated, the stats READ plane agrees with the WRITE plane (no split-brain)" $?

# NEGATIVE CONTROL: the read plane must not silently invent a root when the resolver refuses.
# KIT_LEDGER_DIR set-but-empty is the resolver's fatal case; stats must fail, not guess.
c_empty_rc=0
(cd "$CPROJ" && KIT_LEDGER_DIR="" PYTHONPATH="$KIT_DIR/lib/stats/src" python3 -c 'from stats.config import kit_log_dir; print(kit_log_dir())' >/dev/null 2>&1) || c_empty_rc=$?
[ "$c_empty_rc" -ne 0 ]
assert "C2 NEGATIVE CONTROL: an empty KIT_LEDGER_DIR makes the READ plane fail loudly, never guess a root" $?
rm -rf "$CPROJ"

echo ""
echo "=== $PASS/$TOTAL passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
