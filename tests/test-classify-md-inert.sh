#!/usr/bin/env bash
# test-classify-md-inert.sh
# Pins the classify() fix: a markdown/txt-only diff is INERT regardless of the commit subject
# (a docs-only "migrate" commit is not stateful), while real stateful/behavioral signals are
# unchanged. Negative control: the pre-fix lib (read from the merge-base) classifies the same
# md-only "migrate" diff as stateful.
set -uo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$KIT/lib/gate/proof-ledger.sh"
fails=0
pass(){ echo "PASS $*"; }
fail(){ echo "FAIL $*"; fails=$((fails+1)); }

# build a fixture: $1 dir, $2 = "md" | "code" | "codemd" content, $3 = commit subject
build() {
  local d="$1" kind="$2" subj="$3"
  rm -rf "$d"; mkdir -p "$d/docs" "$d/lib"
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  echo base > "$d/docs/x.md"; git -C "$d" add -A; git -C "$d" commit -qm base
  git -C "$d" checkout -qb feat/x
  case "$kind" in
    md)     echo more >> "$d/docs/x.md" ;;
    code)   echo 'echo hi' >> "$d/lib/y.sh" ;;
    codemd) echo more >> "$d/docs/x.md"; echo 'echo hi' >> "$d/lib/y.sh" ;;
  esac
  git -C "$d" add -A; git -C "$d" commit -qm "$subj"
}
cls() { bash "$1" classify "$2" "$(git -C "$2" rev-parse main)"; }

# AC1: md-only + "migrate" subject -> inert (the fix)
F=/tmp/cls-md; build "$F" md "migrate eval + tool dialects"
[ "$(cls "$LIB" "$F")" = inert ] && pass "md-only 'migrate' diff -> inert" || fail "md-only 'migrate' should be inert, got $(cls "$LIB" "$F")"

# AC3a: code + "migrate" subject -> stateful (real signal preserved)
F=/tmp/cls-codemig; build "$F" code "migrate the database schema"
[ "$(cls "$LIB" "$F")" = stateful ] && pass "code+'migrate' diff -> stateful (preserved)" || fail "code+'migrate' should be stateful, got $(cls "$LIB" "$F")"

# AC3b: code-only, no keywords -> behavioral
F=/tmp/cls-code; build "$F" code "tweak the helper"
[ "$(cls "$LIB" "$F")" = behavioral ] && pass "code-only diff -> behavioral" || fail "code-only should be behavioral, got $(cls "$LIB" "$F")"

# AC2 negative control: a lib with the inert-FIRST block STRIPPED classifies md-only 'migrate'
# as stateful (the bug). History-independent: construct the pre-fix lib from the CURRENT one
# (awk the inert-FIRST block out), so this stays valid even after the fix is merged to master.
F=/tmp/cls-md   # reuse the md-only 'migrate' fixture
# The stripped copy MUST live beside the real lib: proof-ledger.sh resolves its siblings
# (lib/telemetry/kit-log-dir.sh) relative to its own path, so a copy in /tmp aborts with
# FATAL before it can classify anything. That dependency arrived after this test was
# written, which is why the control silently stopped reproducing the bug.
OLD="$(dirname "$LIB")/.cls-oldlib.tmp.sh"
trap 'rm -f "$OLD"' EXIT
awk '/# inert FIRST/{s=1} /^  subjects=/{s=0} !s' "$LIB" > "$OLD"
if [ -s "$OLD" ] && grep -q 'stateful: deploy' "$OLD" && ! grep -q 'inert FIRST' "$OLD"; then
  [ "$(cls "$OLD" "$F")" = stateful ] && pass "inert-FIRST-stripped lib classifies md-only 'migrate' as stateful (the bug; fix is load-bearing)" || fail "stripped lib should reproduce the stateful bug, got $(cls "$OLD" "$F")"
else
  echo "[NO EXECUTABLE CHECK: could not strip the inert-FIRST block]"; fails=$((fails+1))
fi

echo "---"
[ "$fails" -eq 0 ] && { echo "ALL PASS (4/4)"; exit 0; } || { echo "FAILS: $fails"; exit 1; }
