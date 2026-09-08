#!/usr/bin/env bash
# skill-curator shared helpers: paths, config, logging, lock, sentinel, secret scan, slug.
# Sourced by hooks/, lib/reviewer-run.sh, bin/cc-improve. Stdlib bash + jq only. No secrets.
#
# Every path is env-overridable (SKILL_CURATOR_* wins over config.toml wins over the default) so tests
# can redirect all writes into a temp dir. The reviewer/curator MODEL never writes; only the
# trusted code that sources this file writes, and only to the fixed paths below.

# pipefail only (NOT -e / -u): a hook must never abort a session on an unset var or a non-zero
# step. Every variable below is referenced with ${VAR:-} defensively.
set -o pipefail

# Tool root = parent of this lib/ dir. SKILL_CURATOR_ROOT is consumed by sourcing scripts (reviewer-run.sh
# reads $SKILL_CURATOR_ROOT/prompts/...), so it is "unused" only within this file.
SKILL_CURATOR_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034
SKILL_CURATOR_ROOT="$(cd "$SKILL_CURATOR_LIB/.." && pwd)"

_expand() { case "$1" in "~"/*) printf '%s/%s' "$HOME" "${1#\~/}";; *) printf '%s' "$1";; esac; }

# SPEC-200 I2/I5: the kit speaks one language. These knobs were `CC_SI_*` (a host-agent
# prefix the naming invariant bans); the canonical family is now `SKILL_CURATOR_*`, matching
# STATS_* / QUEUE_* / SESSION_*. An operator's existing CC_SI_* export still works for one
# release and says so once, on stderr. Canonical always wins.
for _v in STATE_DIR PROPOSALS_DIR SKILLS_DIR CONFIG SETTINGS MEMORY_LEDGER CURATOR_CMD \
          REVIEWER_CMD SIGNAL_MARKERS; do
  _new="SKILL_CURATOR_$_v"; _old="CC_SI_$_v"
  if [ -z "${!_new:-}" ] && [ -n "${!_old:-}" ]; then
    printf 'skill-curator: %s is deprecated, use %s\n' "$_old" "$_new" >&2
    export "$_new=${!_old}"
  fi
done
unset _v _new _old

SKILL_CURATOR_STATE_DIR="$(_expand "${SKILL_CURATOR_STATE_DIR:-$HOME/.claude/skill-curator}")"
SKILL_CURATOR_PROPOSALS_DIR="$(_expand "${SKILL_CURATOR_PROPOSALS_DIR:-$HOME/.claude/skill-proposals}")"
SKILL_CURATOR_SKILLS_DIR="$(_expand "${SKILL_CURATOR_SKILLS_DIR:-$HOME/.claude/skills}")"
SKILL_CURATOR_LEDGER="$SKILL_CURATOR_STATE_DIR/ledger.jsonl"
SKILL_CURATOR_LOCK="$SKILL_CURATOR_STATE_DIR/state/reviewer.lock"
SKILL_CURATOR_LOG="$SKILL_CURATOR_STATE_DIR/skill-curator.log"
SKILL_CURATOR_CONFIG="$(_expand "${SKILL_CURATOR_CONFIG:-$SKILL_CURATOR_STATE_DIR/config.toml}")"

# cfg KEY DEFAULT : env SKILL_CURATOR_<KEY> wins, then a `key = value` line in config.toml, then DEFAULT.
#
# The deprecation alias lives HERE, in the resolver, not in a hand-list beside it. The first cut
# aliased only the 9 direct-path vars; cfg() DERIVES its name from the key, so the 8 cfg-only
# keys (enabled, model, curator_model, max_turns, transcript_k, auto_promote, signal_gate,
# signal_markers) silently lost their alias. `CC_SI_ENABLED=false` -- an operator who had turned
# the curator OFF -- resolved back to `true` and quietly re-enabled it, with no warning. A
# hand-list next to a deriving resolver is a bug waiting for the next key (review finding).
cfg() {
  local key="$1" def="${2:-}" envvar legacy val
  envvar="SKILL_CURATOR_$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"
  legacy="CC_SI_$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"
  if [ -n "${!envvar:-}" ]; then printf '%s' "${!envvar}"; return; fi
  if [ -n "${!legacy:-}" ]; then
    printf 'skill-curator: %s is deprecated, use %s\n' "$legacy" "$envvar" >&2
    printf '%s' "${!legacy}"; return
  fi
  if [ -f "$SKILL_CURATOR_CONFIG" ]; then
    val="$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$SKILL_CURATOR_CONFIG" | head -1 \
            | sed 's/[[:space:]]*#.*$//; s/^"//; s/"$//; s/^'\''//; s/'\''$//')"
    if [ -n "$val" ]; then printf '%s' "$val"; return; fi
  fi
  printf '%s' "$def"
}

si_log() {  # timestamped line to the tool log; never fatal
  local ts; ts="$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || echo '?')"
  mkdir -p "$SKILL_CURATOR_STATE_DIR" 2>/dev/null || true
  printf '%s skill-curator: %s\n' "$ts" "$*" >> "$SKILL_CURATOR_LOG" 2>/dev/null || true
}

ledger_append() {  # ledger_append <json-object-string>; one JSONL row, never fatal
  mkdir -p "$SKILL_CURATOR_STATE_DIR" 2>/dev/null || true
  printf '%s\n' "$1" >> "$SKILL_CURATOR_LEDGER" 2>/dev/null || true
}

# safe_slug <s>: lowercase kebab, strip anything that could escape a directory. Never empty.
safe_slug() {
  local s; s="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' \
                 | sed 's/-\{2,\}/-/g; s/^-//; s/-$//')"
  s="${s:0:64}"
  [ -n "$s" ] && printf '%s' "$s" || printf 'untitled-draft'
}

# contains_secret <text>: 0 (true) if a high-precision secret pattern is present. Used by the
# trusted wrapper to DROP a draft rather than stage a printed credential (defense in depth on top
# of the reviewer-prompt ban + the promote-time scan).
contains_secret() {
  printf '%s' "${1:-}" | grep -Eq \
    -e 'sk-ant-[A-Za-z0-9_-]{8,}' \
    -e 'sk-[A-Za-z0-9]{20,}' \
    -e 'AKIA[0-9A-Z]{16}' \
    -e 'ghp_[A-Za-z0-9]{30,}' \
    -e 'github_pat_[A-Za-z0-9_]{30,}' \
    -e 'xox[bpras]-[A-Za-z0-9-]{10,}' \
    -e 'AIza[0-9A-Za-z_-]{35}' \
    -e 'eyJ[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{8,}' \
    -e '-----BEGIN [A-Z ]*PRIVATE KEY-----'
}

# reviewing_sentinel_set: true if we are already inside a reviewer (reentrancy guard).
reviewing_sentinel_set() { [ -n "${CLAUDE_REVIEWING:-}" ]; }

# Single-flight lock. macOS has no flock(1), so use an atomic mkdir lock (portable to macOS+Linux).
# si_acquire_lock: 0 if acquired (caller must si_release_lock on exit), 1 if a LIVE holder has it.
si_acquire_lock() {
  local d="${SKILL_CURATOR_LOCK}.d"
  mkdir -p "$(dirname "$d")" 2>/dev/null || true
  if mkdir "$d" 2>/dev/null; then printf '%s' "$$" > "$d/pid" 2>/dev/null || true; return 0; fi
  local hp; hp="$(cat "$d/pid" 2>/dev/null || true)"          # steal a lock whose holder died
  if [ -n "$hp" ] && ! kill -0 "$hp" 2>/dev/null; then
    rm -f "$d/pid" 2>/dev/null || true; rmdir "$d" 2>/dev/null || true
    if mkdir "$d" 2>/dev/null; then printf '%s' "$$" > "$d/pid" 2>/dev/null || true; return 0; fi
  fi
  return 1
}
si_release_lock() { local d="${SKILL_CURATOR_LOCK}.d"; rm -f "$d/pid" 2>/dev/null || true; rmdir "$d" 2>/dev/null || true; }
