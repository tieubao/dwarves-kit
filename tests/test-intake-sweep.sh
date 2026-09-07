#!/usr/bin/env bash
# test-intake-sweep.sh -- hooks/intake-sweep.py: the deferred-link sources -> staging
# funnel adapter (jsonl + command kinds), its three dedup layers, the config gate, the
# throttle, and the backlog-stage.sh --surface wiring. Hermetic: every run points
# REPO_ROOT + INTAKE_SWEEP_STATE_DIR at temp dirs; no model call anywhere.
set -uo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SWEEP="$KIT_DIR/hooks/intake-sweep.py"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1" >&2; FAIL=$((FAIL+1)); }
assert_true() { if [ "$2" = "0" ]; then ok "$1"; else bad "$1"; fi; }

mkrepo() { # fresh consumer repo + state dir; echoes the repo root
  local r; r="$(mktemp -d)"
  mkdir -p "$r/_meta" "$r/state"
  echo "$r"
}

# --- fixture repo: jsonl source with keep/skip/dup rows + a command source ---
R="$(mkrepo)"
cat > "$R/ledger.jsonl" <<'EOF'
{"url": "https://example.com/keep-me", "title": "A keeper article", "verdict": "keep", "conclusion": "worth a deep read"}
{"url": "https://example.com/skip-me", "title": "A skipped article", "verdict": "skip", "conclusion": "off-topic"}
{"url": "https://example.com/on-board", "title": "Already on the board", "verdict": "keep", "conclusion": "dup by title"}
{"url": "https://example.com/in-staging", "title": "Renamed since staged", "verdict": "keep", "conclusion": "dup by url"}
EOF
cat > "$R/fake-source" <<'EOF'
#!/usr/bin/env bash
echo '[{"title": "Saved tab about ducks", "url": "https://example.com/ducks", "collection": "reading-list"}]'
EOF
chmod +x "$R/fake-source"
cat > "$R/_meta/BACKLOG.md" <<'EOF'
| ID-001 | Already on the board | notes | queued |
EOF
cat > "$R/_meta/backlog-staging.md" <<'EOF'
# Backlog staging (auto, via backlog-stage)

## [staged] Some earlier proposal
- Intent: earlier
- Approach: https://example.com/in-staging
- Tags: #u-lo #f-hi
- Source: intake-sweep test 2026-01-01

EOF
cat > "$R/_meta/intake-sources.json" <<EOF
{"sources": [
  {"name": "ledger-keepers", "kind": "jsonl", "path": "ledger.jsonl",
   "include": {"field": "verdict", "equals": "keep"},
   "map": {"title": "title", "url": "url", "intent": "conclusion"},
   "u": "lo", "f": "hi"},
  {"name": "fake-tabs", "kind": "command", "command": "./fake-source",
   "map": {"title": "title", "url": "url"}, "u": "lo", "f": "hi"},
  {"name": "broken", "kind": "command", "command": "./does-not-exist",
   "map": {"title": "title", "url": "url"}}
]}
EOF

echo "== sweep: keepers staged, skips + dups not, broken adapter fail-safe =="
out="$(REPO_ROOT="$R" INTAKE_SWEEP_STATE_DIR="$R/state" python3 "$SWEEP" --force 2>&1)"; rc=$?
S="$R/_meta/backlog-staging.md"
assert_true "sweep exits 0 with a broken adapter in config" "$rc"
assert_true "keep-verdict item staged" "$(grep -q '## \[staged\] A keeper article' "$S"; echo $?)"
assert_true "staged block carries the url in Approach" "$(grep -q '\- Approach: https://example.com/keep-me' "$S"; echo $?)"
assert_true "staged block carries the intake-sweep source line" "$(grep -q '\- Source: intake-sweep ledger-keepers' "$S"; echo $?)"
assert_true "command-adapter item staged" "$(grep -q '## \[staged\] Saved tab about ducks' "$S"; echo $?)"
assert_true "NC: skip-verdict item NOT staged" "$(! grep -q 'skip-me' "$S"; echo $?)"
assert_true "NC: board-title dup NOT staged" "$(! grep -q '## \[staged\] Already on the board' "$S"; echo $?)"
assert_true "NC: staging-url dup NOT staged" "$(! grep -q 'Renamed since staged' "$S"; echo $?)"
assert_true "summary line printed" "$({ trap '' PIPE; echo "$out" 2>/dev/null || :; } | grep -q 'intake-sweep: staged 2 candidate'; echo $?)"

echo "== idempotence: a second forced run stages nothing new =="
before="$(grep -c '^## \[staged\]' "$S")"
REPO_ROOT="$R" INTAKE_SWEEP_STATE_DIR="$R/state" python3 "$SWEEP" --force >/dev/null 2>&1
after="$(grep -c '^## \[staged\]' "$S")"
assert_true "block count unchanged on re-run ($before)" "$([ "$before" = "$after" ]; echo $?)"

echo "== durable dedup: swept key never re-proposed even after its block is promoted =="
# simulate promote: the staged block leaves the staging file entirely
grep -v 'keeper article\|keep-me\|worth a deep read' "$S" > "$S.tmp" && mv -f "$S.tmp" "$S"
REPO_ROOT="$R" INTAKE_SWEEP_STATE_DIR="$R/state" python3 "$SWEEP" --force >/dev/null 2>&1
assert_true "NC: promoted-away keeper NOT re-staged (swept-keys state)" \
  "$(! grep -q '## \[staged\] A keeper article' "$S"; echo $?)"

echo "== config gate: no intake-sources.json -> silent no-op =="
R2="$(mkrepo)"
out="$(REPO_ROOT="$R2" INTAKE_SWEEP_STATE_DIR="$R2/state" python3 "$SWEEP" --force 2>&1)"; rc=$?
assert_true "exits 0 without config" "$rc"
assert_true "NC: no staging file created" "$([ ! -f "$R2/_meta/backlog-staging.md" ]; echo $?)"
assert_true "NC: no output" "$([ -z "$out" ]; echo $?)"

echo "== throttle: second unforced run inside the interval is a no-op =="
R3="$(mkrepo)"
printf '{"url": "https://example.com/one", "title": "First item", "verdict": "keep"}\n' > "$R3/ledger.jsonl"
cat > "$R3/_meta/intake-sources.json" <<'EOF'
{"sources": [{"name": "l", "kind": "jsonl", "path": "ledger.jsonl",
  "include": {"field": "verdict", "equals": "keep"},
  "map": {"title": "title", "url": "url"}}]}
EOF
REPO_ROOT="$R3" INTAKE_SWEEP_STATE_DIR="$R3/state" INTAKE_SWEEP_MIN_INTERVAL=3600 python3 "$SWEEP" >/dev/null 2>&1
printf '{"url": "https://example.com/two", "title": "Second item", "verdict": "keep"}\n' >> "$R3/ledger.jsonl"
REPO_ROOT="$R3" INTAKE_SWEEP_STATE_DIR="$R3/state" INTAKE_SWEEP_MIN_INTERVAL=3600 python3 "$SWEEP" >/dev/null 2>&1
S3="$R3/_meta/backlog-staging.md"
assert_true "first run staged inside the interval" "$(grep -q 'First item' "$S3"; echo $?)"
assert_true "NC: second unforced run throttled" "$(! grep -q 'Second item' "$S3"; echo $?)"

echo "== config bugs are loud, not quiet: unknown kind warns; --check reports raw yield =="
R5="$(mkrepo)"
printf '{"url": "https://example.com/a", "title": "Item A", "verdict": "keep"}\n' > "$R5/ledger.jsonl"
cat > "$R5/_meta/intake-sources.json" <<'EOF'
{"sources": [
  {"name": "good", "kind": "jsonl", "path": "ledger.jsonl",
   "include": {"field": "verdict", "equals": "keep"},
   "map": {"title": "title", "url": "url"}},
  {"name": "typo-kind", "kind": "jsonlines", "path": "ledger.jsonl",
   "map": {"title": "title", "url": "url"}},
  {"name": "dead-path", "kind": "jsonl", "path": "no-such-file.jsonl",
   "map": {"title": "title", "url": "url"}}
]}
EOF
err="$(REPO_ROOT="$R5" INTAKE_SWEEP_STATE_DIR="$R5/state" python3 "$SWEEP" --force 2>&1 >/dev/null)"
assert_true "unknown kind warns on stderr" "$({ trap '' PIPE; echo "$err" 2>/dev/null || :; } | grep -q "typo-kind.*unknown kind 'jsonlines'"; echo $?)"
assert_true "the good source still stages despite a broken sibling" \
  "$(grep -q 'Item A' "$R5/_meta/backlog-staging.md"; echo $?)"
out="$(REPO_ROOT="$R5" INTAKE_SWEEP_STATE_DIR="$R5/state" python3 "$SWEEP" --check 2>&1)"; rc=$?
assert_true "--check exits 0" "$rc"
assert_true "--check reports the good source's raw yield" "$({ trap '' PIPE; echo "$out" 2>/dev/null || :; } | grep -qE 'ok +good \(jsonl\): 1 item'; echo $?)"
assert_true "--check FAILs the unknown kind" "$({ trap '' PIPE; echo "$out" 2>/dev/null || :; } | grep -q 'FAIL typo-kind'; echo $?)"
assert_true "--check WARNs the dead path (0 items)" "$({ trap '' PIPE; echo "$out" 2>/dev/null || :; } | grep -q 'WARN dead-path'; echo $?)"
assert_true "--check counts what needs attention" "$({ trap '' PIPE; echo "$out" 2>/dev/null || :; } | grep -q '3 source(s), 2 needing attention'; echo $?)"
assert_true "NC: --check stages nothing (report-only)" \
  "$(! grep -q 'dead-path\|typo-kind' "$R5/_meta/backlog-staging.md"; echo $?)"
out="$(REPO_ROOT="$R2" INTAKE_SWEEP_STATE_DIR="$R2/state" python3 "$SWEEP" --check 2>&1)"
assert_true "--check says so when no sources are configured" "$({ trap '' PIPE; echo "$out" 2>/dev/null || :; } | grep -q 'no sources configured'; echo $?)"

echo "== surface wiring: backlog-stage.sh --surface runs the sweep then surfaces =="
R4="$(mkrepo)"
printf '{"url": "https://example.com/via-surface", "title": "Via surface", "verdict": "keep"}\n' > "$R4/ledger.jsonl"
cat > "$R4/_meta/intake-sources.json" <<'EOF'
{"sources": [{"name": "l", "kind": "jsonl", "path": "ledger.jsonl",
  "include": {"field": "verdict", "equals": "keep"},
  "map": {"title": "title", "url": "url"}}]}
EOF
out="$(REPO_ROOT="$R4" INTAKE_SWEEP_STATE_DIR="$R4/state" \
      BACKLOG_STAGE_STAGING="$R4/_meta/backlog-staging.md" \
      bash "$KIT_DIR/hooks/backlog-stage.sh" --surface 2>&1)"; rc=$?
assert_true "backlog-stage.sh --surface exits 0" "$rc"
assert_true "sweep ran on the surface pass" "$(grep -q 'Via surface' "$R4/_meta/backlog-staging.md"; echo $?)"
assert_true "surfaced count includes the swept candidate" "$({ trap '' PIPE; echo "$out" 2>/dev/null || :; } | grep -q '1 backlog candidate'; echo $?)"

echo
echo "intake-sweep: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
