#!/usr/bin/env bash
# test-prose-rag-adapter.sh -- SPEC-250 TASK-001: `bin/prose-rag` resolves the
# engine binary ($PROSE_RAG_BIN, then `prose-rag` on PATH) and states the three
# no-engine exits. See `### Interfaces` and `## Edge Cases` in
# docs/specs/SPEC-250-prose-rag-adapter.md.
#
# Run: bash tests/test-prose-rag-adapter.sh

set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHIM="$KIT_DIR/bin/prose-rag"

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
chk() {
  TOTAL=$((TOTAL+1))
  if [ "$2" -eq 0 ] 2>/dev/null; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1))
  else echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL+1)); fi
}
chk_has() { chk "$1" "$({ trap '' PIPE; printf '%s' "$2" 2>/dev/null || :; } | grep -qF -- "$3"; echo $?)"; }
chk_lacks() { chk "$1" "$({ trap '' PIPE; printf '%s' "$2" 2>/dev/null || :; } | grep -qF -- "$3" && echo 1 || echo 0)"; }

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/dk-prose-rag-adapter-test.XXXXXX")"
TMPD="$(cd "$TMPD" && pwd)"
trap 'chmod -R u+w "$TMPD" 2>/dev/null; rm -rf "$TMPD"' EXIT

# The stub echoes its argv and a canary env var, so a test can prove WHICH binary ran
# and that the arguments reached it intact. /bin/bash, not `env bash`: these cases run on a
# narrowed PATH, so the interpreter is named outright.
mkdir -p "$TMPD/envbin" "$TMPD/pathbin" "$TMPD/empty"
cat > "$TMPD/envbin/stub-engine" <<'STUB'
#!/bin/bash
echo "ENVSTUB argv:$*"
echo "ENVSTUB canary:${STUB_CANARY:-}"
STUB
cat > "$TMPD/pathbin/prose-rag" <<'STUB'
#!/bin/bash
echo "PATHSTUB argv:$*"
STUB
chmod +x "$TMPD/envbin/stub-engine" "$TMPD/pathbin/prose-rag"
: > "$TMPD/envbin/not-executable"
mkdir -p "$TMPD/envbin/a-directory"

# The shim resolves through builtins only, but `bash` itself must still be findable, so
# "nothing installed" is a PATH with the system dirs and no prose-rag on it.
SYSPATH="/usr/bin:/bin"
NOPATH="$TMPD/empty:$SYSPATH"

# ============================================================
echo "== PROSE_RAG_BIN wins: the stub runs, with the args and the env intact =="
# ============================================================
OUT1="$(PATH="$NOPATH" PROSE_RAG_BIN="$TMPD/envbin/stub-engine" STUB_CANARY=alive \
        bash "$SHIM" query "two words" --k 8 2>&1)"; RC1=$?
chk "env-set stub: exit 0" "$([ "$RC1" -eq 0 ]; echo $?)"
chk_has "env-set stub: the stub ran" "$OUT1" "ENVSTUB argv:"
chk_has "env-set stub: an argument with spaces arrived intact" "$OUT1" "argv:query two words --k 8"
chk_has "env-set stub: the environment reached the engine" "$OUT1" "ENVSTUB canary:alive"

# ============================================================
echo "== PROSE_RAG_BIN that is not a usable binary falls through to PATH =="
# ============================================================
OUT2="$(PATH="$TMPD/pathbin:$SYSPATH" PROSE_RAG_BIN="$TMPD/envbin/not-executable" \
        bash "$SHIM" query x 2>&1)"; RC2=$?
chk "non-executable env value: exit 0" "$([ "$RC2" -eq 0 ]; echo $?)"
chk_has "non-executable env value: PATH binary ran instead" "$OUT2" "PATHSTUB argv:query x"

# a directory is -x but not -f (edge case 1)
OUT3="$(PATH="$TMPD/pathbin:$SYSPATH" PROSE_RAG_BIN="$TMPD/envbin/a-directory" bash "$SHIM" query x 2>&1)"
chk_has "directory env value: PATH binary ran instead" "$OUT3" "PATHSTUB argv:query x"

# empty is treated as unset (edge case 2)
OUT4="$(PATH="$TMPD/pathbin:$SYSPATH" PROSE_RAG_BIN="" bash "$SHIM" query x 2>&1)"
chk_has "empty env value: PATH binary ran instead" "$OUT4" "PATHSTUB argv:query x"

# ============================================================
echo "== PATH resolution: no env set, the installed binary runs =="
# ============================================================
OUT5="$(PATH="$TMPD/pathbin:$SYSPATH" bash "$SHIM" index --full 2>&1)"; RC5=$?
chk "PATH stub: exit 0" "$([ "$RC5" -eq 0 ]; echo $?)"
chk_has "PATH stub: ran with its args" "$OUT5" "PATHSTUB argv:index --full"

# ============================================================
echo "== no engine anywhere: the three documented exits =="
# ============================================================
OUT6="$(PATH="$NOPATH" bash "$SHIM" hook 2>&1)"; RC6=$?
chk "hook without an engine: exit 0" "$([ "$RC6" -eq 0 ]; echo $?)"
chk "hook without an engine: no output (a recall hook never breaks a prompt)" \
    "$([ -z "$OUT6" ]; echo $?)"

OUT7="$(PATH="$NOPATH" PROSE_RAG_CORPUS="" bash "$SHIM" index 2>&1)"; RC7=$?
chk "index without a corpus: exit 0" "$([ "$RC7" -eq 0 ]; echo $?)"
chk_has "index without a corpus: says nothing was indexed" "$OUT7" "nothing indexed"

OUT8="$(PATH="$NOPATH" bash "$SHIM" query x 2>&1)"; RC8=$?
chk "query without an engine: exit 1" "$([ "$RC8" -eq 1 ]; echo $?)"
chk_has "query without an engine: the install hint names context-kit's crate" \
        "$OUT8" "cargo install --path <context-kit>/src/prose-rag"
chk_has "query without an engine: the hint offers the env seam" "$OUT8" "PROSE_RAG_BIN"

# an explicit --corpus means someone is driving interactively (edge case 4)
OUT9="$(PATH="$NOPATH" bash "$SHIM" index --corpus "$TMPD" 2>&1)"; RC9=$?
chk "index --corpus without an engine: exit 1" "$([ "$RC9" -eq 1 ]; echo $?)"
chk_has "index --corpus without an engine: the install hint" "$OUT9" "engine not installed"

# ============================================================
echo "== the shim is an adapter: it never reaches into lib/ and never builds =="
# ============================================================
LIBREFS="$(grep -c 'lib/prose-rag' "$SHIM" || true)"
chk "no reference to lib/prose-rag (grep -c is 0, got $LIBREFS)" "$([ "$LIBREFS" -eq 0 ]; echo $?)"
chk_lacks "no build command in the shim" "$(cat "$SHIM")" "cargo build"

# ============================================================
echo "== the shim on PATH as \`prose-rag\` resolves once, it does not exec itself forever =="
# ============================================================
# The CPU cap is the safety net: without the recursion marker this case spins in one
# process, and a 10s CPU limit fails the test instead of hanging CI.
mkdir -p "$TMPD/shimbin"
cp "$SHIM" "$TMPD/shimbin/prose-rag"
OUT10="$( (ulimit -t 10; PATH="$TMPD/shimbin:$SYSPATH" bash "$SHIM" query x) 2>&1 )"; RC10=$?
chk "shim on PATH: exit 1, no exec loop" "$([ "$RC10" -eq 1 ]; echo $?)"
chk_has "shim on PATH: falls through to the install hint" "$OUT10" "engine not installed"

# ============================================================
echo "== NEGATIVE CONTROL: the resolution assertions fail on a wrong binary =="
# ============================================================
# The env-set case above would pass vacuously if the shim ran ANY binary; point the env
# at the PATH stub and prove the argv marker actually distinguishes them.
OUTNC="$(PATH="$NOPATH" PROSE_RAG_BIN="$TMPD/pathbin/prose-rag" bash "$SHIM" query x 2>&1)"
chk_lacks "NEGATIVE CONTROL: the env stub's marker is absent when another binary runs" \
          "$OUTNC" "ENVSTUB"

echo ""
echo "== $TOTAL run, $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
