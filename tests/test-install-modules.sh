#!/usr/bin/env bash
# test-install-modules.sh -- ID-277 SG-04 (kit-modularity, install/wire): install.sh is
# LAYERED. The spine (safety-gate, ship-gate, spec-drift-guard, secrets-guard,
# commit-format, anti-rationalization) is always wired; every other hook belongs to an
# opt-in module (`--with <a,b,c>`), recorded in a `kit.toml [modules]` manifest that
# DRIVES the shell wiring above -- it is never a runtime feature-registry a hook reads
# (see the standing anti-drift lint at the bottom of this file).
#
# Run: bash tests/test-install-modules.sh
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
assert_true() { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }

wired_hooks() { # $1 = settings.json path
  jq -r '[.hooks // {} | to_entries[]? | .value[]? | .hooks[]? | .command] | .[]' "$1" 2>/dev/null \
    | grep -oE 'hooks/[A-Za-z0-9._-]+\.sh' | sed 's#hooks/##' | sort -u
}

# modules_section_true <toml-file> -- bare keys set `= true` WITHIN [modules] only
# (SPEC-183). Scoped on purpose: since the install kit.toml is now the FULL
# rendered schema (repo-root default + recomputed [modules]), other sections
# legitimately ship `= true` defaults too ([ledger] telemetry, [mega] tier4_close,
# [gate] understanding_gate, [features] learning_ledger) -- none of them a module.
# Keep this the SAME awk as install.sh's kit_toml_modules_section_true(); we can't
# source install.sh directly here (it's a full script with side effects, not a
# library), so this is a deliberate, sync-required duplicate -- always call it on
# an install-RENDERED file (bare `key = true|false`, no inline comment), never the
# comment-bearing repo-root default.
modules_section_true() {
  awk '
    /^\[modules\]/ { insec = 1; next }
    /^\[/          { insec = 0 }
    insec && /^[a-z_]+[[:space:]]*=[[:space:]]*true[[:space:]]*$/ {
      key = $0; sub(/[[:space:]]*=.*/, "", key); print key
    }
  ' "$1" 2>/dev/null
}

# ============================================================
echo "== NC spine-only: a plain temp-HOME install wires ONLY the spine =="
# ============================================================
H1="$(mktemp -d)"
HOME="$H1" bash "$KIT_DIR/install.sh" >/tmp/kitmod-h1.log 2>&1
WIRED1="$(wired_hooks "$H1/.claude/settings.json")"
EXPECT_SPINE="anti-rationalization.sh
commit-format.sh
safety-gate.sh
secrets-guard.sh
ship-gate.sh
spec-drift-guard.sh"
assert_true "spine-only install wires exactly the 6 spine hooks" "$([ "$WIRED1" = "$EXPECT_SPINE" ]; echo $?)"
NON_SPINE="$(printf '%s\n' "$WIRED1" | grep -vFxf <(printf '%s\n' "$EXPECT_SPINE") || true)"
assert_true "spine-only install: no optional-module hook present (extra: ${NON_SPINE:-none})" "$([ -z "$NON_SPINE" ]; echo $?)"
assert_true "spine-only install: kit.toml has team_mode = false" "$(grep -qx 'team_mode = false' "$H1/.claude/dwarves-kit/kit.toml"; echo $?)"
OPT_TRUE="$(modules_section_true "$H1/.claude/dwarves-kit/kit.toml")"
assert_true "spine-only install: no module recorded true in kit.toml [modules] (extra: ${OPT_TRUE:-none})" "$([ -z "$OPT_TRUE" ]; echo $?)"

# ============================================================
echo "== NC --with board,stats: wires exactly those + records in kit.toml; re-run reproduces =="
# ============================================================
H2="$(mktemp -d)"
HOME="$H2" bash "$KIT_DIR/install.sh" --with board,stats >/tmp/kitmod-h2.log 2>&1
WIRED2="$(wired_hooks "$H2/.claude/settings.json")"
EXPECT_BOARD="$(printf '%s\nbacklog-stage.sh' "$EXPECT_SPINE" | sort -u)"
assert_true "--with board,stats wires spine + backlog-stage.sh (board's hook) only" "$([ "$WIRED2" = "$EXPECT_BOARD" ]; echo $?)"
assert_true "kit.toml records board = true" "$(grep -qx 'board = true' "$H2/.claude/dwarves-kit/kit.toml"; echo $?)"
assert_true "kit.toml records stats = true (hookless module, still recorded)" "$(grep -qx 'stats = true' "$H2/.claude/dwarves-kit/kit.toml"; echo $?)"
assert_true "kit.toml records session = false (not requested)" "$(grep -qx 'session = false' "$H2/.claude/dwarves-kit/kit.toml"; echo $?)"

HOME="$H2" bash "$KIT_DIR/install.sh" >/tmp/kitmod-h2-rerun.log 2>&1
WIRED2B="$(wired_hooks "$H2/.claude/settings.json")"
assert_true "re-run (no --with) reproduces the same wired set from the manifest" "$([ "$WIRED2" = "$WIRED2B" ]; echo $?)"

# ============================================================
echo "== NC un-opted-hook-absent: a cosmetic/session/advisor hook never reaches settings.json =="
# ============================================================
UNWANTED="auto-format.sh notification.sh slop-cleaner.sh statusline.sh codebase-index.sh permission-auto-approve.sh context-hints.sh tool-policy-guard.sh harvest.sh session-state-save.sh citation-guard.sh context-readiness.sh output-offload.sh pre-compact-backup.sh post-compact-reinject.sh money-gate.sh prose-rag.sh"
LEAKED=""
for h in $UNWANTED; do
  { printf '%s\n' "$WIRED2" 2>/dev/null || :; } | grep -qx "$h" && LEAKED="$LEAKED $h"
done
assert_true "no un-opted-in module hook present after --with board,stats (leaked:${LEAKED:-none})" "$([ -z "$LEAKED" ]; echo $?)"

# ============================================================
echo "== NC team_mode reserved: --with team_mode is a clean error, not installable =="
# ============================================================
H3="$(mktemp -d)"
ERR3="$(HOME="$H3" bash "$KIT_DIR/install.sh" --with team_mode 2>&1)"; RC3=$?
assert_true "--with team_mode exits nonzero" "$([ "$RC3" -ne 0 ]; echo $?)"
assert_true "--with team_mode error names the reserved reason" "$({ printf '%s' "$ERR3" 2>/dev/null || :; } | grep -qi 'reserved'; echo $?)"
assert_true "--with team_mode never wrote a settings.json" "$([ ! -f "$H3/.claude/settings.json" ]; echo $?)"

# ============================================================
echo "== NC unknown module name: clean error, not silent =="
# ============================================================
H4="$(mktemp -d)"
ERR4="$(HOME="$H4" bash "$KIT_DIR/install.sh" --with bogus-module 2>&1)"; RC4=$?
assert_true "--with bogus-module exits nonzero" "$([ "$RC4" -ne 0 ]; echo $?)"
assert_true "--with bogus-module error names the unknown module" "$({ printf '%s' "$ERR4" 2>/dev/null || :; } | grep -q 'bogus-module'; echo $?)"
assert_true "--with bogus-module never wrote a settings.json" "$([ ! -f "$H4/.claude/settings.json" ]; echo $?)"

# ============================================================
echo "== NC existing-consumer migration: re-running install.sh is ADDITIVE, never un-wires =="
# ============================================================
# Simulate the pre-SG-04 all-hooks installer: seed settings.json with the FULL
# (unfiltered) kit settings.json, no kit.toml yet.
H5="$(mktemp -d)"
mkdir -p "$H5/.claude"
cp "$KIT_DIR/settings.json" "$H5/.claude/settings.json"
BEFORE5="$(wired_hooks "$H5/.claude/settings.json")"
BEFORE5_N="$(printf '%s\n' "$BEFORE5" | grep -c .)"
HOME="$H5" bash "$KIT_DIR/install.sh" >/tmp/kitmod-h5.log 2>&1
AFTER5="$(wired_hooks "$H5/.claude/settings.json")"
DROPPED="$(comm -23 <(printf '%s\n' "$BEFORE5") <(printf '%s\n' "$AFTER5"))"
assert_true "additive re-install drops nothing from an old all-hooks install (before=$BEFORE5_N, dropped:${DROPPED:-none})" "$([ -z "$DROPPED" ]; echo $?)"

# ============================================================
echo "== NC --prune: the explicit, only way to trim a previously-wired hook =="
# ============================================================
H6="$(mktemp -d)"
mkdir -p "$H6/.claude"
cp "$KIT_DIR/settings.json" "$H6/.claude/settings.json"
HOME="$H6" bash "$KIT_DIR/install.sh" --prune --with board >/tmp/kitmod-h6.log 2>&1
WIRED6="$(wired_hooks "$H6/.claude/settings.json")"
EXPECT_PRUNE="$(printf '%s\nbacklog-stage.sh' "$EXPECT_SPINE" | sort -u)"
assert_true "--prune --with board trims to exactly spine + board (drops the old all-hooks set)" "$([ "$WIRED6" = "$EXPECT_PRUNE" ]; echo $?)"

# ============================================================
echo "== POST-INSTALL SMOKE: every wired hook script runs cleanly (exit 0) on a no-op event =="
# ============================================================
H7="$(mktemp -d)"
HOME="$H7" bash "$KIT_DIR/install.sh" --with board,session,advisor,cosmetic,queue,stats,quiz_gate,weekend_batch,sync >/tmp/kitmod-h7.log 2>&1
# Invoke each installed hook from a real (throwaway) git repo, not the kit checkout
# itself, so a hook's project-root-relative reads (e.g. .claude/backups, docs/specs)
# see a clean, self-consistent tree instead of the kit's own live dev state.
SMOKE_REPO="$(mktemp -d)"
git -C "$SMOKE_REPO" init -q
mkdir -p "$SMOKE_REPO/.claude/backups" "$SMOKE_REPO/docs/specs"
SMOKE_FAIL=0; SMOKE_N=0
for h in "$H7/.claude/dwarves-kit/hooks/"*.sh; do
  SMOKE_N=$((SMOKE_N+1))
  ( cd "$SMOKE_REPO" && echo '{}' | bash "$h" >/tmp/kitmod-smoke-out 2>&1 )
  rc=$?
  if [ "$rc" -ne 0 ]; then SMOKE_FAIL=$((SMOKE_FAIL+1)); echo "    smoke-fail: $(basename "$h") exit=$rc"; fi
done
assert_true "post-install smoke: all $SMOKE_N wired hooks exit 0 on a no-op event ($SMOKE_FAIL failed)" "$([ "$SMOKE_FAIL" -eq 0 ]; echo $?)"

# ============================================================
echo "== STANDING ANTI-DRIFT LINT: no hook reads kit.toml at runtime (record, not registry) =="
# ============================================================
LEAK="$(grep -rl 'kit\.toml' "$KIT_DIR/hooks" 2>/dev/null || true)"
assert_true "no hooks/*.sh reads kit.toml (leaked: ${LEAK:-none})" "$([ -z "$LEAK" ]; echo $?)"

# ============================================================
echo "== NC lint-load-bearing: a hook that DOES read kit.toml is caught, not a vacuous green =="
# ============================================================
# SPEC-183: proves the standing lint above actually catches a violation, not just
# that the repo happens to be clean today. A synthetic hooks/ dir with one real
# hook (copied) plus one planted offender is checked with the SAME assertion the
# standing lint uses; the offender must be named, and the real hook must not be.
NC_HOOKS_DIR="$(mktemp -d)"
cp "$KIT_DIR/hooks/safety-gate.sh" "$NC_HOOKS_DIR/safety-gate.sh"
cat > "$NC_HOOKS_DIR/fake-config-reader.sh" <<'FAKEHOOK'
#!/usr/bin/env bash
# Planted NC offender: a hook that reads kit.toml at runtime.
source "$(dirname "$0")/../lib/config/kit-config.sh" 2>/dev/null || true
grep -q board "$HOME/.claude/dwarves-kit/kit.toml" 2>/dev/null
FAKEHOOK
NC_LEAK="$(grep -rl 'kit\.toml' "$NC_HOOKS_DIR" 2>/dev/null || true)"
assert_true "NC: lint catches a planted hook reading kit.toml (caught: ${NC_LEAK:-NONE-BUG})" "$({ printf '%s' "$NC_LEAK" 2>/dev/null || :; } | grep -q 'fake-config-reader.sh'; echo $?)"
if { printf '%s' "$NC_LEAK" 2>/dev/null || :; } | grep -qx "$NC_HOOKS_DIR/safety-gate.sh"; then FP_RC=1; else FP_RC=0; fi
assert_true "NC: lint does not false-positive the untouched real hook" "$FP_RC"
rm -rf "$NC_HOOKS_DIR"

# ============================================================
echo "== NC chain-coherent: repo-root kit.toml -> install render -> resolver read =="
# ============================================================
# SPEC-183: the 3-artifact chain is ONE coherent thing, not three independent
# claims. Reuses H2 (--with board,stats, already installed above) as the PROD
# regime; a fresh checkout copy stands in for the DEV regime.
REPO_ROOT_TOML="$KIT_DIR/kit.toml"
INSTALL_TOML="$H2/.claude/dwarves-kit/kit.toml"
assert_true "repo-root kit.toml exists (promoted from kit.toml.example)" "$([ -f "$REPO_ROOT_TOML" ]; echo $?)"
assert_true "kit.toml.example no longer exists (fully promoted)" "$([ ! -f "$KIT_DIR/kit.toml.example" ]; echo $?)"
for SEC in '\[ledger\]' '\[mega\]' '\[gate\]' '\[features\]' '\[team\]'; do
  assert_true "repo-root default carries section $SEC" "$(grep -qE "^$SEC" "$REPO_ROOT_TOML"; echo $?)"
  assert_true "install-rendered kit.toml carries section $SEC (full schema, not modules-only)" "$(grep -qE "^$SEC" "$INSTALL_TOML"; echo $?)"
done
# Prod regime: resolver (KIT_CONFIG_ROOT pointed at the install dir) reads the
# INSTALL file's [modules] (board=true, this run's --with).
RESOLVER="$KIT_DIR/lib/config/kit-config.sh"
PROD_VAL="$(KIT_CONFIG_ROOT="$H2/.claude/dwarves-kit" KIT_PROJECT_ROOT="$(mktemp -d)" bash -c "source '$RESOLVER'; kit_config_get modules.board")"
assert_true "prod regime: resolver reads the INSTALL kit.toml (modules.board=true from --with board,stats)" "$([ "$PROD_VAL" = "true" ]; echo $?)"
# Dev regime: resolver (KIT_CONFIG_ROOT pointed at the repo checkout) reads the
# REPO-ROOT default directly -- proven distinct from the install copy by reading
# a [mega] key whose repo-root default differs from nothing-installed (mega is
# never in [modules], so it is untouched by install's per-run recompute; reading
# it from the repo-root root at all is the proof this regime bypasses install).
DEV_VAL="$(KIT_CONFIG_ROOT="$KIT_DIR" KIT_PROJECT_ROOT="$(mktemp -d)" bash -c "source '$RESOLVER'; kit_config_get mega.wave_cap")"
assert_true "dev regime: resolver reads the REPO-ROOT kit.toml directly (mega.wave_cap=2, no install needed)" "$([ "$DEV_VAL" = "2" ]; echo $?)"

# ============================================================
echo "== COVERAGE-DELTA: every module in the manifest maps to a real installable unit =="
# ============================================================
# Each optional module either has >=1 hook that exists on disk, or is a documented
# hookless module backed by a real command/skill/lib subsystem.
declare -a HOOKED_MODULES=(board session advisor cosmetic)
declare -a HOOKLESS_MODULES=(queue stats quiz_gate weekend_batch sync)
COV_FAIL=""
for m in "${HOOKED_MODULES[@]}"; do
  case "$m" in
    board) HOOKS="backlog-stage.sh" ;;
    session) HOOKS="context-readiness.sh output-offload.sh pre-compact-backup.sh post-compact-reinject.sh session-state-save.sh harvest.sh citation-guard.sh" ;;
    advisor) HOOKS="context-hints.sh tool-policy-guard.sh" ;;
    cosmetic) HOOKS="auto-format.sh notification.sh slop-cleaner.sh statusline.sh codebase-index.sh permission-auto-approve.sh" ;;
  esac
  for h in $HOOKS; do
    [ -f "$KIT_DIR/hooks/$h" ] || COV_FAIL="$COV_FAIL $m:$h"
  done
done
[ -d "$KIT_DIR/lib/queue" ] || COV_FAIL="$COV_FAIL queue:lib/queue"
[ -d "$KIT_DIR/lib/stats" ] || COV_FAIL="$COV_FAIL stats:lib/stats"
[ -f "$KIT_DIR/commands/quiz-gate.md" ] || COV_FAIL="$COV_FAIL quiz_gate:commands/quiz-gate.md"
grep -rq "weekend" "$KIT_DIR/commands" 2>/dev/null || COV_FAIL="$COV_FAIL weekend_batch:commands"
[ -d "$KIT_DIR/lib/sync" ] || COV_FAIL="$COV_FAIL sync:lib/sync"
assert_true "every manifest module maps to a real installable unit (missing:${COV_FAIL:-none})" "$([ -z "$COV_FAIL" ]; echo $?)"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
