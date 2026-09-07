#!/bin/bash
# Negative control: a payload larger than the pipe buffer makes the race
# deterministic. Old form dies under pipefail in both signal regimes; the
# guarded form returns grep's status.
set -uo pipefail
big="match-me$(printf '%*s' 300000 '' | tr ' ' 'x')"
printf '%s\n' "$big" "$big" "$big" | grep -q match-me; old_default=$?
( trap '' PIPE; printf '%s\n' "$big" "$big" "$big" | grep -q match-me ); old_ignored=$?
{ trap '' PIPE; printf '%s\n' "$big" "$big" "$big" 2>/dev/null || :; } | grep -q match-me; new_default=$?
( trap '' PIPE; { trap '' PIPE; printf '%s\n' "$big" "$big" "$big" 2>/dev/null || :; } | grep -q match-me ); new_ignored=$?
{ trap '' PIPE; printf '%s\n' "$big" 2>/dev/null || :; } | grep -q nomatch; new_miss=$?
echo "old form, SIGPIPE default: exit=$old_default (RED expected)"
echo "old form, SIGPIPE ignored (CI): exit=$old_ignored (RED expected)"
echo "guarded form, SIGPIPE default: exit=$new_default (0 expected)"
echo "guarded form, SIGPIPE ignored (CI): exit=$new_ignored (0 expected)"
echo "guarded form, no match: exit=$new_miss (1 expected)"
[ $old_default -ne 0 ] && [ $old_ignored -ne 0 ] && [ $new_default -eq 0 ] && [ $new_ignored -eq 0 ] && [ $new_miss -eq 1 ] && echo "CONTROL: PASS" || echo "CONTROL: FAIL"
