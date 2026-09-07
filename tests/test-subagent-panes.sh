#!/usr/bin/env bash
# test-subagent-panes.sh (SPEC-234): read-only jsonl-tail panes over background-subagent
# transcripts. `panes <megadir> <target>...` (a jsonl path | a directory | --latest) grows one
# read-only tmux window per resolved transcript running `tail -F | jq` via the hidden `_pane-tail`
# re-entry subcommand -- mirrors the SPEC-119 `_pane_spawn`/`_pane-exec` exec-direct pattern and
# the SPEC-121 viewer-push once-per-session-creation rule.
#
# No real tmux server: tmux is mocked via the TMUX_CMD seam (records has-session/new-session/
# new-window/kill-window argv, same fixture shape as test-multiplexer.sh / test-pane-viewer.sh).
# Viewers are mocked via VIEWER_CMD (recorder + poison, same as test-pane-viewer.sh). The
# formatter (T6) is exercised directly against `lib/queue/pane-tail.jq` with generated fixtures
# (printf/jq at runtime -- no ESC/OSC bytes pasted literally into this file).
set -uo pipefail
unset CMUX_WORKSPACE_ID KITTY_WINDOW_ID TERM_PROGRAM PANE_VIEWER VIEWER_CMD TMUX_SESSION TMUX_CMD PANE_TAIL_JQ 2>/dev/null || true
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/queue/orchestrate.sh
source "$KIT/lib/queue/orchestrate.sh"

fails=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }

# The viewer exec is fire-and-forget (backgrounded + disowned), so a recorder/poison write can
# land shortly AFTER cmd_panes returns. wait_nonempty polls for a positive write (bounded);
# settle gives a would-be late write time to land before an emptiness/exact-count assertion.
wait_nonempty() {  # file [tries]
  local f="$1" n="${2:-30}" i=0
  while [ "$i" -lt "$n" ]; do [ -s "$f" ] && return 0; sleep 0.1; i=$((i + 1)); done
  return 1
}
settle() { sleep 0.5; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# tmux mock: records every call to $STATE/calls.log (full argv, for -- / order assertions), and
# tracks state (has-session/new-session/new-window/kill-window) without ever exec'ing the pane's
# command -- these tests assert argv shape and call counts, not pane output (T6 exercises the
# formatter directly).
cat > "$TMP/tmux-mock" <<'MOCK'
#!/usr/bin/env bash
set -u
STATE="${TMUX_MOCK_STATE:?TMUX_MOCK_STATE not set}"
mkdir -p "$STATE"
printf '%s\n' "$*" >> "$STATE/calls.log"
sub="$1"; shift
case "$sub" in
  has-session)
    [ "$1" = -t ] && shift
    [ -f "$STATE/session.$1" ]; exit $?
    ;;
  new-session)
    name=""
    while [ "$#" -gt 0 ]; do case "$1" in -s) name="$2"; shift 2 ;; -n) shift 2 ;; *) shift ;; esac; done
    : > "$STATE/session.$name"
    ;;
  new-window)
    session="" id=""; args=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -d) shift ;;
        -t) session="$2"; shift 2 ;;
        -n) id="$2"; shift 2 ;;
        --) shift; args=("$@"); break ;;
        *) shift ;;
      esac
    done
    : > "$STATE/session.$session"
    : > "$STATE/win.$session.$id"
    printf '%s\n' "${args[@]}" > "$STATE/argv.$session.$id"
    ;;
  kill-window)
    printf '%s\n' "$*" >> "$STATE/kills.log"
    ;;
  *) exit 0 ;;
esac
MOCK
chmod +x "$TMP/tmux-mock"

cat > "$TMP/viewer-rec" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${VIEWER_REC_LOG:?}"
exit 0
MOCK
chmod +x "$TMP/viewer-rec"

cat > "$TMP/viewer-poison" <<'MOCK'
#!/usr/bin/env bash
echo "POISON: viewer invoked with: $*" >> "${VIEWER_POISON_LOG:?}"
exit 99
MOCK
chmod +x "$TMP/viewer-poison"

# ================================ T1: unit -- windows + idempotence ================================
echo "=== T1: 2 fixtures -> 2 sa-<id> windows, session ensured once; re-invoke -> kill-window precedes respawn ==="
FIX1="$TMP/transcripts1"; mkdir -p "$FIX1"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}' >| "$FIX1/agent-abc.jsonl"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}' >| "$FIX1/agent-def.jsonl"
MEGA1="$TMP/mega1"; mkdir -p "$MEGA1"
STATE1="$TMP/tmux1"; mkdir -p "$STATE1"
out1=$(
  export TMUX_CMD="$TMP/tmux-mock" TMUX_MOCK_STATE="$STATE1" TMUX_SESSION=orch-panes-t1 PANE_VIEWER=none
  cmd_panes "$MEGA1" "$FIX1" 2>&1
)
rc1=$?
[ "$rc1" = 0 ] && pass "T1: cmd_panes rc 0" || fail "T1: rc=$rc1: $out1"
[ -f "$STATE1/win.orch-panes-t1.sa-abc" ] && [ -f "$STATE1/win.orch-panes-t1.sa-def" ] \
  && pass "T1: two sa-<id> windows created for two fixtures" \
  || fail "T1: windows missing: $(ls "$STATE1" 2>/dev/null)"
n_new_session=$(grep -c '^new-session' "$STATE1/calls.log")
[ "$n_new_session" = 1 ] && pass "T1: tmux session ensured exactly once" || fail "T1: new-session called $n_new_session times"
{ trap '' PIPE; printf '%s\n' "$out1" 2>/dev/null || :; } | grep -q 'spawned 2, skipped 0' \
  && pass "T1: summary line 'spawned 2, skipped 0'" || fail "T1: summary: $out1"

: > "$STATE1/calls.log"
(
  export TMUX_CMD="$TMP/tmux-mock" TMUX_MOCK_STATE="$STATE1" TMUX_SESSION=orch-panes-t1 PANE_VIEWER=none
  cmd_panes "$MEGA1" "$FIX1" >/dev/null 2>&1
)
n_new_session2=$(grep -c '^new-session' "$STATE1/calls.log")
[ "$n_new_session2" = 0 ] && pass "T1: re-invoke reuses the existing session (no second new-session)" \
  || fail "T1: new-session called again ($n_new_session2 times) on re-invoke"
k=$(grep -c '^kill-window' "$STATE1/calls.log")
[ "$k" = 2 ] && pass "T1: re-invoke issues one kill-window per window (idempotent pre-clean)" \
  || fail "T1: kill-window count=$k"
kabc=$(grep -n 'kill-window -t orch-panes-t1:sa-abc' "$STATE1/calls.log" | head -1 | cut -d: -f1)
nabc=$(grep -n '^new-window' "$STATE1/calls.log" | grep 'sa-abc' | head -1 | cut -d: -f1)
if [ -n "$kabc" ] && [ -n "$nabc" ] && [ "$kabc" -lt "$nabc" ]; then
  pass "T1: kill-window precedes new-window for the respawned window (idempotence)"
else
  fail "T1: order wrong or missing (kill@${kabc:-?} new@${nabc:-?}): $(cat "$STATE1/calls.log")"
fi

# ================================ T2: security-pin ================================
echo "=== T2: new-window argv is exec-direct with a -- separator; re-entry tokens separate; paths absolute ==="
MEGA2="$TMP/mega2"; mkdir -p "$MEGA2"
STATE2="$TMP/tmux2"; mkdir -p "$STATE2"
(
  export TMUX_CMD="$TMP/tmux-mock" TMUX_MOCK_STATE="$STATE2" TMUX_SESSION=orch-panes-t2 PANE_VIEWER=none
  cmd_panes "$MEGA2" "$FIX1/agent-abc.jsonl" >/dev/null 2>&1
)
grep -q -- ' -- ' "$STATE2/calls.log" && pass "T2: new-window argv includes a -- separator" \
  || fail "T2: no -- in: $(cat "$STATE2/calls.log")"
argv_file="$STATE2/argv.orch-panes-t2.sa-abc"
if [ -f "$argv_file" ]; then
  nlines=$(wc -l < "$argv_file" | tr -d ' ')
  [ "$nlines" = 4 ] && pass "T2: re-entry argv is 4 SEPARATE tokens (script, _pane-tail, jsonl, formatter)" \
    || fail "T2: argv token count=$nlines: $(cat "$argv_file")"
  l1=$(sed -n '1p' "$argv_file"); l2=$(sed -n '2p' "$argv_file")
  l3=$(sed -n '3p' "$argv_file"); l4=$(sed -n '4p' "$argv_file")
  case "$l1" in */orchestrate.sh) pass "T2: argv[0] is orchestrate.sh's own path" ;; *) fail "T2: argv[0]='$l1'" ;; esac
  [ "$l2" = "_pane-tail" ] && pass "T2: argv[1] is the bare re-entry subcommand" || fail "T2: argv[1]='$l2'"
  case "$l3" in /*) pass "T2: jsonl path is absolute" ;; *) fail "T2: jsonl path not absolute: '$l3'" ;; esac
  case "$l4" in /*) pass "T2: formatter path is absolute" ;; *) fail "T2: formatter path not absolute: '$l4'" ;; esac
else
  fail "T2: argv capture file missing ($argv_file)"
fi

# ================================ T3: skip behavior + usage ================================
echo "=== T3: skips (missing, wrong basename, unexpanded glob, empty dir) warn + count; rc 0; siblings still spawn ==="
FIX3="$TMP/transcripts3"; mkdir -p "$FIX3/emptydir" "$FIX3/badname"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]}}' >| "$FIX3/agent-ok.jsonl"
printf '%s\n' 'not agent shaped' >| "$FIX3/badname/not-agent.jsonl"
MEGA3="$TMP/mega3"; mkdir -p "$MEGA3"
STATE3="$TMP/tmux3"; mkdir -p "$STATE3"
out3=$(
  export TMUX_CMD="$TMP/tmux-mock" TMUX_MOCK_STATE="$STATE3" TMUX_SESSION=orch-panes-t3 PANE_VIEWER=none
  cmd_panes "$MEGA3" "$FIX3" "$FIX3/nope/agent-x.jsonl" "$FIX3/badname/not-agent.jsonl" 'agent-*.jsonl' "$FIX3/emptydir" 2>&1
)
rc3=$?
[ "$rc3" = 0 ] && pass "T3: rc 0 despite multiple skips" || fail "T3: rc=$rc3"
{ trap '' PIPE; printf '%s\n' "$out3" 2>/dev/null || :; } | grep -q 'not a readable regular file' \
  && pass "T3: missing-file skip warns" || fail "T3: no missing-file warning: $out3"
{ trap '' PIPE; printf '%s\n' "$out3" 2>/dev/null || :; } | grep -q 'basename does not match' \
  && pass "T3: wrong-basename skip warns" || fail "T3: no basename warning: $out3"
{ trap '' PIPE; printf '%s\n' "$out3" 2>/dev/null || :; } | grep -q 'empty dir' \
  && pass "T3: empty-dir warns" || fail "T3: no empty-dir warning: $out3"
{ trap '' PIPE; printf '%s\n' "$out3" 2>/dev/null || :; } | grep -q 'spawned 1, skipped 3' \
  && pass "T3: summary counts 1 spawned / 3 skipped (valid sibling still spawns)" || fail "T3: summary: $out3"

out3b=$(cmd_panes "$MEGA3" 2>&1); rc3b=$?
if [ "$rc3b" = 0 ] && { trap '' PIPE; printf '%s\n' "$out3b" 2>/dev/null || :; } | grep -q '^usage:'; then
  pass "T3: <2 total args -> usage on stderr, rc 0"
else
  fail "T3: rc=$rc3b out=$out3b"
fi

# ============== T3b: filename-embedded ESC bytes never reach the operator's terminal raw ==============
echo "=== T3b: ESC-embedded filename is sanitized on display; symlink target is skipped, never spawned ==="
FIX3B="$TMP/transcripts3b"; mkdir -p "$FIX3B"
# Never paste literal ESC/OSC bytes into this file -- generate the fixture name at runtime via
# ANSI-C quoting (SPEC-234 review finding: a transcript FILENAME is subagent-influenced data).
badname=$'agent-\x1b]52;c;evil\x07x.jsonl'
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]}}' >| "$FIX3B/$badname"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]}}' >| "$FIX3B/agent-real.jsonl"
ln -s agent-real.jsonl "$FIX3B/agent-link.jsonl"
MEGA3B="$TMP/mega3b"; mkdir -p "$MEGA3B"
STATE3B="$TMP/tmux3b"; mkdir -p "$STATE3B"
out3b2=$(
  export TMUX_CMD="$TMP/tmux-mock" TMUX_MOCK_STATE="$STATE3B" TMUX_SESSION=orch-panes-t3b PANE_VIEWER=none
  cmd_panes "$MEGA3B" "$FIX3B" 2>&1
)
if { trap '' PIPE; printf '%s' "$out3b2" 2>/dev/null || :; } | grep -q "$(printf '\x1b')"; then
  fail "T3b: raw ESC byte reached combined stdout+stderr: $(printf '%s' "$out3b2" | cat -v)"
else
  pass "T3b: no raw ESC byte in combined output"
fi
{ trap '' PIPE; printf '%s\n' "$out3b2" 2>/dev/null || :; } | grep -qF 'agent-??52?c?evil?x.jsonl' \
  && pass "T3b: ESC-embedded filename rendered sanitized ('?' replacement)" \
  || fail "T3b: sanitized filename not found: $out3b2"
{ trap '' PIPE; printf '%s\n' "$out3b2" 2>/dev/null || :; } | grep -q 'skip: symlink, not a real transcript file' \
  && pass "T3b: symlink target skipped with its own warning (not spawned then ghost-killed)" \
  || fail "T3b: no symlink-skip warning: $out3b2"
[ ! -f "$STATE3B/win.orch-panes-t3b.sa-link" ] \
  && pass "T3b: no window created for the symlink target" \
  || fail "T3b: a window was created for the symlink target"
{ trap '' PIPE; printf '%s\n' "$out3b2" 2>/dev/null || :; } | grep -q 'spawned 2, skipped 1' \
  && pass "T3b: summary counts symlink as skipped (2 spawned: badname + real)" \
  || fail "T3b: summary: $out3b2"

# ================================ T4: directory expansion + --latest ================================
echo "=== T4: --latest derives slug + newest-mtime subagents dir under a fake \$HOME (DEC-007) ==="
FAKEHOME="$TMP/fakehome"; mkdir -p "$FAKEHOME"
FAKECWD="$TMP/fakecwd/some-proj"; mkdir -p "$FAKECWD"
slug=$(cd "$FAKECWD" && printf '%s' "$PWD" | tr '/.' '-')
OLDSESS="$FAKEHOME/.claude/projects/$slug/sess-old/subagents"
NEWSESS="$FAKEHOME/.claude/projects/$slug/sess-new/subagents"
mkdir -p "$OLDSESS" "$NEWSESS"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"old"}]}}' >| "$OLDSESS/agent-old.jsonl"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"new"}]}}' >| "$NEWSESS/agent-new.jsonl"
touch -t 202601010000 "$OLDSESS"
touch "$NEWSESS"

MEGA4="$TMP/mega4"; mkdir -p "$MEGA4"
STATE4="$TMP/tmux4"; mkdir -p "$STATE4"
out4=$(
  cd "$FAKECWD" || exit 1
  export HOME="$FAKEHOME" TMUX_CMD="$TMP/tmux-mock" TMUX_MOCK_STATE="$STATE4" TMUX_SESSION=orch-panes-t4 PANE_VIEWER=none
  cmd_panes "$MEGA4" --latest 2>&1
)
[ -f "$STATE4/win.orch-panes-t4.sa-new" ] && pass "T4: --latest picked the NEWEST-mtime subagents dir" \
  || fail "T4: expected sa-new window; state: $(ls "$STATE4" 2>/dev/null)"
[ ! -f "$STATE4/win.orch-panes-t4.sa-old" ] && pass "T4: --latest did NOT also spawn the older session's window" \
  || fail "T4: unexpectedly spawned sa-old too"
{ trap '' PIPE; printf '%s\n' "$out4" 2>/dev/null || :; } | grep -q 'spawned 1, skipped 0' \
  && pass "T4: summary reflects exactly one resolved transcript" || fail "T4: summary: $out4"

# --latest with no matching project dir: clean miss, warns, rc 0, no windows.
STATE4B="$TMP/tmux4b"; mkdir -p "$STATE4B"
out4b=$(
  cd "$TMP" || exit 1
  export HOME="$TMP/no-such-home" TMUX_CMD="$TMP/tmux-mock" TMUX_MOCK_STATE="$STATE4B" TMUX_SESSION=orch-panes-t4b PANE_VIEWER=none
  cmd_panes "$MEGA4" --latest 2>&1
); rc4b=$?
if [ "$rc4b" = 0 ] && { trap '' PIPE; printf '%s\n' "$out4b" 2>/dev/null || :; } | grep -q -- '--latest:' && { trap '' PIPE; printf '%s\n' "$out4b" 2>/dev/null || :; } | grep -q 'spawned 0, skipped 0'; then
  pass "T4: --latest with no project dir is a clean miss (warns, rc 0, spawns nothing)"
else
  fail "T4: rc=$rc4b out=$out4b"
fi

# ================================ T5: _pane-tail refusals [NEGATIVE CONTROL] ================================
echo "=== T5: _pane-tail refuses each hazard shape, exit 64, named stderr ==="
FIX5="$TMP/transcripts5"; mkdir -p "$FIX5"
GOODFMT="$KIT/lib/queue/pane-tail.jq"
VALID_JSONL="$FIX5/agent-valid.jsonl"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]}}' >| "$VALID_JSONL"

out=$(cmd_pane_tail "$FIX5" "$GOODFMT" 2>&1); rc=$?
[ "$rc" = 64 ] && { trap '' PIPE; printf '%s\n' "$out" 2>/dev/null || :; } | grep -q 'not a regular file' \
  && pass "T5a: a directory is refused, exit 64" || fail "T5a: rc=$rc out=$out"

UNREADABLE="$FIX5/agent-unreadable.jsonl"
printf '%s\n' '{"type":"assistant"}' >| "$UNREADABLE"
chmod 000 "$UNREADABLE"
out=$(cmd_pane_tail "$UNREADABLE" "$GOODFMT" 2>&1); rc=$?
chmod 644 "$UNREADABLE"
[ "$rc" = 64 ] && { trap '' PIPE; printf '%s\n' "$out" 2>/dev/null || :; } | grep -q 'not readable' \
  && pass "T5b: an unreadable file is refused, exit 64" || fail "T5b: rc=$rc out=$out"

LINK="$FIX5/agent-link.jsonl"
ln -sf "$VALID_JSONL" "$LINK"
out=$(cmd_pane_tail "$LINK" "$GOODFMT" 2>&1); rc=$?
[ "$rc" = 64 ] && { trap '' PIPE; printf '%s\n' "$out" 2>/dev/null || :; } | grep -q 'symlink' \
  && pass "T5c: a symlink is refused, exit 64 [SECURITY L4]" || fail "T5c: rc=$rc out=$out"

WRONG="$FIX5/not-agent.jsonl"
printf '%s\n' '{"type":"assistant"}' >| "$WRONG"
out=$(cmd_pane_tail "$WRONG" "$GOODFMT" 2>&1); rc=$?
[ "$rc" = 64 ] && { trap '' PIPE; printf '%s\n' "$out" 2>/dev/null || :; } | grep -q 'basename does not match' \
  && pass "T5d: a wrong-basename file is refused, exit 64" || fail "T5d: rc=$rc out=$out"

out=$(cmd_pane_tail "$VALID_JSONL" "$FIX5/no-such.jq" 2>&1); rc=$?
[ "$rc" = 64 ] && { trap '' PIPE; printf '%s\n' "$out" 2>/dev/null || :; } | grep -q 'formatter missing or unreadable' \
  && pass "T5e: a missing formatter is refused, exit 64" || fail "T5e: rc=$rc out=$out"

# ================================ T6: formatter ================================
echo "=== T6: formatter -- verbatim text, ->/<- lines, drops, malformed/truncated survive, ESC/OSC-52 stripped, cap ==="
PROG="$KIT/lib/queue/pane-tail.jq"
FIX6="$TMP/fixture6.jsonl"
{
  jq -nc '{type:"assistant", message:{content:[{type:"text", text:"hello world"}]}}'
  jq -nc '{type:"assistant", message:{content:[{type:"tool_use", name:"Bash", input:{command:"ls"}}]}}'
  jq -nc '{type:"user", message:{content:[{type:"tool_result", content:"0123456789"}]}}'
  jq -nc '{type:"attachment", foo:"bar"}'
  printf '%s\n' 'not json at all {'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"cut off'
  esc_text=$'AB\x1b[31mCD\x1b]52;c;AAA\x07EF'   # ESC(0x1b)/BEL(0x07) generated via ANSI-C quoting
  jq -nc --arg t "$esc_text" '{type:"assistant", message:{content:[{type:"text", text:$t}]}}'
  bigstr=$(printf 'x%.0s' $(seq 1 2500))
  jq -nc --arg t "$bigstr" '{type:"assistant", message:{content:[{type:"text", text:$t}]}}'
  jq -nc '{type:"assistant", message:{content:[{type:"text", text:"last line ok"}]}}'
} >| "$FIX6"

out6=$(jq -R -r --unbuffered -f "$PROG" "$FIX6")
n6=$(printf '%s\n' "$out6" | wc -l | tr -d ' ')
[ "$n6" = 6 ] && pass "T6: attachment/malformed/truncated-json lines dropped (6 rendered from 9 input lines)" \
  || fail "T6: got $n6 lines: $out6"
line1=$(printf '%s\n' "$out6" | sed -n '1p')
[ "$line1" = "hello world" ] && pass "T6: assistant text renders verbatim" || fail "T6: line1='$line1'"
line2=$(printf '%s\n' "$out6" | sed -n '2p')
case "$line2" in '-> Bash '*) pass "T6: tool_use renders as -> <name> <input prefix>" ;; *) fail "T6: line2='$line2'" ;; esac
line3=$(printf '%s\n' "$out6" | sed -n '3p')
[ "$line3" = "<- result (10 chars)" ] && pass "T6: tool_result renders as count-only <- result (N chars)" \
  || fail "T6: line3='$line3'"
line4=$(printf '%s\n' "$out6" | sed -n '4p')
esc_expected='AB[31mCD]52;c;AAAEF'
[ "$line4" = "$esc_expected" ] && pass "T6: ESC/OSC-52 control bytes stripped, EXACT output match [SECURITY H1]" \
  || fail "T6: line4 mismatch"
line5=$(printf '%s\n' "$out6" | sed -n '5p')
len5=${#line5}
case "$line5" in *'...[truncated]') trunc_ok=1 ;; *) trunc_ok=0 ;; esac
[ "$len5" = 2014 ] && [ "$trunc_ok" = 1 ] && pass "T6: a long line is capped at 2000 chars + ...[truncated] marker" \
  || fail "T6: len5=$len5 trunc_ok=$trunc_ok"
line6=$(printf '%s\n' "$out6" | sed -n '6p')
[ "$line6" = "last line ok" ] && pass "T6: a later valid line still renders after the malformed/truncated ones" \
  || fail "T6: line6='$line6'"

# ================================ T7: viewer / charset gate [SECURITY NEGATIVE CONTROL] ================================
echo "=== T7: viewer fires only on session creation; a metachar TMUX_SESSION is refused by the charset gate ==="
MEGA7="$TMP/mega7"; mkdir -p "$MEGA7"
STATE7="$TMP/tmux7"; mkdir -p "$STATE7"
REC7="$TMP/viewer-rec7.log"; : > "$REC7"
FIX7="$TMP/transcripts7"; mkdir -p "$FIX7"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]}}' >| "$FIX7/agent-x.jsonl"

(
  export TMUX_CMD="$TMP/tmux-mock" TMUX_MOCK_STATE="$STATE7" TMUX_SESSION=orch-panes-t7 \
    PANE_VIEWER=wezterm VIEWER_CMD="$TMP/viewer-rec" VIEWER_REC_LOG="$REC7"
  unset _VIEWER_OPENED
  cmd_panes "$MEGA7" "$FIX7" >/dev/null 2>&1
)
wait_nonempty "$REC7" || true; settle
n=$(wc -l < "$REC7" | tr -d ' ')
[ "$n" = 1 ] && pass "T7: first panes call (session creation) opens exactly one viewer surface" \
  || fail "T7: viewer calls=$n: $(cat "$REC7")"

(
  export TMUX_CMD="$TMP/tmux-mock" TMUX_MOCK_STATE="$STATE7" TMUX_SESSION=orch-panes-t7 \
    PANE_VIEWER=wezterm VIEWER_CMD="$TMP/viewer-rec" VIEWER_REC_LOG="$REC7"
  unset _VIEWER_OPENED
  cmd_panes "$MEGA7" "$FIX7" >/dev/null 2>&1
)
settle
n2=$(wc -l < "$REC7" | tr -d ' ')
[ "$n2" = 1 ] && pass "T7: second panes call against the SAME already-running session opens no additional viewer" \
  || fail "T7: viewer calls after 2nd call=$n2: $(cat "$REC7")"

# A bare (slash-free) marker name: real tmux never re-parses this through a shell either way, and
# our tmux-mock's own bookkeeping stores the session name as a filename component, so a marker
# WITH a slash would break the mock's fixture I/O, not the code under test. Note the mock's own
# limit (same caveat as test-pane-viewer.sh T11): the recorder receives argv directly and never
# re-parses it through a shell, so $PWNED7 could never fire even if the charset gate were
# removed -- the load-bearing asserts here are the EMPTY poison log + the loud charset warn.
PWNED7="pwned7-marker-$$"
POISON7="$TMP/poison7.log"; : > "$POISON7"
STATE7B="$TMP/tmux7b"; mkdir -p "$STATE7B"
out7=$(
  export TMUX_CMD="$TMP/tmux-mock" TMUX_MOCK_STATE="$STATE7B" TMUX_SESSION="x; touch $PWNED7" \
    PANE_VIEWER=wezterm VIEWER_CMD="$TMP/viewer-poison" VIEWER_POISON_LOG="$POISON7"
  unset _VIEWER_OPENED
  cmd_panes "$MEGA7" "$FIX7" 2>&1
); rc7=$?
settle
[ "$rc7" = 0 ] && pass "T7: a metachar TMUX_SESSION still returns rc 0" || fail "T7: rc=$rc7"
if [ ! -s "$POISON7" ] && [ ! -e "$PWNED7" ]; then
  pass "T7: no host command ran [SECURITY NC]: viewer never invoked, no injection via TMUX_SESSION"
else
  fail "T7: poison: $(cat "$POISON7" 2>/dev/null), pwned: $([ -e "$PWNED7" ] && echo YES || echo no)"
fi
{ trap '' PIPE; printf '%s\n' "$out7" 2>/dev/null || :; } | grep -q 'charset gate' \
  && pass "T7: the refusal names the charset gate (loud)" || fail "T7: no charset-gate warning: $out7"

echo "----"
if [ "$fails" = 0 ]; then
  echo "ALL PASS"
  exit 0
else
  echo "$fails FAILING"
  exit 1
fi
