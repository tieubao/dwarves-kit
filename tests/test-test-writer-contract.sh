#!/usr/bin/env bash
# test-test-writer-contract.sh -- SPEC-203 TASK-007.
#
# Pins two contracts that make agents/test-writer.md + commands/test-write.md safe to
# dispatch autonomously:
#   AC1  agents/test-writer.md's `tools:` frontmatter grants no BARE Bash (only the scoped
#        test-runner Bash(...) patterns), matching agents/task-verifier.md's allowlist shape.
#   AC2  commands/test-write.md documents an explicit STOP branch when the resolved spec's
#        `## Test plan critique` is missing or its verdict is not SOLID -- it never
#        unconditionally proceeds to dispatch kit:test-writer.
#   AC3  NEGATIVE CONTROL: a fixture spec markdown carrying a `### Verdict: REVISE` critique
#        (mimicking the real shape test-write.md Step 2 reads) is run through a reimplementation
#        of that exact documented check (grep the `## Test plan critique` section, compare its
#        `### Verdict:` line to `SOLID`), proving the fixture DOES trip the stop condition --
#        not just that the word "stop" appears somewhere in the command file. A SOLID fixture
#        and a missing-critique fixture are run through the same extraction to confirm it
#        discriminates rather than always reporting "stop" (mirrors the fixture-vs-legit-copy
#        discrimination style in tests/test-command-emit-sweep.sh AC4).
#
# Run: bash tests/test-test-writer-contract.sh   (exit 0 = all AC green)

set -uo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AGENT="$KIT_DIR/agents/test-writer.md"
CMD="$KIT_DIR/commands/test-write.md"

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert() { TOTAL=$((TOTAL+1)); if [ "$2" -eq 0 ]; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1)); else echo -e "  ${RED}FAIL${NC} $1 ${3:-}"; FAIL=$((FAIL+1)); fi; }

echo "=== AC1: agents/test-writer.md grants no bare Bash, only scoped test-runner patterns ==="

[ -f "$AGENT" ]; assert "agents/test-writer.md exists" $?

# frontmatter = the block between the first and second '---' line
FRONTMATTER="$(awk '/^---$/{c++; next} c==1' "$AGENT")"

if { printf '%s\n' "$FRONTMATTER" 2>/dev/null || :; } | grep -qE '^[[:space:]]*-[[:space:]]*Bash[[:space:]]*$'; then
  RC=1
else
  RC=0
fi
assert "no bare '- Bash' tools entry (list form)" $RC

if { printf '%s\n' "$FRONTMATTER" 2>/dev/null || :; } | grep -qE ',[[:space:]]*Bash[[:space:]]*[,)]|\(Bash[[:space:]]*[,)]'; then
  RC=1
else
  RC=0
fi
assert "no bare ' Bash,' / ' Bash)' token in an inline tools list either" $RC

{ printf '%s\n' "$FRONTMATTER" 2>/dev/null || :; } | grep -qE '^[[:space:]]*-[[:space:]]*Bash\('
assert "at least one scoped Bash(...) pattern is present (it must be able to run tests)" $?

echo ""
echo "=== AC2: commands/test-write.md documents a real stop branch, not unconditional dispatch ==="

grep -qF '### Step 3: Stop on a bad verdict' "$CMD"
assert "test-write.md names an explicit 'Stop on a bad verdict' step" $?

grep -qF 'stop before dispatching anything' "$CMD"
assert "...and states it stops BEFORE dispatching anything" $?

grep -qF 'Never dispatch `kit:test-writer` against an unreviewed, non-SOLID, or stale matrix' "$CMD"
assert "...and states it never dispatches against an unreviewed/non-SOLID/stale matrix" $?

grep -qF 'even under `bypassPermissions`' "$CMD"
assert "...and the stop holds even under bypassPermissions (autonomous-caller contract)" $?

echo ""
echo "=== AC3: NEGATIVE CONTROL -- a REVISE-verdict fixture trips the documented stop check ==="

FIXTURE_DIR="$(mktemp -d -t test-writer-contract-fixture.XXXXXX)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

cat > "$FIXTURE_DIR/spec-revise.md" <<'EOF'
# Spec: fixture only
## Test plan
Date: 2026-07-30
| # | Case | Category | Covers (AC) | Expected | Proof |
|---|------|----------|--------------|----------|-------|
| 1 | x    | happy    | AC-1         | y        | TBD   |

## Test plan critique
Date: 2026-07-30
### Verdict: REVISE
Needs another boundary case.
EOF

cat > "$FIXTURE_DIR/spec-solid.md" <<'EOF'
# Spec: fixture only
## Test plan
Date: 2026-07-30
| # | Case | Category | Covers (AC) | Expected | Proof |
|---|------|----------|--------------|----------|-------|
| 1 | x    | happy    | AC-1         | y        | TBD   |

## Test plan critique
Date: 2026-07-30
### Verdict: SOLID
Matrix is sufficient.
EOF

cat > "$FIXTURE_DIR/spec-no-critique.md" <<'EOF'
# Spec: fixture only
## Test plan
Date: 2026-07-30
| # | Case | Category | Covers (AC) | Expected | Proof |
|---|------|----------|--------------|----------|-------|
| 1 | x    | happy    | AC-1         | y        | TBD   |
EOF

# Reimplementation of test-write.md Step 2 checks 1+3, verbatim to what the command documents:
#   check 1: "## Test plan critique" section present
#   check 3: the critique's "### Verdict:" line reads exactly "SOLID"
would_dispatch() {
  local spec="$1"
  grep -qF '## Test plan critique' "$spec" || { echo no; return; }
  local verdict
  verdict="$(awk '/^## Test plan critique/{f=1;next} f&&/^### Verdict:/{print;exit}' "$spec" | sed -E 's/^### Verdict:[[:space:]]*//')"
  [ "$verdict" = "SOLID" ] && echo yes || echo no
}

[ "$(would_dispatch "$FIXTURE_DIR/spec-revise.md")" = "no" ]
assert "REVISE-verdict fixture trips the stop check (would NOT dispatch)" $?

[ "$(would_dispatch "$FIXTURE_DIR/spec-solid.md")" = "yes" ]
assert "SOLID-verdict fixture passes the same check (would dispatch) -- proves it discriminates" $?

[ "$(would_dispatch "$FIXTURE_DIR/spec-no-critique.md")" = "no" ]
assert "missing-critique fixture also trips the stop check (check 1, same as a stale/absent verdict)" $?

echo ""
echo "=== Results ==="
echo -e "Passed: ${GREEN}${PASS}${NC} / ${TOTAL}"
if [ "$FAIL" -gt 0 ]; then
  echo -e "Failed: ${RED}${FAIL}${NC}"
  exit 1
else
  echo -e "${GREEN}All test-writer-contract tests passed.${NC}"
  exit 0
fi
