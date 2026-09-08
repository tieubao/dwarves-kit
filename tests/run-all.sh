#!/usr/bin/env bash
# run-all.sh -- run every tests/test-*.sh and report each.
#
# CI used to list one step per suite by hand. That list drifted to 74 of 131 files, so 57
# suites never ran anywhere and four of them had been red on master for some time. A green
# CI was checking 57% of what the repo had. A glob cannot drift.
#
# Usage: bash tests/run-all.sh [--only <pattern>]
# Exit:  0 all green, 1 one or more failed (every failure is listed at the end).

set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_DIR" || exit 1

ONLY=""
[ "${1:-}" = "--only" ] && ONLY="${2:-}"

# Per-suite ceiling. One hung suite must not burn the whole CI job's budget.
TIMEOUT_SECS="${RUN_ALL_TIMEOUT_SECS:-300}"
_timeout() { if command -v timeout >/dev/null 2>&1; then timeout "$@"; else shift; "$@"; fi; }

failed=""
count=0
for t in tests/test-*.sh; do
  [ -f "$t" ] || continue
  name="$(basename "$t" .sh)"
  [ -n "$ONLY" ] && case "$name" in *"$ONLY"*) : ;; *) continue ;; esac
  count=$((count + 1))
  printf '%-46s ' "$name"
  if _timeout "$TIMEOUT_SECS" bash "$t" >/tmp/run-all-$$.log 2>&1; then
    echo "ok"
  else
    rc=$?
    [ "$rc" -eq 124 ] && echo "TIMEOUT (${TIMEOUT_SECS}s)" || echo "FAIL (rc=$rc)"
    failed="$failed $name"
    # Show the FAILING lines, then a short tail for context. A plain tail hid the real
    # assertion in a suite with 840 of them: the failure was 700 lines above the summary.
    if grep -qiE '(^|[^a-z])fail' /tmp/run-all-$$.log; then
      grep -iE '(^|[^a-z])fail' /tmp/run-all-$$.log | head -20 | sed 's/^/      ! /'
    fi
    sed 's/^/      | /' /tmp/run-all-$$.log | tail -8
  fi
  rm -f /tmp/run-all-$$.log
done

echo ""
if [ -n "$failed" ]; then
  echo "run-all: FAILED ->$failed"
  echo "run-all: $count suites run"
  exit 1
fi
echo "run-all: all $count suites passed"
