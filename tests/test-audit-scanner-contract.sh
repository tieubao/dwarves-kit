#!/usr/bin/env bash
# test-audit-scanner-contract.sh -- SPEC-220.
#
# Pins the contracts that make agents/audit-scanner.md safe to dispatch in UNATTENDED
# audit-loop cadence runs:
#   AC1  the `tools:` frontmatter roster is READ-ONLY: no bare Bash, no Write/Edit/
#        NotebookEdit; Read/Grep/Glob present; every scoped Bash(...) pattern is from a
#        read-only verb allowlist. The roster IS the enforcement (the agent physically
#        cannot fix what it audits), so this shape is load-bearing, not stylistic.
#   AC2  dispatched-by wiring pinned BOTH sides: skills/doc-drift/SKILL.md and
#        skills/topology-drift/SKILL.md each dispatch `kit:audit-scanner` as the preferred
#        Tier-2 scanner (general-purpose named as the fallback), and the agent body names
#        both dispatching instances.
#   AC3  the audit-loop grammar rules are pinned in the agent body: the verdict grammar,
#        the no-evidence-downgrades-to-UNSURE rule, the UNTESTABLE-never-REMOVE rule, and
#        the never-fixes rule.
#   NC   NEGATIVE CONTROL: a fixture agent with a write-capable roster (bare `- Bash` +
#        `- Write`) run through the SAME AC1 extraction trips every roster check, proving
#        the check discriminates rather than always passing (mirrors the fixture style in
#        tests/test-test-writer-contract.sh AC3).
#
# Run: bash tests/test-audit-scanner-contract.sh   (exit 0 = all AC green)

set -uo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AGENT="${AUDIT_SCANNER_AGENT_FILE:-$KIT_DIR/agents/audit-scanner.md}"
DOC_DRIFT="$KIT_DIR/skills/doc-drift/SKILL.md"
TOPOLOGY_DRIFT="$KIT_DIR/skills/topology-drift/SKILL.md"

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert() { TOTAL=$((TOTAL+1)); if [ "$2" -eq 0 ]; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1)); else echo -e "  ${RED}FAIL${NC} $1 ${3:-}"; FAIL=$((FAIL+1)); fi; }

# Reusable AC1 roster audit: prints nothing and returns 0 when the file's frontmatter
# tools roster is read-only per the rules above; returns 1 with reasons otherwise.
roster_is_read_only() {
  local file="$1" fm rc=0
  fm="$(awk '/^---$/{c++; next} c==1' "$file")"
  # no bare Bash
  { trap '' PIPE; printf '%s\n' "$fm" 2>/dev/null || :; } | grep -qE '^[[:space:]]*-[[:space:]]*Bash[[:space:]]*$' && { echo "bare Bash"; rc=1; }
  # no write-capable tools
  { trap '' PIPE; printf '%s\n' "$fm" 2>/dev/null || :; } | grep -qE '^[[:space:]]*-[[:space:]]*(Write|Edit|NotebookEdit)[[:space:]]*$' && { echo "write tool"; rc=1; }
  # Read/Grep/Glob present
  for t in Read Grep Glob; do
    { trap '' PIPE; printf '%s\n' "$fm" 2>/dev/null || :; } | grep -qE "^[[:space:]]*-[[:space:]]*$t[[:space:]]*\$" || { echo "missing $t"; rc=1; }
  done
  # every Bash(...) pattern from the read-only verb allowlist
  local pats
  pats="$(printf '%s\n' "$fm" | sed -nE 's/^[[:space:]]*-[[:space:]]*Bash\(([^)]*)\).*/\1/p')"
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    case "$p" in
      "git diff "*|"git log "*|"ls "*|"find "*|"wc "*|"cat "*|"head "*) ;;
      *) echo "non-read-only Bash pattern: $p"; rc=1;;
    esac
  done <<< "$pats"
  return $rc
}

echo "=== AC1: agents/audit-scanner.md tools roster is read-only ==="

[ -f "$AGENT" ]; assert "agents/audit-scanner.md exists" $?

REASONS="$(roster_is_read_only "$AGENT")"; RC=$?
assert "roster is read-only (no bare Bash / Write / Edit; Read+Grep+Glob; Bash verbs allowlisted)" $RC "($REASONS)"

echo ""
echo "=== AC2: dispatched-by wiring pinned both sides ==="

grep -q 'kit:audit-scanner' "$DOC_DRIFT"
assert "doc-drift SKILL.md dispatches kit:audit-scanner" $?
grep -q 'kit:audit-scanner' "$TOPOLOGY_DRIFT"
assert "topology-drift SKILL.md dispatches kit:audit-scanner" $?
grep -qi 'general-purpose' "$DOC_DRIFT"
assert "doc-drift names the general-purpose fallback" $?
grep -qi 'general-purpose' "$TOPOLOGY_DRIFT"
assert "topology-drift names the general-purpose fallback" $?
grep -q 'doc-drift' "$AGENT"
assert "agent body names doc-drift as a dispatching instance" $?
grep -q 'topology-drift' "$AGENT"
assert "agent body names topology-drift as a dispatching instance" $?

echo ""
echo "=== AC3: audit-loop grammar rules pinned in the agent body ==="

grep -qE 'OK.*/.*FIX.*/.*REMOVE.*/.*UNSURE.*/.*DANGER|`OK` / `FIX' "$AGENT"
assert "verdict grammar (OK/FIX/REMOVE/UNSURE/DANGER) present" $?
grep -q 'no checkable evidence downgrades to UNSURE' "$AGENT"
assert "no-evidence downgrade rule present" $?
grep -q 'UNTESTABLE, never REMOVE' "$AGENT"
assert "UNTESTABLE-never-REMOVE rule present" $?
grep -q 'Never fix' "$AGENT"
assert "never-fixes rule present" $?
grep -q 'docs/patterns/audit-loop.md' "$AGENT"
assert "agent cites the audit-loop pattern doc" $?

echo ""
echo "=== NC: write-capable fixture roster trips the AC1 check ==="

FIXTURE_DIR="$(mktemp -d -t audit-scanner-contract.XXXXXX)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

cat > "$FIXTURE_DIR/agent-writey.md" <<'EOF'
---
name: writey-fixture
description: fixture only
tools:
  - Read
  - Grep
  - Glob
  - Write
  - Bash
model: sonnet
---
Fixture body.
EOF

if roster_is_read_only "$FIXTURE_DIR/agent-writey.md" >/dev/null; then RC=1; else RC=0; fi
assert "write-capable fixture FAILS the roster check (discriminates)" $RC

cat > "$FIXTURE_DIR/agent-clean.md" <<'EOF'
---
name: clean-fixture
description: fixture only
tools:
  - Read
  - Grep
  - Glob
  - Bash(git diff *)
model: sonnet
---
Fixture body.
EOF

roster_is_read_only "$FIXTURE_DIR/agent-clean.md" >/dev/null
assert "clean read-only fixture PASSES the same check (not always-fail)" $?

echo ""
echo "=== Results ==="
echo -e "Passed: ${GREEN}${PASS}${NC} / ${TOTAL}"
if [ "$FAIL" -gt 0 ]; then
  echo -e "Failed: ${RED}${FAIL}${NC}"
  exit 1
else
  echo -e "${GREEN}All audit-scanner-contract tests passed.${NC}"
  exit 0
fi
