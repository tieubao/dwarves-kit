#!/usr/bin/env bash
# report-lint.sh -- the `Needs you` admission test, mechanised.
#
# `commands/wrap.md` step 9 says an item belongs in `Needs you` only when the operator is
# the ONLY one who can do it. That rule was prose, and prose lost: a finished green PR kept
# getting parked there as "say go and I merge it", which costs a round trip and buys nothing.
#
# This reads a wrap report and fails when a `Needs you` item asks PERMISSION instead of
# naming a BLOCKER. It cannot judge whether an action is truly irreversible, so it does not
# try. It catches the one shape that is always wrong: an item whose own text offers to do
# the work itself.
#
# Usage: report-lint.sh [<file>]   (reads stdin when no file is given)
# Exit:  0 clean, 1 a finding (each printed as `line <n>: <reason>` on stderr), 2 usage.

set -uo pipefail

# Permission-seeking phrasing. An item carrying any of these is offering to act, which means
# the actor is the agent, not the operator, which means the item fails the admission test.
# Anchored to whole words so "approve" does not match "approved by legal" style prose... it
# does, deliberately: an item that needs someone's approval names the BLOCKER (who must
# approve), and that phrasing survives because the blocker is a person, not the operator's yes.
PERMISSION_RE='say (the word|go)|just say|let me know if|want me to|shall i |should i |can i go ahead|and i will (merge|apply|run|push|do)|and i can (merge|apply|run|push)|confirm and i|give me the (word|go)|ready when you are|approve\?|ok to (merge|proceed|apply|push)\?|proceed\?'

# Verbs the kit runs for itself. A `Needs you` item built around one of these is suspect,
# but not always wrong (a merge really can be blocked on a human), so this is a WARN.
SELF_RUNNABLE_RE='gh pr merge|gh workflow run|gh run (watch|rerun)|git (pull|push|merge)\b|git branch -[dD]|git worktree remove|chezmoi apply|npm (test|install)\b|pytest\b'

# Markers that name a real blocker. Their presence downgrades a SELF_RUNNABLE warn to clean:
# the item is not asking permission, it is reporting what stands in the way.
BLOCKER_RE='blocked (on|by)|waiting on|needs? (your|a) (password|credential|2fa|approval from|signature)|only you can|requires (a )?human|cannot (run|reach|access)|no (credential|access|token)|fails? with|permission denied'

_usage() { echo "usage: report-lint.sh [<file>]   (stdin when no file)" >&2; exit 2; }

src="${1:-}"
if [ -n "$src" ]; then
  [ -f "$src" ] || { echo "report-lint.sh: not a file: $src" >&2; exit 2; }
  case "$src" in -h|--help) _usage ;; esac
  input="$(cat "$src")"
else
  input="$(cat)"
fi

# Walk the report. `in_block` is on between the `Needs you` header and the next bold section
# header, so only that section is judged; a `What happened` sentence may say anything.
findings=0
warns=0
lineno=0
in_block=0
while IFS= read -r line; do
  lineno=$((lineno + 1))
  case "$line" in
    *'**Needs you:**'*) in_block=1; continue ;;
  esac
  [ "$in_block" = 1 ] || continue
  # Any other bold section header closes the block.
  case "$line" in
    '**'*'**'*) in_block=0; continue ;;
  esac
  # Only lettered items are judged; blank lines and the NOTHING sentinel are fine.
  case "$line" in
    [a-z].\ *) : ;;
    *) continue ;;
  esac

  lower="$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')"

  if printf '%s' "$lower" | grep -qE "$PERMISSION_RE"; then
    echo "line ${lineno}: asks permission instead of naming a blocker; run it and report it in What happened" >&2
    echo "  ${line}" >&2
    findings=$((findings + 1))
    continue
  fi

  if printf '%s' "$lower" | grep -qE "$SELF_RUNNABLE_RE" && ! printf '%s' "$lower" | grep -qE "$BLOCKER_RE"; then
    echo "warn line ${lineno}: names a command the kit can run, with no blocker stated" >&2
    echo "  ${line}" >&2
    warns=$((warns + 1))
  fi
done <<< "$input"

if [ "$findings" -gt 0 ]; then
  echo "report-lint: ${findings} finding(s), ${warns} warn(s)" >&2
  exit 1
fi
echo "report-lint: clean (${warns} warn(s))"
exit 0
