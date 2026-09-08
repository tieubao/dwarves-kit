#!/usr/bin/env bash
# adopt.sh -- idempotently inject the dwarves-kit operate-contract into a target repo.
#
# Adoption = the per-repo trigger that makes an agent classify + pick a lane and that makes the
# ship-gate engage. It injects the CONTRACT + a proof marker + pointers; it never copies the
# engine (lib/, the full WORKFLOW matrix) -- the gate machinery reads those from the install
# ($KIT_ROOT). Non-destructive: AGENTS.md + the proof marker are never overwritten.
#
# The CLAUDE.md loader uses an `@AGENTS.md` import (Claude Code includes the file, not just a
# "go read it" pointer; absorbed from repository-harness's --claude shim).
#
# Usage: adopt.sh [--check | --dry-run | --refresh] [--with <a,b,c>] <target-dir>
#   --check   : report status only (exit 0 adopted / 1 not), write nothing.
#   --dry-run : print what would change, write nothing.
#   --refresh : re-sync the kit-managed pieces (WORKFLOW pointer + the CLAUDE.md loader block)
#               to their current form. AGENTS.md + the proof marker are still never overwritten.
#   --with <a,b,c> : only meaningful the first time (seeding a fresh <target>/.kit.toml): the
#               named modules start `true` in the seeded [modules] section instead of the
#               kit-root defaults. Ignored (with a note) once <target>/.kit.toml exists -- a
#               project's own config is never overwritten by re-running adopt (SPEC-192).
#
# Per-project override close-out (SPEC-192, goal 06): the resolver (lib/config/kit-config.sh,
# goal 01) already merges <target>/.kit.toml over the kit-root default. This closes the loop:
# adopt seeds a starter <target>/.kit.toml (opt-in; never overwritten after creation) and, on
# EVERY run (fresh or --refresh), wires the currently-enabled HOOK-bearing modules (board,
# session, advisor, cosmetic) into <target>/.claude/settings.json via a jq MERGE (never a
# wholesale file rewrite -- other entries in that file are preserved). Command/skill modules
# (queue, stats, quiz_gate, weekend_batch, bridge) need no settings.json entry, so they are
# recorded in .kit.toml but never touch settings.json. This is "wired at adopt time", not read
# per hook fire: re-running adopt.sh (an explicit, deliberate action) recomputes the project's
# wired set from its CURRENT .kit.toml; nothing reads .kit.toml at hook-fire time.
set -uo pipefail

KIT_ROOT="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/dwarves-kit}"
# KIT_ROOT is THIS machine's absolute install path. Never render it into a consumer repo:
# those files get committed, so an expanded /Users/<operator> leaks a personal home to every
# reader of that repo. KIT_REF is the portable form the consumer's own shell expands, and it
# resolves for every install mode because install.sh keeps ~/.claude/dwarves-kit pointing at
# the install (in place, or via the per-dir compat symlinks). settings.json already writes its
# hook commands as $HOME/.claude/dwarves-kit/hooks/*.sh for the same reason.
KIT_REF="~/.claude/dwarves-kit"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ROOT="$(cd "$SELF_DIR/.." && pwd)"   # the dwarves-kit repo root when run from its lib/
START="<!-- kit:adopt -->"               # managed-block markers in the consumer CLAUDE.md
END="<!-- /kit:adopt -->"

tmp=""                                   # scratch file; the trap cleans it up on any early exit
trap 'rm -f "$tmp"' EXIT

usage() { echo "usage: adopt.sh [--check | --dry-run | --refresh] [--with <a,b,c>] [--] <target-dir>" >&2; exit 64; }

CHECK=0 DRY=0 REFRESH=0 WITH_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1; shift;;
    --dry-run) DRY=1; shift;;
    --refresh) REFRESH=1; shift;;
    --with) shift; WITH_ARG="${1:-}"; shift;;
    --with=*) WITH_ARG="${1#--with=}"; shift;;
    --) shift; break;;
    -*) usage;;
    *) break;;
  esac
done
TARGET="${1:-}"; [ -n "$TARGET" ] || usage
[ -d "$TARGET" ] || { echo "adopt: target dir not found: $TARGET" >&2; exit 1; }

agents="$TARGET/AGENTS.md"
workflow="$TARGET/WORKFLOW.md"
claude="$TARGET/CLAUDE.md"
marker="$TARGET/docs/verification/README.md"
dotkit="$TARGET/.kit.toml"
project_settings="$TARGET/.claude/settings.json"

is_adopted() {
  # -qxF: the marker must be its own full line (matches how awk strips the block). A substring
  # grep would mis-detect a marker quoted inside prose and skip the append path (review #6).
  [ -f "$agents" ] && [ -f "$marker" ] && [ -f "$claude" ] \
    && grep -qxF "$START" "$claude" 2>/dev/null
}

if [ "$CHECK" -eq 1 ]; then
  is_adopted && { echo "adopted: $TARGET"; exit 0; } || { echo "not adopted: $TARGET"; exit 1; }
fi

git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1 \
  || echo "adopt: warning: $TARGET is not a git repo (adopting at filesystem level anyway)" >&2

# Resolve a source AGENTS.md: the kit repo (dev) first, then the install.
src_agents=""
for c in "$SRC_ROOT/AGENTS.md" "$KIT_ROOT/AGENTS.md"; do
  [ -f "$c" ] && { src_agents="$c"; break; }
done
[ -n "$src_agents" ] || { echo "adopt: no source AGENTS.md (looked in $SRC_ROOT, $KIT_ROOT)" >&2; exit 1; }

workflow_block() {
  cat <<EOF
# WORKFLOW.md (pointer)

This repo is adopted into the dwarves-kit. The canonical lanes and the lane x phase gate matrix
live in the installed kit: \`$KIT_REF/WORKFLOW.md\`. Read that for the lanes and the gate at each
phase boundary. The gate machinery (gate-ledger, ship-gate) parses that copy, not this file.
EOF
}

claude_block() {
  printf '%s\n' "$START"
  printf '## Operating layer (dwarves-kit)\n\n'
  printf '@AGENTS.md\n\n'
  printf 'Before touching code, classify the lane: `bash %s/bin/classify lane classify "<task>"`.\n' "$KIT_REF"
  printf 'A full-lane change records its gates via `%s/bin/gate ledger` or the ship-gate blocks the push.\n' "$KIT_REF"
  printf '%s\n' "$END"
}

did=0
note() { echo "adopt: would $*"; }

# 1. AGENTS.md -- the operate-contract. NEVER overwritten (even on --refresh).
if [ ! -f "$agents" ]; then
  if [ "$DRY" -eq 1 ]; then note "create AGENTS.md (from $src_agents)"; else cp "$src_agents" "$agents"; fi
  did=1
fi

# 2. WORKFLOW.md pointer -- create if absent; --refresh overwrites to current. Write atomically
# (tmp + mv) so a kill / full disk mid-write can't leave a half-written pointer (review #3).
if [ ! -f "$workflow" ] || { [ "$REFRESH" -eq 1 ] && ! cmp -s <(workflow_block) "$workflow"; }; then
  if [ "$DRY" -eq 1 ]; then note "write WORKFLOW.md pointer"; else
    tmp="$(mktemp)"; workflow_block > "$tmp"; mv "$tmp" "$workflow"
  fi
  did=1
fi

# 3. CLAUDE.md loader (@AGENTS.md import) -- append once; --refresh replaces the managed block.
if [ ! -f "$claude" ] || ! grep -qxF "$START" "$claude" 2>/dev/null; then
  if [ "$DRY" -eq 1 ]; then note "append the CLAUDE.md @AGENTS.md loader block"; else
    tmp="$(mktemp)"; { [ -f "$claude" ] && cat "$claude"; printf '\n'; claude_block; } > "$tmp"; mv "$tmp" "$claude"
  fi
  did=1
elif [ "$REFRESH" -eq 1 ]; then
  # Refuse to refresh a block with a START but no END: the awk strip would drop everything from
  # START to EOF and mv would install the truncated file (silent data loss; review CRITICAL #1).
  # This is exactly the legacy single-sentinel shape, so the operator migrates it by hand.
  if ! grep -qxF "$END" "$claude" 2>/dev/null; then
    echo "adopt: $claude has '$START' but no '$END' line; refusing --refresh (would truncate)." >&2
    echo "adopt: add an '$END' line after the managed block, or delete the block, then re-run." >&2
    exit 1
  fi
  if [ "$DRY" -eq 1 ]; then note "refresh the CLAUDE.md loader block"; did=1; else
    tmp="$(mktemp)"
    # END{if(drop)exit 3}: belt-and-suspenders against an unterminated block slipping past the
    # guard above; the `|| exit` stops us from mv-ing a truncated file when awk bails.
    awk -v s="$START" -v e="$END" '
      $0==s{drop=1; next} drop&&$0==e{drop=0; next} !drop{print}
      END{if(drop) exit 3}' "$claude" > "$tmp" \
      || { echo "adopt: failed to strip the managed block from $claude (unterminated?)" >&2; exit 1; }
    claude_block >> "$tmp"
    if cmp -s "$tmp" "$claude"; then rm -f "$tmp"; else mv "$tmp" "$claude"; did=1; fi
  fi
fi

# 4. proof marker -- presence opts this repo into the ship-gate. NEVER overwritten.
if [ ! -f "$marker" ]; then
  if [ "$DRY" -eq 1 ]; then note "create docs/verification/README.md (proof marker)"; else
    mkdir -p "$(dirname "$marker")"
    cat > "$marker" <<EOF
# Verification (proof-of-done marker)

Presence of this file opts this repo into the dwarves-kit proof-of-done ship-gate. A
behavioral/stateful change owes a recorded run here; the shape per loop type comes from the
install: \`bash $KIT_REF/lib/gate/proof-gate.sh contract "<task>"\`.
EOF
  fi
  did=1
fi

# --- SPEC-192 (goal 06): close the per-project override loop -----------------------------

# Resolve the kit-root kit.toml (dev checkout first, then the install) -- same lookup shape
# as src_agents above.
kit_root_toml=""
for c in "$SRC_ROOT/kit.toml" "$KIT_ROOT/kit.toml"; do
  [ -f "$c" ] && { kit_root_toml="$c"; break; }
done

# module -> its hook script basenames (space-separated; empty = hookless -- queue, stats,
# quiz_gate, weekend_batch, bridge are commands/skills with no hook to gate). Kept in sync
# with install.sh's kit_module_hooks() (same doc note there): only board/session/advisor/
# cosmetic carry a hook, so only those need a settings.json entry.
kit_module_hooks() {
  case "$1" in
    board) echo "backlog-stage.sh" ;;
    session) echo "context-readiness.sh output-offload.sh pre-compact-backup.sh post-compact-reinject.sh session-state-save.sh harvest.sh citation-guard.sh" ;;
    advisor) echo "context-hints.sh" ;;
    cosmetic) echo "auto-format.sh notification.sh slop-cleaner.sh statusline.sh codebase-index.sh permission-auto-approve.sh" ;;
    *) echo "" ;;
  esac
}

KIT_KNOWN_MODULES="board session advisor cosmetic queue stats quiz_gate weekend_batch bridge"

# Load the config resolver in a function scope so its own `${1:-}` selftest check (see
# lib/config/kit-config.sh) never sees adopt.sh's own positional parameters (TARGET etc).
_kit_load_config_resolver() {
  # shellcheck source=lib/config/kit-config.sh
  source "$SELF_DIR/config/kit-config.sh"
}
RESOLVER_OK=1
_kit_load_config_resolver 2>/dev/null || RESOLVER_OK=0

# 5. Per-project .kit.toml -- an OPT-IN starter (SPEC-192). Created only if absent; a
# project's own config is NEVER overwritten by adopt, fresh or --refresh (same invariant as
# AGENTS.md / the proof marker). --with (first run only) seeds the named modules `true`;
# every other key seeds the kit-root default it would inherit anyway -- writing the line
# explicitly just makes the override point visible and editable.
if [ -n "$kit_root_toml" ] && [ "$RESOLVER_OK" -eq 1 ]; then
  if [ ! -f "$dotkit" ]; then
    if [ "$DRY" -eq 1 ]; then
      note "seed a starter .kit.toml (modules: ${WITH_ARG:-kit-root defaults})"
    else
      with_norm=""
      [ -n "$WITH_ARG" ] && with_norm=" $(echo "$WITH_ARG" | tr ',' ' ' | xargs) "
      tmp="$(mktemp)"
      {
        echo "# .kit.toml -- this PROJECT's override of the kit-root defaults."
        echo "# Only the keys you set here matter; every key you omit inherits the kit-root"
        echo "# default at $KIT_REF/kit.toml (lib/config/kit-config.sh: project keys WIN)."
        echo "# Re-run \`bash $KIT_REF/lib/adopt.sh --refresh <this repo>\` (or /kit:adopt) after"
        echo "# editing [modules] to re-wire this project's .claude/settings.json to match --"
        echo "# adopt reads this file at adopt time; no hook reads it at hook-fire time."
        echo ""
        echo "[modules]"
        for m in $KIT_KNOWN_MODULES; do
          if [ -n "$with_norm" ]; then
            case "$with_norm" in *" $m "*) v=true ;; *) v=false ;; esac
          else
            KIT_CONFIG_ROOT="$(dirname "$kit_root_toml")" KIT_PROJECT_ROOT="$TARGET" \
              v="$(kit_config_get "modules.$m" "false")"
          fi
          echo "$m = $v"
        done
      } > "$tmp"
      mv "$tmp" "$dotkit"
    fi
    did=1
  elif [ -n "$WITH_ARG" ]; then
    echo "adopt: note: $dotkit already exists; --with ignored (edit the file's [modules] section directly)" >&2
  fi
fi

# 6. Per-project hook-module wiring into <target>/.claude/settings.json (SPEC-192). Runs on
# EVERY adopt invocation (fresh or --refresh), reading this project's CURRENT .kit.toml (project
# override, else the kit-root default -- the resolver from goal 01), so a hand-edited .kit.toml
# is picked up the next time adopt runs. Never on hook-fire (Not: runtime per-call module
# toggling). A jq MERGE, never a settings.json rewrite: only kit-module hook entries
# (dwarves-kit/hooks/*) are added/removed; every other entry in the file is preserved untouched.
# Command/skill modules (queue, stats, quiz_gate, weekend_batch, bridge) have no hook, so they
# never touch settings.json regardless of their .kit.toml value.
if [ -n "$kit_root_toml" ] && [ "$RESOLVER_OK" -eq 1 ] && command -v jq >/dev/null 2>&1; then
  settings_src=""
  for c in "$SRC_ROOT/settings.json" "$KIT_ROOT/settings.json"; do
    [ -f "$c" ] && { settings_src="$c"; break; }
  done
  if [ -n "$settings_src" ]; then
    HOOKED_MODULES="board session advisor cosmetic"
    enabled_list="" wired_hook_names=""
    for m in $HOOKED_MODULES; do
      KIT_CONFIG_ROOT="$(dirname "$kit_root_toml")" KIT_PROJECT_ROOT="$TARGET" \
        v="$(kit_config_get "modules.$m" "false")"
      if [ "$v" = "true" ]; then
        enabled_list="$enabled_list $m"
        wired_hook_names="$wired_hook_names $(kit_module_hooks "$m")"
      fi
    done
    wired_hook_names="$(echo "$wired_hook_names" | xargs)"

    hook_re=""
    for h in $wired_hook_names; do
      esc="$(printf '%s' "$h" | sed 's/\./\\./g')"
      if [ -z "$hook_re" ]; then hook_re="$esc"; else hook_re="$hook_re|$esc"; fi
    done

    if [ "$DRY" -eq 1 ]; then
      note "wire $project_settings for modules:${enabled_list:-<none>} (hooks:${wired_hook_names:-none})"
    else
      before_wired=""
      [ -f "$project_settings" ] && before_wired="$(jq -r '[.hooks // {} | to_entries[]? | .value[]? | .hooks[]? | .command] | .[]' "$project_settings" 2>/dev/null | grep -oE 'dwarves-kit/hooks/[A-Za-z0-9._-]+\.sh' | sort -u)"

      filtered="$(mktemp)"
      if [ -n "$hook_re" ]; then
        jq --arg re "$hook_re" '
          .hooks |= (
            to_entries | map(
              .value |= (
                map(.hooks |= map(select(.command | test($re)))) | map(select(.hooks | length > 0))
              )
            ) | from_entries
          )
        ' "$settings_src" > "$filtered" 2>/dev/null || echo '{"hooks":{}}' > "$filtered"
      else
        echo '{"hooks":{}}' > "$filtered"
      fi

      mkdir -p "$(dirname "$project_settings")"
      # One code path for both "no project settings.json yet" and "re-wiring an existing
      # one" (a missing file reads as {}): strip any prior kit-module hook (dwarves-kit/
      # hooks/*, added by an earlier adopt run), then union in the currently-enabled set.
      # Canonicalized (jq -S, arrays sorted by their own JSON text) so a re-run over an
      # UNCHANGED .kit.toml reproduces byte-identical output -- adopt's own idempotency
      # invariant (test-adopt.sh), not just "the same hook names, any order".
      existing_json='{}'
      [ -f "$project_settings" ] && existing_json="$(cat "$project_settings")"
      merged="$(jq -n --argjson existing "$existing_json" --slurpfile kit "$filtered" '
        $existing as $ex | ($kit[0].hooks // {}) as $kh
        | $ex
        | .hooks = (
            ((($ex.hooks // {}) | to_entries
              | map(.value |= (
                  map(.hooks |= map(select(.command | tostring | contains("dwarves-kit/hooks/") | not)))
                  | map(select(.hooks | length > 0))
                ))
             ) + ($kh | to_entries))
            | group_by(.key)
            | map({
                key: .[0].key,
                value: ([.[].value[]] | unique_by(tostring) | sort_by(tostring))
              })
            | sort_by(.key)
            | from_entries
          )
      ' 2>/dev/null)"
      if [ -n "$merged" ] && echo "$merged" | jq -S '.' >/dev/null 2>&1; then
        echo "$merged" | jq -S '.' > "$project_settings"
      else
        echo "adopt: warning: jq merge of $project_settings failed; left untouched" >&2
      fi
      rm -f "$filtered"

      after_wired=""
      [ -f "$project_settings" ] && after_wired="$(jq -r '[.hooks // {} | to_entries[]? | .value[]? | .hooks[]? | .command] | .[]' "$project_settings" 2>/dev/null | grep -oE 'dwarves-kit/hooks/[A-Za-z0-9._-]+\.sh' | sort -u)"
      [ "$before_wired" != "$after_wired" ] && did=1
      echo "adopt: project hook-module wiring for $TARGET -> modules:${enabled_list:-<none>}"
    fi
  fi
fi

if [ "$DRY" -eq 1 ]; then
  echo "adopt: --dry-run for $TARGET ($([ "$did" -eq 1 ] && echo 'changes above' || echo 'already adopted, nothing to do'))"
else
  echo "adopt: $TARGET ($([ "$did" -eq 1 ] && echo updated || echo 'already adopted, no-op'))"
fi
