#!/bin/bash
# test-meta-agent.sh -- the meta-agent drafter (token-optim-v3 SG-05).
# Validates: (1) agents/meta-agent.md is a well-formed kit agent; (2) the
# committed golden drafts (a subagent + a sub-goal file the drafter produced)
# pass the kit's frontmatter/structure checks AND carry the DRAFT marker.
#
# Run: bash tests/test-meta-agent.sh   (exit 0 = pass, 1 = fail)

KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$KIT_DIR/tests/fixtures/meta-agent"
PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

ok()   { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}PASS${NC} $1"; }
bad()  { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo -e "  ${RED}FAIL${NC} $1"; }
chk()  { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }

# Lint a file's YAML frontmatter the same way test-meta.sh lints agents/.
# $1 label  $2 file  $3 first-content-line (1 = real first line, 2 = after a marker line)
lint_agent_frontmatter() {
  local label="$1" f="$2" start="${3:-1}"
  local body; body=$(tail -n +"$start" "$f")
  [ "$(printf '%s\n' "$body" | head -1)" = "---" ]; chk "$label: frontmatter opens with ---" $?
  local name desc model tools
  name=$(printf '%s\n' "$body" | awk '/^---$/{c++; if(c==2)exit} c==1 && /^name:/' | wc -l | tr -d ' ')
  desc=$(printf '%s\n' "$body" | awk '/^---$/{c++; if(c==2)exit} c==1 && /^description:/' | wc -l | tr -d ' ')
  tools=$(printf '%s\n' "$body" | awk '/^---$/{c++; if(c==2)exit} c==1 && /^tools:/' | wc -l | tr -d ' ')
  model=$(printf '%s\n' "$body" | awk -F': *' '/^---$/{c++; if(c==2)exit} c==1 && /^model:/{print $2; exit}' | tr -d '[:space:]')
  [ "$name" = "1" ];  chk "$label: has name field" $?
  [ "$desc" = "1" ];  chk "$label: has description field" $?
  [ "$tools" = "1" ]; chk "$label: has tools field" $?
  { trap '' PIPE; echo "$model" 2>/dev/null || :; } | grep -qE '^(sonnet|haiku|opus)$'; chk "$label: model is sonnet|haiku|opus ($model)" $?
  # minimal tools: never a bare unscoped Bash entry
  if printf '%s\n' "$body" | awk '/^---$/{c++; if(c==2)exit} c==1' | grep -qE '^[[:space:]]*-[[:space:]]*Bash[[:space:]]*$'; then
    bad "$label: tools are minimal (no bare 'Bash')"
  else
    ok "$label: tools are minimal (no bare 'Bash')"
  fi
}

echo "=== meta-agent definition ==="
MA="$KIT_DIR/agents/meta-agent.md"
[ -f "$MA" ]; chk "agents/meta-agent.md exists" $?
lint_agent_frontmatter "meta-agent" "$MA" 1
grep -q "Mode A" "$MA" && grep -q "Mode B" "$MA" && grep -q "Mode C" "$MA"; chk "meta-agent documents all three modes (A/B draft, C inline)" $?
# Mode C = immediate same-run dispatch: returns an inline spec, writes no file, exempt from the marker.
grep -qi 'inline role spec' "$MA" && grep -qi 'PREAMBLE' "$MA"; chk "meta-agent Mode C returns an inline PREAMBLE (no file)" $?
# Mode C is the OPEN-ENDED authority: infers any role, or returns NO_SPECIALIST for a plain task.
grep -qi 'open-ended' "$MA" && grep -q 'NO_SPECIALIST' "$MA"; chk "meta-agent Mode C is open-ended (any role) + can return NO_SPECIALIST" $?
grep -qi 'fast-path\|fast path' "$KIT_DIR/lib/classify/role-classify.sh"; chk "role-classify is framed as a fast-path hint, not the role universe" $?
# the execute workflow auto-classifies each task and injects a synthesized specialist preamble.
EX="$KIT_DIR/commands/execute.md"
grep -q '2b-0' "$EX" && grep -qi 'classif' "$EX"; chk "execute.md has the 2b-0 role-classification step" $?
grep -qi 'Mode C' "$EX" && grep -qi 'preamble' "$EX"; chk "execute.md dispatches Mode C + injects the preamble same-run" $?
grep -qi 'generic' "$EX"; chk "execute.md falls through to the generic worker on no-domain-match" $?
# the SUBAGENT itself never installs (it drafts to staging); promotion is the command's job.
grep -qi 'never install\|only draft to staging' "$MA"; chk "meta-agent (subagent) itself never installs , drafts to staging" $?
grep -q '^| `meta-agent` ' "$KIT_DIR/docs/MANUAL.md"; chk "meta-agent listed in MANUAL.md (test-meta.sh cross-ref, bulk at docs/MANUAL.md per SPEC-185)" $?
DA_CMD="$KIT_DIR/commands/draft-agent.md"
[ -f "$DA_CMD" ] && head -1 "$DA_CMD" | grep -q '^---$'; chk "commands/draft-agent.md exists with frontmatter" $?
# pin the NEW contract: default-install + a --draft opt-out + the roster/test-meta guard + runtime activation.
grep -qi 'install' "$DA_CMD" && grep -qi 'default' "$DA_CMD"; chk "draft-agent installs by default" $?
grep -q -- '--draft' "$DA_CMD"; chk "draft-agent keeps a --draft opt-out (stop at the staged draft)" $?
grep -q 'test-meta.sh' "$DA_CMD"; chk "draft-agent runs test-meta.sh after install (roster guard stays green)" $?
grep -q '~/.claude/agents' "$DA_CMD"; chk "draft-agent activates the agent for runtime (~/.claude/agents)" $?
grep -qi 'drafts/' "$DA_CMD"; chk "draft-agent still names the concrete drafts/ staging path (for --draft)" $?

MARKER='<!-- DRAFT , review before use. Drafted by meta-agent. Not installed. -->'

echo ""
echo "=== golden draft: subagent (Mode A) ==="
DA="$FIX/drafted-agent.md"
[ -f "$DA" ]; chk "drafted-agent.md exists" $?
[ "$(head -1 "$DA")" = "$MARKER" ]; chk "drafted-agent.md: DRAFT marker is line 1" $?
lint_agent_frontmatter "drafted-agent" "$DA" 2   # frontmatter starts after the marker line
EMDASH=$(printf '\xe2\x80\x94')   # U+2014 as raw UTF-8 bytes (portable: no grep -P)
LC_ALL=C grep -qF "$EMDASH" "$DA" && bad "drafted-agent.md: no em-dash" || ok "drafted-agent.md: no em-dash"

# Simulate the DEFAULT install promotion of the golden draft (strip marker -> agents/<name>.md),
# into a temp dir so the real repo + ~/.claude are untouched. Proves the install path yields a
# valid, marker-free, lint-passing agent that is dispatchable-shaped.
TMPAG="$(mktemp -d "${TMPDIR:-/tmp}/meta-install.XXXXXX")"
tail -n +2 "$DA" > "$TMPAG/installed.md"   # drop the line-1 DRAFT marker
[ "$(head -1 "$TMPAG/installed.md")" = "---" ]; chk "install: marker stripped, frontmatter is now line 1" $?
LC_ALL=C grep -qF "$MARKER" "$TMPAG/installed.md" && bad "install: no DRAFT marker remains" || ok "install: no DRAFT marker remains"
lint_agent_frontmatter "installed-agent" "$TMPAG/installed.md" 1   # passes the SAME lint as a live kit agent
INAME=$(awk -F': *' '/^---$/{c++; if(c==2)exit} c==1 && /^name:/{print $2; exit}' "$TMPAG/installed.md" | tr -d '[:space:]')
[ -n "$INAME" ] && cp "$TMPAG/installed.md" "$TMPAG/$INAME.md" && [ -f "$TMPAG/$INAME.md" ]; chk "install: lands as <name>.md in the agents dir (runtime-discoverable shape)" $?
# SPEC-108: the install step (draft-agent Step 4.2) STAMPS provenance. Simulate the stamp and
# assert the emitted key is well-formed , a NEW-generation emit fixture, not just the backfill.
STAMP="generated-by: draft-agent 2026-07-02 install-sim fixture (SPEC-108)"
awk -v s="$STAMP" '{print} /^model:/{print s}' "$TMPAG/installed.md" > "$TMPAG/stamped.md"
grep -qE '^generated-by: draft-agent [0-9]{4}-[0-9]{2}-[0-9]{2} .+' "$TMPAG/stamped.md"; chk "install: Step-4 stamps a well-formed generated-by (SPEC-108 emit fixture)" $?
lint_agent_frontmatter "stamped-agent" "$TMPAG/stamped.md" 1   # still lints with the provenance key
rm -rf "$TMPAG"

echo ""
echo "=== golden draft: sub-goal file (Mode B) ==="
DS="$FIX/drafted-subgoal.md"
[ -f "$DS" ]; chk "drafted-subgoal.md exists" $?
[ "$(head -1 "$DS")" = "$MARKER" ]; chk "drafted-subgoal.md: DRAFT marker is line 1" $?
grep -qE '^# Sub-goal [0-9]+:' "$DS"; chk "drafted-subgoal.md: has '# Sub-goal NN:' heading" $?
for FIELD in 'Merge policy:' 'Time budget:' 'Proof:' 'Depends on:' 'Branch:' 'PR base:'; do
  grep -qF "$FIELD" "$DS"; chk "drafted-subgoal.md: has '$FIELD'" $?
done
grep -qE '^Model:' "$DS";  chk "drafted-subgoal.md: bare Model: line (orchestrator-parsable)" $?
grep -qE '^Effort:' "$DS"; chk "drafted-subgoal.md: bare Effort: line (orchestrator-parsable)" $?
grep -qF '**Done =**' "$DS"; chk "drafted-subgoal.md: has bold **Done =** boolean" $?
for SEC in '## Outcome' '## Quality bar' '## How to close the loop' '## Scope edges' '## PR body'; do
  grep -qF "$SEC" "$DS"; chk "drafted-subgoal.md: has '$SEC'" $?
done
LC_ALL=C grep -qF "$EMDASH" "$DS" && bad "drafted-subgoal.md: no em-dash" || ok "drafted-subgoal.md: no em-dash"

echo ""
echo "=== golden inline role spec (Mode C, immediate-dispatch) ==="
IC="$FIX/inline-role-spec.txt"
[ -f "$IC" ]; chk "inline-role-spec.txt exists" $?
grep -qE '^NAME:' "$IC";              chk "Mode C: has NAME field" $?
grep -qE '^TOOLS \(advisory\):' "$IC"; chk "Mode C: has advisory TOOLS field" $?
grep -qE '^PREAMBLE:' "$IC";          chk "Mode C: has PREAMBLE field" $?
grep -qi 'specialist' "$IC";          chk "Mode C: preamble frames a specialist role" $?
head -1 "$IC" | grep -qF "$MARKER" && bad "Mode C: no DRAFT marker (it writes no file)" || ok "Mode C: no DRAFT marker (inline, not a file)"
LC_ALL=C grep -qF "$EMDASH" "$IC" && bad "inline-role-spec.txt: no em-dash" || ok "inline-role-spec.txt: no em-dash"

echo ""
echo "=== $PASS/$TOTAL passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
