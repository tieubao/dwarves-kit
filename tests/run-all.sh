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
skipped=0
for t in tests/test-*.sh; do
  [ -f "$t" ] || continue
  name="$(basename "$t" .sh)"
  [ -n "$ONLY" ] && case "$name" in *"$ONLY"*) : ;; *) continue ;; esac
  # A suite may declare external tooling it cannot run without:
  #   # requires: claude codex
  # Missing tooling is a SKIP with the reason, never a failure. Some suites exercise agent
  # CLIs that exist on an operator's machine and never on a CI runner; globbing everything
  # without this turns "cannot run here" into "broken", which is how a green suite gets
  # deleted for being noisy.
  reqs="$(sed -n 's/^# requires:[[:space:]]*//p' "$t" | head -1)"
  missing=""
  for r in $reqs; do command -v "$r" >/dev/null 2>&1 || missing="$missing $r"; done
  if [ -n "$missing" ]; then
    printf '%-46s skip (needs%s)\n' "$name" "$missing"
    skipped=$((skipped + 1))
    continue
  fi
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
    # Strip ANSI colour BEFORE matching. Suites print "\033[0;31mFAIL\033[0m", so the
    # character before FAIL is `m`, and a [^a-z] guard never matches it. The first version
    # of this grep silently matched the word "fail" inside PASSING assertions instead
    # ("## Failure modes", "fail-safe present") and showed no real failure at all.
    _clean="$(sed $'s/\033\[[0-9;]*m//g' /tmp/run-all-$$.log)"
    if printf '%s\n' "$_clean" | grep -qE '(^|[[:space:]])FAIL([[:space:]]|:|$)'; then
      printf '%s\n' "$_clean" | grep -E '(^|[[:space:]])FAIL([[:space:]]|:|$)' | head -20 | sed 's/^/      ! /'
    fi
    sed 's/^/      | /' /tmp/run-all-$$.log | tail -8
  fi
  rm -f /tmp/run-all-$$.log
done

echo ""
if [ -n "$failed" ]; then
  echo "run-all: FAILED ->$failed"
  echo "run-all: $count suites run${skipped:+, $skipped skipped for missing tooling}"
  exit 1
fi
echo "run-all: all $count suites passed${skipped:+, $skipped skipped for missing tooling}"
