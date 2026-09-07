# Spec: precedent finds the built inventory, not only the written record

Generated: 2026-09-06
Status: SHIPPED (dwarves-kit #498, merge 78b13041)
Lane: normal
Type: spec-feature
File: `docs/specs/SPEC-245-precedent-inventory.md`
References: `lib/precedent.sh` (the records surface: keep its keyword filter, grep ranking, and the two-line hit format verbatim); ops-toolkit `tools/repo-sweep/bin/repo-sweep` `_score` at line 625 (AND across terms, name hit 2 vs body hit 1, adjacent-phrase bonus), `_whathas_sources` at line 1310 (one row per source: title, skip note, entries, hit function), `cmd_whathas` at line 1441 (sections ranked by their top hit, `--quiet` collapse, `--json` shape, one log line per query); `lib/session/recall/session_recall.py:189-211` (secret-shape redaction, DATA marker, per-line cap); `bin/learn` + `lib/learn/learn.sh` (shim and entry shape); `lib/board/board.sh:158-168` (registry file format and repo-root precedence); `hooks/harvest.py:1-30` (the fold-in naming rule and consumer-seam wording).

## Problem

`precedent find` answers "have we done something like this before?" at intake (`/kit:assign`, `/kit:grill`), but it reads only the written record: specs, ADRs, retros, verification notes, run ledger. It never looks at what has been BUILT. A task that duplicates an existing tool, script, scheduled job, skill, or memory note sails through intake, because none of those live in `docs/`.

The operator's estate answers the built half with `repo-sweep whathas` (ops-toolkit), a Python digest over tools, scripts, launchd and worker crons, kit verbs, skills, memory notes, feature registries, and house scripts. It is the existence gate the operator's global instructions require before any new tool, and a dotfiles hook (`new-tool-gate`) blocks a new script or job until a whathas check is recorded in the kit's gate ledger. Yet the tool sits outside the kit, its source roots are hardcoded to one estate, and the kit's own intake commands cannot call it. The session that surfaced this (2026-09-06) found `session recall` had already copied whathas's redaction guards by hand, the second sign the kit wants this surface.

## Solution

### Approaches considered

1. **A second surface on the existing noun.** `precedent find --surface records|inventory|all`, one question over two corpora; the inventory sources come from built-in repo-relative defaults plus a consumer registry file. Tradeoff: a Python module beside the bash entry (the inventory scan is a dozen iterators and a scorer, past what grep pipelines express well).
2. **A new module CLI `bin/whathas`.** Port as-is under its own name. Tradeoff: a verb-first orphan, the grammar class ADR-0034 retired (`add-backlog`); assign and grill would need a second call; two finders for one question.
3. **Leave it in ops-toolkit, have the kit shell out when present.** Tradeoff: the kit's intake stays blind on every machine without ops-toolkit, and the estate paths stay hardcoded.

### Chosen approach + why

Approach 1. It keeps one noun for one question, gives assign and grill the built inventory for free, and turns the hardcoded estate into consumer config, the same seam `board` uses for `boards.txt`. Approach 2 was rejected on grammar and on duplication; approach 3 on portability.

### Extensibility & boundaries

- Load-bearing dimension: the number and kind of inventory sources. A new source is one iterator function plus one row in the sources table; display, JSON, quiet, explain, and the log line never change (the whathas invariant, kept).
- Units: `precedent.sh` (verb grammar, records surface, dispatch), `inventory.py` (registry parse, iterators, scorer, digest), `tests/test-precedent.sh` (fixtures for both surfaces). Each is testable alone: the Python module runs standalone with env vars; the bash entry is exercised through `bin/precedent`.
- Registry kinds are a closed set in this spec (`repo`, `scripts`, `skills`, `crons`, `memory`). Anything else is a usage error, so a typo never silently scans nothing.

### Architecture

See `## Design`.

## Picture

```
bin/precedent ──exec──▶ lib/precedent/precedent.sh
                              │
                 ┌────────────┴─────────────┐
            find --surface records      find --surface inventory
                 │ (bash, unchanged)          │ python3 lib/precedent/inventory.py
                 ▼                            ▼
   docs/specs  docs/decisions        built-in defaults           registry file
   docs/retro  docs/verification     · this repo: tools/ (tool.toml + bin/ scripts/ lib/
   $LOG_DIR/runs/*.log                   + top-level *.sh|*.py) scripts/ bin/ cli/ _meta/
                                       .claude/memory .claude/skills docs/FEATURES.md
                                       experiments/*/README.md  research/*.md
                                     · the kit: bin/ + lib/** usage lines, skills/,
                                       docs/FEATURES.md
                                     · ~/.claude/skills, ~/.local/bin
                                     · launchd (LaunchAgents + LaunchDaemons, when present)
                                                       +  <kind> <path> rows:
                                                          repo | scripts | skills | crons | memory
                 │                            │
                 └──────────┬─────────────────┘
                            ▼
             digest: records block, then inventory sections ranked
             by top hit; summary line; one log line in $LOG_DIR/precedent.log
```

## Design

### Approaches considered + chosen

See `## Solution`.

### Diagram

Sequence for `precedent find "<words>"` with the default surface `all`:

```
caller ──▶ precedent.sh: parse flags, resolve ROOT (flag > REPO_ROOT > git toplevel > cwd)
              │
              ├─ records: _keywords → grep docs/* + runs/*.log → ranked hits (existing code)
              │
              └─ inventory: python3 inventory.py --root ROOT --kit KIT --registry FILE
                     │   env: PRECEDENT_REGISTRY, KIT_LEDGER_DIR, HOME
                     ├─ read registry (skip missing paths with a note, refuse unknown kinds)
                     ├─ for each source: iterate entries → score(terms, name, haystack)
                     ├─ redact + cap every hit line; rank sections by top hit
                     ├─ append "<ts>\t<query>\t<hits>\t<top section>" to $LOG_DIR/precedent.log
                     └─ print digest (text | --quiet | --json) or --explain <label>
              │
              └─ print summary line: "precedent: R record matches, N inventory hits in M sections; top: <section>"
```

### ADR link(s)

ADR-0034 (grammar: subsystem noun + verb; this promotes `precedent` from a root-level orphan to a `bin/` subsystem). No new ADR: nothing here is irreversible.

### Boundaries & failure modes

Read-only over every source. Never writes a board, a spec, or a memory note. The only write is the append-only log line, redacted and whitespace-collapsed before it lands, and a failed write never fails the query. The registry is operator config: it resolves from the flag, the environment, or the kit-root `kit.toml` only, never from a project `.kit.toml`, because registry rows widen the roots `--explain` may read and a project toml rides inside an untrusted PR. The legacy `--surface records` output stays byte-identical to the pre-move script and therefore unredacted: it prints headings from the repo's own committed docs, the same trust level as `grep` over that repo; the `all` and `--json` paths redact it. Out of bounds: the ops-toolkit side (retiring `repo-sweep whathas`, the dotfiles `new-tool-gate` phase name), see Out of Scope.

## Technical Design

### Interfaces (I/O contract)

CLI (`bin/precedent`, entry `lib/precedent/precedent.sh`):

```
precedent find "<words>" [--surface records|inventory|all] [--limit N] [--quiet] [--json]
                          [--registry <file>] [--repo-root <path>]
precedent find --explain "<hit label as printed>"
precedent --help
```

- `--surface` default `all`. `records` output is byte-identical to today's `lib/precedent.sh find` for the same input (the parity pin in the tests). Positional `[max]` after the words stays accepted for records-only calls (existing callers).
- `--limit N` (default 5) caps hits per inventory section and the records list.
- `--quiet`: hit sections and the summary line only; empty and skipped sections collapse to one count line.
- `--json`: one object: `data_marker`, one key per section (`{"hits":[...]}` or `{"skipped":"<note>"}`), `records: [{"hits":N,"file":...,"headline":...}]`, `total_hits`, `sections_with_hits`, `nothing_matched`.
- `--explain <label>`: prints the header (first 60 lines, redacted) of the file behind a hit label as printed: a repo-relative path, `~/.local/bin/x`, `kit lib/x.sh`, `skill <name>`, `memory <path>`.
- Exit 0 on a run with zero hits (nothing matched is a valid answer); 64 on usage errors, an unknown surface, an unknown registry kind.

Registry file: whitespace-delimited `<kind> <path>` rows, `#` comments, `~` expands. Resolution: `--registry` flag > `PRECEDENT_REGISTRY` env > `kit_config_get precedent.registry` > `${XDG_CONFIG_HOME:-$HOME/.config}/dwarves-kit/inventory.txt`. A missing registry means built-in defaults only. Kinds:

| Kind | Scans |
|---|---|
| `repo <root>` | the same set the current repo gets by default: `tools/*/tool.toml` + every runnable script under `tools/*/{bin,scripts,lib}/` and at `tools/*/*.sh|*.py`, `scripts/*`, `bin/*`, `cli/*`, `_meta/*` executables, `experiments/*/README.md` (frontmatter, `tech:` tags and lede), `research/*.md` (frontmatter title, purpose, description), `.claude/memory/*.md`, `.claude/skills/*/SKILL.md`, `docs/FEATURES.md` |
| `scripts <dir>` | every text file in the dir; summary = first comment block or docstring |
| `skills <dir>` | `*/SKILL.md`, name + description from frontmatter, body as a low-rank haystack |
| `crons <dir>` | every `wrangler.jsonc` under the dir: worker name + cron expressions |
| `memory <dir>` | `*.md` in the dir and `*/memory/*.md` one level down (the `~/.claude/projects` shape) |

Scoring (ported verbatim): every term must match (word boundary, case-insensitive) in the name or the haystack, else the hit scores 0; a name hit counts 2, a haystack hit 1; a multi-term query in order as one phrase adds a flat bonus. Skills: name or description hit scores double, a body-only hit scores a flat 1.

Output guards: every hit line passes through the secret-shape regex (`op://`, `sk-`, `ghp_`, `AKIA`, `xox[abp]-`, 32+ hex) to `[redacted]` and a 240-char cap; the digest opens with the DATA marker line. The regex is byte-equal to `session_recall.py` and a test pins it so the two copies cannot drift; the DATA marker wording differs by design (files here, transcripts there) and is not pinned.

Log line: `$LOG_DIR/precedent.log`, `LOG_DIR` from `kit_resolve_log_dir` (so `KIT_LEDGER_DIR` redirects it in tests), tab-separated `<iso-ts> <query> <total_hits> <top_section>`, append-only, best-effort.

Invariants: read-only over sources; the records surface's output shape and ranking do not change; adding a source never touches the output paths.

### Data model changes
None. One new config key, `[precedent] registry` in `kit.toml`, status `[consumer]`, default unset.

### API changes
`lib/precedent.sh` is removed; callers move to `bin/precedent find`. The two in-repo callers (`commands/assign.md`, `commands/grill.md`) and the `tests/test-meta.sh` pin update in the same commit.

### UI changes
None.

### Infrastructure changes
None.

## Task Breakdown

### Phase 1: Foundation
- [x] TASK-001 (DONE, commit e07bc30, verified): Move `lib/precedent.sh` to `lib/precedent/precedent.sh`, add `bin/precedent` (shim shape of `bin/learn`), add flag parsing (`--surface`, `--limit`, `--quiet`, `--json`, `--registry`, `--repo-root`, `--explain`, `--help`), keep `find "<words>" [max]` working. Update `commands/assign.md`, `commands/grill.md`, `lib/README.md`, `lib/mega/mega.sh` comment, `tests/test-meta.sh` SPEC-068 pin, `tests/test-bin-forwarders.sh` census. Acceptance: `bin/precedent find "spec drift" --surface records` prints the same bytes as `git show origin/master:lib/precedent.sh | bash -s find "spec drift"`; `bash tests/test-meta.sh` and `bash tests/test-bin-forwarders.sh` green.
- [x] TASK-002 (DONE, commit 975b9bd, verified): `tests/test-precedent.sh` fixture: a temp repo with `tools/alpha/tool.toml` (description mentions "notion sync"), `tools/alpha/bin/alpha-run` (comment header), `scripts/beta.sh`, `.claude/memory/gamma.md` (a `ghp_` token in the body), `.claude/skills/delta/SKILL.md`, `docs/FEATURES.md` with one row, `experiments/eps/README.md`; a temp registry with one `repo`, one `scripts`, one `crons` (a `wrangler.jsonc` with two crons), one missing path, one `~` path; `HOME`, `KIT_LEDGER_DIR`, `PRECEDENT_REGISTRY` overridden. Registered in `.github/workflows/test.yml`. Acceptance: the file runs green with the records-only cases (parity, stopword filter, max validation) before Phase 2 lands.

### Phase 2: Core
- [x] TASK-003 (DONE, verified): `lib/precedent/inventory.py` (stdlib only): registry parse (`~` expansion, comments, unknown kind exits 64, missing path recorded as a skip note), the five kinds plus built-in defaults (this repo, the kit, `~/.claude/skills`, `~/.local/bin`, launchd when the dirs exist), the iterators, `_score`, section ranking, redaction + cap + DATA marker, text/quiet/json output, `--explain`, the log line. Acceptance: test cases for AND semantics (a two-term query where one term is absent scores 0), name-over-body ranking, adjacent-phrase bonus ordering, registry skip note for the missing path, `~` expansion, the `ghp_` token printed as `[redacted]`, `--json` keys present, `--quiet` collapses empty sections to one count line, `--explain "skill delta"` prints the SKILL.md header, `precedent.log` gains one tab-separated line per query, exit 64 on `--surface bogus` and on a registry row of kind `bogus`.
- [x] TASK-004 (DONE, commit 0f8d25a, verified): Wire `all`: records block first, inventory sections after, the summary line last; regex/marker equality pin against `session_recall.py`; `kit.toml` gains `[precedent] registry` (status `[consumer]`) and `lib/config/module-registry.md` gains its row. Acceptance: `bin/precedent find "notion sync"` on the fixture prints the records block, the ranked inventory, and a summary line matching `^precedent: [0-9]+ record matches, [0-9]+ inventory hits in [0-9]+ sections; top: `; the equality pin passes.

### Phase 3: Polish
- [x] TASK-005 (DONE, commit b270831, verified after one lead fix): Docs: `commands/assign.md` and `commands/grill.md` describe both surfaces in one sentence each; `docs/architecture.md` and `MANUAL.md` gain the `precedent` bin row where `learn` is listed; `docs/FEATURES.md` regenerated if the generator's inputs changed (it should not: no command, agent, skill, or hook is added). Proof of done at `docs/verification/precedent-inventory.md` per the behavioral contract (real run on this repo, negative control by reverting `inventory.py`'s scorer). Acceptance: `bash tests/test-meta.sh` green; `bash tests/run-workflow.sh` green.

## After state

- [x] `bin/precedent find "board set"` in this repo prints a `## records` block and lists `lib/board/board.sh` under `## kit verbs`, with SPEC-146 named inline on that line, in one run. (Today: `lib/precedent.sh find` prints the records block only; no bin entry exists.)
- [x] `bin/precedent find "notion sync" --surface inventory --registry <file>` scans every `repo` and `scripts` root in the file and prints a skip note for a missing one. (Today: the source roots are hardcoded in ops-toolkit.)
- [x] `bash tests/test-precedent.sh` exists and is green; `lib/precedent.sh` has a test for the first time. (Today: zero tests.)
- [x] `grep -rn 'precedent.sh find' commands/` returns nothing; both callers say `precedent find`. (Today: two literal callers.)
- [x] `$LOG_DIR/precedent.log` gains one line per query, checkable with `tail -1`. (Today: the log lives in `~/.local/state/repo-sweep/whathas.log`.)

## Acceptance Criteria (global)
- [x] All tasks pass their individual acceptance criteria
- [x] Tests cover happy path + edge cases listed below
- [x] No regressions in existing functionality: records-surface parity pin, `tests/test-meta.sh`, `tests/test-bin-forwarders.sh`

## Verification

```
bash tests/test-precedent.sh && bash tests/test-meta.sh && bash tests/test-bin-forwarders.sh
bin/precedent find "board set" | grep -E '^precedent: [0-9]+ record matches'
```

## Edge Cases
1. Query with only stopwords or tokens under 4 chars: records prints `(no searchable keywords)`, inventory still runs on the raw terms (whathas semantics: it matches short tokens like `ntn`), summary line still prints, exit 0.
2. Registry row with a path that does not exist: section prints `skipped: no dir at <path>`, exit 0.
3. Registry row with an unknown kind: usage error, exit 64, nothing scanned.
4. A hit line containing a secret shape: printed as `[redacted]`, in text and JSON alike.
5. A hit line over 240 chars: truncated at 240.
6. `--explain` with a label that resolves nowhere: prints `explain: no file for <label>`, exit 1.
7. `$LOG_DIR` unwritable: the query still prints, no traceback, exit 0.
8. Not on macOS or no launchd dirs: the launchd section is skipped with a note, never an error.
9. `--surface records` with the positional `[max]`: same output as before this spec.
10. A skill whose body mentions every term but whose description mentions none: ranks at a flat 1, below any description hit.
11. Binary file in a `scripts` dir: skipped silently.
12. The current repo has none of the default dirs (a fresh adopter): every default section skipped, the kit's own verbs and skills still scanned, exit 0.

## Out of Scope
- Retiring `repo-sweep whathas` in ops-toolkit and pointing the operator's global instructions at `precedent find --surface inventory`: a follow-up ops-toolkit PR after this ships.
- Renaming the `whathas` gate phase the dotfiles `new-tool-gate` hook reads: a dotfiles follow-up.
- The house-CLI table and the git-native-features table from whathas: estate-specific and static; both dropped on purpose, and this port never restores them.
- Embeddings, an index, or a daemon: grep-class scan by design, as `lib/precedent.sh` already states.

## Decision Log
- DEC-001: Python stdlib beside the bash entry, not a bash rewrite. The pitfalls research read PHILOSOPHY's hook rule ("all hooks are bash, no Python") as a kit-wide ban; the ban is on hooks, and `lib/` already carries stdlib Python (`learn`, `session`, `bench`). A bash port of twelve iterators and a scorer would be the larger, less legible change.
- DEC-002: Fold into `precedent`, not a new `whathas` noun. One question, one noun; the grammar class ADR-0034 retired was the verb-first orphan.
- DEC-003: Registry kinds are a closed set with an exit-64 on unknown kinds, so a misspelled row never scans nothing silently.
- DEC-004: Third copy of the redaction regex, pinned equal to `session_recall.py` by a test, instead of a shared import across two lib dirs. A shared module would be the right move at the fourth copy.
- DEC-005: `lib/precedent.sh` is removed rather than left as a forwarder. It has two in-repo callers and no external adopters (research: no bin entry, no FEATURES row); a forwarder would keep the orphan alive.
- DEC-006: memory notes are searched by BODY here, a deliberate widening over whathas's frontmatter-only scan, so a fact buried a few lines into a note still surfaces.

## Review

Parallel review, 2026-09-06, diff e7f5fee..a15edd2, 25 files. Reviewers: security (opus), architecture, test-coverage, advisor (critique). Coverage-delta: ok. Every CRITICAL or HIGH finding got one independent refuter; the refuter's disposition is in the Status column.

### Verdict: FIX THEN SHIP

Fix batch applied in b66e5bf: findings 1, 2, 3, 4, 5, 6, 7, 8, 10, 13, 14, 16 (14 new test cases, 37/37). Finding 12 is board row ID-642. Findings 9, 11, 15 recorded as advisory. Lead re-check after the batch: `--explain` refuses `/etc/hosts`, a 16-level `../` traversal, and `~/.gitconfig` with exit 1; the DATA marker precedes the records block.

### Battery (post-merge HEAD 67fc945, four fresh-context arms)

Acceptance verifier PASS (every After-state and AC bullet re-executed; the launchd skip branch is unreachable on a macOS host, recorded as a coverage gap). Reviewer (opus) FIX THEN SHIP. Security lens (opus) FIX THEN SHIP. Advisor: 1 LOW. Arms disagreed with the earlier review-team pass on two HIGHs, the signal the battery exists for.

| # | Finding | Arm | Sev | Route |
|---|---|---|---|---|
| B1 | A repo-committed `.kit.toml` sets `precedent.registry`; registry rows widen the `--explain` allowed roots; `repo /` re-opens the arbitrary read with no flags. Reproduced end to end. | security | HIGH | fixed: `kit_config_get_root` only (kit-root `kit.toml`, never a project toml), negative test with a hostile project `.kit.toml` |
| B2 | `Sections.set_skip` replaces a section wholesale; a registry row with a missing path wipes the ROOT hits already collected under the shared `skills`, `memory`, or `scripts` title and prints a skip note in their place: a silent false negative in an existence gate. | reviewer | HIGH | fixed: skip notes append, hits stay; test with missing `skills` and `memory` rows |
| B3 | `python3` absent or failing blanks the whole default digest, so assign and grill lose a lookup that was pure bash. | reviewer | MEDIUM | fixed: print the records block, one stderr line, propagate the rc |
| B4 | `~` in the registry file path never expands; a typo'd explicit path scans nothing silently. | reviewer | MEDIUM | fixed: expanduser, stderr warning for an explicit path that is not a file |
| B5 | The log line stores the query verbatim: a pasted token persists to the ledger. | security | MEDIUM | fixed: `safe_text` on the query and top section |
| B6 | `--surface records` prints unredacted with no DATA marker (parity with the pre-move script). | security | MEDIUM | accepted, recorded in Boundaries: the repo's own committed docs at grep trust; `all` and `--json` redact |
| B7 | `cmd_explain` opens the candidate path, not the realpath the gate checked (local TOCTOU). | security | LOW | fixed: read the realpath |
| B8 | `--records-file` is an unconfined read reachable only from `inventory.py` argv, never from `bin/precedent`. | security | LOW | docstring marks it internal |
| B9 | The jsonc stripper treats `//` inside a URL as a comment and drops live crons on that line. | security | LOW | fixed: line-start comments only, ceiling noted in a comment |
| B10 | Zero record matches renders an empty `## records` block. | reviewer | LOW | fixed: `(no match)`, collapsed under `--quiet` |
| B11 | `return $?` after a bare command under `set -e` is unreachable. | reviewer | LOW | advisory |
| B12 | Spec After-state and global AC boxes unticked while every claim is verified. | advisor | LOW | fixed |

### Findings

| # | Finding | Found by | Sev | Conf | Status | Route |
|---|---|---|---|---|---|---|
| 1 | `--explain` reads any path: absolute labels taken verbatim, relative labels joined onto ROOT without normalization, `~` and `memory` expanded; nothing confines the resolved path to ROOT, the kit, the skills dir, or registry roots (`inventory.py:759-786`). Reproduced on `/etc/hosts`, a `../` traversal, `~/.gitconfig`. | security | HIGH | 100 | validated | gated_auto: realpath the candidate and refuse it outside the allowed roots (ROOT, KIT_ROOT, `~/.claude/skills`, `~/.local/bin`, registry rows, launchd dirs) |
| 2 | Records block prints above the header and DATA marker, unredacted and uncapped, in text and in the JSON `records` list (`inventory.py:880-896`). | security | MEDIUM | 100 | | gated_auto: print header and marker first; pass records lines and fields through `safe_text` |
| 3 | The implicit positional `[max]` branch (`precedent.sh:193-196`, forces `records` when `--surface` is absent) has no standing test; verified once by hand. | test-coverage | MEDIUM (raised as HIGH, refuter: proportionate at MEDIUM) | 75 | validated | gated_auto: one case `find "notion sync" 3` asserting records only |
| 4 | `--explain` label shapes: only `skill <name>` is tested; `kit`, `memory`, `~`, bare-relative branches run zero times in CI (`inventory.py:759-786`). | test-coverage | MEDIUM | 75 | | gated_auto: one case per shape |
| 5 | `crons` jsonc comment stripping (`inventory.py:572-580`) has no commented fixture; a stripper that does nothing passes. | test-coverage | MEDIUM | 75 | | gated_auto: decoy commented cron in the fixture |
| 6 | `memory <dir>` one-level `*/memory/*.md` walk (`inventory.py:447-461`) unexercised. | test-coverage | MEDIUM | 75 | | gated_auto: nested fixture note |
| 7 | Spec Technical Design and the `inventory.py:33` header claim regex AND marker byte-equality with `session_recall.py`; only the regex is pinned, the marker differs by design (files vs transcripts). `stale-adr:` | advisor | MEDIUM | 100 | | gated_auto: reword both lines |
| 8 | Board row ID-641 still `speccing` while the build is verified. `stale-backlog-status:` | advisor | LOW | 100 | | gated_auto: `executing` now, `shipped` at merge |
| 9 | Scan preamble (`isdir`, `ensure`, sorted `listdir`) repeated; raised as a rule-of-three HIGH. Refuter: 5 of the 7 cited sites share only a 4-line preamble, 2 are recursive walks; a shared helper nets 10 to 15 lines against callback sprawl and risks the `ensure`-before-scoring ordering fix. | architecture | MEDIUM (raised HIGH) | 75 | validated: partially confirmed | advisory: no change |
| 10 | Dead fallback for a missing `inventory.py` in `precedent.sh:105-106, 215-237`; `install.sh` copies `lib/` wholesale, no partial install exists. | architecture | MEDIUM | 75 | | gated_auto: delete the guard and placeholder branch |
| 11 | Label round-trip: printed labels derive from bot-writable fields and the usage text invites `--explain "<label as printed>"`. | security | MEDIUM | 75 | | manual, closed by finding 1's confinement |
| 12 | Redaction regex thin for a 60-line file dump (no AWS secret keys, PEM blocks, `ops_` tokens, `PASSWORD=` assignments); three pinned copies move together. | security | MEDIUM | 75 | | advisory: board row, cross-file change |
| 13 | Query text reaches the log line with newlines and tabs intact (`inventory.py:822-829`). | security | LOW | 100 | | gated_auto: collapse whitespace |
| 14 | `plutil` `TimeoutExpired` is not caught (`inventory.py:655-658`); one hung plist kills the digest. | security | LOW | 100 | | gated_auto: catch `subprocess.SubprocessError` |
| 15 | No frontmatter fence: any `description:` line in the file matches (`inventory.py:160-161`). | security | LOW | 75 | | advisory |
| 16 | `tail()` names a suffix helper; an identity dict `kind_title` (`inventory.py:331, 711`). | architecture | LOW | 75 | | gated_auto: rename, delete |

### Suppressed (below the confidence gate)

test-coverage at 50: `~/.local/bin` dedup untested; body-only skill ranking untested (edge case 10); 240-char cap boundary; `--limit` overflow line; kit-root `kit.toml` fallthrough; positional max with explicit `--surface all`. Self-tests recorded in the lens output; not actioned.

### Previously rejected

None.

### Scores

Security 6/10 (8 after finding 1). Architecture 7/10. Test coverage 6/10. Combined 6.3/10.

### Security

Findings 1, 2, 11, 12, 13, 14, 15. Checked clean: no `shell=True`, `plutil` list-form argv with timeout, grep keywords filtered to `[:alnum:]-`, terms `re.escape`d with no nested quantifier, stdlib only, `mktemp` removed on both paths.

### Architecture

Findings 9, 10, 16. Passed: shim shape byte-equal to `bin/learn`; bash/Python seam at the right cut; closed registry kinds enforced before scanning; repo-root precedence mirrors `board`; docs updated in lockstep; per-capability sections match the spec's examples.

### Test coverage

Findings 3 to 6 plus the suppressed list. Passed: real assertions throughout, byte-parity guard at the right layer, regex pin at unit level, no stale path references, CI wiring present.

### TODOs

- Board row: widen the shared redaction regex across `inventory.py`, `session_recall.py`, and the ops-toolkit source in one change (finding 12).
- Follow-up outside this repo: retire `repo-sweep whathas` in ops-toolkit and point the operator's global instructions at `precedent find --surface inventory`; rename the `whathas` phase the dotfiles `new-tool-gate` hook reads.

## Open questions
(none)
