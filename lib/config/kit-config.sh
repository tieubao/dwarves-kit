#!/usr/bin/env bash
# kit-config.sh -- the single resolver for kit.toml config (config-layer).
#
# WHY: every runtime knob in the kit is an ad-hoc env var resolved in a different
# place. This is the ONE resolver (mirrors lib/telemetry/kit-log-dir.sh, "one place
# the default lives") that reads the layered config: the kit-root default kit.toml,
# overridden by an operator-owned kit.toml under the operator's XDG config dir, in turn
# overridden by a per-project .kit.toml (project WINS). Commands and feature libs
# call kit_config_get AT INVOCATION. Hot spine hooks NEVER source this -- that keeps
# the no-runtime-manifest-read lint green (it forbids HOOK reads, not command reads).
#
# Contract (safe under set -euo pipefail, no output on load):
#   kit_config_get <section.key> [default]   -> resolved value (project > operator > kit-root > default)
#   kit_config_root                           -> the kit-root kit.toml path in use
#   kit_config_operator                       -> the operator kit.toml path in use
#   kit_config_project                        -> the project .kit.toml path in use
#
# Precedence sources (each overridable for tests, a missing file is skipped silently):
#   project : $KIT_PROJECT_ROOT/.kit.toml   (default: $PWD/.kit.toml)
#   operator: $KIT_CONFIG_OPERATOR/kit.toml (default: ${XDG_CONFIG_HOME:-$HOME/.config}/dwarves-kit/kit.toml)
#   kit-root: $KIT_CONFIG_ROOT/kit.toml     (default: ${DWARVES_KIT:-$HOME/.claude/dwarves-kit}/kit.toml)
#
# WHY the operator file exists: keys such as wrap.activity_log and precedent.registry name
# per-operator paths. The kit checkout is a shared, upgradable install, so it is the wrong
# home for one operator's paths. The operator file carries them across kit upgrades.
#
# Idempotent-source guard.
[ -n "${_KIT_CONFIG_SOURCED:-}" ] && return 0 2>/dev/null || true
_KIT_CONFIG_SOURCED=1

kit_config_root()     { printf '%s' "${KIT_CONFIG_ROOT:-${DWARVES_KIT:-$HOME/.claude/dwarves-kit}}/kit.toml"; }
kit_config_operator() { printf '%s' "${KIT_CONFIG_OPERATOR:-${XDG_CONFIG_HOME:-$HOME/.config}/dwarves-kit}/kit.toml"; }
kit_config_project()  { printf '%s' "${KIT_PROJECT_ROOT:-$PWD}/.kit.toml"; }

# _kit_toml_get <file> <section> <key> -- print the raw value of [section].key, empty if absent.
# Line-oriented, no TOML lib (matches install.sh's grep/sed style). Handles: [section]
# headers, `#` full-line and inline comments, surrounding whitespace, and one layer of
# double-quotes. Values themselves must not contain a literal `#` (our schema never does).
_kit_toml_get() {
  local file="$1" section="$2" key="$3"
  [ -f "$file" ] || return 0
  awk -v sec="$section" -v k="$key" '
    { line = $0 }
    line ~ /^[[:space:]]*#/ { next }                      # full-line comment
    line ~ /^[[:space:]]*\[/ {                            # section header
      h = line; sub(/#.*/, "", h); gsub(/[][[:space:]]/, "", h)
      insec = (h == sec); next
    }
    insec {
      sub(/#.*/, "", line)                                # strip inline comment
      if (line ~ ("^[[:space:]]*" k "[[:space:]]*=")) {
        sub(/^[^=]*=[[:space:]]*/, "", line)              # drop `key =`
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)     # trim
        gsub(/^"|"$/, "", line)                           # unquote
        print line; exit
      }
    }
  ' "$file"
}

# kit_config_get <section.key> [default] -- project override, else operator, else kit-root,
# else default. A missing file at any layer is skipped silently.
kit_config_get() {
  local dotkey="$1" def="${2:-}" section key v
  section="${dotkey%%.*}"; key="${dotkey#*.}"
  v="$(_kit_toml_get "$(kit_config_project)" "$section" "$key")"
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  v="$(_kit_toml_get "$(kit_config_operator)" "$section" "$key")"
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  v="$(_kit_toml_get "$(kit_config_root)" "$section" "$key")"
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  printf '%s' "$def"
}

# kit_config_get_root <section.key> [default] -- operator, else kit-root, else default. The
# project overlay is SKIPPED. For security-bearing keys a committed project .kit.toml must
# NOT be able to set: a project toml rides inside an untrusted PR, so a key that selects a
# runner host, a secret ref, or a dispatch target must resolve from an operator-owned file
# alone. Same read-model the kit already applies to enabled_agent_clis. The operator file
# carries the same trust as the kit root: it sits on the operator's own machine and never
# rides inside a pull request.
kit_config_get_root() {
  local dotkey="$1" def="${2:-}" section key v
  section="${dotkey%%.*}"; key="${dotkey#*.}"
  v="$(_kit_toml_get "$(kit_config_operator)" "$section" "$key")"
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  v="$(_kit_toml_get "$(kit_config_root)" "$section" "$key")"
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  printf '%s' "$def"
}

# --- self-test: `bash lib/config/kit-config.sh selftest` (ponytail: one runnable check) ---
# EXECUTED-directly guard: a sourced file inherits the CALLER's "$@". Without this, any
# verb-taking CLI that sources this lib and is invoked with `selftest` (e.g. `queue.sh
# selftest`) silently ran this suite AND inherited its `set -euo pipefail` + EXIT trap, into
# a launcher that deliberately runs without -e. Reproduced and fixed (review finding).
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = "selftest" ]; then
  set -euo pipefail
  d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
  mkdir -p "$d/root" "$d/proj" "$d/op"
  cat > "$d/root/kit.toml" <<'TOML'
[ledger]
location = "shared"   # inline comment must be stripped
[mega]
wave_cap = 2
# over_test = false   # full-comment line must be ignored
TOML
  cat > "$d/proj/.kit.toml" <<'TOML'
[ledger]
location = "isolated"
[gauntlet]
runner_host = "evil-host"
[knowledge]
root = "/tmp/proj"
TOML
  cat > "$d/op/kit.toml" <<'TOML'
[ledger]
location = "operator"
[mega]
wave_cap = 9
[gauntlet]
runner_host = "operator-host"
[knowledge]
root = "/tmp/op"
TOML
  # The base cases pin the operator layer at a path that does not exist, so the operator's
  # REAL ~/.config/dwarves-kit/kit.toml can never leak into this suite on a live machine.
  export KIT_CONFIG_ROOT="$d/root" KIT_PROJECT_ROOT="$d/proj" KIT_CONFIG_OPERATOR="$d/none"
  fail=0
  chk() { [ "$2" = "$3" ] && echo "ok   $1" || { echo "FAIL $1: got [$2] want [$3]"; fail=1; }; }
  chk "project overrides kit-root"      "$(kit_config_get ledger.location)"    "isolated"
  chk "kit-root default when no proj"   "$(kit_config_get mega.wave_cap)"      "2"
  chk "inline comment stripped"         "$(KIT_PROJECT_ROOT=/nonexistent kit_config_get ledger.location)" "shared"
  chk "commented key -> caller default" "$(kit_config_get mega.over_test off)" "off"
  chk "missing key -> caller default"   "$(kit_config_get nope.nope fallback)" "fallback"
  chk "missing section -> empty"        "$(kit_config_get ghost.key)"          ""
  # root-only read: a malicious project .kit.toml MUST NOT win a security-bearing key.
  chk "root-only ignores project override" "$(kit_config_get_root gauntlet.runner_host local)" "local"
  chk "root-only reads kit-root value"     "$(kit_config_get_root mega.wave_cap)"               "2"
  chk "root-only falls to caller default"  "$(kit_config_get_root gauntlet.nope fallback)"      "fallback"
  # negative control: the LEGACY accessor still lets the project override through (proves
  # the two accessors differ, and that the project toml IS being read).
  chk "legacy accessor still overridable"  "$(kit_config_get gauntlet.runner_host local)"       "evil-host"
  # operator overlay: as trusted as the kit root (it sits on the operator's machine, never in
  # a PR), so it wins the root-only read; the project toml still wins the plain read.
  chk "operator wins kit-root on _root" \
    "$(KIT_CONFIG_OPERATOR="$d/op" kit_config_get_root mega.wave_cap)"                          "9"
  chk "operator wins kit-root on get" \
    "$(KIT_CONFIG_OPERATOR="$d/op" KIT_PROJECT_ROOT=/nonexistent kit_config_get ledger.location)" "operator"
  chk "project still wins operator on get" \
    "$(KIT_CONFIG_OPERATOR="$d/op" kit_config_get ledger.location)"                             "isolated"
  chk "project never reaches _root past operator" \
    "$(KIT_CONFIG_OPERATOR="$d/op" kit_config_get_root ledger.location)"                        "operator"
  chk "missing operator file falls through" \
    "$(KIT_CONFIG_OPERATOR="$d/none" kit_config_get_root mega.wave_cap)"                        "2"
  chk "KIT_CONFIG_OPERATOR redirects the file" \
    "$(KIT_CONFIG_OPERATOR="$d/none" kit_config_get_root gauntlet.runner_host local)"           "local"
  # SPEC-249 TASK-001: [knowledge] root is a root-only key like gauntlet.runner_host --
  # a project .kit.toml MUST NOT be able to redirect where knowledge notes land.
  chk "root-only knowledge.root: operator wins over kit-root, project ignored" \
    "$(KIT_CONFIG_OPERATOR="$d/op" kit_config_get_root knowledge.root)"                         "/tmp/op"
  chk "root-only knowledge.root: empty with no operator/kit-root value, even though project sets it" \
    "$(kit_config_get_root knowledge.root)"                                                     ""
  [ "$fail" = 0 ] && echo "PASS kit-config selftest" || { echo "SELFTEST FAILED"; exit 1; }
fi
