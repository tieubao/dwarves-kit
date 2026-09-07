#!/usr/bin/env bash
# test-stable-interface.sh -- the bin/ stable consumer entrypoints (SPEC-184).
#
# Proves the durable fix for the board-shim class of bug: a consumer references
# $KIT/bin/<name>, never a deep lib path, so an internal lib reorg cannot break it.
# Everything runs against a COPY of the kit under a temp dir; the real lib/ is untouched.
set -euo pipefail
KIT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
chk() { if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
KIT="$TMP/kit"; mkdir -p "$KIT"
cp -R "$KIT_DIR/bin" "$KIT/bin"
cp -R "$KIT_DIR/lib" "$KIT/lib"

# --- 1. every bin/ shim exists, is executable, and forwards ---
for c in board classify gate; do
  [ -x "$KIT/bin/$c" ]; chk "bin/$c is executable" $?
done
if bash "$KIT/bin/classify" lane classify "add a hook" | grep -qx full; then r=0; else r=1; fi
chk "bin/classify forwards to lane-classify (full)" "$r"
# bin/gate dispatches to the gate subsystem: `ledger rid` echoes the branch-derived rid.
if bash "$KIT/bin/gate" ledger rid 2>/dev/null | grep -q .; then r=0; else r=1; fi
chk "bin/gate forwards to gate-ledger (rid)" "$r"

# a consumer-shaped board call against a throwaway BACKLOG resolves through bin/board
mkdir -p "$TMP/consumer"
cat > "$TMP/consumer/BACKLOG.md" <<'EOF'
| ID | Item | Notes & source | Status |
|----|------|----------------|--------|
| ID-001 | demo row | seed | queued |
EOF
# consumer shim points at the STABLE bin/board (never lib/board/board.sh)
cat > "$TMP/consumer/board" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec bash "$KIT/bin/board" "\${@:-board}" --backlog-file "$TMP/consumer/BACKLOG.md"
EOF
chmod +x "$TMP/consumer/board"
if bash "$TMP/consumer/board" | grep -q "ID-001"; then r=0; else r=1; fi
chk "consumer drives the board through bin/board (stable)" "$r"

# --- 2. the adopt-injected CLAUDE.md block references bin/, not deep lib paths ---
block="$(sed -n '/claude_block()/,/^}/p' "$KIT_DIR/lib/adopt.sh")"
{ trap '' PIPE; printf '%s' "$block" 2>/dev/null || :; } | grep -q '/bin/classify lane classify' && r=0 || r=1
chk "adopt block references bin/classify (not lib/classify/*)" "$r"
{ trap '' PIPE; printf '%s' "$block" 2>/dev/null || :; } | grep -q '/bin/gate ledger' && r=0 || r=1
chk "adopt block references bin/gate (not lib/gate/*)" "$r"
{ trap '' PIPE; printf '%s' "$block" 2>/dev/null || :; } | grep -q 'lib/classify/lane-classify.sh\|lib/gate/gate-ledger.sh' && r=1 || r=0
chk "adopt block no longer reaches any deep lib path" "$r"

# --- 3. NEGATIVE CONTROL: internal lib rename does NOT break the stable consumer call ---
# 3a. baseline: stable consumer call is GREEN
bash "$TMP/consumer/board" >/dev/null 2>&1 && r=0 || r=1
chk "NC baseline: stable consumer call GREEN before rename" "$r"

# 3b. a SECOND consumer that reaches the DEEP lib path (the old fragile style) is ALSO green now
cat > "$TMP/consumer/board-deep" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec bash "$KIT/lib/board/board.sh" "\${@:-board}" --backlog-file "$TMP/consumer/BACKLOG.md"
EOF
chmod +x "$TMP/consumer/board-deep"
bash "$TMP/consumer/board-deep" >/dev/null 2>&1 && r=0 || r=1
chk "NC baseline: deep-path consumer GREEN before rename" "$r"

# 3c. simulate an internal lib reorg: rename the entry + update ONLY the kit-owned bin/board line
mv "$KIT/lib/board/board.sh" "$KIT/lib/board/board-core.sh"
# the ONE kit-internal edit that absorbs the reorg (the consumer file is byte-unchanged):
sed -i.bak 's#/lib/board/board.sh#/lib/board/board-core.sh#' "$KIT/bin/board" && rm -f "$KIT/bin/board.bak"

# 3d. the STABLE consumer call still resolves (GREEN) -- consumer file untouched
if bash "$TMP/consumer/board" 2>/dev/null | grep -q "ID-001"; then
  echo "ok   NC: stable bin/board consumer STILL resolves after internal rename"
else
  echo "FAIL NC: stable consumer broke on internal rename"; fail=1
fi

# 3e. the DEEP-path consumer BREAKS (RED) on the same rename -- this is the bug class the
#     stable interface fixes; the test bites because the deep reach is what actually breaks.
if bash "$TMP/consumer/board-deep" >/dev/null 2>&1; then
  echo "FAIL NC negative control did not bite: deep-path consumer survived the rename"; fail=1
else
  echo "ok   NC: deep-path consumer BREAKS on the rename (proves the reach is the fragile part)"
fi

# 3f. restore (kit copy is a throwaway, but keep the test hermetic)
mv "$KIT/lib/board/board-core.sh" "$KIT/lib/board/board.sh"

[ "$fail" -eq 0 ] && echo "PASS: stable consumer interface" || { echo "SOME TESTS FAILED"; exit 1; }
