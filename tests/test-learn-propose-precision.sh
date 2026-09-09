#!/usr/bin/env bash
# test-learn-propose-precision.sh -- the ID-305 precision measurement, run as a test.
#
# Measures promote-precision END TO END: how many of the candidates that reach the BOARD are
# genuinely new work. It runs the same labelled sample twice, once with the ID-305 surfaces
# switched off (the pre-fix behaviour: no cockpit registry, no megagoal tree, no aging window,
# no home root) and once with them on, then prints both figures.
#
# THE SAMPLE IS SMALL AND SYNTHETIC. It is 17 candidates whose class mix is scaled down from
# the 69-candidate manual triage in docs/verification/learn-propose-precision.md (16 promote,
# 28 duplicate, 19 already-done, 4 stale, 2 learning). That triage's raw candidate list was
# never kept, so it cannot be replayed; this reconstruction reproduces the CLASSES it
# identified, not its exact rows. Read the after-figure as what the fix can catch on a
# class-faithful sample, never as a field prediction.
#
# Two of the seven duplicates are deliberate PARAPHRASES of a tracked row. Dedup is exact
# normalized-key membership by design (SPEC-144), so it cannot catch those, and they survive
# as false positives after the fix. That residual is the point: a harness that scored 100%
# would only be measuring its own fixture.
#
# Run: bash tests/test-learn-propose-precision.sh
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROPOSE="$KIT_DIR/lib/learn/propose.py"
ADD_BACKLOG="$KIT_DIR/lib/board/bin/add-backlog"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/dk-propose-precision.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT

if date -v-1d >/dev/null 2>&1; then
  days_ago() { date -u -v-"$1"d +%Y-%m-%d; }
else
  days_ago() { date -u -d "-$1 days" +%Y-%m-%d; }
fi
DECAYED="$(days_ago 20)"   # staged before the drain window closed, done by triage time

# --- the labelled sample -----------------------------------------------------------------
# TRUE POSITIVES: new work, tracked nowhere.
TP=(
  "Cache the gate ledger read across lenses"
  "Fail the release job when the changelog target is missing"
  "Teach the drain renderer to group by home"
  "Record the verifier verdict alongside the token count"
)
# DUPLICATES tracked on a cross-repo cockpit board (exact title).
DUP_COCKPIT=(
  "Port the NFT contract to the new chain"
  "Retire the EKS ingress controller"
  "Fold the ICY top-up gate into the treasury check"
)
# DUPLICATES tracked in a megagoal TODO (exact title).
DUP_MEGAGOAL=(
  "Backfill the token metadata"
  "Retire the legacy indexer"
)
# DUPLICATES tracked, but PARAPHRASED. Exact-key dedup cannot see these; they stay FPs.
DUP_PARAPHRASE=(
  "Move the NFT contract onto the new chain"
  "Remove the EKS ingress controller"
)
# ALREADY DONE: valid when staged, shipped during the drain window (the decay class).
DECAY=(
  "Merge the six pending pull requests"
  "Cut the 2.2.0 release"
  "Delete the retired session-intel bin entries"
  "Wire the memory-sweep lens into the aggregate"
  "Drop the standalone add-backlog forwarder"
)
# MIS-HOMED: filed against a repo the cited file does not live in.
MISHOMED=("Widen the rustfmt guard")

FP_TOTAL=$(( ${#DUP_COCKPIT[@]} + ${#DUP_MEGAGOAL[@]} + ${#DUP_PARAPHRASE[@]} + ${#DECAY[@]} + ${#MISHOMED[@]} ))
N_TOTAL=$(( ${#TP[@]} + FP_TOTAL ))

# --- the tracking surfaces the widened anchor is supposed to read -------------------------
mkdir -p "$TMPD/other" "$TMPD/megagoals/nft-migration" "$TMPD/homes/dotfiles"
{ echo "| ID | Item | Notes | Status |"; echo "|---|---|---|---|"
  for t in "${DUP_COCKPIT[@]}"; do echo "| CL-001 | $t | tracked elsewhere | executing |"; done
} > "$TMPD/other/BACKLOG.md"
printf '# registry\nother  %s/other/BACKLOG.md\n' "$TMPD" > "$TMPD/boards.txt"
{ echo "# TODO"; echo
  for t in "${DUP_MEGAGOAL[@]}"; do echo "- [ ] $t -- owner: @tieubao"; done
} > "$TMPD/megagoals/nft-migration/TODO.md"

# The mis-homed candidate cites a file that exists HERE and not in the named home.
mkdir -p "$TMPD/repo/hooks" "$TMPD/repo/_meta"
git -C "$TMPD/repo" init -q 2>/dev/null
git -C "$TMPD/homes/dotfiles" init -q 2>/dev/null
echo "guard body" > "$TMPD/repo/hooks/rustfmt-guard.sh"

# --- the mocked propose seams -------------------------------------------------------------
cat > "$TMPD/agg.json" <<'EOF'
{"window":{"days":30,"megas":null,"rids":["r1"],"n_rids":1},
 "signals":[{"id":"S1","lens":"gate-yield","figure":"spec-validate override_pct=40","rids":["r1"],"detail":{}}]}
EOF
cat > "$TMPD/verify-holds.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null; echo 'VERDICT: HOLDS'
EOF
chmod +x "$TMPD/verify-holds.sh"

# Every candidate is a well-formed, grounded, HOLDS-verified hypothesis: this harness measures
# the dedup + promote gates, not the grounding and refute gates the existing suite covers.
{
  printf '#!/usr/bin/env bash\ncat >/dev/null\ncat <<%s\n[\n' "'JSON'"
  first=1
  emit() {
    local title="$1" home="$2" intent="$3"
    [ "$first" -eq 1 ] || printf ',\n'
    first=0
    printf '{"title":"%s","intent":"%s","approach":"do it","u":"mid","f":"mid","home":"%s","signal":"S1"}' \
      "$title" "$intent" "$home"
  }
  for t in "${TP[@]}" "${DUP_COCKPIT[@]}" "${DUP_MEGAGOAL[@]}" "${DUP_PARAPHRASE[@]}" "${DECAY[@]}"; do
    emit "$t" "" "real reasoning about $t"
  done
  emit "${MISHOMED[0]}" "dotfiles" "the guard in hooks/rustfmt-guard.sh only covers one path"
  printf '\n]\nJSON\n'
} > "$TMPD/interp.sh"
chmod +x "$TMPD/interp.sh"

# --- one measurement run ------------------------------------------------------------------
# $1 = label, $2 = "on" | "off" (the ID-305 surfaces). Echoes the count that reached the board.
measure() {
  local label="$1" mode="$2"
  local dir="$TMPD/run-$label"
  mkdir -p "$dir/_meta" "$dir/hooks"
  cp "$TMPD/repo/hooks/rustfmt-guard.sh" "$dir/hooks/"
  git -C "$dir" init -q 2>/dev/null
  local staging="$dir/_meta/backlog-staging.md" board="$dir/_meta/BACKLOG.md"
  printf '| ID | Item | Notes | Status |\n|---|---|---|---|\n' > "$board"

  local cockpit="$TMPD/boards.txt" megagoals="$TMPD/megagoals" homes="$TMPD/homes" maxage=14
  if [ "$mode" = "off" ]; then
    # Pre-fix behaviour, reached through configuration: the anchor sees neither surface, the
    # promote gate has no window and no home root to resolve against.
    cockpit="$TMPD/absent-registry.txt"; megagoals="$TMPD/absent-megagoals"
    homes="$TMPD/absent-homes"; maxage=99999
  fi

  LEARN_PROPOSE_INTERPRETER="$TMPD/interp.sh" LEARN_PROPOSE_VERIFIER="$TMPD/verify-holds.sh" \
  LEARN_PROPOSE_RID="precision-$label" DWARVES_KIT_LOG_DIR="$dir/logs" \
  LEARN_PROPOSE_COCKPIT="$cockpit" LEARN_PROPOSE_MEGAGOALS="$megagoals" \
  REPO_ROOT="$dir" BACKLOG_STAGE_STAGING="$staging" BACKLOG_STAGE_BACKLOG="$board" \
    python3 "$PROPOSE" --aggregate-file "$TMPD/agg.json" >"$dir/propose.out" 2>&1

  # Age the decay class back to when it was actually staged. Their work shipped during the
  # drain window; only the staging date can tell the promote gate that.
  if [ -f "$staging" ]; then
    for t in "${DECAY[@]}"; do
      python3 - "$staging" "$t" "$DECAYED" <<'PY'
import re, sys
path, title, when = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read()
i = text.find("## [staged] " + title)
if i >= 0:
    j = text.find("## [", i + 4)
    j = len(text) if j < 0 else j
    block = re.sub(r"(?m)^(- Source: .*?)\d{4}-\d{2}-\d{2}", r"\g<1>" + when, text[i:j], count=1)
    open(path, "w", encoding="utf-8").write(text[:i] + block + text[j:])
PY
    done
  fi

  (cd "$dir" && BACKLOG_PROMOTE_HOMES="$homes" BOARD_PROMOTE_MAX_AGE_DAYS="$maxage" \
    BACKLOG_STAGE_STAGING="$staging" BACKLOG_STAGE_BACKLOG="$board" \
    python3 "$ADD_BACKLOG" all) >"$dir/promote.out" 2>&1

  grep -cE '^\| ID-[0-9]+ \|' "$board" 2>/dev/null || echo 0
}

on_board_off="$(measure off off)"
on_board_on="$(measure on on)"

tp_on_board() {   # true positives that reached the board in run $1
  local dir="$TMPD/run-$1" n=0
  for t in "${TP[@]}"; do grep -qF "| $t |" "$dir/_meta/BACKLOG.md" && n=$((n+1)); done
  echo "$n"
}
TP_OFF="$(tp_on_board off)"; TP_ON="$(tp_on_board on)"
pct() { python3 -c "print(f'{100*$1/$2:.0f}%' if $2 else 'n/a')"; }

echo ""
echo "== ID-305 promote-precision, $N_TOTAL labelled candidates ($((${#TP[@]})) genuinely new, $FP_TOTAL false positives) =="
printf '  %-28s %-10s %-10s %s\n' "" "reached board" "true pos" "precision"
printf '  %-28s %-10s %-10s %s\n' "before (surfaces off)" "$on_board_off" "$TP_OFF" "$(pct "$TP_OFF" "$on_board_off")"
printf '  %-28s %-10s %-10s %s\n' "after  (surfaces on)"  "$on_board_on"  "$TP_ON"  "$(pct "$TP_ON" "$on_board_on")"
echo "  residual false positives after the fix: $((on_board_on - TP_ON)) (the paraphrased duplicates; exact-key dedup by design)"
echo ""

# --- assertions ---------------------------------------------------------------------------
[ "$on_board_off" -eq "$N_TOTAL" ] \
  && ok "before: every candidate reached the board ($N_TOTAL)" \
  || bad "before: expected $N_TOTAL on the board, got $on_board_off"
[ "$TP_ON" -eq "${#TP[@]}" ] \
  && ok "after: no true positive was lost (${#TP[@]}/${#TP[@]})" \
  || bad "after: lost a true positive ($TP_ON/${#TP[@]})"
[ "$on_board_on" -lt "$on_board_off" ] \
  && ok "after: fewer candidates reached the board ($on_board_on < $on_board_off)" \
  || bad "after: the gates caught nothing ($on_board_on vs $on_board_off)"
python3 -c "import sys; sys.exit(0 if $TP_ON*$on_board_off > $TP_OFF*$on_board_on else 1)" \
  && ok "after: precision rose" || bad "after: precision did not rise"
[ "$((on_board_on - TP_ON))" -eq "${#DUP_PARAPHRASE[@]}" ] \
  && ok "residual is exactly the paraphrased duplicates (${#DUP_PARAPHRASE[@]})" \
  || bad "residual is $((on_board_on - TP_ON)), expected ${#DUP_PARAPHRASE[@]}"

echo ""
echo "== $((PASS+FAIL)) run, $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
