#!/usr/bin/env bash
# proof-loop-09-scenario-b.sh -- SPEC-199 rung-3 re-execution harness (NOT a CI suite; the
# `proof-` prefix keeps it out of the test-* conventions on purpose).
#
# RE-EXECUTES scenario (b) of docs/proof/loop-09-onboard-wizard/b-bash-unadopted-repo.md LIVE:
# builds the same temp-HOME fixture (bash-install machine + fresh unadopted repo), runs the exact
# command sequence /kit:onboard drives, and ASSERTS the outputs the committed transcript claims.
# Also re-executes the decline-NC (decline-nc.md): the pre-adopt reads leave the repo
# byte-identical. A fresh-context recheck-verifier runs this file to re-judge the transcript
# against reality instead of reading it back (the kit-foldin rung-3 precedent for interactive
# surfaces: a hand-crafted transcript is this mega's most fake-able artifact).
#
# Run: bash tests/proof-loop-09-scenario-b.sh   (exit 0 = every transcript claim reproduced)
set -uo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert_eq() { TOTAL=$((TOTAL+1)); if [ "$2" = "$3" ]; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1)); else echo -e "  ${RED}FAIL${NC} $1 (expected '$3', got '$2')"; FAIL=$((FAIL+1)); fi; }
assert_contains() { TOTAL=$((TOTAL+1)); if { printf '%s' "$2" 2>/dev/null || :; } | grep -qF "$3"; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1)); else echo -e "  ${RED}FAIL${NC} $1 (missing '$3')"; FAIL=$((FAIL+1)); fi; }

ROOT="$(mktemp -d -t sp199-recheck.XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT

# --- the scenario-(b) fixture: bash-install machine + fresh unadopted repo -------------------
CD_BASH="$ROOT/home/.claude"; mkdir -p "$CD_BASH/dwarves-kit"
cat > "$CD_BASH/settings.json" <<'EOF'
{ "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "$HOME/.claude/dwarves-kit/hooks/safety-gate.sh" } ] } ] } }
EOF
REPO="$ROOT/repo-b"; mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
printf '# demo project\n' > "$REPO/README.md"; printf '{"name":"demo"}\n' > "$REPO/package.json"
git -C "$REPO" add -A; git -C "$REPO" commit -qm init

CFG() { env -u PROSE_RAG_INJECT -u MONEY_GATE_REPOS KIT_CONFIG_ROOT="$KIT_DIR" KIT_PROJECT_ROOT="$REPO" bash "$KIT_DIR/bin/config" "$@"; }

echo "=== Transcript claim 1: detect -> bash ==="
MODE="$(CLAUDE_DIR="$CD_BASH" bash "$KIT_DIR/lib/onboard-detect.sh" mode)"
assert_eq "onboard-detect on the bash fixture reads 'bash'" "$MODE" "bash"

echo ""
echo "=== Transcript claim 2: adopt --check -> not adopted ==="
CHECK_OUT="$(bash "$KIT_DIR/lib/adopt.sh" --check "$REPO" 2>&1)"; CHECK_RC=$?
assert_eq "--check exits 1 (not adopted)" "$CHECK_RC" "1"
assert_contains "--check says 'not adopted'" "$CHECK_OUT" "not adopted"

echo ""
echo "=== Transcript claim 3: the --dry-run preview names the 4 contract files + .kit.toml seed, writes nothing ==="
DRY_OUT="$(bash "$KIT_DIR/lib/adopt.sh" --dry-run "$REPO" 2>&1)"
for claim in "would create AGENTS.md" "would write WORKFLOW.md pointer" "would append the CLAUDE.md" "would create docs/verification/README.md" "would seed a starter .kit.toml"; do
  assert_contains "dry-run previews: $claim" "$DRY_OUT" "$claim"
done
assert_eq "dry-run wrote no .kit.toml" "$([ -f "$REPO/.kit.toml" ] && echo yes || echo no)" "no"

echo ""
echo "=== Decline-NC re-execution: after detect + check + dry-run (all a declining user sees), tree is byte-identical ==="
PORC="$(cd "$REPO" && git status --porcelain | wc -l | tr -d ' ')"
assert_eq "porcelain is 0 lines after the read-only steps (decline = no-op)" "$PORC" "0"

echo ""
echo "=== Transcript claim 4: module roster is generated from the registry (12 modules.* rows) ==="
ROSTER="$(CFG list | grep -c '^modules\.')"
assert_eq "config list yields 12 modules.* rows" "$ROSTER" "12"

echo ""
echo "=== Transcript claim 5: ONE adopt --with call seeds the toggled module (bridge=true) ==="
ADOPT_OUT="$(bash "$KIT_DIR/lib/adopt.sh" --with "board,session,advisor,queue,stats,bridge" "$REPO" 2>&1)"
assert_contains "adopt reports the repo updated" "$ADOPT_OUT" "(updated)"
assert_eq ".kit.toml now exists" "$([ -f "$REPO/.kit.toml" ] && echo yes || echo no)" "yes"
BRIDGE_LINE="$(grep -E '^bridge *= *' "$REPO/.kit.toml" | tr -d ' ')"
assert_eq ".kit.toml seeds bridge = true (the --with bridge worked)" "$BRIDGE_LINE" "bridge=true"
COSMETIC_LINE="$(grep -E '^cosmetic *= *' "$REPO/.kit.toml" | tr -d ' ')"
assert_eq ".kit.toml keeps cosmetic = false (unpicked module stays off)" "$COSMETIC_LINE" "cosmetic=false"

echo ""
echo "=== Transcript claim 6: the honest caveat is real -- --with can NOT seed prose_rag (adopt.sh's stale set) ==="
grep -qE '^prose_rag *= *' "$REPO/.kit.toml" && HAS_PR=yes || HAS_PR=no
assert_eq "prose_rag is absent from the seeded .kit.toml (the wizard's hand-edit disclosure is honest)" "$HAS_PR" "no"

echo ""
echo "=== Transcript claim 7: the consumer knob comes from the registry, and is honestly inert by default ==="
KNOB_ROW="$(CFG list | awk '$NF=="prose_rag" && $1=="PROSE_RAG_INJECT"')"
assert_contains "PROSE_RAG_INJECT row exists with MODULE=prose_rag" "$KNOB_ROW" "PROSE_RAG_INJECT"
EXPL="$(CFG explain PROSE_RAG_INJECT)"
assert_contains "explain shows env-only (no kit.toml backing)" "$EXPL" "no kit.toml backing"
assert_contains "explain shows the inert default" "$EXPL" "unset (hook inert)"

echo ""
echo "=== Results ==="
echo -e "Passed: ${GREEN}${PASS}${NC} / ${TOTAL}"
if [ "$FAIL" -gt 0 ]; then
  echo -e "Failed: ${RED}${FAIL}${NC}"
  exit 1
else
  echo -e "${GREEN}Scenario (b) re-executed live: every transcript claim reproduced.${NC}"
  exit 0
fi
