#!/usr/bin/env bash
# test-config-registry.sh -- SPEC-198, harness-loop sub-goal 08.
#
# Two standing lints plus a functional smoke of bin/config:
#   AC1  drift lint: every hit of the goal's seed regex over lib/hooks/bin is covered by
#        lib/config/module-registry.md (a row) or its Allowlist table (internal/test-fixture).
#        0 orphans on the live tree. Built ON tests/lib/contract-lint.sh's manifest_diff_flat
#        (added by this sub-goal, the flat-SET sibling of SG-02's manifest_diff_by_phase) --
#        no second bespoke grep, per the goal file's explicit instruction.
#   AC2  NEGATIVE CONTROL: a planted, unregistered env var matching the seed prefix family IS
#        flagged an orphan by the same sweep -- proves AC1 is not a vacuous pass.
#   AC3  module-stage completeness (formerly "module-leg", renamed by the 2026-07-18
#        amendment): every install.sh KIT_KNOWN_MODULES entry has a row in the
#        registry's "## Module stages" table.
#   AC4  NEGATIVE CONTROL: a planted extra module name (not in KIT_KNOWN_MODULES) does NOT
#        spuriously satisfy AC3 -- proves the completeness check is keyed off the real list.
#   AC5  bin/config functional smoke: list/get/explain resolve correctly, and an env override
#        + a project .kit.toml override each visibly win their own row (the fixture the
#        proof-of-done captures in full).
#
# The resolver fence (lib/config/kit-config.sh untouched by this sub-goal) is NOT a standing
# assertion here -- a future sub-goal may legitimately edit the resolver for its own reason,
# and a permanent test pinned to "this file has zero diff against branch point X" would fail
# forever after. It is a one-time proof-of-done check instead (a `git diff` capture), not a
# durable regression invariant.
#
# Run: bash tests/test-config-registry.sh   (exit 0 = all AC green)

set -uo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REGISTRY="$KIT_DIR/lib/config/module-registry.md"
CONFIG_BIN="$KIT_DIR/bin/config"
# shellcheck source=tests/lib/contract-lint.sh
. "$KIT_DIR/tests/lib/contract-lint.sh"

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert() { TOTAL=$((TOTAL+1)); if [ "$2" -eq 0 ]; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1)); else echo -e "  ${RED}FAIL${NC} $1 ${3:-}"; FAIL=$((FAIL+1)); fi; }
assert_eq() { TOTAL=$((TOTAL+1)); if [ "$2" = "$3" ]; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1)); else echo -e "  ${RED}FAIL${NC} $1 (expected '$3', got '$2')"; FAIL=$((FAIL+1)); fi; }

# The exact seed regex named in _meta/megagoals/harness-loop/goals/08-config-surface.md step 2.
SEED_RE='\$\{?(KIT|WAVE|QUEUE|MEGA|CC_SI|SKILL_CURATOR|PROSE_RAG|MONEY_GATE|TIER4|MUX|TMUX|PANE|TERMINAL|STATS|CC_BACKLOG|HARVEST|BACKLOG|DWARVES)[A-Z_]*'

# Allowlist regex: dynamically derived from the registry's own "## Allowlist" table (single-
# sourced -- this test file does not hand-maintain a second copy of the token list). The
# header row (| Token | ...) is skipped explicitly, mirroring _registry_rows in config.sh;
# without the skip the word "Token" leaks into the allow-regex (harmless today only because
# no seed prefix starts with To, but a widened prefix family could silently over-allowlist).
_allow_regex() {
  awk '
    /^## Allowlist/ {inal=1; next}
    /^## Known gaps/ {inal=0}
    inal && /^\| [A-Za-z]/ {
      if ($0 ~ /^\| Token \|/) next
      gsub(/^\| /,""); split($0,a,"|"); gsub(/^[ \t]+|[ \t]+$/,"",a[1]); print a[1]
    }
  ' "$REGISTRY" | paste -sd'|' -
}

echo "=== AC1: drift lint -- every seed-regex hit in lib/hooks/bin is registered or allowlisted ==="
ALLOW_RE="^($(_allow_regex))\$"
OUT="$(cd "$KIT_DIR" && manifest_diff_flat "lib hooks bin" "$SEED_RE" "$REGISTRY" "$ALLOW_RE")"
RC=$?
[ -n "$OUT" ] && echo "$OUT" >&2
assert "0 orphans on the live tree (drift lint green)" "$RC"

echo ""
echo "=== AC2: NEGATIVE CONTROL -- a planted unregistered env var IS flagged ==="
PLANT_DIR="$(mktemp -d -t config-registry-plant.XXXXXX)"
mkdir -p "$PLANT_DIR/lib"
cat > "$PLANT_DIR/lib/plant.sh" <<'EOF'
#!/usr/bin/env bash
# fixture: a KIT_-prefixed env var this sub-goal never registered.
echo "${KIT_TOTALLY_UNREGISTERED_PLANT:-nope}"
EOF
PLANT_OUT="$(manifest_diff_flat "$PLANT_DIR/lib" "$SEED_RE" "$REGISTRY" "$ALLOW_RE")"
PLANT_RC=$?
assert_eq "the plant is flagged exactly 1 orphan" "$PLANT_RC" "1"
if { trap '' PIPE; printf '%s\n' "$PLANT_OUT" 2>/dev/null || :; } | grep -qF "ORPHAN: KIT_TOTALLY_UNREGISTERED_PLANT"; then RC=0; else RC=1; fi
assert "the flagged orphan is specifically KIT_TOTALLY_UNREGISTERED_PLANT" $RC

echo ""
echo "=== AC3: module-stage completeness -- every KIT_KNOWN_MODULES entry has a registry row ==="
KNOWN_MODULES="$(grep -o '^KIT_KNOWN_MODULES="[^"]*"' "$KIT_DIR/install.sh" | sed -E 's/^KIT_KNOWN_MODULES="//; s/"$//')"
MISSING=0
for m in $KNOWN_MODULES; do
  if ! grep -qE "^\| $m \|" "$REGISTRY"; then
    echo "  MISSING module-stage row: $m" >&2
    MISSING=$((MISSING+1))
  fi
done
assert "every KIT_KNOWN_MODULES entry ($(printf '%s' "$KNOWN_MODULES" | wc -w | tr -d ' ') modules) has a Module-stages row" "$MISSING"

echo ""
echo "=== AC4: NEGATIVE CONTROL -- a module NOT in KIT_KNOWN_MODULES is correctly absent ==="
if grep -qE '^\| totally_fake_module \|' "$REGISTRY"; then RC=1; else RC=0; fi
assert "a fake module name is correctly NOT found in the registry (the check is not vacuous)" $RC

echo ""
echo "=== AC5: bin/config functional smoke (list/get/explain + provenance fixture) ==="
# `get` must emit the MACHINE value (a scalar a script can compare), never the registry
# cell's human markdown (backticks / parenthetical annotations) -- review finding, 2026-07-12.
assert_eq "get WAVE_CAP (default, no overrides) is the clean scalar 2" "$(env -u WAVE_CAP bash "$CONFIG_BIN" get WAVE_CAP)" '2'
assert_eq "get mega.wave_cap (dotted-key lookup) is the clean scalar 2" "$(env -u WAVE_CAP bash "$CONFIG_BIN" get mega.wave_cap)" '2'
assert_eq "get TIER4_CLOSE returns the resolved boolean from kit.toml (matches the list source)" "$(env -u TIER4_CLOSE bash "$CONFIG_BIN" get TIER4_CLOSE)" 'true'
assert_eq "get MEGA_MERGE_POSTURE unquotes the default (one \" layer, like _kit_toml_get)" "$(env -u MEGA_MERGE_POSTURE bash "$CONFIG_BIN" get MEGA_MERGE_POSTURE)" 'auto-to-final'
if bash "$CONFIG_BIN" get NOT_A_REAL_KEY >/dev/null 2>&1; then RC=1; else RC=0; fi
assert "get on an unknown key fails (exit != 0)" $RC
# Set-but-EMPTY env == unset (matches every real consumer's ${VAR:-default} semantics;
# review finding, 2026-07-12): an empty WAVE_CAP must not report an empty env win.
assert_eq "get with set-but-empty env falls through to the default (\${VAR:-} semantics)" "$(WAVE_CAP='' bash "$CONFIG_BIN" get WAVE_CAP)" '2'
# Missing registry file: every read verb fails loudly (exit != 0), never a header-only
# exit-0 render (review finding, 2026-07-12).
if CONFIG_REGISTRY_FILE=/nonexistent-registry.md bash "$CONFIG_BIN" list >/dev/null 2>&1; then RC=1; else RC=0; fi
assert "list with a missing registry file fails (exit != 0), no silent header-only success" $RC

FIXDIR="$(mktemp -d -t config-registry-fixture.XXXXXX)"
mkdir -p "$FIXDIR/root" "$FIXDIR/proj"
cat > "$FIXDIR/root/kit.toml" <<'EOF'
[mega]
wave_cap = 2
tier4_close = true
EOF
cat > "$FIXDIR/proj/.kit.toml" <<'EOF'
[mega]
wave_cap = 5
EOF
FIXTURE_LIST="$(KIT_CONFIG_ROOT="$FIXDIR/root" KIT_PROJECT_ROOT="$FIXDIR/proj" KIT_DELIVERY_RATIO_WARN=99 bash "$CONFIG_BIN" list)"
if { trap '' PIPE; printf '%s\n' "$FIXTURE_LIST" 2>/dev/null || :; } | grep -qE '^WAVE_CAP[[:space:]]+\[impl\][[:space:]]+5[[:space:]]+project \.kit\.toml'; then RC=0; else RC=1; fi
assert "list: a project .kit.toml override visibly wins WAVE_CAP's row (5, project .kit.toml)" $RC
if { trap '' PIPE; printf '%s\n' "$FIXTURE_LIST" 2>/dev/null || :; } | grep -qE '^KIT_DELIVERY_RATIO_WARN[[:space:]]+\[impl\][[:space:]]+99[[:space:]]+env'; then RC=0; else RC=1; fi
assert "list: an env override visibly wins KIT_DELIVERY_RATIO_WARN's row (99, env)" $RC
if { trap '' PIPE; printf '%s\n' "$FIXTURE_LIST" 2>/dev/null || :; } | grep -qE '^TIER4_CLOSE[[:space:]]+\[impl\][[:space:]]+true[[:space:]]+kit-root kit\.toml'; then RC=0; else RC=1; fi
assert "list: no override falls to kit-root kit.toml (TIER4_CLOSE = true, kit-root kit.toml)" $RC

EXPLAIN_OUT="$(KIT_CONFIG_ROOT="$FIXDIR/root" KIT_PROJECT_ROOT="$FIXDIR/proj" bash "$CONFIG_BIN" explain mega.wave_cap)"
if { trap '' PIPE; printf '%s\n' "$EXPLAIN_OUT" 2>/dev/null || :; } | grep -qE '^Effective: 5   \(source: project \.kit\.toml\)$'; then RC=0; else RC=1; fi
assert "explain mega.wave_cap: the winner line names project .kit.toml + the resolved 5" $RC
if { trap '' PIPE; printf '%s\n' "$EXPLAIN_OUT" 2>/dev/null || :; } | grep -qE '2\. project \.kit\.toml \[mega\.wave_cap\][[:space:]]+= 5'; then RC=0; else RC=1; fi
assert "explain mega.wave_cap: level 2 (project) shows the winning value 5" $RC
if { trap '' PIPE; printf '%s\n' "$EXPLAIN_OUT" 2>/dev/null || :; } | grep -qE '3\. kit-root kit\.toml \[mega\.wave_cap\][[:space:]]+= 2'; then RC=0; else RC=1; fi
assert "explain mega.wave_cap: level 3 (kit-root) shows the shadowed value 2" $RC

# Multi-env-var tie-break: ledger.location is shared by two env rows (KIT_LEDGER_DIR listed
# before DWARVES_KIT_LOG_DIR); a bare-key lookup must resolve to the FIRST (canonical) row,
# so setting KIT_LEDGER_DIR wins a `get ledger.location` (registry-order tie-break).
assert_eq "get ledger.location resolves via the first (canonical KIT_LEDGER_DIR) row" \
  "$(KIT_CONFIG_ROOT="$FIXDIR/root" KIT_PROJECT_ROOT="$FIXDIR/proj" KIT_LEDGER_DIR=/tie-break-proof bash "$CONFIG_BIN" get ledger.location)" \
  '/tie-break-proof'

# SPEC-200 I2 (the CC_* prefix ban) is enforced ONCE, in tests/test-kit-contract.sh (rule C1).
# A second copy lived here briefly and its allowlist immediately diverged from C1's: two
# lints doing one job, silently disagreeing, is the fragmentation SPEC-200 exists to stop
# (advisor finding 4). One rule, one enforcer.

# --- SPEC-249 TASK-001: the ## Seams join table (lives OUTSIDE the registry window) ---
# The window stops at the next top-level "## " heading, matching config.sh's own _seam_rows.
# A stop keyed to one literal heading name would let a pipe table under any OTHER later
# section be linted (and ingested) as a seam row.

_seam_rows() {
  awk '
    /^## Seams/ {inseam=1; next}
    inseam && /^## / {inseam=0}
    inseam && /^\|/ {
      if ($0 ~ /^\| Key \|/) next
      if ($0 ~ /^\|---/) next
      print
    }
  ' "$REGISTRY"
}
_seam_col() {
  local row="$1" idx="$2" f s
  IFS='|' read -ra f <<< "$row"
  s="${f[$idx]:-}"
  s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}
# reimplements config.sh's own _registry_rows/_row_get window, kept local to this test file
# so it never depends on sourcing config.sh (which would run main "$@" on load).
_window_rows() {
  awk '
    /^## Env <-> key registry/ {inreg=1; next}
    /^## Allowlist/ {inreg=0}
    inreg && /^\|/ {
      if ($0 ~ /^\| Env var \|/) next
      if ($0 ~ /^\|---/) next
      print
    }
  ' "$REGISTRY"
}
_window_col() { _seam_col "$1" "$2"; }

SEAM_ROWS="$(_seam_rows)"
WINDOW_ROWS="$(_window_rows)"

echo ""
echo "=== AC6: TASK-001 -- every ## Seams row's Key matches a registry row ==="
SEAM_COUNT=0; SEAM_MISSING=0
while IFS= read -r srow; do
  [ -n "$srow" ] || continue
  SEAM_COUNT=$((SEAM_COUNT+1))
  skey="$(_seam_col "$srow" 1)"
  found=0
  while IFS= read -r wrow; do
    [ -n "$wrow" ] || continue
    wenv="$(_window_col "$wrow" 1)"; wkey="$(_window_col "$wrow" 2)"
    if [ "$wenv" = "$skey" ] || [ "$wkey" = "$skey" ]; then found=1; break; fi
  done <<< "$WINDOW_ROWS"
  if [ "$found" -ne 1 ]; then
    echo "  MISSING registry row for seam key: $skey" >&2
    SEAM_MISSING=$((SEAM_MISSING+1))
  fi
done <<< "$SEAM_ROWS"
assert "every ## Seams Key ($SEAM_COUNT rows) matches a registered env var or section.key" "$SEAM_MISSING"

echo ""
echo "=== AC7: TASK-001 -- every ## Seams row's Kind is skill|file|dir|binary ==="
KIND_BAD=0
while IFS= read -r srow; do
  [ -n "$srow" ] || continue
  skind="$(_seam_col "$srow" 2)"
  case "$skind" in
    skill|file|dir|binary) ;;
    *) echo "  BAD Kind '$skind' for row: $srow" >&2; KIND_BAD=$((KIND_BAD+1)) ;;
  esac
done <<< "$SEAM_ROWS"
assert "every ## Seams Kind is one of skill|file|dir|binary" "$KIND_BAD"

echo ""
echo "=== AC8: TASK-001 -- the ## Seams table does not leak into the registry window / 'config list' ==="
LIST_OUT="$(bash "$CONFIG_BIN" list 2>&1)"
LEAK_ROW=0
while IFS= read -r srow; do
  [ -n "$srow" ] || continue
  if printf '%s\n' "$LIST_OUT" | grep -qF "$srow"; then
    echo "  LEAK: a literal ## Seams row line appears in 'config list' output: $srow" >&2
    LEAK_ROW=$((LEAK_ROW+1))
  fi
done <<< "$SEAM_ROWS"
assert "no literal ## Seams row line appears in 'bash bin/config list' output" "$LEAK_ROW"

LEAK_DUP=0
while IFS= read -r srow; do
  [ -n "$srow" ] || continue
  skey="$(_seam_col "$srow" 1)"
  cnt="$(printf '%s\n' "$LIST_OUT" | grep -cF "$skey")"
  if [ "$cnt" -gt 1 ]; then
    echo "  LEAK: seam key '$skey' appears $cnt times in 'config list' output (want <=1)" >&2
    LEAK_DUP=$((LEAK_DUP+1))
  fi
done <<< "$SEAM_ROWS"
assert "every ## Seams key appears at most once in 'bash bin/config list' output" "$LEAK_DUP"

# --------------------------------------------- command autonomy knobs (SPEC-246 sibling)
# Five keys gate an action that is reversible in git; the shipped default acts. Each
# authorizes a WRITE, so the fence that matters is the third assertion per key: a project
# `.kit.toml` rides inside a pull request and must never widen what a command does.
echo ""
echo "=== AC9: command autonomy knobs resolve root-only ==="
# shellcheck source=/dev/null
. "$(cd "$(dirname "$0")/.." && pwd)/lib/config/kit-config.sh"
AUTONOMY_DIR="$(mktemp -d)"; AUT_OP="$AUTONOMY_DIR/op"; AUT_PROJ="$AUTONOMY_DIR/proj"
mkdir -p "$AUT_OP" "$AUT_PROJ"
cat > "$AUT_OP/kit.toml" <<'TOML'
[ship]
confirm_commit = true
confirm_bump = "always"
create_changelog = false
[debug]
confirm_fix = true
[review]
apply_findings = false
TOML
cp "$AUT_OP/kit.toml" "$AUT_PROJ/.kit.toml"
# key<TAB>shipped default<TAB>operator override
while IFS='|' read -r akey adefault aover; do
  [ -n "$akey" ] || continue
  v="$(kit_config_get_root "$akey" "$adefault")"
  assert "$akey ships as $adefault" "$([ "$v" = "$adefault" ] && echo 0 || echo 1)"
  v="$(KIT_CONFIG_OPERATOR="$AUT_OP" kit_config_get_root "$akey" "$adefault")"
  assert "$akey honours the operator kit.toml" "$([ "$v" = "$aover" ] && echo 0 || echo 1)"
  v="$(KIT_PROJECT_ROOT="$AUT_PROJ" kit_config_get_root "$akey" "$adefault")"
  assert "$akey ignores a project .kit.toml" "$([ "$v" = "$adefault" ] && echo 0 || echo 1)"
done <<'KEYS'
ship.confirm_commit|false|true
ship.confirm_bump|major|always
ship.create_changelog|true|false
debug.confirm_fix|false|true
review.apply_findings|true|false
KEYS
rm -rf "$AUTONOMY_DIR"

echo ""
echo "=== $PASS/$TOTAL passed ==="
[ "$FAIL" -eq 0 ]
