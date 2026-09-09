#!/usr/bin/env bash
# test-learn-propose.sh -- SPEC-195 `learn propose` (harness-loop SG-05).
#
# Stages 2-3 (interpret + adversarial-check + dedup + staged write) are exercised with an
# INJECTED aggregate (--aggregate-file) and MOCKED LLM seams (LEARN_PROPOSE_INTERPRETER /
# LEARN_PROPOSE_VERIFIER), so the propose-only / cite-the-number / dedup-hard disciplines
# are proven without a live model or live stats. Stage 1 (the live stats aggregate) is
# proven by the LIVE run in docs/verification/loop-05-retro-cycle.md.
#
# Run: bash tests/test-learn-propose.sh
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROPOSE="$KIT_DIR/lib/learn/propose.py"
SF="$KIT_DIR/lib/learn/staging-format.py"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
assert_true() { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }

# A fresh sandbox per test: an injected aggregate, a HOLDS interpreter+verifier by default,
# isolated staging/board/ledger. Sets TD, AGG, STAGING, BACKLOG. Exports the seams.
setup() {
  TD="$(mktemp -d)"; SANDBOXES+=("$TD")
  AGG="$TD/agg.json"; STAGING="$TD/staging.md"; BACKLOG="$TD/BACKLOG.md"
  cat > "$AGG" <<'EOF'
{"window":{"days":30,"megas":null,"rids":["loop-05","loop-04"],"n_rids":2},
 "signals":[
  {"id":"S1","lens":"gate-yield","figure":"spec-validate override_pct=40","rids":["loop-05","loop-04"],"detail":{}},
  {"id":"S2","lens":"memory-sweep","figure":"12 memory notes reference dead paths","rids":["loop-05"],"detail":{}}
 ]}
EOF
  cat > "$TD/verify-holds.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null; echo 'VERDICT: HOLDS'
EOF
  cat > "$TD/verify-refute.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null; echo 'VERDICT: REFUTED'
EOF
  cat > "$TD/verify-garbled.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null; echo 'hmm, not sure'
EOF
  chmod +x "$TD"/verify-*.sh
  export BACKLOG_STAGE_STAGING="$STAGING" BACKLOG_STAGE_BACKLOG="$BACKLOG"
  export LEARN_PROPOSE_RID="test-rid" DWARVES_KIT_LOG_DIR="$TD/logs"
  export LEARN_PROPOSE_VERIFIER="$TD/verify-holds.sh"
  # The widened dedup anchor reads a cockpit registry + a megagoal tree. Point both at the
  # sandbox so a suite run never reads (or is deduped by) the real repo's surfaces.
  export LEARN_PROPOSE_COCKPIT="$TD/boards.txt" LEARN_PROPOSE_MEGAGOALS="$TD/megagoals"
}
# write a mock interpreter emitting the given JSON array literal
mock_interp() { cat > "$TD/interp.sh" <<EOF
#!/usr/bin/env bash
cat >/dev/null; cat <<'JSON'
$1
JSON
EOF
chmod +x "$TD/interp.sh"; export LEARN_PROPOSE_INTERPRETER="$TD/interp.sh"; }

SANDBOXES=()
cleanup() { for d in "${SANDBOXES[@]:-}"; do [ -n "$d" ] && [ -d "$d" ] && mv "$d" "${d}.done" 2>/dev/null || true; done; }
trap cleanup EXIT

# ============================================================
echo "== happy path: a grounded hypothesis is staged with a cited Source =="
# ============================================================
setup
mock_interp '[{"title":"Clarify the spec Design block","intent":"reduce denials","approach":"add example","u":"mid","f":"hi","home":"dwarves-kit","signal":"S1"}]'
OUT="$(python3 "$PROPOSE" --aggregate-file "$AGG" 2>&1)"; RC=$?
assert_true "happy: exit 0" "$([ $RC -eq 0 ]; echo $?)"
assert_true "happy: one block staged" "$(grep -qc '## \[staged\] Clarify the spec Design block' "$STAGING"; echo $?)"
assert_true "happy: Source cites lens" "$(grep -q 'Source: learn propose .* lens=gate-yield' "$STAGING"; echo $?)"
assert_true "happy: Source cites figure" "$(grep -q 'figure="spec-validate override_pct=40"' "$STAGING"; echo $?)"
assert_true "happy: Source cites rids" "$(grep -q 'rids=loop-05,loop-04' "$STAGING"; echo $?)"

# ============================================================
echo "== honest-empty: an empty aggregate stages 0, leaves staging untouched, exits 0 =="
# ============================================================
setup
echo '{"window":{"days":30,"megas":null,"rids":[],"n_rids":0},"signals":[]}' > "$AGG"
mock_interp '[{"title":"should not appear","intent":"x","approach":"y","u":"lo","f":"lo","home":"","signal":"S1"}]'
OUT="$(python3 "$PROPOSE" --aggregate-file "$AGG" 2>&1)"; RC=$?
assert_true "honest-empty: exit 0" "$([ $RC -eq 0 ]; echo $?)"
assert_true "honest-empty: prints 0 candidates" "$({ trap '' PIPE; echo "$OUT" 2>/dev/null || :; } | grep -q '0 candidates'; echo $?)"
assert_true "honest-empty: staging file NOT created" "$([ ! -f "$STAGING" ]; echo $?)"

# ============================================================
echo "== idempotency: an immediate re-run stages nothing new =="
# ============================================================
setup
mock_interp '[{"title":"Clarify the spec Design block","intent":"reduce denials","approach":"add example","u":"mid","f":"hi","home":"dwarves-kit","signal":"S1"}]'
python3 "$PROPOSE" --aggregate-file "$AGG" >/dev/null 2>&1
N1="$(grep -c '## \[staged\]' "$STAGING")"
OUT="$(python3 "$PROPOSE" --aggregate-file "$AGG" 2>&1)"
N2="$(grep -c '## \[staged\]' "$STAGING")"
assert_true "idempotency: first run staged exactly 1" "$([ "$N1" -eq 1 ]; echo $?)"
assert_true "idempotency: second run added nothing" "$([ "$N1" -eq "$N2" ]; echo $?)"
assert_true "idempotency: re-run reports duplicate drop" "$({ trap '' PIPE; echo "$OUT" 2>/dev/null || :; } | grep -q 'duplicate'; echo $?)"

# ============================================================
echo "== grounding drop: a hypothesis citing an unknown signal id is dropped =="
# ============================================================
setup
mock_interp '[{"title":"Ungrounded proposal","intent":"x","approach":"y","u":"lo","f":"lo","home":"","signal":"S99"}]'
OUT="$(python3 "$PROPOSE" --aggregate-file "$AGG" 2>&1)"
assert_true "grounding: ungrounded proposal NOT staged" "$([ ! -f "$STAGING" ] || ! grep -q 'Ungrounded proposal' "$STAGING"; echo $?)"
assert_true "grounding: reports ungrounded drop" "$({ trap '' PIPE; echo "$OUT" 2>/dev/null || :; } | grep -q '1 ungrounded'; echo $?)"

# ============================================================
echo "== adversarial drop: a REFUTED hypothesis is dropped (fail-closed also drops garbled) =="
# ============================================================
setup
mock_interp '[{"title":"Refuted proposal","intent":"x","approach":"y","u":"mid","f":"mid","home":"","signal":"S1"}]'
export LEARN_PROPOSE_VERIFIER="$TD/verify-refute.sh"
OUT="$(python3 "$PROPOSE" --aggregate-file "$AGG" 2>&1)"
assert_true "adversarial: REFUTED proposal NOT staged" "$([ ! -f "$STAGING" ] || ! grep -q 'Refuted proposal' "$STAGING"; echo $?)"
assert_true "adversarial: reports refuted drop" "$({ trap '' PIPE; echo "$OUT" 2>/dev/null || :; } | grep -q '1 refuted'; echo $?)"
setup
mock_interp '[{"title":"Garbled-verdict proposal","intent":"x","approach":"y","u":"mid","f":"mid","home":"","signal":"S1"}]'
export LEARN_PROPOSE_VERIFIER="$TD/verify-garbled.sh"
OUT="$(python3 "$PROPOSE" --aggregate-file "$AGG" 2>&1)"
assert_true "fail-closed: a garbled/no-clear verdict drops the proposal" "$([ ! -f "$STAGING" ] || ! grep -q 'Garbled-verdict proposal' "$STAGING"; echo $?)"

# ============================================================
echo "== anchored dedup (SPEC-144 Run-3): a suffix-key survives, an exact-key drops =="
# ============================================================
# Seed staging with a REJECTED block whose normalized key is a SUPERSTRING of the new
# proposal's key. A substring/containment dedup would WRONGLY drop the shorter key; exact
# normalized-key set membership does not. Then confirm the exact-key duplicate IS dropped.
setup
cat > "$STAGING" <<'EOF'
# Backlog staging

## [rejected] improve the spec template design block
- Intent: prior rejected proposal
- Approach: n/a
- Tags: #u-lo #f-lo
- Source: learn propose 2026-07-01 | lens=x figure="y" rids=r0
EOF
mock_interp '[{"title":"design block","intent":"a shorter suffix-key proposal","approach":"z","u":"mid","f":"hi","home":"dwarves-kit","signal":"S1"}]'
python3 "$PROPOSE" --aggregate-file "$AGG" >/dev/null 2>&1
assert_true "dedup: suffix-key proposal is NOT wrongly deduped (survives)" "$(grep -q '## \[staged\] design block' "$STAGING"; echo $?)"
# now an EXACT-key duplicate of the rejected block must drop
setup
cat > "$STAGING" <<'EOF'
# Backlog staging

## [rejected] improve the spec template design block
- Intent: prior rejected proposal
- Approach: n/a
- Tags: #u-lo #f-lo
- Source: learn propose 2026-07-01 | lens=x figure="y" rids=r0
EOF
mock_interp '[{"title":"Improve the Spec Template Design Block","intent":"same idea, different case","approach":"z","u":"mid","f":"hi","home":"dwarves-kit","signal":"S1"}]'
OUT="$(python3 "$PROPOSE" --aggregate-file "$AGG" 2>&1)"
assert_true "dedup: exact normalized-key duplicate of a rejected row IS dropped" "$([ "$(grep -c '## \[staged\]' "$STAGING")" -eq 0 ]; echo $?)"

# ============================================================
echo "== TOKENS: both LLM passes emit a marker to the run ledger =="
# ============================================================
setup
mock_interp '[{"title":"Token test proposal","intent":"x","approach":"y","u":"mid","f":"mid","home":"","signal":"S1"}]'
python3 "$PROPOSE" --aggregate-file "$AGG" >/dev/null 2>&1
TOKN="$(grep -c '| TOKENS |' "$TD/logs/runs/test-rid.log" 2>/dev/null || echo 0)"
# one interpret pass + one adversarial pass over one grounded hypothesis = 2 markers minimum
assert_true "tokens: at least 2 TOKENS markers emitted (interpret + adversarial)" "$([ "$TOKN" -ge 2 ]; echo $?)"

# ============================================================
echo "== staging_format: render -> parse round-trip recovers fields =="
# ============================================================
setup
python3 "$SF" render > "$TD/block.md" <<'EOF'
{"title":"Round trip","intent":"i","approach":"a","u":"hi","f":"lo","home":"h","source":"learn propose 2026-07-12 | lens=L figure=\"F\" rids=r1"}
EOF
PARSED="$(python3 "$SF" parse "$TD/block.md" 2>&1)"
assert_true "round-trip: state is staged" "$({ trap '' PIPE; echo "$PARSED" 2>/dev/null || :; } | grep -q '\"state\": \"staged\"'; echo $?)"
assert_true "round-trip: title recovered" "$({ trap '' PIPE; echo "$PARSED" 2>/dev/null || :; } | grep -q '\"title\": \"Round trip\"'; echo $?)"
assert_true "round-trip: Source field recovered" "$({ trap '' PIPE; echo "$PARSED" 2>/dev/null || :; } | grep -q 'lens=L figure'; echo $?)"

# ============================================================
echo "== add-backlog compatibility: a staged block parses under the (unmodified) reader =="
# ============================================================
setup
mock_interp '[{"title":"Compat check","intent":"i","approach":"a","u":"mid","f":"mid","home":"dwarves-kit","signal":"S1"}]'
python3 "$PROPOSE" --aggregate-file "$AGG" >/dev/null 2>&1
LIST="$(BACKLOG_STAGE_STAGING="$STAGING" BACKLOG_STAGE_BACKLOG="$BACKLOG" python3 "$KIT_DIR/lib/board/bin/add-backlog" 2>&1)"
assert_true "compat: add-backlog lists the staged block as a promotable row" "$({ trap '' PIPE; echo "$LIST" 2>/dev/null || :; } | grep -q 'Compat check'; echo $?)"

# ============================================================
echo "== rid fallback: TOKENS still land when the gate-rid call fails (master/detached) =="
# ============================================================
# `gate-ledger.sh rid` exits 1 empty on master/detached HEAD; the tokens verb refuses an
# empty rid. _rid() must fall back to a date slug so TOKENS never goes dark. Proven by
# breaking the gate path so the subprocess errors and asserting the fallback string.
RID_OUT="$(cd "$KIT_DIR" && python3 - <<'PY'
import sys, os, datetime
sys.path.insert(0, "lib/learn")
import propose
propose.KIT_ROOT = "/nonexistent-kit-root-xyz"   # gate-ledger.sh absent -> rid falls back
os.environ.pop("LEARN_PROPOSE_RID", None)
os.environ.pop("REPO_ROOT", None)
rid = propose._rid()
print(rid)
print("OK" if rid == "learn-propose-" + datetime.date.today().isoformat() else "BAD")
PY
)"
assert_true "rid: falls back to a date slug when gate-rid is unavailable" "$({ trap '' PIPE; echo "$RID_OUT" 2>/dev/null || :; } | grep -q '^OK$'; echo $?)"

# ============================================================
echo "== empty-figure grounding: a signal present but with an empty figure is not evidence =="
# ============================================================
setup
echo '{"window":{"days":30,"megas":null,"rids":["r1"],"n_rids":1},"signals":[{"id":"S1","lens":"x","figure":"","rids":["r1"],"detail":{}}]}' > "$AGG"
mock_interp '[{"title":"Empty-figure proposal","intent":"x","approach":"y","u":"mid","f":"mid","home":"","signal":"S1"}]'
OUT="$(python3 "$PROPOSE" --aggregate-file "$AGG" 2>&1)"
assert_true "empty-figure: a hypothesis citing an empty-figure signal is dropped ungrounded" "$([ ! -f "$STAGING" ] || ! grep -q 'Empty-figure proposal' "$STAGING"; echo $?)"
assert_true "empty-figure: reported as ungrounded" "$({ trap '' PIPE; echo "$OUT" 2>/dev/null || :; } | grep -q '1 ungrounded'; echo $?)"

# ============================================================
echo "== figure sanitization: a multi-line / pipe-laden figure stays one Source line =="
# ============================================================
setup
printf '%s' '{"window":{"days":30,"megas":null,"rids":["r1","r2"],"n_rids":2},"signals":[{"id":"S1","lens":"memory-sweep","figure":"line one\nline | two","rids":["r1","r2"],"detail":{}}]}' > "$AGG"
mock_interp '[{"title":"Sanitized citation","intent":"x","approach":"y","u":"mid","f":"mid","home":"","signal":"S1"}]'
python3 "$PROPOSE" --aggregate-file "$AGG" >/dev/null 2>&1
assert_true "sanitize: exactly one staged block (figure newline did not split it)" "$([ "$(grep -c '## \[staged\]' "$STAGING")" -eq 1 ]; echo $?)"
assert_true "sanitize: the Source line still carries rids (citation not truncated)" "$(grep -q 'Source: learn propose.*rids=r1,r2' "$STAGING"; echo $?)"
assert_true "sanitize: block round-trips under the reader (still one parsed block)" "$([ "$(python3 "$SF" parse "$STAGING" | grep -c '\"state\":')" -eq 1 ]; echo $?)"

# ============================================================
echo "== rids cap: a wide window is cited as a bounded sample + count, not a wall of ids =="
# ============================================================
setup
python3 - "$AGG" <<'PY'
import json, sys
rids = [f"rid-{i:03d}" for i in range(30)]
json.dump({"window":{"days":30,"megas":None,"rids":rids,"n_rids":30},
          "signals":[{"id":"S1","lens":"gate-yield","figure":"spec override_pct=40","rids":rids,"detail":{}}]},
         open(sys.argv[1],"w"))
PY
mock_interp '[{"title":"Wide window proposal","intent":"x","approach":"y","u":"mid","f":"mid","home":"","signal":"S1"}]'
python3 "$PROPOSE" --aggregate-file "$AGG" >/dev/null 2>&1
assert_true "rids-cap: citation shows a +N more sample, not all 30 ids" "$(grep -qE 'rids=rid-000,.*,\+22 more' "$STAGING"; echo $?)"
assert_true "rids-cap: Source is still ONE line (grep -c the block's Source)" "$([ "$(grep -c '^- Source:' "$STAGING")" -eq 1 ]; echo $?)"

# ============================================================
echo "== subprocess failure: a crashing interpreter degrades to honest-empty (exit 0) =="
# ============================================================
setup
cat > "$TD/interp-fail.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null; exit 1
EOF
chmod +x "$TD/interp-fail.sh"; export LEARN_PROPOSE_INTERPRETER="$TD/interp-fail.sh"
OUT="$(python3 "$PROPOSE" --aggregate-file "$AGG" 2>&1)"; RC=$?
assert_true "subprocess-fail: exit 0 (never blocks)" "$([ $RC -eq 0 ]; echo $?)"
assert_true "subprocess-fail: 0 candidates, staging untouched" "$([ ! -f "$STAGING" ]; echo $?)"

# ---- SPEC-200 T7: a retro's action items reach the Learn gate ------------------------------
# /kit:retro wrote its outcomes as a checkbox list inside docs/retro/RETRO-<date>.md. `board
# promote` reads ONLY the staging buffer, so those items could never be promoted: a human had to
# retype one to act on it, and so nobody did. Same disease session-intel had (T6).
echo ""
echo "== T7: learn propose --retro stages a retro's action items =="
RT="$(mktemp -d)"
cat > "$RT/RETRO-2026-07-15.md" <<'EOF'
# Retro: a cycle
## What worked
- the negative controls.
## Action items
- [ ] Route Explore subagents to Haiku instead of the inherited Opus -- owner: @tieubao -- deadline: 2026-07-22
- [ ] Compose commit subjects under 72 chars -- owner: tieubao
- [x] Close the money-gate snake_case hole
- [ ] [concrete change] -- owner: [person] -- deadline: [date]
## Kit feedback
- ship-gate fired late.
EOF
printf '# Board\n\n| ID | Item | Notes | Status |\n|---|---|---|---|\n' > "$RT/BACKLOG.md"
RSTG="$RT/staging.md"

OUT="$(python3 "$PROPOSE" --retro "$RT/RETRO-2026-07-15.md" --staging "$RSTG" --backlog "$RT/BACKLOG.md" 2>&1)"
[ "$(grep -c '^## \[staged\]' "$RSTG" 2>/dev/null || echo 0)" = "2" ]
assert_true "T7a: the two OPEN action items are staged" $?
grep -q '^## \[staged\] Route Explore subagents to Haiku instead of the inherited Opus$' "$RSTG"
assert_true "T7b: the title is the change alone (owner/deadline stripped, not swallowed)" $?
grep -q '^- Source: retro 2026-07-15 | RETRO-2026-07-15.md owner=@tieubao' "$RSTG"
assert_true "T7c: owner rides on the citation as a GitHub handle (@tieubao)" $?
# The second item writes a BARE handle; it must be normalized to @handle, not passed through.
grep -c 'owner=@tieubao' "$RSTG" | grep -q '^2$'
assert_true "T7c2: a bare handle is normalized to @tieubao (both items)" $?

# NEGATIVE CONTROL: a CHECKED item is already done; staging it would propose finished work.
grep -q 'snake_case' "$RSTG" && bad "T7d NC: a [x] item was staged" || ok "T7d NC: a checked [x] item is NOT staged"
# NEGATIVE CONTROL: the template placeholder is not an action item.
grep -q 'concrete change' "$RSTG" && bad "T7e NC: the template placeholder was staged" || ok "T7e NC: the template placeholder is NOT staged"
# NEGATIVE CONTROL: the board is never written (propose-don't-dispose).
B1="$(shasum -a 256 "$RT/BACKLOG.md" | cut -d' ' -f1)"
python3 "$PROPOSE" --retro "$RT/RETRO-2026-07-15.md" --staging "$RSTG" --backlog "$RT/BACKLOG.md" >/dev/null 2>&1
B2="$(shasum -a 256 "$RT/BACKLOG.md" | cut -d' ' -f1)"
[ "$B1" = "$B2" ]; assert_true "T7f NC: the board is byte-identical after propose --retro" $?
# idempotent: the re-run above must stage nothing new
[ "$(grep -c '^## \[staged\]' "$RSTG")" = "2" ]
assert_true "T7g: re-running stages nothing new (deduped)" $?
# NEGATIVE CONTROL: --dry-run writes no file at all
DRY="$RT/dry.md"
python3 "$PROPOSE" --retro "$RT/RETRO-2026-07-15.md" --staging "$DRY" --backlog "$RT/BACKLOG.md" --dry-run >/dev/null 2>&1
[ ! -f "$DRY" ]; assert_true "T7h NC: --dry-run writes NO staging file" $?
rm -rf "$RT"

# ============================================================
echo "== ID-305 widened anchor: a cockpit board and a megagoal TODO both dedup =="
# ============================================================
# ID-294 measured 28/69 staged candidates duplicating work tracked on a cross-repo cockpit
# board or a megagoal TODO. The anchor read neither surface, so that work re-staged as new.
setup
mkdir -p "$TD/other" "$TD/megagoals/nft-migration"
cat > "$TD/other/BACKLOG.md" <<'EOF'
| ID | Item | Notes | Status |
|---|---|---|---|
| CL-001 | Port the NFT contract to the new chain | tracked elsewhere | executing |
EOF
printf '# registry\nother  %s/other/BACKLOG.md\n' "$TD" > "$TD/boards.txt"
cat > "$TD/megagoals/nft-migration/TODO.md" <<'EOF'
# TODO

- [ ] Retire the legacy indexer -- owner: @tieubao
- [x] Backfill the token metadata
EOF
mock_interp '[
 {"title":"Port the NFT contract to the new chain","intent":"x","approach":"y","u":"mid","f":"mid","home":"","signal":"S1"},
 {"title":"Retire the legacy indexer","intent":"x","approach":"y","u":"mid","f":"mid","home":"","signal":"S1"},
 {"title":"Backfill the token metadata","intent":"x","approach":"y","u":"mid","f":"mid","home":"","signal":"S1"},
 {"title":"Genuinely new proposal","intent":"x","approach":"y","u":"mid","f":"mid","home":"","signal":"S1"}]'
OUT="$(python3 "$PROPOSE" --aggregate-file "$AGG" 2>&1)"
assert_true "widened: a cockpit board row is deduped" "$([ ! -f "$STAGING" ] || ! grep -q 'Port the NFT contract' "$STAGING"; echo $?)"
assert_true "widened: an OPEN megagoal TODO item is deduped" "$([ ! -f "$STAGING" ] || ! grep -q 'Retire the legacy indexer' "$STAGING"; echo $?)"
assert_true "widened: a DONE megagoal TODO item is deduped too" "$([ ! -f "$STAGING" ] || ! grep -q 'Backfill the token metadata' "$STAGING"; echo $?)"
assert_true "widened: 3 duplicates reported" "$({ trap '' PIPE; echo "$OUT" 2>/dev/null || :; } | grep -q '3 duplicate'; echo $?)"
# NEGATIVE CONTROL: the widening must not swallow a candidate that matches NOTHING.
assert_true "widened NC: an unmatched proposal still stages" "$(grep -q '## \[staged\] Genuinely new proposal' "$STAGING"; echo $?)"

# NEGATIVE CONTROL: with both surfaces absent, the same batch stages all four. This is the
# pre-fix behaviour, and it is what makes the three drops above attributable to the widening.
setup
mock_interp '[
 {"title":"Port the NFT contract to the new chain","intent":"x","approach":"y","u":"mid","f":"mid","home":"","signal":"S1"},
 {"title":"Retire the legacy indexer","intent":"x","approach":"y","u":"mid","f":"mid","home":"","signal":"S1"},
 {"title":"Backfill the token metadata","intent":"x","approach":"y","u":"mid","f":"mid","home":"","signal":"S1"},
 {"title":"Genuinely new proposal","intent":"x","approach":"y","u":"mid","f":"mid","home":"","signal":"S1"}]'
python3 "$PROPOSE" --aggregate-file "$AGG" >/dev/null 2>&1
assert_true "widened NC: no cockpit + no megagoal stages all 4" "$([ "$(grep -c '## \[staged\]' "$STAGING")" -eq 4 ]; echo $?)"

echo ""
echo "== $((PASS+FAIL)) run, $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
