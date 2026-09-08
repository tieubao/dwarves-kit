#!/usr/bin/env bash
# quiz-gate.sh -- the mechanical half of the ★-tap NUDGE (ADR-0031 §2/§3, SPEC-125, SG-04).
#
# The AFTER gate's SPEED REGULATOR (Litt): when a change is significant AND understanding-worthy
# (SPEC-123's `tap` verdict) on a gate/gated-final PR, the human is NUDGED -- offered a 5-question
# quiz built from the ACTUAL change -- before they click-to-merge. It gates the human's ATTENTION,
# never the merge: it is a NUDGE, never must-pass (ADR-0031 Refinement point 3). A waved change
# still merges; nothing here ever blocks a correct build.
#
# THE HARD CONSTRAINT (Litt's plausible-but-wrong caveat, the whole reason this exists):
# the quiz questions are grounded in the DIFF + recorded test results, NEVER the agent's narrative.
# `questions` and `route` take a git `<ref>` ONLY -- there is no narrative/intent argument, so a
# false story physically cannot leak into the quiz (the same architectural guarantee as lib/explain.sh,
# which this reuses for the grounded material). A quiz on the agent's misconceptions is worse than none.
#
# THE KIT DOES NOT REINVENT PEDAGOGY: the quiz ROUTES through the operator's existing `deep-understand`
# AskUserQuestion mastery-gate engine. This lib builds the QUESTIONS (from the diff) and emits the
# dispatch payload; it never scores or grades a quiz itself.
#
# Verbs:
#   quiz-gate.sh questions <ref>
#       -> exactly 5 quiz questions (Q1..Q5) built from the diff + recorded tests. git-ref-only.
#   quiz-gate.sh tap <rid> [--files F] [--impl-notes P] [--pr-kind K] "<desc>"
#       -> the WIRING decision. Prints the one-line nudge + the 3 responses ONLY when
#          significance-classify's verdict is `tap` AND the PR is gate/gated-final. Otherwise prints
#          nothing and exits 0 (the anti-fatigue guard, keyed on the SPEC-123 verdict).
#   quiz-gate.sh respond <rid> <engage|defer|wave> [--ref R]
#       -> logs the human choice to the debt ledger (gate-ledger.sh debt-response). For `engage`
#          (with --ref) also emits the deep-understand routing directive. Always exits 0 (advisory).
#   quiz-gate.sh route <ref>
#       -> the deep-understand dispatch payload: the skill + its AskUserQuestion mastery gate + the
#          5 diff-grounded questions + a pointer to the SPEC-124 explainer material.

set -uo pipefail

QG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_ROOT="$(cd "$QG_DIR/.." && pwd)"  # the lib/ dir; cross-subsystem siblings resolve as "$LIB_ROOT/<subsystem>/<file>"
EXPLAIN="$LIB_ROOT/explain.sh"
SIG_CLASSIFY="$LIB_ROOT/classify/significance-classify.sh"
GATE_LEDGER="$QG_DIR/gate-ledger.sh"

# _primary_file <ref> -- the first non-doc, non-test changed file in READING order (reuses
# lib/explain.sh's grounded ordering). This is the code the quiz drills. Prints NOTHING when the
# change is docs/tests only (no code file), so cmd_questions can fire its "touches only docs/tests"
# branch instead of mis-labeling a doc as the primary code file.
_primary_file() {
  local ref="$1" f
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in
      docs/*|*/tests/*|tests/*) continue ;;
      *SPEC-*|*test-*|*_test.*|*.test.*|*.spec.*) continue ;;
    esac
    printf '%s\n' "$f"; return 0
  done < <(bash "$EXPLAIN" order "$ref" 2>/dev/null)
  # docs/tests-only change: no primary code file. Print nothing (empty), do not degrade to a doc.
  return 0
}

# _added_lines <ref> <file> -- the actual `+` lines the diff introduced for <file> (never the commit
# message). Grounds a question in real code. Blank <file> -> nothing.
_added_lines() {
  local ref="$1" file="$2" base head
  [ -n "$file" ] || return 0
  if [[ "$ref" == *..* ]]; then base="${ref%%..*}"; head="${ref##*..}"; else
    head="$ref"; base="$(git rev-parse -q --verify "${ref}^1" 2>/dev/null || echo 4b825dc642cb6eb9a060e54bf8d69288fbee4904)"
  fi
  git diff "$base" "$head" -- "$file" 2>/dev/null \
    | grep -E '^\+' | grep -vE '^\+\+\+' | sed -E 's/^\+//' | grep -vE '^[[:space:]]*$' | head -3
}

# questions: exactly 5 diff-grounded quiz questions. Input is a git ref ONLY.
cmd_questions() {
  local ref="${1:-HEAD}"
  # The grounded facts, all off the diff/tests (never a narrative):
  local order primary verdict snippet
  order="$(bash "$EXPLAIN" order "$ref" 2>/dev/null | tr '\n' ' ')"; order="${order% }"
  primary="$(_primary_file "$ref")"
  verdict="$(bash "$EXPLAIN" tests "$ref" 2>/dev/null | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g')"
  snippet="$(_added_lines "$ref" "$primary" | tr '\n' ';' | sed -E 's/;+/; /g; s/; $//')"
  local first_file="${order%% *}"

  echo "# 5-question understanding quiz for \`${ref}\`"
  echo "# Grounded in the ACTUAL diff + recorded test results, NOT any agent narrative."
  echo "# These questions are the payload for the deep-understand mastery gate, they are not scored here."
  echo
  echo "Q1. Background: this change is read in the order: ${order:-（no files）}. Start from \`${first_file:-（none）}\` -- what existing context does the change build on, and why is that the reader's first stop?"
  echo "Q2. Goal (off the diff): the change touches these files: ${order:-（none）}. In your own words, what is the goal read OFF THE DIFF -- not off the commit message?"
  if [ -n "$primary" ] && [ -n "$snippet" ]; then
    echo "Q3. The new/changed code in \`${primary}\` introduces: ${snippet}. What does it actually do, and how is it wired into the rest of the change?"
  elif [ -n "$primary" ]; then
    echo "Q3. Trace the changed code in \`${primary}\`. What does it introduce, and how is it wired into the rest of the change?"
  else
    echo "Q3. This change touches only docs/tests (${order:-（none）}). What behavior does it document or verify, and where does the behavior itself live?"
  fi
  echo "Q4. Verification: the recorded test result is: ${verdict:-[no recorded test result]}. Does that proof actually exercise this change's behavior, or is there an uncovered path?"
  echo "Q5. Blast radius / why: why was it resolved this way, and what breaks downstream if you misunderstand \`${primary:-${first_file:-this change}}\`?"
}

# route: the deep-understand dispatch payload. The kit builds the questions + names the engine; it
# does NOT score the quiz (no reinvented pedagogy).
cmd_route() {
  local ref="${1:-HEAD}"
  echo "ROUTE: deep-understand"
  echo "engine: deep-understand skill (its AskUserQuestion mastery-gate quiz)"
  echo "material: the literate explainer (lib/explain.sh render ${ref}); docs/verification/"
  echo "instruction: hand these 5 diff-grounded questions to deep-understand; it runs the mastery gate,"
  echo "             shuffles answer slots, and gates each item on a demonstrated answer. The kit scores nothing."
  echo
  cmd_questions "$ref"
}

# tap: the wiring decision. Fire ONLY on the SPEC-123 `tap` verdict + a gate/gated-final PR.
cmd_tap() {
  local files="" impl="" pr_kind="gate" desc=""
  local a skip=""
  local -a rest=()
  for a in "$@"; do
    if [ -n "$skip" ]; then
      case "$skip" in files) files="$a";; impl) impl="$a";; pr) pr_kind="$a";; esac
      skip=""; continue
    fi
    case "$a" in
      --files)        skip=files ;;
      --files=*)      files="${a#--files=}" ;;
      --impl-notes)   skip=impl ;;
      --impl-notes=*) impl="${a#--impl-notes=}" ;;
      --pr-kind)      skip=pr ;;
      --pr-kind=*)    pr_kind="${a#--pr-kind=}" ;;
      *)              rest+=("$a") ;;
    esac
  done
  local rid="${rest[0]:-}"
  [ -n "$rid" ] || { echo "usage: quiz-gate.sh tap <rid> [--files F] [--impl-notes P] [--pr-kind K] \"<desc>\"" >&2; return 64; }
  desc="${rest[*]:1}"

  # Anti-fatigue guard #1: only gate/gated-final PRs are ever tapped (a routine non-gate PR is never
  # nudged). Silent, advisory: print nothing, exit 0.
  case "$pr_kind" in gate|gated-final) ;; *) return 0 ;; esac

  # The verdict is the SPEC-123 classifier's, never re-derived here (single source of the WHEN).
  local verdict clf_args=()
  [ -n "$files" ] && clf_args+=(--files "$files")
  [ -n "$impl" ] && clf_args+=(--impl-notes "$impl")
  verdict="$(bash "$SIG_CLASSIFY" classify "${clf_args[@]}" "$desc" 2>/dev/null)"

  # Anti-fatigue guard #2 (the load-bearing one): tap ONLY on high×high (`tap`). `wave` (significant
  # but low-worthiness) and `not-significant` print nothing -- the human is never nudged on them.
  [ "$verdict" = tap ] || return 0

  # The nudge: one line + the three responses. This is a NUDGE, never must-pass.
  printf '★ worth understanding: %s\n' "${desc:-this change}"
  echo "  This gate/gated-final PR is significant AND understanding-worthy. Before you merge, pick one"
  echo "  (all three are logged to the debt ledger; the quiz never blocks the merge):"
  echo "    engage  -- pull the 5-question quiz now (deep-understand mastery gate)"
  echo "    defer   -- send it to the weekend batch"
  echo "    wave    -- accept the debt knowingly (the change still merges)"
  echo "  Respond: bash lib/gate/quiz-gate.sh respond ${rid} <engage|defer|wave> [--ref <ref>]"
}

# respond: log the human's choice; for engage, also emit the deep-understand routing directive.
cmd_respond() {
  local rid="${1:-}" response="${2:-}"; shift 2 2>/dev/null || { echo "usage: quiz-gate.sh respond <rid> <engage|defer|wave> [--ref R]" >&2; return 64; }
  case "$response" in engage|defer|wave) ;; *) echo "quiz-gate.sh respond: response must be engage|defer|wave (got '$response')" >&2; return 64;; esac
  local ref="" a skip=""
  for a in "$@"; do
    if [ -n "$skip" ]; then ref="$a"; skip=""; continue; fi
    case "$a" in --ref) skip=ref ;; --ref=*) ref="${a#--ref=}" ;; esac
  done

  # Log to the debt ledger (all three responses, always). This is the ONLY state this writes.
  bash "$GATE_LEDGER" debt-response "$rid" "$response" "SG-04 quiz-gate nudge${ref:+ ref=$ref}" >/dev/null 2>&1 \
    || { echo "quiz-gate.sh respond: failed to write debt-response to the ledger for rid '$rid'" >&2; return 1; }

  case "$response" in
    engage)
      echo "recorded: engage (rid=${rid}). Routing to the deep-understand mastery gate:"
      if [ -n "$ref" ]; then cmd_route "$ref"; else
        echo "ROUTE: deep-understand (no --ref given; run 'quiz-gate.sh route <ref>' to build the questions)"
      fi
      ;;
    defer) echo "recorded: defer (rid=${rid}) -- queued for the weekend batch. The change still merges." ;;
    wave)  echo "recorded: wave (rid=${rid}) -- debt accepted knowingly. The change still merges." ;;
  esac
  return 0
}

usage() { sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

main() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    questions) cmd_questions "$@" ;;
    tap)       cmd_tap "$@" ;;
    respond)   cmd_respond "$@" ;;
    route)     cmd_route "$@" ;;
    ""|-h|--help|help) usage ;;
    *) echo "quiz-gate.sh: unknown subcommand '$sub'" >&2; usage >&2; exit 2 ;;
  esac
}

main "$@"
