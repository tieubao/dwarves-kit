#!/usr/bin/env bash
# proof-ledger.sh -- the proof-of-done ship/merge gate (diff-keyed, spec-independent).
#
# Turns the proof-of-done convention (docs/verification/README.md) from advice into a
# wall: a load-bearing change cannot ship/merge without a matching proof-of-done entry.
# Unlike the lane gate (gate-ledger.sh), this keys off the BRANCH DIFF, not a spec, so it
# fires the same whether the work came through /kit:execute or a freeform /goal loop.
#
# A change's PROOF CLASS comes from its diff (consistent with lib/gate/proof-gate.sh):
#   stateful   -- deploy / migration / data / persistent-state paths or commit subjects.
#                 Pass = a fresh verification entry with a recorded run AND a rollback
#                 note (or [UNAVAILABLE: reason]).
#   behavioral -- changes behavior (code/lib/commands/agents/hooks/tests).
#                 Pass = a fresh verification entry with a green run AND a NEGATIVE CONTROL.
#   inert      -- docs / comments / cosmetic (markdown-only diff). Pass (no ritual).
#
# "Fresh" = the branch diff itself added/modified the docs/verification/*.md entry, so an
# old proof from unrelated work does not satisfy a new change.
#
# An explicit, LOGGED override always exists (never a silent bypass).
#
# FAILS OPEN on genuine ambiguity (no repo, empty diff, no base, missing tooling): a gate
# bug must never block unrelated work. Exit 1 from `check` = block.
#
# Subcommands:
#   classify <root> <base>            print inert|behavioral|stateful for the branch diff
#   check    <root> <base> [slug]     exit 0 if the proof requirement is met (or overridden
#                                     or inert); else exit 1 + what is missing
#   override <slug> <reason>          log a human override for this branch (leaves a trace)
#   is-overridden <slug>              exit 0 if an override is logged
#   negctl   <root> <test-cmd> <mutate-cmd>
#                                     forwards to lib/gate/negctl.sh (the mechanised negative
#                                     control; FAILS CLOSED, prints the block check() reads)
set -uo pipefail

PROOF_LEDGER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_ROOT="$(cd "$PROOF_LEDGER_DIR/.." && pwd)"  # the lib/ dir; cross-subsystem siblings resolve as "$LIB_ROOT/<subsystem>/<file>"
# Durable run-telemetry root (SPEC-097): resolve + one-time additive migration.
# shellcheck source=lib/telemetry/kit-log-dir.sh
source "$LIB_ROOT/telemetry/kit-log-dir.sh" || { echo "FATAL: lib/telemetry/kit-log-dir.sh missing or unreadable" >&2; exit 1; }
# The ONE append substrate (SPEC-182): the override write routes through ledger_append.
# shellcheck source=lib/ledger/ledger.sh
source "$LIB_ROOT/ledger/ledger.sh" || { echo "FATAL: lib/ledger/ledger.sh missing or unreadable" >&2; exit 1; }
# The config-layer resolver (SPEC-186 [ledger] wiring): the delivery-ratio thresholds below
# read through it. kit-log-dir.sh already sources it, but source directly too so this file's
# dependency on kit-config.sh is explicit, not incidental to another lib's internals.
# shellcheck source=lib/config/kit-config.sh
source "$LIB_ROOT/config/kit-config.sh" || { echo "FATAL: lib/config/kit-config.sh missing or unreadable" >&2; exit 1; }
kit_migrate_log_dir || true
LOG_DIR="$(kit_resolve_log_dir)" || exit 1
OVERRIDE_LOG="$LOG_DIR/proof-overrides.log"
OVERRIDE_STREAM="proof-overrides.log"

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
slugify() { printf '%s' "$1" | tr '/ ' '--' | tr -cd '[:alnum:]._-'; }

# changed files on the branch (base..HEAD), plus working-tree changes so a not-yet-
# committed proof still counts during an interactive build.
_changed() {
  local root="$1" base="$2"
  { git -C "$root" diff --name-only "$base"..HEAD 2>/dev/null
    git -C "$root" diff --name-only HEAD 2>/dev/null
    git -C "$root" diff --name-only --cached 2>/dev/null
    git -C "$root" ls-files --others --exclude-standard 2>/dev/null
  } | sort -u | sed '/^$/d'
}

_subjects() { git -C "$1" log "$2"..HEAD --format='%s' 2>/dev/null || true; }

classify() {
  local root="${1:-}" base="${2:-}"
  [ -n "$root" ] && [ -n "$base" ] || { echo "usage: classify <root> <base>" >&2; return 64; }
  local changed subjects blob
  changed="$(_changed "$root" "$base")"
  [ -n "$changed" ] || { echo inert; return 0; }   # empty diff: nothing to gate

  # inert FIRST: a markdown/txt-only diff is docs, never load-bearing, regardless of what the
  # commit subject says. Checking stateful keywords against the subject before this misread a
  # markdown-only "migrate" doc change as stateful (see SPEC-046, the classify-md-inert dogfood).
  if [ -z "$(printf '%s\n' "$changed" | grep -vE '\.(md|txt|markdown)$')" ]; then
    echo inert; return 0
  fi

  subjects="$(_subjects "$root" "$base")"
  blob="$(printf '%s\n%s' "$changed" "$subjects" | tr 'A-Z' 'a-z')"
  # stateful: deploy / migration / data / persistent-state signals (only reached when the diff
  # touches non-doc files, so a docs-only commit can no longer be misclassified by its subject).
  if printf '%s' "$blob" | grep -qE 'deploy|rollout|production|migrat|schema|data[ -]model|database|/db/|\bseed\b|backup|restore|persistent|drop .*(table|column)|alter table|data loss'; then
    echo stateful; return 0
  fi
  echo behavioral
}

# deployable <root> <base>: prints yes|no by mapping classify()'s existing "stateful" class
# to "deployable" (SG-07: deployable-done, ADR-0028/ADR-0025). PURELY ADDITIVE -- a relabel
# of classify()'s output for readability at call sites, never a second classifier. Does not
# read or touch classify()'s logic, and classify()/check() are otherwise byte-unchanged.
deployable() {
  local root="${1:-}" base="${2:-}"
  [ -n "$root" ] && [ -n "$base" ] || { echo "usage: deployable <root> <base>" >&2; return 64; }
  [ "$(classify "$root" "$base")" = "stateful" ] && echo yes || echo no
}

# delivery-ratio <root> <base>: ADVISORY. Splits this branch's ADDED lines into
# "real deliverable" (code + user-facing docs) vs "proof/ceremony" (proof-of-done,
# verification, specs, impl-notes, ADRs, tests) and flags the hollow signature: a lot
# of proof wrapped around a near-zero real change. NEVER blocks -- it is a heuristic
# with real false positives (a legit docs/research sub-goal is proof-heavy by design;
# a 1-line regex fix can be load-bearing), so it only PRINTS a NOTICE/THIN-WARN/OK line
# for a reviewer or `mega status` to surface. Rationale: the proof-of-done gate checks
# that proof EXISTS, not that delivery is PROPORTIONATE, so a thin docs/reconcile
# sub-goal can pass by padding proof (2026-07-05 delivery audit; ADR "delivery ratio").
# Precedence (SPEC-186 [ledger] wiring): env var > project .kit.toml > kit-root kit.toml >
# hardcoded default, via kit_config_get. An explicit env var still wins over config, same
# back-compat contract as kit_resolve_log_dir.
KIT_DELIVERY_RATIO_WARN="${KIT_DELIVERY_RATIO_WARN:-$(kit_config_get ledger.delivery_ratio_warn 3)}"    # proof >= N*real ...
KIT_DELIVERY_REAL_FLOOR="${KIT_DELIVERY_REAL_FLOOR:-$(kit_config_get ledger.delivery_real_floor 40)}"   # ... AND real < FLOOR => THIN-WARN
delivery_ratio() {
  local root="${1:-}" base="${2:-}"
  [ -n "$root" ] && [ -n "$base" ] || { echo "usage: delivery-ratio <root> <base>" >&2; return 64; }
  git -C "$root" rev-parse --verify -q "$base" >/dev/null 2>&1 \
    || { echo "real=0 proof=0 | SKIP: base '$base' is not a commit"; return 0; }
  local real=0 proof=0 add del path
  while IFS=$'\t' read -r add del path; do
    [ -n "$path" ] || continue
    [ "$add" = "-" ] && continue                            # binary file: no line count
    case "$path" in
      */proof-of-done.md|docs/proof/*|*/docs/proof/*|docs/verification/*|*/docs/verification/*|docs/specs/*|*/docs/specs/*|docs/implementation-notes/*|*/docs/implementation-notes/*|docs/runs/*|*/docs/runs/*|docs/decisions/*|*/docs/decisions/*|tests/*|*/tests/*)
        proof=$((proof+add)) ;;
      *.lock|*/uv.lock|*/package-lock.json|*/pnpm-lock.yaml|*/Cargo.lock|*/go.sum)
        : ;;                                                # generated lockfiles: ignore
      *)
        real=$((real+add)) ;;
    esac
  done < <(git -C "$root" diff --numstat "$base"..HEAD 2>/dev/null)

  local verdict
  if [ "$real" -eq 0 ]; then
    if [ "$proof" -gt 0 ]; then
      verdict="NOTICE: docs/proof-only branch -- expected for a docs/research sub-goal, SUSPECT for a build/rewrite/enforce claim"
    else
      verdict="OK: no added lines"
    fi
  elif [ "$proof" -ge $((KIT_DELIVERY_RATIO_WARN*real)) ] && [ "$real" -lt "$KIT_DELIVERY_REAL_FLOOR" ]; then
    verdict="THIN-WARN: proof >= ${KIT_DELIVERY_RATIO_WARN}x real and real < ${KIT_DELIVERY_REAL_FLOOR} -- confirm delivery matches the sub-goal's claim (advisory heuristic; false positives exist)"
  else
    verdict="OK"
  fi
  echo "real=$real proof=$proof | $verdict"
}

# the verification-log files this branch added/modified (excludes the convention README).
# Two accepted shapes, both location-agnostic: any `docs/verification/<slug>.md` (at the
# repo root or nested under whatever owns it) and any path ending `/proof-of-done.md`. The
# content check in check() validates both the same way; location is just where the proof
# lives.
#
# The nested case used to be spelled out as `tools/<name>/docs/verification/`, which only
# covered a monorepo TOOL. ops-toolkit's co-location rule also puts an experiment's proof at
# `experiments/<slug>/docs/verification/<feature>.md`, and that matched nothing, so a real
# proof was invisible and the gate fell through to the override branch and refused the source
# change (hit 2026-08-25). Enumerating owner directories is the bug: every new co-location
# home needs another alternative, and the failure is silent. Matching `docs/verification/` at
# any depth is both smaller and closed over future owners, and it grants nothing the
# already-anywhere `/proof-of-done.md` rule did not.
_fresh_proof_files() {
  local root="$1" base="$2"
  { git -C "$root" diff --name-only "$base"..HEAD 2>/dev/null
    git -C "$root" diff --name-only HEAD 2>/dev/null
    git -C "$root" diff --name-only --cached 2>/dev/null
    git -C "$root" ls-files --others --exclude-standard 2>/dev/null
  } | sort -u | grep -E '(^|/)docs/verification/.+\.md$|(^|/)proof-of-done\.md$' | grep -v '/README\.md$' || true
}

# Repo identity for override scoping (ID-299). The override log is machine-local and now
# keys each entry by repo+slug, so a `backlog-reconcile` override logged in one repo cannot
# short-circuit the ship-gate for the SAME slug in an unrelated repo (the family-office ->
# console-labs collision that hid a real proof). Repo id = the git COMMON dir's parent (the
# shared repo root), absolute, so ALL worktrees of one repo share a key -- keying on
# --show-toplevel would give every `.claude/worktrees/<name>` checkout a different id under
# the kit's own always-worktree policy, silently blocking a push from a sibling worktree.
# The raw absolute path is the key (not a lossy slug: `tr '/ ' '--'` collapsed `foo/bar`
# and `foo-bar` onto the same id, review-flagged); only `|` is stripped for delimiter safety.
# A non-git dir falls back to the ABSOLUTE cwd so two relative "." calls in different dirs
# never collide onto the same key.
_repo_id() {
  local d="${1:-.}" common
  common="$(git -C "$d" rev-parse --git-common-dir 2>/dev/null)" || {
    printf '%s' "$( (cd "$d" 2>/dev/null && pwd -P) || printf '%s' "$d")" | tr -d '|'; return
  }
  case "$common" in
    /*) : ;;
    *) common="$( (cd "$d" 2>/dev/null && cd "$(dirname "$common")" 2>/dev/null && pwd -P) )/$(basename "$common")" ;;
  esac
  common="${common%/.git}"          # the shared repo root, identical across all worktrees
  printf '%s' "$common" | tr -d '|'
}

# negctl forwards to lib/gate/negctl.sh: a tree-mutating, FAIL-CLOSED tool does not belong
# inside the gate (which FAILS OPEN on ambiguity by contract); the verb stays for callers.
negctl() { bash "$PROOF_LEDGER_DIR/negctl.sh" "$@"; }

is_overridden() {
  local slug repo
  slug="$(slugify "${1:-}")"; repo="$(_repo_id "${2:-.}")"
  [ -n "$slug" ] || return 1
  [ -f "$OVERRIDE_LOG" ] || return 1
  # FIELD-anchored match (ID-299 + review security lens): compare the repo/slug FIELDS by
  # position, never a substring of the whole line. A free substring (`grep -F "| $repo | $slug |"`)
  # let a crafted `reason` embedding "| <victim-repo> | <victim-slug> |" forge a match for a
  # repo/slug the operator never touched -- the very cross-repo bypass this change closes.
  # FS is a single "|" (portable across awk variants; a multi-char " | " FS is a regex BSD awk
  # mishandled); fields are trimmed. repo has "|" stripped and slug is charset-restricted, so
  # the reason (field 5+) can never shift or forge fields 2/3/4. Legacy entries carry no repo
  # field ($4 != OVERRIDE) so they match no repo -> fail CLOSED.
  awk -F'|' -v r="$repo" -v s="$slug" '
    function trim(x){ gsub(/^[ \t]+|[ \t]+$/,"",x); return x }
    trim($2)==r && trim($3)==s && trim($4)=="OVERRIDE" { found=1; exit }
    END { exit(found?0:1) }' "$OVERRIDE_LOG"
}

override() {
  local slug raw reason repo
  raw="${1:-}"; shift 2>/dev/null || { echo "usage: override <slug> <reason>" >&2; return 64; }
  reason="${*:-}"; slug="$(slugify "$raw")"
  [ -n "$slug" ] && [ -n "$reason" ] || { echo "usage: override <slug> <reason>" >&2; return 64; }
  # CONTRACT (ID-299): the override is scoped to the repo it is logged FROM, so run it from
  # inside that repo's tree. Refuse when cwd is not a git repo, rather than log a cwd-keyed
  # entry that will never match a push (review: the write side must not silently no-op). This
  # is the write twin of check()'s explicit-$root read; it also closes the cwd-ambiguity class
  # noted in _meta/megagoals/_archive/kit-north-star/FEEDBACK.md.
  if ! git -C . rev-parse --git-common-dir >/dev/null 2>&1; then
    echo "override: cwd is not a git repo. Run this from inside the repo you are overriding for; nothing logged." >&2
    return 66
  fi
  repo="$(_repo_id ".")"
  ledger_append "$OVERRIDE_STREAM" "$(printf '%s | %s | %s | OVERRIDE | %s' "$(now)" "$repo" "$slug" "$reason")" || return 1
  echo "proof-of-done override logged for slug '$slug' in repo '$repo' (trace: $OVERRIDE_LOG)"
}

# _has_committed_image <proof-file> <root>: 0 iff the file embeds an image whose target
# actually EXISTS in the tree (resolved relative to the proof file's dir, then the repo root).
# Closes the fabrication hole: a bare `![x](missing.gif)` string must not count as "it ran" ,
# the picture has to really be there. A committed proof image satisfies this at push time; a
# dangling or typo'd reference does not.
_has_committed_image() {
  local pf="$1" root="$2" path
  [ -f "$pf" ] || return 1
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    path="${path%%[#?]*}"          # strip #anchor / ?query
    path="${path#./}"
    [ -f "$(dirname "$pf")/$path" ] && return 0
    [ -f "$root/$path" ] && return 0
  done < <(grep -oiE '!\[[^]]*\]\([^)]*\.(png|gif|jpe?g|svg|webp)\)' "$pf" 2>/dev/null \
            | sed -E 's/^.*\(([^)]*)\)$/\1/')
  return 1
}

check() {
  local root="${1:-}" base="${2:-}" slug="${3:-}"
  [ -n "$root" ] && [ -n "$base" ] || { echo "usage: check <root> <base> [slug]" >&2; return 64; }
  # fail open: base must resolve to a real commit.
  git -C "$root" rev-parse --verify -q "$base" >/dev/null 2>&1 || return 0

  local class last_v; class="$(classify "$root" "$base")"
  [ "$class" = "inert" ] && return 0          # docs/cosmetic: no ritual.

  local files f ok=1
  # A committed screenshot/GIF embed counts as captured run-evidence too (visual/demo work
  # proves "it actually ran" with a picture, not only a text run-table). The semantic marker
  # (NEGATIVE CONTROL / rollback) is still required, and the image must actually EXIST , see
  # _has_committed_image, so a dangling `![x](missing.gif)` reference does not count.
  files="$(_fresh_proof_files "$root" "$base")"
  # per-file (back-compat): a flat docs/verification/<slug>.md or a co-located
  # proof-of-done.md carries both markers in one file.
  if [ -n "$files" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      local p="$root/$f"; [ -f "$p" ] || continue
      if [ "$class" = "behavioral" ]; then
        # SPEC-080: an INCONCLUSIVE verdict never satisfies the gate, even with Exit: 0.
        # LAST-verdict-wins (review lens 2): the documented append shape retries after a
        # noisy run, so only the most recent Verdict: line in the file decides.
        last_v="$(grep -iE '^[[:space:]]*Verdict:' "$p" | tail -1)"
        grep -qi 'NEGATIVE CONTROL' "$p" && { grep -qE 'Exit:[[:space:]]*0|VERDICT: PASS|Verdict: PASS|PASS' "$p" || _has_committed_image "$p" "$root"; } \
          && ! printf '%s' "$last_v" | grep -qiE 'Verdict:[[:space:]]*(INCONCLUSIVE|FAIL)' && ok=0 && break
      else # stateful
        grep -qiE 'rollback|\[UNAVAILABLE' "$p" && { grep -qE 'Command:|Exit:' "$p" || _has_committed_image "$p" "$root"; } && ok=0 && break
      fi
    done <<< "$files"
  fi
  # set-wise (directory layout): under docs/verification/<slug>/ the green run and the
  # negative control may live in different runs/ files. Group by the <slug>/ prefix and
  # satisfy when the UNION of a group's files carries both markers.
  if [ "$ok" -ne 0 ] && [ -n "$files" ]; then
    local groups g content grp_img
    groups="$(printf '%s\n' "$files" | sed -nE 's#^(.*docs/verification/[^/]+/).*#\1#p' | sort -u)"
    while IFS= read -r g; do
      [ -n "$g" ] || continue
      content=""; grp_img=1     # grp_img=0 iff some file in the group embeds a REAL image
      while IFS= read -r f; do
        case "$f" in
          "$g"*) [ -f "$root/$f" ] && { content+="$(cat "$root/$f")"$'\n'; _has_committed_image "$root/$f" "$root" && grp_img=0; } ;;
        esac
      done <<< "$(printf '%s\n' "$files" | sort)"
      if [ "$class" = "behavioral" ]; then
        # SPEC-080 last-verdict-wins, set-wise: files concatenate in sorted (= chronological)
        # order, so the union's final Verdict: line is the latest run's.
        last_v="$(printf '%s' "$content" | grep -iE '^[[:space:]]*Verdict:' | tail -1)"
        printf '%s' "$content" | grep -qi 'NEGATIVE CONTROL' \
          && { printf '%s' "$content" | grep -qE 'Exit:[[:space:]]*0|VERDICT: PASS|Verdict: PASS|PASS' || [ "$grp_img" -eq 0 ]; } \
          && ! printf '%s' "$last_v" | grep -qiE 'Verdict:[[:space:]]*(INCONCLUSIVE|FAIL)' \
          && ok=0 && break
      else # stateful
        printf '%s' "$content" | grep -qiE 'rollback|\[UNAVAILABLE' \
          && { printf '%s' "$content" | grep -qE 'Command:|Exit:' || [ "$grp_img" -eq 0 ]; } \
          && ok=0 && break
      fi
    done <<< "$groups"
  fi
  [ "$ok" -eq 0 ] && return 0

  # A real proof (checked above) always wins outright. Only fall back to an override
  # when no fresh proof file satisfies the requirement: the override log is append-only,
  # so checking it FIRST (the old order) meant a mistaken or early override for a slug
  # touching a source file blocked that slug FOREVER, even after a legitimate
  # proof-of-done with a NEGATIVE CONTROL landed in the same branch later (found
  # 2026-08-06: a docs+one-line-.sh-fix branch logged an override before writing its
  # proof doc, then could never pass again once the proof doc existed, because this
  # check short-circuited on the override every time). Checking the real proof first
  # closes that trap without weakening the override's own docs-only restriction below.
  if [ -n "$slug" ] && is_overridden "$slug" "$root"; then
    # cc-hyg-04: an override excuses docs / deploy-inert work, NOT application source
    # code. A blanket override that silently passes an unproven SOURCE change is the
    # rtk-611 hole (2026-07-01: an overridden branch shipped a broken source change,
    # reverted 9h later). Deploy scripts under a deploy/ path stay override-able (they
    # are verified via deploy-proof/UAT per SPEC-095); source code elsewhere is not.
    # Build the source-code remainder. A file counts as source if it has a code
    # extension OR is an extensionless shebang script (e.g. the kit's own
    # lib/goal/handoff-gen); deploy scripts at a SANCTIONED location (repo-root deploy/
    # or a per-tool tools/<name>/deploy/) are exempt -- but a `deploy` dir nested
    # anywhere else (src/deploy/, lib/deploy/) is NOT, or it would reopen the hole.
    local src_remainder="" f
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$f" in deploy/*|tools/*/deploy/*) continue ;; esac   # sanctioned deploy: override-able
      if printf '%s' "$f" | grep -qE '\.(sh|bash|zsh|py|js|jsx|mjs|cjs|ts|tsx|go|rs|rb|c|h|cc|cpp|hpp|java|php|swift|kt|kts|scala|clj|cljs|ex|exs|lua|pl|pm|r|m|mm|sql)$'; then
        src_remainder="${src_remainder}${f}"$'\n'; continue
      fi
      # extensionless file (no dot in basename): treat as source if it is a shebang script.
      case "$(basename "$f")" in
        *.*) : ;;
        *) [ -f "$root/$f" ] && [ "$(head -c2 "$root/$f" 2>/dev/null)" = '#!' ] && src_remainder="${src_remainder}${f}"$'\n' ;;
      esac
    done < <(_changed "$root" "$base")
    if [ -n "$src_remainder" ]; then
      echo "proof-of-done: override for '$slug' REJECTED -- the branch changes source files with no proof of done:" >&2
      printf '%s' "$src_remainder" | sed 's/^/    - /' >&2
      echo "  An override excuses docs / deploy-inert work only. Provide a proof of done for the source change (run /kit:verify), or split it out." >&2
      return 1
    fi
    echo "proof-of-done: OVERRIDDEN for '$slug' (docs/deploy-inert remainder; logged, see $OVERRIDE_LOG)" >&2
    return 0
  fi

  # blocked: name exactly what is missing.
  {
    echo "BLOCKED: proof of done. This is a '$class' change; it cannot ship/merge without a matching proof-of-done entry in docs/verification/."
    if [ "$class" = "behavioral" ]; then
      echo "  Need: a docs/verification/<slug>.md added by this branch with a green run AND a NEGATIVE CONTROL (revert -> RED -> restore)."
      echo "        ('green run' = a text run-table (Command:/Exit:/Verdict: PASS) OR a committed screenshot/GIF embed for visual/demo work.)"
    else
      echo "  Need: a docs/verification/<slug>.md added by this branch with a recorded run AND a rollback note, or [UNAVAILABLE: reason] if no such flow exists here."
      echo "        ('recorded run' = Command:/Exit: text OR a committed screenshot/GIF embed for visual/demo work.)"
    fi
    echo "  Type-specific shape: run 'bash lib/gate/proof-gate.sh contract \"<your task>\"' for the exact artifact this work-type owes + the skill that owns it (e.g. a data/CLI tool owes a recorded live run; an eval owes a TEST-REPORT)."
    echo "  Produce it via /kit:verify (or record it), or log an explicit override (audited):"
    echo "    bash lib/gate/proof-ledger.sh override '${slug:-<branch-slug>}' \"<reason>\""
    # ID-299 operator hint: an override for THIS slug exists in the log but is scoped to a
    # different repo (legacy unqualified, a sibling repo, or a non-root/wrong-worktree cwd),
    # so it does not apply here. Say so, or the operator re-logs and it still "does nothing".
    if [ -n "$slug" ] && [ -f "$OVERRIDE_LOG" ] \
       && awk -F'|' -v s="$slug" 'function trim(x){gsub(/^[ \t]+|[ \t]+$/,"",x);return x} trim($3)==s && trim($4)=="OVERRIDE"{f=1;exit} END{exit(f?0:1)}' "$OVERRIDE_LOG"; then
      echo "  Note: an override for '$slug' exists in the log but is scoped to a different repo; re-log it from THIS repo's root."
    fi
  } >&2
  return 1
}

cmd="${1:-}"; shift 2>/dev/null || true
case "$cmd" in
  classify)      classify "$@" ;;
  check)         check "$@" ;;
  override)      override "$@" ;;
  is-overridden) is_overridden "$@" ;;
  deployable)    deployable "$@" ;;
  delivery-ratio) delivery_ratio "$@" ;;
  negctl)        negctl "$@" ;;
  *) echo "usage: proof-ledger.sh {classify|check|override|is-overridden|deployable|delivery-ratio|negctl} ..." >&2; exit 64 ;;
esac
