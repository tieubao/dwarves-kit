# Architecture Patterns: dwarves-kit

## Directory structure

Organizing principle: **subsystems by concern** (config, board, precedent, gate, telemetry) with stable bin/ forwarders.

```
lib/                      # subsystems: lib/{config,board,precedent,gate,telemetry}/
  config/                 # config resolution (kit-config.sh + kit.toml)
  board/                  # backlog board system (SPEC-146)
  precedent/              # prior-art search (SPEC-245)
  gate/                   # proof-of-done gate (SPEC-016)
  registry/               # feature-registry.sh (generates FEATURES.md)
  adopt/                  # onboarding consumer repos
bin/                      # stable entrypoints (never internal paths)
  board / precedent / wrap / config  # thin wrappers to lib/*
commands/                 # command docs (.md + frontmatter + AGENTS.md contract)
docs/
  specs/                  # SPEC-NNN.md (autolinking in proof-of-done)
  verification/           # proof-of-done files: one per completed feature
  FEATURES.md             # GENERATED (regenerate: bash lib/registry/feature-registry.sh generate)
tests/
  test-*.sh               # one suite per subsystem: test-config.sh, test-board.sh, test-precedent.sh
  test-no-personal-paths.sh  # guard: no /Users/<owner> strings ship in repo
  fixtures/               # shared test data
```

## Config pattern

**Three-layer resolution** (project > operator > kit-root > default):

```bash
# lib/config/kit-config.sh defines:
kit_config_get section.key [default]          # project > operator > kit-root > default
kit_config_get_root section.key [default]     # operator > kit-root > default (skips project)

# Resolution order (each file optional):
# 1. $KIT_PROJECT_ROOT/.kit.toml (repo-local, project-level config)
# 2. ${KIT_CONFIG_OPERATOR}/kit.toml (operator's ~/.config/dwarves-kit/kit.toml)
# 3. ${DWARVES_KIT}/kit.toml (kit-root default)
```

New config key: add to kit.toml, add a comment in kit-config.sh header, add three test cases in tests/test-config.sh (one per layer), use `kit_config_get` in the consumer code.

## Error handling

Pattern: **exit 1 + stderr on failure, exit 0 + output on success**, all under `set -euo pipefail`.

Example from lib/precedent/precedent.sh:

```bash
if [ -z "$kws" ]; then 
  echo "(no searchable keywords in the description)" >&2
  return 64  # EX_USAGE
fi
# Success path outputs the result and returns 0
```

Commands never store output in globals; they capture via `var=$(cmd)` and check `$?` immediately.

## Naming conventions

- **Files**: kebab-case (test-config.sh, parse-board.sh, kit-config.sh)
- **Functions**: underscore_prefix for private (_kit_toml_get, _resolve_root), no prefix for exported (kit_config_get)
- **Test helpers**: `assert()` / `skip()` / `ok()` / `no()` (per test suite, locally defined)
- **Commands**: /kit:verb-name (lowercase, no caps: /kit:wrap, /kit:assign)

## How recent features were built

### SPEC-248: operator config overlay (commit 2685cc7)

**Files:**
- lib/config/kit-config.sh: added kit_config_operator(), kit_config_get_root(), three-layer logic
- kit.toml: added [wrap].before and [precedent].registry keys
- commands/wrap.md: documented Step -1 (before seam) and Step 6 (activity_log key)
- docs/specs/SPEC-248-operator-config.md: requirement spec
- docs/verification/operator-config.md: proof-of-done with green run + negative control
- tests/test-config.sh: added 5 operator-layer cases to selftest
- tests/test-wrap.sh, test-precedent.sh: added operator-key integration tests

**Pattern:** Config changes = lib/config/* + tests/test-config.sh selftest + docs/specs/SPEC-NNN + docs/verification/proof.md, all in one commit.

### SPEC-245: precedent inventory surface (commit 78b1304)

**Files:**
- lib/precedent/precedent.sh: added _inventory_find(), verb dispatch logic
- lib/precedent/inventory.py: 300+ lines Python scorer (new file)
- bin/precedent: forwarding wrapper, unchanged
- docs/FEATURES.md: REGENERATED (bash lib/registry/feature-registry.sh generate)

**Pattern:** Feature landing → update FEATURES.md via registry script at push time.

## Test structure

**Naming:** test-{subsystem}.sh (executable)

**Helper pattern:**
```bash
PASS=0; FAIL=0
assert() { if [ "$2" -eq 0 ] 2>/dev/null; then echo "  PASS $1"; PASS=$((PASS+1)); else echo "  FAIL $1"; FAIL=$((FAIL+1)); fi; }
ok() { PASS=$((PASS+1)); echo "ok - $1"; }
no() { FAIL=$((FAIL+1)); echo "NOT ok - $1"; }
```

**Guard rule** (test-no-personal-paths.sh): No `/Users/{owner}` or `workspace/{owner}` strings ship in repo. Split sensitive strings in grep patterns (tieubao → tieu""bao) to avoid self-hits.

## Proof-of-done location & grammar

**Location:** `docs/verification/{slug}.md` (one per feature branch)

**Grammar (SPEC-016 contract):**
```markdown
## Green run (commit-sha)

Command: <exact bash command>
Exit: 0
Output (excerpt): <stdout/stderr evidence>
Verdict: PASS

## NEGATIVE CONTROL (lead, throwaway worktree)

Command: <mutation to break the feature>
Exit: 1 under mutation (0 before, 0 after revert)
Verdict: RED-as-expected
```

Critical: uppercase **PASS/RED-as-expected**, exact command text, fresh-context verifier, negative control must cause RED.

## Docs/FEATURES.md regeneration

**File:** `docs/FEATURES.md` marked GENERATED.

**Trigger:** Manual before push → `bash lib/registry/feature-registry.sh generate`

**Test gate:** `tests/test-meta.sh` runs `regenerate-and-diff` to catch drift. If FEATURES.md is stale at push, gate blocks.

## Command docs pattern

**Location & structure:** `commands/{verb}.md` with frontmatter + step list.

**Example (commands/wrap.md):**
- Frontmatter: description + trigger phrases for intent matching
- Self-intro banner: `[kit:wrap] <one-line summary>`
- When/Prerequisites sections
- Process: step -1 through step 8, each with rationale
- Each step has concrete examples (e.g., "Step 0: check for foreign activity via `bin/wrap scan`")

**New command step:** edit the step's section in commands/{verb}.md, add test cases in tests/test-{verb}.sh, regenerate FEATURES.md.

