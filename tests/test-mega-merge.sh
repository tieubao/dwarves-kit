#!/usr/bin/env bash
# test-mega-merge.sh -- SPEC-100, kit-telemetry SG-05.
# Pins the CODE-LEVEL gate/held-final exclusion in lib/goal/mega-merge.sh: a gate-tagged /
# held-final / draft PR is refused at the code level even when the prompt-level rule is
# absent, unreadable state fails closed, and a normal `auto` PR still merges.
#
# Fully offline: gate-ledger + PR-state are injected (MEGA_MERGE_GATE_LEDGER,
# MEGA_MERGE_PR_INFO_CMD), so no `gh` and no real gate ledger are touched.
#
# Run: bash tests/test-mega-merge.sh   (exit 0 = all green)

set -uo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MM="$KIT_DIR/lib/goal/mega-merge.sh"
US=$'\037'

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
ok() { TOTAL=$((TOTAL+1)); if [ "$2" -eq 0 ]; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1)); else echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL+1)); fi; }
has() { { trap '' PIPE; printf '%s' "$2" 2>/dev/null || :; } | grep -qF -- "$1"; }

TMP="$(mktemp -d)"
# injected gate-ledger stubs: one that passes, one that fails
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/gl-pass"; chmod +x "$TMP/gl-pass"
printf '#!/usr/bin/env bash\necho "MISSING-GATE: build" >&2\nexit 1\n' > "$TMP/gl-fail"; chmod +x "$TMP/gl-fail"
# injected PR-state: pr number selects the scenario
cat > "$TMP/prinfo" <<SH
#!/usr/bin/env bash
US=\$'\\037'
case "\$1" in
  1) printf 'false%senhancement%snormal feature PR\\n' "\$US" "\$US" ;;   # clear
  2) printf 'false%sdo-not-merge%sheld final PR\\n' "\$US" "\$US" ;;      # hold label
  3) printf 'true%s%sdraft wip\\n' "\$US" "\$US" ;;                       # draft
  4) printf 'false%s%s[HOLD] gated final\\n' "\$US" "\$US" ;;             # title marker
  5) exit 1 ;;                                                            # unreadable
  6) printf 'false%sci-red,gated-final%smixed labels\\n' "\$US" "\$US" ;; # hold among others
  7) printf 'false%s*%sglob label\\n' "\$US" "\$US" ;;                    # label '*' must not glob/clear-crash
  8) printf 'false%s  Gated-Final  %swhitespace and case\\n' "\$US" "\$US" ;; # normalized hold match
  9) echo "not json at all {{{" ;;                                        # malformed non-empty -> fail closed
esac
SH
chmod +x "$TMP/prinfo"
export MEGA_MERGE_PR_INFO_CMD="$TMP/prinfo"

run() { MEGA_MERGE_GATE_LEDGER="$1" bash "$MM" merge "$2" somerid full 2>&1; }

# fake gh on PATH that marks if invoked, so "a held PR never reaches gh even with --execute"
# is a real assertion (the exclusion runs BEFORE the execute/posture branch).
GH_MARK="$TMP/gh-called"
printf '#!/usr/bin/env bash\necho "$*" >> "%s"\nexit 0\n' "$GH_MARK" > "$TMP/gh"; chmod +x "$TMP/gh"

echo "=== mega-merge exclusion (SPEC-100 AC1-AC6) ==="

# AC1 [positive control]: a clear, gate-passing PR still merges (dry-run reaches the merge cmd).
O1="$(run "$TMP/gl-pass" 1)"; R1=$?
has "gh pr merge 1" "$O1"; ok "AC1: normal auto PR (clear + gate pass) still merges (dry-run)" $?
ok "AC1: exit 0 for a mergeable PR" $([ "$R1" -eq 0 ] && echo 0 || echo 1)

# AC2 [NC]: a hold-labelled PR is refused even with a PASSING gate.
O2="$(run "$TMP/gl-pass" 2)"; R2=$?
has "BLOCKED" "$O2"; ok "AC2 [NC]: hold-label PR refused" $?
has "hold label" "$O2"; ok "AC2: refusal names the hold label" $?
ok "AC2: exit nonzero" $([ "$R2" -ne 0 ] && echo 0 || echo 1)

# AC3 [NC]: a draft PR is refused.
O3="$(run "$TMP/gl-pass" 3)"
has "is a draft" "$O3"; ok "AC3 [NC]: draft PR refused" $?

# AC4 [NC]: a bracketed-title-marker PR is refused.
O4="$(run "$TMP/gl-pass" 4)"
has "title carries a hold marker" "$O4"; ok "AC4 [NC]: title-marker PR refused" $?

# AC5 [NC, fail-closed]: unreadable PR state is refused with a reason (never merged on doubt).
O5="$(run "$TMP/gl-pass" 5)"; R5=$?
has "cannot read PR" "$O5"; ok "AC5 [NC]: unclassifiable PR refused (fail-closed)" $?
ok "AC5: exit nonzero" $([ "$R5" -ne 0 ] && echo 0 || echo 1)
if has "gh pr merge" "$O5"; then ok "AC5: never prints a merge command for an unreadable PR" 1; else ok "AC5: never prints a merge command for an unreadable PR" 0; fi

# AC6: a hold label among others still blocks (not just a solo label).
O6="$(run "$TMP/gl-pass" 6)"
has "gated-final" "$O6"; ok "AC6: hold label detected among multiple labels" $?

# AC6b [injection safety]: a label of "*" is treated as a literal string, never glob-expanded
# (the label loop must not word-split/glob an attacker-set label); it is not a hold word -> clear.
O8="$(cd "$TMP" && touch fa fb && run "$TMP/gl-pass" 7)"
has "gh pr merge 7" "$O8"; ok "AC6b: label '*' is literal, no glob expansion / no crash" $?
# AC6c: a hold label with surrounding whitespace + odd case still blocks (normalized match).
O9="$(run "$TMP/gl-pass" 8)"
has "hold label" "$O9"; ok "AC6c: whitespace/case-variant hold label still blocks" $?

# AC5b [fail-closed on garbage]: non-empty but malformed PR state (not the 3-field shape) is
# refused, NOT parsed to a garbage draft that falls through to clear (security review B2).
O5b="$(run "$TMP/gl-pass" 9)"
has "cannot read PR" "$O5b"; ok "AC5b [NC]: malformed non-empty PR state fails closed (not cleared)" $?
if has "gh pr merge" "$O5b"; then ok "AC5b: never prints a merge command for malformed state" 1; else ok "AC5b: never prints a merge command for malformed state" 0; fi

# AC7 [gate still enforced]: a CLEAR PR with a FAILING gate is still blocked (exclusion did
# not bypass the ship-gate). Exclusion is checked first, but a clear PR then hits the gate.
O7="$(run "$TMP/gl-fail" 1)"
has "ship-gate not satisfied" "$O7"; ok "AC7: clear PR + failing gate still blocked by the gate" $?

# AC7b [unknown-lane fail-closed, TIER-4 security]: a clear PR with an UNKNOWN lane (e.g. the
# real gate-ledger, not a stub) must NOT vacuous-pass. Uses the real gate-ledger deliberately.
GL_REAL="$KIT_DIR/lib/gate/gate-ledger.sh"
O7b="$(DWARVES_KIT_LOG_DIR="$(mktemp -d)/l" MEGA_MERGE_GATE_LEDGER="$GL_REAL" MEGA_MERGE_PR_INFO_CMD="$TMP/prinfo" bash "$MM" merge 1 someridZ mega --execute 2>&1)"
has "BLOCKED" "$O7b"; ok "AC7b: unknown lane 'mega' is refused, not vacuous-passed (real gate-ledger)" $?
if has "gh pr merge" "$O7b"; then ok "AC7b: unknown lane never reaches gh --execute" 1; else ok "AC7b: unknown lane never reaches gh --execute" 0; fi

# AC8 [load-bearing]: a held PR with --execute NEVER calls gh (exclusion runs before the
# execute branch). Would catch a future reorder that moved the check after --execute.
rm -f "$GH_MARK"
O10="$(PATH="$TMP:$PATH" MEGA_MERGE_GATE_LEDGER="$TMP/gl-pass" bash "$MM" merge 2 somerid full --execute 2>&1)"
has "BLOCKED" "$O10"; ok "AC8: held PR + --execute is still BLOCKED" $?
ok "AC8 [load-bearing]: held PR + --execute never invokes gh" $([ -f "$GH_MARK" ] && echo 1 || echo 0)

echo ""
echo "=== mega-merge mark (SPEC-100 mark half, SG-04 / ID-089) ==="
# A mock gh that records its args, so `mark`'s calls are asserted without touching GitHub.
# PR 3 = the prinfo `draft` scenario, so mark's post-state verify (_merge_exclusion) confirms held.
GH_LOG="$TMP/mark-gh.log"; : > "$GH_LOG"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$GH_LOG" > "$TMP/mark-gh"; chmod +x "$TMP/mark-gh"
MARK_OUT="$(MEGA_MERGE_GH="$TMP/mark-gh" bash "$MM" mark 3 2>&1)"; MARK_RC=$?
MARKED_CALLS="$(cat "$GH_LOG")"
has "label create do-not-merge" "$MARKED_CALLS"; ok "mark: ensures the do-not-merge label (so --label never fails)" $?
has "pr ready 3 --undo" "$MARKED_CALLS"; ok "mark: converts the PR to a draft (GitHub-intrinsic block)" $?
has "pr edit 3 --add-label do-not-merge" "$MARKED_CALLS"; ok "mark: adds the do-not-merge hold label" $?
# post-state verification (SPEC-104 TIER-4): mark confirms the mark landed + exits 0 on success.
{ [ "$MARK_RC" -eq 0 ] && has "marked PR #3 held" "$MARK_OUT"; }; ok "mark: confirms the mark landed (exit 0 + 'held')" $?
# NEGATIVE CONTROL (the silent-failure guard): mark a PR whose post-state is NOT held (scenario 1
# = clear) -> mark must WARN + exit nonzero instead of falsely reporting success.
MARK_FAIL="$(MEGA_MERGE_GH="$TMP/mark-gh" bash "$MM" mark 1 2>&1)"; MF_RC=$?
{ [ "$MF_RC" -ne 0 ] && has "NOT confirmed held" "$MARK_FAIL"; }; ok "mark: silent-failure guard -- unconfirmed mark WARNs + exits nonzero" $?
# mark <-> guard MEET (end-to-end): the state mark produces is exactly what _merge_exclusion refuses.
O_LABEL="$(run "$TMP/gl-pass" 2)"   # scenario 2 = the do-not-merge label the mark adds; gate PASSES
if ! has "gh pr merge 2" "$O_LABEL" && has "hold label" "$O_LABEL"; then ok "mark<->guard: a do-not-merge PR is refused even with a passing gate" 0; else ok "mark<->guard: a do-not-merge PR is refused even with a passing gate" 1; fi
O_DRAFT="$(run "$TMP/gl-pass" 3)"   # scenario 3 = the draft the mark sets; gate PASSES
if ! has "gh pr merge 3" "$O_DRAFT" && has "is a draft" "$O_DRAFT"; then ok "mark<->guard: a draft PR is refused (GitHub-intrinsic + code guard)" 0; else ok "mark<->guard: a draft PR is refused" 1; fi
# negative control: an UN-marked normal auto PR clears the guard + merges.
O_UNMARKED="$(run "$TMP/gl-pass" 1)"
has "gh pr merge 1" "$O_UNMARKED"; ok "mark negative control: an un-marked auto PR clears the guard + merges" $?
# input guard + idempotence
MB="$(bash "$MM" mark notanum 2>&1)"; has "must be a bare PR number" "$MB"; ok "mark: rejects a non-numeric PR (exit 64)" $?
MEGA_MERGE_GH="$TMP/mark-gh" bash "$MM" mark 3 >/dev/null 2>&1; ok "mark: idempotent (re-run exits 0)" $([ $? -eq 0 ] && echo 0 || echo 1)

echo ""
echo "=== $PASS/$TOTAL passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
