#!/usr/bin/env bash
# test-spec-index.sh -- the read-only SPEC registry view (lib/spec/spec-index.sh).
#
# spec-index is purely a "list every SPEC across all */docs/specs/ namespaces,
# grouped by namespace" READ view. Numbering stays per-namespace local; this lib
# is NOT wired into spec-next / goal-drafts / precedent. This pins that the view
# lists a central spec AND a co-located spec under the correct namespace labels.
#
# Run: bash tests/test-spec-index.sh
# Exit 0 = all pass. Exit 1 = failures.
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
PASS=0; FAIL=0; TOTAL=0

ok()  { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}PASS${NC} $1"; }
bad() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo -e "  ${RED}FAIL${NC} $1"; }
expect()  { if { printf '%s' "$3" 2>/dev/null || :; } | grep -q "$2"; then ok "$1"; else bad "$1 (missing '$2' in: $3)"; fi; }
refute()  { if { printf '%s' "$3" 2>/dev/null || :; } | grep -q "$2"; then bad "$1 (unexpected '$2')"; else ok "$1"; fi; }

SPEC_INDEX="$KIT_DIR/lib/spec/spec-index.sh"

mk_repo() {
  local r; r="$(mktemp -d "${TMPDIR:-/tmp}/kit-spec-index.XXXXXX")"
  git -C "$r" init -q
  git -C "$r" config user.email t@t.t
  git -C "$r" config user.name t
  printf '%s\n' "$r"
}

write_spec() {  # <repo> <relpath> <heading> <status>
  local full="$1/$2"
  mkdir -p "$(dirname "$full")"
  {
    printf '# Spec: %s\n' "$3"
    printf 'Status: %s\n\n' "$4"
    printf '## Problem\n\nbody\n'
  } > "$full"
}

# ============================================================
echo "=== spec-index: central + co-located, grouped by namespace ==="
# ============================================================
REPO="$(mk_repo)"
trap 'rm -rf "$REPO" "${REPO2:-}"' EXIT
# Two namespaces, each with its OWN local SPEC-001 (per-namespace numbering).
write_spec "$REPO" "docs/specs/SPEC-001-foo.md"           "foo central" "DRAFT"
write_spec "$REPO" "tools/bar/docs/specs/SPEC-001-bar.md" "bar tool"    "SHIPPED"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "specs"

INDEX="$(cd "$REPO" && bash "$SPEC_INDEX" list)"

expect "spec-index: central namespace header present" "^central docs/specs$"        "$INDEX"
expect "spec-index: co-located namespace header present" "^tools/bar$"              "$INDEX"
expect "spec-index: central SPEC-001 row + title"     "SPEC-001 | foo central"      "$INDEX"
expect "spec-index: co-located SPEC-001 row + title"  "SPEC-001 | bar tool"         "$INDEX"
expect "spec-index: co-located row carries its SHIPPED status" "bar tool | SHIPPED" "$INDEX"
# both local SPEC-001s coexist (per-namespace numbering) -> two SPEC-001 rows total
ROWS="$(printf '%s\n' "$INDEX" | grep -c 'SPEC-001 ')"
expect "spec-index: both local SPEC-001s listed (2 rows)" "^2$" "$ROWS"

# ============================================================
echo ""
echo "=== spec-index: central-only repo ==="
# ============================================================
REPO2="$(mk_repo)"
write_spec "$REPO2" "docs/specs/SPEC-001-foo.md" "foo central only" "SHIPPED"
git -C "$REPO2" add -A; git -C "$REPO2" commit -qm "central spec"

INDEX2="$(cd "$REPO2" && bash "$SPEC_INDEX" list)"
expect "spec-index: central-only lists SPEC-001"         "SPEC-001 | foo central only" "$INDEX2"
expect "spec-index: central-only has the central header" "^central docs/specs$"        "$INDEX2"
refute "spec-index: central-only has no co-located namespace" "tools/"                 "$INDEX2"

echo ""
echo "=== Results ==="
echo -e "Passed: ${GREEN}$PASS${NC} / $TOTAL"
if [ "$FAIL" -gt 0 ]; then echo -e "${RED}$FAIL assertions failed.${NC}"; exit 1; fi
echo -e "${GREEN}spec-index green.${NC}"
