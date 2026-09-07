#!/bin/bash
# test-kit-foldin-hooks.sh -- fixture tests for the 4 kit-foldin hooks (kit-foldin
# sub-goal 02): backlog-stage, citation-guard, context-hints, harvest. Each is a
# function-named port of an ops-toolkit cc-* tool (design note
# research/2026-07-05-cc-elevation-kit-foldin-design.md); this pins the ported
# behavior + fail-open/fail-closed posture + the two-manifest registration.
#
# Run: bash tests/test-kit-foldin-hooks.sh
# Exit 0 = all tests pass. Exit 1 = failures found.

KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TD="$(mktemp -d "${TMPDIR:-/tmp}/kit-foldin-hooks-test.XXXXXX")"
trap 'rm -rf "${TD:?}"' EXIT

PASS=0
FAIL=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_exit() {
  local NAME="$1" EXPECTED="$2" ACTUAL="$3"
  TOTAL=$((TOTAL + 1))
  if [ "$ACTUAL" -eq "$EXPECTED" ]; then
    echo -e "  ${GREEN}PASS${NC} $NAME (exit $ACTUAL)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} $NAME (expected exit $EXPECTED, got $ACTUAL)"
    FAIL=$((FAIL + 1))
  fi
}

assert_eq() {
  local NAME="$1" EXPECTED="$2" ACTUAL="$3"
  TOTAL=$((TOTAL + 1))
  if [ "$ACTUAL" = "$EXPECTED" ]; then
    echo -e "  ${GREEN}PASS${NC} $NAME"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} $NAME (expected '$EXPECTED', got '$ACTUAL')"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local NAME="$1" NEEDLE="$2" HAY="$3"
  TOTAL=$((TOTAL + 1))
  if { trap '' PIPE; printf '%s' "$HAY" 2>/dev/null || :; } | grep -qF "$NEEDLE"; then
    echo -e "  ${GREEN}PASS${NC} $NAME"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} $NAME (missing '$NEEDLE')"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local NAME="$1" NEEDLE="$2" HAY="$3"
  TOTAL=$((TOTAL + 1))
  if { trap '' PIPE; printf '%s' "$HAY" 2>/dev/null || :; } | grep -qF "$NEEDLE"; then
    echo -e "  ${RED}FAIL${NC} $NAME (unexpectedly found '$NEEDLE')"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${NC} $NAME"
    PASS=$((PASS + 1))
  fi
}

# Detached work lands asynchronously: poll a file for a needle instead of asserting
# right after the hook returns (the hook is expected to return before the write happens).
wait_for_file_contains() {
  local NAME="$1" NEEDLE="$2" FILE="$3" TRIES=50
  TOTAL=$((TOTAL + 1))
  while [ "$TRIES" -gt 0 ]; do
    if [ -f "$FILE" ] && grep -qF "$NEEDLE" "$FILE" 2>/dev/null; then
      echo -e "  ${GREEN}PASS${NC} $NAME"
      PASS=$((PASS + 1))
      return
    fi
    sleep 0.1
    TRIES=$((TRIES - 1))
  done
  echo -e "  ${RED}FAIL${NC} $NAME (missing '$NEEDLE' in $FILE after 5s)"
  FAIL=$((FAIL + 1))
}

# ============================================================
echo "=== context-hints.sh (UserPromptSubmit) ==="
# ============================================================
MAP="$TD/skillmap.json"
printf '{"ocr": "local-ocr-skill"}\n' > "$MAP"
STATE="$TD/ch-state"

OUT=$(CONTEXT_HINTS_SKILLMAP="$MAP" CONTEXT_HINTS_STATE="$STATE" CONTEXT_HINTS_NOW=1000 \
  bash -c "echo '{\"prompt\":\"can you OCR this file\",\"session_id\":\"sess1\"}' | bash '$KIT_DIR/hooks/context-hints.sh'")
RC=$?
assert_exit "row 1: skill hint fires on keyword match" 0 $RC
assert_contains "row 1: hint names the mapped skill" "local-ocr-skill (keyword: ocr)" "$OUT"

# NC: empty stdin never crashes / never blocks.
RC=0; echo '' | bash "$KIT_DIR/hooks/context-hints.sh" >/dev/null 2>&1 || RC=$?
assert_exit "NC: empty stdin exits 0" 0 $RC

# NC: malformed JSON never crashes / never blocks.
RC=0; echo 'not json' | bash "$KIT_DIR/hooks/context-hints.sh" >/dev/null 2>&1 || RC=$?
assert_exit "NC: malformed JSON exits 0" 0 $RC

# ID-269: session-age cache-hygiene nudge. Threshold is NUDGE_THRESHOLD_SECONDS in
# context-hints.py (6h = 21600s). Each row primes a session's "start" at t=BASE via a
# first hook call, then re-invokes at t=BASE+ELAPSED to control the elapsed value the
# hook computes (same CONTEXT_HINTS_NOW seam the row-1 test above already relies on).
NUDGE_STATE="$TD/ch-nudge-state"
NUDGE_THRESHOLD=21600

# row 5a (negative control, well under threshold): no nudge line at all.
CONTEXT_HINTS_STATE="$NUDGE_STATE" CONTEXT_HINTS_NOW=1000 \
  bash -c "echo '{\"prompt\":\"hi\",\"session_id\":\"nudge-far-under\"}' | bash '$KIT_DIR/hooks/context-hints.sh'" >/dev/null
OUT=$(CONTEXT_HINTS_STATE="$NUDGE_STATE" CONTEXT_HINTS_NOW=$((1000 + 100)) \
  bash -c "echo '{\"prompt\":\"hi\",\"session_id\":\"nudge-far-under\"}' | bash '$KIT_DIR/hooks/context-hints.sh'")
assert_not_contains "row 5a: far under threshold (100s elapsed), no nudge (negative control)" \
  "cache-hygiene rule" "$OUT"

# row 5b: just under threshold (threshold - 5s elapsed), still no nudge.
CONTEXT_HINTS_STATE="$NUDGE_STATE" CONTEXT_HINTS_NOW=2000 \
  bash -c "echo '{\"prompt\":\"hi\",\"session_id\":\"nudge-just-under\"}' | bash '$KIT_DIR/hooks/context-hints.sh'" >/dev/null
OUT=$(CONTEXT_HINTS_STATE="$NUDGE_STATE" CONTEXT_HINTS_NOW=$((2000 + NUDGE_THRESHOLD - 5)) \
  bash -c "echo '{\"prompt\":\"hi\",\"session_id\":\"nudge-just-under\"}' | bash '$KIT_DIR/hooks/context-hints.sh'")
assert_not_contains "row 5b: 5s under threshold, no nudge" "cache-hygiene rule" "$OUT"

# row 5c: just over threshold (threshold + 5s elapsed), nudge fires with the exact line.
CONTEXT_HINTS_STATE="$NUDGE_STATE" CONTEXT_HINTS_NOW=3000 \
  bash -c "echo '{\"prompt\":\"hi\",\"session_id\":\"nudge-just-over\"}' | bash '$KIT_DIR/hooks/context-hints.sh'" >/dev/null
OUT=$(CONTEXT_HINTS_STATE="$NUDGE_STATE" CONTEXT_HINTS_NOW=$((3000 + NUDGE_THRESHOLD + 5)) \
  bash -c "echo '{\"prompt\":\"hi\",\"session_id\":\"nudge-just-over\"}' | bash '$KIT_DIR/hooks/context-hints.sh'")
assert_contains "row 5c: 5s over threshold, nudge fires" \
  "consider /clear or a handoff split (cache-hygiene rule)" "$OUT"

# ============================================================
echo ""
echo "=== citation-guard.sh (Stop) ==="
# ============================================================
mkdir -p "$TD/cg-repo"
printf 'line1\nline2\nline3\n' > "$TD/cg-repo/foo.txt"
CG_TRANS="$TD/cg-transcript.jsonl"
cat > "$CG_TRANS" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"See foo.txt:2 for the good ref and foo.txt:99 for the bad ref."}]}}
EOF

RC=0
echo "{\"transcript_path\":\"$CG_TRANS\",\"cwd\":\"$TD/cg-repo\"}" \
  | bash "$KIT_DIR/hooks/citation-guard.sh" >/dev/null 2>&1 || RC=$?
assert_exit "row 2: log-only default never blocks on a bad ref" 0 $RC

CG_LOG="$TD/cg.log"
STRICT_OUT=$(CITATION_GUARD_STRICT=1 CITATION_GUARD_LOG="$CG_LOG" bash -c \
  "echo '{\"transcript_path\":\"$CG_TRANS\",\"cwd\":\"$TD/cg-repo\"}' | bash '$KIT_DIR/hooks/citation-guard.sh'" 2>&1)
RC=$?
assert_exit "row 2b: strict mode blocks (exit 2) on the bad ref" 2 $RC
assert_contains "row 2b: strict mode names the bad ref" "foo.txt:99" "$STRICT_OUT"
assert_contains "row 2b: bad ref logged" "foo.txt:99" "$(cat "$CG_LOG" 2>/dev/null)"

# NC: empty stdin never crashes.
RC=0; echo '' | bash "$KIT_DIR/hooks/citation-guard.sh" >/dev/null 2>&1 || RC=$?
assert_exit "NC: empty stdin exits 0" 0 $RC

# NC: malformed JSON never crashes.
RC=0; echo 'not json' | bash "$KIT_DIR/hooks/citation-guard.sh" >/dev/null 2>&1 || RC=$?
assert_exit "NC: malformed JSON exits 0" 0 $RC

# ============================================================
echo ""
echo "=== backlog-stage.sh (SessionEnd) ==="
# ============================================================
mkdir -p "$TD/bs-repo/_meta"
git -C "$TD/bs-repo" init -q
BS_TRANS="$TD/bs-transcript.jsonl"
cat > "$BS_TRANS" <<'EOF'
{"type":"user","message":{"content":[{"type":"text","text":"we should add a backlog item to fix the flaky deploy script later"}]}}
EOF
cat > "$TD/bs-extractor.sh" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
[{"title":"fix flaky deploy script","intent":"stop deploy flakiness","approach":"investigate retries","u":"hi","f":"mid","home":""}]
JSON
EOF
chmod +x "$TD/bs-extractor.sh"

RC=0
REPO_ROOT="$TD/bs-repo" BACKLOG_STAGE_EXTRACTOR="$TD/bs-extractor.sh" BACKLOG_STAGE_STATE_DIR="$TD/bs-state" \
  BACKLOG_STAGE_SYNC=1 \
  bash -c "echo '{\"transcript_path\":\"$BS_TRANS\"}' | bash '$KIT_DIR/hooks/backlog-stage.sh'" >/dev/null 2>&1 || RC=$?
assert_exit "row 3: stages a candidate, exits 0" 0 $RC
STAGED=$(cat "$TD/bs-repo/_meta/backlog-staging.md" 2>/dev/null)
assert_contains "row 3: staged file has the candidate (repo-relative default)" "fix flaky deploy script" "$STAGED"

# row 3b (detach fix): the DEFAULT path (no BACKLOG_STAGE_SYNC) must return fast and
# stage the candidate in a detached child -- this is what SessionEnd actually invokes.
mkdir -p "$TD/bs-repo-async/_meta"
git -C "$TD/bs-repo-async" init -q
START_NS=$(date +%s%N)
RC=0
REPO_ROOT="$TD/bs-repo-async" BACKLOG_STAGE_EXTRACTOR="$TD/bs-extractor.sh" BACKLOG_STAGE_STATE_DIR="$TD/bs-state-async" \
  bash -c "echo '{\"transcript_path\":\"$BS_TRANS\"}' | bash '$KIT_DIR/hooks/backlog-stage.sh'" >/dev/null 2>&1 || RC=$?
END_NS=$(date +%s%N)
assert_exit "row 3b: detached mode still exits 0 immediately" 0 $RC
ELAPSED_MS=$(( (END_NS - START_NS) / 1000000 ))
TOTAL=$((TOTAL + 1))
if [ "$ELAPSED_MS" -lt 2000 ]; then
  echo -e "  ${GREEN}PASS${NC} row 3b: hook returns in <2s even though the extractor call is not run yet (${ELAPSED_MS}ms)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} row 3b: hook took ${ELAPSED_MS}ms (expected <2000ms, detach not firing)"
  FAIL=$((FAIL + 1))
fi
wait_for_file_contains "row 3b: candidate lands in staging after the hook already returned" \
  "fix flaky deploy script" "$TD/bs-repo-async/_meta/backlog-staging.md"

# row 3c (the actual bug this fix targets): a SLOW extractor (the real `claude -p` call
# can take seconds) must NOT make the hook itself slow. Pre-fix, this would block for the
# full extractor duration; post-fix, the hook returns immediately regardless.
cat > "$TD/bs-slow-extractor.sh" <<'EOF'
#!/usr/bin/env bash
sleep 2
cat <<'JSON'
[{"title":"slow extractor proof","intent":"prove detach works under a real delay","approach":"sleep 2 then answer","u":"hi","f":"mid","home":""}]
JSON
EOF
chmod +x "$TD/bs-slow-extractor.sh"
mkdir -p "$TD/bs-repo-slow/_meta"
git -C "$TD/bs-repo-slow" init -q
START_NS=$(date +%s%N)
RC=0
REPO_ROOT="$TD/bs-repo-slow" BACKLOG_STAGE_EXTRACTOR="$TD/bs-slow-extractor.sh" BACKLOG_STAGE_STATE_DIR="$TD/bs-state-slow" \
  bash -c "echo '{\"transcript_path\":\"$BS_TRANS\"}' | bash '$KIT_DIR/hooks/backlog-stage.sh'" >/dev/null 2>&1 || RC=$?
END_NS=$(date +%s%N)
ELAPSED_MS=$(( (END_NS - START_NS) / 1000000 ))
assert_exit "row 3c: hook exits 0 even with a 2s-slow extractor" 0 $RC
TOTAL=$((TOTAL + 1))
if [ "$ELAPSED_MS" -lt 1000 ]; then
  echo -e "  ${GREEN}PASS${NC} row 3c: hook returns in <1s despite a 2s-slow extractor (${ELAPSED_MS}ms) -- this is the bug this fix targets"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} row 3c: hook took ${ELAPSED_MS}ms (expected <1000ms) -- hook is blocking on the slow extractor again"
  FAIL=$((FAIL + 1))
fi
wait_for_file_contains "row 3c: candidate lands ~2s later, after the slow extractor finishes" \
  "slow extractor proof" "$TD/bs-repo-slow/_meta/backlog-staging.md"

# row 3d: BACKLOG_STAGE_SYNC=1 must actually run INLINE (blocking), not just produce the
# same eventual content. Without this row, a regression that silently stopped honoring
# the SYNC env var (typo, _truthy break) would still pass every other row, since a fast
# extractor makes both the sync and detached paths finish quickly either way.
mkdir -p "$TD/bs-repo-syncslow/_meta"
git -C "$TD/bs-repo-syncslow" init -q
START_NS=$(date +%s%N)
RC=0
REPO_ROOT="$TD/bs-repo-syncslow" BACKLOG_STAGE_EXTRACTOR="$TD/bs-slow-extractor.sh" BACKLOG_STAGE_STATE_DIR="$TD/bs-state-syncslow" \
  BACKLOG_STAGE_SYNC=1 \
  bash -c "echo '{\"transcript_path\":\"$BS_TRANS\"}' | bash '$KIT_DIR/hooks/backlog-stage.sh'" >/dev/null 2>&1 || RC=$?
END_NS=$(date +%s%N)
ELAPSED_MS=$(( (END_NS - START_NS) / 1000000 ))
assert_exit "row 3d: BACKLOG_STAGE_SYNC=1 exits 0" 0 $RC
TOTAL=$((TOTAL + 1))
if [ "$ELAPSED_MS" -ge 1800 ]; then
  echo -e "  ${GREEN}PASS${NC} row 3d: BACKLOG_STAGE_SYNC=1 genuinely blocks for the extractor's 2s delay (${ELAPSED_MS}ms)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} row 3d: BACKLOG_STAGE_SYNC=1 returned in ${ELAPSED_MS}ms (expected >=1800ms) -- the sync seam is silently detaching instead of blocking"
  FAIL=$((FAIL + 1))
fi
STAGED_SYNC=$(cat "$TD/bs-repo-syncslow/_meta/backlog-staging.md" 2>/dev/null)
assert_contains "row 3d: candidate already present immediately (proves it ran inline, not async)" "slow extractor proof" "$STAGED_SYNC"

# row 3e: the detached child must be reparented into its OWN process group
# (start_new_session=True) -- the literal OS-level mechanism the whole fix's
# "survives SessionEnd's process teardown" claim rests on. Rows 3b/3c only prove the
# hook returns fast and the work eventually lands; neither proves the child is actually
# isolated from the invoking process group. Verified via `pgrep`/`ps`, not a kill/signal
# race (avoids flakiness from timing a signal against process spawn).
mkdir -p "$TD/bs-repo-pgid/_meta"
git -C "$TD/bs-repo-pgid" init -q
cat > "$TD/bs-pgid-extractor.sh" <<'EOF'
#!/usr/bin/env bash
sleep 2
cat <<'JSON'
[{"title":"pgid probe","intent":"stay alive long enough to inspect","approach":"sleep 2","u":"hi","f":"mid","home":""}]
JSON
EOF
chmod +x "$TD/bs-pgid-extractor.sh"
INVOKER_PGID=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
RC=0
REPO_ROOT="$TD/bs-repo-pgid" BACKLOG_STAGE_EXTRACTOR="$TD/bs-pgid-extractor.sh" BACKLOG_STAGE_STATE_DIR="$TD/bs-state-pgid" \
  bash -c "echo '{\"transcript_path\":\"$BS_TRANS\"}' | bash '$KIT_DIR/hooks/backlog-stage.sh'" >/dev/null 2>&1 || RC=$?
sleep 0.3
CHILD_PID=$(pgrep -f "bs-pgid-extractor.sh" | head -1)
TOTAL=$((TOTAL + 1))
if [ -n "$CHILD_PID" ]; then
  CHILD_PGID=$(ps -o pgid= -p "$CHILD_PID" 2>/dev/null | tr -d ' ')
  if [ -n "$CHILD_PGID" ] && [ "$CHILD_PGID" != "$INVOKER_PGID" ]; then
    echo -e "  ${GREEN}PASS${NC} row 3e: detached child (pgid=$CHILD_PGID) is in a DIFFERENT process group than the invoker (pgid=$INVOKER_PGID) -- would survive the invoker's group being torn down"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} row 3e: detached child shares the invoker's process group (pgid=$CHILD_PGID) -- would be killed alongside it"
    FAIL=$((FAIL + 1))
  fi
else
  echo -e "  ${RED}FAIL${NC} row 3e: could not find the detached extractor process to inspect (already finished or never spawned)"
  FAIL=$((FAIL + 1))
fi
wait_for_file_contains "row 3e: candidate still lands after the pgid check" \
  "pgid probe" "$TD/bs-repo-pgid/_meta/backlog-staging.md"

# row 3f: a CORRUPT payload handoff file must never leak on disk. cmd_staged_run's read
# step (json.load) can fail on a truncated/malformed file; the fix wraps BOTH the read
# and the work in one outer finally so the payload file is always removed, not just when
# the read succeeds.
mkdir -p "$TD/bs-state-corrupt"
echo 'not valid json{{{' > "$TD/bs-state-corrupt/payload-corrupt.json"
RC=0
python3 "$KIT_DIR/hooks/backlog-stage.py" --staged-run "$TD/bs-state-corrupt/payload-corrupt.json" >/dev/null 2>&1 || RC=$?
assert_exit "row 3f: --staged-run on a corrupt payload exits 0" 0 $RC
TOTAL=$((TOTAL + 1))
if [ ! -f "$TD/bs-state-corrupt/payload-corrupt.json" ]; then
  echo -e "  ${GREEN}PASS${NC} row 3f: corrupt payload file was removed, not leaked"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} row 3f: corrupt payload file $TD/bs-state-corrupt/payload-corrupt.json was left behind"
  FAIL=$((FAIL + 1))
fi

# row 3g: stage_from_text() unit-tested directly (no subprocess, no transcript file,
# no detach plumbing) -- proving its dedup-skip and empty-candidates branches, which no
# full-hook-invocation test exercises (every existing row uses one new, non-duplicate
# candidate). Mirrors the ID-202 race harness's importlib.util pattern already used
# later in this same file.
cat > "$TD/bs-unit-test.py" <<PYEOF
import importlib.util, os, sys

KIT_DIR = "$KIT_DIR"
TD = "$TD"

spec = importlib.util.spec_from_file_location("backlog_stage_under_test", os.path.join(KIT_DIR, "hooks", "backlog-stage.py"))
bs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bs)

backlog = os.path.join(TD, "bs-unit-backlog.md")
staging = os.path.join(TD, "bs-unit-staging.md")

with open(backlog, "w") as fh:
    fh.write("| ID | Item | Notes | Status |\n|---|---|---|---|\n| ID-1 | Fix flaky deploy script | already tracked | queued |\n")

bs.run_extractor = lambda prompt: '[{"title":"Fix flaky deploy script","intent":"dup","approach":"","u":"hi","f":"mid","home":""}]'
bs.stage_from_text("dummy transcript text", "2026-07-30", backlog, staging)
dedup_ok = not os.path.exists(staging)
print("dedup_skip_ok=" + str(dedup_ok))

bs.run_extractor = lambda prompt: '[]'
bs.stage_from_text("dummy transcript text", "2026-07-30", backlog, staging)
empty_ok = not os.path.exists(staging)
print("empty_candidates_ok=" + str(empty_ok))
PYEOF
UNIT_OUT=$(python3 "$TD/bs-unit-test.py" 2>&1)
assert_contains "row 3g: stage_from_text skips a candidate whose title already exists on the board" "dedup_skip_ok=True" "$UNIT_OUT"
assert_contains "row 3g: stage_from_text writes nothing for an empty candidate list" "empty_candidates_ok=True" "$UNIT_OUT"

# NC: empty stdin never blocks a session end.
RC=0; echo '' | bash "$KIT_DIR/hooks/backlog-stage.sh" >/dev/null 2>&1 || RC=$?
assert_exit "NC: empty stdin exits 0" 0 $RC

# NC: malformed JSON never blocks a session end.
RC=0; echo 'not json' | bash "$KIT_DIR/hooks/backlog-stage.sh" >/dev/null 2>&1 || RC=$?
assert_exit "NC: malformed JSON exits 0" 0 $RC

# ============================================================
echo ""
echo "=== harvest.sh (PreCompact / SessionEnd) ==="
# ============================================================
mkdir -p "$TD/hv-repo"
git -C "$TD/hv-repo" init -q
HV_TRANS="$TD/hv-transcript.jsonl"
cat > "$HV_TRANS" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"we decided to use REPO_ROOT as the seam"}]}}
EOF
cat > "$TD/hv-extractor.sh" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
[{"item":"repo-root-seam","kind":"decision","home":"drop","why":"consumer config seam"}]
JSON
EOF
chmod +x "$TD/hv-extractor.sh"

RC=0
REPO_ROOT="$TD/hv-repo" HARVEST_EXTRACTOR="$TD/hv-extractor.sh" HARVEST_MIN_INTERVAL=0 HARVEST_SYNC=1 \
  bash -c "echo '{\"transcript_path\":\"$HV_TRANS\"}' | bash '$KIT_DIR/hooks/harvest.sh'" >/dev/null 2>&1 || RC=$?
assert_exit "row 4: PreCompact-mode harvest stages a learning, exits 0" 0 $RC
LEDGER=$(cat "$TD/hv-repo/_meta/learned-ledger.md" 2>/dev/null)
assert_contains "row 4: ledger created at repo-relative default with no ledger dir pre-existing" "repo-root-seam" "$LEDGER"

# --lab-log mode
cat > "$TD/hv-lablog.sh" <<'EOF'
#!/usr/bin/env bash
cat <<'OUT'
## 2026-07-05 - repo-root-seam: adopted repo-relative default via REPO_ROOT
- decided to mirror lib/board/board.sh's repo-root precedent
OUT
EOF
chmod +x "$TD/hv-lablog.sh"
RC=0
REPO_ROOT="$TD/hv-repo" HARVEST_EXTRACTOR="$TD/hv-lablog.sh" HARVEST_MIN_INTERVAL=0 HARVEST_SYNC=1 \
  bash -c "echo '{\"transcript_path\":\"$HV_TRANS\"}' | bash '$KIT_DIR/hooks/harvest.sh' --lab-log" >/dev/null 2>&1 || RC=$?
assert_exit "row 4b: --lab-log drafts an entry, exits 0" 0 $RC
DRAFT=$(cat "$TD/hv-repo/_meta/.lab-log-draft.md" 2>/dev/null)
assert_contains "row 4b: draft never writes the real LAB_LOG.md" "repo-root-seam" "$DRAFT"

# row 4c (detach fix): the DEFAULT path (no HARVEST_SYNC) for BOTH no-arg and --lab-log
# must return fast and do the real work in a detached child -- this is what
# PreCompact/SessionEnd actually invoke, and is the fix for the SessionEnd-cancellation
# bug (the `claude -p` extractor call can take up to 120s, the invoking hook only gets
# ~30s, and SessionEnd fires while the CLI process is already exiting).
mkdir -p "$TD/hv-repo-async"
git -C "$TD/hv-repo-async" init -q
START_NS=$(date +%s%N)
RC=0
REPO_ROOT="$TD/hv-repo-async" HARVEST_EXTRACTOR="$TD/hv-extractor.sh" HARVEST_MIN_INTERVAL=0 \
  bash -c "echo '{\"transcript_path\":\"$HV_TRANS\"}' | bash '$KIT_DIR/hooks/harvest.sh'" >/dev/null 2>&1 || RC=$?
END_NS=$(date +%s%N)
assert_exit "row 4c: detached no-arg mode still exits 0 immediately" 0 $RC
ELAPSED_MS=$(( (END_NS - START_NS) / 1000000 ))
TOTAL=$((TOTAL + 1))
if [ "$ELAPSED_MS" -lt 2000 ]; then
  echo -e "  ${GREEN}PASS${NC} row 4c: no-arg hook returns in <2s (${ELAPSED_MS}ms)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} row 4c: no-arg hook took ${ELAPSED_MS}ms (expected <2000ms, detach not firing)"
  FAIL=$((FAIL + 1))
fi
wait_for_file_contains "row 4c: ledger entry lands after the hook already returned" \
  "repo-root-seam" "$TD/hv-repo-async/_meta/learned-ledger.md"

RC=0
REPO_ROOT="$TD/hv-repo-async" HARVEST_EXTRACTOR="$TD/hv-lablog.sh" HARVEST_MIN_INTERVAL=0 \
  bash -c "echo '{\"transcript_path\":\"$HV_TRANS\"}' | bash '$KIT_DIR/hooks/harvest.sh' --lab-log" >/dev/null 2>&1 || RC=$?
assert_exit "row 4d: detached --lab-log mode still exits 0 immediately" 0 $RC
wait_for_file_contains "row 4d: LAB_LOG draft lands after the hook already returned" \
  "repo-root-seam" "$TD/hv-repo-async/_meta/.lab-log-draft.md"

# row 4e (the actual bug this fix targets): a SLOW extractor (the real `claude -p` call
# can take seconds, up to its own 120s budget) must NOT make either mode's hook slow.
# Pre-fix, the hook blocked for the full extractor duration -- past the hook's own
# timeout (30s in this kit's hooks.json) and past SessionEnd's exit-teardown race.
cat > "$TD/hv-slow-extractor.sh" <<'EOF'
#!/usr/bin/env bash
sleep 2
cat <<'JSON'
[{"item":"slow-extractor-proof","kind":"insight","home":"drop","why":"proves detach under a real delay"}]
JSON
EOF
chmod +x "$TD/hv-slow-extractor.sh"
mkdir -p "$TD/hv-repo-slow"
git -C "$TD/hv-repo-slow" init -q

START_NS=$(date +%s%N)
RC=0
REPO_ROOT="$TD/hv-repo-slow" HARVEST_EXTRACTOR="$TD/hv-slow-extractor.sh" HARVEST_MIN_INTERVAL=0 \
  bash -c "echo '{\"transcript_path\":\"$HV_TRANS\"}' | bash '$KIT_DIR/hooks/harvest.sh'" >/dev/null 2>&1 || RC=$?
END_NS=$(date +%s%N)
ELAPSED_MS=$(( (END_NS - START_NS) / 1000000 ))
assert_exit "row 4e: no-arg hook exits 0 even with a 2s-slow extractor" 0 $RC
TOTAL=$((TOTAL + 1))
if [ "$ELAPSED_MS" -lt 1000 ]; then
  echo -e "  ${GREEN}PASS${NC} row 4e: no-arg hook returns in <1s despite a 2s-slow extractor (${ELAPSED_MS}ms) -- this is the bug this fix targets"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} row 4e: no-arg hook took ${ELAPSED_MS}ms (expected <1000ms) -- hook is blocking on the slow extractor again"
  FAIL=$((FAIL + 1))
fi
wait_for_file_contains "row 4e: ledger entry lands ~2s later, after the slow extractor finishes" \
  "slow-extractor-proof" "$TD/hv-repo-slow/_meta/learned-ledger.md"

cat > "$TD/hv-slow-lablog.sh" <<'EOF'
#!/usr/bin/env bash
sleep 2
cat <<'OUT'
## 2026-07-30 - slow-lablog-proof: proves --lab-log detach under a real delay
- extractor slept 2s before answering
OUT
EOF
chmod +x "$TD/hv-slow-lablog.sh"

START_NS=$(date +%s%N)
RC=0
REPO_ROOT="$TD/hv-repo-slow" HARVEST_EXTRACTOR="$TD/hv-slow-lablog.sh" HARVEST_MIN_INTERVAL=0 \
  bash -c "echo '{\"transcript_path\":\"$HV_TRANS\"}' | bash '$KIT_DIR/hooks/harvest.sh' --lab-log" >/dev/null 2>&1 || RC=$?
END_NS=$(date +%s%N)
ELAPSED_MS=$(( (END_NS - START_NS) / 1000000 ))
assert_exit "row 4f: --lab-log hook exits 0 even with a 2s-slow extractor" 0 $RC
TOTAL=$((TOTAL + 1))
if [ "$ELAPSED_MS" -lt 1000 ]; then
  echo -e "  ${GREEN}PASS${NC} row 4f: --lab-log hook returns in <1s despite a 2s-slow extractor (${ELAPSED_MS}ms)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} row 4f: --lab-log hook took ${ELAPSED_MS}ms (expected <1000ms) -- hook is blocking on the slow extractor again"
  FAIL=$((FAIL + 1))
fi
wait_for_file_contains "row 4f: LAB_LOG draft lands ~2s later, after the slow extractor finishes" \
  "slow-lablog-proof" "$TD/hv-repo-slow/_meta/.lab-log-draft.md"

# row 4g/4h: HARVEST_SYNC=1 must actually run INLINE (blocking) for both modes, not just
# produce the same eventual content -- a regression that silently stopped honoring the
# env var would still pass every other row, since a fast extractor finishes quickly
# either way.
mkdir -p "$TD/hv-repo-syncslow"
git -C "$TD/hv-repo-syncslow" init -q

START_NS=$(date +%s%N)
RC=0
REPO_ROOT="$TD/hv-repo-syncslow" HARVEST_EXTRACTOR="$TD/hv-slow-extractor.sh" HARVEST_MIN_INTERVAL=0 HARVEST_SYNC=1 \
  bash -c "echo '{\"transcript_path\":\"$HV_TRANS\"}' | bash '$KIT_DIR/hooks/harvest.sh'" >/dev/null 2>&1 || RC=$?
END_NS=$(date +%s%N)
ELAPSED_MS=$(( (END_NS - START_NS) / 1000000 ))
assert_exit "row 4g: HARVEST_SYNC=1 no-arg mode exits 0" 0 $RC
TOTAL=$((TOTAL + 1))
if [ "$ELAPSED_MS" -ge 1800 ]; then
  echo -e "  ${GREEN}PASS${NC} row 4g: HARVEST_SYNC=1 no-arg mode genuinely blocks for the extractor's 2s delay (${ELAPSED_MS}ms)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} row 4g: HARVEST_SYNC=1 no-arg mode returned in ${ELAPSED_MS}ms (expected >=1800ms) -- the sync seam is silently detaching instead of blocking"
  FAIL=$((FAIL + 1))
fi
LEDGER_SYNC=$(cat "$TD/hv-repo-syncslow/_meta/learned-ledger.md" 2>/dev/null)
assert_contains "row 4g: ledger entry already present immediately (proves it ran inline)" "slow-extractor-proof" "$LEDGER_SYNC"

START_NS=$(date +%s%N)
RC=0
REPO_ROOT="$TD/hv-repo-syncslow" HARVEST_EXTRACTOR="$TD/hv-slow-lablog.sh" HARVEST_MIN_INTERVAL=0 HARVEST_SYNC=1 \
  bash -c "echo '{\"transcript_path\":\"$HV_TRANS\"}' | bash '$KIT_DIR/hooks/harvest.sh' --lab-log" >/dev/null 2>&1 || RC=$?
END_NS=$(date +%s%N)
ELAPSED_MS=$(( (END_NS - START_NS) / 1000000 ))
assert_exit "row 4h: HARVEST_SYNC=1 --lab-log mode exits 0" 0 $RC
TOTAL=$((TOTAL + 1))
if [ "$ELAPSED_MS" -ge 1800 ]; then
  echo -e "  ${GREEN}PASS${NC} row 4h: HARVEST_SYNC=1 --lab-log mode genuinely blocks for the extractor's 2s delay (${ELAPSED_MS}ms)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} row 4h: HARVEST_SYNC=1 --lab-log mode returned in ${ELAPSED_MS}ms (expected >=1800ms) -- the sync seam is silently detaching instead of blocking"
  FAIL=$((FAIL + 1))
fi
DRAFT_SYNC=$(cat "$TD/hv-repo-syncslow/_meta/.lab-log-draft.md" 2>/dev/null)
assert_contains "row 4h: LAB_LOG draft already present immediately (proves it ran inline)" "slow-lablog-proof" "$DRAFT_SYNC"

# row 4i: the detached child must be reparented into its OWN process group
# (start_new_session=True) -- the literal OS-level mechanism the fix's "survives
# SessionEnd's process teardown" claim rests on. Verified via `pgrep`/`ps` (not a
# kill/signal race, which would be flaky to time against process spawn).
mkdir -p "$TD/hv-repo-pgid"
git -C "$TD/hv-repo-pgid" init -q
cat > "$TD/hv-pgid-extractor.sh" <<'EOF'
#!/usr/bin/env bash
sleep 2
cat <<'JSON'
[{"item":"pgid-probe","kind":"insight","home":"drop","why":"stay alive long enough to inspect"}]
JSON
EOF
chmod +x "$TD/hv-pgid-extractor.sh"
INVOKER_PGID=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
RC=0
REPO_ROOT="$TD/hv-repo-pgid" HARVEST_EXTRACTOR="$TD/hv-pgid-extractor.sh" HARVEST_MIN_INTERVAL=0 \
  bash -c "echo '{\"transcript_path\":\"$HV_TRANS\"}' | bash '$KIT_DIR/hooks/harvest.sh'" >/dev/null 2>&1 || RC=$?
sleep 0.3
CHILD_PID=$(pgrep -f "hv-pgid-extractor.sh" | head -1)
TOTAL=$((TOTAL + 1))
if [ -n "$CHILD_PID" ]; then
  CHILD_PGID=$(ps -o pgid= -p "$CHILD_PID" 2>/dev/null | tr -d ' ')
  if [ -n "$CHILD_PGID" ] && [ "$CHILD_PGID" != "$INVOKER_PGID" ]; then
    echo -e "  ${GREEN}PASS${NC} row 4i: detached child (pgid=$CHILD_PGID) is in a DIFFERENT process group than the invoker (pgid=$INVOKER_PGID) -- would survive the invoker's group being torn down"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} row 4i: detached child shares the invoker's process group (pgid=$CHILD_PGID) -- would be killed alongside it"
    FAIL=$((FAIL + 1))
  fi
else
  echo -e "  ${RED}FAIL${NC} row 4i: could not find the detached extractor process to inspect (already finished or never spawned)"
  FAIL=$((FAIL + 1))
fi
wait_for_file_contains "row 4i: ledger entry still lands after the pgid check" \
  "pgid-probe" "$TD/hv-repo-pgid/_meta/learned-ledger.md"

# row 4j/4k/4l: a CORRUPT payload handoff file must never leak on disk, for all three
# detached-child entry points (--harvest-run, --lab-log-run, --stop-harvest). Each one's
# read step (json.load) can fail on a truncated/malformed file; the shared
# _read_and_run() wraps BOTH the read and the work in one outer finally.
mkdir -p "$TD/hv-state-corrupt"
for MODE in harvest-run lab-log-run stop-harvest; do
  PF="$TD/hv-state-corrupt/payload-$MODE.json"
  echo 'not valid json{{{' > "$PF"
  RC=0
  python3 "$KIT_DIR/hooks/harvest.py" "--$MODE" "$PF" >/dev/null 2>&1 || RC=$?
  assert_exit "row 4j-l: --$MODE on a corrupt payload exits 0" 0 $RC
  TOTAL=$((TOTAL + 1))
  if [ ! -f "$PF" ]; then
    echo -e "  ${GREEN}PASS${NC} row 4j-l: --$MODE's corrupt payload file was removed, not leaked"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} row 4j-l: --$MODE's corrupt payload file $PF was left behind"
    FAIL=$((FAIL + 1))
  fi
done

# ID-202: dedup-on-append must survive CONCURRENT invocations sharing one ledger
# (e.g. parallel subagent sessions each firing PreCompact). Pre-fix, existing_slugs()
# (read) and append_rows() (write) were two unlocked steps: several concurrent
# harvest.py processes could each read the ledger before any had appended and all
# decide the same slug was new, observed as up to 6x duplicates in production.
#
# A real subprocess-timing race (N processes + a sleeping fake extractor) is what
# actually happens in production, but proved too flaky to assert on in THIS test
# under a loaded dev/CI box: pre-fix failure rate ranged 30-90% run-to-run because
# process-spawn jitter alone was often enough to scatter arrivals outside the
# window. So this drives the SAME code path (_harvest_payload) in-process via
# Python threads with a threading.Barrier forcing simultaneous arrival at the
# critical section, plus a deterministic sleep inside existing_slugs() standing in
# for "the write hasn't landed yet" -- this reproduces the exact race 8/8 times
# pre-fix (dup_count=8) and 8/8 times post-fix (dup_count=1) in manual verification.
cat >"$TD/hv-race-transcript.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"harvest append needs a lock"}]}}
EOF
RACE_LEDGER="$TD/hv-race-repo/_meta/learned-ledger.md"
mkdir -p "$TD/hv-race-repo"
cat >"$TD/hv-race-test.py" <<PYEOF
import importlib.util, threading, os, sys, time

KIT_DIR = "$KIT_DIR"
LEDGER = "$RACE_LEDGER"
TRANSCRIPT = "$TD/hv-race-transcript.jsonl"
N = 8

os.environ["HARVEST_LEDGER"] = LEDGER
os.environ["HARVEST_GLOSSARIES"] = ""
os.environ["HARVEST_MIN_INTERVAL"] = "0"

spec = importlib.util.spec_from_file_location("harvest_under_test", os.path.join(KIT_DIR, "hooks", "harvest.py"))
harvest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(harvest)

barrier = threading.Barrier(N)
real_extract = harvest.extract_json_array
real_existing_slugs = harvest.existing_slugs

def patched_extract(text):
    barrier.wait()  # force all N threads into the vulnerable section at the same instant
    return real_extract(text)

def patched_existing_slugs(ledger, glossaries):
    # Stand-in for "no other process has appended yet": widen the read-then-decide
    # window past any GIL scheduling quantum, so an unlocked caller reliably lets
    # ALL N threads read a pre-append ledger state.
    result = real_existing_slugs(ledger, glossaries)
    time.sleep(0.05)
    return result

def fake_run_extractor(prompt):
    return '[{"item":"harvest-dedup-race","kind":"insight","home":"drop","why":"append has no lock"}]'

harvest.extract_json_array = patched_extract
harvest.existing_slugs = patched_existing_slugs
harvest.run_extractor = fake_run_extractor

payload = {"transcript_path": TRANSCRIPT}

def worker():
    harvest._harvest_payload(payload)

threads = [threading.Thread(target=worker) for _ in range(N)]
for t in threads:
    t.start()
for t in threads:
    t.join()

content = open(LEDGER, encoding="utf-8").read() if os.path.exists(LEDGER) else ""
print(content.count("harvest-dedup-race"))
print(content.count("| date | item"))
PYEOF
RACE_OUT=$(python3 "$TD/hv-race-test.py" 2>/dev/null)
DUP_COUNT=$(echo "$RACE_OUT" | sed -n '1p')
HEADER_COUNT=$(echo "$RACE_OUT" | sed -n '2p')
assert_eq "row 4c: 8 concurrent harvests of the same insight stage exactly once (ID-202)" "1" "$DUP_COUNT"
assert_eq "row 4c: concurrent harvests never duplicate the ledger header" "1" "$HEADER_COUNT"

# NC: empty stdin never blocks a compaction/session-end.
RC=0; echo '' | bash "$KIT_DIR/hooks/harvest.sh" >/dev/null 2>&1 || RC=$?
assert_exit "NC: empty stdin exits 0" 0 $RC

# NC: malformed JSON never blocks a compaction/session-end.
RC=0; echo 'not json' | bash "$KIT_DIR/hooks/harvest.sh" >/dev/null 2>&1 || RC=$?
assert_exit "NC: malformed JSON exits 0" 0 $RC

# NC: --cleanup on a missing ledger path handles cleanly (no crash, no dir created).
RC=0; HARVEST_LEDGER="$TD/hv-repo/_meta/no-such-ledger.md" bash "$KIT_DIR/hooks/harvest.sh" --cleanup >/dev/null 2>&1 || RC=$?
assert_exit "NC: --cleanup on missing ledger dir exits 0" 0 $RC

# ============================================================
echo ""
echo "=== Registration parity: settings.json AND hooks/hooks.json ==="
# ============================================================
for NAME in backlog-stage citation-guard context-hints harvest; do
  RC=0; grep -q "dwarves-kit/hooks/${NAME}.sh" "$KIT_DIR/settings.json" || RC=1
  assert_exit "settings.json registers $NAME" 0 $RC
  RC=0; grep -q "hooks/${NAME}.sh" "$KIT_DIR/hooks/hooks.json" || RC=1
  assert_exit "hooks/hooks.json registers $NAME" 0 $RC
done

# ============================================================
echo ""
echo "=== Installer materializes all 4 hooks + companions into a temp HOME ==="
# ============================================================
# ID-277 SG-04: these 4 hooks are optional modules now (backlog-stage -> board,
# citation-guard/harvest -> session, context-hints -> advisor), so the settings.json
# wiring check below needs an explicit --with; the physical-file materialization
# (hooks/, lib/, etc.) is unconditional regardless of module selection.
INSTALL_HOME="$TD/install-home"
if HOME="$INSTALL_HOME" bash "$KIT_DIR/install.sh" --with board,session,advisor >/dev/null 2>&1; then
  DEST="$INSTALL_HOME/.claude/dwarves-kit/hooks"
  for NAME in backlog-stage citation-guard context-hints harvest; do
    RC=0; [ -f "$DEST/${NAME}.sh" ] || RC=1
    assert_exit "install.sh materializes hooks/${NAME}.sh" 0 $RC
    RC=0; [ -x "$DEST/${NAME}.sh" ] || RC=1
    assert_exit "install.sh materializes hooks/${NAME}.sh executable" 0 $RC
    RC=0; [ -f "$DEST/${NAME}.py" ] || RC=1
    assert_exit "install.sh materializes hooks/${NAME}.py (companion)" 0 $RC
  done
  RC=0; [ -f "$DEST/context-hints-skills-map.json" ] || RC=1
  assert_exit "install.sh materializes context-hints-skills-map.json (companion)" 0 $RC

  # jq the merged settings.json in the temp HOME to confirm all 4 paths are wired.
  for NAME in backlog-stage citation-guard context-hints harvest; do
    RC=0
    jq -e --arg n "$NAME" \
      '[.hooks | to_entries[] | .value[] | .hooks[].command] | any(contains("dwarves-kit/hooks/" + $n + ".sh"))' \
      "$INSTALL_HOME/.claude/settings.json" >/dev/null 2>&1 || RC=1
    assert_exit "temp-HOME settings.json wires $NAME" 0 $RC
  done
else
  assert_exit "install.sh ran cleanly into a temp HOME" 0 1
fi

# ============================================================
echo ""
echo "=== Skill-copy loop generalization (install.sh) ==="
# ============================================================
# Fabricate a SECOND skill dir the kit ships alongside get-api-docs, so the loop
# is proven to copy every skills/*/SKILL.md, not just the one hardcoded name.
FAKE_KIT="$TD/fake-kit"
cp -R "$KIT_DIR" "$FAKE_KIT"
mkdir -p "$FAKE_KIT/skills/fake-second-skill"
printf '# fake-second-skill\n\nA fixture skill to prove the install.sh copy loop globs.\n' \
  > "$FAKE_KIT/skills/fake-second-skill/SKILL.md"
SKILL_HOME="$TD/skill-home"
if HOME="$SKILL_HOME" bash "$FAKE_KIT/install.sh" >/dev/null 2>&1; then
  RC=0; [ -f "$SKILL_HOME/.claude/skills/get-api-docs/SKILL.md" ] || RC=1
  assert_exit "skill-copy loop still installs get-api-docs" 0 $RC
  RC=0; [ -f "$SKILL_HOME/.claude/skills/fake-second-skill/SKILL.md" ] || RC=1
  assert_exit "skill-copy loop installs a SECOND, non-hardcoded skill (glob proof)" 0 $RC
else
  assert_exit "fake-kit install.sh ran cleanly" 0 1
fi

# ============================================================
echo ""
echo "=== Done gate: no ops-toolkit path leaked into the new files ==="
# ============================================================
LEAK=$(grep -rln 'workspace/tieubao' \
  "$KIT_DIR/hooks/backlog-stage.sh" "$KIT_DIR/hooks/backlog-stage.py" \
  "$KIT_DIR/hooks/citation-guard.sh" "$KIT_DIR/hooks/citation-guard.py" \
  "$KIT_DIR/hooks/context-hints.sh" "$KIT_DIR/hooks/context-hints.py" \
  "$KIT_DIR/hooks/context-hints-skills-map.json" \
  "$KIT_DIR/hooks/harvest.sh" "$KIT_DIR/hooks/harvest.py" 2>/dev/null || true)
assert_eq "no 'workspace/tieubao' in any new file" "" "$LEAK"

# ============================================================
echo ""
echo "=== Results ==="
echo "Passed: $PASS / $TOTAL"
if [ "$FAIL" -gt 0 ]; then
  echo -e "${RED}$FAIL test(s) failed.${NC}"
  exit 1
fi
echo -e "${GREEN}All kit-foldin hooks tests passed.${NC}"
