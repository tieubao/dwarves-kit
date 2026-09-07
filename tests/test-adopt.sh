#!/usr/bin/env bash
# test-adopt.sh -- lib/adopt.sh: fresh adopt, idempotency, --check, no-clobber.
set -uo pipefail
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok - $1"; }
no() { FAIL=$((FAIL + 1)); echo "NOT ok - $1"; }

newrepo() { local d; d="$(mktemp -d)"; git -C "$d" init -q; echo "$d"; }

# 1. fresh adopt creates the 4 artifacts
T1="$(newrepo)"
bash lib/adopt.sh "$T1" >/dev/null
if [ -f "$T1/AGENTS.md" ] && [ -f "$T1/WORKFLOW.md" ] && [ -f "$T1/docs/verification/README.md" ] \
  && grep -q 'kit:adopt' "$T1/CLAUDE.md"; then
  ok "fresh adopt creates AGENTS.md + WORKFLOW pointer + CLAUDE pointer + proof marker"
else
  no "fresh adopt artifacts"
fi

# 2. idempotent re-run = clean git diff
git -C "$T1" add -A
git -C "$T1" -c user.email=t@t -c user.name=t commit -qm init
bash lib/adopt.sh "$T1" >/dev/null
if git -C "$T1" diff --quiet; then ok "re-run is a clean no-op (idempotent)"; else no "re-run dirtied the tree"; fi

# 3. --check: 0 on adopted, 1 on fresh
if bash lib/adopt.sh --check "$T1" >/dev/null; then ok "--check exits 0 on an adopted repo"; else no "--check should be 0 on adopted"; fi
T2="$(newrepo)"
if bash lib/adopt.sh --check "$T2" >/dev/null; then no "--check should be 1 on a fresh repo"; else ok "--check exits 1 on a fresh repo"; fi

# 4. no-clobber: a pre-existing AGENTS.md is never overwritten
T3="$(newrepo)"
printf 'SENTINEL-DO-NOT-CLOBBER\n' > "$T3/AGENTS.md"
bash lib/adopt.sh "$T3" >/dev/null
if grep -q SENTINEL-DO-NOT-CLOBBER "$T3/AGENTS.md"; then ok "existing AGENTS.md is not clobbered"; else no "AGENTS.md was clobbered"; fi

# 5. CLAUDE.md loader uses an @AGENTS.md import + paired markers
if grep -q '@AGENTS.md' "$T1/CLAUDE.md" && grep -q '<!-- /kit:adopt -->' "$T1/CLAUDE.md"; then
  ok "CLAUDE.md loader uses @AGENTS.md import + paired end marker"
else
  no "CLAUDE.md loader missing @-import or end marker"
fi

# 6. --dry-run writes nothing
T4="$(newrepo)"
bash lib/adopt.sh --dry-run "$T4" >/dev/null
if [ ! -f "$T4/AGENTS.md" ] && [ ! -f "$T4/CLAUDE.md" ]; then ok "--dry-run writes nothing"; else no "--dry-run wrote files"; fi

# 7. --refresh keeps exactly one managed block (idempotent replace)
bash lib/adopt.sh --refresh "$T1" >/dev/null
s=$(grep -c '<!-- kit:adopt -->' "$T1/CLAUDE.md"); e=$(grep -c '<!-- /kit:adopt -->' "$T1/CLAUDE.md")
if [ "$s" = 1 ] && [ "$e" = 1 ]; then ok "--refresh keeps a single managed block"; else no "--refresh duplicated the block (s=$s e=$e)"; fi

# 8. --refresh REFUSES to truncate a block whose END marker is gone (review CRITICAL #1: the awk
#    strip would otherwise drop everything from START to EOF and mv the truncated file).
T5="$(newrepo)"
bash lib/adopt.sh "$T5" >/dev/null
printf 'TAIL-SENTINEL-KEEP-ME\n' >> "$T5/CLAUDE.md"
grep -v '<!-- /kit:adopt -->' "$T5/CLAUDE.md" > "$T5/CLAUDE.noend" && mv "$T5/CLAUDE.noend" "$T5/CLAUDE.md"
cp "$T5/CLAUDE.md" "$T5/CLAUDE.before"
if bash lib/adopt.sh --refresh "$T5" >/dev/null 2>&1; then
  no "--refresh should FAIL on a block missing its END marker"
elif cmp -s "$T5/CLAUDE.md" "$T5/CLAUDE.before" && grep -q TAIL-SENTINEL-KEEP-ME "$T5/CLAUDE.md"; then
  ok "--refresh refuses to truncate a block missing its END marker (file untouched)"
else
  no "--refresh mutated a file it should have refused (tail lost)"
fi

# 9. --refresh re-syncs a STALE block body (the actual purpose, not just idempotency) and keeps
#    the surrounding prose.
T6="$(newrepo)"
printf '# Repo\n\n<!-- kit:adopt -->\nSTALE-BODY\n<!-- /kit:adopt -->\n\n## Keep this tail\n' > "$T6/CLAUDE.md"
bash lib/adopt.sh --refresh "$T6" >/dev/null
if ! grep -q STALE-BODY "$T6/CLAUDE.md" && grep -q '@AGENTS.md' "$T6/CLAUDE.md" && grep -q 'Keep this tail' "$T6/CLAUDE.md"; then
  ok "--refresh replaces a stale block body and preserves surrounding content"
else
  no "--refresh did not re-sync the stale block or lost surrounding content"
fi

# 10. --refresh never overwrites AGENTS.md or the proof marker (documented invariant).
T7="$(newrepo)"
bash lib/adopt.sh "$T7" >/dev/null
printf 'AGENTS-SENTINEL\n' >> "$T7/AGENTS.md"
printf 'MARKER-SENTINEL\n' >> "$T7/docs/verification/README.md"
bash lib/adopt.sh --refresh "$T7" >/dev/null
if grep -q AGENTS-SENTINEL "$T7/AGENTS.md" && grep -q MARKER-SENTINEL "$T7/docs/verification/README.md"; then
  ok "--refresh preserves AGENTS.md + proof marker (never overwritten)"
else
  no "--refresh overwrote AGENTS.md or the proof marker"
fi

# 11. --dry-run on an already-adopted repo writes nothing (T1 was committed in test 2).
bash lib/adopt.sh --dry-run "$T1" >/dev/null
if git -C "$T1" diff --quiet; then ok "--dry-run on an adopted repo writes nothing"; else no "--dry-run dirtied an adopted repo"; fi

# ------------------------------------------------------------------------------------------
# SPEC-192 (goal 06, harness-ops): per-project .kit.toml override + adopt-time module wiring.
# The resolver (lib/config/kit-config.sh, goal 01) already merges <project>/.kit.toml over the
# kit-root default; these tests close the loop through adopt: a starter .kit.toml is seeded,
# and the currently-enabled hook-modules (board/session/advisor/cosmetic) are wired into
# <project>/.claude/settings.json at adopt time.
# ------------------------------------------------------------------------------------------
wired_hooks() { jq -r '[.hooks // {} | to_entries[]? | .value[]? | .hooks[]? | .command] | .[]' "$1" 2>/dev/null | grep -oE 'dwarves-kit/hooks/[A-Za-z0-9._-]+\.sh' | sed 's#dwarves-kit/hooks/##' | sort -u; }

if ! command -v jq >/dev/null 2>&1; then
  echo "skip - SPEC-192 module-wiring tests need jq; not found on PATH"
else

# 12. Fresh adopt seeds a starter .kit.toml with a [modules] section naming every known module.
T8="$(newrepo)"
bash lib/adopt.sh "$T8" >/dev/null
if [ -f "$T8/.kit.toml" ] && grep -q '^\[modules\]' "$T8/.kit.toml" \
  && grep -qE '^board[[:space:]]*=' "$T8/.kit.toml" && grep -qE '^cosmetic[[:space:]]*=' "$T8/.kit.toml"; then
  ok "fresh adopt seeds a starter .kit.toml with a [modules] section"
else
  no "fresh adopt did not seed .kit.toml with the expected [modules] section"
fi

# 13. That same fresh adopt wires the kit-root-default-enabled modules' hooks into the
# project's settings.json (board/session/advisor default true; cosmetic defaults false).
W13="$(wired_hooks "$T8/.claude/settings.json")"
if { printf '%s\n' "$W13" 2>/dev/null || :; } | grep -qx backlog-stage.sh && { printf '%s\n' "$W13" 2>/dev/null || :; } | grep -qx context-hints.sh \
  && ! { printf '%s\n' "$W13" 2>/dev/null || :; } | grep -qx auto-format.sh; then
  ok "fresh adopt wires kit-root-default-enabled modules' hooks (board/advisor in, cosmetic out)"
else
  no "fresh adopt wired the wrong hook set: [$W13]"
fi

# 14. --with on a FRESH repo seeds the named modules true and wires their hooks even when the
# kit-root default is false (cosmetic defaults false; --with cosmetic turns it on for THIS repo).
T9="$(newrepo)"
bash lib/adopt.sh --with cosmetic "$T9" >/dev/null
if grep -qx 'cosmetic = true' "$T9/.kit.toml" \
  && { printf '%s\n' "$(wired_hooks "$T9/.claude/settings.json")" 2>/dev/null || :; } | grep -qx auto-format.sh; then
  ok "--with cosmetic on a fresh repo seeds cosmetic=true and wires its hook"
else
  no "--with cosmetic did not seed/wire cosmetic for a fresh repo"
fi

# 15. THE Done= proof: a project .kit.toml [modules] board=false results in that project NOT
# wiring the board hook (backlog-stage.sh), verified via its settings.json.
T10="$(newrepo)"
bash lib/adopt.sh "$T10" >/dev/null
W15_BEFORE="$(wired_hooks "$T10/.claude/settings.json")"
{ printf '%s\n' "$W15_BEFORE" 2>/dev/null || :; } | grep -qx backlog-stage.sh \
  && ok "precondition: board's hook is wired before the override (kit-root default board=true)" \
  || no "precondition failed: board's hook was never wired to begin with"
sed -i.bak 's/^board = true$/board = false/' "$T10/.kit.toml" && rm -f "$T10/.kit.toml.bak"
grep -qx 'board = false' "$T10/.kit.toml" || no "test setup: could not flip board=false in $T10/.kit.toml"
bash lib/adopt.sh --refresh "$T10" >/dev/null
W15_AFTER="$(wired_hooks "$T10/.claude/settings.json")"
if ! { printf '%s\n' "$W15_AFTER" 2>/dev/null || :; } | grep -qx backlog-stage.sh; then
  ok "DONE=: project .kit.toml [modules] board=false -> board's hook is NOT wired (settings.json)"
else
  no "DONE=: board=false in .kit.toml did not stop board's hook from being wired"
fi
# session's hook must be untouched by the board-only edit (surgical re-wiring, not a full reset).
if { printf '%s\n' "$W15_AFTER" 2>/dev/null || :; } | grep -qx context-readiness.sh; then
  ok "re-wiring after a board=false edit leaves the still-enabled session module's hooks wired"
else
  no "re-wiring after a board=false edit dropped an unrelated still-enabled module's hooks"
fi

# 16. THE Done= proof, second clause: a [ledger] override in the project .kit.toml is honored
# by a command reading it (the resolver from goal 01, exercised end-to-end through a real
# adopted project directory rather than a synthetic fixture).
T11="$(newrepo)"
bash lib/adopt.sh "$T11" >/dev/null
printf '\n[ledger]\nlocation = "isolated"\n' >> "$T11/.kit.toml"
KIT_REPO_ROOT="$(pwd)"
LEDGER_VAL="$(KIT_CONFIG_ROOT="$KIT_REPO_ROOT" KIT_PROJECT_ROOT="$T11" bash -c "source '$KIT_REPO_ROOT/lib/config/kit-config.sh'; kit_config_get ledger.location")"
if [ "$LEDGER_VAL" = "isolated" ]; then
  ok "DONE=: a [ledger] override in the project .kit.toml is honored by the resolver"
else
  no "DONE=: [ledger] override was not honored (got [$LEDGER_VAL], want isolated)"
fi

# 17. --with is ignored (never clobbers) once <project>/.kit.toml already exists.
bash lib/adopt.sh --with cosmetic "$T11" >/dev/null 2>&1
if ! grep -qx 'cosmetic = true' "$T11/.kit.toml"; then
  ok "--with is ignored once .kit.toml already exists (never overwritten)"
else
  no "--with clobbered an existing .kit.toml"
fi

# 18. Idempotent re-run after a config edit: re-running adopt again with NO further edits is a
# clean no-op on the module wiring (settled state is stable, not re-churned every run).
git -C "$T10" init -q >/dev/null 2>&1 || true
git -C "$T10" add -A && git -C "$T10" -c user.email=t@t -c user.name=t commit -qm settle >/dev/null
bash lib/adopt.sh --refresh "$T10" >/dev/null
if git -C "$T10" diff --quiet; then
  ok "re-running adopt --refresh with an unchanged .kit.toml is a clean no-op on module wiring"
else
  no "re-running adopt --refresh churned settings.json with no .kit.toml change"
fi

rm -rf "$T8" "$T9" "$T10" "$T11"
fi

rm -rf "$T1" "$T2" "$T3" "$T4" "$T5" "$T6" "$T7"
echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
