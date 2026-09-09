#!/usr/bin/env bash
# Negative control for the board-id mint history floor.
#
# Reverts the fix in sync_core.next_id (drops the history floor, leaving the
# pre-fix "read the checkout and nothing else" mint), shows the tests go RED,
# restores, shows them go GREEN. Run from anywhere; it edits only a temp copy
# path inside the worktree and always restores it.
set -euo pipefail
cd "$(dirname "$0")/../.."
CORE=lib/sync/sync_core.py
BACKUP="$(mktemp)"
cp "$CORE" "$BACKUP"
restore() { cp "$BACKUP" "$CORE"; }
trap restore EXIT

TESTS='test_next_id_skips_an_id_only_git_history_still_holds or test_next_id_sees_an_id_taken_on_another_ref or test_apply_board_mint_clears_ids_only_history_holds'

echo "=== 1. fix REVERTED (history floor removed): expect RED ==="
python3 - "$CORE" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
t = p.read_text()
old = "    hist = [history_max_id(path, prefix)] if path is not None else []\n"
assert old in t, "revert anchor not found; the fix moved"
p.write_text(t.replace(old, "    hist = []  # NEGATIVE CONTROL: pre-fix mint\n"))
PY
set +e
uv run --no-project --with pytest -- pytest lib/sync/tests/test_core.py -q -k "$TESTS"
red=$?
set -e
echo "reverted exit status: $red"
[ "$red" -ne 0 ] || { echo "NEGATIVE CONTROL FAILED: tests passed without the fix"; exit 1; }

echo
echo "=== 2. fix RESTORED: expect GREEN ==="
restore
uv run --no-project --with pytest -- pytest lib/sync/tests/test_core.py -q -k "$TESTS"
echo "restored exit status: $?"
echo
echo "negative control OK: RED without the fix, GREEN with it"
