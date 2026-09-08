#!/usr/bin/env bash
# test-no-scattered-ids.sh -- the provenance rule, enforced where the repo is already clean.
#
# THE RULE (CONTRIBUTING.md "Where an ID may appear"): a spec, task, ADR or ticket id belongs
# in exactly one of three places. The record that IS it. A row keyed by it. One provenance
# footer at the bottom of a doc. Everywhere else, state the thing plainly.
#
# THIS LINT IS A RATCHET, NOT A FULL AUDIT. The repo carries roughly 2,600 scattered ids that
# predate the rule, so a lint over all of them would fail on day one and be disabled by
# Tuesday. It enforces the two zones that are already clean, so they cannot regrow, and gains
# a zone each time a cleanup batch lands. Widening it is the point; a zone list that never
# grows means the cleanup stopped.
#
#   Zone 1  no id inside a string the code PRINTS (hooks/, lib/, excluding nested tests/)
#   Zone 2  no instruction telling the model to EMIT an id into its own output (commands/)
#
# Run: bash tests/test-no-scattered-ids.sh

set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_DIR" || exit 1

PASS=0; FAIL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
ok()  { echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1)); }
no()  { echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL+1)); }

ID_RE='(SPEC|TASK|ADR|SG|DEC|ID)-[0-9]+'

# Documented exemptions, each a real one rather than a convenience:
#   SPEC-%s          a printf substitution; the VALUE is the reserved number a worker acts on
#   lib/*/tests/     test-progress echoes, not operator-facing
#   ID-[0-9]+"       a quoted data key the code reads (tool.toml board rows)
_exempt() {
  case "$1" in
    *'SPEC-%s'*|*'ID-%s'*)        return 0 ;;
    */tests/*)                    return 0 ;;
  esac
  return 1
}

echo "=== Zone 1: no id inside a printed string ==="
hits=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  _exempt "$line" && continue
  echo "     $line" >&2
  hits=$((hits+1))
done < <(grep -rnE "(echo|printf)[^|]*\"[^\"]*${ID_RE}|(echo|printf)[^|]*'[^']*${ID_RE}" \
           hooks lib --include='*.sh' --include='cc-improve' 2>/dev/null || true)
if [ "$hits" -eq 0 ]; then
  ok "no spec id reaches the operator's terminal through echo or printf"
else
  no "$hits printed string(s) carry a spec id; the reader cannot open a spec, so state the thing plainly"
fi

echo ""
echo "=== Zone 2: no instruction tells the model to emit an id ==="
# The shape that matters: a command telling the model to WRITE a bracketed id token into an
# artifact it produces. commands/next.md did exactly this, manufacturing the banned tag on
# every run, which is how a rule about prose became a rule the tooling itself broke.
emit=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  echo "     $line" >&2
  emit=$((emit+1))
done < <(grep -rnE '(append|write|add|emit).{0,40}`?(TASK|SPEC|ID)-\[' commands 2>/dev/null || true)
if [ "$emit" -eq 0 ]; then
  ok "no command instructs the model to write an id token into its own output"
else
  no "$emit instruction(s) emit an id; remove the token, keep the instruction"
fi

echo ""
echo "=== Ratchet: the zone list is meant to grow ==="
# A reminder with teeth: this asserts the rule is written down, so the lint cannot outlive
# its own documentation.
if grep -q "Where an ID may appear" CONTRIBUTING.md 2>/dev/null; then
  ok "CONTRIBUTING.md carries the rule this lint enforces"
else
  no "CONTRIBUTING.md has no 'Where an ID may appear' section; the lint would be enforcing an unwritten rule"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then echo "test-no-scattered-ids: $PASS passed, $FAIL FAILED" >&2; exit 1; fi
echo "test-no-scattered-ids: all $PASS passed"
