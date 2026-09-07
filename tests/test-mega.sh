#!/usr/bin/env bash
# test-mega.sh -- lib/mega/mega.sh (kit-modularity sub-goal 08): `mega status <slug>` reconciles a
# mega-goal's ROADMAP.md sub-goal claims against GIT TRUTH.
#
# Proves the full drift-class taxonomy on a fixture mega ("testmega") with 8 sub-goals, one per
# class, over a REAL mktemp git repo (CODEROOT) for branches/commits and a stub `gh` (GH_BIN,
# PATH-injected, no real network call ever) for PR state:
#
#   01-alpha    [x] + PR merged                         -> OK
#   02-beta     [x] + PR NOT merged      (NC-1)         -> CLAIM-UNVERIFIED
#   03-gamma    [ ] + branch 0 commits, no open PR (NC-2)-> STALLED
#   04-delta    [ ] + PR IS merged       (NC-3)         -> MERGED-UNCHECKED
#   05-epsilon  [ ] + branch 0 commits BUT an open PR   -> WIP, never STALLED (the nuance:
#                                                          0-commits + a live open PR is
#                                                          in-flight, not a dispatched-but-empty
#                                                          lie -- only 0-commits WITH NO open PR
#                                                          is STALLED)
#   06-zeta     [ ] + branch with commits, no open PR   -> WIP
#   07-eta      [ ] + no branch, no PR at all           -> PENDING
#   08-theta    [~] rehomed                             -> INFO, always, regardless of git truth
#
# Run: bash tests/test-mega.sh   (exit 0 = all AC/NC green)

set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MEGA="$KIT_DIR/lib/mega/mega.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok - $1"; }
no() { FAIL=$((FAIL + 1)); echo "NOT ok - $1"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/dk-mega-test.XXXXXX")"
TMP="$(cd "$TMP" && pwd)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# CODEROOT -- a REAL git repo (branches/commits are git truth; no stub needed for git itself,
# per the suite's precedent of using real git in mktemp fixtures, e.g. test-board.sh's fixA/fixB).
# ---------------------------------------------------------------------------
CODEROOT="$TMP/coderoot"
mkdir -p "$CODEROOT"
git -C "$CODEROOT" init -q
git -C "$CODEROOT" config user.email t@t
git -C "$CODEROOT" config user.name t
echo init > "$CODEROOT/README"
git -C "$CODEROOT" add -A
git -C "$CODEROOT" commit -qm init
git -C "$CODEROOT" branch -M master

# 03-gamma: branch created off master, ZERO commits ahead (the STALLED signal).
git -C "$CODEROOT" branch feat/testmega-03-gamma master

# 05-epsilon: branch created off master, ZERO commits ahead, but WILL have an open PR (stub
# below) -- the nuance case: 0 commits + a live open PR must classify WIP, never STALLED.
git -C "$CODEROOT" branch feat/testmega-05-epsilon master

# 06-zeta: branch off master WITH 2 commits ahead, no open PR -> WIP via commits alone.
git -C "$CODEROOT" checkout -qb feat/testmega-06-zeta master
echo a >> "$CODEROOT/README"; git -C "$CODEROOT" commit -qam "zeta 1"
echo b >> "$CODEROOT/README"; git -C "$CODEROOT" commit -qam "zeta 2"
git -C "$CODEROOT" checkout -q master

# ---------------------------------------------------------------------------
# MEGAROOT -- <slug>/ROADMAP.md + <slug>/goals/<sub>.md (the "**Branch:**" lookup).
# ---------------------------------------------------------------------------
MEGAROOT="$TMP/megaroot"
SLUG="testmega"
mkdir -p "$MEGAROOT/$SLUG/goals"

cat > "$MEGAROOT/$SLUG/ROADMAP.md" <<'ROADMAP'
# Mega-goal: testmega

## Sub-goals

- [x] 01-alpha (testrepo), does alpha, `auto`, PR #101 merged abc123def0 (shipped clean)
- [x] 02-beta (testrepo), does beta, `auto`, PR #999 merged deadbeef00 (roadmap claims merged, PR isn't)
- [ ] 03-gamma (testrepo), does gamma, `auto`, PR #
- [ ] 04-delta (testrepo), does delta, `auto`, PR #104
- [ ] 05-epsilon (testrepo), does epsilon, `auto`, PR #
- [ ] 06-zeta (testrepo), does zeta, `auto`, PR #
- [ ] 07-eta (testrepo), does eta, `auto`, PR #
- [~] 08-theta (testrepo), rehomed into a sibling mega, `auto`, PR #
ROADMAP

printf '**Branch:** feat/testmega-03-gamma\n'   > "$MEGAROOT/$SLUG/goals/03-gamma.md"
printf '**Branch:** feat/testmega-05-epsilon\n' > "$MEGAROOT/$SLUG/goals/05-epsilon.md"
printf '**Branch:** feat/testmega-06-zeta\n'    > "$MEGAROOT/$SLUG/goals/06-zeta.md"
# 07-eta deliberately has NO goal file -> no branch -> PENDING.

# ---------------------------------------------------------------------------
# Stub gh -- PR #101 MERGED, #999 still OPEN (the CLAIM-UNVERIFIED case), #104 MERGED (the
# MERGED-UNCHECKED case), and one open PR whose head is feat/testmega-05-epsilon (the nuance
# case). No real network call is ever made; GH_BIN points here for the whole run.
# ---------------------------------------------------------------------------
STUBGH="$TMP/stub-gh"
cat > "$STUBGH" <<'STUBEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view")
    case "$3" in
      101) echo MERGED ;;
      999) echo OPEN ;;
      104) echo MERGED ;;
      *) exit 1 ;;
    esac
    ;;
  "pr list")
    cat <<'JSON'
[{"number":205,"headRefName":"feat/testmega-05-epsilon"}]
JSON
    ;;
  *) echo "stub-gh: unhandled call: $*" >&2; exit 1 ;;
esac
STUBEOF
chmod +x "$STUBGH"

run_status() { GH_BIN="$STUBGH" bash "$MEGA" status "$SLUG" --megagoals-root "$MEGAROOT" --code-root "$CODEROOT" "$@"; }

OUT="$(run_status)"; RC=$?

detail_for() { printf '%s\n' "$OUT" | grep -F " $1 "; }

# ---------------------------------------------------------------------------
# AC1-AC8: per-class classification
# ---------------------------------------------------------------------------
case "$(detail_for 01-alpha)" in *OK*) ok "01-alpha (PR merged) -> OK";; *) no "01-alpha should be OK: $(detail_for 01-alpha)";; esac
case "$(detail_for 02-beta)" in *CLAIM-UNVERIFIED*) ok "NC-1: 02-beta ([x] + PR NOT merged) -> CLAIM-UNVERIFIED";; *) no "NC-1 failed: $(detail_for 02-beta)";; esac
case "$(detail_for 03-gamma)" in *STALLED*) ok "NC-2: 03-gamma ([ ] + 0 commits, no open PR) -> STALLED";; *) no "NC-2 failed: $(detail_for 03-gamma)";; esac
case "$(detail_for 04-delta)" in *MERGED-UNCHECKED*) ok "NC-3: 04-delta ([ ] + PR merged) -> MERGED-UNCHECKED";; *) no "NC-3 failed: $(detail_for 04-delta)";; esac
d05="$(detail_for 05-epsilon)"
case "$d05" in
  *STALLED*) no "nuance FAILED: 05-epsilon (0 commits + OPEN PR) misclassified STALLED: $d05" ;;
  *WIP*)     ok "nuance: 05-epsilon (0 commits but an OPEN PR) -> WIP, never STALLED" ;;
  *)         no "05-epsilon: neither WIP nor STALLED: $d05" ;;
esac
case "$(detail_for 06-zeta)" in *WIP*) ok "06-zeta ([ ] + commits, no open PR) -> WIP";; *) no "06-zeta failed: $(detail_for 06-zeta)";; esac
case "$(detail_for 07-eta)" in *PENDING*) ok "07-eta ([ ] + no branch, no PR) -> PENDING";; *) no "07-eta failed: $(detail_for 07-eta)";; esac
case "$(detail_for 08-theta)" in *INFO*) ok "08-theta ([~] rehomed) -> INFO always";; *) no "08-theta failed: $(detail_for 08-theta)";; esac

# ---------------------------------------------------------------------------
# AC9: rollup line -- 1 ok (01-alpha only) / 8 total, 3 drift (02+03+04); nonzero exit on drift
# ---------------------------------------------------------------------------
rollup_line="$(printf '%s\n' "$OUT" | tail -n1)"
if [ "$rollup_line" = "testmega: 1/8 ok  ⚠ 3 drift" ]; then
  ok "rollup line: testmega: 1/8 ok  ⚠ 3 drift"
else
  no "rollup line mismatch: got '$rollup_line'"
fi
if [ "$RC" -ne 0 ]; then ok "exit code nonzero when drift > 0"; else no "exit code should be nonzero on drift"; fi

# ---------------------------------------------------------------------------
# AC10: --rollup-only prints ONLY the rollup line
# ---------------------------------------------------------------------------
ROLLUP_ONLY_OUT="$(run_status --rollup-only)"
if [ "$ROLLUP_ONLY_OUT" = "$rollup_line" ]; then
  ok "--rollup-only prints exactly the rollup line, no detail"
else
  no "--rollup-only mismatch: got '$ROLLUP_ONLY_OUT'"
fi

# ---------------------------------------------------------------------------
# NC suite-identical-or-better control: a clean mega (every box checked + its PR merged, no
# drift) must roll up with ZERO drift and exit 0 -- proves the reconciler doesn't false-positive
# on a genuinely healthy roadmap.
# ---------------------------------------------------------------------------
CLEANROOT="$TMP/megaroot-clean"
mkdir -p "$CLEANROOT/cleanmega/goals"
cat > "$CLEANROOT/cleanmega/ROADMAP.md" <<'ROADMAP'
# Mega-goal: cleanmega

## Sub-goals

- [x] 01-only (testrepo), the only sub-goal, `auto`, PR #101 merged abc123def0 (shipped clean)
ROADMAP
CLEAN_OUT="$(GH_BIN="$STUBGH" bash "$MEGA" status cleanmega --megagoals-root "$CLEANROOT" --code-root "$CODEROOT" --rollup-only)"
CLEAN_RC=$?
if [ "$CLEAN_OUT" = "cleanmega: 1/1 ok" ] && [ "$CLEAN_RC" -eq 0 ]; then
  ok "clean roadmap (all [x] verified merged) -> 0 drift, exit 0"
else
  no "clean-roadmap control failed: out='$CLEAN_OUT' rc=$CLEAN_RC"
fi

# ---------------------------------------------------------------------------
# Error paths: missing ROADMAP.md, unknown subcommand
# ---------------------------------------------------------------------------
if ! GH_BIN="$STUBGH" bash "$MEGA" status nope-slug --megagoals-root "$MEGAROOT" --code-root "$CODEROOT" >/dev/null 2>&1; then
  ok "missing ROADMAP.md -> nonzero exit"
else
  no "missing ROADMAP.md should fail"
fi
if ! bash "$MEGA" bogus-verb >/dev/null 2>&1; then
  ok "unknown subcommand -> nonzero exit"
else
  no "unknown subcommand should fail"
fi

# ---------------------------------------------------------------------------
# board.sh wiring: `board board --with-mega` / `board status --with-mega` surface the SAME
# rollup as a trailing "MEGA ROLLUP" section, opt-in only (never on by default -- see the
# byte-identical render non-regression NC in test-board.sh, which never passes --with-mega).
# ---------------------------------------------------------------------------
BOARD_SH="$KIT_DIR/lib/board/board.sh"
BOARDREPO="$TMP/boardrepo"
mkdir -p "$BOARDREPO/_meta/megagoals/testmega/goals"
git -C "$BOARDREPO" init -q   # _repo_root_for needs a real git toplevel to resolve correctly
cp "$MEGAROOT/$SLUG/ROADMAP.md" "$BOARDREPO/_meta/megagoals/testmega/ROADMAP.md"
cp "$MEGAROOT/$SLUG/goals/"*.md "$BOARDREPO/_meta/megagoals/testmega/goals/"
cat > "$BOARDREPO/_meta/BACKLOG.md" <<'BOARDMD'
# Backlog

## Active queue

| ID | Item | Notes & source | Status |
|----|------|-----------------|--------|
| ID-001 | Mega-goal: testmega | scaffold at `_meta/megagoals/testmega/` | queued |
BOARDMD

WITH_MEGA_OUT="$(GH_BIN="$STUBGH" bash "$BOARD_SH" board --with-mega --mega-code-root "$CODEROOT" --backlog-file "$BOARDREPO/_meta/BACKLOG.md" 2>&1)"
if { trap '' PIPE; printf '%s\n' "$WITH_MEGA_OUT" 2>/dev/null || :; } | grep -qF "testmega: 1/8 ok  ⚠ 3 drift"; then
  ok "board board --with-mega surfaces the mega rollup in a trailing MEGA ROLLUP section"
else
  no "board --with-mega did not surface the rollup: $WITH_MEGA_OUT"
fi
WITHOUT_MEGA_OUT="$(bash "$BOARD_SH" board --backlog-file "$BOARDREPO/_meta/BACKLOG.md" 2>&1)"
if ! { trap '' PIPE; printf '%s\n' "$WITHOUT_MEGA_OUT" 2>/dev/null || :; } | grep -q "MEGA ROLLUP"; then
  ok "board board WITHOUT --with-mega never touches gh / never prints a rollup (opt-in, non-regressing default)"
else
  no "board board without --with-mega should not print a MEGA ROLLUP section"
fi

echo "---"
echo "Coverage delta: mega.sh had 0 tests before this file; now $((PASS + FAIL)) checks across the full drift-class taxonomy."
echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
