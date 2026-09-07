#!/usr/bin/env bash
# test-config-seams.sh -- SPEC-249 TASK-002: `bin/config seams [--check]`, the cross-kit
# seam report over the "## Seams" join table (lib/config/config.sh `_seam_rows` /
# `_seam_resolve` / `cmd_seams`).
#
# Two registries are exercised: the LIVE lib/config/module-registry.md (its five real seam
# rows: wrap.before, wrap.activity_log, precedent.registry, knowledge.root, PROSE_RAG_BIN),
# and a small FIXTURE registry (CONFIG_REGISTRY_FILE is overridable, same as
# tests/test-config-registry.sh's own fixtures) that adds a malformed row and an unknown-kind
# row -- neither of which the live registry can carry (it is lint-guarded by
# test-config-registry.sh AC6/AC7).
#
# KIT_CONFIG_OPERATOR is always pinned at a path that does not exist and KIT_CONFIG_ROOT at a
# fresh temp dir per case, so a real operator ~/.config/dwarves-kit/kit.toml on the host
# machine can never leak a personal path into this suite's output (mirrors
# tests/test-wrap.sh's own pin).
#
# Run: bash tests/test-config-seams.sh

set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_BIN="$KIT_DIR/bin/config"

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
chk() {
  TOTAL=$((TOTAL+1))
  if [ "$2" -eq 0 ] 2>/dev/null; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1))
  else echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL+1)); fi
}
chk_has() { chk "$1" "$({ trap '' PIPE; printf '%s' "$2" 2>/dev/null || :; } | grep -qF -- "$3"; echo $?)"; }
chk_no()  { chk "$1" "$({ trap '' PIPE; printf '%s' "$2" 2>/dev/null || :; } | grep -qF -- "$3" && echo 1 || echo 0)"; }

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/dk-config-seams-test.XXXXXX")"
TMPD="$(cd "$TMPD" && pwd)"
trap 'rm -rf "$TMPD"' EXIT

HOME_DIR="$TMPD/home"; mkdir -p "$HOME_DIR"
OUTSIDE_DIR="$TMPD/outside"; mkdir -p "$OUTSIDE_DIR"
ROOT_DIR="$TMPD/root"; mkdir -p "$ROOT_DIR"
PROJ_DIR="$TMPD/proj"; mkdir -p "$PROJ_DIR"
NO_OPERATOR="$TMPD/no-operator-config"   # never created

write_root_toml() { printf '%s\n' "$1" > "$ROOT_DIR/kit.toml"; }
write_root_toml ""   # empty by default; cases that need a value overwrite it

# --------------------------------------------------------------------------- fixture registry

FIXTURE_REGISTRY="$TMPD/fixture-registry.md"
cat > "$FIXTURE_REGISTRY" <<'EOF'
# fixture module-registry.md for test-config-seams.sh

## Env <-> key registry

### test

| Env var | kit.toml key | Default | Status | Module | Doc |
|---|---|---|---|---|---|
| - | test.skill_seam | `""` | [consumer] | test | fixture skill-kind seam key. |
| - | test.dir_seam | `""` | [consumer] | test | fixture dir-kind seam key. |

## Allowlist

| Token | Why excluded |
|---|---|

## Seams

| Key | Kind | Filled by |
|---|---|---|
| test.skill_seam | skill | fixture |
| test.dir_seam | dir | fixture |
| test.malformed_seam | dir |
| test.unknown_kind_seam | bogus | fixture |
| test.ghost_seam | dir | fixture |

## Known gaps

| Key | Kind | Filled by |
|---|---|---|
| test.after_heading_seam | dir | should-never-appear |
EOF

# test.ghost_seam is deliberately absent from the registry table above: it exercises
# _seam_resolve's _find_row failure branch (a well-formed seam row naming an unregistered key).
# The "## Known gaps" table mirrors the live registry's own trailing section: its rows must
# never be read as seams.

# --------------------------------------------------------------------------- case 1: all-default

write_root_toml ""
OUT1="$(HOME="$HOME_DIR" KIT_CONFIG_ROOT="$ROOT_DIR" KIT_CONFIG_OPERATOR="$NO_OPERATOR" \
  KIT_PROJECT_ROOT="$PROJ_DIR" env -u PROSE_RAG_BIN -u KIT_SKILL_DIRS -u CLAUDE_PLUGIN_ROOT \
  PATH="/usr/bin:/bin" bash "$CONFIG_BIN" seams)"
RC1=$?
chk "all-default: exits 0" "$RC1"
ROWCOUNT1="$(printf '%s\n' "$OUT1" | tail -n +2 | grep -c .)"
chk "all-default report has five rows" "$([ "$ROWCOUNT1" -eq 5 ] && echo 0 || echo 1)"
chk_has "all-default: wrap.before shows default" "$OUT1" "wrap.before"
chk_has "all-default: PROSE_RAG_BIN shows absent (nothing on the stripped PATH)" "$(printf '%s\n' "$OUT1" | grep '^PROSE_RAG_BIN')" "absent"

# --------------------------------------------------------------------------- case 2: skill filled + resolving

mkdir -p "$HOME_DIR/skills-a/myskill"
: > "$HOME_DIR/skills-a/myskill/SKILL.md"
write_root_toml $'[test]\nskill_seam = "myskill"'
OUT2="$(HOME="$HOME_DIR" KIT_CONFIG_ROOT="$ROOT_DIR" KIT_CONFIG_OPERATOR="$NO_OPERATOR" \
  KIT_PROJECT_ROOT="$PROJ_DIR" CONFIG_REGISTRY_FILE="$FIXTURE_REGISTRY" \
  KIT_SKILL_DIRS="$HOME_DIR/skills-a" bash "$CONFIG_BIN" seams | grep '^test.skill_seam')"
chk_has "skill filled and resolving under a KIT_SKILL_DIRS dir inside HOME" "$OUT2" "filled"

# --------------------------------------------------------------------------- case 3: skill filled + missing

write_root_toml $'[test]\nskill_seam = "ghost-skill"'
OUT3="$(HOME="$HOME_DIR" KIT_CONFIG_ROOT="$ROOT_DIR" KIT_CONFIG_OPERATOR="$NO_OPERATOR" \
  KIT_PROJECT_ROOT="$PROJ_DIR" CONFIG_REGISTRY_FILE="$FIXTURE_REGISTRY" \
  KIT_SKILL_DIRS="$HOME_DIR/skills-a" bash "$CONFIG_BIN" seams | grep '^test.skill_seam')"
chk_has "skill filled and missing -> unresolved" "$OUT3" "unresolved"

# --------------------------------------------------------------------------- case 4: KIT_SKILL_DIRS outside HOME dropped

mkdir -p "$OUTSIDE_DIR/skills-b/myskill"
: > "$OUTSIDE_DIR/skills-b/myskill/SKILL.md"
write_root_toml $'[test]\nskill_seam = "myskill"'
OUT4="$(HOME="$HOME_DIR" KIT_CONFIG_ROOT="$ROOT_DIR" KIT_CONFIG_OPERATOR="$NO_OPERATOR" \
  KIT_PROJECT_ROOT="$PROJ_DIR" CONFIG_REGISTRY_FILE="$FIXTURE_REGISTRY" \
  KIT_SKILL_DIRS="$OUTSIDE_DIR/skills-b" bash "$CONFIG_BIN" seams | grep '^test.skill_seam')"
chk_has "a KIT_SKILL_DIRS entry outside HOME is ignored (skill there reads unresolved)" "$OUT4" "unresolved"

# --------------------------------------------------------------------------- case 5: dir filled + existing

mkdir -p "$HOME_DIR/a-real-dir"
write_root_toml "[test]
dir_seam = \"$HOME_DIR/a-real-dir\""
OUT5="$(HOME="$HOME_DIR" KIT_CONFIG_ROOT="$ROOT_DIR" KIT_CONFIG_OPERATOR="$NO_OPERATOR" \
  KIT_PROJECT_ROOT="$PROJ_DIR" CONFIG_REGISTRY_FILE="$FIXTURE_REGISTRY" \
  bash "$CONFIG_BIN" seams | grep '^test.dir_seam')"
chk_has "dir filled and existing -> filled" "$OUT5" "filled"

# --------------------------------------------------------------------------- case 6: dir filled + missing

write_root_toml "[test]
dir_seam = \"$HOME_DIR/no-such-dir\""
OUT6="$(HOME="$HOME_DIR" KIT_CONFIG_ROOT="$ROOT_DIR" KIT_CONFIG_OPERATOR="$NO_OPERATOR" \
  KIT_PROJECT_ROOT="$PROJ_DIR" CONFIG_REGISTRY_FILE="$FIXTURE_REGISTRY" \
  bash "$CONFIG_BIN" seams | grep '^test.dir_seam')"
chk_has "dir filled and missing -> unresolved" "$OUT6" "unresolved"

# --------------------------------------------------------------------------- case 7: PROSE_RAG_BIN absent

write_root_toml ""
OUT7="$(HOME="$HOME_DIR" KIT_CONFIG_ROOT="$ROOT_DIR" KIT_CONFIG_OPERATOR="$NO_OPERATOR" \
  KIT_PROJECT_ROOT="$PROJ_DIR" env -u PROSE_RAG_BIN PATH="/usr/bin:/bin" \
  bash "$CONFIG_BIN" seams | grep '^PROSE_RAG_BIN')"
chk_has "PROSE_RAG_BIN unset and empty PATH -> absent" "$OUT7" "absent"

# --------------------------------------------------------------------------- case 8: PROSE_RAG_BIN non-executable

: > "$TMPD/not-executable"
chmod -x "$TMPD/not-executable"
OUT8="$(HOME="$HOME_DIR" KIT_CONFIG_ROOT="$ROOT_DIR" KIT_CONFIG_OPERATOR="$NO_OPERATOR" \
  KIT_PROJECT_ROOT="$PROJ_DIR" PROSE_RAG_BIN="$TMPD/not-executable" \
  bash "$CONFIG_BIN" seams | grep '^PROSE_RAG_BIN')"
chk_has "PROSE_RAG_BIN set to a non-executable file -> unresolved" "$OUT8" "unresolved"

# --------------------------------------------------------------------------- case 8b: PROSE_RAG_BIN is a directory
# [ -x ] is true for a searchable directory, so the check must also require a regular file.
OUT8B="$(HOME="$HOME_DIR" KIT_CONFIG_ROOT="$ROOT_DIR" KIT_CONFIG_OPERATOR="$NO_OPERATOR" \
  KIT_PROJECT_ROOT="$PROJ_DIR" PROSE_RAG_BIN="$TMPD" \
  bash "$CONFIG_BIN" seams | grep '^PROSE_RAG_BIN')"
chk_has "PROSE_RAG_BIN set to a directory -> unresolved" "$OUT8B" "unresolved"

# --------------------------------------------------------------------------- case 9: prose-rag on PATH

mkdir -p "$TMPD/bin"
cat > "$TMPD/bin/prose-rag" <<'EOF'
#!/usr/bin/env bash
echo "fixture prose-rag"
EOF
chmod +x "$TMPD/bin/prose-rag"
OUT9="$(HOME="$HOME_DIR" KIT_CONFIG_ROOT="$ROOT_DIR" KIT_CONFIG_OPERATOR="$NO_OPERATOR" \
  KIT_PROJECT_ROOT="$PROJ_DIR" env -u PROSE_RAG_BIN PATH="$TMPD/bin:/usr/bin:/bin" \
  bash "$CONFIG_BIN" seams | grep '^PROSE_RAG_BIN')"
chk_has "a fake executable prose-rag on the temp PATH -> filled" "$OUT9" "filled"
chk_has "prose-rag VALUE is the PATH-resolved binary" "$OUT9" "$TMPD/bin/prose-rag"

# --------------------------------------------------------------------------- case 10: project .kit.toml ignored

printf '[knowledge]\nroot = "/tmp/never"\n' > "$PROJ_DIR/.kit.toml"
write_root_toml ""
OUT10="$(HOME="$HOME_DIR" KIT_CONFIG_ROOT="$ROOT_DIR" KIT_CONFIG_OPERATOR="$NO_OPERATOR" \
  KIT_PROJECT_ROOT="$PROJ_DIR" bash "$CONFIG_BIN" seams)"
chk_no "a project .kit.toml [knowledge] root value never appears in the output" "$OUT10" "/tmp/never"
rm -f "$PROJ_DIR/.kit.toml"

# --------------------------------------------------------------------------- case 11: malformed row + unknown kind

OUT11="$(HOME="$HOME_DIR" KIT_CONFIG_ROOT="$ROOT_DIR" KIT_CONFIG_OPERATOR="$NO_OPERATOR" \
  KIT_PROJECT_ROOT="$PROJ_DIR" CONFIG_REGISTRY_FILE="$FIXTURE_REGISTRY" \
  bash "$CONFIG_BIN" seams)"
chk_has "malformed row (fewer than three cells): VALUE is (malformed row)" \
  "$(printf '%s\n' "$OUT11" | grep '^test.malformed_seam')" "(malformed row)"
chk_has "malformed row status is unresolved" \
  "$(printf '%s\n' "$OUT11" | grep '^test.malformed_seam')" "unresolved"
chk_has "unknown kind: VALUE is (unknown kind)" \
  "$(printf '%s\n' "$OUT11" | grep '^test.unknown_kind_seam')" "(unknown kind)"
chk_has "unknown kind status is unresolved" \
  "$(printf '%s\n' "$OUT11" | grep '^test.unknown_kind_seam')" "unresolved"

# --------------------------------------------------------------------------- case 12: --check

HOME="$HOME_DIR" KIT_CONFIG_ROOT="$ROOT_DIR" KIT_CONFIG_OPERATOR="$NO_OPERATOR" \
  KIT_PROJECT_ROOT="$PROJ_DIR" CONFIG_REGISTRY_FILE="$FIXTURE_REGISTRY" \
  bash "$CONFIG_BIN" seams --check >/dev/null 2>&1
chk "--check exits 1 when a row is unresolved (fixture always carries one)" "$([ $? -eq 1 ] && echo 0 || echo 1)"

write_root_toml ""
HOME="$HOME_DIR" KIT_CONFIG_ROOT="$ROOT_DIR" KIT_CONFIG_OPERATOR="$NO_OPERATOR" \
  KIT_PROJECT_ROOT="$PROJ_DIR" env -u PROSE_RAG_BIN -u KIT_SKILL_DIRS -u CLAUDE_PLUGIN_ROOT \
  PATH="/usr/bin:/bin" bash "$CONFIG_BIN" seams --check >/dev/null 2>&1
chk "--check exits 0 when every live-registry row is default/absent, none unresolved" "$?"

# --------------------------------------------------------------------------- case 13: missing registry

CONFIG_REGISTRY_FILE="$TMPD/does-not-exist.md" bash "$CONFIG_BIN" seams >/dev/null 2>&1
chk "missing registry file exits 1, same as config list" "$([ $? -eq 1 ] && echo 0 || echo 1)"

# --------------------------------------------------------------------------- case 14: CLAUDE_PLUGIN_ROOT unset

OUT14="$(HOME="$HOME_DIR" KIT_CONFIG_ROOT="$ROOT_DIR" KIT_CONFIG_OPERATOR="$NO_OPERATOR" \
  KIT_PROJECT_ROOT="$PROJ_DIR" CONFIG_REGISTRY_FILE="$FIXTURE_REGISTRY" \
  env -u CLAUDE_PLUGIN_ROOT -u KIT_SKILL_DIRS bash "$CONFIG_BIN" seams 2>&1)"
RC14=$?
chk "CLAUDE_PLUGIN_ROOT unset does not abort (default skill dir list is HOME/.claude/skills alone)" "$RC14"
chk_no "no unbound-variable error on stderr" "$OUT14" "unbound variable"

# --------------------------------------------------------------------------- case 15: ghost seam key

chk_has "a seam row whose Key has no registry row: VALUE is (malformed row)" \
  "$(printf '%s\n' "$OUT11" | grep '^test.ghost_seam')" "(malformed row)"
chk_has "a seam row whose Key has no registry row: status is unresolved" \
  "$(printf '%s\n' "$OUT11" | grep '^test.ghost_seam')" "unresolved"

# --------------------------------------------------------------------------- case 16: seam window stops at the next heading

chk_no "a pipe table under a heading AFTER ## Seams is never read as a seam row" \
  "$OUT11" "test.after_heading_seam"
FIXROWS="$(printf '%s\n' "$OUT11" | tail -n +2 | grep -c .)"
chk "the fixture report prints exactly its five ## Seams rows" \
  "$([ "$FIXROWS" -eq 5 ] && echo 0 || echo 1)"

# --------------------------------------------------------------------------- case 17: dir target outside HOME

# The consumers (`wrap log`, `wrap knowledge-root`) refuse a target whose realpath sits
# outside $HOME, so an advisor that called such a target `filled` would exit 0 on a root the
# consumer rejects. Same directory, inside HOME, must still read `filled`.
mkdir -p "$OUTSIDE_DIR/knowledge"
write_root_toml "[knowledge]
root = \"$OUTSIDE_DIR/knowledge\""
OUT17="$(HOME="$HOME_DIR" KIT_CONFIG_ROOT="$ROOT_DIR" KIT_CONFIG_OPERATOR="$NO_OPERATOR" \
  KIT_PROJECT_ROOT="$PROJ_DIR" bash "$CONFIG_BIN" seams | grep '^knowledge.root')"
chk_has "an existing dir OUTSIDE HOME set as knowledge.root -> unresolved" "$OUT17" "unresolved"

HOME="$HOME_DIR" KIT_CONFIG_ROOT="$ROOT_DIR" KIT_CONFIG_OPERATOR="$NO_OPERATOR" \
  KIT_PROJECT_ROOT="$PROJ_DIR" env -u PROSE_RAG_BIN -u KIT_SKILL_DIRS -u CLAUDE_PLUGIN_ROOT \
  PATH="/usr/bin:/bin" bash "$CONFIG_BIN" seams --check >/dev/null 2>&1
chk "--check exits 1 on that out-of-HOME knowledge.root" "$([ $? -eq 1 ] && echo 0 || echo 1)"

mkdir -p "$HOME_DIR/knowledge"
write_root_toml "[knowledge]
root = \"$HOME_DIR/knowledge\""
OUT17B="$(HOME="$HOME_DIR" KIT_CONFIG_ROOT="$ROOT_DIR" KIT_CONFIG_OPERATOR="$NO_OPERATOR" \
  KIT_PROJECT_ROOT="$PROJ_DIR" bash "$CONFIG_BIN" seams | grep '^knowledge.root')"
chk_has "the same dir INSIDE HOME set as knowledge.root -> filled" "$OUT17B" "filled"
write_root_toml ""

# --------------------------------------------------------------------------- case 19: file target that is a symlink

# `[ -f ]` follows a leaf symlink, so a symlink under HOME whose target is a regular file used
# to read `filled` while `wrap log` refuses it outright (a symlink at a write target redirects
# the append). The advisor must agree with the consumer.
: > "$OUTSIDE_DIR/real-activity.md"
ln -s "$OUTSIDE_DIR/real-activity.md" "$HOME_DIR/linked-activity.md"
write_root_toml "[wrap]
activity_log = \"$HOME_DIR/linked-activity.md\""
OUT19="$(HOME="$HOME_DIR" KIT_CONFIG_ROOT="$ROOT_DIR" KIT_CONFIG_OPERATOR="$NO_OPERATOR" \
  KIT_PROJECT_ROOT="$PROJ_DIR" bash "$CONFIG_BIN" seams | grep '^wrap.activity_log')"
chk_has "a file target that is a symlink under HOME -> unresolved" "$OUT19" "unresolved"

: > "$HOME_DIR/real-activity.md"
write_root_toml "[wrap]
activity_log = \"$HOME_DIR/real-activity.md\""
OUT19B="$(HOME="$HOME_DIR" KIT_CONFIG_ROOT="$ROOT_DIR" KIT_CONFIG_OPERATOR="$NO_OPERATOR" \
  KIT_PROJECT_ROOT="$PROJ_DIR" bash "$CONFIG_BIN" seams | grep '^wrap.activity_log')"
chk_has "a plain regular file under HOME -> filled" "$OUT19B" "filled"
write_root_toml ""

# --------------------------------------------------------------------------- case 18: forged env-var cell never executes

# ATTACK SHAPE: bash evaluates an array subscript during indirect expansion, so an env-var
# cell of `EVIL[$(cmd)]` used to run cmd on `"${!cell:-}"` (bash 3.2 included).
# CONFIG_REGISTRY_FILE is an unvalidated env override, so a forged registry is
# attacker-controlled input reaching both `config seams` and `config list`.
CANARY="$TMPD/canary"
FORGED_REGISTRY="$TMPD/forged-registry.md"
cat > "$FORGED_REGISTRY" <<EOF
# forged module-registry.md for test-config-seams.sh

## Env <-> key registry

### test

| Env var | kit.toml key | Default | Status | Module | Doc |
|---|---|---|---|---|---|
| EVIL[\$(touch $CANARY)] | env-only | (none) | [impl] | test | forged env-var cell. |

## Allowlist

| Token | Why excluded |
|---|---|

## Seams

| Key | Kind | Filled by |
|---|---|---|
| EVIL[\$(touch $CANARY)] | dir | forged |
EOF

rm -f "$CANARY"
OUT18="$(HOME="$HOME_DIR" KIT_CONFIG_ROOT="$ROOT_DIR" KIT_CONFIG_OPERATOR="$NO_OPERATOR" \
  KIT_PROJECT_ROOT="$PROJ_DIR" CONFIG_REGISTRY_FILE="$FORGED_REGISTRY" \
  bash "$CONFIG_BIN" seams 2>&1)"
chk "a forged env-var cell never executes its subscript during config seams" \
  "$([ -e "$CANARY" ] && echo 1 || echo 0)"
chk_has "the forged seam row reads unresolved" "$OUT18" "unresolved"
chk_has "the forged seam row VALUE is (malformed row)" "$OUT18" "(malformed row)"

rm -f "$CANARY"
HOME="$HOME_DIR" KIT_CONFIG_ROOT="$ROOT_DIR" KIT_CONFIG_OPERATOR="$NO_OPERATOR" \
  KIT_PROJECT_ROOT="$PROJ_DIR" CONFIG_REGISTRY_FILE="$FORGED_REGISTRY" \
  bash "$CONFIG_BIN" list >/dev/null 2>&1
chk "a forged env-var cell never executes its subscript during config list" \
  "$([ -e "$CANARY" ] && echo 1 || echo 0)"

# --------------------------------------------------------------------------- case 20: relative seam path never resolves against cwd

# A `file`/`dir` seam value that is not absolute and not `~`-prefixed must never be
# resolved against the invoking shell's cwd: `_seam_target_resolves` shells out to `cd
# "$(dirname "$val")"`, which for a relative value used to resolve against wherever
# `config seams` happened to be invoked from -- a raw operator value like "sub/rel.md"
# could then read `filled` purely by accident of cwd. Put the target file under HOME so
# the buggy cwd-relative resolution would ALSO pass the HOME fence and read `filled`;
# otherwise this case would pass for the wrong reason (the HOME fence rejecting it).
CWD_A="$HOME_DIR/cwd-a"; mkdir -p "$CWD_A/sub"; : > "$CWD_A/sub/rel.md"
CWD_B="$HOME_DIR/cwd-b"; mkdir -p "$CWD_B/sub"; : > "$CWD_B/sub/rel.md"
write_root_toml '[wrap]
activity_log = "sub/rel.md"'
OUT20A="$(cd "$CWD_A" && HOME="$HOME_DIR" KIT_CONFIG_ROOT="$ROOT_DIR" KIT_CONFIG_OPERATOR="$NO_OPERATOR" \
  KIT_PROJECT_ROOT="$PROJ_DIR" bash "$CONFIG_BIN" seams | grep '^wrap.activity_log')"
chk_has "a relative seam value from cwd A never resolves against cwd -> unresolved" "$OUT20A" "unresolved"
chk_has "the raw relative value is reported verbatim, not a cwd-resolved path" "$OUT20A" "sub/rel.md"

OUT20B="$(cd "$CWD_B" && HOME="$HOME_DIR" KIT_CONFIG_ROOT="$ROOT_DIR" KIT_CONFIG_OPERATOR="$NO_OPERATOR" \
  KIT_PROJECT_ROOT="$PROJ_DIR" bash "$CONFIG_BIN" seams | grep '^wrap.activity_log')"
chk_has "the same relative value from a DIFFERENT cwd still reads unresolved" "$OUT20B" "unresolved"
STATUS20A="$(printf '%s' "$OUT20A" | awk '{print $4}')"
STATUS20B="$(printf '%s' "$OUT20B" | awk '{print $4}')"
chk "status is identical across the two cwds" "$([ "$STATUS20A" = "$STATUS20B" ] && echo 0 || echo 1)"
write_root_toml ""

# --------------------------------------------------------------------------- case 21: zero seam rows

# A registry with the "## Seams" heading missing entirely (or present but empty) used to
# print just the header and exit 0 under --check -- silently indistinguishable from "every
# seam resolved". `_seam_rows` yields nothing for a registry with no such heading.
NO_SEAMS_REGISTRY="$TMPD/no-seams-registry.md"
cat > "$NO_SEAMS_REGISTRY" <<'EOF'
# fixture module-registry.md with no ## Seams heading

## Env <-> key registry

### test

| Env var | kit.toml key | Default | Status | Module | Doc |
|---|---|---|---|---|---|
| - | test.key | `""` | [consumer] | test | fixture key. |

## Allowlist

| Token | Why excluded |
|---|---|
EOF
OUT21="$(CONFIG_REGISTRY_FILE="$NO_SEAMS_REGISTRY" bash "$CONFIG_BIN" seams)"
chk "zero seam rows: exits 0 without --check" "$?"
chk_has "zero seam rows: prints the explicit no-rows line" "$OUT21" "(no seam rows: ## Seams table missing or empty)"

CONFIG_REGISTRY_FILE="$NO_SEAMS_REGISTRY" bash "$CONFIG_BIN" seams --check >/dev/null 2>&1
chk "zero seam rows: --check exits 1" "$([ $? -eq 1 ] && echo 0 || echo 1)"

# --------------------------------------------------------------------------- bonus: unknown flag

bash "$CONFIG_BIN" seams --bogus >/dev/null 2>&1
chk "unknown flag is a usage error (exit 64)" "$([ $? -eq 64 ] && echo 0 || echo 1)"

echo ""
echo "=== $PASS/$TOTAL passed ==="
[ "$FAIL" -eq 0 ]
