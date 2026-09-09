#!/usr/bin/env bash
# requires: claude codex opencode
# test-harness-dispatch.sh
# Pins the ID-390 WIRING: the `Harness:` goal-file header actually routes a sub-goal to a non-claude
# CLI. tests/test-harness-adapter.sh pins the argv RESOLVER; this file pins that orchestrate.sh
# reaches it, delivers the prompt correctly, and leaves the claude path alone.
#
# The load-bearing assertions:
#   - absent `Harness:` -> claude -> the ORIGINAL $CLAUDE_CMD path (the backward-compat invariant;
#     the 178 pre-existing orchestrate assertions are the other half of that proof).
#   - an unknown harness hard-stops (64) instead of falling back to claude -- a silent fallback
#     would run the sub-goal on the wrong, wrong-priced vendor.
#   - the claude tier allowlist applies ONLY to claude: `Model: gpt-5` under `Harness: codex` is
#     admitted verbatim, while the same value with no harness is still rejected (negative control).
#   - the vendor path really EXECS the vendor, with the prompt delivered per the adapter's declared
#     mode. Proven with mock binaries on PATH that record their argv + stdin to disk.
#
# The mocks are what make this a real test rather than a string comparison: a wrong prompt-delivery
# mode does not error, it runs the agent with an empty prompt and exits 0, so only an artifact
# written by the invoked process can tell the two apart.
set -uo pipefail
export TIER4_CLOSE=0
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/queue/orchestrate.sh
source "$KIT/lib/queue/orchestrate.sh"

fails=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A mega-goal dir with one sub-goal whose goal file carries the given header lines.
mk_goal() {  # headers... -> echoes the megadir
  local dir; dir=$(mktemp -d "$TMP/mega.XXXXXX")
  mkdir -p "$dir/goals"
  { for h in "$@"; do printf '%s\n' "$h"; done; printf '\nbody\n'; } > "$dir/goals/01-thing.md"
  printf '%s\n' "$dir"
}

# Mock vendor binaries on PATH. Each records its argv and its stdin, so the test can prove BOTH that
# the right binary ran and that the prompt arrived by the right channel.
MOCKBIN="$TMP/bin"; mkdir -p "$MOCKBIN"
for v in codex pi opencode; do
  cat > "$MOCKBIN/$v" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TMP/$v.argv"
printf '%s' "\${!#}" > "$TMP/$v.lastarg"   # the RAW last positional (the prompt, for argv-mode)
cat > "$TMP/$v.stdin"
exit 0
EOF
  chmod +x "$MOCKBIN/$v"
done
export PATH="$MOCKBIN:$PATH"

# Hermetic config: point the resolver at temp dirs so it never reads the real installed kit.toml.
# set_harnesses writes the kit-root kit.toml's `mega.enabled_agent_clis` value; "" = claude-only (feature
# OFF). Default the suite to all three enabled; the gate section flips it to "" to prove OFF.
mkdir -p "$TMP/cfgroot" "$TMP/cfgproj"
export KIT_CONFIG_ROOT="$TMP/cfgroot" KIT_PROJECT_ROOT="$TMP/cfgproj"
set_harnesses() { printf '[mega]\nenabled_agent_clis = "%s"\n' "$1" > "$TMP/cfgroot/kit.toml"; }
set_harnesses "codex pi opencode"

echo "== _harness_of: header parse + default =="
d=$(mk_goal "Model: opus");                 got=$(_harness_of "$d/goals/01-thing.md")
[ "$got" = claude ] && pass "absent Harness: defaults to claude" || { fail "default harness"; echo "got: $got"; }
d=$(mk_goal "Harness: codex");              got=$(_harness_of "$d/goals/01-thing.md")
[ "$got" = codex ] && pass "Harness: codex parses" || { fail "codex parse"; echo "got: $got"; }
d=$(mk_goal "Harness:   OpenCode  ");       got=$(_harness_of "$d/goals/01-thing.md")
[ "$got" = opencode ] && pass "Harness: is case-insensitive + trimmed" || { fail "case/trim"; echo "got: $got"; }
got=$(_harness_of "/nonexistent/goal.md")
[ "$got" = claude ] && pass "missing goal file -> claude" || { fail "missing file"; echo "got: $got"; }

echo "== unknown harness hard-stops, never falls back to claude =="
d=$(mk_goal "Harness: bogusvendor")
if out=$(_harness_of "$d/goals/01-thing.md" 2>&1); then
  fail "unknown harness should return nonzero"; echo "got: $out"
else
  rc=$?
  [ "$rc" = 64 ] && pass "unknown harness returns 64" || { fail "unknown harness rc"; echo "rc=$rc"; }
  case "$out" in *claude*) pass "error names the known vendors" ;; *) fail "error should list known vendors"; echo "$out" ;; esac
fi

echo "== config gate: multi-vendor is opt-in, default OFF =="
# With the feature DISABLED (empty mega.enabled_agent_clis), a known vendor must hard-stop, NOT fall back to
# claude. This is the whole point of the kit-config gate Han asked for: the code ships to everyone,
# the capability stays off until a user enables a vendor they actually set up.
set_harnesses ""
d=$(mk_goal "Harness: codex")
if out=$(_harness_of "$d/goals/01-thing.md" 2>&1); then
  fail "disabled vendor should hard-stop, got: $out"
else
  rc=$?
  [ "$rc" = 64 ] && pass "disabled vendor returns 64 (no silent claude fallback)" || { fail "disabled rc"; echo "rc=$rc"; }
  case "$out" in *not\ enabled*mega.enabled_agent_clis*) pass "error says 'not enabled' AND names the config key" ;; *) fail "disabled error should name the key mega.enabled_agent_clis"; echo "$out" ;; esac
fi
# claude MUST still work with the feature off -- it is the substrate, never gated.
d=$(mk_goal "Model: opus")
got=$(_harness_of "$d/goals/01-thing.md"); [ "$got" = claude ] && pass "claude works with feature OFF" || { fail "claude gated?!"; echo "got: $got"; }
# Enabling one vendor must NOT enable a sibling: a partial allowlist is honored exactly.
set_harnesses "codex"
d=$(mk_goal "Harness: pi")
_harness_of "$d/goals/01-thing.md" >/dev/null 2>&1 && fail "pi should be blocked when only codex is enabled" || pass "partial allowlist: pi blocked while codex allowed"
d=$(mk_goal "Harness: codex")
[ "$(_harness_of "$d/goals/01-thing.md")" = codex ] && pass "partial allowlist: codex admitted" || fail "codex should be admitted"
set_harnesses "codex pi opencode"   # restore the suite default

echo "== SECURITY: the gate is not self-authorizable from a project .kit.toml (review CRITICAL) =="
# A hostile mega-goal PR could ship a project .kit.toml that enables the vendor it also requests in a
# goal file. The gate must read the KIT-ROOT install config ONLY, never the PR-writable project layer.
# Reproduce the attack: kit-root empty, project .kit.toml enables codex -> must STILL be blocked.
set_harnesses ""                                                    # kit-root: feature OFF
printf '[mega]\nenabled_agent_clis = "codex"\n' > "$TMP/cfgproj/.kit.toml"   # attacker's project override
d=$(mk_goal "Harness: codex")
if _harness_of "$d/goals/01-thing.md" >/dev/null 2>&1; then
  fail "SECURITY: a project .kit.toml self-enabled the vendor (gate bypassed)"
else
  pass "project .kit.toml CANNOT self-enable the vendor (kit-root-only gate)"
fi
# Control: the SAME enablement in the KIT-ROOT config DOES enable it (proves the gate reads kit-root,
# not that it ignores config entirely).
set_harnesses "codex"                                              # kit-root: ON
[ "$(_harness_of "$d/goals/01-thing.md")" = codex ] && pass "kit-root config DOES enable (control)" || fail "kit-root enablement should work"
rm -f "$TMP/cfgproj/.kit.toml"
set_harnesses "codex pi opencode"   # restore

echo "== SECURITY: Effort is charset-validated (no argv / TOML injection, review HIGH) =="
# Effort has no allowlist by design, but reaches an exec as syntax on two paths: codex splices it into
# a TOML string, and the claude path word-splits it into the real argv. Both need a charset gate.
d=$(mk_goal "Harness: codex" 'Effort: high", sandbox_mode="danger-full-access')
_route "$d/goals/01-thing.md" >/dev/null 2>&1 && fail "codex TOML-breakout effort was accepted" || pass "codex TOML-breakout effort rejected"
d=$(mk_goal 'Effort: x --mcp-config /tmp/evil.json')   # claude path, word-split injection
_route "$d/goals/01-thing.md" >/dev/null 2>&1 && fail "claude flag-injection effort was accepted" || pass "claude flag-injection effort rejected"
d=$(mk_goal "Harness: codex" "Model: gpt-5" "Effort: high")   # clean value still passes
[ "$(_route "$d/goals/01-thing.md")" = "$(printf 'gpt-5\thigh')" ] && pass "clean effort still admitted (gate didn't over-reject)" || fail "clean effort should pass"

echo "== tier allowlist is claude-only =="
d=$(mk_goal "Harness: codex" "Model: gpt-5" "Effort: high")
if out=$(_route "$d/goals/01-thing.md" 2>&1); then
  [ "$out" = "$(printf 'gpt-5\thigh')" ] && pass "non-claude model passes through verbatim" \
    || { fail "codex model passthrough"; printf 'got: %q\n' "$out"; }
else
  fail "codex Model: gpt-5 was rejected by the claude allowlist"; echo "got: $out"
fi
# Negative control: the SAME value with no Harness: is still claude, so the gate must still reject.
d=$(mk_goal "Model: gpt-5")
if _route "$d/goals/01-thing.md" >/dev/null 2>&1; then
  fail "negative control: gpt-5 under claude should still be rejected"
else
  pass "negative control: claude allowlist still rejects gpt-5"
fi

echo "== the vendor path really execs the vendor =="
run_vendor() {  # megadir -> rc, via _run_one_session
  local d="$1" pf="$TMP/prompt.txt"
  printf 'PROMPT_BODY_MARKER\n' > "$pf"
  _run_one_session "$d" SG-01 "$pf" "" 0 >/dev/null 2>&1
}

# codex: stdin delivery.
rm -f "$TMP/codex.argv" "$TMP/codex.stdin"
d=$(mk_goal "Harness: codex" "Model: gpt-5" "Effort: high"); run_vendor "$d"; rc=$?
[ "$rc" = 0 ] && pass "codex sub-goal dispatches rc=0" || { fail "codex dispatch rc"; echo "rc=$rc"; }
[ -f "$TMP/codex.argv" ] && pass "the codex binary was actually invoked" || fail "codex never ran"
got=$(tr '\n' ' ' < "$TMP/codex.argv" 2>/dev/null)
[ "$got" = 'exec --model gpt-5 -c model_reasoning_effort="high" -s workspace-write ' ] \
  && pass "codex argv carries model + TOML effort + sandbox flag" || { fail "codex argv"; printf 'got: %q\n' "$got"; }
grep -q PROMPT_BODY_MARKER "$TMP/codex.stdin" 2>/dev/null \
  && pass "codex received the prompt on STDIN" || fail "codex prompt not on stdin"

# opencode: argv delivery. Same prompt, different channel -- this is the pair that would silently
# pass with an empty prompt if the mode were wrong.
rm -f "$TMP/opencode.argv" "$TMP/opencode.stdin"
d=$(mk_goal "Harness: opencode" "Model: anthropic/claude-sonnet-5"); run_vendor "$d"
grep -q PROMPT_BODY_MARKER "$TMP/opencode.argv" 2>/dev/null \
  && pass "opencode received the prompt as an ARGV positional" || { fail "opencode prompt not in argv"; cat "$TMP/opencode.argv" 2>/dev/null; }
[ -s "$TMP/opencode.stdin" ] && fail "opencode stdin should be empty (prompt goes via argv)" \
  || pass "opencode stdin left empty (no double-delivery)"

# pi: argv delivery + its own effort spelling.
rm -f "$TMP/pi.argv"
d=$(mk_goal "Harness: pi" "Model: google/gemini-3-pro" "Effort: high"); run_vendor "$d"
grep -q -- '--thinking' "$TMP/pi.argv" 2>/dev/null \
  && pass "pi effort maps to --thinking, not --effort" || { fail "pi effort flag"; cat "$TMP/pi.argv" 2>/dev/null; }

echo "== SECURITY: argv-mode prompt starting with '-' is delivered, not parsed as a flag (review HIGH) =="
# A prompt whose first char is '-' (e.g. a '---' markdown rule atop POINTER_PROMPT.md) would be read
# as an option by pi/opencode. The delivery must guarantee the positional never starts with '-'. The
# mock records its argv one-token-per-line: line 1 is `run`, then the prompt token. With the leading-
# newline guard the prompt token's first line is EMPTY (the guard newline); without it, it is `---`.
rm -f "$TMP/opencode.argv" "$TMP/opencode.lastarg"
pf="$TMP/dashprompt.txt"; printf -- '---\nreal body PROMPT_BODY_MARKER\n' > "$pf"
d=$(mk_goal "Harness: opencode")
_run_one_session "$d" SG-01 "$pf" "" 0 >/dev/null 2>&1
grep -q PROMPT_BODY_MARKER "$TMP/opencode.lastarg" 2>/dev/null \
  && pass "opencode still received the dash-prefixed body (as the last positional)" || { fail "dash-prefixed prompt lost"; cat "$TMP/opencode.argv"; }
# The raw last positional must NOT start with '-'. With the newline guard its first byte is '\n'.
first=$(head -c1 "$TMP/opencode.lastarg" | od -An -c | tr -d ' ')
[ "$first" = '\n' ] \
  && pass "prompt arg is guarded (first byte is newline; never starts with '-')" \
  || { fail "prompt arg first byte is '$first' not newline -> vendor would parse a leading '-' as a flag"; }

echo "== claude path is untouched (backward compat) =="
# $CLAUDE_CMD is the mock seam every pre-existing test drives. With no Harness: header the vendor
# branch must not be taken at all, so a $CLAUDE_CMD mock still receives the dispatch.
rm -f "$TMP/claudemock.argv"
cat > "$TMP/claudemock" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TMP/claudemock.argv"
cat > /dev/null
exit 0
EOF
chmod +x "$TMP/claudemock"
d=$(mk_goal "Model: fable" "Effort: high")
CLAUDE_CMD="$TMP/claudemock" CLAUDE_FLAGS="" run_vendor "$d"
[ -f "$TMP/claudemock.argv" ] && pass "no Harness: header still routes through \$CLAUDE_CMD" \
  || fail "claude path regressed: \$CLAUDE_CMD mock never invoked"

echo "== observability degrade WARNs rather than blocking dispatch =="
rm -f "$TMP/codex.argv"
d=$(mk_goal "Harness: codex")
pf="$TMP/prompt.txt"; printf 'PROMPT_BODY_MARKER\n' > "$pf"
warn=$(CAPTURE_TOKENS=1 _run_one_session "$d" SG-01 "$pf" "" 0 2>&1 >/dev/null)
case "$warn" in
  *WARN*stream-json*) pass "CAPTURE_TOKENS on a vendor path WARNs" ;;
  *) fail "expected a WARN about no stream-json equivalent"; printf 'got: %s\n' "$warn" ;;
esac
[ -f "$TMP/codex.argv" ] && pass "and still dispatches (advisory, not a wall)" \
  || fail "observability degrade blocked the dispatch"
# All FOUR observability triggers WARN (review LOW: only CAPTURE_TOKENS was covered before). stream is
# the 5th positional; the other three are env globals.
warn=$(_run_one_session "$d" SG-01 "$pf" "" 1 2>&1 >/dev/null)                 # stream=1
case "$warn" in *WARN*stream-json*) pass "stream=1 WARNs" ;; *) fail "stream=1 should WARN"; echo "$warn" ;; esac
warn=$(DETERMINISTIC_HANDOFF=1 _run_one_session "$d" SG-01 "$pf" "" 0 2>&1 >/dev/null)
case "$warn" in *WARN*stream-json*) pass "DETERMINISTIC_HANDOFF=1 WARNs" ;; *) fail "DETERMINISTIC_HANDOFF should WARN"; echo "$warn" ;; esac
warn=$(WATCHDOG_STALL_SECS=30 _run_one_session "$d" SG-01 "$pf" "" 0 2>&1 >/dev/null)
case "$warn" in *WARN*watchdog*|*WARN*stream-json*) pass "WATCHDOG_STALL_SECS>0 WARNs (vendor path is watchdog-exempt)" ;; *) fail "WATCHDOG_STALL_SECS should WARN"; echo "$warn" ;; esac

echo "== END-TO-END: cmd_run drives a vendor sub-goal to grounded completion (review HIGH) =="
# The strongest test: run the REAL orchestrator (`orchestrate.sh run`), not a sourced helper, with a
# mock codex that flips its ROADMAP box the way a real agent would. Proves the whole wired path:
# harness gate -> vendor dispatch -> grounded completion (box-flip advance). Mirrors the fixture
# pattern in test-orchestrate-hardening.sh. Serial run (WAVE_CAP unset -> 1), so no git/worktree.
ORCH="$KIT/lib/queue/orchestrate.sh"
mk_mega() {  # roadmap-checkbox-char -> echoes megadir
  local dir; dir=$(mktemp -d "$TMP/e2e.XXXXXX"); mkdir -p "$dir/goals"
  printf '# e2e\n\n- [%s] SG-01 vendor probe , auto\n' "$1" > "$dir/ROADMAP.md"
  printf 'run one sub-goal.\n' > "$dir/POINTER_PROMPT.md"
  printf 'Harness: codex\nModel: gpt-5\nEffort: high\n\n**Branch:** chore/e2e\n\n## Task\nflip the box.\n' > "$dir/goals/01-probe.md"
  printf '%s\n' "$dir"
}
# A codex mock that does the agent's job: flip SG-01's box in the megadir ROADMAP it is told about.
codex_flip="$TMP/bin-e2e"; mkdir -p "$codex_flip"
cat > "$codex_flip/codex" <<EOF
#!/usr/bin/env bash
cat >/dev/null   # drain the stdin prompt
sed -i.bak 's/- \[ \] SG-01/- [x] SG-01/' "\$MOCK_ROADMAP" 2>/dev/null || \
  { tmp=\$(mktemp); sed 's/- \[ \] SG-01/- [x] SG-01/' "\$MOCK_ROADMAP" > "\$tmp"; mv "\$tmp" "\$MOCK_ROADMAP"; }
exit 0
EOF
chmod +x "$codex_flip/codex"

# ON: feature enabled at kit-root -> dispatches to codex -> box flips -> advance.
set_harnesses "codex"
meg=$(mk_mega " ")
out=$(cd "$meg" && MOCK_ROADMAP="$meg/ROADMAP.md" TIER4_CLOSE=0 PATH="$codex_flip:$PATH" \
      KIT_CONFIG_ROOT="$TMP/cfgroot" KIT_PROJECT_ROOT="$TMP/cfgproj" \
      timeout 60 bash "$ORCH" run "$meg" 2>&1)
grep -q '\[x\] SG-01' "$meg/ROADMAP.md" && pass "e2e ON: vendor sub-goal reached grounded completion (box flipped)" \
  || { fail "e2e ON: box not flipped"; printf '%s\n' "$out" | tail -4; }
case "$out" in *"harness: codex"*) pass "e2e ON: dispatch log names the codex harness" ;; *) fail "e2e ON: log should name codex"; printf '%s\n' "$out" | tail -4 ;; esac
case "$out" in *complete*|*"all sub-goals"*) pass "e2e ON: run advanced/completed" ;; *) fail "e2e ON: no advance"; printf '%s\n' "$out" | tail -4 ;; esac

# OFF: feature disabled at kit-root -> pre-flight STOP -> box stays unchecked, generic routing STOP.
set_harnesses ""
meg=$(mk_mega " ")
out=$(cd "$meg" && MOCK_ROADMAP="$meg/ROADMAP.md" TIER4_CLOSE=0 PATH="$codex_flip:$PATH" \
      KIT_CONFIG_ROOT="$TMP/cfgroot" KIT_PROJECT_ROOT="$TMP/cfgproj" \
      timeout 60 bash "$ORCH" run "$meg" 2>&1)
grep -q '\[ \] SG-01' "$meg/ROADMAP.md" && pass "e2e OFF: box stays unchecked (blocked, no dispatch)" \
  || { fail "e2e OFF: box was flipped despite disabled gate!"; printf '%s\n' "$out" | tail -4; }
case "$out" in *"rejected pre-flight by routing"*) pass "e2e OFF: generic routing STOP (not the old 'invalid Model tier' lie)" ;; *) fail "e2e OFF: missing routing STOP"; printf '%s\n' "$out" | tail -4 ;; esac
set_harnesses "codex pi opencode"

echo
[ "$fails" = 0 ] && { echo "all green"; exit 0; } || { echo "$fails FAILED"; exit 1; }
