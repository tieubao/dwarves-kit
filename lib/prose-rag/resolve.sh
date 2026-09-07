#!/usr/bin/env bash
# resolve.sh -- the ONE prose-rag engine resolver (SPEC-251).
#
# WHY: `bin/prose-rag` and `lib/config/config.sh` both answered "where is the engine?"
# with their own `command -v prose-rag`. That lookup finds the wrapper install.sh writes
# at ~/.local/bin/prose-rag, which only execs the kit shim: the shim then reports the
# install hint (correct) while `config seams` reported `filled` (wrong). One function,
# two readers, two skip rules.
#
# Contract: `prose_rag_resolve [name]` prints ONE path and returns 0, or prints nothing
# and returns 1. Reads only PROSE_RAG_BIN and PATH. It never executes a candidate.
#
# Idempotent-source guard: sourcing twice is a no-op.
[ -n "${_KIT_PROSE_RAG_RESOLVE_SOURCED:-}" ] && return 0 2>/dev/null || true
_KIT_PROSE_RAG_RESOLVE_SOURCED=1

_PROSE_RAG_RESOLVE_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# _prose_rag_canonical <path> -- the physical path, symlinks followed.
# A bounded readlink loop, not `readlink -f`: BSD readlink has no -f, and a symlink cycle
# must end the walk instead of spinning.
_prose_rag_canonical() {
  local p="$1" hops=0 link dir
  while [ -L "$p" ] && [ "$hops" -lt 32 ]; do
    link="$(readlink "$p" 2>/dev/null)" || return 1
    dir="$(dirname "$p")"
    case "$link" in
      /*) p="$link" ;;
      *) p="$dir/$link" ;;
    esac
    hops=$((hops + 1))
  done
  dir="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s\n' "$dir" "$(basename "$p")"
}

# _prose_rag_is_kit_wrapper <path> -- does the file start with install.sh's shim marker?
# A subshell so `set +o pipefail` stays local: grep -q closes the pipe early, and under
# the caller's pipefail head's SIGPIPE status would mask the match. `grep -a` keeps a
# Mach-O or ELF engine binary from being treated as unreadable rather than unmarked.
_prose_rag_is_kit_wrapper() (
  set +o pipefail
  head -c 200 "$1" 2>/dev/null | grep -a -q 'dwarves-kit CLI shim'
)

# prose_rag_resolve [name] -- print the first real engine binary.
prose_rag_resolve() {
  local name="${1:-prose-rag}" bin shim rest entry cand real

  bin="${PROSE_RAG_BIN:-}"
  # [ -x ] alone is true for a searchable directory; a binary must be a regular file too.
  if [ -n "$bin" ] && [ -f "$bin" ] && [ -x "$bin" ]; then
    printf '%s\n' "$bin"
    return 0
  fi

  shim="$(_prose_rag_canonical "$_PROSE_RAG_RESOLVE_SELF/../../bin/prose-rag" 2>/dev/null || true)"

  rest="${PATH:-}"
  while [ -n "$rest" ]; do
    case "$rest" in
      *:*) entry="${rest%%:*}"; rest="${rest#*:}" ;;
      *) entry="$rest"; rest="" ;;
    esac
    # An empty PATH entry means cwd to the shell; here it is skipped, never searched.
    [ -n "$entry" ] || continue
    cand="$entry/$name"
    [ -f "$cand" ] && [ -x "$cand" ] || continue
    _prose_rag_is_kit_wrapper "$cand" && continue
    if [ -n "$shim" ]; then
      real="$(_prose_rag_canonical "$cand" 2>/dev/null || true)"
      [ "$real" = "$shim" ] && continue
    fi
    printf '%s\n' "$cand"
    return 0
  done
  return 1
}
