#!/usr/bin/env bash
# test-spec-reserve.sh -- SPEC-128: atomic wavefront SPEC-number reservation.
#
# Proves the CONCURRENCY case SPEC-064 did not: a parallel wave that each calls `next` before
# any branch/spec exists all get the SAME number. `reserve` claims a number under a portable
# mkdir-mutex + a reservations ledger folded into the scan, so N concurrent claims yield N
# DISTINCT numbers. Includes the required negative control (the OLD `next` path DOES collide),
# the SPEC-064 contract regression, reconciliation (realized + expired), repo-scope, lock
# crash-safety, and the orchestrate.sh reserve-inject wiring.
#
# Run: bash tests/test-spec-reserve.sh
# Exit 0 = all pass. Exit 1 = failures.
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SN="$KIT_DIR/lib/spec/spec-next.sh"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
PASS=0; FAIL=0; TOTAL=0
ok()  { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}PASS${NC} $1"; }
bad() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo -e "  ${RED}FAIL${NC} $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3' got '$2')"; fi; }
expect() { if { trap '' PIPE; printf '%s' "$3" 2>/dev/null || :; } | grep -q "$2"; then ok "$1"; else bad "$1 (missing '$2' in: $3)"; fi; }
# grep -c prints "0" AND exits 1 on no match, so `grep -c || echo 0` double-prints. This
# returns a single clean integer whether or not the file exists / the pattern matches.
count() { local c; c="$(grep -c "$1" "$2" 2>/dev/null)"; printf '%s' "${c:-0}"; }

# A temp git repo whose only spec is SPEC-005 => next free is 006. `cd` into it so spec-next's
# `git rev-parse --show-toplevel` resolves here; SPEC_RESERVE_FILE isolates the ledger.
mk_repo() {
  local r; r="$(mktemp -d "${TMPDIR:-/tmp}/kit-spec-reserve.XXXXXX")"
  git -C "$r" init -q; git -C "$r" config user.email t@t.t; git -C "$r" config user.name t
  mkdir -p "$r/docs/specs"; : > "$r/docs/specs/SPEC-005-x.md"
  git -C "$r" add -A; git -C "$r" commit -qm init >/dev/null 2>&1
  printf '%s\n' "$r"
}

# ============================================================
echo "=== T1: single reserve on empty ledger ==="
# ============================================================
R="$(mk_repo)"; RES="$R/res.log"
OUT="$(cd "$R" && SPEC_RESERVE_FILE="$RES" bash "$SN" reserve)"
eq "T1 reserve returns max+1 (006)" "$OUT" "006"
LINES="$(count '| RESERVE |' "$RES")"
eq "T1 exactly one RESERVE line appended" "$LINES" "1"
expect "T1 line is repo-scoped + carries num" "num=006 repo=$(basename "$R")" "$(cat "$RES")"

# ============================================================
echo "=== T2: 20 parallel reserve -> 20 distinct (atomic claim, CORE) ==="
# ============================================================
R="$(mk_repo)"; RES="$R/res.log"; ACC="$R/acc"; : > "$ACC"
( cd "$R"
  for _ in $(seq 1 20); do ( SPEC_RESERVE_FILE="$RES" bash "$SN" reserve >> "$ACC" 2>/dev/null ) & done
  wait )
T2_TOTAL="$(grep -c . "$ACC" | tr -d ' ')"
T2_DISTINCT="$(sort -u "$ACC" | grep -c . | tr -d ' ')"
eq "T2 emitted 20 numbers" "$T2_TOTAL" "20"
eq "T2 all 20 distinct (zero collisions)" "$T2_DISTINCT" "20"

# ============================================================
echo "=== T3: a reserved number reads as TAKEN before its branch exists ==="
# ============================================================
R="$(mk_repo)"; RES="$R/res.log"
N="$(cd "$R" && SPEC_RESERVE_FILE="$RES" bash "$SN" reserve)"       # 006
CHK="$(cd "$R" && SPEC_RESERVE_FILE="$RES" bash "$SN" check "$N" 2>&1; echo "rc=$?")"
expect "T3 check <reserved> says TAKEN" "TAKEN" "$CHK"
expect "T3 check <reserved> exits 1"    "rc=1"  "$CHK"
NEXT="$(cd "$R" && SPEC_RESERVE_FILE="$RES" bash "$SN" next)"
eq "T3 next advances past the reservation (007)" "$NEXT" "007"

# ============================================================
echo "=== T4: NEGATIVE CONTROL -- 20 parallel next (old path) DOES collide ==="
# ============================================================
R="$(mk_repo)"; RES="$R/res.log"; ACC="$R/acc"; : > "$ACC"    # empty ledger: `next` has no reservation
( cd "$R"
  for _ in $(seq 1 20); do ( SPEC_RESERVE_FILE="$RES" bash "$SN" next >> "$ACC" 2>/dev/null ) & done
  wait )
NC_TOTAL="$(grep -c . "$ACC" | tr -d ' ')"
NC_DISTINCT="$(sort -u "$ACC" | grep -c . | tr -d ' ')"
if [ "$NC_DISTINCT" -lt "$NC_TOTAL" ]; then
  ok "T4 old next path collides ($NC_DISTINCT distinct < $NC_TOTAL) -- harness CAN see a collision"
else
  bad "T4 expected a collision from the un-reserved path, got $NC_DISTINCT distinct of $NC_TOTAL"
fi

# ============================================================
echo "=== T5: SPEC-064 contract intact with an empty ledger ==="
# ============================================================
R="$(mk_repo)"; RES="$R/res.log"
# SPEC-005 present + SPEC-041 in a branch name => check 041 TAKEN (branch scan), next numeric.
git -C "$R" branch "feat/SPEC-041-x" >/dev/null 2>&1
N5="$(cd "$R" && SPEC_RESERVE_FILE="$RES" bash "$SN" next)"
expect "T5 next is a 3-digit number" "^[0-9][0-9][0-9]$" "$N5"
CHK5="$(cd "$R" && SPEC_RESERVE_FILE="$RES" bash "$SN" check 041 2>&1; echo "rc=$?")"
expect "T5 check sees a branch-only number as TAKEN (SPEC-064 scan)" "TAKEN" "$CHK5"
expect "T5 taken exits 1" "rc=1" "$CHK5"
CHK5F="$(cd "$R" && SPEC_RESERVE_FILE="$RES" bash "$SN" check 999 2>&1; echo "rc=$?")"
expect "T5 a free number reports free + exits 0" "rc=0" "$CHK5F"
eq "T5 no ledger file created by next/check (contract untouched)" "$([ -f "$RES" ] && echo yes || echo no)" "no"

# ============================================================
echo "=== T6: reconcile -- a REALIZED reservation (now a branch) stops counting ==="
# ============================================================
R="$(mk_repo)"; RES="$R/res.log"
N6="$(cd "$R" && SPEC_RESERVE_FILE="$RES" bash "$SN" reserve)"   # 006 reserved
# Realize it: create a branch carrying SPEC-006 (the worker made its branch).
git -C "$R" branch "feat/SPEC-006-done" >/dev/null 2>&1
# Next reserve must prune the now-redundant 006 line and still not double-count it.
N6B="$(cd "$R" && SPEC_RESERVE_FILE="$RES" bash "$SN" reserve)"  # should be 007 (006 realized)
eq "T6 next reserve after realization is 007" "$N6B" "007"
REALIZED_LINES="$(count 'num=006' "$RES")"
eq "T6 the realized 006 reservation line was pruned" "$REALIZED_LINES" "0"

# ============================================================
echo "=== T7: reconcile -- an EXPIRED reservation stops counting ==="
# ============================================================
R="$(mk_repo)"; RES="$R/res.log"
# Hand-write a reservation dated in 1970 (definitely older than any TTL).
printf '1970-01-01T00:00:00Z | RESERVE | num=006 repo=%s\n' "$(basename "$R")" > "$RES"
# With TTL default 24h, the ancient 006 is expired => not counted => next free is still 006.
N7="$(cd "$R" && SPEC_RESERVE_FILE="$RES" bash "$SN" next)"
eq "T7 expired reservation does not inflate next (still 006)" "$N7" "006"
# A fresh reserve prunes the expired line.
(cd "$R" && SPEC_RESERVE_FILE="$RES" bash "$SN" reserve >/dev/null)
EXP_LINES="$(count '1970-01-01' "$RES")"
eq "T7 expired line pruned on next reserve" "$EXP_LINES" "0"

# ============================================================
echo "=== T8: reservations are REPO-SCOPED (repo A does not inflate repo B) ==="
# ============================================================
RA="$(mk_repo)"; RB="$(mk_repo)"; RES="$RA/shared.log"    # one shared ledger file, two repos
(cd "$RA" && SPEC_RESERVE_FILE="$RES" bash "$SN" reserve >/dev/null)   # reserves 006 for repo A
(cd "$RA" && SPEC_RESERVE_FILE="$RES" bash "$SN" reserve >/dev/null)   # 007 for repo A
N8B="$(cd "$RB" && SPEC_RESERVE_FILE="$RES" bash "$SN" next)"          # repo B ignores A's lines
eq "T8 repo B's next ignores repo A's reservations (006)" "$N8B" "006"

# ============================================================
echo "=== T9: stale LOCK dir older than TTL is reclaimed ==="
# ============================================================
R="$(mk_repo)"; RES="$R/res.log"
mkdir -p "$(dirname "$RES")"; mkdir "$RES.lock"          # simulate a dead holder's leftover lock
# Backdate the lock dir well past the TTL so the reclaim path fires.
touch -t 200001010000 "$RES.lock" 2>/dev/null || true
N9="$(cd "$R" && SPEC_RESERVE_TTL=1 SPEC_RESERVE_FILE="$RES" bash "$SN" reserve 2>/dev/null)"
eq "T9 reserve reclaims a stale lock and still claims (006)" "$N9" "006"
eq "T9 lock released after reserve" "$([ -d "$RES.lock" ] && echo held || echo free)" "free"

# ============================================================
echo "=== T10: orchestrate _wave_reserve_spec wiring (mock spec-next) ==="
# ============================================================
# Source orchestrate.sh (its source-guard skips main) and drive the helper with a mock.
# shellcheck disable=SC1090
( source "$KIT_DIR/lib/queue/orchestrate.sh" 2>/dev/null
  MOCK="$(mktemp)"; printf '#!/usr/bin/env bash\necho 128\n' > "$MOCK"; chmod +x "$MOCK"
  got="$(SPEC_NEXT_CMD="$MOCK" _wave_reserve_spec)"
  [ "$got" = "128" ] && echo "T10A-OK" || echo "T10A-BAD:$got"
  # degrade path: a mock that fails (nonzero, no output) => helper returns nonzero, empty
  BADMOCK="$(mktemp)"; printf '#!/usr/bin/env bash\nexit 1\n' > "$BADMOCK"; chmod +x "$BADMOCK"
  if got2="$(SPEC_NEXT_CMD="$BADMOCK" _wave_reserve_spec)"; then echo "T10B-BAD:nonempty:$got2"; else
    [ -z "$got2" ] && echo "T10B-OK" || echo "T10B-BAD:$got2"; fi
) > "${TMPDIR:-/tmp}/t10.$$" 2>/dev/null
T10="$(cat "${TMPDIR:-/tmp}/t10.$$" 2>/dev/null)"
expect "T10 helper returns the reserved number from spec-next" "T10A-OK" "$T10"
expect "T10 helper degrades (nonzero+empty) on reserve failure" "T10B-OK" "$T10"

# ============================================================
echo "=== T11: EXPIRED prune is cross-repo (review #3, bounded shared ledger) ==="
# ============================================================
# An expired reservation for repo B must be cleaned up by repo A's reserve, or the
# machine-global ledger grows unbounded across repos.
RA="$(mk_repo)"; RES="$RA/shared.log"
printf '1970-01-01T00:00:00Z | RESERVE | num=006 repo=some-other-repo\n' > "$RES"   # expired, foreign repo
(cd "$RA" && SPEC_RESERVE_FILE="$RES" bash "$SN" reserve >/dev/null)
FOREIGN_EXPIRED="$(count 'some-other-repo' "$RES")"
eq "T11 a foreign repo's EXPIRED line is pruned by any reserve" "$FOREIGN_EXPIRED" "0"
# But a foreign repo's LIVE (non-expired) line is left alone (realized-prune stays repo-scoped).
RB2="$(mk_repo)"; RES2="$RB2/shared.log"
printf '%s | RESERVE | num=006 repo=some-other-repo\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$RES2"
(cd "$RB2" && SPEC_RESERVE_FILE="$RES2" bash "$SN" reserve >/dev/null)
FOREIGN_LIVE="$(count 'some-other-repo' "$RES2")"
eq "T11 a foreign repo's LIVE line is preserved" "$FOREIGN_LIVE" "1"

# ============================================================
echo "=== T12: repo match is anchored (review #4: 'foo' != 'foo-bar') ==="
# ============================================================
# Reserve under a repo whose name is a prefix of the ledger line's repo; it must NOT count.
R="$(mktemp -d "${TMPDIR:-/tmp}/kit-spec-reserve.XXXXXX")"; mv "$R" "$R-bar"; R="$R-bar"
git -C "$R" init -q; git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
mkdir -p "$R/docs/specs"; : > "$R/docs/specs/SPEC-005-x.md"
git -C "$R" add -A; git -C "$R" commit -qm init >/dev/null 2>&1
RES="$R/res.log"
# A live reservation for repo "<base>-bar" (this repo). A DIFFERENT repo whose name is the
# bare prefix must not fold this in. Simulate by writing a line for this repo, then asking a
# would-be prefix repo... simpler: assert the anchored fold only matches the exact repo.
BASE="$(basename "$R")"                 # e.g. kit-spec-reserve.xxx-bar
PREFIX="${BASE%-bar}"                    # the bare prefix, kit-spec-reserve.xxx
printf '%s | RESERVE | num=006 repo=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PREFIX" > "$RES"
# This repo is "<...>-bar"; a line for the PREFIX repo must NOT be folded in, so next is 006.
N12="$(cd "$R" && SPEC_RESERVE_FILE="$RES" bash "$SN" next)"
eq "T12 a prefix-repo reservation is NOT folded into this repo (006)" "$N12" "006"

# ============================================================
echo "=== T13: check message byte-identical to SPEC-064 on empty ledger (review #5) ==="
# ============================================================
R="$(mk_repo)"; RES="$R/res.log"
MSG13="$(cd "$R" && SPEC_RESERVE_FILE="$RES" bash "$SN" check 005 2>&1)"
expect "T13 empty-ledger TAKEN message has NO reservation clause" "seen in specs/, a branch, or a recent commit subject)" "$MSG13"
if { trap '' PIPE; printf '%s' "$MSG13" 2>/dev/null || :; } | grep -q 'reservation'; then bad "T13 empty-ledger message leaked a reservation clause"; else ok "T13 no reservation clause on empty ledger"; fi

# ============================================================
echo "=== T14: a normal reserve FREES the lock (no held lock, no owner leak) ==="
# ============================================================
R="$(mk_repo)"; RES="$R/res.log"
N14="$(cd "$R" && SPEC_RESERVE_FILE="$RES" bash "$SN" reserve)"
eq "T14 normal reserve returns a number" "$N14" "006"
eq "T14 lock dir freed after a normal reserve" "$([ -d "$RES.lock" ] && echo held || echo free)" "free"
eq "T14 no owner file left behind" "$([ -e "$RES.lock/owner" ] && echo leak || echo clean)" "clean"

# ============================================================
echo "=== T15: a FRESH (non-stale) foreign lock is RESPECTED, not stolen ==="
# ============================================================
# This is the direct guard for the mutex fail-open the macOS CI masked: if lock-mtime reads
# garbage (Linux `stat -f %m` = --file-system format), a FRESH lock looks older-than-TTL and
# gets reclaimed -> the number is stolen. With correct mtime the fresh lock is respected, so a
# bounded reserve times out (empty, nonzero) and the foreign lock is still held.
R="$(mk_repo)"; RES="$R/res.log"
mkdir -p "$(dirname "$RES")"; mkdir "$RES.lock"; printf 'foreign.owner.token' > "$RES.lock/owner"   # current mtime, foreign owner
OUT15="$(cd "$R" && SPEC_RESERVE_MAX_TRIES=3 SPEC_RESERVE_FILE="$RES" bash "$SN" reserve 2>/dev/null; echo "rc=$?")"
if { trap '' PIPE; printf '%s' "$OUT15" 2>/dev/null || :; } | grep -qE '^[0-9]{3}$'; then bad "T15 reserve STOLE a fresh foreign lock (fail-open: $OUT15)"; else ok "T15 reserve did not steal a fresh foreign lock"; fi
expect "T15 bounded reserve fails loudly rather than fail-open" "rc=1" "$OUT15"
eq "T15 the fresh foreign lock is still held" "$([ -d "$RES.lock" ] && echo held || echo free)" "held"
eq "T15 the foreign owner token is untouched" "$(cat "$RES.lock/owner" 2>/dev/null)" "foreign.owner.token"

# ============================================================
echo ""
echo "=== Results ==="
echo -e "Passed: ${GREEN}$PASS${NC} / $TOTAL"
if [ "$FAIL" -gt 0 ]; then echo -e "${RED}$FAIL assertions failed.${NC}"; exit 1; fi
echo -e "${GREEN}spec-reserve green.${NC}"
