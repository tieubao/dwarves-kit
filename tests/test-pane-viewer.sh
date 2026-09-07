#!/usr/bin/env bash
# test-pane-viewer.sh (SPEC-121): pins the PUSH half of the SPEC-119 multiplexer. PANE_VIEWER
# (default `auto`) opens ONE viewer tab/surface per wave attached to the wave's tmux session;
# `none` = today's pull behavior exactly; headless (no TTY / nothing detected) degrades silently
# so CI is byte-identical to today -- the named negative control. The viewer argv is exec-direct
# (no `$SHELL -c` re-parse, the SPEC-119 #143 pattern), the session name is charset-gated, and
# the cmux path never passes `--focus true` (known cmux RPC wedge).
#
# No real GUI or tmux server: viewers are mocked via the VIEWER_CMD seam (recorder + poison),
# tmux via the TMUX_CMD mock (same fixture shape as test-multiplexer.sh).
set -uo pipefail
export TIER4_CLOSE=0
# Scrub the invoking terminal's own viewer fingerprints so detection tests are hermetic (this
# suite may itself run inside cmux/iTerm/kitty on an operator's machine).
unset CMUX_WORKSPACE_ID KITTY_WINDOW_ID TERM_PROGRAM PANE_VIEWER VIEWER_CMD TMUX_SESSION 2>/dev/null || true
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/queue/orchestrate.sh
source "$KIT/lib/queue/orchestrate.sh"
ORCH="$KIT/lib/queue/orchestrate.sh"

fails=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }

# The viewer exec is fire-and-forget (backgrounded + disowned, SPEC-121 review fix), so a
# recorder/poison write can land shortly AFTER _viewer_open/_wave_run returns. wait_nonempty
# polls for a positive write (bounded); settle gives a would-be late write time to land before
# an emptiness or exact-count assertion.
wait_nonempty() {  # file [tries]
  local f="$1" n="${2:-30}" i=0
  while [ "$i" -lt "$n" ]; do [ -s "$f" ] && return 0; sleep 0.1; i=$((i + 1)); done
  return 1
}
settle() { sleep 0.5; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mk_git_mega() {  # repo
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name test
  git -C "$repo" commit -q --allow-empty -m init
}

make_goal() {  # megadir id [glob]
  local mg="$1" id="$2" glob="${3:-}"
  mkdir -p "$mg/goals"
  {
    printf '# %s: sub-goal\n' "$id"
    printf '**Branch:** feat/%s\n' "$(printf '%s' "$id" | tr 'A-Z' 'a-z')"
    if [ -n "$glob" ]; then printf '\n## Touches\n- %s\n' "$glob"; fi
  } > "$mg/goals/${id#SG-}-${id}.md"
}

mk_mega() {  # parent-out-var-prefix  (creates repo + mega with 2 disjoint sub-goals)
  local repo="$1"
  mk_git_mega "$repo"
  local mg="$repo/mega"; mkdir -p "$mg"
  cat > "$mg/ROADMAP.md" <<'EOF'
# Mega-goal: viewer
## Sub-goals
- [ ] SG-01 alpha , auto , PR #__
- [ ] SG-02 beta , auto , PR #__
EOF
  echo "POINTER: resume from ROADMAP" > "$mg/POINTER_PROMPT.md"
  make_goal "$mg" SG-01 "lib/wave-a/**"
  make_goal "$mg" SG-02 "lib/wave-b/**"
  printf '%s\n' "$mg"
}

# Same tmux mock as test-multiplexer.sh: new-window EXECS the multi-arg command in the background.
cat > "$TMP/tmux-mock" <<'MOCK'
#!/usr/bin/env bash
set -u
STATE="${TMUX_MOCK_STATE:?TMUX_MOCK_STATE not set}"
mkdir -p "$STATE"
printf '%s\n' "$*" >> "$STATE/calls.log"
sub="$1"; shift
case "$sub" in
  has-session) [ "$1" = -t ] && shift; [ -f "$STATE/session.$1" ]; exit $? ;;
  new-session)
    name=""
    while [ "$#" -gt 0 ]; do case "$1" in -s) name="$2"; shift 2 ;; -n) shift 2 ;; *) shift ;; esac; done
    : > "$STATE/session.$name" ;;
  new-window)
    session="" id="" dir=""; cmd_argv=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -d) shift ;; -t) session="$2"; shift 2 ;; -n) id="$2"; shift 2 ;; -c) dir="$2"; shift 2 ;;
        --) shift; cmd_argv=("$@"); break ;;
        *) shift ;;
      esac
    done
    : > "$STATE/session.$session"
    ( cd "$dir" 2>/dev/null || exit 1; "${cmd_argv[@]}" ) > "$STATE/pane.$session.$id.log" 2>&1 &
    ;;
  kill-window) : ;;
  *) exit 0 ;;
esac
MOCK
chmod +x "$TMP/tmux-mock"

# Viewer recorder: appends its full argv to $VIEWER_REC_LOG, exits 0.
cat > "$TMP/viewer-rec" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${VIEWER_REC_LOG:?}"
exit 0
MOCK
chmod +x "$TMP/viewer-rec"

# Poisoned viewer: any invocation is itself the failure.
cat > "$TMP/viewer-poison" <<'MOCK'
#!/usr/bin/env bash
echo "POISON: viewer invoked with: $*" >> "${VIEWER_POISON_LOG:?}"
exit 99
MOCK
chmod +x "$TMP/viewer-poison"

# Failing viewer: records then exits nonzero (the resilience case).
cat > "$TMP/viewer-fail" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${VIEWER_REC_LOG:?}"
exit 7
MOCK
chmod +x "$TMP/viewer-fail"

# Claude mock: flips its sub-goal's box via the locked flip CLI.
cat > "$TMP/claude-mux" <<'MOCK'
#!/usr/bin/env bash
prompt=$(cat)
id=$(printf '%s' "$prompt" | grep -oE 'SG-[0-9]+' | head -1)
echo "VIEWER-WAVE from $id"
bash "$ORCH" flip "$MEGADIR" "$id" >/dev/null 2>&1
exit 0
MOCK
chmod +x "$TMP/claude-mux"

# ============================ T1: default is auto (push by default) ============================
[ "$PANE_VIEWER" = auto ] \
  && pass "T1 default: PANE_VIEWER unset resolves to 'auto' (push is the default)" \
  || fail "T1 default: expected auto, got '$PANE_VIEWER'"

# ============================ T2: detection order ============================
d=$(CMUX_WORKSPACE_ID=ws1 TERM_PROGRAM=iTerm.app _viewer_detect)
[ "$d" = cmux ] && pass "T2 detect: cmux env beats TERM_PROGRAM" || fail "T2 detect: cmux-first order broken (got '$d')"
d=$(TERM_PROGRAM=iTerm.app _viewer_detect)
[ "$d" = iterm ] && pass "T2 detect: TERM_PROGRAM=iTerm.app -> iterm" || fail "T2 detect: iTerm.app -> '$d'"
d=$(TERM_PROGRAM=ghostty _viewer_detect)
[ "$d" = ghostty ] && pass "T2 detect: TERM_PROGRAM=ghostty -> ghostty" || fail "T2 detect: ghostty -> '$d'"
d=$(TERM_PROGRAM=WezTerm _viewer_detect)
[ "$d" = wezterm ] && pass "T2 detect: TERM_PROGRAM=WezTerm -> wezterm" || fail "T2 detect: WezTerm -> '$d'"
d=$(TERM_PROGRAM=Apple_Terminal _viewer_detect)
[ "$d" = terminal ] && pass "T2 detect: TERM_PROGRAM=Apple_Terminal -> terminal" || fail "T2 detect: Apple_Terminal -> '$d'"
d=$(TERM_PROGRAM=SomethingElse KITTY_WINDOW_ID=3 _viewer_detect)
[ "$d" = kitty ] && pass "T2 detect: KITTY_WINDOW_ID after TERM_PROGRAM misses -> kitty" || fail "T2 detect: kitty -> '$d'"
d=$(_viewer_detect)
[ -z "$d" ] && pass "T2 detect: nothing set -> empty (degrade)" || fail "T2 detect: expected empty, got '$d'"

# auto + TTY (overridden true) + detection -> the detected viewer.
r=$(_viewer_tty() { return 0; }; TERM_PROGRAM=WezTerm PANE_VIEWER=auto _viewer_resolve)
[ "$r" = wezterm ] && pass "T2 resolve: auto + TTY + WezTerm -> wezterm" || fail "T2 resolve: auto positive path -> '$r'"

# ============================ T3: auto + no TTY -> none (headless degrade) ============================
r=$(TERM_PROGRAM=WezTerm PANE_VIEWER=auto _viewer_resolve 2>/dev/null)
[ "$r" = none ] && pass "T3 resolve: auto + NO TTY -> none even with a viewer env present (headless degrade)" \
  || fail "T3 resolve: expected none, got '$r'"

# Defense-in-depth fallback: an unknown value that somehow bypasses cmd_run's pre-flight (tests
# and other direct _wave_run callers) maps to none in _viewer_resolve, never to an exec.
r=$(PANE_VIEWER=bogus _viewer_resolve)
[ "$r" = none ] && pass "T3 resolve: unknown PANE_VIEWER value falls back to none (defense-in-depth)" \
  || fail "T3 resolve: bogus value -> '$r' (want none)"

# ============================ T4: wave opens EXACTLY ONE viewer surface ============================
A=$(mk_mega "$TMP/repo-a")
STATE_A="$TMP/tmux-a"; mkdir -p "$STATE_A"
REC_A="$TMP/rec-a.log"; : > "$REC_A"
arc=0
( export MULTIPLEXER=1 TMUX_CMD="$TMP/tmux-mock" TMUX_MOCK_STATE="$STATE_A" TMUX_SESSION=orch-viewer-a \
    PANE_VIEWER=wezterm VIEWER_CMD="$TMP/viewer-rec" VIEWER_REC_LOG="$REC_A" \
    WAVE_CAP=2 CLAUDE_FLAGS="" CLAUDE_CMD="$TMP/claude-mux" ORCH="$ORCH" MEGADIR="$A"
  _wave_run "$A" "$A/ROADMAP.md" ) > "$TMP/a.out" 2>&1 || arc=$?
[ "$arc" = 0 ] && pass "T4 wave: _wave_run rc 0" || { fail "T4 wave: rc=$arc"; cat "$TMP/a.out"; }
wait_nonempty "$REC_A" || true   # fire-and-forget exec: give the recorder write a moment
settle
n=$(wc -l < "$REC_A" | tr -d ' ')
[ "$n" = 1 ] && pass "T4 wave: viewer opened EXACTLY once for a 2-sub-goal wave (one surface per wave, not per worker)" \
  || { fail "T4 wave: viewer invocations = $n (want 1)"; cat "$REC_A"; }
if grep -q '^wezterm cli spawn -- tmux attach -t orch-viewer-a$' "$REC_A"; then
  pass "T4 wave: argv is the exec-direct wezterm attach to the wave's tmux session"
else
  fail "T4 wave: unexpected viewer argv: $(cat "$REC_A")"
fi

# ============================ T5: reuse guard spans the run ============================
REC_B="$TMP/rec-b.log"; : > "$REC_B"
( export TMUX_SESSION=orch-viewer-b PANE_VIEWER=wezterm VIEWER_CMD="$TMP/viewer-rec" VIEWER_REC_LOG="$REC_B"
  _viewer_open "$A"; _viewer_open "$A"; _viewer_open "$A" ) >/dev/null 2>&1
wait_nonempty "$REC_B" || true
settle
n=$(wc -l < "$REC_B" | tr -d ' ')
[ "$n" = 1 ] && pass "T5 reuse: three _viewer_open calls for one session -> one invocation" \
  || fail "T5 reuse: viewer invocations = $n (want 1)"

# ============================ T6: PANE_VIEWER=none is pull exactly [NEGATIVE CONTROL] ============================
C=$(mk_mega "$TMP/repo-c")
STATE_C="$TMP/tmux-c"; mkdir -p "$STATE_C"
PLOG_C="$TMP/poison-c.log"; : > "$PLOG_C"
crc=0
( export MULTIPLEXER=1 TMUX_CMD="$TMP/tmux-mock" TMUX_MOCK_STATE="$STATE_C" TMUX_SESSION=orch-viewer-c \
    PANE_VIEWER=none VIEWER_CMD="$TMP/viewer-poison" VIEWER_POISON_LOG="$PLOG_C" \
    WAVE_CAP=2 CLAUDE_FLAGS="" CLAUDE_CMD="$TMP/claude-mux" ORCH="$ORCH" MEGADIR="$C"
  _wave_run "$C" "$C/ROADMAP.md" ) > "$TMP/c.out" 2>&1 || crc=$?
settle   # a late async poison write must not slip past the emptiness assert
if [ "$crc" = 0 ] && [ ! -s "$PLOG_C" ]; then
  pass "T6 none [NEGATIVE CONTROL]: PANE_VIEWER=none completes the wave and never invokes a viewer (pull exactly)"
else
  fail "T6 none: rc=$crc, poison: $(cat "$PLOG_C" 2>/dev/null)"
fi

# ============================ T7: headless auto degrade [NEGATIVE CONTROL, named] ============================
# PANE_VIEWER left at the sourced default (auto); the subshell's stderr is captured to a file, so
# `_viewer_tty` is false -- exactly a headless CI run. TERM_PROGRAM=WezTerm is deliberately
# EXPORTED (review fix, test-coverage P2): with a detectable viewer env present, only the TTY
# gate stands between auto and an exec, so this proves the gate itself end-to-end through
# _wave_run, not just "no ambient env => no viewer". Byte-identical to today = the wave completes
# and the poisoned viewer never fires.
D=$(mk_mega "$TMP/repo-d")
STATE_D="$TMP/tmux-d"; mkdir -p "$STATE_D"
PLOG_D="$TMP/poison-d.log"; : > "$PLOG_D"
drc=0
( export MULTIPLEXER=1 TMUX_CMD="$TMP/tmux-mock" TMUX_MOCK_STATE="$STATE_D" TMUX_SESSION=orch-viewer-d \
    TERM_PROGRAM=WezTerm \
    VIEWER_CMD="$TMP/viewer-poison" VIEWER_POISON_LOG="$PLOG_D" \
    WAVE_CAP=2 CLAUDE_FLAGS="" CLAUDE_CMD="$TMP/claude-mux" ORCH="$ORCH" MEGADIR="$D"
  _wave_run "$D" "$D/ROADMAP.md" ) > "$TMP/d.out" 2>&1 || drc=$?
settle
if [ "$drc" = 0 ] && [ ! -s "$PLOG_D" ]; then
  pass "T7 headless [NEGATIVE CONTROL]: default auto + detectable viewer env but NO TTY degrades silently -- the TTY gate holds end-to-end, headless CI byte-identical to today"
else
  fail "T7 headless: rc=$drc, poison: $(cat "$PLOG_D" 2>/dev/null)"
fi

# ============================ T8: MULTIPLEXER off -> viewer unreachable [NEGATIVE CONTROL] ============================
E=$(mk_mega "$TMP/repo-e")
PLOG_E="$TMP/poison-e.log"; : > "$PLOG_E"
erc=0
( # MULTIPLEXER stays at the sourced default (0/off); even an explicit viewer must be unreachable.
  export PANE_VIEWER=wezterm VIEWER_CMD="$TMP/viewer-poison" VIEWER_POISON_LOG="$PLOG_E" \
    WAVE_CAP=2 CLAUDE_FLAGS="" CLAUDE_CMD="$TMP/claude-mux" ORCH="$ORCH" MEGADIR="$E"
  _wave_run "$E" "$E/ROADMAP.md" ) > "$TMP/e.out" 2>&1 || erc=$?
settle
if [ "$erc" = 0 ] && [ ! -s "$PLOG_E" ]; then
  pass "T8 mux-off [NEGATIVE CONTROL]: viewer logic unreachable with MULTIPLEXER unset (plain pull path untouched)"
else
  fail "T8 mux-off: rc=$erc, poison: $(cat "$PLOG_E" 2>/dev/null)"
fi

# ============================ T9: allowlist pre-flight rejection ============================
F=$(mk_mega "$TMP/repo-f")
out=$(PANE_VIEWER=bogus bash "$ORCH" run "$F" --dry-run 2>&1); frc=$?
if [ "$frc" = 64 ] && { trap '' PIPE; printf '%s' "$out" 2>/dev/null || :; } | grep -q 'PANE_VIEWER must be one of: auto|cmux|kitty|wezterm|ghostty|iterm|terminal|none'; then
  pass "T9 allowlist: unknown PANE_VIEWER rejected at pre-flight (rc 64) naming the allowed set"
else
  fail "T9 allowlist: rc=$frc, out: $out"
fi
out=$(PANE_VIEWER=none bash "$ORCH" run "$F" --dry-run 2>&1); frc=$?
[ "$frc" = 0 ] && pass "T9 allowlist: a valid PANE_VIEWER value passes pre-flight" \
  || fail "T9 allowlist: valid value rejected (rc=$frc): $out"
# Exact-token enumeration (review fix, security P2): two adjacent allowed words joined by a
# space are a substring of the joined allowlist, so the old membership idiom accepted them.
out=$(PANE_VIEWER="cmux kitty" bash "$ORCH" run "$F" --dry-run 2>&1); frc=$?
[ "$frc" = 64 ] && pass "T9 allowlist: multi-token 'cmux kitty' is rejected (exact-token match, not substring)" \
  || fail "T9 allowlist: multi-token value accepted (rc=$frc): $out"

# ============================ T10: cmux never gets --focus true (RPC-wedge pin) ============================
REC_G="$TMP/rec-g.log"; : > "$REC_G"
( export TMUX_SESSION=orch-viewer-g PANE_VIEWER=cmux VIEWER_CMD="$TMP/viewer-rec" VIEWER_REC_LOG="$REC_G"
  _viewer_open "$A" ) >/dev/null 2>&1
wait_nonempty "$REC_G" || true
if grep -q -- '--focus false' "$REC_G" && ! grep -q -- '--focus true' "$REC_G"; then
  pass "T10 cmux: argv pins --focus false and never --focus true (known cmux RPC wedge)"
else
  fail "T10 cmux: argv: $(cat "$REC_G")"
fi
if grep -q 'tmux attach -t orch-viewer-g' "$REC_G"; then
  pass "T10 cmux: surface command attaches to the wave's tmux session"
else
  fail "T10 cmux: no attach command in argv: $(cat "$REC_G")"
fi

# ============================ T10b: every viewer's argv shape is dispatched + pinned ============================
# (review fix, test-coverage P1: kitty/ghostty/iterm/terminal were only ever proven as DETECT
# names, never as built argv -- including the two osascript sinks whose argv-item passing is the
# spec's named injection mitigation.)
viewer_argv() {  # viewer session -> prints the recorded argv line
  local rec="$TMP/rec-$1-$2.log"; : > "$rec"
  ( export TMUX_SESSION="$2" PANE_VIEWER="$1" VIEWER_CMD="$TMP/viewer-rec" VIEWER_REC_LOG="$rec"
    _viewer_open "$A" ) >/dev/null 2>&1
  wait_nonempty "$rec" || true
  cat "$rec"
}
v=$(viewer_argv kitty orch-vk)
[ "$v" = "kitty @ launch --type=tab tmux attach -t orch-vk" ] \
  && pass "T10b kitty: exec-direct argv shape" || fail "T10b kitty argv: '$v'"
v=$(viewer_argv wezterm orch-vw)
[ "$v" = "wezterm cli spawn -- tmux attach -t orch-vw" ] \
  && pass "T10b wezterm: exec-direct argv shape" || fail "T10b wezterm argv: '$v'"
v=$(viewer_argv ghostty orch-vg)
[ "$v" = "open -na Ghostty --args -e tmux attach -t orch-vg" ] \
  && pass "T10b ghostty: exec-direct argv shape" || fail "T10b ghostty argv: '$v'"
# osascript sinks: the session name must arrive as a TRAILING ARGV ITEM (after 'end run'), and
# must never be spliced into the AppleScript -e source (which only carries the "tmux attach -t "
# prefix + `item 1 of argv`). A future edit interpolating $mux into the -e string would fail both.
v=$(viewer_argv iterm orch-vi)
case "$v" in
  osascript\ -e\ on\ run\ argv*iTerm*"end run orch-vi")
    if { trap '' PIPE; printf '%s' "$v" 2>/dev/null || :; } | grep -q 'attach -t orch-vi'; then
      fail "T10b iterm: session name SPLICED into the AppleScript source: '$v'"
    else
      pass "T10b iterm: osascript gets the session name as a trailing argv item, never spliced into the source"
    fi ;;
  *) fail "T10b iterm argv: '$v'" ;;
esac
v=$(viewer_argv terminal orch-vt)
case "$v" in
  osascript\ -e\ on\ run\ argv*Terminal*"end run orch-vt")
    if { trap '' PIPE; printf '%s' "$v" 2>/dev/null || :; } | grep -q 'attach -t orch-vt'; then
      fail "T10b terminal: session name SPLICED into the AppleScript source: '$v'"
    else
      pass "T10b terminal: osascript gets the session name as a trailing argv item, never spliced into the source"
    fi ;;
  *) fail "T10b terminal argv: '$v'" ;;
esac

# ============================ T11: charset gate on the session name [SECURITY NC] ============================
REC_H="$TMP/rec-h.log"; : > "$REC_H"
PWNED="$TMP/pwned-viewer"
( export TMUX_SESSION="x; touch $PWNED" PANE_VIEWER=cmux VIEWER_CMD="$TMP/viewer-rec" VIEWER_REC_LOG="$REC_H"
  _viewer_open "$A" ) > "$TMP/h.out" 2>&1
hrc=$?
settle
# Note the mock's limit: the recorder receives argv directly and never re-parses it through a
# shell, so $PWNED can't fire via the mock even if the charset gate were removed -- the
# load-bearing asserts here are the EMPTY recorder log + the loud warn; the pwned-file check
# only guards against a future regression that hands the raw name to a real shell sink.
if [ "$hrc" = 0 ] && [ ! -s "$REC_H" ] && [ ! -e "$PWNED" ]; then
  pass "T11 charset [SECURITY NC]: a metachar session name is refused -- viewer never invoked, no host command ran, wave untouched (rc 0)"
else
  fail "T11 charset: rc=$hrc, rec: $(cat "$REC_H" 2>/dev/null), pwned: $([ -e "$PWNED" ] && echo YES || echo no)"
fi
grep -q 'charset gate' "$TMP/h.out" \
  && pass "T11 charset: refusal is loud (warn names the gate)" \
  || fail "T11 charset: no warn emitted"

# ============================ T12: viewer failure never fails the wave ============================
I=$(mk_mega "$TMP/repo-i")
STATE_I="$TMP/tmux-i"; mkdir -p "$STATE_I"
REC_I="$TMP/rec-i.log"; : > "$REC_I"
irc=0
( export MULTIPLEXER=1 TMUX_CMD="$TMP/tmux-mock" TMUX_MOCK_STATE="$STATE_I" TMUX_SESSION=orch-viewer-i \
    PANE_VIEWER=wezterm VIEWER_CMD="$TMP/viewer-fail" VIEWER_REC_LOG="$REC_I" \
    WAVE_CAP=2 CLAUDE_FLAGS="" CLAUDE_CMD="$TMP/claude-mux" ORCH="$ORCH" MEGADIR="$I"
  _wave_run "$I" "$I/ROADMAP.md" ) > "$TMP/i.out" 2>&1 || irc=$?
ib1=$(_sg_line "$I/ROADMAP.md" SG-01); ib2=$(_sg_line "$I/ROADMAP.md" SG-02)
iboxes=0
case "$ib1" in '- [x] SG-01'*) case "$ib2" in '- [x] SG-02'*) iboxes=1 ;; esac ;; esac
if [ "$irc" = 0 ] && [ "$iboxes" = 1 ]; then
  pass "T12 resilience: a failing viewer (rc 7) degrades to pull; wave rc 0 and both boxes flipped"
else
  fail "T12 resilience: rc=$irc, SG-01: $ib1, SG-02: $ib2"; cat "$TMP/i.out"
fi
# The degrade warn is written by the fire-and-forget subshell (inherited stderr -> i.out); poll.
w=0
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q 'degrading to pull' "$TMP/i.out" && { w=1; break; }; sleep 0.2; done
[ "$w" = 1 ] \
  && pass "T12 resilience: degrade warn emitted" \
  || fail "T12 resilience: no degrade warn in output"

# ============================ T13: real-exec path, missing binary degrades ============================
# (review fix, test-coverage P1: VIEWER_CMD unset is the DEFAULT operator path; prove the
# `command -v` miss (rc 127) degrades the same way. PATH is pinned to system dirs that carry
# tr/grep but no kitty on any dev box or CI runner.)
T13OUT="$TMP/t13.out"; : > "$T13OUT"
t13rc=0
( export TMUX_SESSION=orch-viewer-t13 PANE_VIEWER=kitty VIEWER_CMD="" PATH=/usr/bin:/bin
  _viewer_open "$A" ) > "$T13OUT" 2>&1 || t13rc=$?
w=0
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q 'degrading to pull' "$T13OUT" && { w=1; break; }; sleep 0.2; done
if [ "$t13rc" = 0 ] && [ "$w" = 1 ] && grep -q 'rc 127' "$T13OUT"; then
  pass "T13 real-exec: missing viewer binary (command -v miss, rc 127) degrades to pull; _viewer_open rc 0"
else
  fail "T13 real-exec: rc=$t13rc, out: $(cat "$T13OUT")"
fi

echo "----"
if [ "$fails" = 0 ]; then
  echo "ALL PASS"
  exit 0
else
  echo "$fails FAILING"
  exit 1
fi
