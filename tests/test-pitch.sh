#!/usr/bin/env bash
# test-pitch.sh -- SPEC-140, kit-run-integrity mega-goal sub-goal 06 (ID-250).
#
# Proves /kit:pitch's assembly engine (lib/pitch.sh) is a grounded ASSEMBLER, never a writer:
#   AC1  real sample: render against a REAL recently-shipped rid (kit-emit-sweep) produces all
#        5 sections; committed as docs/verification/pitch-command/sample-pitch.md. The two
#        checks that depend on machine-local ledger state (the PR link, the grill-skip reason)
#        assert against a FROZEN fixture (tests/fixtures/pitch/real-sample/, a snapshot of the
#        same real content) instead of the live render, so CI's fresh checkout (no
#        ~/.local/state/dwarves-kit ledger for kit-emit-sweep) can't fail a check that only
#        ever worked on a dev machine that had already run/shipped that rid.
#   AC2  LOAD-BEARING NC: a rid with NO grill record in its ledger prints the literal line
#        "no grill record for this run" and nothing grill-shaped
#   AC3  LOAD-BEARING NC: a rid with NO docs/implementation-notes/<rid>.md file prints the
#        literal line "no implementation-notes file for this run" and no deviation content
#   AC4  contrastive: the SAME two checks against the "full" fixture (both sources present)
#        do NOT print the absence lines, and DO print the real fixture content
#   AC5  NEVER-AUTO-POST: neither lib/pitch.sh nor commands/pitch.md mentions gh pr/issue
#        comment, discord, slack, or curl
#   AC6  the commands/ship.md Step 8 advisory bullet is wired to the REAL commands (not a
#        paraphrase), and its condition (significance=high AND team-shared) is exercised
#        behaviorally against real ledger fixtures + a stubbed `gh`
#   AC7  team-shared is fail-safe: a failing/unavailable `gh` returns "no", exit 1
#
# Run: bash tests/test-pitch.sh   (exit 0 = all AC green)
set -uo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$KIT_DIR/lib/pitch.sh"
LEDGER="$KIT_DIR/lib/gate/gate-ledger.sh"
FIXTURES="$KIT_DIR/tests/fixtures/pitch"

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert() { TOTAL=$((TOTAL+1)); if [ "$2" -eq 0 ]; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1)); else echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL+1)); fi; }

# ------------------------------------------------------------------------------------------
# _mkws <fixture-name> -> prints a fresh scratch workspace dir with docs/{specs,verification,
# implementation-notes} populated from tests/fixtures/pitch/<fixture-name>/, plus a scratch
# DWARVES_KIT_LOG_DIR (so no test ever touches the real machine's run corpus, kit-log-dir.sh's
# own override contract) with ledger.log installed as runs/<fixture-name>.log.
# ------------------------------------------------------------------------------------------
_mkws() {
  local name="$1" src="$FIXTURES/$1" ws
  ws="$(mktemp -d)"
  mkdir -p "$ws/docs/specs" "$ws/docs/verification" "$ws/docs/implementation-notes" "$ws/logs/runs"
  [ -f "$src/spec.md" ] && cp "$src/spec.md" "$ws/docs/specs/SPEC-900-$name.md"
  [ -f "$src/proof.md" ] && cp "$src/proof.md" "$ws/docs/verification/$name.md"
  [ -f "$src/impl-notes.md" ] && cp "$src/impl-notes.md" "$ws/docs/implementation-notes/$name.md"
  [ -f "$src/ledger.log" ] && cp "$src/ledger.log" "$ws/logs/runs/$name.log"
  printf '%s' "$ws"
}

_render() {  # <fixture-name>
  local name="$1" ws
  ws="$(_mkws "$name")"
  ( cd "$ws" && DWARVES_KIT_LOG_DIR="$ws/logs" bash "$LIB" render "$name" )
}

# _render_with_origin <fixture-name> -- same as _render, but the scratch workspace is also a
# real (if empty) git repo with `origin` pointed at the real dwarvesf/dwarves-kit remote, so
# `_pr_url`'s `git remote get-url origin` resolves and the PR link renders as a real
# `.../pull/<N>` URL instead of the bare `#<N>` fallback. No network call: `git remote add`
# only writes local config.
_render_with_origin() {  # <fixture-name>
  local name="$1" ws
  ws="$(_mkws "$name")"
  ( cd "$ws" && git init -q && git remote add origin https://github.com/dwarvesf/dwarves-kit.git \
      && DWARVES_KIT_LOG_DIR="$ws/logs" bash "$LIB" render "$name" )
}

echo "=== AC1: real sample -- render against a REAL recently-shipped rid (kit-emit-sweep) ==="
PROOF_DIR="$KIT_DIR/docs/verification/pitch-command"
mkdir -p "$PROOF_DIR"
( cd "$KIT_DIR" && bash "$LIB" render kit-emit-sweep --out "$PROOF_DIR/sample-pitch.md" ) >/dev/null
assert "AC1 sample-pitch.md was written" "$([ -s "$PROOF_DIR/sample-pitch.md" ] && echo 0 || echo 1)"
SECTIONS=$(grep -cE '^## [1-5]\. ' "$PROOF_DIR/sample-pitch.md")
assert "AC1 all 5 numbered sections present (got $SECTIONS)" "$([ "$SECTIONS" -eq 5 ] && echo 0 || echo 1)"
assert "AC1 outcome section names the real spec (SPEC-139-kit-emit-sweep)" \
  "$(grep -qi 'command emit sweep' "$PROOF_DIR/sample-pitch.md" && echo 0 || echo 1)"
# The PR-link and grill-skip checks below need ledger content that only ever lives in
# ~/.local/state/dwarves-kit/logs (machine-local, per lib/telemetry/kit-log-dir.sh) -- absent on a fresh
# CI checkout. Assert against a frozen, committed fixture (a snapshot of the same real
# kit-emit-sweep content) rather than the live render, so the proof is CI-portable without
# weakening what it proves.
OUT_REAL_SAMPLE="$(_render_with_origin real-sample)"
assert "AC1 evidence section carries a real PR link (#168)" \
  "$({ trap '' PIPE; printf '%s' "$OUT_REAL_SAMPLE" 2>/dev/null || :; } | grep -q 'pull/168' && echo 0 || echo 1)"
assert "AC1 unknowns section surfaces the real grill skip (reason=operator-wave)" \
  "$({ trap '' PIPE; printf '%s' "$OUT_REAL_SAMPLE" 2>/dev/null || :; } | grep -q 'reason=operator-wave' && echo 0 || echo 1)"

echo ""
echo "=== AC2 + AC4a: grill record -- NO-grill fixture (load-bearing) vs full fixture (contrast) ==="
OUT_NOGRILL="$(_render no-grill)"
OUT_FULL="$(_render full)"
assert "AC2 no-grill fixture prints the literal absence line" \
  "$({ trap '' PIPE; printf '%s' "$OUT_NOGRILL" 2>/dev/null || :; } | grep -qF 'no grill record for this run' && echo 0 || echo 1)"
assert "AC2 no-grill fixture never fabricates a grill answer (no 'branches resolved' text)" \
  "$({ trap '' PIPE; printf '%s' "$OUT_NOGRILL" 2>/dev/null || :; } | grep -q 'branches resolved' && echo 1 || echo 0)"
assert "AC4a full fixture does NOT print the grill absence line" \
  "$({ trap '' PIPE; printf '%s' "$OUT_FULL" 2>/dev/null || :; } | grep -qF 'no grill record for this run' && echo 1 || echo 0)"
assert "AC4a full fixture DOES surface its real grill content" \
  "$({ trap '' PIPE; printf '%s' "$OUT_FULL" 2>/dev/null || :; } | grep -q 'branches resolved' && echo 0 || echo 1)"

echo ""
echo "=== AC3 + AC4b: implementation-notes -- NO-implnotes fixture (load-bearing) vs full fixture ==="
OUT_NOTES="$(_render no-implnotes)"
assert "AC3 no-implnotes fixture prints the literal absence line" \
  "$({ trap '' PIPE; printf '%s' "$OUT_NOTES" 2>/dev/null || :; } | grep -qF 'no implementation-notes file for this run' && echo 0 || echo 1)"
assert "AC3 no-implnotes fixture never fabricates a deviation (no 'fixture deviation' text)" \
  "$({ trap '' PIPE; printf '%s' "$OUT_NOTES" 2>/dev/null || :; } | grep -q 'fixture deviation' && echo 1 || echo 0)"
assert "AC4b full fixture does NOT print the implementation-notes absence line" \
  "$({ trap '' PIPE; printf '%s' "$OUT_FULL" 2>/dev/null || :; } | grep -qF 'no implementation-notes file for this run' && echo 1 || echo 0)"
assert "AC4b full fixture DOES surface its real deviation entries (both of them)" \
  "$([ "$(printf '%s' "$OUT_FULL" | grep -c 'fixture deviation')" -eq 2 ] && echo 0 || echo 1)"

echo ""
echo "=== AC4c: negative controls + evidence + cost sections, full fixture ==="
assert "AC4c unknowns section surfaces the proof's negative control" \
  "$({ trap '' PIPE; printf '%s' "$OUT_FULL" 2>/dev/null || :; } | grep -qi 'negative control' && echo 0 || echo 1)"
assert "AC4c evidence section carries the verbatim acceptance-criteria table" \
  "$({ trap '' PIPE; printf '%s' "$OUT_FULL" 2>/dev/null || :; } | grep -q 'fixture thing happens' && echo 0 || echo 1)"
assert "AC4c cost section surfaces the spec's Out of Scope block" \
  "$({ trap '' PIPE; printf '%s' "$OUT_FULL" 2>/dev/null || :; } | grep -q 'fixture-feature-x' && echo 0 || echo 1)"
assert "AC4c ask section is always emitted (pure template, no source to miss)" \
  "$({ trap '' PIPE; printf '%s' "$OUT_FULL" 2>/dev/null || :; } | grep -qi 'approve' && echo 0 || echo 1)"

echo ""
echo "=== AC5: NEVER-AUTO-POST (load-bearing) -- grep negative control ==="
# Checks the EXECUTABLE surface only, not prose that documents the boundary by naming the
# forbidden verbs (the exact self-referential fixture trap kit-emit-sweep's own impl-notes
# recorded: a "this file has no secrets" sentence trips a naive scanner on the word
# "secrets"). lib/pitch.sh's boundary comment and commands/pitch.md's "Rules"/"Step 2" prose
# both legitimately SAY "never gh pr comment / discord / slack / curl" -- that prose is the
# proof of intent, not a violation. What must be airtight is CODE: lib/pitch.sh's non-comment
# lines, and the fenced ```bash blocks in commands/pitch.md (the only text an agent actually
# executes).
FORBIDDEN='gh pr comment|gh issue comment|discord|slack|curl'
CODE_HITS=$(grep -vE '^\s*#' "$KIT_DIR/lib/pitch.sh" | grep -icE "$FORBIDDEN" || true)
BASH_BLOCKS=$(awk '/^```bash$/{f=1;next} /^```$/{f=0} f' "$KIT_DIR/commands/pitch.md")
BLOCK_HITS=$(printf '%s' "$BASH_BLOCKS" | grep -icE "$FORBIDDEN" || true)
assert "AC5 zero auto-post CALLS in lib/pitch.sh's executable lines (found: $CODE_HITS)" \
  "$([ "$CODE_HITS" -eq 0 ] && echo 0 || echo 1)"
assert "AC5 zero auto-post CALLS in commands/pitch.md's bash code blocks (found: $BLOCK_HITS)" \
  "$([ "$BLOCK_HITS" -eq 0 ] && echo 0 || echo 1)"
assert "AC5 commands/pitch.md explicitly documents it never posts (prose, not code)" \
  "$(grep -qi 'never post' "$KIT_DIR/commands/pitch.md" && echo 0 || echo 1)"

echo ""
echo "=== AC7: team-shared is fail-safe (stubbed gh, no network) ==="
FAKEBIN="$(mktemp -d)"
cat > "$FAKEBIN/gh" <<'STUB'
#!/usr/bin/env bash
case "${GH_STUB_MODE:-}" in
  org)  echo "Organization" ;;
  user) echo "User" ;;
  *)    exit 1 ;;
esac
STUB
chmod +x "$FAKEBIN/gh"

TS_ORG_OUT=$(PATH="$FAKEBIN:$PATH" GH_STUB_MODE=org bash "$LIB" team-shared); TS_ORG_RC=$?
assert "AC7 org owner -> prints 'yes', exit 0" "$([ "$TS_ORG_OUT" = "yes" ] && [ "$TS_ORG_RC" -eq 0 ] && echo 0 || echo 1)"

TS_USER_OUT=$(PATH="$FAKEBIN:$PATH" GH_STUB_MODE=user bash "$LIB" team-shared); TS_USER_RC=$?
assert "AC7 user (solo) owner -> prints 'no', exit 1" "$([ "$TS_USER_OUT" = "no" ] && [ "$TS_USER_RC" -eq 1 ] && echo 0 || echo 1)"

TS_FAIL_OUT=$(PATH="$FAKEBIN:$PATH" GH_STUB_MODE=fail bash "$LIB" team-shared); TS_FAIL_RC=$?
assert "AC7 gh failure -> fails SAFE ('no', exit 1), never throws" "$([ "$TS_FAIL_OUT" = "no" ] && [ "$TS_FAIL_RC" -eq 1 ] && echo 0 || echo 1)"

echo ""
echo "=== AC6: ship.md Step 8 advisory bullet -- wiring + behavioral condition ==="
SHIP="$KIT_DIR/commands/ship.md"
assert "AC6 ship.md names the real read-back command (gate-ledger.sh show | grep DEBT)" \
  "$(grep -qF "gate-ledger.sh show <rid> | grep '| DEBT |'" "$SHIP" && echo 0 || echo 1)"
assert "AC6 ship.md names the real team-shared predicate (lib/pitch.sh team-shared)" \
  "$(grep -qF 'lib/pitch.sh team-shared' "$SHIP" && echo 0 || echo 1)"
assert "AC6 ship.md states the bullet never blocks" \
  "$(grep -A2 'Pitch offer' "$SHIP" | grep -qi 'never blocks' && echo 0 || echo 1)"

# Behavioral: exercise the EXACT commands ship.md's bullet names, against real ledger
# fixtures (full = significance=high, no-implnotes = significance=low) + the stubbed gh.
_would_offer() {  # <fixture-name> <gh-stub-mode>
  local name="$1" mode="$2" ws last
  ws="$(_mkws "$name")"
  last="$(cd "$ws" && DWARVES_KIT_LOG_DIR="$ws/logs" bash "$LEDGER" show "$name" | grep '| DEBT |' | tail -1)"
  if { trap '' PIPE; printf '%s' "$last" 2>/dev/null || :; } | grep -q 'significance=high' \
     && PATH="$FAKEBIN:$PATH" GH_STUB_MODE="$mode" bash "$LIB" team-shared >/dev/null 2>&1; then
    echo yes
  else
    echo no
  fi
}
assert "AC6 high-significance + team-shared (org) -> offer fires" \
  "$([ "$(_would_offer full org)" = "yes" ] && echo 0 || echo 1)"
assert "AC6 low-significance + team-shared (org) -> offer does NOT fire" \
  "$([ "$(_would_offer no-implnotes org)" = "no" ] && echo 0 || echo 1)"
assert "AC6 high-significance + solo repo (user) -> offer does NOT fire" \
  "$([ "$(_would_offer full user)" = "no" ] && echo 0 || echo 1)"

echo ""
echo "  ---------------------------------------------"
echo "  TOTAL: $TOTAL   PASS: $PASS   FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
