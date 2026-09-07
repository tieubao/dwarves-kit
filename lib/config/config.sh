#!/usr/bin/env bash
# config.sh -- the bin/config engine (SPEC-198, ADR-0034 decision 4).
#
# WHY: every runtime knob has an env var, a kit.toml key, or both, resolved by a DIFFERENT
# ad-hoc precedence in a different file. There was no ONE place to see "what is this knob's
# value right now, and WHY" (env override vs project .kit.toml vs kit-root kit.toml vs
# hardcoded default) without opening files. This is that read/explain surface.
#
# FENCE (ADR-0034 decision 4): `lib/config/kit-config.sh` stays the ONLY reader of TOML. This
# file does NOT parse kit.toml itself -- it calls INTO kit-config.sh's existing accessors
# (kit_config_get / kit_config_root / kit_config_project / _kit_toml_get) for every value, and
# reads the CHECKED-IN lib/config/module-registry.md (a markdown table, not TOML) to enumerate
# which keys exist. `config set` is OUT (help text says .kit.toml hand-edit for now).
#
# Verbs:
#   config list             -- every declared knob: key, status tag, effective value,
#                               provenance, owning module
#   config get <key>        -- the resolved effective value only (for scripting)
#   config explain <key>    -- the full 4-level provenance chain + which level won
# <key> is either the env var name (WAVE_CAP) or the dotted kit.toml key (mega.wave_cap).
set -euo pipefail
CONFIG_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY_FILE="${CONFIG_REGISTRY_FILE:-$CONFIG_SELF/module-registry.md}"
# shellcheck source=lib/config/kit-config.sh
source "$CONFIG_SELF/kit-config.sh" || { echo "config: lib/config/kit-config.sh missing or unreadable" >&2; exit 1; }
# The binary seam's PATH lookup is the SAME contract bin/prose-rag execs (SPEC-251): one
# resolver, so a stale kit wrapper on PATH cannot read `filled` here while the shim
# correctly reports no engine.
# The readability test comes first: bash 3.2 exits the whole shell on a `source` it cannot
# find, so a `||` message would never print.
[ -r "$CONFIG_SELF/../prose-rag/resolve.sh" ] || { echo "config: lib/prose-rag/resolve.sh missing or unreadable" >&2; exit 1; }
# shellcheck source=lib/prose-rag/resolve.sh
source "$CONFIG_SELF/../prose-rag/resolve.sh"

# _env_val <name> -- the value of env var <name>, and ONLY when <name> is a syntactically
# valid shell identifier ([A-Za-z_][A-Za-z0-9_]*). Prints nothing and returns 1 otherwise.
#
# ATTACK SHAPE (why this exists): bash EVALUATES an array subscript during indirect expansion,
# so `"${!n}"` where n holds `EVIL[$(cmd)]` runs cmd -- command execution from a plain string,
# bash 3.2 included. Every name reaching an indirect expansion here comes from the registry
# table, and CONFIG_REGISTRY_FILE is an unvalidated env override, so a forged registry is
# attacker-controlled input. Validate the NAME before any indirect expansion, at both call
# sites (_resolve and _seam_resolve). The `case` glob keeps this bash 3.2 safe.
_env_val() {
  local n="$1"
  case "$n" in
    ''|[0-9]*|*[!A-Za-z0-9_]*) return 1 ;;
  esac
  printf '%s' "${!n:-}"
}

_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# _registry_rows -- print every data row (raw, still pipe-delimited) from every subsection
# under "## Env <-> key registry", skipping section headers, table headers, and separators.
_registry_rows() {
  [ -f "$REGISTRY_FILE" ] || { echo "config: registry file missing: $REGISTRY_FILE" >&2; return 1; }
  awk '
    /^## Env <-> key registry/ {inreg=1; next}
    /^## Allowlist/ {inreg=0}
    inreg && /^\|/ {
      if ($0 ~ /^\| Env var \|/) next
      if ($0 ~ /^\|---/) next
      print
    }
  ' "$REGISTRY_FILE"
}

# _row_get <row> <1..6> -- trimmed column (1=env var, 2=kit.toml key, 3=default, 4=status,
# 5=module, 6=doc). Pipe-split is safe: the registry deliberately keeps no literal `|` inside
# a cell (verified at authoring time; see the sub-goal's proof-of-done pipe-count check).
_row_get() {
  local row="$1" idx="$2" f
  IFS='|' read -ra f <<< "$row"
  _trim "${f[$idx]:-}"
}

# _seam_rows -- print every data row (raw, pipe-delimited) from the "## Seams" join table
# (SPEC-249 TASK-002). This table sits AFTER "## Allowlist", outside _registry_rows' window,
# so it never doubles as a fake registry row in `config list`. Three columns: Key, Kind,
# Filled by. The window CLOSES at the next top-level "## " heading, so a pipe table under a
# later section (module-registry.md already carries "## Known gaps") is never read as a seam
# row. tests/test-config-registry.sh's own lint copy must use the same stop rule.
_seam_rows() {
  [ -f "$REGISTRY_FILE" ] || { echo "config: registry file missing: $REGISTRY_FILE" >&2; return 1; }
  awk '
    /^## Seams/ {inseam=1; next}
    inseam && /^## / {inseam=0}
    inseam && /^\|/ {
      if ($0 ~ /^\| Key \|/) next
      if ($0 ~ /^\|---/) next
      print
    }
  ' "$REGISTRY_FILE"
}

# _find_row <key> -- first registry row whose env-var column OR kit.toml-key column exactly
# matches <key>. Registry order is the tie-break when a kit.toml key has more than one env var
# (ledger.location: KIT_LEDGER_DIR is listed before DWARVES_KIT_LOG_DIR before the toml-only
# default row, so a lookup by the bare key resolves to the canonical env var's row).
_find_row() {
  local key="$1" row env tk
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    env="$(_row_get "$row" 1)"; tk="$(_row_get "$row" 2)"
    if [ "$env" = "$key" ] || [ "$tk" = "$key" ]; then printf '%s' "$row"; return 0; fi
  done < <(_registry_rows)
  return 1
}

# _default_value <cell> -- the MACHINE value of a registry Default cell. The cell is authored
# for humans (a backtick-quoted literal plus an optional parenthetical annotation, e.g.
# `1` (truthy)), but `config get`'s contract is "the resolved effective value only (for
# scripting)" -- so extract the first backtick-quoted literal and strip one layer of
# double-quotes (mirroring _kit_toml_get's own unquote). A cell with NO backtick literal
# ((none), **no-default-consumer**, n/a) is a pure annotation: there IS no machine default,
# and the annotation itself is the most honest output, so it passes through as-is.
_default_value() {
  local cell="$1" lit
  case "$cell" in
    \`*)
      lit="${cell#\`}"; lit="${lit%%\`*}"
      lit="${lit#\"}"; lit="${lit%\"}"
      printf '%s' "$lit"
      ;;
    *) printf '%s' "$cell" ;;
  esac
}

# _resolve <row> -- sets EFFECTIVE / PROVENANCE / ENV_VAL / ENV_SET / PROJ_VAL / PROJ_SET /
# ROOT_VAL / ROOT_SET (globals; mirrors the small-bash-script house style of
# lib/classify/lane-classify.sh's LANE/REASON/FIRED globals, not a subshell-return dance).
_resolve() {
  local row="$1" envvar tomlkey defaultval section key
  envvar="$(_row_get "$row" 1)"; tomlkey="$(_row_get "$row" 2)"
  defaultval="$(_default_value "$(_row_get "$row" 3)")"

  # Non-EMPTY test, not bare existence: every real consumer in this codebase reads its knob
  # via ${VAR:-default} (e.g. orchestrate.sh's WAVE_CAP), which treats set-but-empty exactly
  # like unset -- so this surface must match, or `WAVE_CAP="" config explain` would report an
  # empty env win the real orchestrator never sees. (The one deliberate exception,
  # KIT_LEDGER_DIR's set-but-empty FATAL in kit_resolve_log_dir, is documented on that row;
  # the generic model does not replay it.) Also consistent with the TOML levels below, whose
  # [ -n ... ] tests already treat empty as unset.
  #
  # A malformed env-var cell (see _env_val's attack-shape note) resolves as if unset.
  ENV_VAL=""; ENV_SET=0
  local ev
  if [ "$envvar" != "-" ] && ev="$(_env_val "$envvar")" && [ -n "$ev" ]; then
    ENV_SET=1; ENV_VAL="$ev"
  fi

  PROJ_VAL=""; PROJ_SET=0; ROOT_VAL=""; ROOT_SET=0
  if [ "$tomlkey" != "env-only" ] && [ "$tomlkey" != "-" ]; then
    section="${tomlkey%%.*}"; key="${tomlkey#*.}"
    PROJ_VAL="$(_kit_toml_get "$(kit_config_project)" "$section" "$key")"
    [ -n "$PROJ_VAL" ] && PROJ_SET=1
    ROOT_VAL="$(_kit_toml_get "$(kit_config_root)" "$section" "$key")"
    [ -n "$ROOT_VAL" ] && ROOT_SET=1
  fi

  if [ "$ENV_SET" = 1 ]; then EFFECTIVE="$ENV_VAL"; PROVENANCE="env"
  elif [ "$PROJ_SET" = 1 ]; then EFFECTIVE="$PROJ_VAL"; PROVENANCE="project .kit.toml"
  elif [ "$ROOT_SET" = 1 ]; then EFFECTIVE="$ROOT_VAL"; PROVENANCE="kit-root kit.toml"
  else EFFECTIVE="$defaultval"; PROVENANCE="default"
  fi
}

# _seam_cells <row> -- how many pipe-delimited fields the raw row splits into. `read -a`
# preserves a LEADING empty field from the opening pipe but drops the trailing one, so a
# well-formed "| Key | Kind | Filled by |" row (3 data cells) splits into 4 fields; anything
# short of that is missing at least one of the three columns.
_seam_cells() {
  local row="$1" f
  IFS='|' read -ra f <<< "$row"
  printf '%s' "${#f[@]}"
}

# _skill_dirs -- the ordered list of skill dirs a "skill" kind seam is checked against
# (SPEC-249 TASK-002). KIT_SKILL_DIRS entries are kept only when their realpath sits under
# $HOME's realpath (a repo .envrc can set this env var, so it is untrusted); the default list
# ($HOME/.claude/skills plus $CLAUDE_PLUGIN_ROOT/skills when set) is the kit's own and needs
# no fence. set -u safe: CLAUDE_PLUGIN_ROOT and KIT_SKILL_DIRS are read with ${VAR:-}.
_skill_dirs() {
  local list="${KIT_SKILL_DIRS:-}" d rp
  if [ -n "$list" ]; then
    local IFS=':'
    for d in $list; do
      [ -n "$d" ] || continue
      rp="$(cd "$d" 2>/dev/null && pwd -P)" || continue
      _under_home "$rp" && printf '%s\n' "$rp"
    done
  else
    printf '%s\n' "${HOME}/.claude/skills"
    [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && printf '%s\n' "${CLAUDE_PLUGIN_ROOT}/skills"
  fi
}

# _under_home <realpath> -- is <realpath> $HOME's realpath, or under it? The caller resolves
# the path first; this only compares.
_under_home() {
  local home_real
  home_real="$(cd "$HOME" 2>/dev/null && pwd -P)" || return 1
  case "$1" in "$home_real"|"$home_real"/*) return 0 ;; esac
  return 1
}

# _seam_target_resolves <kind> <value> -- does the seam's resolved value name a real target?
# Never executes anything; existence checks only (per the Interfaces contract).
#
# For file and dir the check is realpath-under-$HOME, not bare existence: the consumers
# (`wrap log`, `wrap knowledge-root`) apply exactly that fence and REFUSE a target outside
# $HOME. Reporting such a target as `filled` made `config seams --check` exit 0 on a root the
# consumer would reject -- an advisor that disagrees with the thing it advises on.
_seam_target_resolves() {
  local kind="$1" val="$2" d base
  case "$kind" in
    skill)
      while IFS= read -r d; do
        [ -n "$d" ] || continue
        [ -f "$d/$val/SKILL.md" ] && return 0
      done < <(_skill_dirs)
      return 1
      ;;
    file)
      base="$(basename "$val")"
      d="$(cd "$(dirname "$val")" 2>/dev/null && pwd -P)" || return 1
      # `[ -f ]` follows a leaf symlink; `wrap log` refuses one outright, so the advisor does too.
      [ -f "$d/$base" ] && [ ! -L "$d/$base" ] || return 1
      _under_home "$d/$base"
      ;;
    dir)
      d="$(cd "$val" 2>/dev/null && pwd -P)" || return 1
      _under_home "$d"
      ;;
    *) return 1 ;;
  esac
}

# _seam_resolve <row> -- sets SEAM_KEY / SEAM_KIND / SEAM_FILLEDBY / SEAM_VALUE / SEAM_STATUS
# (globals, mirrors _resolve's own style). Joins the seam's Key to its registry row with
# _find_row for the default and module -- NEVER _resolve (that reads the project .kit.toml,
# which a seam target must never do; DEC-004/DEC-010). A section.key resolves through
# kit_config_get_root; an env-only key reads ${VAR:-}. The verb never executes a target.
_seam_resolve() {
  local srow="$1" key kind filledby row envvar tomlkey defaultval raw

  if [ "$(_seam_cells "$srow")" -lt 4 ]; then
    SEAM_KEY="$(_row_get "$srow" 1)"; SEAM_KIND="$(_row_get "$srow" 2)"; SEAM_FILLEDBY="$(_row_get "$srow" 3)"
    [ -n "$SEAM_KEY" ] || SEAM_KEY="(malformed row)"
    SEAM_VALUE="(malformed row)"; SEAM_STATUS="unresolved"
    return 0
  fi

  key="$(_row_get "$srow" 1)"; kind="$(_row_get "$srow" 2)"; filledby="$(_row_get "$srow" 3)"
  SEAM_KEY="$key"; SEAM_KIND="$kind"; SEAM_FILLEDBY="$filledby"

  case "$kind" in
    skill|file|dir|binary) ;;
    *) SEAM_VALUE="(unknown kind)"; SEAM_STATUS="unresolved"; return 0 ;;
  esac

  row="$(_find_row "$key")" || { SEAM_VALUE="(malformed row)"; SEAM_STATUS="unresolved"; return 0; }
  envvar="$(_row_get "$row" 1)"; tomlkey="$(_row_get "$row" 2)"
  defaultval="$(_default_value "$(_row_get "$row" 3)")"

  if [ "$tomlkey" != "env-only" ] && [ "$tomlkey" != "-" ]; then
    raw="$(kit_config_get_root "$tomlkey" "")"
  else
    # A malformed env-var cell (see _env_val's attack-shape note) is a broken registry row,
    # not an unset knob: report it as such rather than silently resolving to empty.
    raw="$(_env_val "$envvar")" || { SEAM_VALUE="(malformed row)"; SEAM_STATUS="unresolved"; return 0; }
  fi
  case "$raw" in "~"/*) raw="${HOME}/${raw#\~/}" ;; esac

  if [ "$kind" != "binary" ]; then
    if [ -z "$raw" ] || [ "$raw" = "$defaultval" ]; then
      SEAM_VALUE="${raw:-(empty)}"; SEAM_STATUS="default"
      return 0
    fi
    SEAM_VALUE="$raw"
    # A `file`/`dir` value that is not absolute (and was not `~`-prefixed above) must never be
    # resolved against this process's cwd: `_seam_target_resolves` shells out to `cd
    # "$(dirname "$val")"`, which for a relative value silently resolves against wherever
    # `config seams` happens to be invoked from -- a raw operator value like "notes.md" could
    # then read `filled` purely by accident of cwd. Reject it here before that call.
    if [ "$kind" = "file" ] || [ "$kind" = "dir" ]; then
      case "$raw" in
        /*) ;;
        *) SEAM_STATUS="unresolved"; return 0 ;;
      esac
    fi
    if _seam_target_resolves "$kind" "$raw"; then SEAM_STATUS="filled"; else SEAM_STATUS="unresolved"; fi
    return 0
  fi

  # binary: "default" never applies (DEC-009); env-set must be executable, else PATH lookup.
  if [ -n "$raw" ]; then
    SEAM_VALUE="$raw"
    # [ -x ] alone is true for a searchable directory; a binary must be a regular file too.
    if [ -f "$raw" ] && [ -x "$raw" ]; then SEAM_STATUS="filled"; else SEAM_STATUS="unresolved"; fi
    return 0
  fi
  local found
  found="$(prose_rag_resolve "$defaultval" || true)"
  if [ -n "$found" ]; then SEAM_VALUE="$found"; SEAM_STATUS="filled"
  else SEAM_VALUE="(not on PATH)"; SEAM_STATUS="absent"
  fi
}

# _display_key <row> -- the env var name if one exists, else the kit.toml key.
_display_key() {
  local row="$1" envvar tomlkey
  envvar="$(_row_get "$row" 1)"; tomlkey="$(_row_get "$row" 2)"
  [ "$envvar" != "-" ] && { printf '%s' "$envvar"; return 0; }
  printf '%s' "$tomlkey"
}

cmd_list() {
  printf '%-30s %-10s %-30s %-20s %s\n' "KEY" "STATUS" "VALUE" "PROVENANCE" "MODULE"
  local row status module display val
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    _resolve "$row"
    status="$(_row_get "$row" 4)"; module="$(_row_get "$row" 5)"
    display="$(_display_key "$row")"
    val="$EFFECTIVE"
    # A machine-empty default ("" -- e.g. TIER4_CORPUS) renders as a visible marker, not a
    # blank cell a reader would misread as a rendering bug. Display-only: `get` still emits
    # the honest empty string for scripting.
    [ -n "$val" ] || val="(empty)"
    # Non-[impl] keys are inert by contract (design/reserved/consumer): never render them as
    # a live toggle, so a reader cannot mistake a designed-not-built key for a working one.
    if [ "$status" != "[impl]" ]; then
      local tag="${status#\[}"; tag="${tag%\]}"
      val="(inert: $tag, no live effect)"
    fi
    printf '%-30s %-10s %-30s %-20s %s\n' "$display" "$status" "$val" "$PROVENANCE" "$module"
  done < <(_registry_rows)
}

cmd_get() {
  local key="${1:?usage: config get <key>}" row
  row="$(_find_row "$key")" || { echo "config: unknown key '$key' (not in $REGISTRY_FILE)" >&2; return 1; }
  _resolve "$row"
  printf '%s\n' "$EFFECTIVE"
}

cmd_explain() {
  local key="${1:?usage: config explain <key>}" row envvar tomlkey defaultval status module doc
  row="$(_find_row "$key")" || { echo "config: unknown key '$key' (not in $REGISTRY_FILE)" >&2; return 1; }
  envvar="$(_row_get "$row" 1)"; tomlkey="$(_row_get "$row" 2)"; defaultval="$(_row_get "$row" 3)"
  status="$(_row_get "$row" 4)"; module="$(_row_get "$row" 5)"; doc="$(_row_get "$row" 6)"
  _resolve "$row"

  printf '%s (module=%s, status=%s)\n' "$(_display_key "$row")" "$module" "$status"
  printf '  %s\n\n' "$doc"

  if [ "$envvar" != "-" ]; then
    if [ "$ENV_SET" = 1 ]; then printf '  1. env             %-20s = %s\n' "$envvar" "$ENV_VAL"
    else printf '  1. env             %-20s = (unset)\n' "$envvar"; fi
  else
    printf '  1. env             n/a (this key has no env override)\n'
  fi

  if [ "$tomlkey" != "env-only" ] && [ "$tomlkey" != "-" ]; then
    if [ "$PROJ_SET" = 1 ]; then printf '  2. project .kit.toml %-19s = %s   [%s]\n' "[$tomlkey]" "$PROJ_VAL" "$(kit_config_project)"
    else printf '  2. project .kit.toml %-19s = (unset)   [%s]\n' "[$tomlkey]" "$(kit_config_project)"; fi
    if [ "$ROOT_SET" = 1 ]; then printf '  3. kit-root kit.toml %-19s = %s   [%s]\n' "[$tomlkey]" "$ROOT_VAL" "$(kit_config_root)"
    else printf '  3. kit-root kit.toml %-19s = (unset)   [%s]\n' "[$tomlkey]" "$(kit_config_root)"; fi
  else
    printf '  2. project .kit.toml n/a (this key has no kit.toml backing: %s)\n' "$tomlkey"
    printf '  3. kit-root kit.toml n/a (this key has no kit.toml backing: %s)\n' "$tomlkey"
  fi

  printf '  4. default          = %s\n\n' "$defaultval"
  printf 'Effective: %s   (source: %s)\n' "$EFFECTIVE" "$PROVENANCE"
}

cmd_seams() {
  local check=0 srow any_unresolved=0 rows=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --check) check=1; shift ;;
      *) echo "config seams: unknown flag '$1'" >&2; usage >&2; return 64 ;;
    esac
  done
  printf '%-30s %-10s %-30s %-15s %s\n' "KEY" "KIND" "VALUE" "STATUS" "FILLED-BY"
  while IFS= read -r srow; do
    [ -n "$srow" ] || continue
    rows=$((rows + 1))
    _seam_resolve "$srow"
    printf '%-30s %-10s %-30s %-15s %s\n' "$SEAM_KEY" "$SEAM_KIND" "$SEAM_VALUE" "$SEAM_STATUS" "$SEAM_FILLEDBY"
    [ "$SEAM_STATUS" = "unresolved" ] && any_unresolved=1
  done < <(_seam_rows)
  # A missing or empty "## Seams" heading otherwise printed just the header and exited 0,
  # silently reporting nothing wrong -- indistinguishable from a registry with every seam
  # genuinely filled. Say so explicitly, and let --check treat it as the failure it is.
  if [ "$rows" -eq 0 ]; then
    echo "(no seam rows: ## Seams table missing or empty)"
    [ "$check" = 1 ] && return 1
    return 0
  fi
  [ "$check" = 1 ] && [ "$any_unresolved" = 1 ] && return 1
  return 0
}

usage() {
  cat <<'EOF'
usage: config {list|get|explain|seams} [args...]

  config list             every declared knob: key, status, effective value, provenance, module
  config get <key>        the resolved effective value only (env var name or dotted kit.toml key)
  config explain <key>    the full 4-level provenance chain (env > project > kit-root > default)
  config seams [--check]  cross-kit seam report: KEY KIND VALUE STATUS FILLED-BY (SPEC-249);
                          --check exits 1 if any row is unresolved

`config set` is not built. Hand-edit <project>/.kit.toml to change a project-level value; the
kit-root default lives in kit.toml. See docs/specs/SPEC-198-config-surface.md.
EOF
}

main() {
  local verb="${1:-}"
  # Fail loudly up front for the read verbs: _registry_rows' own error would otherwise be
  # swallowed by cmd_list's `< <(...)` process substitution (whose exit status is never
  # checked), leaving a header-only render with exit 0 -- a silent-success a CI wrapper
  # would misread. cmd_get/cmd_explain would fail anyway, but with a misleading "unknown
  # key" message instead of the real cause. (A separate guard case, not `;;&` fall-through
  # -- that is bash-4-only and macOS ships bash 3.2.)
  case "$verb" in
    list|get|explain|seams)
      [ -f "$REGISTRY_FILE" ] || { echo "config: registry file missing: $REGISTRY_FILE" >&2; return 1; }
      ;;
  esac
  case "$verb" in
    list) cmd_list ;;
    get) shift; cmd_get "$@" ;;
    explain) shift; cmd_explain "$@" ;;
    seams) shift; cmd_seams "$@" ;;
    ""|-h|--help|help) usage ;;
    *) echo "config: unknown verb '$verb'" >&2; usage >&2; return 64 ;;
  esac
}

main "$@"
