#!/bin/bash
# Negative control: a payload larger than the pipe buffer, spread across
# multiple lines so grep -q can match on the first line and exit while the
# writer is still blocked on the remaining ones, makes the race deterministic.
# Same mechanism as docs/verification/test-grep-pipefail-negctl.sh (#510),
# ported to `echo` producers instead of `printf`. A single giant line
# (no embedded newline) does not reproduce it here: this darwin box's pipe
# absorbs a solo 200-500KB write before grep even starts reading, so the
# probe needs the same multi-line shape as the printf original.
set -uo pipefail
big=$(head -c 300000 /dev/zero | tr '\0' a)
block="$big"$'\n'"$big"$'\n'"$big"
echo "$block" | grep -q a; old_default=$?
( trap '' PIPE; echo "$block" | grep -q a ); old_ignored=$?
{ trap '' PIPE; echo "$block" 2>/dev/null || :; } | grep -q a; new_default=$?
( trap '' PIPE; { trap '' PIPE; echo "$block" 2>/dev/null || :; } | grep -q a ); new_ignored=$?
{ trap '' PIPE; echo "$big" 2>/dev/null || :; } | grep -q nomatch; new_miss=$?
echo "old form, SIGPIPE default: exit=$old_default (RED expected)"
echo "old form, SIGPIPE ignored (CI): exit=$old_ignored (RED expected)"
echo "guarded form, SIGPIPE default: exit=$new_default (0 expected)"
echo "guarded form, SIGPIPE ignored (CI): exit=$new_ignored (0 expected)"
echo "guarded form, no match: exit=$new_miss (1 expected)"
[ $old_default -ne 0 ] && [ $old_ignored -ne 0 ] && [ $new_default -eq 0 ] && [ $new_ignored -eq 0 ] && [ $new_miss -eq 1 ] && echo "CONTROL: PASS" || echo "CONTROL: FAIL"
