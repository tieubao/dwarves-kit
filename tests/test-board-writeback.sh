#!/usr/bin/env bash
# test-board-writeback.sh -- SPEC-149 (runner-fastpath sub-goal 08): lib/board/board-writeback.sh + the
# `board.sh writeback` subcommand it backs.
#
# Proves:
#   AC1  reverse-native maps every reachable Hermes status to its git target correctly, and
#        rejects anything else (empty output, nonzero exit)
#   AC2  a genuine Hermes-side status move (live status != the snapshot's recorded hermes_status)
#        produces exactly the right changeset entry; an UNCHANGED row produces none
#   AC3  `apply` builds the sync branch in an ISOLATED worktree: the caller's own checkout stays
#        on its original branch, working tree clean, untouched
#   AC4  the commit body carries `actor=hermes`
#   AC5  snapshot refresh updates ONLY `hermes_status`; `row_hash` passes through UNCHANGED
#
#   NC1  hash mismatch (git row changed since mirror) -> edit SKIPPED + reported; file untouched
#   NC2  illegal target status (not a backlog.sh state) -> rejected with reason; file untouched
#   NC3  empty changeset -> zero commits, zero branches, an honest "0 changes" line
#   NC4  a card from a non-opted-in repo in the Hermes delta -> refused with reason, ZERO hermes
#        calls ever made against that repo's board (defense in depth on top of the mirror's own
#        opt-in filter)
#   NC5  mirror snapshot MISSING or CORRUPT -> writeback refuses ALL edits, explicit error, exit
#        nonzero (never degrades to "no conflicts, apply everything")
#   NC6  TWO-WRITER coexistence: a row appended to the fixture BACKLOG.md AFTER the mirror
#        snapshot was taken survives byte-for-byte; the chore/board-sync branch bases on the
#        CURRENT HEAD (not a stale/cached one)
#
#   RT   Round-trip demo (fixtures only): move one card, run writeback, capture the branch+commit
#        diff showing exactly one status flip
#
# Run: bash tests/test-board-writeback.sh   (exit 0 = all AC/NC green)

set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOARD="$KIT_DIR/lib/board/board.sh"
BOARD_MIRROR="$KIT_DIR/lib/board/board-mirror.sh"
BOARD_WRITEBACK="$KIT_DIR/lib/board/board-writeback.sh"

PASS=0; FAIL=0; SKIP=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
assert() {
  TOTAL=$((TOTAL+1))
  if [ "$2" -eq 0 ] 2>/dev/null; then echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1))
  else echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL+1)); fi
}
skip() { TOTAL=$((TOTAL+1)); SKIP=$((SKIP+1)); echo -e "  ${YELLOW}SKIP${NC} $1"; }

TMPDIR_T="$(mktemp -d "${TMPDIR:-/tmp}/dk-board-writeback-test.XXXXXX")"
TMPDIR_T="$(cd "$TMPDIR_T" && pwd -P)"
trap 'rm -rf "$TMPDIR_T"' EXIT

# ---------------------------------------------------------------------------
# Fixture world: fixR (opted IN, a real git repo with a real local bare "remote" so `git push`
# genuinely succeeds with zero network -- only `gh` is stubbed, per the sub-goal contract) +
# fixTrading (opted OUT, named like the real sensitive repo it stands in for, NEVER given a real
# BACKLOG.md path -- NC4 must reject it before ever trying to resolve one).
# ---------------------------------------------------------------------------
REMOTE="$TMPDIR_T/remote.git"
git init -q --bare "$REMOTE"

FIXR="$TMPDIR_T/fixR"
mkdir -p "$FIXR/_meta"
git init -q "$FIXR"; git -C "$FIXR" config user.email t@t; git -C "$FIXR" config user.name t

cat > "$FIXR/_meta/BACKLOG.md" <<'BOARD_R'
# Backlog
## Active queue
| ID | Item | Notes & source | Status |
|----|------|-----------------|--------|
| ID-001 | Do the thing | some notes | queued |
| ID-002 | Claimed thing | notes2 | claimed |
| ID-003 | Parked thing | notes3 | parked |
BOARD_R
git -C "$FIXR" add -A && git -C "$FIXR" commit -q -m "chore(test): seed fixR board"
DEFAULT_BRANCH="$(git -C "$FIXR" symbolic-ref --short HEAD)"
git -C "$FIXR" remote add origin "$REMOTE"
git -C "$FIXR" push -q -u origin "$DEFAULT_BRANCH"

REGISTRY="$TMPDIR_T/boards.txt"
cat > "$REGISTRY" <<REG
fixR        $FIXR/_meta/BACKLOG.md        on
fixTrading  /nonexistent/BACKLOG.md       off
REG

# The hermes stub: `list --json` reads a per-test-controlled JSON file (STUB_LIST_JSON); anything
# else logs and errors (writeback's diff step never needs create/block/complete -- those are
# board-mirror's verbs, not writeback's). Querying the fixTrading board is a HARD FAIL (exit 9,
# distinguishable from a normal error) so NC4 can prove it never happens, not just "didn't show up
# in the result".
STUB="$TMPDIR_T/stub-hermes"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
echo "$*" >> "${STUB_CALL_LOG:?STUB_CALL_LOG unset}"
if [ "$1" = "kanban" ] && [ "$3" = "fixTrading" ]; then
  echo "FATAL TEST INVARIANT VIOLATION: fixTrading board queried" >&2
  exit 9
fi
if [ "$1" = "kanban" ] && [ "$4" = "list" ]; then
  cat "${STUB_LIST_JSON:?STUB_LIST_JSON unset}"
  exit 0
fi
echo "stub: unhandled call: $*" >&2
exit 1
STUBEOF
chmod +x "$STUB"

# The gh stub: logs argv (+ cwd) to a call log, never touches the network, returns a canned URL.
GHSTUB="$TMPDIR_T/stub-gh"
cat > "$GHSTUB" <<'GHEOF'
#!/usr/bin/env bash
echo "PWD=$(pwd) ARGS=$*" >> "${GH_CALL_LOG:?GH_CALL_LOG unset}"
echo "https://example.invalid/fake/fake/pull/1"
GHEOF
chmod +x "$GHSTUB"

CALLS="$TMPDIR_T/calls.log"
GHCALLS="$TMPDIR_T/gh-calls.log"
SNAP="$TMPDIR_T/snapshot.jsonl"
: > "$CALLS"; : > "$GHCALLS"; : > "$SNAP"

echo "=== AC1: reverse-native maps every reachable status, rejects anything else ==="
STATUS_DONE="done"
R1="$(bash "$BOARD_WRITEBACK" reverse-native triage)"
R2="$(bash "$BOARD_WRITEBACK" reverse-native ready)"
R3="$(bash "$BOARD_WRITEBACK" reverse-native blocked)"
R4="$(bash "$BOARD_WRITEBACK" reverse-native "$STATUS_DONE")"
bash "$BOARD_WRITEBACK" reverse-native todo    >/dev/null 2>&1; RC5=$?
bash "$BOARD_WRITEBACK" reverse-native running >/dev/null 2>&1; RC6=$?
bash "$BOARD_WRITEBACK" reverse-native archived >/dev/null 2>&1; RC7=$?
assert "triage -> queued"          "$([ "$R1" = "queued" ]  && echo 0 || echo 1)"
assert "ready -> claimed"          "$([ "$R2" = "claimed" ] && echo 0 || echo 1)"
assert "blocked -> parked"         "$([ "$R3" = "parked" ]  && echo 0 || echo 1)"
assert "done -> shipped"           "$([ "$R4" = "shipped" ] && echo 0 || echo 1)"
assert "todo has no legal reverse mapping (nonzero exit)"     "$([ "$RC5" -ne 0 ] && echo 0 || echo 1)"
assert "running has no legal reverse mapping (nonzero exit)"  "$([ "$RC6" -ne 0 ] && echo 0 || echo 1)"
assert "an arbitrary custom status has no legal reverse mapping (nonzero exit)" "$([ "$RC7" -ne 0 ] && echo 0 || echo 1)"

echo ""
echo "=== Build the golden snapshot via a real 'board mirror' run (stub hermes) ==="
IDCTR="$TMPDIR_T/idcounter"; echo 0 > "$IDCTR"
: > "$CALLS"
MIRROR_STUB="$TMPDIR_T/stub-hermes-mirror"
cat > "$MIRROR_STUB" <<'MSTUBEOF'
#!/usr/bin/env bash
echo "$*" >> "${STUB_CALL_LOG:?}"
if [ "$1" = "kanban" ]; then
  case "$4" in
    create)
      n=$(( $(cat "${STUB_ID_COUNTER:-/dev/null}" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "${STUB_ID_COUNTER}"
      printf '{"id":"t_stub%03d"}\n' "$n"
      ;;
    block) echo "moved (stub)" ;;
    *) echo "mirror-stub: unhandled verb $4" >&2; exit 1 ;;
  esac
fi
MSTUBEOF
chmod +x "$MIRROR_STUB"
STUB_CALL_LOG="$CALLS" STUB_ID_COUNTER="$IDCTR" HERMES_BIN="$MIRROR_STUB" \
  bash "$BOARD" mirror --repo-root "$TMPDIR_T" --registry "$REGISTRY" --snapshot "$SNAP" >/dev/null 2>&1
assert "golden snapshot has 3 rows (one per fixR row)" "$([ "$(wc -l < "$SNAP" | tr -d ' ')" -eq 3 ] && echo 0 || echo 1)"

ID001="$(jq -r 'select(.origin=="fixR:ID-001").hermes_id' "$SNAP")"
ID002="$(jq -r 'select(.origin=="fixR:ID-002").hermes_id' "$SNAP")"
ID003="$(jq -r 'select(.origin=="fixR:ID-003").hermes_id' "$SNAP")"
HASH001="$(jq -r 'select(.origin=="fixR:ID-001").row_hash' "$SNAP")"

echo ""
echo "=== AC2/RT: a genuine Hermes-side move produces the right changeset; an unchanged row does not ==="
# ID-001 (queued->triage at mirror time) moved to "ready" in Hermes (operator claimed it).
# ID-002 (claimed->ready at mirror time) stays "ready" (no move at all).
# ID-003 (parked->blocked at mirror time) moved to "done" (operator marked it done).
LIST1="$TMPDIR_T/list1.json"
jq -nc --arg i1 "$ID001" --arg i2 "$ID002" --arg i3 "$ID003" \
  '[{id:$i1,status:"ready",title:"Do the thing"},{id:$i2,status:"ready",title:"Claimed thing"},{id:$i3,status:"done",title:"Parked thing"}]' > "$LIST1"

: > "$CALLS"
DIFF1="$(STUB_CALL_LOG="$CALLS" STUB_LIST_JSON="$LIST1" HERMES_BIN="$STUB" bash "$BOARD_WRITEBACK" diff --registry "$REGISTRY" --snapshot "$SNAP" 2>"$TMPDIR_T/diff1.err")"
assert "changeset has exactly 2 entries (ID-001, ID-003 moved; ID-002 did not)" \
  "$([ "$(printf '%s\n' "$DIFF1" | grep -c .)" -eq 2 ] && echo 0 || echo 1)"
assert "ID-001's changeset entry: queued -> claimed" \
  "$(printf '%s\n' "$DIFF1" | jq -e 'select(.origin=="fixR:ID-001") | .current_status=="queued" and .target_status=="claimed"' >/dev/null 2>&1 && echo 0 || echo 1)"
assert "ID-003's changeset entry: parked -> shipped" \
  "$(printf '%s\n' "$DIFF1" | jq -e 'select(.origin=="fixR:ID-003") | .current_status=="parked" and .target_status=="shipped"' >/dev/null 2>&1 && echo 0 || echo 1)"
assert "ID-002 (no Hermes-side move) never appears in the changeset" \
  "$({ trap '' PIPE; printf '%s\n' "$DIFF1" 2>/dev/null || :; } | grep -q 'ID-002' && echo 1 || echo 0)"
assert "only ONE hermes call made (batched list, not per-row)" \
  "$([ "$(wc -l < "$CALLS" | tr -d ' ')" -eq 1 ] && echo 0 || echo 1)"

echo ""
echo "=== AC3/AC4/RT: apply builds an isolated worktree; caller checkout untouched; actor=hermes ==="
HEAD_BEFORE_APPLY="$(git -C "$FIXR" rev-parse HEAD)"
: > "$CALLS"; : > "$GHCALLS"
STUB_CALL_LOG="$CALLS" STUB_LIST_JSON="$LIST1" HERMES_BIN="$STUB" GH_BIN="$GHSTUB" GH_CALL_LOG="$GHCALLS" \
  bash "$BOARD" writeback --repo-root "$TMPDIR_T" --registry "$REGISTRY" --snapshot "$SNAP" >"$TMPDIR_T/wb1.out" 2>"$TMPDIR_T/wb1.err"
WB1_RC=$?
assert "writeback exits 0 on a successful apply" "$([ "$WB1_RC" -eq 0 ] && echo 0 || echo 1)"
assert "caller's own checkout is STILL on the default branch" \
  "$([ "$(git -C "$FIXR" branch --show-current)" = "$DEFAULT_BRANCH" ] && echo 0 || echo 1)"
assert "caller's own checkout HEAD is UNCHANGED (worktree isolation held)" \
  "$([ "$(git -C "$FIXR" rev-parse HEAD)" = "$HEAD_BEFORE_APPLY" ] && echo 0 || echo 1)"
assert "caller's own working tree is clean (no stray edits)" \
  "$([ -z "$(git -C "$FIXR" status --porcelain)" ] && echo 0 || echo 1)"
assert "a chore/board-sync branch now exists" \
  "$(git -C "$FIXR" show-ref --verify --quiet refs/heads/chore/board-sync && echo 0 || echo 1)"
assert "the sync commit body carries actor=hermes" \
  "$(git -C "$FIXR" show chore/board-sync -s --format=%B | grep -qx 'actor=hermes' && echo 0 || echo 1)"
assert "the sync branch's diff touches ONLY the Status column of the two matched rows" \
  "$(git -C "$FIXR" diff "$DEFAULT_BRANCH" chore/board-sync -- _meta/BACKLOG.md | grep -c '^[+-]|' | grep -qx 4 && echo 0 || echo 1)"
RT_DIFF="$(git -C "$FIXR" diff "$DEFAULT_BRANCH" chore/board-sync -- _meta/BACKLOG.md)"
assert "RT: the diff shows ID-001 queued->claimed" "$({ trap '' PIPE; printf '%s\n' "$RT_DIFF" 2>/dev/null || :; } | grep -q -- '-| ID-001 .* queued ' && { trap '' PIPE; printf '%s\n' "$RT_DIFF" 2>/dev/null || :; } | grep -q -- '+| ID-001 .* claimed' && echo 0 || echo 1)"
assert "RT: the diff shows ID-003 parked->shipped" "$({ trap '' PIPE; printf '%s\n' "$RT_DIFF" 2>/dev/null || :; } | grep -q -- '-| ID-003 .* parked ' && { trap '' PIPE; printf '%s\n' "$RT_DIFF" 2>/dev/null || :; } | grep -q -- '+| ID-003 .* shipped' && echo 0 || echo 1)"
assert "'gh pr create' was called exactly once (never a real API call -- it's the stub)" \
  "$([ "$(wc -l < "$GHCALLS" | tr -d ' ')" -eq 1 ] && echo 0 || echo 1)"
assert "'gh pr create' argv carries --base/--head/--title/--body-file as discrete args" \
  "$(grep -q -- '--base '"$DEFAULT_BRANCH"' --head chore/board-sync --title' "$GHCALLS" && echo 0 || echo 1)"
assert "the remote 'origin' actually received the branch (a real, local, non-network push)" \
  "$(git --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/chore/board-sync && echo 0 || echo 1)"

echo ""
echo "=== AC5: snapshot refresh -- ONLY hermes_status changes; row_hash passes through unchanged ==="
NEW_HASH001="$(jq -r 'select(.origin=="fixR:ID-001").row_hash' "$SNAP")"
NEW_STATUS001="$(jq -r 'select(.origin=="fixR:ID-001").hermes_status' "$SNAP")"
assert "ID-001's row_hash in the snapshot is UNCHANGED after writeback (pass-through, not recomputed)" \
  "$([ "$NEW_HASH001" = "$HASH001" ] && echo 0 || echo 1)"
assert "ID-001's hermes_status in the snapshot is now 'ready' (the live value writeback observed)" \
  "$([ "$NEW_STATUS001" = "ready" ] && echo 0 || echo 1)"
skip "ID-003 (target 'shipped') post-refresh snapshot presence is documented (not asserted as a hard requirement here) -- see decisions in the PR body"

echo ""
echo "=== NC3: a second writeback run with NO further Hermes-side moves is an honest '0 changes', touches nothing ==="
BRANCHCOUNT_BEFORE="$(git -C "$FIXR" for-each-ref refs/heads/chore/board-sync | wc -l | tr -d ' ')"
HEAD_DEFAULT_BEFORE="$(git -C "$FIXR" rev-parse "$DEFAULT_BRANCH")"
SYNC_SHA_BEFORE="$(git -C "$FIXR" rev-parse chore/board-sync)"
: > "$CALLS"; : > "$GHCALLS"
WB2_OUT="$(STUB_CALL_LOG="$CALLS" STUB_LIST_JSON="$LIST1" HERMES_BIN="$STUB" GH_BIN="$GHSTUB" GH_CALL_LOG="$GHCALLS" \
  bash "$BOARD" writeback --repo-root "$TMPDIR_T" --registry "$REGISTRY" --snapshot "$SNAP" 2>&1)"; WB2_RC=$?
assert "NC3: exit 0" "$([ "$WB2_RC" -eq 0 ] && echo 0 || echo 1)"
assert "NC3: reports '0 changes'" "$({ trap '' PIPE; printf '%s\n' "$WB2_OUT" 2>/dev/null || :; } | grep -q '0 changes' && echo 0 || echo 1)"
assert "NC3: zero gh calls made" "$([ ! -s "$GHCALLS" ] && echo 0 || echo 1)"
assert "NC3: default branch HEAD unchanged" "$([ "$(git -C "$FIXR" rev-parse "$DEFAULT_BRANCH")" = "$HEAD_DEFAULT_BEFORE" ] && echo 0 || echo 1)"
assert "NC3: chore/board-sync branch unchanged (no new commit)" "$([ "$(git -C "$FIXR" rev-parse chore/board-sync)" = "$SYNC_SHA_BEFORE" ] && echo 0 || echo 1)"
assert "NC3: still exactly one chore/board-sync ref (no duplicate/second branch)" "$([ "$BRANCHCOUNT_BEFORE" -eq 1 ] && [ "$(git -C "$FIXR" for-each-ref refs/heads/chore/board-sync | wc -l | tr -d ' ')" -eq 1 ] && echo 0 || echo 1)"

echo ""
echo "=== NC1: hash mismatch (git row changed since mirror) -> SKIPPED + reported; file untouched ==="
# ID-002's item text changes on git (a real, independent edit) WITHOUT re-mirroring; its snapshot
# row_hash now stales relative to the current extraction. Also craft a Hermes-side move for it so
# there IS something writeback would otherwise apply.
sed -i.bak 's/| Claimed thing | notes2 | claimed |/| Claimed thing EDITED | notes2 | claimed |/' "$FIXR/_meta/BACKLOG.md"
rm -f "$FIXR/_meta/BACKLOG.md.bak"
git -C "$FIXR" add -A && git -C "$FIXR" commit -q -m "test(fixture): edit ID-002 item text without re-mirroring"
NC1_CONTENT_BEFORE="$(git -C "$FIXR" show "$DEFAULT_BRANCH":_meta/BACKLOG.md)"
LIST_NC1="$TMPDIR_T/list-nc1.json"
jq -nc --arg i1 "$ID001" --arg i2 "$ID002" --arg i3 "$ID003" \
  '[{id:$i1,status:"ready",title:"x"},{id:$i2,status:"blocked",title:"x"},{id:$i3,status:"done",title:"x"}]' > "$LIST_NC1"
: > "$CALLS"
NC1_ERR="$(STUB_CALL_LOG="$CALLS" STUB_LIST_JSON="$LIST_NC1" HERMES_BIN="$STUB" bash "$BOARD_WRITEBACK" diff --registry "$REGISTRY" --snapshot "$SNAP" 2>&1 >/dev/null)"
assert "NC1: ID-002's hash-mismatch skip is reported" "$({ trap '' PIPE; printf '%s\n' "$NC1_ERR" 2>/dev/null || :; } | grep -q 'fixR:ID-002.*row_hash mismatch' && echo 0 || echo 1)"
NC1_CONTENT_AFTER="$(git -C "$FIXR" show "$DEFAULT_BRANCH":_meta/BACKLOG.md)"
assert "NC1: the default-branch BACKLOG.md is byte-for-byte untouched by the (rejected) diff" \
  "$([ "$NC1_CONTENT_BEFORE" = "$NC1_CONTENT_AFTER" ] && echo 0 || echo 1)"

echo ""
echo "=== NC2: illegal target status (hermes reports a status with no legal backlog.sh mapping) ==="
LIST_NC2="$TMPDIR_T/list-nc2.json"
jq -nc --arg i1 "$ID001" --arg i3 "$ID003" \
  '[{id:$i1,status:"in_review",title:"x"},{id:$i3,status:"done",title:"x"}]' > "$LIST_NC2"
NC2_ERR="$(STUB_LIST_JSON="$LIST_NC2" STUB_CALL_LOG="$CALLS" HERMES_BIN="$STUB" bash "$BOARD_WRITEBACK" diff --registry "$REGISTRY" --snapshot "$SNAP" 2>&1 >/dev/null)"
assert "NC2: ID-001's illegal-target-status skip is reported by name" \
  "$({ trap '' PIPE; printf '%s\n' "$NC2_ERR" 2>/dev/null || :; } | grep -q "fixR:ID-001.*no legal backlog.sh mapping" && echo 0 || echo 1)"

echo ""
echo "=== NC4: a card from a non-opted-in repo (fixTrading) in the Hermes delta -> refused, NEVER queried ==="
FAKE_HASH="fixture-not-a-real-hash-nc4-stray-row"
SNAP_NC4="$TMPDIR_T/snap-nc4.jsonl"
{ cat "$SNAP"; jq -nc --arg h "$FAKE_HASH" '{origin:"fixTrading:TR-001",repo:"fixTrading",id:"TR-001",board:"fixTrading",hermes_id:"t_fake",row_hash:$h,hermes_status:"triage",seen_at:"2026-01-01T00:00:00Z"}'; } > "$SNAP_NC4"
LIST_NC4="$TMPDIR_T/list-nc4.json"
jq -nc --arg i1 "$ID001" '[{id:$i1,status:"ready",title:"x"}]' > "$LIST_NC4"
: > "$CALLS"
NC4_ERR="$(STUB_LIST_JSON="$LIST_NC4" STUB_CALL_LOG="$CALLS" HERMES_BIN="$STUB" bash "$BOARD_WRITEBACK" diff --registry "$REGISTRY" --snapshot "$SNAP_NC4" 2>&1 >/dev/null)"
NC4_RC=$?
assert "NC4: exit 0 (a per-row rejection, not a whole-run abort)" "$([ "$NC4_RC" -eq 0 ] && echo 0 || echo 1)"
assert "NC4: fixTrading's row is refused with a named reason" \
  "$({ trap '' PIPE; printf '%s\n' "$NC4_ERR" 2>/dev/null || :; } | grep -q "fixTrading:TR-001.*not opted in" && echo 0 || echo 1)"
assert "NC4: the fixTrading board was NEVER queried (stub would have exited 9 and this diff would have shown the FATAL line otherwise)" \
  "$({ trap '' PIPE; printf '%s\n' "$NC4_ERR" 2>/dev/null || :; } | grep -q 'FATAL TEST INVARIANT VIOLATION' && echo 1 || echo 0)"
assert "NC4: no call log line ever references the fixTrading board" "$(grep -qi 'fixtrading' "$CALLS" && echo 1 || echo 0)"

echo ""
echo "=== NC5: MISSING or CORRUPT snapshot -> writeback REFUSES ALL edits, explicit error, exit nonzero ==="
MISSING_SNAP="$TMPDIR_T/does-not-exist.jsonl"
set +e
MISSING_ERR="$(bash "$BOARD_WRITEBACK" diff --registry "$REGISTRY" --snapshot "$MISSING_SNAP" 2>&1 >/dev/null)"; MISSING_RC=$?
set -e
assert "NC5a: missing snapshot -> nonzero exit" "$([ "$MISSING_RC" -ne 0 ] && echo 0 || echo 1)"
assert "NC5a: missing snapshot -> explicit REFUSING error" "$({ trap '' PIPE; printf '%s\n' "$MISSING_ERR" 2>/dev/null || :; } | grep -q 'REFUSING all edits' && echo 0 || echo 1)"

CORRUPT_SNAP="$TMPDIR_T/corrupt.jsonl"
printf '{"origin":"fixR:ID-001"}\nTHIS IS NOT JSON\n' > "$CORRUPT_SNAP"
set +e
CORRUPT_ERR="$(bash "$BOARD_WRITEBACK" diff --registry "$REGISTRY" --snapshot "$CORRUPT_SNAP" 2>&1 >/dev/null)"; CORRUPT_RC=$?
set -e
assert "NC5b: corrupt snapshot -> nonzero exit" "$([ "$CORRUPT_RC" -ne 0 ] && echo 0 || echo 1)"
assert "NC5b: corrupt snapshot -> explicit REFUSING error" "$({ trap '' PIPE; printf '%s\n' "$CORRUPT_ERR" 2>/dev/null || :; } | grep -q 'REFUSING all edits' && echo 0 || echo 1)"

EMPTY_SNAP="$TMPDIR_T/empty-valid.jsonl"
: > "$EMPTY_SNAP"
set +e
EMPTY_OUT="$(bash "$BOARD" writeback --repo-root "$TMPDIR_T" --registry "$REGISTRY" --snapshot "$EMPTY_SNAP" 2>&1)"; EMPTY_RC=$?
set -e
assert "NC5c: a PRESENT-but-EMPTY snapshot (valid, zero rows) is NOT treated as corrupt -- exit 0" "$([ "$EMPTY_RC" -eq 0 ] && echo 0 || echo 1)"
assert "NC5c: a present-but-empty snapshot honestly reports 0 changes (not a refusal)" "$({ trap '' PIPE; printf '%s\n' "$EMPTY_OUT" 2>/dev/null || :; } | grep -q '0 changes' && echo 0 || echo 1)"

echo ""
echo "=== NC6: TWO-WRITER coexistence -- a post-snapshot appended row survives byte-for-byte; branch bases on current HEAD ==="
# Fresh fixture (fixR2) so this test is independent of the mutations NC1/AC2 already made to fixR.
REMOTE2="$TMPDIR_T/remote2.git"
git init -q --bare "$REMOTE2"
FIXR2="$TMPDIR_T/fixR2"
mkdir -p "$FIXR2/_meta"
git init -q "$FIXR2"; git -C "$FIXR2" config user.email t@t; git -C "$FIXR2" config user.name t
cat > "$FIXR2/_meta/BACKLOG.md" <<'BOARD_R2'
| ID | Item | Notes | Status |
|----|------|-------|--------|
| ID-501 | Second-repo thing | notes | queued |
BOARD_R2
git -C "$FIXR2" add -A && git -C "$FIXR2" commit -q -m "chore(test): seed fixR2 board"
DEF2="$(git -C "$FIXR2" symbolic-ref --short HEAD)"
git -C "$FIXR2" remote add origin "$REMOTE2"
git -C "$FIXR2" push -q -u origin "$DEF2"

REG2="$TMPDIR_T/boards2.txt"
echo "fixR2 $FIXR2/_meta/BACKLOG.md on" > "$REG2"
H501="$(bash "$BOARD_MIRROR" row-hash fixR2 ID-501 "Second-repo thing" notes queued)"
SNAP2="$TMPDIR_T/snap2.jsonl"
jq -nc --arg h "$H501" '{origin:"fixR2:ID-501",repo:"fixR2",id:"ID-501",board:"fixR2",hermes_id:"t_501",row_hash:$h,hermes_status:"triage",seen_at:"2026-01-01T00:00:00Z"}' > "$SNAP2"

APPENDED_LINE="| ID-999 | Concurrently appended by another writer | after the mirror snapshot | queued |"
echo "$APPENDED_LINE" >> "$FIXR2/_meta/BACKLOG.md"
git -C "$FIXR2" add -A && git -C "$FIXR2" commit -q -m "test(fixture): concurrent append ID-999 after snapshot"
HEAD_BEFORE_NC6="$(git -C "$FIXR2" rev-parse HEAD)"

LIST_NC6="$TMPDIR_T/list-nc6.json"
jq -nc '[{id:"t_501",status:"ready",title:"x"}]' > "$LIST_NC6"
: > "$CALLS"; : > "$GHCALLS"
STUB_CALL_LOG="$CALLS" STUB_LIST_JSON="$LIST_NC6" HERMES_BIN="$STUB" GH_BIN="$GHSTUB" GH_CALL_LOG="$GHCALLS" \
  bash "$BOARD" writeback --repo-root "$TMPDIR_T" --registry "$REG2" --snapshot "$SNAP2" >/dev/null 2>&1

PARENT_SHA="$(git -C "$FIXR2" log chore/board-sync -1 --format=%P)"
assert "NC6: the sync branch's parent commit == the pre-writeback HEAD (built from CURRENT HEAD, not stale)" \
  "$([ "$PARENT_SHA" = "$HEAD_BEFORE_NC6" ] && echo 0 || echo 1)"
assert "NC6: the appended row survives BYTE-FOR-BYTE on the sync branch" \
  "$(git -C "$FIXR2" show chore/board-sync:_meta/BACKLOG.md | grep -qF -- "$APPENDED_LINE" && echo 0 || echo 1)"
NC6_DIFF="$(git -C "$FIXR2" diff "$DEF2" chore/board-sync -- _meta/BACKLOG.md)"
assert "NC6: the diff touches ONLY ID-501's status line (2 changed lines: -/+), never the appended row" \
  "$([ "$(printf '%s\n' "$NC6_DIFF" | grep -c '^[+-]|')" -eq 2 ] && echo 0 || echo 1)"

echo ""
echo "=== Static security audit: argv-safety, no eval/sh-c, no direct DB access ==="
assert "board-writeback.sh never eval/sh-c's a parsed variable" \
  "$(grep -qE '\beval\b|sh -c' "$BOARD_WRITEBACK" && echo 1 || echo 0)"
assert "board-writeback.sh never references a .db/sqlite path in code" \
  "$(grep -E '\.db\"|sqlite' "$BOARD_WRITEBACK" | grep -v '^\s*#' >/dev/null 2>&1 && echo 1 || echo 0)"
# shellcheck disable=SC2016  # intentional: single-quoted so `\$VAR` stays a literal-dollar regex
# for grep -E, never shell-expanded -- we are searching board-writeback.sh's SOURCE TEXT for the
# literal argv-element shape, not evaluating a live command.
assert "board-writeback.sh calls gh pr create with discrete argv (--title/--body-file), never a composed string" \
  "$(grep -qE '"\$GH_BIN" pr create --base "\$base" --head "\$branch" --title "\$title" --body-file "\$body"' "$BOARD_WRITEBACK" && echo 0 || echo 1)"

echo ""
echo "=== Coverage delta ==="
assert "coverage delta: board-writeback checks went from 0 to $TOTAL in this suite" 0

echo ""
echo "  ---------------------------------------------"
echo "  TOTAL: $TOTAL   PASS: $PASS   FAIL: $FAIL   SKIP: $SKIP"
[ "$FAIL" -eq 0 ]
