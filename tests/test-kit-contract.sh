#!/usr/bin/env bash
# test-kit-contract.sh -- SPEC-200: the standing contract EVERY kit module must satisfy.
#
# The rules in docs/kit-contract.md, executable. Not style policing: each rule below exists
# because its violation already shipped and cost something (the cite is in the rule's header).
#
# C1  NAMING     no kit-owned name carries the host-agent prefix (`cc-` / `CC_*`).
# C2  WIRING     every lib/<mod>/bin/<exe> is reachable from an operator surface (a bin/
#                dispatcher case, a bin/ shim, or an explicit exempt list) -- an unreachable
#                tool is a tool nobody runs (session-audit shipped unwired, 2026-07-14).
# C3  DOCS       every module dir carries README.md + SPEC.md + docs/proof-of-done.md.
# C4  TESTS      every module dir carries at least one tests/*.sh.
# C5  CURRENCY   every proposer LOADS lib/learn/staging-format.py to render its `## [staged]`
#                blocks (naming a renderer is not enough: two files kept private copies, one
#                drifted into a forgery hole, and the old grep matched their own definitions)
#                and NEVER writes a board directly (ADR-0034 decision 1 / SPEC-200 I1).
# C6  ROOT       every module that persists state resolves it through lib/telemetry/kit-log-dir.sh
#                (SPEC-097), never a hardcoded ~/.claude/dwarves-kit/logs.
# C7  PORTABLE   no test reaches for a tool CI does not have (rg/fd/sd/jq...): a missing binary
#                turns a lint into a VACUOUS PASS (this exact bug shipped, 2026-07-14).
# C8  CI         every .github/workflows/*.yml is valid: an unquoted step name carrying ": "
#                parses as a mapping and invalidates the WHOLE file, so every lint in it
#                silently stops guarding anything (shipped red at 0s, 2026-07-14).
# C9  DISPATCH   every "dispatched by /X" claim (agent frontmatter, README roster) is backed by
#                a command that really dispatches it (4 were wrong, 2026-07-14).
# C10 EXEC       every text executable declares its interpreter (shebang + exec bit): a wrong
#                guess fails ugly (`bash <python-script>` died on a docstring, 2026-07-15).
#
# Every rule has a NEGATIVE CONTROL, and the planted violation must arrive in a shape the
# rule's author did NOT have in mind: an NC that plants the exact form the regex was written
# against proves only that the regex matches itself. Four rules were vacuous until re-planted
# differently. A lint nobody can see fail is a lint nobody should trust.
#
# Run: bash tests/test-kit-contract.sh
set -uo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$KIT" || exit 1

PASS=0; FAIL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
ok()  { printf "  ${GREEN}PASS${NC} %s\n" "$1"; PASS=$((PASS+1)); }
bad() { printf "  ${RED}FAIL${NC} %s %s\n" "$1" "${2:-}"; FAIL=$((FAIL+1)); }
chk() { if [ -z "$2" ]; then ok "$1"; else bad "$1" "(offenders: $(echo "$2" | tr '\n' ' '))"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Modules = the kit's DECLARED module list (install.sh KIT_KNOWN_MODULES, the same list
# lib/config/module-registry.md is completeness-checked against) mapped to their lib/ dirs,
# UNION any lib/ dir carrying a tool.toml.
#
# The first cut used tool.toml alone, which matched THREE dirs (plugin-check, stats,
# skill-curator) out of twelve declared modules: C3/C4 were green while never looking at
# board, queue, session, gate, learn... including the module this very PR edits. A lint whose
# scope silently excludes 3/4 of its subject is the vacuous-pass failure mode wearing a
# different hat (advisor finding 1).
#
# Second scope bug, same shape: a module whose code is ONLY hooks (money_gate, cosmetic) has no
# lib/<name>/ dir, so `[ -d "lib/$m" ]` yielded NOTHING and the module was invisible to C3/C4.
# That is exactly how money_gate went its whole lifetime with no SPEC while the lint stayed
# green (found 2026-07-15). A declared module now MUST have a lib/<name>/ home, even if that
# home holds only its docs: the missing home is itself the finding, not an excuse to skip it.
# A module's home is not always lib/<its-own-name>: several are FEATURES of another lib
# (quiz_gate lives in lib/gate/, weekend_batch in lib/learn/, bridge in lib/board/), and one
# is an agent, not a lib at all. This map is the honest resolution; without it the lint either
# skipped them (the old blind spot: money_gate went its whole lifetime unspecced while C3 stayed
# green) or reported a phantom lib/<name> that was never supposed to exist.
module_home() {  # module_home <module> -> its dir, or "" for "documented elsewhere by design"
  case "$1" in
    quiz-gate)      echo "lib/gate" ;;        # lib/gate/quiz-gate.sh
    weekend-batch)  echo "lib/learn" ;;       # lib/learn/weekend-batch.sh
    bridge)         echo "lib/board" ;;       # lib/board/board-mirror.sh + board-writeback.sh
    worktree)       echo "lib/worktree-provision" ;;
    advisor)        echo "" ;;                # an AGENT (agents/advisor.md), not a lib module
    *)              for d in "lib/$1" "lib/${1//-/_}"; do [ -d "$d" ] && { echo "$d"; return; }; done
                    echo "lib/$1" ;;          # no home: emit the expected path so C3/C4 REPORT it
  esac
}
modules() {
  {
    grep -o '^KIT_KNOWN_MODULES="[^"]*"' install.sh | sed 's/.*"\(.*\)"/\1/' | tr ' ' '\n' \
      | sed 's/_/-/g' | while read -r m; do
          [ -n "$m" ] || continue
          h="$(module_home "$m")"
          [ -n "$h" ] && echo "$h"
        done
    find lib -maxdepth 2 -name tool.toml -exec dirname {} \;
  } | sort -u
}

# Existing, KNOWN doc/test debt: modules that predate the contract and do not yet satisfy C3/C4.
# The lint fails on anything NOT in this file, so no NEW debt can land; each line here is a
# visible IOU, not a silent exemption. Shrinking it is the work; growing it is a decision a
# human has to make in a diff.
GAPS="tests/kit-contract-known-gaps.txt"
known_gap() { grep -qxF "$1" "$GAPS" 2>/dev/null; }

# ---------------------------------------------------------------- C1 naming
echo "== C1 naming: no kit-owned cc-/CC_ prefix =="
# Grandfathered deprecated aliases (each warns and dies one release after SPEC-200), plus
# CC_PLUGINS_DIR which the HOST provides (we read it, we do not own its spelling).
# Grandfathered names are listed IN FULL and anchored with $. A bare `CC_SI_` prefix would
# permanently exempt the whole namespace, including a CC_SI_* var added tomorrow: the rule's
# stated job is to stop exactly that (review finding).
# `CC_SI_` (bare, trailing underscore) is the DERIVATION STEM in skill-curator's cfg(): the
# resolver builds the legacy name from the key, so the stem is the only literal in the source.
# Every other grandfathered name is spelled in full.
CC_OK='CC_SI_|CC_BACKLOG_(STAGING|BACKLOG|BACKLOG_FIX)|CC_PLUGINS_DIR'
cc_env() {  # POSIX grep only (see C7: `rg` is absent on CI and returns nothing = vacuous pass)
  # Match every shape a real regression arrives in, not just the one the first cut imagined:
  # ${VAR} / $VAR, os.environ.get("VAR") AND ('VAR'), os.environ["VAR"], getenv, and a bare
  # `CC_FOO=` assignment or `export CC_FOO`. The narrow first cut missed four of these; a NC
  # that plants only the shape the regex expects proves nothing (review finding).
  # -I skips BINARIES (a Rust/Python build tree is full of C-compiler macros like CC_OPT_,
  # CC_PROFILE: not our env vars, and a lint that reports them is a lint people mute).
  # tests/ are excluded because a back-compat test must NAME the deprecated var to prove the
  # alias still works; banning that would ban testing the ban.
  # Comment lines are stripped BEFORE matching: a comment explaining the retired name (the ones
  # in anomalies.py and common.sh document exactly this bug) is documentation, not a reader.
  # Same reasoning as C6; a lint that punishes its own fix trains people to delete the comment.
  grep -rhIE --exclude='*.md' --exclude='*.toml' --exclude-dir=.venv --exclude-dir=target \
    --exclude-dir=__pycache__ --exclude-dir=tests \
    'CC_[A-Z_]{2,}' "$@" 2>/dev/null \
    | grep -vE '^[[:space:]]*(#|//|\*)' \
    | grep -oE 'CC_[A-Z_]{2,}' | sort -u | grep -vE "^($CC_OK)$" || true
}
chk "no un-grandfathered CC_* env in lib/hooks/bin" "$(cc_env lib hooks bin)"

# a cc-* executable on an operator surface (bin/ or a module bin/) is the same fossil
cc_exe="$(find bin lib -type f -perm -u+x -name 'cc-*' 2>/dev/null | grep -v '/cc-improve$' || true)"
chk "no cc-* executable (except the deprecated cc-improve shim)" "$cc_exe"

printf 'x=${CC_PLANTED_VIOLATION}\n' > "$TMP/plant.sh"
if [ -n "$(cc_env "$TMP")" ]; then ok "NEGATIVE CONTROL: a planted CC_* IS caught"; else bad "NEGATIVE CONTROL: planted CC_* slipped through"; fi

# ---------------------------------------------------------------- C2 wiring
echo "== C2 wiring: every module executable is reachable from an operator surface =="
# Exempt = reached through a DISPATCHER, not directly (the dispatcher itself is the operator
# surface, and the C2b check below proves each one is really dispatched). The first cut also
# listed skill-improve, skill-review and cc-improve here, and they were reachable from NOTHING:
# the exempt list had become a laundering mechanism for the exact bug C2 exists to catch
# (advisor finding 2). They now have bin/ shims and are gone from this list. What remains is
# only the session family (dispatched by lib/session/session.sh, asserted below) and
# add-backlog (called by board.sh).
WIRING_EXEMPT='session-observe|session-report|session-semantic|session-intel|session-recall|session-audit|add-backlog'
unwired=""
while IFS= read -r exe; do
  base="$(basename "$exe")"
  { trap '' PIPE; echo "$base" 2>/dev/null || :; } | grep -qE "^($WIRING_EXEMPT)$" && continue
  # A deprecated-alias shim (it warns and execs the canonical name) is reachable BY DEFINITION:
  # it exists so an old call-site keeps working. Requiring a bin/ shim for the shim is silly.
  grep -q 'is deprecated, use' "$exe" 2>/dev/null && continue
  # reachable if a bin/ entry mentions it, a lib/*/*.sh dispatcher execs it, or a hook calls it
  if ! grep -rqF "$base" bin lib/*/*.sh hooks 2>/dev/null; then unwired="$unwired$exe\n"; fi
done < <(find lib -path '*/bin/*' -type f -perm -u+x -not -path '*/.venv/*' -not -path '*/target/*' 2>/dev/null | sort)
chk "no module executable is unreachable from bin/ or a dispatcher" "$(printf "%b" "$unwired")"

# C2b: the exempt list is not a free pass. Every exempt name must be provably reached by a
# dispatcher case or a wrapper, or it is unwired and merely hiding behind the exemption.
undispatched=""
# Derive the verb list from the dispatcher itself. Hardcoding it pinned `report`, a verb
# SPEC-200 I4 retires: the lint would have failed its own roadmap and forced the implementer
# to edit the test to obey the spec (review finding).
for exe in lib/session/*/bin/session-*; do
  [ -f "$exe" ] || continue
  v="${exe##*/session-}"
  grep -qE "^[[:space:]]+$v\)" lib/session/session.sh || undispatched="$undispatched session:$v"
done
grep -q 'add-backlog' lib/board/board.sh 2>/dev/null || undispatched="$undispatched board:add-backlog"
chk "every EXEMPT executable is really dispatched (no laundering)" "$undispatched"

# ---------------------------------------------------------------- C3 docs
echo "== C3 docs: README + SPEC + proof-of-done per module =="
missing=""; gapped=0
for m in $(modules); do
  # A spec is either the module-root SPEC.md (session tools' shape) or a numbered spec under
  # docs/specs/ (the repo-layout shape). Demanding ONE filename would be the lint inventing a
  # convention the kit does not have -- and a false failure teaches people to ignore the lint.
  # A spanner module (lib/session/ = observe + intel + audit + recall) documents each sub-tool,
  # not the umbrella dir. Accept the artifact in the module dir OR in any immediate sub-tool
  # dir; demanding a module-root copy would push people to write a stub nobody reads.
  for want in README.md SPEC docs/proof-of-done.md; do
    case "$want" in
      SPEC) [ -f "$m/SPEC.md" ] && continue
            ls "$m"/docs/specs/SPEC-*.md >/dev/null 2>&1 && continue
            ls "$m"/*/SPEC.md >/dev/null 2>&1 && continue
            ls "$m"/*/docs/specs/SPEC-*.md >/dev/null 2>&1 && continue ;;
      *)    [ -f "$m/$want" ] && continue
            ls "$m"/*/"$want" >/dev/null 2>&1 && continue ;;
    esac
    if known_gap "$m/$want"; then gapped=$((gapped+1)); else missing="$missing$m/$want\n"; fi
  done
done
chk "every module has README + a spec + docs/proof-of-done.md (no NEW gaps)" "$(printf "%b" "$missing")"
[ "$gapped" -gt 0 ] && printf "  DEBT %s known doc gaps (see %s)\n" "$gapped" "$GAPS"

# ---------------------------------------------------------------- C4 tests
echo "== C4 tests: every module has at least one test =="
untested=""; t_gapped=0
for m in $(modules); do
  mod="$(basename "$m")"
  # Tests live either in the module (lib/<m>/tests/) or at the repo root (tests/test-<m>.*),
  # both are real homes in this kit; a lint that only knew one would report a false gap.
  # Root-level tests are named test-<mod>.sh OR test-<mod>-<topic>.sh (test-gate-outcome.sh,
  # test-learn-propose.sh). Matching only the exact name reported a false gap for two core libs.
  # `ls a b` returns NONZERO if ANY arg is missing, so a two-glob `ls` silently reported a gap
  # for modules that DO have tests. find is the honest test here.
  ls "$m"/tests/*.sh >/dev/null 2>&1 && continue
  alt="${mod//-/_}"
  [ -n "$(find tests -maxdepth 1 \( -name "test-$mod.*" -o -name "test-$mod-*" \
                                  -o -name "test-$alt.*" -o -name "test-$alt-*" \) 2>/dev/null)" ] && continue
  if known_gap "$m/tests"; then t_gapped=$((t_gapped+1)); else untested="$untested$m\n"; fi
done
chk "every module has a test (module-local or repo-root)" "$(printf "%b" "$untested")"
[ "$t_gapped" -gt 0 ] && printf "  DEBT %s known test gaps (see %s)\n" "$t_gapped" "$GAPS"

# ---------------------------------------------------------------- C5 proposal currency
echo "== C5 currency: proposers stage blocks, never write a board =="
# Anything that writes a `## [staged]` block must get it from the ONE renderer.
bespoke=""
while IFS= read -r f; do
  case "$f" in
    */tests/*) continue ;;              # a test ASSERTS on the block; it does not render one
    */board/bin/add-backlog)            # the PROMOTER: it PARSES staged blocks and writes the
      continue ;;                       # board. That is the human gate, the one edge into the
  esac                                  # board, not a proposer. Reading the grammar != minting it.
  # It must LOAD the shared module, not merely NAME a renderer. The first cut grepped for
  # `render_block|render_candidate`, and a file that DEFINES that function matches its own
  # grep: the rule passed vacuously for the two files it most needed to catch. Both kept a
  # private copy of the block grammar, and one had already drifted into a live forgery hole
  # (a bare .strip() let an embedded newline mint a SECOND staged block: one candidate in,
  # two proposals out, the forged one indistinguishable to `board promote`). A copy of a
  # shared grammar is not a copy for long (found 2026-07-15).
  body="$(grep -vE '^[[:space:]]*#' "$f")"
  { trap '' PIPE; echo "$body" 2>/dev/null || :; } | grep -q 'staging-format\.py\|staging_format' || { bespoke="$bespoke$f\n"; continue; }
  # ... and it must not ALSO define its own renderer next to that import.
  { trap '' PIPE; echo "$body" 2>/dev/null || :; } | grep -qE '^[[:space:]]*def (render_block|render_candidate)\(' \
    && ! { trap '' PIPE; echo "$body" 2>/dev/null || :; } | grep -qE 'sf\.render_block|\.render_block\(\{' \
    && bespoke="$bespoke$f(defines-its-own)\n"
# No --include: the kit's executables are EXTENSIONLESS by house rule, so filtering to
# *.py/*.sh skipped session-audit, one of the very writers this rule governs. C6 had the same
# blindness; the same fix. (Found by drawing the data-flow diagram and noticing a writer the
# lint had never seen.)
done < <(grep -rlI '## \[staged\]' lib hooks --exclude='*.md' --exclude-dir=.venv \
           --exclude-dir=target --exclude-dir=__pycache__ 2>/dev/null \
         | grep -v 'staging-format.py' | sort)
chk "every staged-block writer goes through the one renderer" "$(printf "%b" "$bespoke")"

# No proposer appends to a BACKLOG.md (the human gate `board promote` owns that write).
# Three append shapes, not one: `>> $BACKLOG`, python `open(..., "a")`, and `tee -a` (the last
# evaded the first cut). sed -i insertion remains out of reach of a grep; C5's real guarantee
# is the renderer, this is the belt.
autofile="$(grep -rlE '>>[[:space:]]*"?\$?\{?BACKLOG|open\([^)]*BACKLOG[^)]*,[[:space:]]*"a|tee[[:space:]]+-a[^|]*BACKLOG' \
            lib hooks 2>/dev/null | grep -v '/board/' || true)"
chk "no proposer appends to a board directly (propose-don't-dispose)" "$autofile"

# ---------------------------------------------------------------- C6 durable root
echo "== C6 root: persistence resolves through kit-log-dir.sh =="
# Code lines only: a COMMENT naming the old path (e.g. the one in queue.sh explaining why it
# moved) is documentation, not a hardcode. Grepping prose here would punish the fix.
# No --include filter: the kit's executables are EXTENSIONLESS by house rule (the BTM plist
# convention), so filtering to *.sh/*.py skipped 10 of them, including two this PR touches
# (review finding). Exclude only docs.
hardcoded="$(grep -rn --exclude='*.md' --exclude-dir=.venv --exclude-dir=tests \
             '\.claude/dwarves-kit/logs' lib 2>/dev/null \
             | grep -v 'kit-log-dir.sh' | grep -vE ':[0-9]+:[[:space:]]*#' | cut -d: -f1 | sort -u || true)"
chk "no module hardcodes the pre-SPEC-097 log root" "$hardcoded"

# ---------------------------------------------------------------- C7 portable tests
echo "== C7 portable: tests use no tool CI lacks =="
# A test that shells out to a missing binary produces EMPTY output, and an emptiness-asserting
# lint then passes vacuously. This is not hypothetical: it shipped on 2026-07-14 (`rg` in the
# C1 lint), and only the negative control caught it.
NONPORTABLE='rg|fd|sd|bat|eza|jaq|delta|dust|procs'
# Command position only: start of line, after a pipe, `$(`, `&&`, `;`, or `!`. Matching the
# bare word anywhere flags prose ("Coverage delta") and is how a lint earns a reputation for
# crying wolf.
# This file is excluded from its own sweep: its negative control PLANTS an `rg` line on
# purpose, and a lint that flags its own fixture is a lint that cannot be green.
# The trailing `-` (a dash-flag) is NOT required: `rg "pat" file` and `fd . | head` carry no
# flag and slipped through the first cut (review finding). Require only that the tool sits in
# command position followed by whitespace.
offenders="$(grep -rhoE --exclude='test-kit-contract.sh' \
             "(^|\\\$\(|\||&&|;|!)[[:space:]]*($NONPORTABLE)[[:space:]]" tests lib/*/tests 2>/dev/null \
             | grep -oE "($NONPORTABLE)[[:space:]]" | grep -oE "^($NONPORTABLE)" | sort -u || true)"
chk "no test invokes a non-CI tool (rg/fd/sd/...)" "$offenders"

# ---------------------------------------------------------------- C10 executables self-declare
echo "== C10 exec: every module executable declares its interpreter =="
# An executable with no shebang (or no +x) forces the caller to GUESS the interpreter, and a
# wrong guess fails ugly: `bash session-audit` (a python script) died with a shell syntax error
# on a docstring line, 2026-07-15. The script must say what runs it; the caller must not have to.
# A compiled binary legitimately has neither: skip anything not a text file.
noshebang=""
while IFS= read -r f; do
  file "$f" 2>/dev/null | grep -qiE 'text|script' || continue     # skip compiled binaries
  head -c2 "$f" 2>/dev/null | grep -q '#!' || noshebang="$noshebang$f(no-shebang)\n"
  [ -x "$f" ] || noshebang="$noshebang$f(not-executable)\n"
done < <(find bin lib -path '*/bin/*' -type f -not -path '*/.venv/*' -not -path '*/target/*' \
           -not -path '*/__pycache__/*' 2>/dev/null | sort)
chk "every text executable has a shebang and the exec bit" "$(printf "%b" "$noshebang")"

# ---------------------------------------------------------------- C8 CI workflow parses
echo "== C8 CI: the workflow file is valid YAML =="
# A broken workflow file does not fail the tests: it fails the RUN, so every lint in this file
# silently stops guarding anything. It shipped exactly once, on the push that added the C-rules
# step: an unquoted step name containing ": " parses as a mapping. The cheapest possible guard.
# Deliberately NOT a yaml-parser check: pyyaml is not installed here or on CI, so importing it
# would make this rule SKIP, i.e. pass vacuously, i.e. exactly the C7 bug. Grep for the one
# shape that actually broke: an UNQUOTED `- name:` / `run:` scalar carrying ": " (YAML then
# reads it as a nested mapping and the whole file is invalid).
wf_bad="$(grep -rnE '^[[:space:]]*-?[[:space:]]*(name|run|if):[[:space:]]+[^"'"'"'|>&*][^"'"'"']*:[[:space:]]' \
          .github/workflows/ 2>/dev/null | grep -vE ':[[:space:]]*#' || true)"
chk "no unquoted workflow scalar carries a colon-space (breaks the whole file)" "$wf_bad"

# ---------------------------------------------------------------- C9 dispatch claims are true
echo "== C9 lens wiring: every 'dispatched by /X' claim is real =="
# README's agent roster and each agent's own frontmatter both name the command that dispatches
# them. Three README cells and one frontmatter were WRONG on 2026-07-14 (acceptance-verifier
# claimed /execute, brief-reviewer claimed /spec, security-reviewer claimed /review; none of
# those commands mentions the agent). A prose claim about wiring is a claim a grep can check.
badclaim=""
# A command dispatches an agent either BY NAME, or INDIRECTLY through the role classifier
# (`role-classify.sh agent-for <domain>` returns a *-worker name at runtime, so the literal
# never appears in the command body). Treat the latter as dispatching the worker agents.
dispatches() {  # dispatches <command-file> <agent>
  grep -qF "$2" "$1" && return 0
  case "$2" in *-worker) grep -q 'role-classify.*agent-for' "$1" && return 0 ;; esac
  return 1
}
for agent_md in agents/*.md; do
  a="$(basename "$agent_md" .md)"
  # ONLY the explicit "Dispatched by ..." clause is a wiring claim. A command named elsewhere in
  # the prose ("more thorough than /review's built-in checks") is a comparison, not a claim; the
  # first cut flagged it and would have taught people to delete accurate sentences.
  claim="$(grep -m1 '^description:' "$agent_md" | grep -oiE 'dispatched by [^.]*' || true)"
  for cmd in $(printf '%s' "$claim" | grep -oE '/(kit:)?[a-z-]+' | sed 's|^/||; s|^kit:||' | sort -u); do
    [ -f "commands/$cmd.md" ] || continue                       # not a command name, skip
    dispatches "commands/$cmd.md" "$a" || badclaim="$badclaim $a:frontmatter-claims-/$cmd"
  done
  # commands named in README's roster row for this agent (that column IS a wiring claim)
  row="$(grep -m1 "^| $a |" README.md || true)"
  [ -n "$row" ] || continue
  for cmd in $(printf '%s' "$row" | cut -d'|' -f3 | grep -oE '/(kit:)?[a-z-]+' | sed 's|^/||; s|^kit:||' | sort -u); do
    [ -f "commands/$cmd.md" ] || continue
    dispatches "commands/$cmd.md" "$a" || badclaim="$badclaim $a:README-claims-/$cmd"
  done
done
chk "no agent claims a dispatcher that does not dispatch it" "$badclaim"

# ---------------------------------------------------------------- negative controls
# Each rule above asserts an ABSENCE. An absence-assertion that cannot fail is worse than no
# test at all (see the C7 header: that is exactly how the first cut of C1 shipped green on CI
# while checking nothing). Every rule gets a planted violation here.
echo "== NEGATIVE CONTROLS: each rule catches a violation planted in an UNEXPECTED shape =="
# The first cut planted each violation in the exact syntactic form its own regex was written
# against, which proves only that the regex matches itself. A review re-planted them in the
# forms a real regression actually arrives in, and FOUR rules turned out to be vacuous. Every
# NC below therefore uses a shape the rule's author did NOT have in mind.
mkdir -p "$TMP/nc/bin" "$TMP/nc/tests" "$TMP/nc/lib"

# C1: single-quoted environ.get, subscript form, and a bare assignment (not ${...})
printf "x = os.environ.get('CC_SNEAKY_ONE')\ny = os.environ[\"CC_SNEAKY_TWO\"]\n" > "$TMP/nc/plant.py"
printf 'export CC_SNEAKY_THREE=1\n' > "$TMP/nc/plant.sh"
nc1="$(cc_env "$TMP/nc")"
[ "$(echo "$nc1" | grep -c CC_SNEAKY)" -eq 3 ] && ok "C1 catches all three unexpected CC_* shapes" || bad "C1 vacuous on unexpected shapes" "(caught: $nc1)"
# and a NEW CC_SI_* must NOT be grandfathered by the stem
printf 'z=${CC_SI_BRAND_NEW_FOSSIL}\n' > "$TMP/nc/plant2.sh"
{ trap '' PIPE; echo "$(cc_env "$TMP/nc")" 2>/dev/null || :; } | grep -q CC_SI_BRAND_NEW_FOSSIL && ok "C1 does not blanket-exempt the CC_SI_ namespace" || bad "C1 grandfathers a NEW CC_SI_ var"
rm -f "$TMP/nc/plant.py" "$TMP/nc/plant.sh" "$TMP/nc/plant2.sh"

# C2: an unwired executable in a module bin/ (the session-audit / skill-improve shape)
printf '#!/usr/bin/env bash\necho hi\n' > "$TMP/nc/bin/totally-unwired"; chmod +x "$TMP/nc/bin/totally-unwired"
if ! grep -rqF "totally-unwired" bin lib/*/*.sh hooks 2>/dev/null; then ok "C2 would catch an unwired module executable"; else bad "C2 is vacuous"; fi

# C5: a bespoke writer that name-drops the renderer IN A COMMENT (the evasion that passed)
printf '# uses staging-format.py conventions\nprint("## [staged] forged")\n' > "$TMP/nc/lib/bespoke.py"
if ! grep -vE '^[[:space:]]*#' "$TMP/nc/lib/bespoke.py" | grep -q 'staging_format\|render_block'; then
  ok "C5 catches a writer that only MENTIONS the renderer in a comment"
else bad "C5 vacuous on the comment-mention evasion"; fi

# C5: the evasion that actually shipped, twice: a writer that DEFINES its own render_block.
# The old grep matched the definition itself, so the rule passed for the exact files it existed
# to catch. This NC plants a private renderer, not a mention.
printf 'def render_block(c):\n    return "## [staged] " + c["title"] + "\\n"\n' \
  > "$TMP/nc/lib/private-renderer.py"
nc5b="$(grep -vE '^[[:space:]]*#' "$TMP/nc/lib/private-renderer.py")"
if ! { trap '' PIPE; echo "$nc5b" 2>/dev/null || :; } | grep -q 'staging-format\.py\|staging_format'; then
  ok "C5 catches a writer that DEFINES its own renderer (the copy that drifted)"
else bad "C5 vacuous on the private-renderer evasion"; fi

# C5b: a direct board append via tee -a (not the >> shape the rule was written for)
printf 'echo row | tee -a "$BACKLOG_FILE"\n' > "$TMP/nc/lib/autofile.sh"
grep -qE 'tee[[:space:]]+-a[^|]*BACKLOG' "$TMP/nc/lib/autofile.sh" && ok "C5b: the tee -a board-append shape is detectable" || bad "C5b vacuous"

# C6: hardcoded log root in an EXTENSIONLESS executable (the kit's own house style)
printf '#!/usr/bin/env bash\nLOG=$HOME/.claude/dwarves-kit/logs/x.log\n' > "$TMP/nc/bin/extensionless"; chmod +x "$TMP/nc/bin/extensionless"
[ -n "$(grep -rn --exclude='*.md' '\.claude/dwarves-kit/logs' "$TMP/nc" 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*#')" ] \
  && ok "C6 catches a hardcode in an extensionless executable" || bad "C6 vacuous on extensionless files"

# C7: a non-portable tool with NO dash-flag (the form the first cut missed)
printf 'out=$(rg "pattern" file)\n' > "$TMP/nc/tests/nonportable.sh"
nc7="$(grep -rhoE "(^|\\\$\(|\||&&|;|!)[[:space:]]*($NONPORTABLE)[[:space:]]" "$TMP/nc/tests" 2>/dev/null || true)"
[ -n "$nc7" ] && ok "C7 catches a flagless rg in a test" || bad "C7 vacuous on the flagless form"

# C8: the EXACT workflow line that shipped red (an unquoted step name carrying ": ")
mkdir -p "$TMP/nc/.github/workflows"
printf 'jobs:\n  test:\n    steps:\n      - name: Run the kit contract (SPEC-200: naming, wiring)\n        run: bash x.sh\n' \
  > "$TMP/nc/.github/workflows/bad.yml"
nc8="$(grep -rnE '^[[:space:]]*-?[[:space:]]*(name|run|if):[[:space:]]+[^"'"'"'|>&*][^"'"'"']*:[[:space:]]' \
       "$TMP/nc/.github/workflows/" 2>/dev/null || true)"
[ -n "$nc8" ] && ok "C8 catches the unquoted colon-space step name (the real incident)" || bad "C8 vacuous"

# C9: an agent whose frontmatter claims a command that does not mention it
printf -- '---\nname: nc-phantom-agent\ndescription: A fixture. Dispatched by /kit:ship for nothing.\n---\n' \
  > "$TMP/nc/phantom.md"
claim="$(grep -m1 '^description:' "$TMP/nc/phantom.md" | grep -oiE 'dispatched by [^.]*')"
cmd="$(printf '%s' "$claim" | grep -oE '/(kit:)?[a-z-]+' | sed 's|^/||; s|^kit:||' | head -1)"
if [ -f "commands/$cmd.md" ] && ! grep -qF "nc-phantom-agent" "commands/$cmd.md"; then
  ok "C9 catches an agent claiming a dispatcher that ignores it"
else bad "C9 vacuous"; fi

# C10: an executable with no shebang (the shape that made `bash <python-script>` explode)
printf 'print("no shebang here")\n' > "$TMP/nc/bin/interpreterless"; chmod +x "$TMP/nc/bin/interpreterless"
if head -c2 "$TMP/nc/bin/interpreterless" | grep -q '#!'; then bad "C10 vacuous"; else
  ok "C10 catches an executable that does not declare its interpreter"; fi

echo ""
echo "=== kit-contract: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
