#!/bin/bash
# ship-gate.sh, PreToolUse hook, matcher: Bash
# Workflow-completeness gate at the ship/push boundary (ADR-0024). When a feature
# branch is pushed or a PR is opened, refuse if the active spec's lane has a
# required (measure-twice) gate with no `ran`/`override` entry in its run ledger.
#
# This is a QUALITY gate, not a safety gate: it FAILS OPEN on any ambiguity (no
# repo, no spec, no lane, missing tooling) so a bug here can never block unrelated
# work. push-to-main and force-push stay safety-gate.sh's job. Exit 2 = block.
set -uo pipefail
# Preserve fail-open even on the pathological case (HOME unset under set -u): the lib
# fallback below uses $HOME, so default it to empty rather than error-exit (SPEC-045 review).
HOME="${HOME:-}"
INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -z "$CMD" ] && exit 0

# SPEC-064: strip heredoc bodies BEFORE the engage check, so "git push" appearing in
# generated prose (PR bodies, test fixtures) never engages the gate. Same normalizer
# shape as safety-gate.sh.
CMD_CODE=$(printf '%s\n' "$CMD" | awk '
  BEGIN { inhd = 0 }
  {
    line = $0
    if (inhd) { t = line; gsub(/^[ \t]+/, "", t); if (t == marker) inhd = 0; next }
    if (match(line, /<<-?[ \t]*["'\'']?[A-Za-z_][A-Za-z0-9_]*["'\'']?/)) {
      m = substr(line, RSTART, RLENGTH)
      sub(/<<-?[ \t]*/, "", m); gsub(/["'\'']/, "", m)
      marker = m; inhd = 1
      line = substr(line, 1, RSTART - 1)
    }
    print line
  }')

# Engage only on a ship action: a git push or a gh pr create (in CODE, not prose).
echo "$CMD_CODE" | grep -qE 'git[[:space:]]+push|gh[[:space:]]+pr[[:space:]]+create' || exit 0
# Leave push-to-main / force-push to safety-gate; do not double-handle.
echo "$CMD_CODE" | grep -qE '\b(main|master)\b|--force' && exit 0

# SPEC-064: a command that cd's elsewhere ships THAT repo, not the session cwd (the
# cross-repo misfire: a `cd other-repo && git push` was gated against the SESSION
# repo's spec). Resolve the repo from a leading cd prefix when present.
# BSD-sed-portable: grab the cd arg with grep -o, then strip the prefix + quotes.
CDDIR=$(printf '%s' "$CMD_CODE" | grep -oE '^[[:space:]]*cd[[:space:]]+[^&;|]+' | head -1 \
  | sed -E 's/^[[:space:]]*cd[[:space:]]+//; s/[[:space:]]+$//; s/^"//; s/"$//' || true)
case "$CDDIR" in *'$'*) CDDIR="" ;; esac   # variables cannot be resolved: fall back
CDDIR="${CDDIR/#\~/$HOME}"
# Test affordance: print the resolved cd-target and exit (never set outside tests).
if [ "${DWARVES_KIT_PRINT_CDDIR:-0}" = "1" ]; then printf '%s\n' "$CDDIR"; exit 0; fi
if [ -n "$CDDIR" ] && [ -d "$CDDIR" ]; then
  ROOT=$(git -C "$CDDIR" rev-parse --show-toplevel 2>/dev/null || true)
else
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
fi
[ -n "$ROOT" ] || exit 0
BRANCH=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
[ -n "$BRANCH" ] || exit 0
SLUG="${BRANCH#*/}"   # strip the type/ prefix (feat/, docs/, ...)

# One copy of the three-way default-branch fallback (review: was duplicated per block).
_resolve_base() {
  git -C "$ROOT" rev-parse --verify -q origin/main >/dev/null 2>&1 && echo origin/main \
    || { git -C "$ROOT" rev-parse --verify -q main >/dev/null 2>&1 && echo main || echo master; }
}

# --- Proof-of-done gate (diff-keyed, SPEC-INDEPENDENT). This is the bridge: it fires on
# freeform /goal work too, because it classifies the branch DIFF instead of a spec. A
# load-bearing (behavioral/stateful) change cannot ship without a matching proof-of-done
# entry. Fails open on ambiguity (handled inside proof-ledger). Exit 2 = block. ---
# Resolve the lib from the kit's INSTALL location, not the repo being pushed (SPEC-045):
# in bash-install mode CLAUDE_PLUGIN_ROOT is unset, and a consumer repo has no lib/, so a
# $ROOT fallback fails open in every consumer. The stable install path fixes that; plugin
# mode (CLAUDE_PLUGIN_ROOT set) is unchanged.
PROOF="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/dwarves-kit}/lib/gate/proof-ledger.sh"
# OPT-IN: engage only in a repo that adopted the proof-of-done convention. A repo with
# no docs/verification/README.md never gets gated (the gate is for kit-adopting repos,
# not every repo the user touches).
if [ -f "$PROOF" ] && [ -f "$ROOT/docs/verification/README.md" ]; then
  DEFAULT=$(_resolve_base)
  BASE=$(git -C "$ROOT" merge-base HEAD "$DEFAULT" 2>/dev/null || true)
  HEADSHA=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)
  if [ -n "$BASE" ] && [ "$BASE" != "$HEADSHA" ]; then
    if ! PMSG=$(bash "$PROOF" check "$ROOT" "$BASE" "$SLUG" 2>&1); then
      LOG_DIR="${DWARVES_KIT_LOG_DIR:-$HOME/.claude/dwarves-kit/logs}"
      mkdir -p "$LOG_DIR" 2>/dev/null || true
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | BLOCKED | proof-gate | $SLUG" >> "$LOG_DIR/ship-gate.log" 2>/dev/null || true
      printf '%s\n' "$PMSG" >&2
      exit 2
    fi
  fi
  # delivery-ratio advisory (ID-277 delivery-audit fix; NEVER blocks): surface a proof-heavy
  # branch -- lots of proof-of-done/verification/spec lines wrapped around a near-zero real
  # change -- so a reviewer can spot-check delivery vs the sub-goal's claim. Heuristic with real
  # false positives (a docs sub-goal is proof-heavy by design; a 1-line fix can be load-bearing),
  # so it is a NUDGE, never a gate: fires only on THIN-WARN/NOTICE, silent on OK.
  if [ -n "${BASE:-}" ] && [ "${BASE:-}" != "${HEADSHA:-}" ]; then
    DR=$(bash "$PROOF" delivery-ratio "$ROOT" "$BASE" 2>/dev/null || true)
    case "$DR" in *THIN-WARN*|*NOTICE*) echo "[advisory] delivery-ratio: $DR" >&2 ;; esac
  fi
fi

# SPEC-069 advisory (never blocks), relocated ABOVE the spec check (SPEC-071 / ID-063):
# spec-less freeform pushes are exactly the work most likely to be un-boarded, and the
# old placement exited before the nudge could fire.
if [ -f "$ROOT/_meta/BACKLOG.md" ] && ! grep -E '^\|' "$ROOT/_meta/BACKLOG.md" 2>/dev/null | grep -qF -- "$SLUG"; then
  echo "[advisory] branch slug '$SLUG' appears nowhere in _meta/BACKLOG.md; if this is real work, give it a board row" >&2
fi

# Doc-projection gate (kit repo only): the drift class that shipped twice
# (ID-467, ID-639) is an agent/command landing without its MANUAL/architecture
# rows. When THIS push touches a projection surface, run the fast grep subset
# (lib/gate/doc-projection-check.sh, ~0.1s; the slow FEATURES regen stays in
# the full suite). Kit repo only by the file-existence scoping (a consumer repo
# has neither file). Escape hatch: DWARVES_KIT_SKIP_DOC_PROJECTION=1.
if [ -f "$ROOT/lib/gate/doc-projection-check.sh" ] && [ -f "$ROOT/tests/test-meta.sh" ] \
   && [ "${DWARVES_KIT_SKIP_DOC_PROJECTION:-0}" != "1" ]; then
  DPBASE=$(git -C "$ROOT" merge-base HEAD "$(_resolve_base)" 2>/dev/null || true)
  if [ -n "$DPBASE" ] && git -C "$ROOT" diff --name-only "$DPBASE" HEAD 2>/dev/null \
       | grep -qE '^(agents/|commands/|AGENTS\.md$|docs/(MANUAL|architecture|WORKFLOW)\.md$)'; then
    if ! DPMSG=$(bash "$ROOT/lib/gate/doc-projection-check.sh" "$ROOT" 2>&1); then
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | BLOCKED | doc-projection | $SLUG" >> "${DWARVES_KIT_LOG_DIR:-$HOME/.claude/dwarves-kit/logs}/ship-gate.log" 2>/dev/null || true
      {
        echo "BLOCKED: doc-projection drift. This push touches a projection surface and the derived doc rows are out of sync:"
        printf '%s\n' "$DPMSG"
        echo "Fix the named rows (or run 'bash tests/test-meta.sh' for the full picture). Escape: DWARVES_KIT_SKIP_DOC_PROJECTION=1."
      } >&2
      exit 2
    fi
  fi
fi

# SPEC-071 / ID-062 advisory (never blocks): a run that recorded real build work but
# ships no committable verification record dies with the session (the run ledger is
# gitignored by design). The proof-gate BLOCKS behavioral diffs in adopted repos; this
# covers its deliberate fail-open seams (non-adopted repo, tests/CI-only diff). Lane
# comes from the ledger's own START line, never the spec; base is computed locally.
# Placed deliberately AFTER the proof block: in adopted repos a behavioral diff already
# hard-BLOCKS above; this covers only the proof-gate's fail-open seams.
LEDGER62="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/dwarves-kit}/lib/gate/gate-ledger.sh"
if [ -f "$LEDGER62" ]; then
  RLED=$(bash "$LEDGER62" show "$SLUG" 2>/dev/null || true)
  # RLANE derived from START unconditionally (review: descent must not depend on the
  # ID-062 build-ran gate; a run can violate order without ever recording build).
  RLANE=$( { printf '%s' "$RLED" | grep '| START-AMEND |' | tail -1; printf '%s' "$RLED" | grep '| START |' | head -1; } | head -1 | sed -nE 's/.*\| lane=([a-z-]+).*/\1/p')
  if printf '%s' "$RLED" | grep -q '| GATE | build | ran'; then
    case "$RLANE" in
      normal|full|bug)
        DEF62=$(_resolve_base)
        BASE62=$(git -C "$ROOT" merge-base HEAD "$DEF62" 2>/dev/null || true)
        if [ -n "$BASE62" ] && ! git -C "$ROOT" diff --name-only "$BASE62" HEAD 2>/dev/null \
            | grep -E '^docs/verification/.+\.md$|(^|/)proof-of-done\.md$' \
            | grep -vq '/README\.md$'; then
          echo "[advisory] run '$SLUG' (lane $RLANE) recorded a build but this branch ships no docs/verification/ record; the session ledger is not committable evidence" >&2
        fi ;;
    esac
  fi
fi

# SPEC-076 advisory (never blocks): V-model descent , phases recorded out of the
# lane's plan order. Lane from the ledger START line (same source as the ID-062 warn).
if [ -f "$LEDGER62" ] && [ -n "${RLANE:-}" ]; then
  DOUT=$(bash "$LEDGER62" descent "$SLUG" "$RLANE" 2>/dev/null || true)
  DN=$(printf '%s' "$DOUT" | grep -c '^DESCENT:' || true)
  if [ "${DN:-0}" -gt 0 ] 2>/dev/null; then
    echo "[advisory] run '$SLUG': $DN descent violation(s), phases recorded before an earlier plan phase disposed; see: bash <kit>/lib/gate/gate-ledger.sh descent $SLUG $RLANE" >&2
  fi
fi

# Resolve the spec for this slug; fail open if there is no spec-driven run.
SPEC=$(ls "$ROOT"/docs/specs/SPEC-*-"$SLUG".md 2>/dev/null | head -1 || true)
[ -n "$SPEC" ] || exit 0

# ID-466 advisory (never blocks): the spec carries a ## Test plan, so the proof-of-done owes
# a ## Test plan coverage map -- each matrix row mapped to the run that exercised it, or an
# explicit skip reason (shape: docs/verification/README.md "Test plan coverage map"). WARNS
# on a missing map or unmapped rows; no test plan in the spec = no new requirement.
PGATE="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/dwarves-kit}/lib/gate/proof-gate.sh"
if [ -f "$PGATE" ] && grep -qE '^## Test plan[[:space:]]*$' "$SPEC" 2>/dev/null; then
  # repo-root proof homes for this slug (flat file, dir layout, runs/); co-located
  # tools/*/docs/proof-of-done.md has no slug linkage, deliberately not scanned.
  PFILES=$(ls "$ROOT/docs/verification/$SLUG.md" "$ROOT/docs/verification/$SLUG"/*.md \
              "$ROOT/docs/verification/$SLUG"/runs/*.md 2>/dev/null || true)
  # shellcheck disable=SC2086  # PFILES is a newline list of repo paths, splitting intended
  COV=$(bash "$PGATE" coverage "$SPEC" $PFILES 2>/dev/null || true)
  case "$COV" in
    NO-MAP*)   echo "[advisory] test-plan coverage: spec '$SLUG' has a ## Test plan ($COV) but no proof doc for the slug carries a '## Test plan coverage' map; map each matrix row to its run or an explicit skip reason (docs/verification/README.md)" >&2 ;;
    UNMAPPED*) echo "[advisory] test-plan coverage: proof map for '$SLUG' leaves test-plan matrix rows unmapped ($COV); map each row to a run or an explicit skip reason" >&2 ;;
  esac
fi

LANE=$(grep -m1 -iE '^Lane:' "$SPEC" 2>/dev/null | sed -E 's/^[Ll]ane:[[:space:]]*//; s/[[:space:]].*$//' || true)
if [ -z "$LANE" ]; then
  # Spec exists but declares no lane. In an ADOPTED repo (proof marker present) this is a gap,
  # not a pass: fail CLOSED so a spec-driven change cannot ship lane-less (the growatt-tui hole).
  # Everywhere else (no marker) stay fail-open: the gate never blocks unrelated work.
  if [ -f "$ROOT/docs/verification/README.md" ]; then
    LOG_DIR="${DWARVES_KIT_LOG_DIR:-$HOME/.claude/dwarves-kit/logs}"
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | BLOCKED | ship-gate | $SLUG (no-lane)" >> "$LOG_DIR/ship-gate.log" 2>/dev/null || true
    {
      echo "BLOCKED: ship-gate. Spec '$SLUG' has no 'Lane:' header, so its required gates cannot be checked."
      echo "Add a lane to $SPEC (e.g. 'Lane: full'). Classify with:"
      echo "  bash \"${CLAUDE_PLUGIN_ROOT:-\$HOME/.claude/dwarves-kit}/lib/classify/lane-classify.sh\" classify \"<task>\""
    } >&2
    exit 2
  fi
  exit 0
fi

LEDGER="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/dwarves-kit}/lib/gate/gate-ledger.sh"
[ -f "$LEDGER" ] || exit 0

# SPEC-129: bracket the ship gate with an OUTCOME emit (caught= + START/END timing). This is
# the live invocation path for the additive OUTCOME marker. It is BEST-EFFORT and writes ONLY
# to the rid ledger, so it can never change this hook's fail-open contract, exit code, or
# operator output. caught=true when the check BLOCKS (it caught a missing-gate defect),
# caught=false on a clean pass. The `outcome` marker keys on $2=="OUTCOME"; check()/_rows()/
# the ship-gate's own read all ignore it (they key on $2=="GATE").
bash "$LEDGER" outcome "$SLUG" ship start >/dev/null 2>&1 || true

if ! GAPS=$(bash "$LEDGER" check "$LANE" "$SLUG" 2>&1); then
  bash "$LEDGER" outcome "$SLUG" ship end caught=true >/dev/null 2>&1 || true
  LOG_DIR="${DWARVES_KIT_LOG_DIR:-$HOME/.claude/dwarves-kit/logs}"
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | BLOCKED | ship-gate | $SLUG ($LANE)" >> "$LOG_DIR/ship-gate.log" 2>/dev/null || true
  {
    echo "BLOCKED: ship-gate. The '$LANE' lane requires gates that have not run for spec '$SLUG':"
    printf '%s\n' "$GAPS" | sed 's/^/  /'
    echo "Run the missing gate(s), or log an explicit override (recorded for audit):"
    echo "  bash \"$LEDGER\" override $SLUG <phase> \"<reason>\""
  } >&2
  exit 2
fi
bash "$LEDGER" outcome "$SLUG" ship end caught=false >/dev/null 2>&1 || true
exit 0
