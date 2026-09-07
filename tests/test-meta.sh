#!/bin/bash
# test-meta.sh -- Structural integrity tests for kit artifacts.
# Catches drift the unit tests can't see: version mismatches, missing
# frontmatter, stale references between files, schema violations.
#
# Run: bash tests/test-meta.sh
# Exit 0 = all tests pass. Exit 1 = failures found.
#
# Source: added in v1.5.1 after retro-review of v1.4 and v1.5 surfaced
# a live version drift bug (plugin.json said 1.4.0 while VERSION said 1.5.0).

KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_eq() {
  local NAME="$1" EXPECTED="$2" ACTUAL="$3"
  TOTAL=$((TOTAL + 1))
  if [ "$ACTUAL" = "$EXPECTED" ]; then
    echo -e "  ${GREEN}PASS${NC} $NAME"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} $NAME (expected '$EXPECTED', got '$ACTUAL')"
    FAIL=$((FAIL + 1))
  fi
}

assert_true() {
  local NAME="$1" RC="$2"
  TOTAL=$((TOTAL + 1))
  if [ "$RC" -eq 0 ]; then
    echo -e "  ${GREEN}PASS${NC} $NAME"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} $NAME"
    FAIL=$((FAIL + 1))
  fi
}

# ============================================================
echo "=== Plugin manifest schema ==="
# ============================================================

# plugin.json: name, version, description present
PLUGIN_NAME=$(jq -r '.name' "$KIT_DIR/.claude-plugin/plugin.json")
assert_eq "plugin.json name == 'kit'" "kit" "$PLUGIN_NAME"

PLUGIN_VERSION=$(jq -r '.version' "$KIT_DIR/.claude-plugin/plugin.json")
VERSION_FILE=$(cat "$KIT_DIR/VERSION" | tr -d '[:space:]')
assert_eq "plugin.json version matches VERSION file" "$VERSION_FILE" "$PLUGIN_VERSION"

# SPEC-115: the THIRD version surface (tool.toml) must match too , the v1.7.0 cut
# missed it (tool.toml drifted to 1.6.0); this three-surface pin kills that class.
TOOL_TOML_VERSION=$(grep -E '^version' "$KIT_DIR/tool.toml" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
assert_eq "tool.toml version matches VERSION file (3-surface pin, SPEC-115)" "$VERSION_FILE" "$TOOL_TOML_VERSION"

# ============================================================
echo "=== Invocation namespace guard (SPEC-029, SPEC-030) ==="
# ============================================================
# The kit's commands resolve as /kit:<cmd> (plugin) or bare /<cmd> (bash install).
# /user:<cmd> is the dead reserved-prefix form and must not appear in LIVE docs
# OR in the runtime surfaces that print command hints (install.sh, hooks/*.sh).
# Denylist, not allowlist (DEC-004): scan every tracked *.md EXCEPT the dated,
# point-in-time dirs (specs/retros/ADRs/handoff/research), PLUS install.sh and
# hooks/*.sh (SPEC-030 DEC-003), so a future live doc OR hook is covered
# automatically. tests/ is NOT scanned: this file names /user: to describe the
# guard. Enforces /user: ABSENCE only (DEC-005); bare-/cmd is not auto-checked.
USER_NS_HITS=$(cd "$KIT_DIR" && { git ls-files '*.md' \
      | grep -vE '^(docs/specs/|docs/retro/|docs/decisions/|docs/handoff/|docs/research/|docs/verification/|_meta/|CHANGELOG\.md|docs/CHANGELOG\.md)'; \
    git ls-files 'install.sh' 'hooks/*.sh'; } \
  | xargs grep -l '/user:' 2>/dev/null)
if [ -n "$USER_NS_HITS" ]; then
  echo "  live files still using /user::" >&2
  echo "$USER_NS_HITS" | sed 's/^/    /' >&2
fi
[ -z "$USER_NS_HITS" ]; assert_true "no /user: invocation form in live docs/install/hooks (SPEC-029, SPEC-030)" $?

PLUGIN_DESC=$(jq -r '.description // ""' "$KIT_DIR/.claude-plugin/plugin.json")
TOTAL=$((TOTAL + 1))
if [ -n "$PLUGIN_DESC" ]; then
  echo -e "  ${GREEN}PASS${NC} plugin.json has description"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} plugin.json description empty"
  FAIL=$((FAIL + 1))
fi

# marketplace.json: plugins[0].name matches plugin.json.name
MP_PLUGIN_NAME=$(jq -r '.plugins[0].name' "$KIT_DIR/.claude-plugin/marketplace.json")
assert_eq "marketplace.json plugins[0].name == plugin.json name" "$PLUGIN_NAME" "$MP_PLUGIN_NAME"

MP_NAME=$(jq -r '.name' "$KIT_DIR/.claude-plugin/marketplace.json")
assert_eq "marketplace.json name == 'dwarves-marketplace'" "dwarves-marketplace" "$MP_NAME"

# ============================================================
echo ""
echo "=== Hook registration parity (settings.json vs hooks/hooks.json) ==="
# ============================================================

H1=$(jq '[.hooks | to_entries[] | .value[] | .hooks[]] | length' "$KIT_DIR/settings.json")
H2=$(jq '[.hooks | to_entries[] | .value[] | .hooks[]] | length' "$KIT_DIR/hooks/hooks.json")
assert_eq "hook count parity (settings.json == hooks.json)" "$H1" "$H2"

# All hooks.json paths use ${CLAUDE_PLUGIN_ROOT}
NON_PLUGIN_PATHS=$(jq -r '[.hooks | to_entries[] | .value[] | .hooks[].command] | .[]' "$KIT_DIR/hooks/hooks.json" | grep -v '\${CLAUDE_PLUGIN_ROOT}' | wc -l | tr -d ' ')
assert_eq "all hooks.json paths use \${CLAUDE_PLUGIN_ROOT}" "0" "$NON_PLUGIN_PATHS"

# Same set of event types in both
EVENTS_SETTINGS=$(jq -r '.hooks | keys | sort | join(",")' "$KIT_DIR/settings.json")
EVENTS_HOOKS=$(jq -r '.hooks | keys | sort | join(",")' "$KIT_DIR/hooks/hooks.json")
assert_eq "same event types in both files" "$EVENTS_SETTINGS" "$EVENTS_HOOKS"

# ============================================================
echo ""
echo "=== Hook executability ==="
# ============================================================

# Every hook script must carry the exec bit. They run via `bash <script>`
# at runtime so a missing bit is silent, which is exactly why CI never
# caught session-state-save.sh shipping as 100644. kit-health flags it;
# this asserts it so it cannot regress past CI again. Offenders are named
# in the test label on failure.
NON_EXEC=$(for f in "$KIT_DIR"/hooks/*.sh; do [ -x "$f" ] || basename "$f"; done | tr '\n' ' ' | sed 's/ $//')
NON_EXEC_COUNT=$(printf '%s' "$NON_EXEC" | wc -w | tr -d ' ')
assert_eq "all hooks/*.sh are executable (non-exec: ${NON_EXEC:-none})" "0" "$NON_EXEC_COUNT"

# ============================================================
echo ""
echo "=== Installer materializes the hooks settings.json references ==="
# ============================================================
# settings.json hard-codes $HOME/.claude/dwarves-kit/hooks/<script>.sh for every
# hook (and the statusline). install.sh must place each script at that path, or
# every hook fails at runtime with "No such file or directory". This regressed
# once: settings referenced the hooks but install.sh never installed them, so a
# fresh session greeted the user with a SessionStart hook error.

# (1) Each referenced script exists in the repo's hooks/ dir.
MISSING_IN_REPO=$(grep -oE 'dwarves-kit/hooks/[A-Za-z0-9._-]+\.sh' "$KIT_DIR/settings.json" \
  | sed 's#.*/##' | sort -u \
  | while read -r s; do [ -f "$KIT_DIR/hooks/$s" ] || echo "$s"; done \
  | tr '\n' ' ' | sed 's/ $//')
assert_eq "every settings.json hook script exists in hooks/ (missing: ${MISSING_IN_REPO:-none})" "" "$MISSING_IN_REPO"

# (2) A real install into a throwaway HOME leaves every referenced path resolvable.
# This is the direct regression guard: it fails on the buggy installer that never
# materialized the scripts, and passes once install.sh links them into place.
TMP_HOME=$(mktemp -d)
if HOME="$TMP_HOME" bash "$KIT_DIR/install.sh" >/dev/null 2>&1; then
  UNRESOLVED=$(grep -oE '\$HOME/\.claude/dwarves-kit/hooks/[A-Za-z0-9._-]+\.sh' "$TMP_HOME/.claude/settings.json" \
    | sort -u \
    | while read -r raw; do p=${raw/\$HOME/$TMP_HOME}; [ -f "$p" ] || echo "$p"; done \
    | tr '\n' ' ' | sed 's/ $//')
  assert_eq "install.sh resolves every dwarves-kit hook path (unresolved: ${UNRESOLVED:-none})" "" "$UNRESOLVED"
  # SPEC-045: install must materialize lib/ so the gates resolve from the stable
  # install path in consumer repos (else the proof-of-done gate fails open everywhere
  # but dwarves-kit). -e follows the dir symlink to the real file.
  [ -e "$TMP_HOME/.claude/dwarves-kit/lib/gate/proof-ledger.sh" ]
  assert_true "install.sh materializes lib/gate/proof-ledger.sh (SPEC-045)" $?
  # SPEC-049: install must materialize the operate-contract too, so adopt (needs a source
  # AGENTS.md) + gate-ledger (reads WORKFLOW.md) work from the install, not only the dev
  # checkout. Asserts the REAL install run, not test-install-contract.sh's simulated layout.
  [ -e "$TMP_HOME/.claude/dwarves-kit/AGENTS.md" ]
  assert_true "install.sh materializes AGENTS.md (SPEC-049)" $?
  [ -e "$TMP_HOME/.claude/dwarves-kit/WORKFLOW.md" ]
  assert_true "install.sh materializes WORKFLOW.md (SPEC-049)" $?
  # SPEC-185: WORKFLOW.md's bulk moved to docs/WORKFLOW.md (root is a thin stub); gate-ledger
  # reads $KIT_ROOT/docs/WORKFLOW.md at runtime, so install.sh must ALSO materialize that file
  # or every installed consumer's gate machinery 404s against an uncopied docs/ path.
  [ -e "$TMP_HOME/.claude/dwarves-kit/docs/WORKFLOW.md" ]
  assert_true "install.sh materializes docs/WORKFLOW.md bulk (SPEC-185)" $?
  N_INSTALLED=$(CLAUDE_PLUGIN_ROOT="$TMP_HOME/.claude/dwarves-kit" bash "$TMP_HOME/.claude/dwarves-kit/lib/gate/gate-ledger.sh" required full 2>/dev/null | wc -l | tr -d ' ')
  assert_true "installed stub's pointer resolves: gate-ledger reads the lane matrix from the install ($N_INSTALLED gates, SPEC-185)" "$([ "${N_INSTALLED:-0}" -ge 5 ]; echo $?)"
  # SPEC-049: uninstall removes the two contract symlinks (the new uninstall code path).
  HOME="$TMP_HOME" bash "$KIT_DIR/install.sh" --uninstall >/dev/null 2>&1
  { [ ! -L "$TMP_HOME/.claude/dwarves-kit/AGENTS.md" ] && [ ! -L "$TMP_HOME/.claude/dwarves-kit/WORKFLOW.md" ]; }
  assert_true "uninstall removes the AGENTS.md + WORKFLOW.md symlinks (SPEC-049)" $?
  [ ! -L "$TMP_HOME/.claude/dwarves-kit/docs/WORKFLOW.md" ]
  assert_true "uninstall removes the docs/WORKFLOW.md symlink (SPEC-185)" $?
else
  assert_eq "install.sh runs cleanly into an isolated HOME" "ok" "failed"
fi
rm -rf "$TMP_HOME"

# (3) In-place layout (README Option 2: the kit is cloned to ~/.claude/dwarves-kit)
# must NOT clobber the real hook scripts. Regression: when KIT_DIR == the install
# destination, the per-file link step rm'd each script and replaced it with a
# self-referential broken symlink. Here the scripts must stay resolvable.
INPLACE_HOME=$(mktemp -d)
mkdir -p "$INPLACE_HOME/.claude/dwarves-kit"
cp -R "$KIT_DIR/hooks" "$KIT_DIR/commands" "$KIT_DIR/agents" "$KIT_DIR/skills" \
      "$KIT_DIR/settings.json" "$KIT_DIR/install.sh" "$INPLACE_HOME/.claude/dwarves-kit/" 2>/dev/null
HOME="$INPLACE_HOME" bash "$INPLACE_HOME/.claude/dwarves-kit/install.sh" >/dev/null 2>&1
INPLACE_BROKEN=$(for f in "$INPLACE_HOME/.claude/dwarves-kit/hooks/"*.sh; do [ -f "$f" ] || basename "$f"; done \
  | tr '\n' ' ' | sed 's/ $//')
assert_eq "in-place install keeps hook scripts resolvable (broken: ${INPLACE_BROKEN:-none})" "" "$INPLACE_BROKEN"
rm -rf "$INPLACE_HOME"

# ============================================================
echo ""
echo "=== AGENTS.md operating layer (SPEC-024) ==="
# ============================================================
# Part A: pin the cycle's structural outputs so a wording flip fails CI.
#   1. kit-root AGENTS.md exists + carries the four portable zones + the literal
#      "Pause if" + the CC-only-enforcement statement.
#   2. commands/assign.md carries the six-section /goal projection (the writer
#      side of the AGENTS.md->assign.md projection).
#   3. Low-cost regression guards for TASK-003 (hello-spec AGENTS.md) and
#      TASK-006 (spec.md "## After state").

AGENTS_MD="$KIT_DIR/AGENTS.md"
TOTAL=$((TOTAL + 1))
if [ -f "$AGENTS_MD" ]; then
  echo -e "  ${GREEN}PASS${NC} AGENTS.md exists at kit root (SPEC-024)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} AGENTS.md missing at kit root"
  FAIL=$((FAIL + 1))
fi

# The four portable zones (DEC-005). Pin the heading literals, not prose.
for ZONE in "## 1. Read in this order" "## 2. Task loop" "## 3. Done means" "## 4. Pause if (ask a human)"; do
  TOTAL=$((TOTAL + 1))
  if grep -qF "$ZONE" "$AGENTS_MD" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC} AGENTS.md has zone '$ZONE'"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} AGENTS.md missing zone '$ZONE'"
    FAIL=$((FAIL + 1))
  fi
done

# The literal "Pause if" (the fourth zone's stable phrase, also the goal section).
TOTAL=$((TOTAL + 1))
if grep -qF 'Pause if' "$AGENTS_MD" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} AGENTS.md carries the literal 'Pause if'"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} AGENTS.md lost the literal 'Pause if'"
  FAIL=$((FAIL + 1))
fi

# The CC-only-enforcement statement (PHILOSOPHY honesty rule: never over-claim
# portable enforcement). A drift to "enforcement is portable" would be a lie.
TOTAL=$((TOTAL + 1))
if grep -qF 'Enforcement is Claude-Code-only' "$AGENTS_MD" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} AGENTS.md states enforcement is Claude-Code-only"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} AGENTS.md lost the CC-only-enforcement statement"
  FAIL=$((FAIL + 1))
fi

# commands/assign.md carries the six-section projection (the writer side). A
# wording flip on any section name breaks the AGENTS.md->assign.md projection.
ASSIGN_MD="$KIT_DIR/commands/assign.md"
for SECTION in "Context-to-read" "Constraints" "Operating rules" "Validation loop" "Done-when" "Pause-if"; do
  TOTAL=$((TOTAL + 1))
  if grep -qF "$SECTION" "$ASSIGN_MD" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC} assign.md has projection section '$SECTION'"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} assign.md missing projection section '$SECTION'"
    FAIL=$((FAIL + 1))
  fi
done

# Low-cost regression guards: TASK-003 (hello-spec AGENTS.md w/ "Pause if") and
# TASK-006 (spec.md template's "## After state"). Pin both so they cannot silently
# regress.
DEMO_AGENTS="$KIT_DIR/examples/hello-spec/AGENTS.md"
TOTAL=$((TOTAL + 1))
if [ -f "$DEMO_AGENTS" ] && grep -qF 'Pause if' "$DEMO_AGENTS" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} examples/hello-spec/AGENTS.md exists + carries 'Pause if' (TASK-003)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} examples/hello-spec/AGENTS.md missing or lost 'Pause if'"
  FAIL=$((FAIL + 1))
fi

# Review issue 2: the downstream template (the file real projects copy) must pin
# all four zone headings too, not just "Pause if" - same teeth as the kit root.
for ZONE in "## 1. Read in this order" "## 2. Task loop" "## 3. Done means" "## 4. Pause if (ask a human)"; do
  TOTAL=$((TOTAL + 1))
  if grep -qF "$ZONE" "$DEMO_AGENTS" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC} examples/hello-spec/AGENTS.md has zone '$ZONE'"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} examples/hello-spec/AGENTS.md missing zone '$ZONE'"
    FAIL=$((FAIL + 1))
  fi
done

TOTAL=$((TOTAL + 1))
if grep -qF '## After state' "$KIT_DIR/commands/spec.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} commands/spec.md template carries '## After state' (TASK-006)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} commands/spec.md template lost '## After state'"
  FAIL=$((FAIL + 1))
fi

# Review issue 6: assign.md Done-when must reference the spec's "## After state"
# (the projection source), not merely carry the "Done-when" label.
TOTAL=$((TOTAL + 1))
if grep -qF '## After state' "$ASSIGN_MD" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} assign.md Done-when references the spec's '## After state'"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} assign.md Done-when lost the '## After state' projection source"
  FAIL=$((FAIL + 1))
fi

# Review issue 1 (anti-drift): the spec's primary failure mode is a CC-layer doc
# RESTATING the ordered read-list that AGENTS.md owns (zone 1 is the single source).
# WORKFLOW.md and CLAUDE.md must point, not carry a numbered "1. AGENTS.md /
# 2. CLAUDE.md ..." restatement. A reappearance is drift; fail loudly. Scoped to
# these two CC-layer docs; AGENTS.md itself legitimately carries the list.
# SPEC-185: WORKFLOW.md's bulk lives at docs/WORKFLOW.md; check both the root stub and the bulk.
for DOC in WORKFLOW.md docs/WORKFLOW.md CLAUDE.md; do
  RESTATE=$(grep -cE '^[0-9]+\.[[:space:]]+(AGENTS|CLAUDE)\.md' "$KIT_DIR/$DOC" 2>/dev/null || true)
  assert_eq "$DOC does not restate the AGENTS.md read-order list (no drift)" "0" "$RESTATE"
done

# ------------------------------------------------------------
# Part B: install.sh merge-with-existing-hooks regression (DEC-004).
# The existing installer test runs into a HOME with NO settings.json, so it never
# exercises the jq clean+merge path. This test pre-seeds settings.json with a
# THIRD-PARTY hook (a command that does NOT contain "dwarves-kit") and asserts the
# merge preserves it, yields valid JSON, and still pulls in a dwarves-kit hook.
MERGE_HOME=$(mktemp -d)
mkdir -p "$MERGE_HOME/.claude"
THIRD_PARTY_CMD="/opt/acme/hooks/audit-log.sh"
# Build the pre-existing settings via jq so it is always well-formed JSON.
jq -n --arg cmd "$THIRD_PARTY_CMD" '{
  hooks: {
    PreToolUse: [
      { matcher: "Bash", hooks: [ { type: "command", command: $cmd } ] }
    ]
  }
}' > "$MERGE_HOME/.claude/settings.json"

HOME="$MERGE_HOME" bash "$KIT_DIR/install.sh" >/dev/null 2>&1
MERGED_SETTINGS="$MERGE_HOME/.claude/settings.json"

# (a) the third-party hook command survived the merge.
TOTAL=$((TOTAL + 1))
if grep -qF "$THIRD_PARTY_CMD" "$MERGED_SETTINGS" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} install merge preserves the third-party hook (DEC-004)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} install merge DROPPED the third-party hook (merge bug)"
  FAIL=$((FAIL + 1))
fi

# (b) the resulting settings.json is valid JSON.
TOTAL=$((TOTAL + 1))
if jq '.' "$MERGED_SETTINGS" >/dev/null 2>&1; then
  echo -e "  ${GREEN}PASS${NC} merged settings.json is valid JSON"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} merged settings.json is not valid JSON (merge corrupted it)"
  FAIL=$((FAIL + 1))
fi

# (c) at least one dwarves-kit hook was merged in alongside the third-party one.
TOTAL=$((TOTAL + 1))
KIT_HOOK_COUNT=$(jq '[.hooks | to_entries[] | .value[] | .hooks[] | select(.command | tostring | contains("dwarves-kit"))] | length' "$MERGED_SETTINGS" 2>/dev/null || echo 0)
if [ "${KIT_HOOK_COUNT:-0}" -gt 0 ]; then
  echo -e "  ${GREEN}PASS${NC} install merge added at least one dwarves-kit hook ($KIT_HOOK_COUNT)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} install merge added no dwarves-kit hooks"
  FAIL=$((FAIL + 1))
fi
rm -rf "$MERGE_HOME"

# ============================================================
echo ""
echo "=== Freeform front door (SPEC-026) ==="
# ============================================================
# Pin the SPEC-026 contract in commands/assign.md so a wording flip on any of
# the intake paths, the /kit:think delegation, or the four invariants fails CI.
# All literals exist in assign.md today; this guards them from silent drift.
# ASSIGN_MD is set in the SPEC-024 block above.

# Two-shape resolver: the ID-first regex AND the freeform branch must both be named.
for LITERAL in '^ID-[0-9]+$' 'freeform'; do
  TOTAL=$((TOTAL + 1))
  if grep -qF "$LITERAL" "$ASSIGN_MD" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC} assign.md documents the '$LITERAL' intake shape (SPEC-026)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} assign.md lost the '$LITERAL' intake shape (resolver drift)"
    FAIL=$((FAIL + 1))
  fi
done

# Delegation: the crystallize interview is delegated to /kit:think, not embedded (DEC-003).
TOTAL=$((TOTAL + 1))
if grep -qF '/kit:think' "$ASSIGN_MD" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} assign.md delegates crystallize to /kit:think (SPEC-026 DEC-003)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} assign.md lost the /kit:think delegation (interview embedded?)"
  FAIL=$((FAIL + 1))
fi

# The four invariants. atomic-allocate is pinned via BOTH its named marker and the
# 'collision' guard wording, since both literals are load-bearing in assign.md.
for INVARIANT in 'row-before-draft' 'approve-before-allocate' 'sanitize' 'atomic-allocate' 'collision'; do
  TOTAL=$((TOTAL + 1))
  if grep -qF "$INVARIANT" "$ASSIGN_MD" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC} assign.md pins the '$INVARIANT' invariant (SPEC-026)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} assign.md lost the '$INVARIANT' invariant (contract drift)"
    FAIL=$((FAIL + 1))
  fi
done

# Slug hardening: the sanitized slug charset must stay pinned (path-traversal guard).
TOTAL=$((TOTAL + 1))
if grep -qF '[a-z0-9-]' "$ASSIGN_MD" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} assign.md pins the '[a-z0-9-]' slug charset (SPEC-026 DEC-004)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} assign.md lost the '[a-z0-9-]' slug charset (slug hardening drift)"
  FAIL=$((FAIL + 1))
fi

# ============================================================
echo ""
echo "=== Agent files ==="
# ============================================================

# Each agent has YAML frontmatter with name + description
for AGENT_FILE in "$KIT_DIR/agents/"*.md; do
  AGENT=$(basename "$AGENT_FILE" .md)
  HEAD3=$(head -1 "$AGENT_FILE")
  assert_eq "agent $AGENT starts with ---" "---" "$HEAD3"
  HAS_NAME=$(awk '/^---$/{c++; if(c==2)exit} c==1 && /^name:/' "$AGENT_FILE" | wc -l | tr -d ' ')
  assert_eq "agent $AGENT has name field" "1" "$HAS_NAME"
  HAS_DESC=$(awk '/^---$/{c++; if(c==2)exit} c==1 && /^description:/' "$AGENT_FILE" | wc -l | tr -d ' ')
  assert_eq "agent $AGENT has description field" "1" "$HAS_DESC"
  # model: must be present and one of the accepted Claude Code model aliases.
  # Same structural-parity intent as the plugin.json version check: grep-only
  # presence isn't enough, the value has to be in the real model surface.
  MODEL_VAL=$(awk -F': *' '/^---$/{c++; if(c==2)exit} c==1 && /^model:/{print $2; exit}' "$AGENT_FILE" | tr -d '[:space:]')
  TOTAL=$((TOTAL + 1))
  if { trap '' PIPE; echo "$MODEL_VAL" 2>/dev/null || :; } | grep -qE '^(sonnet|haiku|opus)$'; then
    echo -e "  ${GREEN}PASS${NC} agent $AGENT model is sonnet|haiku|opus ($MODEL_VAL)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} agent $AGENT model invalid or missing ('$MODEL_VAL')"
    FAIL=$((FAIL + 1))
  fi
done

# MANUAL.md agent table cross-refs match agents/ files.
# Canonical agent inventory is in MANUAL.md "Agents" section (table rows), whose bulk now
# lives at docs/MANUAL.md (root MANUAL.md is a thin stub, SPEC-185).
# CLAUDE.md no longer mirrors the inventory; see docs/architecture.md for component fit.
MANUAL_BULK="$KIT_DIR/docs/MANUAL.md"
SUBAGENT_NAMES=$(grep '^| `' "$MANUAL_BULK" | sed 's/^| `\([^`]*\)`.*/\1/' | sort -u)
for NAME in $SUBAGENT_NAMES; do
  if [ -f "$KIT_DIR/agents/$NAME.md" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC} MANUAL.md row '$NAME' has agents/$NAME.md"
    PASS=$((PASS + 1))
  fi
done

# Reverse: every agent file mentioned in MANUAL.md as a table row.
for AGENT_FILE in "$KIT_DIR/agents/"*.md; do
  AGENT=$(basename "$AGENT_FILE" .md)
  TOTAL=$((TOTAL + 1))
  if grep -q "^| \`$AGENT\` " "$MANUAL_BULK"; then
    echo -e "  ${GREEN}PASS${NC} agent $AGENT listed in MANUAL.md"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} agent $AGENT NOT listed in MANUAL.md"
    FAIL=$((FAIL + 1))
  fi
done

# ============================================================
echo ""
echo "=== Command files ==="
# ============================================================

for CMD_FILE in "$KIT_DIR/commands/"*.md; do
  CMD=$(basename "$CMD_FILE" .md)
  HEAD1=$(head -1 "$CMD_FILE")
  assert_eq "command $CMD starts with ---" "---" "$HEAD1"
  HAS_DESC=$(awk '/^---$/{c++; if(c==2)exit} c==1 && /^description:/' "$CMD_FILE" | wc -l | tr -d ' ')
  assert_eq "command $CMD has description field" "1" "$HAS_DESC"
done

# SPEC-011: the opt-in /kit:design command must exist (the frontmatter loop above
# covers its shape; this asserts presence so a deletion fails CI).
TOTAL=$((TOTAL + 1))
if [ -f "$KIT_DIR/commands/design.md" ]; then
  echo -e "  ${GREEN}PASS${NC} commands/design.md exists (/kit:design lane)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} commands/design.md missing"
  FAIL=$((FAIL + 1))
fi

# ============================================================
echo ""
echo "=== Spec / ADR number-collision guard (shared-branch numbering) ==="
# ============================================================
# Two sessions assigning SPEC-NNN / ADR-NNNN against the same tree both read the
# same max and pick max+1, colliding (surfaced only at merge). This turns that
# silent collision into a loud CI failure. Allocation rule + conflict resolution
# live in docs/specs/README.md ("Concurrent numbering").

DUP_SPECS=$(ls "$KIT_DIR/docs/specs/" | grep -oE '^SPEC-[0-9]+' | sort | uniq -d | tr '\n' ' ' | sed 's/ *$//')
assert_eq "no duplicate SPEC numbers (dups: ${DUP_SPECS:-none})" "" "$DUP_SPECS"

DUP_ADRS=$(ls "$KIT_DIR/docs/decisions/" | grep -oE '^[0-9]+' | sort | uniq -d | tr '\n' ' ' | sed 's/ *$//')
assert_eq "no duplicate ADR numbers (dups: ${DUP_ADRS:-none})" "" "$DUP_ADRS"

# ============================================================
echo ""
echo "=== Debug loop (SPEC-013) ==="
# ============================================================
# The /kit:debug command must exist and carry its load-bearing structure,
# and the guess-fix guard's ledger contract must stay in sync with the hook.

DEBUG_CMD="$KIT_DIR/commands/debug.md"
TOTAL=$((TOTAL + 1))
if [ -f "$DEBUG_CMD" ]; then
  echo -e "  ${GREEN}PASS${NC} commands/debug.md exists (/kit:debug, bug lane)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} commands/debug.md missing"
  FAIL=$((FAIL + 1))
fi

for HEADING in "## Phase 1: Root cause" "## Phase 2: Pattern" "## Phase 3: Hypothesis" "## Phase 4: Implementation"; do
  TOTAL=$((TOTAL + 1))
  if grep -qF "$HEADING" "$DEBUG_CMD" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC} debug.md has '$HEADING'"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} debug.md missing '$HEADING'"
    FAIL=$((FAIL + 1))
  fi
done

for MARKER in "NO FIX WITHOUT A RECORDED ROOT CAUSE" "git bisect" "3-fix architecture wall"; do
  TOTAL=$((TOTAL + 1))
  if grep -qF "$MARKER" "$DEBUG_CMD" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC} debug.md carries '$MARKER'"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} debug.md missing '$MARKER'"
    FAIL=$((FAIL + 1))
  fi
done

# DEC-010: the guard's ledger heading "## Root cause" must appear in BOTH the
# command (which writes the ledger) and the hook (which greps it). A rename on
# one side would silently disable the guard; pinning both literals breaks the
# build instead.
RAT_HOOK="$KIT_DIR/hooks/anti-rationalization.sh"
for FILE in "$DEBUG_CMD" "$RAT_HOOK"; do
  TOTAL=$((TOTAL + 1))
  if grep -qF '## Root cause' "$FILE" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC} '$(basename "$FILE")' pins the literal '## Root cause' (DEC-010)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} '$(basename "$FILE")' lost the '## Root cause' contract (guard would silently break)"
    FAIL=$((FAIL + 1))
  fi
done

# WORKFLOW.md must carry the bug lane that routes to /debug. Bulk lives at
# docs/WORKFLOW.md (root is a thin stub, SPEC-185).
TOTAL=$((TOTAL + 1))
if grep -qE '^\| bug ' "$KIT_DIR/docs/WORKFLOW.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} WORKFLOW.md has the bug lane"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} WORKFLOW.md missing the bug lane"
  FAIL=$((FAIL + 1))
fi

# SPEC-018 DEC-003/DEC-006: the `## Test plan` heading is the writer/reader
# contract; it must appear in BOTH test-plan.md (writer) and execute.md (reader).
# A rename on one side silently disables execute's consumption of the plan.
TP_CMD="$KIT_DIR/commands/test-plan.md"
EXEC_CMD="$KIT_DIR/commands/execute.md"
for FILE in "$TP_CMD" "$EXEC_CMD"; do
  TOTAL=$((TOTAL + 1))
  if grep -qF '## Test plan' "$FILE" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC} '$(basename "$FILE")' pins the literal '## Test plan' (SPEC-018)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} '$(basename "$FILE")' lost the '## Test plan' contract (execute would silently read no plan)"
    FAIL=$((FAIL + 1))
  fi
done

# SPEC-018 DEC-005: the test-plan matrix must carry the proof column.
TOTAL=$((TOTAL + 1))
if grep -qiF 'proof' "$TP_CMD" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} test-plan.md carries the 'proof' column (SPEC-018 DEC-005)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} test-plan.md dropped the 'proof' column"
  FAIL=$((FAIL + 1))
fi

# SPEC-018 DEC-001: test-plan writes into the spec, not a root TEST-PLAN.md.
TOTAL=$((TOTAL + 1))
if grep -qF 'TEST-PLAN.md' "$TP_CMD" 2>/dev/null; then
  echo -e "  ${RED}FAIL${NC} test-plan.md still references a root TEST-PLAN.md (should write into the spec)"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC} test-plan.md writes into the spec, no root TEST-PLAN.md (SPEC-018 DEC-001)"
  PASS=$((PASS + 1))
fi

# ============================================================
echo ""
echo "=== Concurrency-safe review placement (## Review in the spec) ==="
# ============================================================
# Review output is concurrency-safe: it lives in the active spec as a `## Review`
# section, never a fixed-name root file two worktrees/sessions could clobber. Pin
# the writer/reader/home contract (same drift-guard shape as `## Test plan`):
# spec.md documents the home, review + review-team write it, ship reads its verdict.
REVIEW_CMD="$KIT_DIR/commands/review.md"
RT_CMD="$KIT_DIR/commands/review-team.md"
SHIP_CMD="$KIT_DIR/commands/ship.md"
for FILE in "$KIT_DIR/commands/spec.md" "$REVIEW_CMD" "$RT_CMD" "$SHIP_CMD"; do
  TOTAL=$((TOTAL + 1))
  if grep -qF '## Review' "$FILE" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC} '$(basename "$FILE")' carries the '## Review' spec-section contract"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} '$(basename "$FILE")' lost the '## Review' contract (review placement drift)"
    FAIL=$((FAIL + 1))
  fi
done

# No command may write or read a fixed-name root review/todo file (the thing the
# move removes). A `REVIEW.md` / `REVIEW-*.md` / `TODOS.md` mention in review,
# review-team, ship, or start is a regression back to the shared-namespace design.
ROOT_REVIEW_HITS=$(grep -lE 'REVIEW\.md|REVIEW-[a-z]|TODOS\.md' \
  "$REVIEW_CMD" "$RT_CMD" "$SHIP_CMD" "$KIT_DIR/commands/start.md" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
assert_eq "no fixed-name REVIEW*/TODOS root file in review/ship/start (offenders: ${ROOT_REVIEW_HITS:-none})" "" "$ROOT_REVIEW_HITS"

# SPEC-023: devs-team + visual-team write their critiques spec-first. Pin the
# wording on both of devs-team's sides (read AND write) so a one-sided flip back
# to brief-first fails the suite. No command reads these critiques (human-facing),
# so a wording pin is the right guard, not a writer/reader drift-guard.
DT_CMD="$KIT_DIR/commands/devs-team.md"
VT_CMD="$KIT_DIR/commands/visual-team.md"
TOTAL=$((TOTAL + 1))
if grep -qF 'spec-first' "$DT_CMD" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} devs-team.md reads the design spec-first (SPEC-023)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} devs-team.md lost its spec-first read (reverted to brief-first?)"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
if grep -qF 'the active spec if present, else the pre-spec brief' "$DT_CMD" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} devs-team.md writes the critique spec-first (SPEC-023)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} devs-team.md lost its spec-first write target (reverted to brief-first?)"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
if grep -qF 'spec-first' "$VT_CMD" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} visual-team.md writes the critique spec-first (SPEC-023)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} visual-team.md lost its spec-first placement"
  FAIL=$((FAIL + 1))
fi

# SPEC-052: the test-plan-review-team lane. Pin the literal `## Test plan critique`
# heading + the `spec-first` write target (same drift-guard shape as devs-team's
# critique, SPEC-023). No command reads this critique (human-facing), so a wording
# pin is the right guard. Also pin the bounded-loop contract it must carry.
TPRT_CMD="$KIT_DIR/commands/test-plan-review-team.md"
TOTAL=$((TOTAL + 1))
if [ -f "$TPRT_CMD" ] && grep -qF '## Test plan critique' "$TPRT_CMD" && grep -qF 'spec-first' "$TPRT_CMD"; then
  echo -e "  ${GREEN}PASS${NC} test-plan-review-team.md exists + writes '## Test plan critique' spec-first (SPEC-052)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} test-plan-review-team.md missing or lost its '## Test plan critique' / spec-first contract"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
if grep -qF '[[QL-VERDICT' "$TPRT_CMD" 2>/dev/null && grep -qF 'test-design-standard.md' "$TPRT_CMD" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} test-plan-review-team.md carries the QL-VERDICT loop + encodes test-design-standard.md (SPEC-052)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} test-plan-review-team.md lost the QL-VERDICT loop or the standard reference"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
if grep -qF '[[QL-VERDICT' "$KIT_DIR/commands/gauntlet.md" 2>/dev/null && grep -qF 'round=N clean=' "$KIT_DIR/commands/gauntlet.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} gauntlet.md emits the QL-VERDICT round marker, preset-invariant (SPEC-235)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} gauntlet.md lost the QL-VERDICT round marker"
  FAIL=$((FAIL + 1))
fi

# SPEC-201: AI-in-the-loop cost-tier taxonomy in /kit:test-plan (Step 1c) + the
# test-plan-review-team's 6th lens (Tiering & floor). DECISION-BRIEF-behavioral-test-tiering.md
# SG-1/SG-2. Pin the 5 doctrine facts test-plan.md must carry (positive), the 6th-lens wiring
# in test-plan-review-team.md, and a negative control: the exact old "5 lenses" framing that
# would silently drop lens 6 must not linger anywhere the lens count is stated.
TP_TIER_CMD="$KIT_DIR/commands/test-plan.md"
TOTAL=$((TOTAL + 1))
if grep -qF 'Step 1c' "$TP_TIER_CMD" 2>/dev/null \
   && grep -qF '`mechanical`' "$TP_TIER_CMD" 2>/dev/null \
   && grep -qF '`smoke`' "$TP_TIER_CMD" 2>/dev/null \
   && grep -qF '`behavioral`' "$TP_TIER_CMD" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} test-plan.md Step 1c names all three cost tiers (SPEC-201)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} test-plan.md missing Step 1c or one of the three tier names"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
if grep -qF 'config asserts lie; a behavior claim keeps a real-model probe' "$TP_TIER_CMD" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} test-plan.md states the floor rule verbatim (SPEC-201)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} test-plan.md lost the verbatim floor rule"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
if grep -qF 'Never delete or downgrade a behavior/security claim below the `behavioral` tier to cut cost' "$TP_TIER_CMD" 2>/dev/null \
   && grep -qF 'Never let a `smoke`-tier run gate a ship' "$TP_TIER_CMD" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} test-plan.md states both hard don'ts verbatim (SPEC-201)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} test-plan.md lost one or both verbatim hard don'ts"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
if grep -qF 'smoke-eligible' "$TP_TIER_CMD" 2>/dev/null && grep -qF 'retry-eligible' "$TP_TIER_CMD" 2>/dev/null \
   && grep -qF 'allowlist' "$TP_TIER_CMD" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} test-plan.md states the smoke/retry doctrine (SPEC-201)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} test-plan.md lost the smoke/retry doctrine"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
if grep -qF 'Tier | Smoke-eligible | Retry-eligible' "$TP_TIER_CMD" 2>/dev/null \
   && grep -qF 'AI-in-the-loop doctrine' "$TP_TIER_CMD" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} test-plan.md Step 3 template carries the tier columns + doctrine block (SPEC-201)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} test-plan.md Step 3 template dropped the tier columns or doctrine block"
  FAIL=$((FAIL + 1))
fi
# AC1(a) (review finding): the detection-signal sentence itself, not just the tier names it
# leads into, must survive a regression.
TOTAL=$((TOTAL + 1))
if grep -qF '### Step 1c: AI-in-the-loop tiering' "$TP_TIER_CMD" 2>/dev/null \
   && grep -qF 'operative test' "$TP_TIER_CMD" 2>/dev/null \
   && grep -qF 'observing a live model' "$TP_TIER_CMD" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} test-plan.md Step 1c states the AI-in-the-loop detection signal + operative test (SPEC-201 AC1a)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} test-plan.md lost the AI-in-the-loop detection-signal wording"
  FAIL=$((FAIL + 1))
fi
# Review finding: a security/side-effect case must never be smoke-eligible (the brief's exit
# criterion says "never-retry, never-smoke", not just never-retry).
TOTAL=$((TOTAL + 1))
if grep -qF 'security or side-effect case is NEVER smoke-eligible' "$TP_TIER_CMD" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} test-plan.md states security/side-effect cases are never smoke-eligible (SPEC-201, brief exit criterion c)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} test-plan.md lost the never-smoke-eligible rule for security/side-effect cases"
  FAIL=$((FAIL + 1))
fi

TOTAL=$((TOTAL + 1))
if grep -qF 'Tiering & floor' "$TPRT_CMD" 2>/dev/null \
   && grep -qF 'not an AI-in-the-loop plan' "$TPRT_CMD" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} test-plan-review-team.md carries the Tiering & floor lens, N/A-safe (SPEC-201)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} test-plan-review-team.md missing the Tiering & floor lens"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
if grep -qF '6 lenses' "$TPRT_CMD" 2>/dev/null && grep -qF 'Dispatch 6 lenses' "$TPRT_CMD" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} test-plan-review-team.md lens count is 6 in the title and Step 2 heading (SPEC-201)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} test-plan-review-team.md lens count not updated to 6 everywhere"
  FAIL=$((FAIL + 1))
fi
# AC3 (review finding): the frontmatter `description:` line is a distinct location from the
# Step 2 heading checked above (a regression could flip one and miss the other). Scope the
# check to the description line itself so it is not vacuously satisfied by Step 2's own text.
TOTAL=$((TOTAL + 1))
TPRT_DESC_LINE=$(grep -m1 '^description:' "$TPRT_CMD" 2>/dev/null || true)
if { trap '' PIPE; printf '%s' "$TPRT_DESC_LINE" 2>/dev/null || :; } | grep -qF '6 test-design lenses'; then
  echo -e "  ${GREEN}PASS${NC} test-plan-review-team.md frontmatter description says '6 test-design lenses' (SPEC-201 AC3)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} test-plan-review-team.md frontmatter description lost '6 test-design lenses'"
  FAIL=$((FAIL + 1))
fi
# Negative control: the stale "5 subagents"/"5 angles"/"5 test-design lenses" framing
# (pre-SPEC-201) would silently cap the dispatch at 5 and drop lens 6. Must NOT appear anymore.
TOTAL=$((TOTAL + 1))
if grep -qE '5 (subagents|angles|test-design lenses)' "$TPRT_CMD" 2>/dev/null; then
  echo -e "  ${RED}FAIL${NC} [NC] test-plan-review-team.md still says '5 subagents'/'5 angles'/'5 test-design lenses' (lens 6 would be silently dropped)"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC} [NC] test-plan-review-team.md dropped the stale 5-lens framing (SPEC-201)"
  PASS=$((PASS + 1))
fi
TOTAL=$((TOTAL + 1))
if grep -qF 'Tiering & floor: [X]/10, or N/A' "$TPRT_CMD" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} test-plan-review-team.md scores template includes the 6th (N/A-able) score line (SPEC-201)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} test-plan-review-team.md scores template missing the 6th score line"
  FAIL=$((FAIL + 1))
fi
# The pre-registered negative control from the brief: a plan that puts a boundary claim in
# the config (mechanical) tier must be a pattern the lens explicitly names as CRITICAL.
TOTAL=$((TOTAL + 1))
if grep -qF 'config tier' "$TPRT_CMD" 2>/dev/null && grep -qE 'boundary.{0,40}mechanical|mechanical.{0,40}boundary' "$TPRT_CMD" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} [NC] test-plan-review-team.md lens 6 names the boundary-claim-in-config-tier negative control (SPEC-201, brief exit criterion)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} [NC] test-plan-review-team.md lens 6 does not name the boundary-in-config-tier negative control"
  FAIL=$((FAIL + 1))
fi
# Review finding: "each lens returns 2-5 findings" contradicted lens 6's N/A (0 findings,
# no score) path -- a subagent told a hard floor of 2 would hallucinate on a clean/N/A plan.
TOTAL=$((TOTAL + 1))
if grep -qF '0-5 findings' "$TPRT_CMD" 2>/dev/null && ! grep -qF '2-5 findings' "$TPRT_CMD" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} [NC] test-plan-review-team.md findings range allows 0, stale '2-5' gone (no forced-finding hallucination risk on N/A/clean, SPEC-201)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} [NC] test-plan-review-team.md still forces a 2-5 finding floor, contradicting lens 6's N/A path"
  FAIL=$((FAIL + 1))
fi
# Review finding: lens 4's ladder "smoke" stage and lens 6's `smoke` cost tier are different
# concepts sharing a word in the same dispatch prompt; the disambiguation must be present.
TOTAL=$((TOTAL + 1))
if grep -qF 'ladder-smoke stage' "$TPRT_CMD" 2>/dev/null || grep -qF 'ladder smoke stage' "$TPRT_CMD" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} test-plan-review-team.md disambiguates lens 6's smoke tier from lens 4's ladder smoke stage (SPEC-201)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} test-plan-review-team.md missing the smoke-tier vs ladder-smoke-stage disambiguation"
  FAIL=$((FAIL + 1))
fi

# SPEC-201 AC4: the §5b dialect table (SPEC-056/057) stays byte-identical -- same 12 types,
# same row count -- and gains a cross-reference paragraph AFTER the table, not inside it.
TDS_CMD="$KIT_DIR/docs/verification/test-design-standard.md"
TOTAL=$((TOTAL + 1))
DIALECT_ROWS_201=$(awk '/^## 5b/,/^## 6/' "$TDS_CMD" | grep -cE '^\| (incident|learning|planning|operate|eval|research|review|reconcile|doc|migration|data-tool|spec-feature) \|')
if [ "$DIALECT_ROWS_201" = "12" ]; then
  echo -e "  ${GREEN}PASS${NC} test-design-standard.md §5b dialect table still has all 12 rows, untouched (SPEC-201 AC4)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} test-design-standard.md §5b dialect table row count changed (got $DIALECT_ROWS_201, want 12)"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
if awk '/^## 5b/,/^## 6/' "$TDS_CMD" | grep -qF 'Step 1c'; then
  echo -e "  ${GREEN}PASS${NC} test-design-standard.md §5b cross-references Step 1c (SPEC-201 AC4)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} test-design-standard.md §5b missing the Step 1c cross-reference"
  FAIL=$((FAIL + 1))
fi

# SPEC-020: the ui-design loop. Assert the command exists, delegates generation
# to frontend-design (the kit ships no renderer), critiques via visual-team, and
# carries the `## UI design` brief heading. Downstream-facing; no behavior harness.
UID_CMD="$KIT_DIR/commands/ui-design.md"
TOTAL=$((TOTAL + 1))
if [ -f "$UID_CMD" ] && grep -qF 'frontend-design' "$UID_CMD" && grep -qF '## UI design' "$UID_CMD" && grep -qF 'visual-team' "$UID_CMD"; then
  echo -e "  ${GREEN}PASS${NC} ui-design.md exists + delegates generation + critiques via visual-team (SPEC-020)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} ui-design.md missing or not wired (needs frontend-design + visual-team + '## UI design')"
  FAIL=$((FAIL + 1))
fi

# ============================================================
echo ""
echo "=== Integration-verifier (SPEC-021) ==="
# ============================================================
# The cross-task wiring verifier must exist, stay read-only (no write tools in
# its frontmatter), and be dispatched by /execute. The generic agent-loop above
# already checks its name/description/model and the MANUAL cross-ref.

ICA="$KIT_DIR/agents/integration-verifier.md"
TOTAL=$((TOTAL + 1))
if [ -f "$ICA" ]; then
  echo -e "  ${GREEN}PASS${NC} agents/integration-verifier.md exists"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} agents/integration-verifier.md missing"
  FAIL=$((FAIL + 1))
fi

# Read-only contract: no bare Bash and no Edit/Write/MultiEdit in the tools list.
# Scoped Bash(...) entries do not match (they have a paren), so they are allowed.
WRITE_TOOLS=$(grep -cE '^[[:space:]]*-[[:space:]]+(Edit|Write|MultiEdit|Bash)[[:space:]]*$' "$ICA" 2>/dev/null || true)
assert_eq "integration-verifier has no write/bare-Bash tools (DEC-006)" "0" "$WRITE_TOOLS"

TOTAL=$((TOTAL + 1))
if grep -q 'integration-verifier' "$KIT_DIR/commands/execute.md" 2>/dev/null \
   && grep -q 'base ref' "$KIT_DIR/commands/execute.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} commands/execute.md dispatches the integration-verifier with a base ref"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} commands/execute.md does not wire the integration-verifier (+base ref)"
  FAIL=$((FAIL + 1))
fi

# ============================================================
echo ""
echo "=== Doc-verifier (SPEC-022) ==="
# ============================================================
# The doc-vs-code fact-checker must exist, stay read-only (no write tools), and
# be dispatched by /docs. The generic agent-loop above checks name/desc/model
# and the MANUAL cross-ref.

DVA="$KIT_DIR/agents/doc-verifier.md"
TOTAL=$((TOTAL + 1))
if [ -f "$DVA" ]; then
  echo -e "  ${GREEN}PASS${NC} agents/doc-verifier.md exists"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} agents/doc-verifier.md missing"
  FAIL=$((FAIL + 1))
fi

DV_WRITE=$(grep -cE '^[[:space:]]*-[[:space:]]+(Edit|Write|MultiEdit|Bash)[[:space:]]*$' "$DVA" 2>/dev/null || true)
assert_eq "doc-verifier has no write/bare-Bash tools (DEC-002)" "0" "$DV_WRITE"

TOTAL=$((TOTAL + 1))
if grep -q 'doc-verifier' "$KIT_DIR/commands/docs.md" 2>/dev/null \
   && grep -q 'Step 4.5' "$KIT_DIR/commands/docs.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} commands/docs.md dispatches the doc-verifier at Step 4.5"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} commands/docs.md does not wire the doc-verifier (+Step 4.5)"
  FAIL=$((FAIL + 1))
fi

# ============================================================
echo ""
echo "=== Spec-authoring depth contract (SPEC-008) ==="
# ============================================================
# The /spec Solution template must scaffold design depth (2-3 approaches +
# chosen + extensibility), and /spec-validate must carry the 5th reviewer.
# Assert on heading/marker presence only, not prose, to avoid brittle coupling.

SPEC_CMD="$KIT_DIR/commands/spec.md"
for HEADING in "### Approaches considered" "### Chosen approach" "### Extensibility & boundaries"; do
  TOTAL=$((TOTAL + 1))
  if grep -qF "$HEADING" "$SPEC_CMD" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC} spec.md Solution template has '$HEADING'"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} spec.md Solution template missing '$HEADING'"
    FAIL=$((FAIL + 1))
  fi
done

# SPEC-009: the I/O contract (under Technical Design) + the Failure modes section.
for HEADING in "### Interfaces (I/O contract)" "## Failure modes"; do
  TOTAL=$((TOTAL + 1))
  if grep -qF "$HEADING" "$SPEC_CMD" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC} spec.md template has '$HEADING'"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} spec.md template missing '$HEADING'"
    FAIL=$((FAIL + 1))
  fi
done

# SPEC-012 P1: the /spec template carries goal stop-criteria (so any spec is pointer-/goal-ready).
for HEADING in "## Verification" "## Open questions"; do
  TOTAL=$((TOTAL + 1))
  if grep -qF "$HEADING" "$SPEC_CMD" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC} spec.md template has '$HEADING'"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} spec.md template missing '$HEADING'"
    FAIL=$((FAIL + 1))
  fi
done

# SPEC-010 + concurrency sweep (ADR-0010): docs/specs/ is the SOLE spec location;
# the legacy .planning/ deprecation fallback is fully removed from every live surface
# (commands, hooks, agents). No exception remains -- ANY .planning ref in these dirs
# is a regression. (Dated ledgers under docs/specs|decisions|retro may still name it
# as history; this file names it to describe the guard, so tests/ is not scanned.)
STRAY_PLANNING=$(grep -rn '\.planning' "$KIT_DIR/commands/" "$KIT_DIR/hooks/" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "no .planning/ refs in commands/ or hooks/ (fallback removed)" "0" "$STRAY_PLANNING"

# SPEC-005: the state model is documented (the dual-mode detection itself is
# behavior-tested in test-hooks.sh). Backlog schema + architecture state-model
# section + the goal-registry ADR must exist; agents/ carry no stray .planning ref.
TOTAL=$((TOTAL + 1))
if grep -qF '## Schema' "$KIT_DIR/_meta/BACKLOG.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} BACKLOG.md has the Active-queue Schema section (SPEC-005)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} BACKLOG.md missing the Schema section"
  FAIL=$((FAIL + 1))
fi

TOTAL=$((TOTAL + 1))
if grep -qF '## State model' "$KIT_DIR/docs/architecture.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} architecture.md has the State model section (SPEC-005)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} architecture.md missing the State model section"
  FAIL=$((FAIL + 1))
fi

TOTAL=$((TOTAL + 1))
if [ -f "$KIT_DIR/docs/decisions/0011-goal-registry.md" ]; then
  echo -e "  ${GREEN}PASS${NC} ADR-0011 goal-registry exists (SPEC-005)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} ADR-0011 goal-registry missing"
  FAIL=$((FAIL + 1))
fi

# SPEC-005 TASK-2 + concurrency sweep: agents/ carry no .planning ref at all (the
# legacy fallback pointers in task-verifier/responding-to-review were removed).
STRAY_PLANNING_AGENTS=$(grep -rn '\.planning' "$KIT_DIR/agents/" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "no .planning/ refs in agents/ (fallback removed)" "0" "$STRAY_PLANNING_AGENTS"

# SPEC-006: the orchestration spine is documented + /kit:assign exists.
# Bulk lives at docs/WORKFLOW.md (root WORKFLOW.md is a thin stub, SPEC-185).
WF_SPINE="$KIT_DIR/docs/WORKFLOW.md"
for HEADING in "## The spine" "#### Doc-impact map"; do
  TOTAL=$((TOTAL + 1))
  if grep -qF "$HEADING" "$WF_SPINE" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC} WORKFLOW.md has '$HEADING' (SPEC-006)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} WORKFLOW.md missing '$HEADING'"
    FAIL=$((FAIL + 1))
  fi
done
TOTAL=$((TOTAL + 1))
if grep -qF 'Build decisions' "$WF_SPINE" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} WORKFLOW.md documents the Build-decisions convention (SPEC-006)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} WORKFLOW.md missing the Build-decisions convention"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
if [ -f "$KIT_DIR/commands/assign.md" ]; then
  echo -e "  ${GREEN}PASS${NC} commands/assign.md exists (/kit:assign, SPEC-006)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} commands/assign.md missing"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
if grep -qF 'Loop boundaries' "$KIT_DIR/docs/PHILOSOPHY.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} PHILOSOPHY has the bounded/unbounded loop note (SPEC-006)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} PHILOSOPHY missing the loop-boundaries note"
  FAIL=$((FAIL + 1))
fi

# SPEC-016: the three opt-in critique/test lanes exist.
for CMD in devs-team visual-team test-plan; do
  TOTAL=$((TOTAL + 1))
  if [ -f "$KIT_DIR/commands/$CMD.md" ]; then
    echo -e "  ${GREEN}PASS${NC} commands/$CMD.md exists (/kit:$CMD, SPEC-016)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} commands/$CMD.md missing"
    FAIL=$((FAIL + 1))
  fi
done

# SPEC-017: /kit:execute expands tasks into bite-sized steps.
TOTAL=$((TOTAL + 1))
if grep -qF 'bite-sized steps' "$KIT_DIR/commands/execute.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} execute.md has the bite-sized step-expansion marker (SPEC-017)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} execute.md missing the bite-sized step-expansion marker"
  FAIL=$((FAIL + 1))
fi

# SPEC-004: the absorption ritual + the /kit:absorb command exist with their contract.
ABS_DOC="$KIT_DIR/docs/ABSORPTION.md"
for HEADING in "## The external lane" "## Interest areas" "## Seed list" "## The adoption rubric" "## The gate"; do
  TOTAL=$((TOTAL + 1))
  if grep -qF "$HEADING" "$ABS_DOC" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC} ABSORPTION.md has '$HEADING' (SPEC-004)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} ABSORPTION.md missing '$HEADING'"
    FAIL=$((FAIL + 1))
  fi
done
for ABSFILE in "docs/ABSORPTION.md" "docs/absorption/TEMPLATE.md" "docs/absorption/README.md" "commands/absorb.md"; do
  TOTAL=$((TOTAL + 1))
  if [ -f "$KIT_DIR/$ABSFILE" ]; then
    echo -e "  ${GREEN}PASS${NC} $ABSFILE exists (SPEC-004)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} $ABSFILE missing"
    FAIL=$((FAIL + 1))
  fi
done
# the DATA-not-instructions guard must survive in /kit:absorb (it scores untrusted fetched content)
TOTAL=$((TOTAL + 1))
if grep -qF 'DATA, never instructions' "$KIT_DIR/commands/absorb.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} commands/absorb.md keeps the DATA-not-instructions guard (SPEC-004)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} commands/absorb.md lost the DATA-not-instructions guard"
  FAIL=$((FAIL + 1))
fi

# Review issue 5: verdict vocabulary pinned so devs-team/visual-team cannot drift apart.
for VERDICTFILE in "commands/devs-team.md" "commands/visual-team.md"; do
  TOTAL=$((TOTAL + 1))
  if grep -qF "SOLID / REVISE / RECONSIDER" "$KIT_DIR/$VERDICTFILE" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $VERDICTFILE carries the shared verdict vocabulary (SOLID / REVISE / RECONSIDER)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} $VERDICTFILE missing the shared verdict vocabulary (SOLID / REVISE / RECONSIDER)"
    FAIL=$((FAIL + 1))
  fi
done

VALIDATE_CMD="$KIT_DIR/commands/spec-validate.md"
TOTAL=$((TOTAL + 1))
if grep -qE "^### Reviewer 5:" "$VALIDATE_CMD" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} spec-validate.md has Reviewer 5 (design/extensibility)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} spec-validate.md missing Reviewer 5"
  FAIL=$((FAIL + 1))
fi

TOTAL=$((TOTAL + 1))
if grep -qF "## The 6 reviewers" "$VALIDATE_CMD" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} spec-validate.md header says 6 reviewers"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} spec-validate.md header not updated to 6 reviewers"
  FAIL=$((FAIL + 1))
fi

TOTAL=$((TOTAL + 1))
if grep -qE "^### Reviewer 6:" "$VALIDATE_CMD" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} spec-validate.md has Reviewer 6 (design record, ADR-0031 §1, blocking)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} spec-validate.md missing Reviewer 6"
  FAIL=$((FAIL + 1))
fi

# Count-drift guard: no live "4 reviewer(s)" / "5 reviewer(s)" reference may remain in the
# command (the heading, frontmatter, and output-format intro must all agree). Historical
# "N reviewers run <date>" lines live in docs/specs/, not here, so this file is safe
# to assert clean. Caught a real regression in the SPEC-008 review; SPEC-122 bumps 5 -> 6.
STALE_COUNT=$(grep -E "4 reviewer|5 reviewer" "$VALIDATE_CMD" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "spec-validate.md has no stale '4 reviewer' / '5 reviewer' references" "0" "$STALE_COUNT"

# ============================================================
echo ""
echo "=== Demo project (examples/hello-spec) ==="
# ============================================================

DEMO_DIR="$KIT_DIR/examples/hello-spec"

for f in README.md CLAUDE.md docs/specs/SPEC-001-version-flag.md; do
  TOTAL=$((TOTAL + 1))
  if [ -f "$DEMO_DIR/$f" ]; then
    echo -e "  ${GREEN}PASS${NC} examples/hello-spec/$f exists"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} examples/hello-spec/$f missing"
    FAIL=$((FAIL + 1))
  fi
done

# Demo SPEC.md must contain the standard sections
for SECTION in "## Problem" "## Solution" "## Technical Design" "## Task Breakdown" "## Acceptance Criteria" "## Edge Cases" "## Out of Scope" "## Decision Log"; do
  TOTAL=$((TOTAL + 1))
  if grep -q "^${SECTION}" "$DEMO_DIR/docs/specs/SPEC-001-version-flag.md" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC} demo SPEC has '$SECTION'"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} demo SPEC missing '$SECTION'"
    FAIL=$((FAIL + 1))
  fi
done

# Demo CLAUDE.md must have kit-template sections
for SECTION in "## Project" "## Tech Stack" "## Commands" "## Repository Structure" "## Code Quality Rules" "## Workflow" "## Spec Location"; do
  TOTAL=$((TOTAL + 1))
  if grep -q "^${SECTION}" "$DEMO_DIR/CLAUDE.md" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC} demo CLAUDE.md has '$SECTION'"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} demo CLAUDE.md missing '$SECTION'"
    FAIL=$((FAIL + 1))
  fi
done

# ============================================================
echo ""
echo "=== Workflow file ==="
# ============================================================

WF="$KIT_DIR/.github/workflows/test.yml"
TOTAL=$((TOTAL + 1))
if [ -f "$WF" ]; then
  echo -e "  ${GREEN}PASS${NC} .github/workflows/test.yml exists"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} workflow file missing"
  FAIL=$((FAIL + 1))
fi

# Heuristic YAML structure (no python/yq dep): top-level keys present
for KEY in "^name:" "^on:" "^jobs:"; do
  TOTAL=$((TOTAL + 1))
  if grep -q "$KEY" "$WF"; then
    echo -e "  ${GREEN}PASS${NC} workflow has top-level '$KEY'"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} workflow missing '$KEY'"
    FAIL=$((FAIL + 1))
  fi
done

# Permissions block (security best practice)
TOTAL=$((TOTAL + 1))
if grep -q "^permissions:" "$WF"; then
  echo -e "  ${GREEN}PASS${NC} workflow has explicit permissions block"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} workflow missing permissions block (security warning)"
  FAIL=$((FAIL + 1))
fi

# Test runner step references the actual test file
TOTAL=$((TOTAL + 1))
if grep -q "tests/test-hooks.sh" "$WF"; then
  echo -e "  ${GREEN}PASS${NC} workflow references tests/test-hooks.sh"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} workflow does not reference tests/test-hooks.sh"
  FAIL=$((FAIL + 1))
fi

# ============================================================
echo ""
echo "=== CONTRIBUTING.md cross-links ==="
# ============================================================

if [ -f "$KIT_DIR/CONTRIBUTING.md" ]; then
  # Extract relative .md links and check each path exists
  RELATIVE_LINKS=$(grep -oE '\[`?[^]]+`?\]\(([^)]+\.md)\)' "$KIT_DIR/CONTRIBUTING.md" | grep -oE '\(([^)]+\.md)\)' | tr -d '()')
  for LINK in $RELATIVE_LINKS; do
    # Skip absolute URLs
    case "$LINK" in http*) continue ;; esac
    TOTAL=$((TOTAL + 1))
    if [ -f "$KIT_DIR/$LINK" ]; then
      echo -e "  ${GREEN}PASS${NC} link '$LINK' resolves"
      PASS=$((PASS + 1))
    else
      echo -e "  ${RED}FAIL${NC} broken link in CONTRIBUTING.md: '$LINK'"
      FAIL=$((FAIL + 1))
    fi
  done
fi

# ============================================================
echo ""
echo "=== WORKFLOW.md contract ==="
# ============================================================

# Bulk lives at docs/WORKFLOW.md (root WORKFLOW.md is a thin stub, SPEC-185).
WF_ROOT="$KIT_DIR/docs/WORKFLOW.md"
WF_DEMO="$KIT_DIR/examples/hello-spec/WORKFLOW.md"

# Kit-root WORKFLOW.md carries the four pinned sections (matched on ASCII prefixes
# so the grep cannot drift on a parenthetical or a Unicode glyph in the header).
for SECTION in "^## Required reading" "^## Size the work first" "^## The cycle" "^## Completion contract"; do
  TOTAL=$((TOTAL + 1))
  if grep -q "$SECTION" "$WF_ROOT" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC} WORKFLOW.md has '$SECTION'"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} WORKFLOW.md missing '$SECTION'"
    FAIL=$((FAIL + 1))
  fi
done

# Both the downstream template and the kit root now use docs/specs/ (post-unify, SPEC-010).
# (ADR-0002). Asserting each in its own file catches a copy-paste path error.
TOTAL=$((TOTAL + 1))
if grep -qF 'docs/specs/' "$WF_DEMO" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} examples/hello-spec/WORKFLOW.md uses docs/specs/"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} examples/hello-spec/WORKFLOW.md missing docs/specs/"
  FAIL=$((FAIL + 1))
fi

TOTAL=$((TOTAL + 1))
if grep -qF 'docs/specs/' "$WF_ROOT" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} WORKFLOW.md uses docs/specs/ convention"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} WORKFLOW.md missing docs/specs/ convention"
  FAIL=$((FAIL + 1))
fi

# ============================================================
echo ""
echo "=== Mid-flight amend convention (SPEC-027) ==="
# ============================================================
# Pin the BUILDING -> SPECIFYING -> BUILDING amend convention across its four
# surfaces so a wording flip on any of them fails CI. WORKFLOW.md is the canonical
# home of the rule; the other three are projections/the model row that point at it.

# (a) execute.md reroutes the "don't modify the spec" anti-pattern to the declared
# amend path: it must reference BOTH "amend" and "checkpoint".
TOTAL=$((TOTAL + 1))
if grep -qF 'amend' "$KIT_DIR/commands/execute.md" 2>/dev/null \
   && grep -qF 'checkpoint' "$KIT_DIR/commands/execute.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} execute.md references the amend path (amend + checkpoint) (SPEC-027)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} execute.md lost the amend path (needs amend + checkpoint)"
  FAIL=$((FAIL + 1))
fi

# (b) WORKFLOW.md is the canonical home: it must carry the "Mid-flight amend" rule.
TOTAL=$((TOTAL + 1))
if grep -qF 'Mid-flight amend' "$KIT_DIR/docs/WORKFLOW.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} WORKFLOW.md documents the Mid-flight amend rule (SPEC-027, canonical)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} WORKFLOW.md lost the Mid-flight amend rule"
  FAIL=$((FAIL + 1))
fi

# (c) spec.md documents the optional on-demand "## Amendments" provenance section.
TOTAL=$((TOTAL + 1))
if grep -qF '## Amendments' "$KIT_DIR/commands/spec.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} spec.md documents the '## Amendments' section (SPEC-027)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} spec.md lost the '## Amendments' section"
  FAIL=$((FAIL + 1))
fi

# (d) architecture.md "## SDLC state machine" carries the BUILDING -> SPECIFYING amend
# transition row. Pin the whole row (From cell BUILDING, the amend trigger, To cell
# SPECIFYING) so the model stays legible; brittle-proofed via the full-row regex.
# (This guard moved here when the operating-layer-vision doc was folded into architecture.md.)
TOTAL=$((TOTAL + 1))
if grep -qE '\| BUILDING \|.*amend the spec.*\| SPECIFYING' "$KIT_DIR/docs/architecture.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} architecture.md has the BUILDING -> SPECIFYING amend row (SPEC-027)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} architecture.md lost the BUILDING -> SPECIFYING amend transition row"
  FAIL=$((FAIL + 1))
fi

# ============================================================
echo ""
echo "=== Release-hygiene guard (SPEC-028) ==="
# ============================================================
# Pin the PRESENCE of the phantom-cut warn on its two surfaces so a deletion or a
# wording flip fails CI. DEC-004: assert the surfaces carry the check, NEVER that
# the working tree is currently tag-clean ("VERSION named but untagged" is a
# legitimate transient during a release and CI often does not fetch tags). So we
# grep the command-prompt files; we never run the phantom-cut check against the repo.

# (a) ship.md (Step 4a) carries the phantom-cut / git-tag check AND the warn-not-block stance.
TOTAL=$((TOTAL + 1))
if grep -qF 'git tag -l' "$KIT_DIR/commands/ship.md" 2>/dev/null \
   && grep -qiF 'phantom' "$KIT_DIR/commands/ship.md" 2>/dev/null \
   && grep -qiF 'warn, not block' "$KIT_DIR/commands/ship.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} ship.md carries the release-hygiene warn (phantom-cut git-tag check + warn-not-block) (SPEC-028)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} ship.md lost the release-hygiene warn (needs git-tag phantom-cut check + warn-not-block stance)"
  FAIL=$((FAIL + 1))
fi

# (b) kit-health.md carries the phantom-cut check.
TOTAL=$((TOTAL + 1))
if grep -qF 'git tag -l' "$KIT_DIR/commands/kit-health.md" 2>/dev/null \
   && grep -qiF 'phantom' "$KIT_DIR/commands/kit-health.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} kit-health.md carries the phantom-cut check (git-tag check + phantom) (SPEC-028)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} kit-health.md lost the phantom-cut check (needs git-tag check + phantom)"
  FAIL=$((FAIL + 1))
fi

# ============================================================
echo ""
echo "=== V-model lens, convergence, and inventory parity (SPEC-031) ==="
# ============================================================

# (a) No "8 (workflow|lifecycle )?phases" string in operating surfaces.
# Scope: docs/, commands/, WORKFLOW.md, README.md, MANUAL.md, AGENTS.md --
# EXCLUDING docs/specs/, docs/decisions/, docs/research/, docs/retro/, docs/handoff/,
# docs/CHANGELOG.md (AMEND-001: archive dirs / the changelog are point-in-time and may
# reference old counts -- a retro or a changelog entry that documents the fix must be
# free to quote the forbidden string; only live surfaces are checked).
# git ls-files, never a filesystem walk (SPEC-029's dead-prefix scan already
# does this): a raw `grep -r` sweeps UNTRACKED gauntlet room copies under
# docs/verification/gauntlet/*/ , which each carry their own test-meta.sh and
# trip on the string this test names to describe itself (ID-640).
# docs/verification/ is also excluded below: a proof-of-done record is a
# point-in-time artifact that legitimately quotes the very string it fixed
# (like retro/handoff), so it is not a live operating surface.
PHASES_8_HITS=$(cd "$KIT_DIR" && git ls-files \
      'docs/*' 'commands/*' 'WORKFLOW.md' 'README.md' 'MANUAL.md' 'AGENTS.md' \
    | grep -vE '^(docs/specs/|docs/decisions/|docs/research/|docs/retro/|docs/handoff/|docs/verification/|docs/CHANGELOG\.md)' \
    | xargs grep -In -E "8 (workflow|lifecycle )?phases" 2>/dev/null | head -1)
TOTAL=$((TOTAL + 1))
if [ -z "$PHASES_8_HITS" ]; then
  echo -e "  ${GREEN}PASS${NC} no '8 (workflow|lifecycle )?phases' string in operating surfaces (SPEC-031, AMEND-001)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} stale '8 phases' string found in operating surfaces (SPEC-031, AMEND-001)"
  echo "    first hit: $PHASES_8_HITS" >&2
  FAIL=$((FAIL + 1))
fi

# (b) WORKFLOW.md carries both "## The V-model lens" and "## Lead-owned convergence"
# sections, and the lens section lists every phase name from the cycle table.
#
# Implementation notes (simplification logged):
# - Phase names are extracted from the cycle table (## The cycle ... ## The V-model lens).
# - The "UI design (opt-in, downstream)" cycle-table entry is abbreviated to
#   "UI design (opt-in)" in the lens's phase-names sentence. We strip the
#   ", downstream" qualifier before matching so the test is not brittle to this
#   intentional abbreviation. All other phase names are matched verbatim.
# - We assert BOTH section headings PLUS each phase name within the lens block,
#   not merely heading existence, so the test is not silently weakened.
TOTAL=$((TOTAL + 1))
if grep -q "^## The V-model lens" "$KIT_DIR/docs/WORKFLOW.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} WORKFLOW.md has '## The V-model lens' section (SPEC-031)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} WORKFLOW.md missing '## The V-model lens' section"
  FAIL=$((FAIL + 1))
fi

TOTAL=$((TOTAL + 1))
if grep -q "^## Lead-owned convergence" "$KIT_DIR/docs/WORKFLOW.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} WORKFLOW.md has '## Lead-owned convergence' section (SPEC-031)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} WORKFLOW.md missing '## Lead-owned convergence' section"
  FAIL=$((FAIL + 1))
fi

# Extract phase names from the cycle table (column 1, skipping header and separator).
# Then check each (after stripping ", downstream" qualifier) appears in the lens section.
LENS_SECTION=$(sed -n '/^## The V-model lens/,/^## /p' "$KIT_DIR/docs/WORKFLOW.md")
CYCLE_PHASES=$(sed -n '/^## The cycle/,/^## The V-model lens/p' "$KIT_DIR/docs/WORKFLOW.md" \
  | grep "^| " | grep -v "^| Phase\|^|---" \
  | sed 's/^| \([^|]*\)|.*/\1/' | sed 's/[[:space:]]*$//')
TOTAL=$((TOTAL + 1))
if [ "$(printf '%s\n' "$CYCLE_PHASES" | grep -c .)" -ge 13 ]; then
  echo -e "  ${GREEN}PASS${NC} CYCLE_PHASES extracted >= 13 entries (extraction not vacuous)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} CYCLE_PHASES extracted fewer than 13 entries (heading rename or parse break?)"
  FAIL=$((FAIL + 1))
fi
PHASE_FAIL=0
while IFS= read -r phase; do
  # Strip ", downstream" qualifier (lens abbreviates "UI design (opt-in, downstream)"
  # to "UI design (opt-in)"); all other names match verbatim.
  trimmed=$(echo "$phase" | sed 's/, downstream//')
  TOTAL=$((TOTAL + 1))
  if { trap '' PIPE; echo "$LENS_SECTION" 2>/dev/null || :; } | grep -qF "$trimmed"; then
    echo -e "  ${GREEN}PASS${NC} V-model lens references cycle phase '$phase'"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} V-model lens missing cycle phase '$phase' (searched as '$trimmed')"
    FAIL=$((FAIL + 1))
    PHASE_FAIL=$((PHASE_FAIL + 1))
  fi
done <<< "$CYCLE_PHASES"

# (c) Every entry in the hands-off list (## Lead-owned convergence -> ### Hands-off
# shared-surface list) also appears in the WORKFLOW.md #### Doc-impact map.
# This enforces the "subset invariant" stated in WORKFLOW.md itself.
# Implementation note: entries with wildcards (e.g. docs/retro/v*.md) are matched
# on their base path (docs/retro/) since the doc-impact map uses the base path.
# DOC_IMPACT_BLOCK intentionally spans the map + version-surfaces note (the range
# ends at the next ## heading, which includes both the map table and the note below
# it); matching against the full block is correct per DEC-005 (looser match is deliberate).
DOC_IMPACT_BLOCK=$(sed -n '/^#### Doc-impact map/,/^## Lead-owned convergence/p' "$KIT_DIR/docs/WORKFLOW.md")
HANDS_OFF_ENTRIES=$(sed -n '/^### Hands-off shared-surface list/,/^###/p' "$KIT_DIR/docs/WORKFLOW.md" \
  | grep "^-" \
  | sed "s/^- \`\([^\`]*\)\`.*/\1/" | sed "s/^- //")
TOTAL=$((TOTAL + 1))
if [ "$(printf '%s\n' "$HANDS_OFF_ENTRIES" | grep -c .)" -ge 8 ]; then
  echo -e "  ${GREEN}PASS${NC} HANDS_OFF_ENTRIES extracted >= 8 entries (extraction not vacuous)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} HANDS_OFF_ENTRIES extracted fewer than 8 entries (heading rename or parse break?)"
  FAIL=$((FAIL + 1))
fi
while IFS= read -r entry; do
  # Strip wildcard suffix for matching (docs/retro/v*.md -> docs/retro/)
  base=$(echo "$entry" | sed 's/\*\.md[^)]*$//' | sed 's/v\*$//')
  TOTAL=$((TOTAL + 1))
  if { trap '' PIPE; echo "$DOC_IMPACT_BLOCK" 2>/dev/null || :; } | grep -qF "$base"; then
    echo -e "  ${GREEN}PASS${NC} hands-off entry '$entry' appears in doc-impact map (SPEC-031)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} hands-off entry '$entry' NOT in doc-impact map (subset invariant broken)"
    FAIL=$((FAIL + 1))
  fi
done <<< "$HANDS_OFF_ENTRIES"

# (d) The command/agent V-phase inventory table in docs/architecture.md has a row
# count equal to the live file count (ls commands/*.md + ls agents/*.md).
# Implementation note: rows are counted from the inventory table only, delimited
# between "## Command and agent V-phase inventory" and "## State model" (the next
# ## heading after the table). Only pipe-prefixed data rows are counted (excluding
# the header row and separator row identified by "| Entry" and "|---").
ARCH_TABLE_ROWS=$(sed -n '/^## Command and agent V-phase inventory/,/^## /p' \
  "$KIT_DIR/docs/architecture.md" \
  | grep "^|" | grep -v "^| Entry\|^|---" | wc -l | tr -d ' ')
CMD_COUNT=$(ls "$KIT_DIR/commands/"*.md 2>/dev/null | wc -l | tr -d ' ')
AGT_COUNT=$(ls "$KIT_DIR/agents/"*.md 2>/dev/null | wc -l | tr -d ' ')
LIVE_COUNT=$((CMD_COUNT + AGT_COUNT))
assert_eq "architecture.md inventory table rows == live file count ($ARCH_TABLE_ROWS == $LIVE_COUNT)" \
  "$LIVE_COUNT" "$ARCH_TABLE_ROWS"

# No-counts policy (2026-08-10): the docs carry NO literal roster numbers (they churned on
# every addition and cost more to maintain than they informed; the operator retired them).
# Completeness is still pinned below by the ROW checks, live tree vs table rows, both sides
# computed, no hand-maintained number anywhere.
HOOK_COUNT=$(ls "$KIT_DIR/hooks/"*.sh 2>/dev/null | wc -l | tr -d ' ')

# SG-10 (harness-loop): the README inventory TABLES (not just the layout comment) stay
# pinned to live counts , the agents table sat at 11 rows against 25 files because only
# the layout number was pinned. Both the <summary> header number and the table row count
# are computed and compared; a new agent/command/skill without a README row fails here.
SKILL_COUNT=$(ls "$KIT_DIR/skills/"*/SKILL.md 2>/dev/null | wc -l | tr -d ' ')
# No-counts policy: header/layout numbers retired; a stray survivor fails here so one can
# never quietly come back and start drifting again.
assert_eq "README carries no literal roster counts (headers/layout)" "0" \
  "$(grep -cE '<b>(Agents|Commands|Skills|Hooks)</b> \([0-9]+|(agents|commands|hooks)/ *\([0-9]+' "$KIT_DIR/README.md" | tr -d ' ')"

# Table row counts (data rows only: exclude the header row and |--- separator).
AGT_DETAILS=$(sed -n '/<summary><b>Agents<\/b>/,/<\/details>/p' "$KIT_DIR/README.md")
README_AGT_ROWS=$(echo "$AGT_DETAILS" | sed -n '/^| Agent |/,/^$/p' | grep '^|' | grep -cv '^| Agent\|^|---' | tr -d ' ')
README_SKILL_ROWS=$(echo "$AGT_DETAILS" | sed -n '/^| Skill |/,/^$/p' | grep '^|' | grep -cv '^| Skill\|^|---' | tr -d ' ')
README_CMD_ROWS=$(sed -n '/<summary><b>Commands<\/b>/,/<\/details>/p' "$KIT_DIR/README.md" \
  | grep '^|' | grep -cv '^| Command\|^|---' | tr -d ' ')
README_HOOK_ROWS=$(sed -n '/<summary><b>Hooks<\/b>/,/<\/details>/p' "$KIT_DIR/README.md" \
  | grep '^|' | grep -cv '^| Hook\|^|---' | tr -d ' ')
assert_eq "README agents table rows == live agents ($README_AGT_ROWS == $AGT_COUNT)" "$AGT_COUNT" "$README_AGT_ROWS"
assert_eq "README skills table rows == live skills ($README_SKILL_ROWS == $SKILL_COUNT)" "$SKILL_COUNT" "$README_SKILL_ROWS"
assert_eq "README commands table rows == live commands ($README_CMD_ROWS == $CMD_COUNT)" "$CMD_COUNT" "$README_CMD_ROWS"
assert_eq "README hooks table rows == live hooks ($README_HOOK_ROWS == $HOOK_COUNT)" "$HOOK_COUNT" "$README_HOOK_ROWS"

# No-counts policy: the architecture.md headline tally is retired the same way.
assert_eq "architecture.md carries no headline roster tally" "0" \
  "$(grep -cE '^Total: [0-9]+ commands' "$KIT_DIR/docs/architecture.md" | tr -d ' ')"

# The README five-stage table covers every module the registry assigns a stage (ADR-0034
# decision 3 rendered without omissions; the two tables share one truth). "leg" renamed to
# "stage" by the 2026-07-18 amendment (ID-292).
FIVE_LEG_BLOCK=$(sed -n '/^## The five stages/,/^## /p' "$KIT_DIR/README.md")
REGISTRY_MODULES=$(sed -n '/^## Module stages/,/^## /p' "$KIT_DIR/lib/config/module-registry.md" \
  | grep '^| ' | grep -v '^| Module\|^|---' | awk -F'|' '{gsub(/ /,"",$2); print $2}')
TOTAL=$((TOTAL + 1))
MISSING_LEG_MODULES=""
while IFS= read -r m; do
  [ -n "$m" ] || continue
  { trap '' PIPE; echo "$FIVE_LEG_BLOCK" 2>/dev/null || :; } | grep -q "\`$m\`" || MISSING_LEG_MODULES="$MISSING_LEG_MODULES $m"
done <<< "$REGISTRY_MODULES"
if [ -z "$MISSING_LEG_MODULES" ]; then
  echo -e "  ${GREEN}PASS${NC} README five-stage table covers every module-registry stage row"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} README five-stage table missing module(s):$MISSING_LEG_MODULES"
  FAIL=$((FAIL + 1))
fi

# ============================================================
echo ""
echo "=== Parallel-execution boundary un-nerf (SPEC-032 C1 / ADR-0019) ==="
# ============================================================

# (a) The superseding ADR exists (the goal's "conflict settled by a recorded ADR").
TOTAL=$((TOTAL + 1))
if [ -f "$KIT_DIR/docs/decisions/0019-parallel-execution-boundary.md" ]; then
  echo -e "  ${GREEN}PASS${NC} ADR-0019 (parallel-execution-boundary) exists (SPEC-032 C1)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} ADR-0019 (parallel-execution-boundary) missing"
  FAIL=$((FAIL + 1))
fi

# (b) The un-nerf is cross-referenced from the live policy + map docs (not silently
# broken): PHILOSOPHY and architecture.md both cite ADR-0019.
for doc in "docs/PHILOSOPHY.md" "docs/architecture.md"; do
  TOTAL=$((TOTAL + 1))
  if grep -q "ADR-0019" "$KIT_DIR/$doc" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $doc cross-references ADR-0019 (un-nerf recorded)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} $doc must cross-reference ADR-0019"
    FAIL=$((FAIL + 1))
  fi
done

# (c) The old hard-forbid claim no longer survives as a live PHILOSOPHY statement.
# The bald "not competing with agent runtimes" ban was the C1 boundary; its reworded
# form is the cross-goal fan-out carve-out. Scoped to PHILOSOPHY.md (the live policy);
# specs/ADRs that QUOTE the old wording to document the supersession are exempt.
TOTAL=$((TOTAL + 1))
if grep -q "not competing with agent runtimes" "$KIT_DIR/docs/PHILOSOPHY.md" 2>/dev/null; then
  echo -e "  ${RED}FAIL${NC} stale C1 ban ('not competing with agent runtimes') still live in PHILOSOPHY.md"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC} stale C1 ban absent from PHILOSOPHY.md (boundary reworded, ADR-0019)"
  PASS=$((PASS + 1))
fi

# (d) kit-health carries the recorded fan-out carve-out so it does not flag dispatch.
TOTAL=$((TOTAL + 1))
if grep -qi "cross-goal fan-out" "$KIT_DIR/commands/kit-health.md" 2>/dev/null \
   && grep -q "ADR-0019" "$KIT_DIR/commands/kit-health.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} kit-health records the cross-goal fan-out carve-out (ADR-0019)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} kit-health must record the cross-goal fan-out carve-out (ADR-0019)"
  FAIL=$((FAIL + 1))
fi

# ============================================================
echo ""
echo "=== Dispatch moat: ## Touches + lib/gate/dispatch-gate.sh (SPEC-032) ==="
# ============================================================

# (a) The gate/guard helper exists and is executable (pure-bash moat).
TOTAL=$((TOTAL + 1))
if [ -f "$KIT_DIR/lib/gate/dispatch-gate.sh" ] && [ -x "$KIT_DIR/lib/gate/dispatch-gate.sh" ]; then
  echo -e "  ${GREEN}PASS${NC} lib/gate/dispatch-gate.sh exists and is executable (SPEC-032)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} lib/gate/dispatch-gate.sh missing or not executable"
  FAIL=$((FAIL + 1))
fi

# (b) The spec template documents the `## Touches` section + the prefix-glob constraint.
TOTAL=$((TOTAL + 1))
if grep -q '^## Touches' "$KIT_DIR/commands/spec.md" 2>/dev/null \
   && grep -qi 'directory-prefix' "$KIT_DIR/commands/spec.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} commands/spec.md documents ## Touches + the prefix-glob constraint (SPEC-032)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} commands/spec.md must document ## Touches + the directory-prefix-glob constraint"
  FAIL=$((FAIL + 1))
fi

# (c) The new lib/ dir is registered in the WORKFLOW doc-impact map (new-top-level-dir rule).
TOTAL=$((TOTAL + 1))
if grep -q '`lib/\*`' "$KIT_DIR/docs/WORKFLOW.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} lib/* row present in the WORKFLOW doc-impact map (SPEC-032)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} WORKFLOW doc-impact map missing the lib/* row"
  FAIL=$((FAIL + 1))
fi

# (d) The /kit:dispatch command exists with a description and is wired to the moat.
TOTAL=$((TOTAL + 1))
if [ -f "$KIT_DIR/commands/dispatch.md" ] && grep -q '^description:' "$KIT_DIR/commands/dispatch.md"; then
  echo -e "  ${GREEN}PASS${NC} commands/dispatch.md exists with a description (SPEC-032)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} commands/dispatch.md missing or has no description"
  FAIL=$((FAIL + 1))
fi

# (e) dispatch.md runs the gate + drift guard and converges without auto-merge.
TOTAL=$((TOTAL + 1))
if grep -q 'dispatch-gate.sh' "$KIT_DIR/commands/dispatch.md" 2>/dev/null \
   && grep -qi 'no auto-merge\|never auto-merge\|NEVER auto-merge\|not.*auto-merge' "$KIT_DIR/commands/dispatch.md" 2>/dev/null \
   && grep -q 'kit:ship' "$KIT_DIR/commands/dispatch.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} dispatch.md wires the gate + lead-owned convergence, no auto-merge (SPEC-032)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} dispatch.md must use lib/gate/dispatch-gate.sh, converge via /kit:ship, and refuse auto-merge"
  FAIL=$((FAIL + 1))
fi

# (f) dispatch.md is registered in the human-facing inventories (README + MANUAL).
TOTAL=$((TOTAL + 1))
if grep -q 'kit:dispatch' "$KIT_DIR/README.md" 2>/dev/null \
   && grep -q 'kit:dispatch' "$KIT_DIR/docs/MANUAL.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} /kit:dispatch registered in README + MANUAL command inventories (SPEC-032)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} /kit:dispatch must be in the README command table + MANUAL command list"
  FAIL=$((FAIL + 1))
fi

# (g) The lane classifier exists, is executable, and is wired into the intake/dispatch path.
TOTAL=$((TOTAL + 1))
if [ -f "$KIT_DIR/lib/classify/lane-classify.sh" ] && [ -x "$KIT_DIR/lib/classify/lane-classify.sh" ]; then
  echo -e "  ${GREEN}PASS${NC} lib/classify/lane-classify.sh exists and is executable (lane auto-classification)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} lib/classify/lane-classify.sh missing or not executable"
  FAIL=$((FAIL + 1))
fi

TOTAL=$((TOTAL + 1))
if grep -q 'lane-classify.sh' "$KIT_DIR/commands/assign.md" 2>/dev/null \
   && grep -q 'lane-classify.sh' "$KIT_DIR/commands/dispatch.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} lane-classify.sh wired into the intake (/kit:assign) + dispatch paths"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} lane-classify.sh must be wired into /kit:assign + /kit:dispatch"
  FAIL=$((FAIL + 1))
fi

# SPEC-053: the advisory lane floor-check must exist in the classifier AND be wired
# into /kit:assign Step 5. A drop on either side makes the under-size guard a phantom.
TOTAL=$((TOTAL + 1))
if grep -qE '^[[:space:]]*check\)' "$KIT_DIR/lib/classify/lane-classify.sh" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} lane-classify.sh exposes a 'check' subcommand (SPEC-053 floor guard)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} lane-classify.sh lost the 'check' subcommand (SPEC-053 floor guard)"
  FAIL=$((FAIL + 1))
fi

TOTAL=$((TOTAL + 1))
if grep -qF 'lane-classify.sh check' "$KIT_DIR/commands/assign.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} assign.md wires the lane floor-check into Step 5 (SPEC-053)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} assign.md lost the lane floor-check wiring (SPEC-053)"
  FAIL=$((FAIL + 1))
fi

# SPEC-054: every work type has a defined loop + executor. Three legs: the registry's agent
# column (all 6 rows), the WORKFLOW Type-loops table (all 6 types), the assign type-routing.
TOTAL=$((TOTAL + 1))
AGENT_OK=$(awk -F'|' '/^\|/ {f2=$2; gsub(/^[ \t]+|[ \t]+$/, "", f2);
  if (f2 == "task-type" || f2 ~ /^-+$/) next; n++
  v=$6; gsub(/^[ \t]+|[ \t]+$/, "", v)
  if (v ~ /preassigned|dynamic|per lane/) ok++ } END { print (n==12 && ok==12) ? "yes" : "no" }' "$KIT_DIR/docs/verification/task-types.md")
if [ "$AGENT_OK" = "yes" ]; then
  echo -e "  ${GREEN}PASS${NC} task-types registry: all 12 rows carry an agent entry (SPEC-054/057)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} task-types registry agent column incomplete (SPEC-054/057)"
  FAIL=$((FAIL + 1))
fi

TOTAL=$((TOTAL + 1))
LOOP_ROWS=$(awk '/^## Type loops/,/^## [^T]/' "$KIT_DIR/docs/WORKFLOW.md" | grep -cE '^\| (incident|learning|planning|operate|eval|research|review|reconcile|doc|migration|data-tool|spec-feature) \|')
if [ "$(grep -c '^## Type loops' "$KIT_DIR/docs/WORKFLOW.md")" -eq 1 ] && [ "$LOOP_ROWS" -eq 12 ]; then
  echo -e "  ${GREEN}PASS${NC} WORKFLOW.md Type-loops table covers all 11 types (SPEC-054/057)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} WORKFLOW.md Type-loops table missing or incomplete (SPEC-054, rows=$LOOP_ROWS)"
  FAIL=$((FAIL + 1))
fi

TOTAL=$((TOTAL + 1))
if grep -qF 'task-type-classify.sh classify' "$KIT_DIR/commands/assign.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} assign.md routes by task type before sizing (SPEC-054)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} assign.md lost the type-routing step (SPEC-054)"
  FAIL=$((FAIL + 1))
fi

# SPEC-055: the backlog kanban. The helper exists, assign documents pull mode, the
# vocabulary carries the claimed state. A drop on any leg makes pull a phantom.
TOTAL=$((TOTAL + 1))
if [ -x "$KIT_DIR/lib/board/backlog.sh" ] && grep -qF -- '--next' "$KIT_DIR/commands/assign.md" \
   && grep -qF '`claimed`' "$KIT_DIR/_meta/BACKLOG.md"; then
  echo -e "  ${GREEN}PASS${NC} backlog kanban wired: lib/board/backlog.sh + assign --next + claimed state (SPEC-055)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} backlog kanban incomplete: need lib/board/backlog.sh executable + assign --next + claimed vocab (SPEC-055)"
  FAIL=$((FAIL + 1))
fi

# SPEC-146: the cockpit board command. board.sh + parse-board.sh exist and are executable,
# board.sh actually delegates base render to backlog.sh (never reimplements it), and the
# doc-impact map (README + architecture.md) mentions both new lib files. A drop on any leg
# means the render-migration contract this depends on is silently unwired.
TOTAL=$((TOTAL + 1))
if [ -x "$KIT_DIR/lib/board/board.sh" ] && [ -x "$KIT_DIR/lib/board/parse-board.sh" ] \
   && grep -qF 'backlog.sh' "$KIT_DIR/lib/board/board.sh" \
   && grep -qF 'lib/board/board.sh' "$KIT_DIR/README.md" \
   && grep -qF 'lib/board/parse-board.sh' "$KIT_DIR/README.md" \
   && grep -qF 'board.sh' "$KIT_DIR/docs/architecture.md"; then
  echo -e "  ${GREEN}PASS${NC} cockpit board wired: lib/board/board.sh + lib/board/parse-board.sh executable, delegates to backlog.sh, doc-impact map updated (SPEC-146)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} cockpit board incomplete: need lib/board/board.sh + lib/board/parse-board.sh executable, backlog.sh delegation, README + architecture.md mentions (SPEC-146)"
  FAIL=$((FAIL + 1))
fi

# SPEC-147: the board-bridge mirror. board-mirror.sh exists and is executable, board.sh wires
# both mirror and status dispatch cases to it, and the doc-impact map (README + architecture.md)
# mentions the new lib file. A drop on any leg means the bridge is silently unwired.
TOTAL=$((TOTAL + 1))
if [ -x "$KIT_DIR/lib/board/board-mirror.sh" ] \
   && grep -qF 'mirror) shift; cmd_mirror "$@" ;;' "$KIT_DIR/lib/board/board.sh" \
   && grep -qF 'status) shift; cmd_status "$@" ;;' "$KIT_DIR/lib/board/board.sh" \
   && grep -qF 'lib/board/board-mirror.sh' "$KIT_DIR/README.md" \
   && grep -qF 'board-mirror.sh' "$KIT_DIR/docs/architecture.md"; then
  echo -e "  ${GREEN}PASS${NC} board-bridge mirror wired: lib/board/board-mirror.sh executable, board.sh dispatches mirror+status, doc-impact map updated (SPEC-147)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} board-bridge mirror incomplete: need lib/board/board-mirror.sh executable, board.sh mirror/status dispatch, README + architecture.md mentions (SPEC-147)"
  FAIL=$((FAIL + 1))
fi

# SPEC-149: the board-bridge writeback (the reverse leg). board-writeback.sh exists and is
# executable, board.sh wires the writeback dispatch case to it, and the doc-impact map
# (README + architecture.md) mentions the new lib file. A drop on any leg means the writeback
# leg is silently unwired.
TOTAL=$((TOTAL + 1))
if [ -x "$KIT_DIR/lib/board/board-writeback.sh" ] \
   && grep -qF 'writeback) shift; cmd_writeback "$@" ;;' "$KIT_DIR/lib/board/board.sh" \
   && grep -qF 'lib/board/board-writeback.sh' "$KIT_DIR/README.md" \
   && grep -qF 'board-writeback.sh' "$KIT_DIR/docs/architecture.md"; then
  echo -e "  ${GREEN}PASS${NC} board-bridge writeback wired: lib/board/board-writeback.sh executable, board.sh dispatches writeback, doc-impact map updated (SPEC-149)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} board-bridge writeback incomplete: need lib/board/board-writeback.sh executable, board.sh writeback dispatch, README + architecture.md mentions (SPEC-149)"
  FAIL=$((FAIL + 1))
fi

# SPEC-056: per-type test dialects. Three legs: the 6-row dialect table, the type-aware
# test-plan step, the default flip in the cycle table.
TOTAL=$((TOTAL + 1))
DIALECT_ROWS=$(awk '/^## 5b/,/^## 6/' "$KIT_DIR/docs/verification/test-design-standard.md" | grep -cE '^\| (incident|learning|planning|operate|eval|research|review|reconcile|doc|migration|data-tool|spec-feature) \|')
if [ "$DIALECT_ROWS" -eq 12 ] && grep -qF 'task-type-classify' "$KIT_DIR/commands/test-plan.md" \
   && grep -qF 'Test plan (default' "$KIT_DIR/docs/WORKFLOW.md"; then
  echo -e "  ${GREEN}PASS${NC} test dialects wired: 11-type table + type-aware test-plan + default flip (SPEC-056/057)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} test dialects incomplete (rows=$DIALECT_ROWS) (SPEC-056/057)"
  FAIL=$((FAIL + 1))
fi

# SPEC-057 parity: every registry type has BOTH a WORKFLOW loop row AND a dialect row.
# A half-added type (registry row without loop/dialect) is a phantom and goes RED here.
TOTAL=$((TOTAL + 1))
REG_N=$(awk -F'|' '/^\|/ {f2=$2; gsub(/^[ \t]+|[ \t]+$/, "", f2); if (f2 == "task-type" || f2 ~ /^-+$/) next; print f2}' "$KIT_DIR/docs/verification/task-types.md" | sort)
PARITY_OK=yes
while IFS= read -r ty; do
  grep -qE "^\| ${ty} \|" <(awk '/^## Type loops/,/^## [^T]/' "$KIT_DIR/docs/WORKFLOW.md") || PARITY_OK="no-loop:$ty"
  grep -qE "^\| ${ty} \|" <(awk '/^## 5b/,/^## 6/' "$KIT_DIR/docs/verification/test-design-standard.md") || PARITY_OK="no-dialect:$ty"
done <<< "$REG_N"
if [ "$PARITY_OK" = "yes" ] && [ "$(echo "$REG_N" | grep -c .)" -eq 12 ]; then
  echo -e "  ${GREEN}PASS${NC} type parity: every registry type has a loop row AND a dialect row (SPEC-057)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} type parity broken: $PARITY_OK (SPEC-057)"
  FAIL=$((FAIL + 1))
fi

# SPEC-057 operating-layer parity: AGENTS.md (the adopt-shipped contract) must carry the
# intake story: board pull, type-first classification, done-first phase 0. Losing any leg
# strands consumer repos on the old code-only contract.
TOTAL=$((TOTAL + 1))
if grep -qE 'backlog\.sh"? next' "$KIT_DIR/AGENTS.md" && grep -qE 'task-type-classify\.sh"? classify' "$KIT_DIR/AGENTS.md" \
   && grep -qF 'Done =' "$KIT_DIR/AGENTS.md" && grep -qF 'Where work comes from' "$KIT_DIR/docs/WORKFLOW.md"; then
  echo -e "  ${GREEN}PASS${NC} operating layer carries the intake story: board + type-first + done-first (SPEC-057)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} AGENTS.md/WORKFLOW.md lost the intake story (board/type/done-first) (SPEC-057)"
  FAIL=$((FAIL + 1))
fi

# SPEC-058: the grill. The command exists with all 11 type banks AND the three wiring legs
# (AGENTS task loop, assign, WORKFLOW phase-0) route classify -> grill -> Done=.
TOTAL=$((TOTAL + 1))
GRILL_BANKS=$(grep -cE '^### (incident|reconcile|operate|planning|learning|eval|research|doc|migration|data-tool|spec-feature)$' "$KIT_DIR/commands/grill.md" 2>/dev/null || echo 0)
if [ "$GRILL_BANKS" -eq 11 ] && grep -qF 'kit:grill' "$KIT_DIR/AGENTS.md" \
   && grep -qF 'kit:grill' "$KIT_DIR/commands/assign.md" && grep -qF 'grill' "$KIT_DIR/docs/WORKFLOW.md"; then
  echo -e "  ${GREEN}PASS${NC} grill intake wired: 11 type banks + AGENTS/assign/WORKFLOW legs (SPEC-058)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} grill intake incomplete (banks=$GRILL_BANKS) (SPEC-058)"
  FAIL=$((FAIL + 1))
fi

# SPEC-059: the absorb wave. (a) debug.md opens with the feedback-loop-first phase and its
# load-bearing catalog tactics; (b) review-team's architecture lens carries the deep-module
# vocabulary; (c) PHILOSOPHY carries the skill-routing rule that routes future absorbs.
TOTAL=$((TOTAL + 1))
if grep -qF '## Phase 0: Build a feedback loop' "$KIT_DIR/commands/debug.md" \
   && grep -qF 'Differential loop' "$KIT_DIR/commands/debug.md" \
   && grep -qF 'bisect run' "$KIT_DIR/commands/debug.md"; then
  echo -e "  ${GREEN}PASS${NC} debug.md has Phase 0 feedback-loop catalog (SPEC-059)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} debug.md missing Phase 0 feedback-loop catalog (SPEC-059)"
  FAIL=$((FAIL + 1))
fi

TOTAL=$((TOTAL + 1))
if grep -qF 'deletion test' "$KIT_DIR/commands/review-team.md" \
   && grep -qF 'locality' "$KIT_DIR/commands/review-team.md"; then
  echo -e "  ${GREEN}PASS${NC} review-team architecture lens carries deep-module vocabulary (SPEC-059)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} review-team architecture lens missing deep-module vocabulary (SPEC-059)"
  FAIL=$((FAIL + 1))
fi

TOTAL=$((TOTAL + 1))
if grep -qF 'Skill routing: what belongs in the kit' "$KIT_DIR/docs/PHILOSOPHY.md"; then
  echo -e "  ${GREEN}PASS${NC} PHILOSOPHY carries the skill-routing rule (SPEC-059)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} PHILOSOPHY missing skill-routing rule (SPEC-059)"
  FAIL=$((FAIL + 1))
fi

# SPEC-061: lane telemetry. (a) gate-ledger has the start verb; (b) the read-side
# aggregator exists with both subcommands; (c) retro carries the disposition contract;
# (d) WORKFLOW names the judging criteria.
TOTAL=$((TOTAL + 1))
if grep -qF 'start)    start "$@" ;;' "$KIT_DIR/lib/gate/gate-ledger.sh" \
   && grep -qF 'usage: $uprefix <rid> <chosen-lane> <classified-lane> <chosen-type> [classified-type] [repo]' "$KIT_DIR/lib/gate/gate-ledger.sh"; then
  echo -e "  ${GREEN}PASS${NC} gate-ledger has the START routing verb (SPEC-061)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} gate-ledger missing the START verb (SPEC-061)"
  FAIL=$((FAIL + 1))
fi

TOTAL=$((TOTAL + 1))
if [ -x "$KIT_DIR/lib/telemetry/lane-telemetry.sh" ] && grep -qF 'report)' "$KIT_DIR/lib/telemetry/lane-telemetry.sh" \
   && grep -qF 'misfires)' "$KIT_DIR/lib/telemetry/lane-telemetry.sh"; then
  echo -e "  ${GREEN}PASS${NC} lane-telemetry.sh exists with report+misfires (SPEC-061)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} lane-telemetry.sh missing or incomplete (SPEC-061)"
  FAIL=$((FAIL + 1))
fi

TOTAL=$((TOTAL + 1))
if grep -qF 'Lane telemetry sweep (SPEC-061)' "$KIT_DIR/commands/retro.md" \
   && grep -qF 'Disposition contract' "$KIT_DIR/commands/retro.md" \
   && grep -qF 'How lanes are judged' "$KIT_DIR/docs/WORKFLOW.md" \
   && grep -qF 'gate-ledger.sh start' "$KIT_DIR/commands/assign.md"; then
  echo -e "  ${GREEN}PASS${NC} telemetry wired: retro Step 1d + WORKFLOW criteria + assign START (SPEC-061)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} telemetry wiring incomplete (SPEC-061)"
  FAIL=$((FAIL + 1))
fi

# SPEC-062: telemetry closure. The operator scenarios live in WORKFLOW; debug carries the
# escaped-from marker; test-plan commands record their outcome.
TOTAL=$((TOTAL + 1))
if grep -qF 'What the operator sees, and when (SPEC-062)' "$KIT_DIR/docs/WORKFLOW.md" \
   && grep -qF 'escaped-from=' "$KIT_DIR/commands/debug.md" \
   && grep -qF 'gate-ledger.sh record <rid> test-plan ran' "$KIT_DIR/commands/test-plan.md" \
   && grep -qF 'gate-ledger.sh record <rid> test-plan ran' "$KIT_DIR/commands/test-plan-review-team.md" \
   && grep -qF 'classified-type' "$KIT_DIR/lib/gate/gate-ledger.sh"; then
  echo -e "  ${GREEN}PASS${NC} telemetry closure wired: scenarios + escaped-from + test-plan records + ctype (SPEC-062)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} telemetry closure wiring incomplete (SPEC-062)"
  FAIL=$((FAIL + 1))
fi

# SPEC-063: run legibility. plan/progress/trace exist; AGENTS carries the show-the-road
# rule + grill disposition recording; assign prints the plan; grill records itself.
TOTAL=$((TOTAL + 1))
if grep -qF 'plan)     plan "$@" ;;' "$KIT_DIR/lib/gate/gate-ledger.sh" \
   && grep -qF 'progress) progress "$@" ;;' "$KIT_DIR/lib/gate/gate-ledger.sh" \
   && grep -qF 'trace)    trace "$@" ;;' "$KIT_DIR/lib/telemetry/lane-telemetry.sh" \
   && grep -qF 'Show the road, then your position on it (SPEC-063)' "$KIT_DIR/AGENTS.md" \
   && grep -qF 'record <rid> grill' "$KIT_DIR/AGENTS.md" \
   && grep -qF 'gate-ledger.sh plan' "$KIT_DIR/commands/assign.md" \
   && grep -qF 'record <rid> grill ran' "$KIT_DIR/commands/grill.md"; then
  echo -e "  ${GREEN}PASS${NC} run legibility wired: plan/progress/trace + AGENTS/assign/grill (SPEC-063)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} run legibility wiring incomplete (SPEC-063)"
  FAIL=$((FAIL + 1))
fi

# SPEC-065: stack-merge exists with both verbs + dry-run; ship.md points at it.
TOTAL=$((TOTAL + 1))
if [ -x "$KIT_DIR/lib/goal/stack-merge.sh" ] && grep -qF 'next_link' "$KIT_DIR/lib/goal/stack-merge.sh" \
   && grep -qF 'dry-run' "$KIT_DIR/lib/goal/stack-merge.sh" \
   && grep -qF 'stack-merge.sh chain' "$KIT_DIR/commands/ship.md"; then
  echo -e "  ${GREEN}PASS${NC} stack-merge codified + wired into ship (SPEC-065)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} stack-merge missing or unwired (SPEC-065)"
  FAIL=$((FAIL + 1))
fi

# SPEC-066: the install copies (no ln -s on hook files) and stamps; kit-health probes staleness.
TOTAL=$((TOTAL + 1))
if grep -qF 'cp "$HOOK_FILE" "$LINK"' "$KIT_DIR/install.sh" \
   && ! grep -qF 'ln -s "$HOOK_FILE"' "$KIT_DIR/install.sh" \
   && grep -qF 'INSTALL-STAMP' "$KIT_DIR/install.sh" \
   && grep -qF 'INSTALL-STAMP' "$KIT_DIR/commands/kit-health.md"; then
  echo -e "  ${GREEN}PASS${NC} install-by-copy + stamp + staleness probe (SPEC-066)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} install-by-copy incomplete (SPEC-066)"
  FAIL=$((FAIL + 1))
fi

# SPEC-067: the golden run exists, is executable, and CI runs it.
TOTAL=$((TOTAL + 1))
if [ -x "$KIT_DIR/tests/test-e2e.sh" ] && grep -qF 'test-e2e.sh' "$KIT_DIR/.github/workflows/test.yml"; then
  echo -e "  ${GREEN}PASS${NC} golden-run e2e exists + CI runs it (SPEC-067)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} golden-run e2e missing or not in CI (SPEC-067)"
  FAIL=$((FAIL + 1))
fi

# SPEC-068: precedent lookup exists and intake reads it (assign + grill).
TOTAL=$((TOTAL + 1))
if [ -x "$KIT_DIR/bin/precedent" ] \
   && grep -qF 'precedent find' "$KIT_DIR/commands/assign.md" \
   && grep -qF 'precedent find' "$KIT_DIR/commands/grill.md"; then
  echo -e "  ${GREEN}PASS${NC} precedent lookup wired into intake (SPEC-068)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} precedent lookup missing or unwired (SPEC-068)"
  FAIL=$((FAIL + 1))
fi

# SPEC-069: retro follow-ups wired (escalation rule, advisory, grill line, color gate).
TOTAL=$((TOTAL + 1))
if grep -qF 'Review escalation (SPEC-069)' "$KIT_DIR/docs/WORKFLOW.md" \
   && grep -qF 'review-team' "$KIT_DIR/AGENTS.md" \
   && grep -qF 'codebase-memory' "$KIT_DIR/commands/grill.md" \
   && grep -qF 'appears nowhere in _meta/BACKLOG.md' "$KIT_DIR/hooks/ship-gate.sh" \
   && grep -qF 'NO_COLOR' "$KIT_DIR/lib/gate/gate-ledger.sh" \
   && grep -qF '_boardless' "$KIT_DIR/lib/telemetry/lane-telemetry.sh"; then
  echo -e "  ${GREEN}PASS${NC} retro follow-ups wired: escalation + advisory + grill + colors + detectors (SPEC-069)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} retro follow-ups incomplete (SPEC-069)"
  FAIL=$((FAIL + 1))
fi

# ============================================================
echo ""
echo "=== Multi-session: goal-registry + ADR-0022 (SPEC-036) ==="
# ============================================================

# (a) The cross-session registry helper exists and is executable (pure-bash substrate).
TOTAL=$((TOTAL + 1))
if [ -f "$KIT_DIR/lib/goal/goal-registry.sh" ] && [ -x "$KIT_DIR/lib/goal/goal-registry.sh" ]; then
  echo -e "  ${GREEN}PASS${NC} lib/goal/goal-registry.sh exists and is executable (SPEC-036)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} lib/goal/goal-registry.sh missing or not executable"
  FAIL=$((FAIL + 1))
fi

# (b) goal-registry reuses the dispatch-gate disjointness rule (no second moat).
TOTAL=$((TOTAL + 1))
if grep -q 'dispatch-gate.sh' "$KIT_DIR/lib/goal/goal-registry.sh" 2>/dev/null \
   && ! grep -q '^prefix_overlap()' "$KIT_DIR/lib/goal/goal-registry.sh" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} goal-registry.sh sources dispatch-gate.sh, does not re-implement the gate (SPEC-036 DEC-002)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} goal-registry.sh must source dispatch-gate.sh and not redefine prefix_overlap"
  FAIL=$((FAIL + 1))
fi

# (c) The multi-session boundary ADR exists.
TOTAL=$((TOTAL + 1))
if [ -f "$KIT_DIR/docs/decisions/0022-multi-session-boundary.md" ]; then
  echo -e "  ${GREEN}PASS${NC} ADR-0022 (multi-session boundary) exists (SPEC-036)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} docs/decisions/0022-multi-session-boundary.md missing"
  FAIL=$((FAIL + 1))
fi

# (d) PHILOSOPHY's multi-session boundary is reworded (the blanket "stays L5" claim is
#     gone) and references ADR-0022, so the bend is recorded, not silent.
TOTAL=$((TOTAL + 1))
if ! grep -q 'multi-session coordination across machines or live operators stays L5' "$KIT_DIR/docs/PHILOSOPHY.md" 2>/dev/null \
   && grep -q 'ADR-0022' "$KIT_DIR/docs/PHILOSOPHY.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} PHILOSOPHY multi-session boundary reworded + cites ADR-0022 (SPEC-036 C4)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} PHILOSOPHY must rework the blanket multi-session 'stays L5' claim and cite ADR-0022"
  FAIL=$((FAIL + 1))
fi

# (e) The claim is wired into /kit:assign and the monitor into /kit:start.
TOTAL=$((TOTAL + 1))
if grep -q 'goal-registry.sh' "$KIT_DIR/commands/assign.md" 2>/dev/null \
   && grep -q 'goal-registry.sh' "$KIT_DIR/commands/start.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} goal-registry wired: claim in /kit:assign, monitor in /kit:start (SPEC-036)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} goal-registry must be wired into /kit:assign (claim) + /kit:start (list)"
  FAIL=$((FAIL + 1))
fi

# (f) kit-health carries the recorded running-goal-registry carve-out (so it does not
#     flag the registry as runtime duplication).
TOTAL=$((TOTAL + 1))
if grep -qi 'running-goal registry' "$KIT_DIR/commands/kit-health.md" 2>/dev/null \
   && grep -q 'ADR-0022' "$KIT_DIR/commands/kit-health.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} kit-health carries the running-goal-registry carve-out (ADR-0022) (SPEC-036)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} kit-health must record the running-goal-registry carve-out citing ADR-0022"
  FAIL=$((FAIL + 1))
fi

# (g) ADR-0022 is cross-referenced from architecture.md (the concurrency boundary).
TOTAL=$((TOTAL + 1))
if grep -q 'ADR-0022' "$KIT_DIR/docs/architecture.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} architecture.md cross-references ADR-0022 (SPEC-036)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} docs/architecture.md must cross-reference ADR-0022"
  FAIL=$((FAIL + 1))
fi

# ============================================================
echo ""
echo "=== Goal-draft lifecycle: goal-drafts.sh + ADR-0023 (SPEC-037) ==="
# ============================================================

# (a) lib/goal/goal-drafts.sh exists and is executable.
TOTAL=$((TOTAL + 1))
if [ -f "$KIT_DIR/lib/goal/goal-drafts.sh" ] && [ -x "$KIT_DIR/lib/goal/goal-drafts.sh" ]; then
  echo -e "  ${GREEN}PASS${NC} lib/goal/goal-drafts.sh exists and is executable (SPEC-037)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} lib/goal/goal-drafts.sh missing or not executable"
  FAIL=$((FAIL + 1))
fi

# (b) The LIVE goal-draft contract carries no INDEX.md (the phantom is gone; only the
#     annotated historical record in ADR-0011/ADR-0023/SPEC-005 keeps the word).
LIVE_INDEX=$(grep -l 'INDEX\.md' "$KIT_DIR/commands/assign.md" "$KIT_DIR/commands/start.md" "$KIT_DIR/commands/next.md" "$KIT_DIR/docs/WORKFLOW.md" "$KIT_DIR/docs/architecture.md" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "no INDEX.md in the live goal-draft contract (SPEC-037 / ADR-0023)" "0" "$LIVE_INDEX"

# (c) ADR-0023 exists and ADR-0011 records the supersession (supersede, not rewrite).
TOTAL=$((TOTAL + 1))
if [ -f "$KIT_DIR/docs/decisions/0023-goal-draft-lifecycle.md" ] \
   && grep -q 'ADR-0023' "$KIT_DIR/docs/decisions/0011-goal-registry.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} ADR-0023 exists + ADR-0011 Status line names it (SPEC-037)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} ADR-0023 missing, or ADR-0011 does not record the supersession"
  FAIL=$((FAIL + 1))
fi

# (d) The State model section names BOTH stores side by side (draft + registry).
SM_SECTION=$(awk '/^## State model/{f=1; print; next} f && /^## /{exit} f{print}' "$KIT_DIR/docs/architecture.md" 2>/dev/null)
TOTAL=$((TOTAL + 1))
if { trap '' PIPE; printf '%s' "$SM_SECTION" 2>/dev/null || :; } | grep -q '\.claude/goals' && { trap '' PIPE; printf '%s' "$SM_SECTION" 2>/dev/null || :; } | grep -q 'kit-goals'; then
  echo -e "  ${GREEN}PASS${NC} architecture.md State model names both the draft store and kit-goals registry (SPEC-037)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} architecture.md State model must show both .claude/goals and kit-goals side by side"
  FAIL=$((FAIL + 1))
fi

# (e) The archive is wired into /kit:ship.
TOTAL=$((TOTAL + 1))
if grep -q 'goal-drafts.sh' "$KIT_DIR/commands/ship.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} goal-drafts.sh archive wired into /kit:ship (SPEC-037)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} /kit:ship must run lib/goal/goal-drafts.sh archive"
  FAIL=$((FAIL + 1))
fi

# ============================================================
echo ""
echo "=== /kit:verify command (SPEC-035) ==="
# ============================================================

# (a) commands/verify.md exists with a one-line description.
TOTAL=$((TOTAL + 1))
if [ -f "$KIT_DIR/commands/verify.md" ] && grep -q '^description:' "$KIT_DIR/commands/verify.md"; then
  echo -e "  ${GREEN}PASS${NC} commands/verify.md exists with a description (SPEC-035)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} commands/verify.md missing or has no description"
  FAIL=$((FAIL + 1))
fi

# (b) verify.md dispatches both read-only test agents (the right-arm levels).
TOTAL=$((TOTAL + 1))
if grep -q 'task-verifier' "$KIT_DIR/commands/verify.md" 2>/dev/null \
   && grep -q 'integration-verifier' "$KIT_DIR/commands/verify.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} verify.md dispatches task-verifier + integration-verifier (SPEC-035)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} verify.md must dispatch task-verifier + integration-verifier"
  FAIL=$((FAIL + 1))
fi

# (c) verify.md is read-only: it must DECLARE that it never dispatches fix-agent.
# Asserting the invariant is stated (not the mere absence of the string, which the
# file's own "to fix, run /execute" prose would defeat). A missing/empty file yields
# no match and fails, so this cannot pass vacuously.
TOTAL=$((TOTAL + 1))
if grep -qiE 'never dispatch[^.]*fix-agent' "$KIT_DIR/commands/verify.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} verify.md declares the read-only invariant (no fix-agent) (SPEC-035)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} verify.md must declare it does not dispatch fix-agent (read-only)"
  FAIL=$((FAIL + 1))
fi

# ============================================================
echo ""
echo "=== Gate ledger + ship enforcement (ADR-0024) ==="

assert_true "lib/gate/gate-ledger.sh exists and is executable" "$([ -x "$KIT_DIR/lib/gate/gate-ledger.sh" ] && echo 0 || echo 1)"
assert_true "hooks/ship-gate.sh exists and is executable" "$([ -x "$KIT_DIR/hooks/ship-gate.sh" ] && echo 0 || echo 1)"
assert_true "ADR-0024 (gate ledger + ship enforcement) exists" "$([ -f "$KIT_DIR/docs/decisions/0024-gate-ledger-and-ship-enforcement.md" ] && echo 0 || echo 1)"
assert_true "ship-gate registered in hooks.json (plugin path)" "$(grep -q 'hooks/ship-gate.sh' "$KIT_DIR/hooks/hooks.json" && echo 0 || echo 1)"
assert_true "ship-gate registered in settings.json (bash-install path)" "$(grep -q 'hooks/ship-gate.sh' "$KIT_DIR/settings.json" && echo 0 || echo 1)"
assert_true "PHILOSOPHY records the ADR-0024 ship-boundary bend" "$(grep -q 'ADR-0024' "$KIT_DIR/docs/PHILOSOPHY.md" && echo 0 || echo 1)"
assert_true "kit-health records the ship-gate carve-out" "$(grep -q 'ship-gate' "$KIT_DIR/commands/kit-health.md" && echo 0 || echo 1)"

# The lane×phase matrix is the single source for the lane->gate map; every value
# cell must be one of the three tokens so gate-ledger.sh can parse it (ADR-0024).
GL_BADCELLS=$(awk '
  /^## Lane.*depth matrix/ {inmx=1; next}
  inmx && /^## / {exit}
  inmx && /^\| *Phase *\|/ {hdr=1; next}
  inmx && hdr && /^\|/ {
    if ($0 ~ /^\| *-+/) next;
    n=split($0, c, "|");
    for (i=3;i<n;i++){ v=c[i]; gsub(/^ +| +$/,"",v);
      if (v!="" && v!="measure-twice" && v!="run-lite" && v!="skip") bad++ }
  }
  END{print bad+0}
' "$KIT_DIR/docs/WORKFLOW.md")
assert_eq "lane×phase matrix cells are all measure-twice|run-lite|skip" "0" "$GL_BADCELLS"

GL_REQ="$(bash "$KIT_DIR/lib/gate/gate-ledger.sh" required normal 2>/dev/null | tr '\n' ' ')"
assert_true "gate-ledger required(normal) derives spec+build+ship from the matrix" "$({ trap '' PIPE; echo "$GL_REQ" 2>/dev/null || :; } | grep -q 'spec' && { trap '' PIPE; echo "$GL_REQ" 2>/dev/null || :; } | grep -q 'build' && { trap '' PIPE; echo "$GL_REQ" 2>/dev/null || :; } | grep -q 'ship' && echo 0 || echo 1)"
assert_true "WORKFLOW documents the gate-ledger + ship-enforcement convention" "$(grep -q 'Gate ledger and ship enforcement' "$KIT_DIR/docs/WORKFLOW.md" && echo 0 || echo 1)"
assert_true "ship.md records the Ship gate + names the override path" "$(grep -q 'gate-ledger.sh' "$KIT_DIR/commands/ship.md" && echo 0 || echo 1)"
assert_true "AGENTS operate-contract points at the gate-ledger convention" "$(grep -q 'gate-ledger' "$KIT_DIR/AGENTS.md" && echo 0 || echo 1)"

# SPEC-051 (A4-lite): /kit:retro carries the advisory decision-capture nudge, and it is framed
# advisory (the assertion pins both, so a future edit cannot quietly turn it into a hard gate).
assert_true "retro.md has the decision-capture nudge pointing at docs/decisions/" \
  "$(awk '/Decision-capture nudge/{f=1} f && /^### Step 2/{exit} f && /docs\/decisions\//{found=1} END{exit !found}' "$KIT_DIR/commands/retro.md" && echo 0 || echo 1)"
assert_true "retro decision-capture nudge is framed advisory, never a block" \
  "$(awk '/Decision-capture nudge/{f=1} f && /advisory, never a block/{found=1} END{exit !found}' "$KIT_DIR/commands/retro.md" && echo 0 || echo 1)"

# ============================================================
echo ""
echo "=== Implementation-notes log (SPEC-041 / ID-041) ==="
# ============================================================
# The worker template + the orchestrator summary + the /kit:next hand-off must
# carry the implementation-notes rule so any spec-driven build leaves an anchor
# for the PR reviewer and the /wrap-session LAB_LOG entry. Four pins so the
# rule cannot regress silently across the three insertion points.

assert_true "execute.md worker template carries the implementation-notes rule" \
  "$(grep -q 'implementation-notes' "$KIT_DIR/commands/execute.md" && echo 0 || echo 1)"

assert_true "execute.md 'When done' reporting names the implementation-notes path" \
  "$(awk '/^## When done/{f=1;next} f && /^## /{exit} f && /implementation-notes/{found=1} END{exit !found}' "$KIT_DIR/commands/execute.md" >/dev/null && echo 0 || echo 1)"

assert_true "execute.md Step 4 completion summary surfaces the implementation-notes file" \
  "$(awk '/^### Step 4: Completion/{f=1;next} f && /^### /{exit} f && /implementation-notes/{found=1} END{exit !found}' "$KIT_DIR/commands/execute.md" >/dev/null && echo 0 || echo 1)"

assert_true "next.md Step 4 hand-off carries the implementation-notes reminder" \
  "$(awk '/^### Step 4: Hand off/{f=1;next} f && /^### /{exit} f && /implementation-notes/{found=1} END{exit !found}' "$KIT_DIR/commands/next.md" >/dev/null && echo 0 || echo 1)"

# ============================================================
echo ""
echo "=== Verification log (execution-backed verify) ==="
# ============================================================
# "Verify before proceeding" is only real if the verification was actually run
# and the run is recorded as a re-runnable artifact: command + exit + output
# excerpt + verdict. Prose "Tests: passing" is not proof. Eight pins so the
# convention cannot regress: a convention doc (+ its required fields), the
# no-check marker, the agent's captured record, the two write-sites (execute +
# verify), the completion-summary surface, and the PHILOSOPHY bend.

assert_true "docs/verification/ convention doc exists" \
  "$([ -f "$KIT_DIR/docs/verification/README.md" ] && echo 0 || echo 1)"

assert_true "verification convention records command + exit + output excerpt + verdict" \
  "$(grep -q 'Command:' "$KIT_DIR/docs/verification/README.md" && grep -q 'Exit:' "$KIT_DIR/docs/verification/README.md" && grep -q 'Output (excerpt)' "$KIT_DIR/docs/verification/README.md" && echo 0 || echo 1)"

assert_true "task-verifier emits the explicit no-check marker (no fake pass)" \
  "$(grep -q '\[NO EXECUTABLE CHECK:' "$KIT_DIR/agents/task-verifier.md" && echo 0 || echo 1)"

assert_true "task-verifier verdict captures the executed command + exit code" \
  "$(grep -q 'Verification record' "$KIT_DIR/agents/task-verifier.md" && grep -q 'Command:' "$KIT_DIR/agents/task-verifier.md" && echo 0 || echo 1)"

assert_true "execute.md writes the verification log (docs/verification/)" \
  "$(grep -q 'docs/verification/' "$KIT_DIR/commands/execute.md" && echo 0 || echo 1)"

assert_true "execute.md Step 4 completion summary surfaces the verification-log path" \
  "$(awk '/^### Step 4: Completion/{f=1;next} f && /^### /{exit} f && /docs\/verification\//{found=1} END{exit !found}' "$KIT_DIR/commands/execute.md" >/dev/null && echo 0 || echo 1)"

assert_true "verify.md records the read-only run to the verification log" \
  "$(grep -q 'docs/verification/' "$KIT_DIR/commands/verify.md" && echo 0 || echo 1)"

assert_true "review.md reads test state from the verification log (static-judgment boundary)" \
  "$(grep -q 'docs/verification/' "$KIT_DIR/commands/review.md" && echo 0 || echo 1)"

assert_true "PHILOSOPHY records the execution-backed-verify bend" \
  "$(grep -q 'docs/verification/' "$KIT_DIR/docs/PHILOSOPHY.md" && echo 0 || echo 1)"

# ---- proof of done: the negative control (a green check is only proof if it can fail) ----

assert_true "convention defines proof of done (green + negative control + reproducible)" \
  "$(grep -qi 'Proof of done' "$KIT_DIR/docs/verification/README.md" && grep -qi 'negative control' "$KIT_DIR/docs/verification/README.md" && echo 0 || echo 1)"

assert_true "task-verifier can run a bash/make project suite (not only npm/go/pytest/cargo)" \
  "$(grep -qE 'Bash\(bash tests/\*\)|Bash\(make test\*\)' "$KIT_DIR/agents/task-verifier.md" && echo 0 || echo 1)"

assert_true "task-verifier flags a weak/absent negative control on load-bearing tasks" \
  "$(grep -qi 'Negative control' "$KIT_DIR/agents/task-verifier.md" && echo 0 || echo 1)"

assert_true "execute.md produces a negative control for load-bearing builds" \
  "$(grep -qi 'NEGATIVE CONTROL' "$KIT_DIR/commands/execute.md" && echo 0 || echo 1)"

assert_true "verify.md produces a negative control for load-bearing specs" \
  "$(grep -qi 'NEGATIVE CONTROL' "$KIT_DIR/commands/verify.md" && echo 0 || echo 1)"

# ---- risk-gated proof of done: the class gate (stateful | behavioral | inert) ----

assert_true "lib/gate/proof-gate.sh exists and is executable" \
  "$([ -x "$KIT_DIR/lib/gate/proof-gate.sh" ] && echo 0 || echo 1)"

assert_true "proof-gate names the three proof classes (stateful, behavioral, inert)" \
  "$(out=$(bash "$KIT_DIR/lib/gate/proof-gate.sh" classes 2>/dev/null); { trap '' PIPE; echo "$out" 2>/dev/null || :; } | grep -q stateful && { trap '' PIPE; echo "$out" 2>/dev/null || :; } | grep -q behavioral && { trap '' PIPE; echo "$out" 2>/dev/null || :; } | grep -q inert && echo 0 || echo 1)"

assert_true "convention defines the risk-class gate (stateful/behavioral/inert + proof-gate)" \
  "$(grep -qi 'proof class' "$KIT_DIR/docs/verification/README.md" && grep -q 'proof-gate.sh' "$KIT_DIR/docs/verification/README.md" && echo 0 || echo 1)"

assert_true "convention names the inert exempt marker + the run-the-real-flow rule" \
  "$(grep -q 'PROOF OF DONE: exempt' "$KIT_DIR/docs/verification/README.md" && grep -qi 'real primary flow' "$KIT_DIR/docs/verification/README.md" && echo 0 || echo 1)"

assert_true "execute.md gates the proof by class (proof-gate)" \
  "$(grep -q 'proof-gate.sh' "$KIT_DIR/commands/execute.md" && echo 0 || echo 1)"

assert_true "verify.md gates the proof by class (proof-gate)" \
  "$(grep -q 'proof-gate.sh' "$KIT_DIR/commands/verify.md" && echo 0 || echo 1)"

assert_true "task-verifier reads proof class (inert exempt ok; stateful needs rollback)" \
  "$(grep -q 'proof-gate.sh' "$KIT_DIR/agents/task-verifier.md" && grep -q 'PROOF OF DONE: exempt' "$KIT_DIR/agents/task-verifier.md" && echo 0 || echo 1)"

# ---- proof-of-done ENFORCEMENT: the ship/merge gate (advice -> wall) ----

assert_true "lib/gate/proof-ledger.sh exists and is executable" \
  "$([ -x "$KIT_DIR/lib/gate/proof-ledger.sh" ] && echo 0 || echo 1)"

assert_true "ship-gate wires the diff-keyed proof-of-done gate" \
  "$(grep -q 'proof-ledger.sh' "$KIT_DIR/hooks/ship-gate.sh" && echo 0 || echo 1)"

assert_true "proof gate is opt-in (engages only where docs/verification/README.md exists)" \
  "$(grep -q 'docs/verification/README.md' "$KIT_DIR/hooks/ship-gate.sh" && echo 0 || echo 1)"

assert_true "proof-ledger provides a logged override (no silent bypass)" \
  "$(grep -q 'override' "$KIT_DIR/lib/gate/proof-ledger.sh" && grep -qi 'OVERRIDE' "$KIT_DIR/lib/gate/proof-ledger.sh" && echo 0 || echo 1)"

assert_true "ADR records the proof-of-done ship gate" \
  "$([ -f "$KIT_DIR/docs/decisions/0025-proof-of-done-ship-gate.md" ] && echo 0 || echo 1)"

assert_true "convention documents the enforcement gate + override" \
  "$(grep -qi 'ship/merge gate\|enforcement' "$KIT_DIR/docs/verification/README.md" && grep -q 'proof-ledger' "$KIT_DIR/docs/verification/README.md" && echo 0 || echo 1)"

assert_true "PHILOSOPHY records the deferred enforcement hook is now built" \
  "$(grep -q 'proof-ledger' "$KIT_DIR/docs/PHILOSOPHY.md" && echo 0 || echo 1)"

# ---- single-source numbers: borrowed from the experiment sibling (no hand-typed drift) ----

assert_true "lib/gate/verify-counts.sh exists and is executable" \
  "$([ -x "$KIT_DIR/lib/gate/verify-counts.sh" ] && echo 0 || echo 1)"

# ID-291: the gate dispatcher routes BOTH `verify-counts` and its legacy `verif-counts`
# alias to verify-counts.sh. The real target regenerates COUNTS.md by running every
# suite, so stub it and prove routing cheaply -- a future edit that drops the alias arm
# (or misroutes the verb) is then caught in CI, not by eyeballing the case statement.
_gate_route_tmp="$(mktemp -d "${TMPDIR:-/tmp}/dk-gate-route.XXXXXX")"
cp "$KIT_DIR/lib/gate/gate.sh" "$_gate_route_tmp/gate.sh"
printf '#!/usr/bin/env bash\necho "ROUTED $*"\n' > "$_gate_route_tmp/verify-counts.sh"
chmod +x "$_gate_route_tmp/verify-counts.sh"
assert_true "gate dispatch routes 'verify-counts' to verify-counts.sh" \
  "$(bash "$_gate_route_tmp/gate.sh" verify-counts probe 2>/dev/null | grep -q '^ROUTED probe' && echo 0 || echo 1)"
assert_true "gate dispatch routes legacy 'verif-counts' alias to verify-counts.sh" \
  "$(bash "$_gate_route_tmp/gate.sh" verif-counts probe 2>/dev/null | grep -q '^ROUTED probe' && echo 0 || echo 1)"
rm -rf "$_gate_route_tmp"

assert_true "COUNTS.md carries the generated single-source block" \
  "$(grep -q 'BEGIN GEN:counts' "$KIT_DIR/docs/verification/COUNTS.md" 2>/dev/null && echo 0 || echo 1)"

assert_true "convention names the experiment sibling + single-source borrow" \
  "$(grep -qi 'sibling' "$KIT_DIR/docs/verification/README.md" && grep -qi 'single-source\|codebase-tool-benchmark\|falsifiab' "$KIT_DIR/docs/verification/README.md" && echo 0 || echo 1)"
echo "=== codebase-memory auto-index hook (SPEC-043) ==="
# ============================================================
# The opt-in SessionStart hook must exist, be executable, be registered in both hook
# registries, and guard on git rev-parse (NOT '[ -d .git ]', which silently skips
# worktrees because .git is a file there).

assert_true "hooks/codebase-index.sh exists and is executable" \
  "$([ -x "$KIT_DIR/hooks/codebase-index.sh" ] && echo 0 || echo 1)"

assert_true "auto-index hook guards on git rev-parse (worktree-correct, not [ -d .git ])" \
  "$(grep -q 'git rev-parse --is-inside-work-tree' "$KIT_DIR/hooks/codebase-index.sh" && ! grep -qE '^\[ -d \.git \]' "$KIT_DIR/hooks/codebase-index.sh" && echo 0 || echo 1)"

assert_true "auto-index hook registered as SessionStart in both registries" \
  "$(grep -q 'codebase-index.sh' "$KIT_DIR/settings.json" && grep -q 'codebase-index.sh' "$KIT_DIR/hooks/hooks.json" && echo 0 || echo 1)"

# ============================================================
echo ""
echo "=== Task-type contracts (SPEC-044) ==="
# ============================================================
# Second axis of the verification gate: task TYPE -> proof artifact + owning skill,
# composed with the proof CLASS. Pins the classifier, the registry, and the
# proof-gate `contract` compose. These go RED if SPEC-044 is reverted (negative control).

TTC="$KIT_DIR/lib/classify/task-type-classify.sh"
TTREG="$KIT_DIR/docs/verification/task-types.md"

assert_true "lib/classify/task-type-classify.sh exists and is executable" \
  "$([ -x "$TTC" ] && echo 0 || echo 1)"

assert_eq "classify -> eval" "eval" "$(bash "$TTC" classify 'benchmark X vs Y for retrieval' 2>/dev/null)"
assert_eq "classify -> research" "research" "$(bash "$TTC" classify 'research the tooling landscape' 2>/dev/null)"
assert_eq "classify -> doc" "doc" "$(bash "$TTC" classify 'write the README for the tool' 2>/dev/null)"
assert_eq "classify -> migration" "migration" "$(bash "$TTC" classify 'migrate the database schema' 2>/dev/null)"
assert_eq "classify -> data-tool" "data-tool" "$(bash "$TTC" classify 'build a CLI to pull data from the API' 2>/dev/null)"
# Negative control: an unmatched description falls through to the default, not a wrong type.
assert_eq "classify default (neg control) -> spec-feature" "spec-feature" "$(bash "$TTC" classify 'add a sort button to the trade log' 2>/dev/null)"

assert_eq "task-type-classify types lists 12" "12" "$(bash "$TTC" types 2>/dev/null | grep -c .)"

assert_true "task-types.md registry exists" "$([ -f "$TTREG" ] && echo 0 || echo 1)"
for T in eval research doc migration data-tool spec-feature; do
  assert_true "registry has a row for '$T'" \
    "$(grep -qE "^\| *$T *\|" "$TTREG" && echo 0 || echo 1)"
done

CONTRACT_OUT="$(bash "$KIT_DIR/lib/gate/proof-gate.sh" contract 'build a CLI to pull data from the API' 2>/dev/null)"
assert_true "proof-gate contract names the data-tool type" \
  "$({ trap '' PIPE; printf '%s' "$CONTRACT_OUT" 2>/dev/null || :; } | grep -q 'type=data-tool' && echo 0 || echo 1)"
assert_true "proof-gate contract names the recorded-run artifact + owning skill" \
  "$({ trap '' PIPE; printf '%s' "$CONTRACT_OUT" 2>/dev/null || :; } | grep -qi 'recorded live run' && { trap '' PIPE; printf '%s' "$CONTRACT_OUT" 2>/dev/null || :; } | grep -qi 'ops-tool-shape' && echo 0 || echo 1)"
assert_true "proof-gate contract upgrades a migration to stateful (class wins on rigor)" \
  "$(bash "$KIT_DIR/lib/gate/proof-gate.sh" contract 'migrate the database schema' 2>/dev/null | grep -q 'class=stateful' && echo 0 || echo 1)"

# ============================================================

# ============================================================
echo ""
echo "=== SPEC-070: rid standardization pins ==="
# ============================================================
# Agreement pin (INTENTIONAL SEAM): both ends of the rid contract carry the
# exact #*/ strip transform; if either drops it, the contract is broken.
RC=0; grep -qF '#*/' "$KIT_DIR/hooks/ship-gate.sh" || RC=1
assert_eq "agreement pin: ship-gate carries the #*/ transform" 0 $RC
RC=0; grep -qF '#*/' "$KIT_DIR/lib/gate/gate-ledger.sh" || RC=1
assert_eq "agreement pin: gate-ledger rid carries the #*/ transform" 0 $RC
RC=0; grep -q '^  rid)' "$KIT_DIR/lib/gate/gate-ledger.sh" || RC=1
assert_eq "gate-ledger dispatches the rid verb" 0 $RC

# Sweep pin (AC5): no gate-ledger call site still uses <spec-slug> as a rid
# (debug.md's escaped-from spec REFERENCE is exempt; doc-path uses are not calls).
RESIDUAL=$(grep -rn 'spec-slug\|record <slug>' "$KIT_DIR/commands/" "$KIT_DIR/AGENTS.md" "$KIT_DIR/docs/WORKFLOW.md" 2>/dev/null | grep 'gate-ledger' | grep -v 'escaped-from' | wc -l | tr -d ' ')
assert_eq "sweep pin: zero gate-ledger rid call sites say spec-slug" "0" "$RESIDUAL"

# Entry-point wiring: assign derives the rid; AGENTS documents the contract once.
RC=0; grep -q 'gate-ledger.sh rid' "$KIT_DIR/commands/assign.md" || RC=1
assert_eq "assign.md derives RID via gate-ledger rid" 0 $RC
RC=0; grep -q 'SPEC-070' "$KIT_DIR/AGENTS.md" || RC=1
assert_eq "AGENTS.md carries the one-rid-per-run contract" 0 $RC


# ============================================================
echo ""
echo "=== SPEC-073 + ID-060: doc-loop second entry + eval design parked ==="
# ============================================================
RC=0; grep -qF 'standalone revision, content brief' "$KIT_DIR/docs/WORKFLOW.md" || RC=1
assert_eq "doc loop carries the standalone-revision entry path (ID-060)" 0 $RC
RC=0; grep -qF 'doc-verifier confirming docs match code' "$KIT_DIR/docs/WORKFLOW.md" || RC=1
assert_eq "doc loop both entries share the doc-verifier exit" 0 $RC
RC=0; grep -qF 'EXECUTION PARKED until 3-5 days' "$KIT_DIR/docs/specs/SPEC-073-telemetry-eval-design.md" || RC=1
assert_eq "telemetry eval design exists and is parked-until-data (ID-067)" 0 $RC
RC=0; grep -qF 'the design pins the WINDOW, not the flag' "$KIT_DIR/docs/specs/SPEC-073-telemetry-eval-design.md" || RC=1
assert_eq "eval design pins its data window honestly" 0 $RC


# ============================================================
echo ""
echo "=== SPEC-074: composition section + 3-surface parity (ID-066) ==="
# ============================================================
RC=0; grep -qF 'Lane x type composition (SPEC-074 / ID-066)' "$KIT_DIR/docs/WORKFLOW.md" || RC=1
assert_eq "WORKFLOW carries the lane x type composition rule" 0 $RC
RC=0; grep -qF 'recorded `skipped "<loop-step note>"`' "$KIT_DIR/docs/WORKFLOW.md" || RC=1
assert_eq "composition names the skip-with-loop-note mapping" 0 $RC
# 3-surface parity: every type in the loops table has a registry row and vice versa
LOOPT=$(awk '/## Type loops/,/### Lane x type composition/' "$KIT_DIR/docs/WORKFLOW.md" | grep '^| ' | cut -d'|' -f2 | tr -d ' ' | grep -v '^Type$' | grep -v '^-*$' | sort)
REGT=$(grep '^|' "$KIT_DIR/docs/verification/task-types.md" | cut -d'|' -f2 | tr -d ' ' | grep -v '^task-type$' | grep -v '^-*$' | sort)
assert_eq "type loops table and registry agree on the 12 types" "$LOOPT" "$REGT"


# SPEC-076: descent contract wired
RC=0; grep -qF 'The V-model descent contract (SPEC-076 / ID-068)' "$KIT_DIR/docs/WORKFLOW.md" || RC=1
assert_eq "WORKFLOW carries the descent contract" 0 $RC
RC=0; grep -q '^  descent)' "$KIT_DIR/lib/gate/gate-ledger.sh" || RC=1
assert_eq "gate-ledger dispatches the descent verb" 0 $RC
RC=0; grep -qF 'descent violation' "$KIT_DIR/hooks/ship-gate.sh" || RC=1
assert_eq "ship-gate carries the descent advisory" 0 $RC


# SPEC-077: per-link self-reconcile wired (the unit fixtures cover the helper; this
# pins the call site that gh-dependent flow tests cannot reach)
RC=0; grep -qF 'ensure_reconciled "$head" "$base"' "$KIT_DIR/lib/goal/stack-merge.sh" || RC=1
assert_eq "stack-merge next_link self-reconciles every link" 0 $RC
RC=0; grep -qF 'start --amend' "$KIT_DIR/lib/gate/gate-ledger.sh" || RC=1
assert_eq "gate-ledger documents the amend path" 0 $RC


# ============================================================
echo ""
echo "=== SPEC-078: review-team routing + tiering (ID-076/078) ==="
# ============================================================
RT="$KIT_DIR/commands/review-team.md"
RC=0; grep -qF 'gated_auto' "$RT" && grep -qF 'advisory' "$RT" && grep -qF 'route conservatively' "$RT" || RC=1
assert_eq "review-team carries the 3 apply-classes + conservative rule (ID-076)" 0 $RC
RC=0; grep -qF 'Route:' "$RT" || RC=1
assert_eq "report template carries the Route line" 0 $RC
RC=0; grep -qF 'becomes a board row' "$RT" && grep -qF 'responding-to-review' "$RT" || RC=1
assert_eq "decision gate routes each class to its destination" 0 $RC
RC=0; grep -qF 'matching the session model' "$RT" && grep -qF 'model: sonnet' "$RT" && grep -qF 'silently down-tier' "$RT" || RC=1
assert_eq "model tiering named per lens (ID-078)" 0 $RC
RC=0; grep -qiF 'if the override is unavailable' "$RT" || RC=1
assert_eq "tiering fallback sentence present" 0 $RC


# ============================================================
echo ""
echo "=== SPEC-080: verify-this delta + tripwires (ID-077/080) ==="
# ============================================================
VF="$KIT_DIR/commands/verify.md"
RT80="$KIT_DIR/commands/review-team.md"
RC=0; grep -qF 'condition + metric + threshold' "$VF" || RC=1
assert_eq "verify carries the claim-restatement preamble (ID-077)" 0 $RC
RC=0; grep -qF 'PASS / FAIL / INCONCLUSIVE' "$VF" && grep -qF 'honest third verdict' "$VF" || RC=1
assert_eq "INCONCLUSIVE is a legal verdict with named causes" 0 $RC
RC=0; grep -qF 'Baseline:' "$KIT_DIR/docs/verification/README.md" || RC=1
assert_eq "verification README carries the comparative-evidence line" 0 $RC
RC=0; grep -qF '1k lines' "$RT80" && grep -qiF 'spaghetti' "$RT80" || RC=1
assert_eq "Reviewer 2 carries both tripwires (ID-080)" 0 $RC
RC=0; grep -qiE "Verdict:.*INCONCLUSIVE" "$KIT_DIR/lib/gate/proof-ledger.sh" || RC=1
assert_eq "proof-ledger REJECTS an INCONCLUSIVE verdict (SPEC-080 guard present)" 0 $RC


# ============================================================
echo ""
echo "=== SPEC-081: anchored-confidence merge (ID-075) ==="
# ============================================================
RT81="$KIT_DIR/commands/review-team.md"
RC=0; grep -qF 'Confidence anchors (SPEC-081' "$RT81" || RC=1
assert_eq "Step 2 carries the confidence-anchor contract" 0 $RC
for a in "another lens would likely agree" "I can name the failing input" "the logic is airtight"; do
  RC=0; grep -qF "$a" "$RT81" || RC=1
  assert_eq "anchor self-test present: $a" 0 $RC
done
RC=0; grep -qF 'line-bucket' "$RT81" && grep -qF 'normalized title' "$RT81" || RC=1
assert_eq "fingerprint dedup rule present" 0 $RC
RC=0; grep -qF 'ONE anchor step' "$RT81" || RC=1
assert_eq "corroboration promotion rule present" 0 $RC
RC=0; grep -qF 'below 75 are suppressed' "$RT81" && grep -qF 'CRITICAL survives at 50' "$RT81" || RC=1
assert_eq "late confidence gate present (<75; CRITICAL at 50+)" 0 $RC
RC=0; grep -qF 'never silently dropped' "$RT81" && grep -qF 'Suppressed findings (below the confidence gate, or refuted by a validator)' "$RT81" || RC=1
assert_eq "suppressed-appendix never-drop rule + template section present" 0 $RC
RC=0; grep -qF 'Confidence: ' "$RT81" || RC=1
assert_eq "report rows carry Confidence" 0 $RC
# AC4 ordering: promotion paragraph before the gate paragraph
# (one-occurrence assumption: both anchor strings must stay unique in the file)
RC=0; [ "$(grep -c 'ONE anchor step' "$RT81")" = "1" ] && [ "$(grep -c 'below 75 are suppressed' "$RT81")" = "1" ] || RC=1
assert_eq "ordering-pin anchor strings are unique" 0 $RC
P=$(grep -n 'ONE anchor step' "$RT81" | head -1 | cut -d: -f1)
G=$(grep -n 'below 75 are suppressed' "$RT81" | head -1 | cut -d: -f1)
RC=0; [ -n "$P" ] && [ -n "$G" ] && [ "$P" -lt "$G" ] || RC=1
assert_eq "the confidence gate runs LATE (after promotion, by file order)" 0 $RC



# ============================================================
echo ""
echo "=== SPEC-082: per-finding validators (ID-079) ==="
# ============================================================
RT82="$KIT_DIR/commands/review-team.md"
RC=0; grep -qF 'Step 3b: Validate verdict-driving findings' "$RT82" || RC=1
assert_eq "Step 3b exists" 0 $RC
RC=0; grep -qF 'PER finding, never batched' "$RT82" || RC=1
assert_eq "per-finding never-batch rule present" 0 $RC
RC=0; grep -qF 'recreates the persona-bias problem' "$RT82" || RC=1
assert_eq "upstream rationale quoted" 0 $RC
RC=0; grep -qF 'adversarial REFUTER' "$RT82" && grep -qF 'DEMOTE to the suppressed appendix carrying the refutation' "$RT82" || RC=1
assert_eq "refuter framing + refuted disposition present" 0 $RC
RC=0; grep -qF 'marked validated' "$RT82" || RC=1
assert_eq "confirmed disposition present" 0 $RC
RC=0; grep -qF 'NEVER drops a CRITICAL/HIGH' "$RT82" && grep -qF 'unvalidated' "$RT82" || RC=1
assert_eq "infra-failure fail-safe present" 0 $RC
RC=0; grep -qF 'UNSUPPRESSED finding with severity CRITICAL or HIGH' "$RT82" || RC=1
assert_eq "scope line present (unsuppressed P0/P1 only)" 0 $RC
# ordering: 3b after the late gate, before Step 4
G=$(grep -n 'below 75 are suppressed' "$RT82" | head -1 | cut -d: -f1)
B=$(grep -n 'Step 3b: Validate verdict-driving findings' "$RT82" | head -1 | cut -d: -f1)
S4=$(grep -n '### Step 4' "$RT82" | head -1 | cut -d: -f1)
RC=0; [ -n "$G" ] && [ -n "$B" ] && [ -n "$S4" ] && [ "$G" -lt "$B" ] && [ "$B" -lt "$S4" ] || RC=1
assert_eq "Step 3b sits between the confidence gate and Step 4" 0 $RC


# ============================================================
echo ""
echo "=== SPEC-083: session-start board wire (ID-033) ==="
# ============================================================
CR83="$KIT_DIR/hooks/context-readiness.sh"
RC=0; grep -qF 'board:${BOARD_Q}q' "$CR83" || RC=1
assert_eq "hook emits the board state token" 0 $RC
RC=0; grep -qF 'Twin of lib/board/backlog.sh _rows' "$CR83" || RC=1
assert_eq "hook documents the parser-twin coupling" 0 $RC
RC=0; grep -qF 'state the task, or /kit:assign --next' "$CR83" || RC=1
assert_eq "queue suggestion is intent-first + assign --next" 0 $RC
RC=0; [ "$(grep -cF "say '" "$CR83")" -ge 4 ] || RC=1
assert_eq "cycle suggestions speak intent-first (4+ say-branches)" 0 $RC
RC=0; grep -qF '`_meta/BACKLOG.md` queue)' "$KIT_DIR/docs/MANUAL.md" || RC=1
assert_eq "MANUAL /kit:start Reads mentions the board" 0 $RC
RC=0; grep -qF 'board:Nq' "$KIT_DIR/docs/MANUAL.md" || RC=1
assert_eq "MANUAL hook row carries the board token" 0 $RC


# ============================================================
echo ""
echo "=== SPEC-084: hook fallback layer (ID-036) ==="
# ============================================================
ARCH84="$KIT_DIR/docs/architecture.md"
RC=0; grep -qF '## Hook fallback layer (closing the layering contract)' "$ARCH84" || RC=1
assert_eq "the section exists" 0 $RC
RC=0; grep -qF 'fallback for failure modes that survive prose instruction' "$ARCH84" || RC=1
assert_eq "the 3-layer fallback rule stated" 0 $RC
RC=0; grep -qF 'survive prose AND the damage is irreversible' "$ARCH84" || RC=1
assert_eq "placement decision test: hard criterion" 0 $RC
# parity: one table row per hooks/*.sh file, both sides computed
HOOK_FILES=$(ls "$KIT_DIR"/hooks/*.sh | wc -l | tr -d ' ')
HOOK_ROWS=$(awk '/^## Hook fallback layer/,/^## [^H]/' "$ARCH84" | grep -cE '^\| `[a-z-]+` \|' || true)
assert_eq "parity: table rows == hook files ($HOOK_FILES)" "$HOOK_FILES" "$HOOK_ROWS"
for H in safety-gate secrets-guard ship-gate commit-format anti-rationalization; do
  RC=0; awk '/^## Hook fallback layer/,/^## [^H]/' "$ARCH84" | grep -E "^\| .$H. \|" | grep -q 'hard' || RC=1
  assert_eq "hard class declared: $H" 0 $RC
done
RC=0; grep -qF 'guardrail = the hard subset' "$ARCH84" || RC=1
assert_eq "C3 reconciliation present (bounded guardrail)" 0 $RC
RC=0; grep -qF 'ID-012 P2' "$ARCH84" && grep -qF 'ID-027' "$ARCH84" || RC=1
assert_eq "folded concerns dispositioned" 0 $RC
RC=0; grep -qF 'autonomous loop' "$KIT_DIR/commands/spec-validate.md" || RC=1
assert_eq "spec-validate Reviewer 4 autonomy-gate bullet" 0 $RC
RC=0; grep -qF 'the hook-fallback layer is still open' "$ARCH84" && RC=1
assert_eq "the still-open marker is gone" 0 $RC
RC=0; grep -qF '"Hook fallback layer"' "$KIT_DIR/AGENTS.md" || RC=1
assert_eq "AGENTS.md points at the layering contract" 0 $RC


# ============================================================
echo ""
echo "=== SPEC-085: operator doc sync (ID-070) ==="
# ============================================================
RM85="$KIT_DIR/README.md"
# parity: ROW counts only (summary-header numbers retired by the no-counts policy 2026-08-10)
HF=$(ls "$KIT_DIR"/hooks/*.sh | wc -l | tr -d ' ')
HROWS=$(awk '/<summary><b>Hooks<\/b>/,/<\/details>/' "$RM85" | grep -cE '^\| [a-z]' || true)
assert_eq "README hooks rows == hook files ($HF)" "$HF" "$HROWS"
CF=$(ls "$KIT_DIR"/commands/*.md | wc -l | tr -d ' ')
CROWS=$(awk '/<summary><b>Commands<\/b>/,/<\/details>/' "$RM85" | grep -cE '^\| /kit:' || true)
assert_eq "README commands rows == command files ($CF)" "$CF" "$CROWS"
# content: the hard hook is in the public table; the two missing commands exist
RC=0; awk '/<summary><b>Hooks<\/b>/,/<\/details>/' "$RM85" | grep -q '^| ship-gate' || RC=1
assert_eq "README hooks table carries ship-gate" 0 $RC
RC=0; awk '/<summary><b>Commands<\/b>/,/<\/details>/' "$RM85" | grep -q 'kit:adopt' && awk '/<summary><b>Commands<\/b>/,/<\/details>/' "$RM85" | grep -q 'kit:test-plan-review-team' || RC=1
assert_eq "README commands table carries adopt + test-plan-review-team" 0 $RC
RC=0; awk '/<summary><b>Hooks<\/b>/,/<\/details>/' "$RM85" | grep '^| context-readiness' | grep -q 'board' || RC=1
assert_eq "README context-readiness row is board-aware (SPEC-083)" 0 $RC

# ============================================================
echo ""
echo "=== ADR-0029: review-function naming convention (SG-08) ==="
# ============================================================
# The SG-08 rename (three retired-suffix agent names migrated onto the
# reviewer/verifier/team axis; see ADR-0029) is a one-time migration; this
# block is the machine enforcement that keeps a FUTURE off-axis review-agent
# name from landing silently. Two pure-function checks below (name -> pass/fail)
# back both the real-roster scan (a)/(b) and the negative control (c), so the
# same logic that gates the repo is the logic proven to discriminate.

# is_retired_suffix NAME -> 0 (banned) | 1 (not banned)
# Retired per the ADR-0029 rename map: -checker, -auditor, bare "reviewer",
# and "-validate" used as a review-function suffix.
is_retired_suffix() {
  case "$1" in
    *-checker) return 0 ;;
    *-auditor) return 0 ;;
    reviewer) return 0 ;;
    *-validate) return 0 ;;
    *) return 1 ;;
  esac
}

# is_on_review_axis NAME -> 0 (conforms) | 1 (off-axis)
# The convention's positive axis: a review-function name ends in -reviewer
# (static/left-arm), -verifier (dynamic/right-arm), or -team (panel command).
# advisor, agent-effectiveness, and break-it are the named-noun exceptions (see (b)).
is_on_review_axis() {
  case "$1" in
    *-reviewer) return 0 ;;
    *-verifier) return 0 ;;
    *-team) return 0 ;;
    advisor) return 0 ;;
    agent-effectiveness) return 0 ;;
    # break-it reads the WHOLE branch for an unconstrained input, so it is a
    # cross-cutting named-noun lens like advisor, not a per-artifact -reviewer.
    break-it) return 0 ;;
    *) return 1 ;;
  esac
}

# (a) GLOBAL BAN, roster-scanning: no agent, command, or skill name may use a
# retired suffix. The roster is DERIVED from the live dirs (same derivation
# style as the SPEC-219 registry-freshness pin), so a new commands/foo-checker.md
# or skills/foo-validate/ fails here the moment it lands, without anyone
# updating this test. Grandfathered names predate this widening and are pinned
# pending the operator decisions recorded in
# docs/research/2026-08-01-naming-reconciliation.md (visible debt, not license):
#   spec-validate -- finding 3 / proposal "/kit:spec-validate -> /kit:spec-team"
#                    (a dedicated migration PR with a legacy alias window).
RETIRED_GRANDFATHERED="spec-validate"
ALL_NAMES=""
for AGENT_FILE in "$KIT_DIR/agents/"*.md; do
  ALL_NAMES="$ALL_NAMES agents/$(awk -F': ' '/^name:/{print $2; exit}' "$AGENT_FILE" | tr -d '[:space:]')"
done
for CMD_FILE in "$KIT_DIR/commands/"*.md; do
  ALL_NAMES="$ALL_NAMES commands/$(basename "$CMD_FILE" .md)"
done
for SKILL_DIR in "$KIT_DIR/skills/"*/; do
  ALL_NAMES="$ALL_NAMES skills/$(basename "$SKILL_DIR")"
done
for ENTRY in $ALL_NAMES; do
  NAME="${ENTRY#*/}"
  TOTAL=$((TOTAL + 1))
  if ! is_retired_suffix "$NAME"; then
    echo -e "  ${GREEN}PASS${NC} $ENTRY is not a retired suffix"
    PASS=$((PASS + 1))
  else
    case " $RETIRED_GRANDFATHERED " in
      *" $NAME "*)
        echo -e "  ${GREEN}PASS${NC} $ENTRY uses a retired suffix but is GRANDFATHERED (naming-reconciliation report, pending operator decision)"
        PASS=$((PASS + 1))
        ;;
      *)
        echo -e "  ${RED}FAIL${NC} $ENTRY uses a retired suffix"
        FAIL=$((FAIL + 1))
        ;;
    esac
  fi
done

# (b) POSITIVE AXIS, roster-scanning: every current V-model review agent must
# be on-axis, i.e. end in -reviewer/-verifier/-team, OR be one of the three
# allowed named-noun validators. `advisor` is the ADR-0028 cross-cutting
# generic lens (not per-artifact, so it earns its own noun).
# `agent-effectiveness` (SPEC-088, SG-01) is intentionally allowed too: it
# reviews an AGENT DEFINITION, not a V-model work artifact, so like `advisor`
# it is a named-noun validator, NOT a naming violation -- do not "fix" its
# name to *-reviewer.
# `break-it` (SPEC-247) joins them: it probes the WHOLE branch for an input the
# suite does not constrain, a cross-cutting lens like `advisor`, so a
# *-reviewer suffix would misname it as per-artifact -- do not "fix" it either.
# The review-agent roster is DERIVED from the live agents/ dir instead of a
# frozen name list (the pre-widening hardcoded 11 names missed every agent
# added after the list froze; naming-reconciliation finding 6): a review agent
# is any agent whose tools roster is read-only (no Write/Edit), minus the
# ADR-0029:89 out-of-scope names (the research-* prefix family and
# responding-to-review; finding 7). Grandfathered off-axis names are pinned
# pending the operator decisions in the same report:
#   audit-scanner -- finding 4 / proposal: amend ADR-0029 to sanction -scanner
#                    as the evidence-gathering class, or rename audit-reviewer.
# (claim-verifier passes this suffix scan but wears the wrong CLASS of suffix,
#  finding 2 / proposal claim-reviewer or a -team shape; a suffix scan cannot
#  police semantics, so that stays a report proposal, not a test.)
# devops-triage -- shipped read-only with no axis suffix (SPEC-239 era);
#                  proposal: triage-reviewer, or sanction -triage as an
#                  incident class. Pending operator decision (ID-639).
AXIS_GRANDFATHERED="audit-scanner devops-triage"
REVIEW_AGENTS=""
for AGENT_FILE in "$KIT_DIR/agents/"*.md; do
  AGENT_NAME=$(awk -F': ' '/^name:/{print $2; exit}' "$AGENT_FILE" | tr -d '[:space:]')
  case "$AGENT_NAME" in research-*|responding-to-review) continue ;; esac
  WRITECAP=$(awk '/^---$/{c++; next} c==1' "$AGENT_FILE" | grep -cE '^[[:space:]]*-[[:space:]]*(Write|Edit|MultiEdit|NotebookEdit)$')
  [ "$WRITECAP" -eq 0 ] || continue
  REVIEW_AGENTS="$REVIEW_AGENTS $AGENT_NAME"
done
for NAME in $REVIEW_AGENTS; do
  TOTAL=$((TOTAL + 1))
  if is_on_review_axis "$NAME"; then
    echo -e "  ${GREEN}PASS${NC} review agent '$NAME' is on the naming axis (reviewer|verifier|team|named-noun)"
    PASS=$((PASS + 1))
  else
    case " $AXIS_GRANDFATHERED " in
      *" $NAME "*)
        echo -e "  ${GREEN}PASS${NC} review agent '$NAME' is OFF-axis but GRANDFATHERED (naming-reconciliation report, pending operator decision)"
        PASS=$((PASS + 1))
        ;;
      *)
        echo -e "  ${RED}FAIL${NC} review agent '$NAME' is OFF the ADR-0029 naming axis"
        FAIL=$((FAIL + 1))
        ;;
    esac
  fi
done
# Derivation floor: an awk/frontmatter format change must not silently derive
# an empty (or gutted) roster and pass vacuously. Two anchors: one pre-freeze
# name, one post-freeze addition the old hardcoded list missed.
RC=0
case " $REVIEW_AGENTS " in *" task-verifier "*) : ;; *) RC=1 ;; esac
case " $REVIEW_AGENTS " in *" api-reviewer "*) : ;; *) RC=1 ;; esac
assert_eq "derived review-agent roster contains task-verifier + api-reviewer (derivation not vacuous)" 0 $RC

# (c) NEGATIVE CONTROL: prove the ban logic actually discriminates, not just
# that it always passes. Feed it fake names only (never a real agents/ file).
RC=0
is_retired_suffix "foo-checker" || RC=1
is_retired_suffix "foo-auditor" || RC=1
is_retired_suffix "reviewer" || RC=1
is_retired_suffix "foo-validate" || RC=1
assert_eq "negative control: is_retired_suffix REJECTS foo-checker/foo-auditor/reviewer/foo-validate" 0 $RC

RC=0
is_retired_suffix "foo-reviewer" && RC=1
is_retired_suffix "foo-verifier" && RC=1
is_retired_suffix "foo-team" && RC=1
is_retired_suffix "advisor" && RC=1
assert_eq "negative control: is_retired_suffix does NOT flag conforming names (no false positives)" 0 $RC

RC=0
is_on_review_axis "foo-checker" && RC=1
is_on_review_axis "foo-auditor" && RC=1
is_on_review_axis "foo-scanner" && RC=1
assert_eq "negative control: is_on_review_axis REJECTS off-axis fake names" 0 $RC

# ============================================================
# SPEC-107: cheap-tier defaults , three authoring surfaces, one sonnet-first stance.
# (Surface 2, the plan-for-mega-goal subgoal-template, lives in the dotfiles repo and
#  is proven by a LOCAL diff, not here , its path is absent in CI.)
# ============================================================
EX="$KIT_DIR/commands/execute.md"
RC=0; grep -qiE 'workers dispatch at .?sonnet.? by default' "$EX" || RC=1
assert_eq "execute.md workers default to sonnet (SPEC-107 surface 1)" 0 $RC
RC=0; grep -qiE 'Model:.*(escape hatch|hard[- ]reasoning|override)' "$EX" || RC=1
assert_eq "execute.md names the spec Model: escape hatch (SPEC-107 surface 1)" 0 $RC

MA="$KIT_DIR/agents/meta-agent.md"
RC=0; grep -qiE 'write .?Model: sonnet' "$MA" || RC=1
assert_eq "meta-agent Mode B writes Model: sonnet on abstain (SPEC-107 surface 3)" 0 $RC
# Negative controls: the OLD contradicting stance is GONE, not merely supplemented.
RC=0; grep -qF "human's call, not a silent auto-write" "$MA" && RC=1
assert_eq "negative control: old 'human's call' contradiction removed from meta-agent" 0 $RC
RC=0; grep -qE 'OMIT the .?Model:.? line' "$MA" && RC=1
assert_eq "negative control: old 'OMIT the Model: line' abstain removed from meta-agent" 0 $RC

# ============================================================
# SPEC-244: verifier tier parity , a verifier is never dumber than its worker.
# ============================================================
PARITY='dispatch with an explicit model override matching the spec tier'
RC=0; grep -qE '^model: opus$' "$KIT_DIR/agents/recheck-verifier.md" || RC=1
assert_eq "recheck-verifier pins model: opus (SPEC-244)" 0 $RC
RC=0; grep -qF "$PARITY" "$EX" || RC=1
assert_eq "execute.md carries the verifier parity override sentence (SPEC-244)" 0 $RC
RC=0; grep -qF "$PARITY" "$KIT_DIR/commands/verify.md" || RC=1
assert_eq "verify.md carries the verifier parity override sentence (SPEC-244)" 0 $RC
# Negative control: the OLD wall-off stance is GONE from execute.md, not merely supplemented.
RC=0; grep -qF 'Verifiers keep their own frontmatter tiers (unchanged).' "$EX" && RC=1
assert_eq "negative control: old verifier wall-off sentence removed from execute.md" 0 $RC
# doc-verifier is deliberately out of scope (docs phase, not spec-tier-bound).
RC=0; grep -qE '^model: sonnet$' "$KIT_DIR/agents/doc-verifier.md" || RC=1
assert_eq "doc-verifier stays sonnet (SPEC-244 decision c)" 0 $RC

# ============================================================
# SPEC-108: meta-agent provenance , the generated agents carry a well-formed generated-by:,
# and the key is SET-EQUAL to the known generated roster (no silent spread to hand-written agents).
# ============================================================
GEN_ROSTER="acceptance-verifier advisor brief-reviewer recheck-verifier system-verifier api-reviewer data-etl-worker db-migration-worker frontend-reviewer infra-reviewer performance-reviewer"
for a in $GEN_ROSTER; do
  RC=0; grep -qE '^generated-by: draft-agent [0-9]{4}-[0-9]{2}-[0-9]{2} .+' "$KIT_DIR/agents/$a.md" || RC=1
  assert_eq "generated agent $a carries a well-formed generated-by (SPEC-108)" 0 $RC
done
GEN_ACTUAL=$(grep -lE '^generated-by:' "$KIT_DIR/agents/"*.md 2>/dev/null | while read -r f; do basename "$f" .md; done | sort | tr '\n' ' ' | sed 's/ *$//')
GEN_EXPECTED=$(printf '%s\n' $GEN_ROSTER | sort | tr '\n' ' ' | sed 's/ *$//')
assert_eq "generated-by key set-equals the known generated roster (no spread to hand-written agents)" "$GEN_EXPECTED" "$GEN_ACTUAL"

# ============================================================
# SPEC-109: operator-persona design lens , opt-in 6th visual-team lens GATED on persona-supplied
# (byte-compatible without the arg), persisted + threaded from ui-design, boundary recorded (DEC-017).
# ============================================================
VT="$KIT_DIR/commands/visual-team.md"
RC=0; grep -qF 'persona: <archetype>' "$VT" || RC=1
assert_eq "visual-team accepts a persona: <archetype> arg (SPEC-109)" 0 $RC
RC=0; grep -qiF 'operator persona' "$VT" || RC=1
assert_eq "visual-team has an operator-persona 6th lens (SPEC-109)" 0 $RC
# F1 conditionality pins , the 6th lens AND the 6th Scores row carry a persona-supplied guard,
# so an UNCONDITIONAL 6th lens (which would break byte-compat) fails the test, not just its absence.
RC=0; grep -qiE 'ONLY when a .?persona' "$VT" || RC=1
assert_eq "6th persona lens is GATED on persona-supplied (SPEC-109 conditionality)" 0 $RC
RC=0; grep -qiE 'row appears ONLY when a .?persona' "$VT" || RC=1
assert_eq "6th Scores row is GATED on persona-supplied (SPEC-109 conditionality)" 0 $RC
# NEGATIVE CONTROL: the 5 existing lenses present verbatim + no-arg fires exactly 5, byte-identical.
for L in 'Hierarchy / typography' 'System-consistency' 'Accessibility / contrast' 'Restraint / simplicity' 'Expressiveness / brand-fit'; do
  RC=0; grep -qF "$L" "$VT" || RC=1
  assert_eq "visual-team 5-lens NC: '$L' present unchanged (SPEC-109)" 0 $RC
done
RC=0; grep -qiF 'byte-identical' "$VT" || RC=1
assert_eq "visual-team no-arg path is byte-identical / exactly 5 lenses (SPEC-109 NC)" 0 $RC
# F2 ui-design PERSISTS (brief line) AND THREADS (forwards to visual-team $ARGUMENTS).
UIDESIGN="$KIT_DIR/commands/ui-design.md"
RC=0; grep -qiF 'Persona (optional)' "$UIDESIGN" || RC=1
assert_eq "ui-design brief seeds a Persona line (SPEC-109 persist)" 0 $RC
RC=0; grep -qF 'persona: <archetype>' "$UIDESIGN" || RC=1
assert_eq "ui-design Step 3 forwards Persona into visual-team ARGUMENTS (SPEC-109 thread)" 0 $RC
# Governance: DEC-017 formal in SPEC-109 + reciprocal pointer in SPEC-016 + kit-health carve-out.
RC=0; { grep -q 'DEC-017' "$KIT_DIR/docs/specs/SPEC-109-persona-lens.md" && grep -q 'DEC-017' "$KIT_DIR/docs/specs/SPEC-016-critique-and-test-lanes.md"; } || RC=1
assert_eq "DEC-017 recorded in SPEC-109 + reciprocal pointer in SPEC-016 (SPEC-109)" 0 $RC
RC=0; grep -qiF 'operator-supplied' "$KIT_DIR/commands/kit-health.md" || RC=1
assert_eq "kit-health check-13 carries the operator-persona carve-out (SPEC-109)" 0 $RC

# ============================================================
# SPEC-112: UI done-modes , the Done-mode flag + the TWO-SIDED quiescence stop (the no-false-
# quiescence NC pinned as the full conjunction) + the fixture traces in the proof-of-done.
# ============================================================
UIDM="$KIT_DIR/commands/ui-design.md"
RC=0; grep -qiE 'Done-mode' "$UIDM" || RC=1
assert_eq "ui-design consumes a Done-mode flag (SPEC-112)" 0 $RC
RC=0; grep -qiE 'zero NEW findings >=HIGH AND no OPEN finding >=HIGH' "$UIDM" || RC=1
assert_eq "quiescence stop is TWO-SIDED: zero NEW >=HIGH AND no OPEN >=HIGH (no-false-quiescence NC)" 0 $RC
RC=0; grep -qiE 'does NOT quiesce|re-finds an|falsely-calm' "$UIDM" || RC=1
assert_eq "the re-found-CRITICAL-does-not-quiesce trap is stated (SPEC-112)" 0 $RC
RC=0; grep -qF '[[QL-VERDICT' "$UIDM" || RC=1
assert_eq "quiescence emits QL-VERDICT round markers (SPEC-112)" 0 $RC
RC=0; grep -qiE 'Deferred findings' "$UIDM" || RC=1
assert_eq "Deferred findings subsection defined (SPEC-112)" 0 $RC
RC=0; { grep -qiE 'Round cap: 3' "$UIDM" && grep -qiE 'cap of 2' "$UIDM"; } || RC=1
assert_eq "cap divergence pinned: quiescence 3, plain REVISE 2 (SPEC-112 DEC-018)" 0 $RC
RC=0; grep -qiE 'COVERAGE-DELTA|ACs-covered' "$UIDM" || RC=1
assert_eq "over-test coverage-delta row defined (SPEC-112)" 0 $RC
# fixture TRACES pinned in the proof-of-done (the goal's crux proof, not just the contract text):
DMPROOF="$KIT_DIR/docs/verification/done-modes.md"
RC=0; { grep -qiE 'converge' "$DMPROOF" && grep -qiE 'cap-out|round 3|round cap 3' "$DMPROOF" && grep -qiE 're-found|does NOT quiesce|falsely' "$DMPROOF" && grep -qiE 'plain REVISE|cap.*2' "$DMPROOF"; } || RC=1
assert_eq "done-modes proof carries the 3 quiescence fixtures + plain-REVISE regression (SPEC-112)" 0 $RC

# ============================================================
echo ""
echo "=== Feature-registry freshness pin (SPEC-219) ==="
# ============================================================
# docs/FEATURES.md is a generated projection (lib/registry/feature-registry.sh).
# Same class as the derived-count pins above: regenerate to a temp file and diff
# against the committed copy; ANY drift (a feature added/removed/renamed, a
# description or wiring change) fails here until the registry is regenerated.
REG_TMP=$(mktemp)
bash "$KIT_DIR/lib/registry/feature-registry.sh" generate "$REG_TMP" 2>/dev/null
diff -q "$REG_TMP" "$KIT_DIR/docs/FEATURES.md" >/dev/null 2>&1
assert_true "docs/FEATURES.md is fresh (regenerate == committed, SPEC-219)" $?
# AC-1 determinism pin (review finding): a second run must be byte-identical, so a
# future edit that reintroduces nondeterminism (locale, glob order, a timestamp)
# fails HERE even when the committed file was regenerated in the same PR.
REG_TMP2=$(mktemp)
bash "$KIT_DIR/lib/registry/feature-registry.sh" generate "$REG_TMP2" 2>/dev/null
cmp -s "$REG_TMP" "$REG_TMP2"
assert_true "feature-registry generator is deterministic (double run byte-identical, SPEC-219)" $?
# Skill-dispatcher derivation pin: an agent dispatched only by skills must not
# show `-`; audit-scanner is dispatched by the doc-drift + topology-drift + ci-drift skills
# (cap_list caps the shown names at 3 alphabetically then "+N" for the rest, so a fourth
# dispatcher pushes the last name into the overflow count rather than dropping it silently).
ASROW=$(grep -E '^\| `audit-scanner` ' "$KIT_DIR/docs/FEATURES.md")
RC=0; { { trap '' PIPE; echo "$ASROW" 2>/dev/null || :; } | grep -q 'doc-drift (skill)' && { trap '' PIPE; echo "$ASROW" 2>/dev/null || :; } | grep -q 'ci-drift (skill)' && { trap '' PIPE; echo "$ASROW" 2>/dev/null || :; } | grep -qE '\+[0-9]+ *\|'; } || RC=1
assert_eq "audit-scanner dispatched-by names doc-drift + ci-drift, overflow count covers the rest" 0 $RC
rm -f "$REG_TMP" "$REG_TMP2"

# ============================================================
echo ""
echo "=== Self-intro convention (SPEC-222) ==="
# ============================================================
# AGENTS.md carries the self-intro convention (every /kit: command opens its
# first reply with a `[kit:<name>] <purpose>` banner; dispatched agents' reports
# open the same way), and the three highest-traffic entry commands wire it
# concretely. Remaining commands adopt on next touch; the AGENTS.md contract
# covers them meanwhile, so only these four surfaces are pinned.
RC=0; { grep -qF '## Self-intro' "$AGENTS_MD" && grep -qF '[kit:<name>]' "$AGENTS_MD"; } || RC=1
assert_eq "AGENTS.md carries the Self-intro convention section + banner format (SPEC-222)" 0 $RC
for CMD in start assign execute; do
  assert_true "commands/$CMD.md wires the self-intro banner (SPEC-222)" \
    "$(grep -qF "[kit:$CMD]" "$KIT_DIR/commands/$CMD.md" && echo 0 || echo 1)"
done

echo ""
echo "=== Results ==="
# ============================================================
echo -e "Passed: ${GREEN}${PASS}${NC} / ${TOTAL}"
if [ "$FAIL" -gt 0 ]; then
  echo -e "Failed: ${RED}${FAIL}${NC}"
  exit 1
else
  echo -e "${GREEN}All meta tests passed.${NC}"
  exit 0
fi
