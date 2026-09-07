# lib/config/module-registry.md , module<->stage + env<->key registry (SPEC-198)

Machine home pinned by ADR-0034 decision 3 (stage names renamed by the 2026-07-18 amendment,
leg -> stage): ONE checked-in file carrying both the
module -> primary-stage table (decision 3's authoritative assignment) and the
env<->key rows (decision 4's `bin/config` read surface). Parsed by
`lib/config/config.sh` (the `bin/config` engine) and by
`tests/test-config-registry.sh` (the drift + completeness lints). Both readers are
line-oriented `awk`/`grep` over these markdown tables , this file is NOT a second
TOML reader; VALUE resolution for any row still goes through
`lib/config/kit-config.sh` (`kit_config_get` / `kit_config_root` /
`kit_config_project` / `_kit_toml_get`), the ADR-0034 decision-4 fence
("`lib/config/kit-config.sh` stays the ONLY reader of TOML").

Generated-from-nothing-else: seeded from a fresh sweep (`rg -ohE
'\$\{?(KIT|WAVE|QUEUE|MEGA|CC_SI|PROSE_RAG|MONEY_GATE|TIER4|MUX|TMUX|PANE|TERMINAL|STATS|CC_BACKLOG|HARVEST|BACKLOG|DWARVES)[A-Z_]*'
lib hooks bin | sort -u`), then every hit's reader + default verified at its
source by hand (no pre-existing table existed before this file), plus every
`kit.toml`-declared key (whether or not it has an env override), so `bin/config
list` can render "every declared key," not just the env-shaped subset.

## Module stages

Authoritative assignment per ADR-0034 decision 3, renamed by the 2026-07-18 amendment (leg ->
stage; Specify/Execute/Observe/Govern -> Shape/Build/Watch/Check, Learn kept). Old names shown
parenthetically for one release. Every `KIT_KNOWN_MODULES` entry
(`install.sh:170`, 12 modules) has exactly one row. `team_mode` is excluded from
`KIT_KNOWN_MODULES` itself (install.sh hard-rejects it until team-mode ships), so
it is not a row here either , the completeness rule is scoped to
`KIT_KNOWN_MODULES`, not to every `[modules]` line in `kit.toml`.

| Module | Primary stage | Notes |
|---|---|---|
| board | Shape (Specify) | spanner: input side (Shape) + staging/promote (Learn) |
| session | Watch (Observe) | spanner: capture side (Watch) + harvest (Learn); `session audit` is the deep Watch pass (LLM audit, `run`) + a Learn-stage proposer (`triage`) |
| advisor | Check (Govern) | |
| cosmetic | (none) | orthogonal to the loop; statusline |
| queue | Build (Execute) | |
| stats | Watch (Observe) | |
| quiz_gate | Build (Execute) | |
| weekend_batch | Learn | |
| sync | Shape (Specify) | spanner: spoke intake -> board rows (Shape input side) + outward mirror to Reminders/Notion/Hermes (Watch, presentation). Engine lib/sync/, verb `board sync`, per-repo `[sync]` config. ABSORBED `bridge` 2026-07-16 (same engine surface, zero live consumers at fold time: no `bridge=on` rows, no snapshot, module off): the SPEC-147 cockpit mirror + SPEC-149 writeback become a sync EDGE in the SPEC-002 P2 port (ID-290). FIRST SLICE LANDED (`lib/sync/cockpit.py`, `board mirror --engine sync --dry-run`): the deterministic multi-source EXTRACT + keyed `row_hash` git-wins diff, carrying over the reachable-state map {triage, ready, blocked, done}. The legacy `mirror`/`status`/`writeback` verbs + lib/board/board-mirror.sh + board-writeback.sh stay the DEFAULT and runnable, serving the still-deferred live LOAD leg, two-way writeback, snapshot migration, and eventual verb-retirement. |
| worktree | Build (Execute) | |
| money_gate | Check (Govern) | |
| classify | Shape (Specify) | not a `KIT_KNOWN_MODULES` install toggle (it is spine machinery), but ADR-0034 decision 3 assigns it a stage and pins THIS file as the machine home for that table. Added 2026-07-14: the stage was answerable only from ADR prose. |
| gate | Check (Govern) | spine machinery, same as above (ADR-0034 decision 3). |
| spec | Shape (Specify) | spine machinery (ADR-0034 decision 3). |
| goal | Shape (Specify) | spine machinery (ADR-0034 decision 3). |
| mega | Build (Execute) | spine machinery (ADR-0034 decision 3). |
| learn | Learn | spine machinery; created BY ADR-0034 decision 1 (the Learn stage's home). |
| telemetry | Watch (Observe) | spine machinery; the durable-root resolver + lane telemetry. |
| gauntlet | Check (Govern) | side-flow 11 (commands/gauntlet.md): probe-convergence engine, onboarding is the reference preset; one shared config pair serves every preset. Config: `gauntlet.runner_host` ("local" or an ssh alias; remote rounds ship committed state, run there, pull the record back) + `gauntlet.probe_key_ref` (1P ref the RUNNER host resolves itself; the key never travels over ssh). Consumer: `tests/gauntlet/cleanroom/run-remote.sh`. |
| skill-curator | Learn | ADR-0034 decision 3 lists it under Learn; installs via hooks, not a `--with` module. |
| prose_rag | Learn | **deviation, not in ADR-0034's decision-3 table** (checked: `grep -n prose_rag docs/decisions/0034-harness-loop-taxonomy.md` has zero hits in the leg table). Assigned Learn by this sub-goal's own judgment: prose-rag is a recall/retrieval read over the user's own accumulated corpus (til/research/learned-ledger), the same read-side shape as the Learn stage's other members, not a Watch-class run-telemetry capture. Flagged for Han; a later ADR-0034 amendment may reassign it. |

## Env <-> key registry

One row per declared knob. `Env var` is `-` for a `kit.toml`-only key (no env
override exists); `kit.toml key` is `env-only` for a var with no TOML backing.
Every row has at least one of the two populated. `Status` reuses `kit.toml`'s own
tags (`[impl] [design] [reserved] [consumer]`); an env-only var is `[impl]` iff a
real reader consumes it today (all rows below are, except where noted).

### config (the resolver's own bootstrapping knobs + the kit install root)

| Env var | kit.toml key | Default | Status | Module | Doc |
|---|---|---|---|---|---|
| DWARVES_KIT | env-only | `$HOME/.claude/dwarves-kit` | [impl] | config | The kit install root; `KIT_CONFIG_ROOT`'s own fallback. |
| KIT_CONFIG_ROOT | env-only | `${DWARVES_KIT:-$HOME/.claude/dwarves-kit}` | [impl] | config | Override where the kit-root `kit.toml` itself is read from (this IS the resolver's own bootstrap knob; it cannot have a `kit.toml` key). |
| KIT_PROJECT_ROOT | env-only | `$PWD` | [impl] | config | Override which project's `.kit.toml` is consulted. |
| KIT_CONFIG_OPERATOR | env-only | `${XDG_CONFIG_HOME:-$HOME/.config}/dwarves-kit` | [impl] | config | Override where the OPERATOR `kit.toml` is read from (the overlay between the project `.kit.toml` and the kit root; it is a bootstrap knob, so it cannot have a `kit.toml` key). The operator file carries per-operator paths across kit upgrades and is as trusted as the kit root, since it lives on the operator's own machine and never rides inside a pull request. |
| DWARVES_KIT_DEBUG | env-only | `0` | [impl] | (none) | Verbose hook/command debug logging; cross-cutting, not config-subsystem-specific. |
| DWARVES_KIT_LICENSE | env-only | `$HOME/.config/dwarves-kit/license` | [impl] | config | `bin/activate`: path to the license keyfile the activation check reads. |
| KIT_TOOL_POLICY | env-only | `$HOME/.claude/dwarves-kit/tool-policy.json` | [impl] | config | `hooks/tool-policy-guard.sh`: path to the tool-policy JSON the guard enforces. |
| DWARVES_KIT_LANES_D | env-only | `$HOME/.config/dwarves-kit/lanes.d` | [impl] | config | `lib/gate/gate-ledger.sh`: dropin dir for per-lane `.plan` files. |

### Data-plane keys ([ledger] section + the durable telemetry root)

| Env var | kit.toml key | Default | Status | Module | Doc |
|---|---|---|---|---|---|
| KIT_LEDGER_DIR | ledger.location | (none; canonical) | [impl] | ledger | The durable run-telemetry/ledger root override; wins over `DWARVES_KIT_LOG_DIR` and the toml key. Set-but-empty is a FATAL error, never silent fall-through. Two-env special case (see `DWARVES_KIT_LOG_DIR` below); the authoritative precedence lives in `lib/telemetry/kit-log-dir.sh::kit_resolve_log_dir` , this row resolves independently under the generic 4-level model, it does not replay that function's exact tie-break. |
| DWARVES_KIT_LOG_DIR | ledger.location | (none; alias) | [impl] | ledger | Back-compat alias, precedence #2 under `KIT_LEDGER_DIR`, over the toml key. Pre-SPEC-182 name for the same root; kept for every existing test pin + the live corpus. |
| - | ledger.location | `"shared"` | [impl] | ledger | The toml-level default consulted only when neither env var above is set: `"shared"` -> XDG (`${XDG_STATE_HOME:-$HOME/.local/state}/dwarves-kit/logs`); `"isolated"` -> `$PWD/.kit/logs`; any other value = an explicit path. |
| - | ledger.telemetry | `true` | [design] | ledger | Comment says `[impl]` in `kit.toml`, but no reader was found (grepped `ledger.telemetry` and `kit_config_get ledger` across lib/hooks; only the kit-config.sh selftest matches, not a real consumer) , retagged `[design]` here; flagged as a `kit.toml` status-tag drift for the lead, not fixed in this sub-goal (no kit.toml schema changes, no resolver changes, scope fence). |
| KIT_DELIVERY_RATIO_WARN | ledger.delivery_ratio_warn | `3` | [impl] | gate | Proof-to-real line ratio that triggers a delivery (THIN-WARN) warning. |
| KIT_DELIVERY_REAL_FLOOR | ledger.delivery_real_floor | `40` | [impl] | gate | Real-work line-count floor; below it + a high proof ratio flags a run THIN-WARN. |

### STATS_* source vars (explicit per goal instruction; every one has NO hardcoded fallback , unset means "skip this source," not "use a default path")

| Env var | kit.toml key | Default | Status | Module | Doc |
|---|---|---|---|---|---|
| STATS_TIDE_DB | env-only | **no-default-consumer** | [impl] | stats | ops-toolkit-specific: path to tide's sqlite state db. Unset -> `config.tide_db_path()` returns `None` -> that source's table renders empty, skip-safe (no hardcoded fallback path). |
| STATS_TGCLEANUP_DIR | env-only | **no-default-consumer** | [impl] | stats | ops-toolkit-specific: root of the tg-cleanup tool's data. Unset -> `None` -> that source is skipped. |
| STATS_LEARNED_MD | env-only | **no-default-consumer** | [impl] | stats | ops-toolkit-specific: path to the learned-ledger markdown file. Unset -> `None` -> that source is skipped. |
| STATS_REPOS | env-only | **no-default-consumer** | [impl] | stats | Comma-separated repo ROOTs for `rejected_findings` / `stats review-yield` (SPEC-137). Unset -> `""` splits to `[]`, zero repos scanned. |
| STATS_GIT_REPO_DIR | env-only | (kit repo root) | [impl] | stats | Where `stats` looks for its own git history; kit-internal, computed dynamically, never hardcoded. |
| STATS_MEMORY_REPO_DIR | env-only | (kit repo root) | [impl] | stats | Where `stats` looks for memory-lens data; kit-internal, computed dynamically. |
| STATS_SESSIONS_DIR | env-only | `~/.claude/projects` | [impl] | stats | Claude Code's own session-transcript dir; host-generic. |
| STATS_SECRET_GUARD_LOG | env-only | `~/.cache/claude-secret-guard.log` | [impl] | stats | The secret-guard hook's audit log path; host-generic. |
| STATS_MEMORY_PROJECTS_ROOT | env-only | `~/.claude/projects` | [impl] | stats | Root `stats` scans for cross-project memory-lens data; host-generic. |
| BACKLOG_STAGE_BACKLOG | env-only | (none) | [impl] | stats, board, learn, session, wrap | **Canonical (SPEC-200 I2)**: read-only backlog file every proposer dedups against. Unset -> dedup source unavailable. One name, one resource: `stats --propose`, `board promote`, `learn propose`, `session audit triage` and `hooks/backlog-stage.py` all read THIS. `wrap stage` is the one reader that does not error when unset: it defaults to the current repo's `_meta/BACKLOG.md`. |
| BACKLOG_STAGE_STAGING | env-only | (none) | [impl] | stats, board, learn, session, wrap | **Canonical (SPEC-200 I2)**: the feedback loop's ONLY write target (the staging buffer). Unset -> a proposer errors "no destination configured" rather than writing a stray relative path. `wrap stage` is the one reader that does not error when unset: it defaults to the current repo's `_meta/backlog-staging.md`. Under `wrap stage` an override path must already exist as a regular file, because the value arrives from the environment a repo `.envrc` writes and create-on-absent would let it seed a new file under `$HOME`. |
| CC_BACKLOG_BACKLOG | env-only | (none) | [impl] | stats | **Deprecated alias** of `BACKLOG_STAGE_BACKLOG` (SPEC-200 I2). Still read by `stats`; warns on stderr; removed one release after SPEC-200 lands. The host-agent `CC_*` prefix is banned by the kit naming invariant and lint-enforced (`tests/test-config-registry.sh`). |
| CC_BACKLOG_STAGING | env-only | (none) | [impl] | stats | **Deprecated alias** of `BACKLOG_STAGE_STAGING` (SPEC-200 I2). Same terms as the row above. |
| STATS_DB_REMOVED | (none , not a real config var) | n/a | n/a | n/a | **Registered, not excluded** (scope fence: never delete an undocumented var without registering it first): grepped `lib/stats/src/stats/{config,materialize,adapters}.py` , zero references. Only appears in `lib/stats/tests/*.sh` as an exported scratch path used purely for test-fixture cleanup (`rm -f "$STATS_DB_REMOVED"`). Not read by any product code path; the drift lint allowlists it (see Allowlist below) as dead/vestigial rather than a live knob. |

### mega (WAVE_CAP / TIER4_CLOSE / MULTIPLEXER / merge posture)

| Env var | kit.toml key | Default | Status | Module | Doc |
|---|---|---|---|---|---|
| WAVE_CAP | mega.wave_cap | `2` | [impl] | mega | Max concurrent sub-goals admitted per wave. |
| TIER4_CLOSE | mega.tier4_close | `true` | [impl] | mega | Enables the Tier-4 mega-close auto-verify+hold sequence (SPEC-118). |
| MULTIPLEXER | mega.multiplexer | `0` (off) | [impl] | mega | Opt-in wave pane multiplexing (SPEC-119); only engages when a wave actually admits >=1 sub-goal concurrently. |
| MEGA_MERGE_POSTURE | mega.mega_merge_posture | `"auto-to-final"` | [impl] | mega | `"auto-to-final"` or `"per-pr-review"` merge posture. |
| - | mega.merge_autonomy | `"gated-final"` | [design] | mega | `"gated-final"` or `"full-auto"`; no env override found. |
| - | mega.default_model | `"sonnet"` | [design] | mega | GLOBAL model fallback; real control is the per-sub-goal goal-file `Model:` field. Precedence: goal-file `Model:` > project cfg > this default. |
| - | mega.over_test | `false` | [design] | mega | GLOBAL scaffold-rigor default; real control is per-sub-goal `Done-mode: over-test` (SPEC-112). |
| MEGAGOALS_ROOT | env-only | (none) | [impl] | mega | Root dir where mega-goal folders live; unset falls through to further path resolution in `lib/mega/mega.sh`. |
| MEGA_MERGE_PR_INFO_CMD | env-only | (none) | [impl] | mega | Override the command used to fetch PR info at merge time; called directly when set. |
| MEGA_MERGE_GATE_LEDGER | env-only | `$LIB_ROOT/gate/gate-ledger.sh` | [impl] | mega | Which `gate-ledger.sh` `mega-merge.sh` shells out to. |
| MEGA_GATE_DISPATCH | env-only | `1` | [impl] | mega | `1` dispatches a `gate` / `gate!` sub-goal like any other (grounded on the PR existing); `0` restores the stop-before-running behavior. |
| PANE_TAIL_JQ | env-only | `$ORCH_DIR/pane-tail.jq` | [impl] | mega | The jq formatter the multiplexer pane tail reads through; read-only by construction. |
| QUEUE_PUSH_ONLY | env-only | `0` | [impl] | queue | `1` pushes the branch and stops without opening the PR (draft or ready per the run's own rule). |
| DWARVES_KIT_SKIP_DOC_PROJECTION | env-only | `0` | [impl] | gate | `1` skips the ship-gate's doc-projection check for a repo that has neither projection file; an escape hatch, never a default. |
| MEGA_MERGE_GH | env-only | `gh` | [impl] | mega | Override the `gh` binary/wrapper used for PR ops at merge. |
| BACKLOG_LIB | env-only | `$LIB_ROOT/board/backlog.sh` | [impl] | mega | Which `backlog.sh` `orchestrate.sh` shells out to for wave admission reads. |
| PANE_VIEWER | env-only | `auto` | [impl] | mega | Which terminal-viewer surface to push-open on wave spawn (SPEC-119). |
| TMUX_CMD | env-only | `tmux` | [impl] | mega | Override the tmux binary `orchestrate.sh` drives for wave panes. |
| TMUX_SESSION | env-only | (none) | [impl] | mega | Override the tmux session name for a mega run; unset falls to `_mux_session_name` derivation. |
| TIER4_CORPUS | env-only | `""` (empty) | [impl] | mega | Override the corpus path used by Tier-4 close checks. |
| WAVE_MERGE_CMD | env-only | `$LIB_ROOT/goal/mega-merge.sh merge` | [impl] | mega | Override the merge command a completed wave invokes. |
| WAVE_MERGE_LANE | env-only | `full` | [impl] | mega | Override the risk lane used at wave-merge time. |
| WAVE_POLL_SECS | env-only | `0.2` | [impl] | mega | Polling interval while waiting for wave admission. |

### queue (single-goal driver, `lib/queue/queue.sh`)

| Env var | kit.toml key | Default | Status | Module | Doc |
|---|---|---|---|---|---|
| TERMINAL_MUX | env-only | `tmux` | [impl] | queue | Which multiplexer the single-goal queue drives; `tmux` is the only value supported today. |
| MUX_CMD | env-only | `$TERMINAL_MUX` | [impl] | queue | Override the multiplexer binary. |
| QUEUE_MUX_SESSION | env-only | `dk-queue` | [impl] | queue | tmux session name the queue drives. |
| QUEUE_CLAUDE_CMD | env-only | `claude` | [impl] | queue | Override the Claude CLI binary the queue launches. |
| QUEUE_CLAUDE_FLAGS | env-only | `--dangerously-skip-permissions` | [impl] | queue | Flags passed to the launched Claude CLI. |
| QUEUE_POLL_SECS | env-only | `15` | [impl] | queue | Polling interval for queue status. |
| QUEUE_TIMEOUT_SECS | env-only | `7200` | [impl] | queue | Max time a queue item may run. |
| QUEUE_RETRY_SLEEP_SECS | env-only | `1800` | [impl] | queue | Sleep before retrying a failed queue item. |
| QUEUE_STARTUP_SECS | env-only | `20` | [impl] | queue | Grace period for the launched session to start. |
| QUEUE_SUBMIT_SETTLE_SECS | env-only | `2` | [impl] | queue | Settle time after submitting a prompt. |
| QUEUE_BOARD_CMD | env-only | `board` | [impl] | queue | Override the board CLI command name. |
| QUEUE_JOURNAL | env-only | `${DWARVES_KIT_LOG_DIR:-$HOME/.claude/dwarves-kit/logs}/queue-journal.tsv` | [impl] | queue | Path to the queue's TSV journal. |
| QUEUE_ALLOWED_POINTER_GLOB | env-only | `_meta/megagoals/* .claude/goals/*` | [impl] | queue | Glob allowlist for pointer files the queue may submit. |
| QUEUE_GOAL_CHAR_LIMIT | env-only | `4000` | [impl] | queue | `/goal` char ceiling; an over-budget pointer fails fast before a window opens. |
| QUEUE_WAIT_POLL_SECS | env-only | `5` | [impl] | queue | Poll interval (seconds) for the `queue wait` verb. |
| QUEUE_BEAT_STALE_SECS | env-only | `600` | [impl] | queue | Beat age past which the conductor is presumed gone (SPEC-221). |
| QUEUE_BEAT_DEAD_SECS | env-only | `3600` | [impl] | queue | Beat age past which the reaper writes a verdict (SPEC-221). |
| QUEUE_MAX_STALLS | env-only | `3` | [impl] | queue | Stalls before a slug is quarantined (empty retry_after). |
| QUEUE_COOLDOWN_SECS | env-only | `1800` | [impl] | queue | Breaker cooldown before an `error` row is re-picked. |
| QUEUE_NOPROGRESS_TRIP | env-only | `3` | [impl] | queue | Consecutive no-progress runs that trip the breaker. |
| QUEUE_SAMEERROR_TRIP | env-only | `5` | [impl] | queue | Consecutive `error` runs that trip the breaker. |
| QUEUE_RETRY_JITTER_MIN | env-only | `5` | [impl] | queue | Floor (minutes) of the jittered retry window after a stall. |
| QUEUE_RETRY_JITTER_SPAN | env-only | `11` | [impl] | queue | Span (minutes) of the jittered retry window after a stall. |
| QUEUE_PR_READY | env-only | `0` | [impl] | queue | `1` opens a normal PR; `0` keeps the unattended draft-PR default (SPEC-224). |
| QUEUE_MAX_TOOL_CALLS | env-only | `0` | [impl] | queue | Per-row ceiling on the run's self-reported TOOL_CALLS (`0` = off). |
| QUEUE_MAX_TOTAL_TOOL_CALLS | env-only | `0` | [impl] | queue | Queue-wide TOOL_CALLS ceiling across rows this run (`0` = off). |
| QUEUE_SANITIZE_PROMPT | env-only | `0` | [impl] | queue | `1` treats the pointer body as untrusted (SPEC-223 XPIA pass); implied by `--from-boards`. |
| QUEUE_MAX_PROMPT_CHARS | env-only | `20000` | [impl] | queue | `lib/queue/sanitize.sh`: max prompt chars accepted before the pointer is rejected. |
| QUEUE_PROTECTED_GLOBS | env-only | `.claude/* CLAUDE.md AGENTS.md .github/* _meta/BACKLOG.md` | [impl] | queue | `lib/queue/sanitize.sh`: protected-path globs a gated run may not write. |
| QUEUE_PERL_CMD | env-only | `perl` | [impl] | queue | `lib/queue/sanitize.sh`: perl binary override for the sanitize pass. |

### board

| Env var | kit.toml key | Default | Status | Module | Doc |
|---|---|---|---|---|---|
| BACKLOG_FILE | env-only | `$BACKLOG_DIR/../../_meta/BACKLOG.md` | [impl] | board | Override which `BACKLOG.md` the CLI reads/writes. |
| BACKLOG_ID_RE | env-only | `[A-Z]+-[0-9]+` | [impl] | board | Regex for what counts as a backlog item ID. |
| KIT_BOARDS_REGISTRY | env-only | `<repo-root>/_meta/boards.txt` | [impl] | board | `lib/mega/runs-dashboard.py`: override the boards registry the cross-repo cockpit reads (beats the repo-root default, loses to `--registry`). |

### sync (two-way spoke mirror, `board sync` -> `lib/sync/backlog_sync.py`)

All resolved in `board.sh cmd_sync` via `kit_config_get` at invocation and
passed to the python engine as flags (the engine reads no TOML; ADR-0034
single-reader fence). No env vars; per-repo values live in `.kit.toml [sync]`.

| Env var | kit.toml key | Default | Status | Module | Doc |
|---|---|---|---|---|---|
| - | sync.apps | `""` (sync off) | [impl] | sync | Comma list of apps to sync to (`reminders,notion,hermes,multica,notion-taskboard`); the plugin mechanism. Legacy aliases `surfaces` and `sources` still read as fallbacks (renamed 2026-07-16 for plain vocabulary; `sources` also collided with SPEC-002's board-side inputs). `notion-taskboard` is a one-way, insert-only push (SPEC-003), not part of the two-way mesh. `notion-taskboard-pull` is the opposite posture, a read-only intake FROM a foreign board (SPEC-004); it runs alone and the engine refuses an invocation that lists it beside any other app. |
| - | sync.mode | `"manual"` | [impl] | sync | `manual` (default) or `cron`. Read by `lib/sync/deploy/macos/install` (kit ID-289): a repo must set `mode = "cron"` before that installer will render or load a per-repo scheduled-sync LaunchAgent; any other value is a clean refusal, not a silent fallthrough. Not read by `board.sh cmd_sync` itself -- manual `board sync` runs are unaffected by this key. ALSO re-read live by the installed `board-sync-cron` launcher on every scheduled run: flipping `mode` back to `"manual"` after install makes the next scheduled run skip cleanly (exit 0, logged) rather than silently keep syncing against a config that says it shouldn't. |
| - | sync.interval_secs | `3600` | [impl] | sync | Cron LaunchAgent `StartInterval` seconds, read by `lib/sync/deploy/macos/install` as the default cadence for `mode = "cron"`; `--interval-secs N` overrides it for one install run. |
| - | sync.reminders_list | `"Backlog"` | [impl] | sync | Apple Reminders list name. |
| - | sync.notion_db | `""` | [impl] | sync | Bind an existing Notion database id. |
| - | sync.notion_parent | `""` | [impl] | sync | Notion page id to create the board under (bootstrap). |
| - | sync.hermes_target | `""` | [impl] | sync | Where the hermes instance lives: an ssh host, `local`, or `sudo:<user>` for an instance owned by another uid on this host. No default: unset aborts the sync. |
| - | sync.hermes_home | `""` | [impl] | sync | HERMES_HOME of the kanban store to sync against. |
| - | sync.hermes_board | `""` | [impl] | sync | Kanban board slug, on reads as well as writes. Empty uses the instance's own current board, which is mutable global state. |
| - | sync.hermes_assignee | `""` | [impl] | sync | Profile every relayed task is assigned to. Empty leaves tasks unassigned, so no worker picks them up. |
| - | sync.hermes_workspace | `""` | [impl] | sync | Workspace for every relayed task, e.g. `dir:/path/outbox/{id}`. `{id}` is the board id, so each task gets its own directory. Empty means the CLI default, `scratch`, which is deleted on completion. |
| - | sync.scope_exit_cap | `20` | [impl] | sync | Max rows one run may close on an app when a filter changes; `--allow-scope-exit N` is the one-run override. |
| - | sync.reminders_only_tags | `""` | [impl] | sync | Down-filter: a row must carry one of these tags to appear on reminders. |
| - | sync.reminders_skip_tags | `""` | [impl] | sync | Down-filter: a row carrying any of these tags never appears on reminders. |
| - | sync.reminders_intake | `""` (all) | [impl] | sync | Up-filter for foreign reminders items: `all`, `tagged:<tag>`, or `none`. |
| - | sync.notion_only_tags | `""` | [impl] | sync | Down-filter: a row must carry one of these tags to appear on notion. |
| - | sync.notion_skip_tags | `""` | [impl] | sync | Down-filter: a row carrying any of these tags never appears on notion. |
| - | sync.notion_intake | `""` (all) | [impl] | sync | Up-filter for foreign notion items: `all`, `tagged:<tag>`, or `none`. |
| - | sync.hermes_only_tags | `""` | [impl] | sync | Down-filter: a row must carry one of these tags to appear on hermes. |
| - | sync.hermes_skip_tags | `""` | [impl] | sync | Down-filter: a row carrying any of these tags never appears on hermes. |
| - | sync.hermes_intake | `""` (all) | [impl] | sync | Up-filter for foreign hermes items: `all`, `tagged:<tag>`, or `none`. |
| - | sync.multica_only_tags | `""` | [impl] | sync | Down-filter: a row must carry one of these tags to appear on multica. |
| - | sync.multica_skip_tags | `""` | [impl] | sync | Down-filter: a row carrying any of these tags never appears on multica. |
| - | sync.multica_intake | `""` (all) | [impl] | sync | Up-filter for foreign multica items: `all`, `tagged:<tag>`, or `none`. |
| - | sync.notion_taskboard_db | `""` | [impl] | sync | Target Notion database id for the one-way insert-only Task Board push (SPEC-003). Tenant id: lives in the consumer repo's `.kit.toml`, never here. Required when `notion-taskboard` is in `apps`. |
| - | sync.notion_taskboard_status_map | `""` | [impl] | sync | `board-state=OptionName` comma map to the team board's OWN Status options, e.g. `queued=Backlog,executing=In progress,parked=Waiting,shipped=Done`. `dropped` is skipped by default (never pushed). |
| - | sync.notion_taskboard_status_default | `""` | [impl] | sync | Status option for board states absent from the map (e.g. claimed/speccing/validated); without it, an unmapped state is a hard, guided error rather than a guess. |
| - | sync.notion_taskboard_priority_map | `""` | [impl] | sync | `tag=Option` map for Priority, e.g. `u-hi=P0,u-mid=P1,u-lo=P2` (derived from a row's `#u-*` tag). |
| - | sync.notion_taskboard_weight_map | `""` | [impl] | sync | `tag=Value` map for Weight, e.g. `f-hi=2,f-mid=5,f-lo=13` (from a row's `#f-*` tag). Optional. |
| - | sync.notion_taskboard_owner | `""` | [impl] | sync | Owner value set on create (a people-prop user id by default). Tenant id: consumer repo only. |
| - | sync.notion_taskboard_props | `""` | [impl] | sync | JSON overriding the target prop NAMES `{title,status,priority,weight,owner,notes}` (defaults Task/Status/Priority/Weight/Owner/Notes). |
| - | sync.notion_taskboard_types | `""` | [impl] | sync | JSON overriding the target prop TYPES `{status,priority,weight,owner}` (defaults status/select/number/people). |
| - | sync.notion_taskboard_only_tags | `""` | [impl] | sync | Down-filter: a row must carry one of these tags to be pushed to the Task Board. |
| - | sync.notion_taskboard_skip_tags | `""` | [impl] | sync | Down-filter: a row carrying any of these tags is never pushed to the Task Board. |
| - | sync.notion_taskboard_pull_db | `""` | [impl] | sync | Source Notion database id for the read-only Task Board intake (SPEC-004). Tenant id: consumer repo only. The engine refuses the run if this equals `notion_db` or `notion_taskboard_db`, because those apps write. |
| - | sync.notion_taskboard_pull_props | `""` | [impl] | sync | JSON overriding the source prop NAMES `{title,status,notes,queue}` (defaults Task/Status/Notes/Agent Queue). |
| - | sync.notion_taskboard_pull_done_option | `""` (Done) | [impl] | sync | Status option treated as done and therefore never pulled. |

### session (incl. session-intel / skill-curator, prefix `SKILL_CURATOR_*`)

| Env var | kit.toml key | Default | Status | Module | Doc |
|---|---|---|---|---|---|
| SKILL_CURATOR_STATE_DIR | env-only | `$HOME/.claude/skill-curator` | [impl] | session | Root of the skill-curator tool's state (ledger, lock, log, config). |
| SKILL_CURATOR_PROPOSALS_DIR | env-only | `$HOME/.claude/skill-proposals` | [impl] | session | Where drafted skill proposals land. |
| SKILL_CURATOR_SKILLS_DIR | env-only | `$HOME/.claude/skills` | [impl] | session | Where curated/promoted skills are written. |
| SKILL_CURATOR_CONFIG | env-only | `$SKILL_CURATOR_STATE_DIR/config.toml` | [impl] | session | skill-curator's own config file (a separate file, not `kit.toml`). |
| SKILL_CURATOR_SETTINGS | env-only | `$HOME/.claude/settings.json` | [impl] | session | Which `settings.json` the skill-curator installer patches. |
| SKILL_CURATOR_MEMORY_LEDGER | env-only | `""` | [impl] | session | Path to the learning ledger surface.sh cross-references; feature is off if unset. |
| SKILL_CURATOR_CURATOR_CMD | env-only | (real `claude -p`) | [impl] | session | Override the curator's model-invocation command (test injection point). |
| SKILL_CURATOR_REVIEWER_CMD | env-only | (real `claude -p`) | [impl] | session | Override the async reviewer's model-invocation command. |
| DWARVES_KIT_SESSION_MARKER | env-only | `/tmp/.dwarves-kit-session-start` | [impl] | session | Path of the session-start marker file. |
| SESSION_AUDIT_CMD | env-only | `claude -p --model <M> --allowedTools Bash,Read,Grep,Glob --output-format json` | [impl] | session | Agent runtime `session audit run` pipes its rendered prompt to; tests inject fixtures here. |
| SESSION_AUDIT_DATE | env-only | (today) | [impl] | session | Report-date override (YYYY-MM-DD) for deterministic tests. |

### gate

| Env var | kit.toml key | Default | Status | Module | Doc |
|---|---|---|---|---|---|
| - | gate.understanding_gate | `true` | [impl] | gate | `hooks/anti-rationalization.sh` (ADR-0031). Always-on today; no env override exists , exposing an on/off toggle is new work. |
| DWARVES_KIT_PRINT_CDDIR | env-only | `0` | [impl] | gate | Debug: print the resolved cwd/repo-root and exit. |
| KIT_ROOT | env-only | `$SCRIPT_ROOT` | [impl] | gate | Mixed usage: most files compute this internally from `BASH_SOURCE`, not the environment; `lib/gate/proof-table-gen.sh` alone treats it as an operator-settable override, defaulting to `$SCRIPT_ROOT`. |

### prose_rag / money_gate

| Env var | kit.toml key | Default | Status | Module | Doc |
|---|---|---|---|---|---|
| PROSE_RAG_INJECT | env-only | unset (hook inert) | [impl] | prose_rag | The engine's own opt-in master switch for the recall-inject hook , deliberately NOT `modules.prose_rag` (that toggle only gates hook *install*, this gates whether the installed hook actually fires). |
| PROSE_RAG_CORPUS | env-only | unset (index skips clean) | [impl] | prose_rag | Colon-separated corpus dirs/files for `prose-rag index` (adapter-default invariant: no personal path in the kit). Unset with no `--corpus` = unconfigured consumer -> `index` exits 0, db untouched (the shipped kit-weekly `prose-rag-index` job stays silent-green). Under launchd, supplied via `~/.config/kit-weekly/env`. |
| MONEY_GATE_REPOS | env-only | (unset) | [impl] | money_gate | Colon-separated list of repo names the guard treats as financial; hook is inert (exits 0) without it. |
| PROSE_RAG_BIN | env-only | `prose-rag` on PATH | [consumer] | prose_rag | Path to the `prose-rag` binary (context-kit fills this: `cargo install --path src/prose-rag`). `bin/prose-rag` is an adapter and resolves the same order `config seams` reports for the `binary` kind: `${PROSE_RAG_BIN:-}` if set must be an executable regular file, else `command -v prose-rag`. Unset with nothing on PATH means the overlay is not installed, not an error. |
| PROSE_RAG_SHIM_ACTIVE | env-only | (unset) | [impl] | prose_rag | Recursion guard set by `bin/prose-rag` before it execs the resolved engine. The kit installer puts a PATH wrapper named `prose-rag` that execs this shim, so without the marker `command -v prose-rag` would resolve to the shim itself. Internal: nothing sets it by hand. |

### precedent (`precedent find` inventory surface, no install module)

| Env var | kit.toml key | Default | Status | Module | Doc |
|---|---|---|---|---|---|
| PRECEDENT_REGISTRY | precedent.registry | `${XDG_CONFIG_HOME:-$HOME/.config}/dwarves-kit/inventory.txt` | [consumer] | precedent | Registry file of extra `<kind> <path>` scan locations (`repo\|scripts\|skills\|crons\|memory`) for `precedent find --surface inventory\|all`. Resolution: `--registry` flag > this env var > `kit_config_get_root precedent.registry` (the operator `kit.toml` or the kit-root `kit.toml` ONLY; a project `.kit.toml` is never read for this key because registry rows widen the roots `--explain` may read and a project toml rides inside an untrusted PR, `kit-config.sh:75-90`) > the XDG default path shown here (read by `inventory.py` itself, not the resolver). Empty/missing registry means built-in scan only. |

### wrap (`/kit:wrap` landing-step config, no install module)

| Env var | kit.toml key | Default | Status | Module | Doc |
|---|---|---|---|---|---|
| - | wrap.activity_log | `""` | [consumer] | wrap | Absolute or `~`-prefixed path to the operator's own activity-log file, resolved with `kit_config_get_root` (the operator `kit.toml` or the kit-root `kit.toml` ONLY; a project `.kit.toml` is never read for this key because it names a file the kit writes to, `kit-config.sh:75-90`). Its resolved realpath must sit under `$HOME`'s realpath and name an existing regular file, else `wrap log` exits 1 naming the resolved path. Empty means `wrap log` prints the line and reports that nothing was written, exit 0. |
| - | wrap.before | `""` | [consumer] | wrap | Name of a skill `/kit:wrap` invokes FIRST, before step 0, resolved with `kit_config_get_root` (the operator `kit.toml` or the kit-root `kit.toml` ONLY; a project `.kit.toml` is never read for this key because it names code the command runs and a project toml rides inside an untrusted PR, `kit-config.sh:75-90`). The skill's report lines fold into the wrap report after its `FYI` line. Empty means no skill runs. |
| KIT_SKILL_DIRS | env-only | `$HOME/.claude/skills` plus `${CLAUDE_PLUGIN_ROOT:-}/skills` when set | [consumer] | wrap | Colon-separated list of skill directories `config seams` searches for a `skill` kind row's `SKILL.md` (e.g. `wrap.before`). Entries whose realpath does not sit under `$HOME` are dropped, because a repo `.envrc` can set this. Not read by any code yet; `config seams` (TASK-002) is the first consumer. |

### knowledge (context tree root, no install module)

| Env var | kit.toml key | Default | Status | Module | Doc |
|---|---|---|---|---|---|
| - | knowledge.root | `""` | [consumer] | wrap | Absolute or `~`-prefixed path to the context tree root (context-kit fills this), resolved with `kit_config_get_root` (the operator `kit.toml` or the kit-root `kit.toml` ONLY; a project `.kit.toml` is never read for this key because it names a tree outside the repo, `kit-config.sh:75-90`). Empty means repo-local: knowledge notes stay under `<repo>/.claude/memory/`. Filled, repo knowledge files land under `<root>/projects/<repo-basename>/`. |

### web_drift (skill knob, no install module)

| Env var | kit.toml key | Default | Status | Module | Doc |
|---|---|---|---|---|---|
| WEB_DRIFT_SITES | env-only | (unset) | [impl] | (none) | Sites the `kit:web-drift` audit loop enumerates, read by `lib/webcheck/webcheck.py sites` (adapter-default invariant: the kit ships no hostname). Separator is COMMA or WHITESPACE, never colon, because every `https://` URL carries a colon. Unset means no sites are declared: the skill reports that and stops, which is a clean result, not an error. |

### modules (install-time manifest, `install.sh` `KIT_KNOWN_MODULES`, one row per entry)

No env var exists for any of these , they are install-time flags recorded in the
consumer's own `kit.toml [modules]` section (an install RECORD, never read at
runtime by a hook per the standing "no runtime manifest read" lint), read at
COMMAND invocation via `kit_config_get modules.<name>`.

| Env var | kit.toml key | Default | Status | Module | Doc |
|---|---|---|---|---|---|
| - | modules.board | `true` | [impl] | board | Enables board's hooks + CLI. |
| - | modules.session | `true` | [impl] | session | Enables session's hooks + CLI. |
| - | modules.advisor | `true` | [impl] | advisor | Enables the advisor's hook-bearing surface. |
| - | modules.cosmetic | `false` | [impl] | cosmetic | Statusline; orthogonal to the loop. |
| - | modules.queue | `true` | [impl] | queue | Hookless; orchestrate/dispatch are commands. |
| - | modules.stats | `true` | [impl] | stats | Hookless read-plane projection. |
| - | modules.quiz_gate | `false` | [impl] | quiz_gate | Hookless; backs `commands/quiz-gate.md`. |
| - | modules.weekend_batch | `false` | [impl] | weekend_batch | Hookless; backs `lib/queue/weekend-batch.sh`. |
| - | modules.worktree | `false` | [impl] | worktree | Hookless; exposes the `worktree-provision` CLI. |
| - | modules.money_gate | `false` | [impl] | money_gate | `money-gate.sh` PreToolUse guard; inert without `MONEY_GATE_REPOS`. |
| - | modules.prose_rag | `false` | [impl] | prose_rag | `prose-rag.sh` recall inject + CLI; dormant without `PROSE_RAG_INJECT=1`. |
| - | modules.sync | `false` | [impl] | sync | hookless; `board sync` two-way spoke mirror, inert without `[sync] sources`. |

### features / team (reserved / design, all inert by contract)

| Env var | kit.toml key | Default | Status | Module | Doc |
|---|---|---|---|---|---|
| - | features.auto_improvement | `false` | [design] | (none) | Read-plane loop over the ledger -> backlog proposals; design-doc only. |
| - | features.learning_ledger | `true` | [consumer] | (none) | Orchestration lives in an external consumer skill (ops-toolkit/dotfiles, SPEC-126); the kit only collects + routes. |
| - | team.actor_identity | `false` | [design] | (none) | `actor=` on gate rows + Owner col + `claim` verb. |
| - | team.attestation | `false` | [design] | (none) | `docs/runs/<rid>.md` branch-riding + `attested-for=`. |
| - | team.ci_recheck | `false` | [design] | (none) | Report-only GitHub Action, always exit 0. |
| - | team.spec_reservation | `false` | [design] | (none) | Pushed spec-stub branch = SPEC-number reservation. |
| - | team.policy | `false` | [design] | (none) | Git-tracked `[policy]`: path fences, guarded verbs. |
| - | team.onboarding | `false` | [design] | (none) | `adopt --with team` -> `TEAM.md`. |
| - | team.pilot | `false` | [design] | (none) | End-to-end UAT (held). |

## Allowlist (internal, excluded from the drift lint)

Tokens the seed regex matches that are NOT real user-facing env vars , either a
script-local computed path (assigned before any read, never inherited from the
environment), a test-fixture-only name, or an unrelated false positive of the
prefix match. The drift lint (`tests/test-config-registry.sh`) treats a hit
against any of these bare tokens as covered without a registry row.

| Token | Why excluded |
| KIT_LOG_DIR | the RESOLVED ledger root, exported by `lib/telemetry/kit-log-dir.sh` for child tools (`mega review`/`mega report` read it); operators configure `KIT_LEDGER_DIR` / `[ledger].location`, never this |
|---|---|
| BACKLOG_DIR | `lib/board/backlog.sh`: computed via `pwd`, script-local. |
| KIT_REF | `lib/adopt.sh`: the literal `~/.claude/dwarves-kit` string written into a consumer's AGENTS.md for its own shell to expand; assigned, never env-read. |
| BACKLOG_SH | `lib/board/board.sh`: computed path, not env-overridable. |
| CC_BACKLOG_BACKLOG_FIX | `lib/stats/tests/test-deviation-rate.sh`: test-fixture-local, assigned then used in the same file, never read as inherited env. |
| SKILL_CURATOR_LEDGER | `lib/skill-curator/lib/common.sh`: derived from `SKILL_CURATOR_STATE_DIR`, not independently env-read. |
| SKILL_CURATOR_LIB | `lib/skill-curator/lib/common.sh`: computed via `BASH_SOURCE`. |
| SKILL_CURATOR_LOCK | `lib/skill-curator/lib/common.sh`: derived path. |
| SKILL_CURATOR_LOG | `lib/skill-curator/lib/common.sh`: derived path. |
| SKILL_CURATOR_ROOT | `lib/skill-curator/lib/common.sh`: computed `$SKILL_CURATOR_LIB/..`. |
| KIT | `lib/gate/verify-counts.sh`: computed repo-root var, script-local. |
| KITLOG | `lib/stats/tests/test-defect-correlation.sh`: test-fixture-local. |
| KITTY_WINDOW_ID | The Kitty terminal emulator's own env var; an unrelated false positive of the `KIT` prefix match, not a kit config surface at all. |
| KIT_DIR | `lib/plugin-check/tests/smoke.sh`: test-fixture scratch dir. |
| KIT_KNOWN_MODULES | `install.sh`: a hardcoded bash array literal, never read from the environment. |
| KIT_LIB | Script-local computed dir in most readers (e.g. `lib/telemetry/lane-telemetry.sh`); the real env-overridable cousin is `DWARVES_KIT_LIB` (Python, `lib/stats/src/stats/config.py`), which the bash-oriented seed regex cannot see (no `$` sigil in Python source) , documented here rather than silently dropped: see `lib/stats/README.md`'s own env table for `DWARVES_KIT_LIB`'s default (this repo's own `lib/`, kit-internal). |
| MEGA_SH | `lib/board/board.sh`: computed `$BOARD_DIR/../mega/mega.sh`. |
| QUEUE_SH | `lib/queue/watch-board.sh`: computed `$WATCH_DIR/queue.sh`, script-local sibling path, never env-read (same shape as `MEGA_SH`). |
| PANE_VIEWER_ALLOWED | `lib/queue/orchestrate.sh`: a hardcoded allowlist string, not itself env-read; it validates `PANE_VIEWER`. |
| STATS_DB_REMOVED | Dead/vestigial test-fixture token, see its row above , no product reader exists. Kept OUT of the drift-fail set (registered above instead of silently dropped, per the scope fence) but also allowlisted so the lint does not double-count it as a live undocumented knob. |

## Seams

The cross-kit hand-off points: existing `[consumer]` registry rows above, each tagged
with a resolution kind and the overlay expected to fill it. This table sits OUTSIDE
`_registry_rows`' window (it ends at `## Allowlist`), so it never doubles as a fake
registry row. `bin/config seams` resolves each row and reports its state; the default,
module, and description come from the registry rows above and are not repeated here.

| Key | Kind | Filled by |
|---|---|---|
| wrap.before | skill | learning-kit concept flush, or the operator |
| wrap.activity_log | file | operator |
| precedent.registry | file | operator |
| knowledge.root | dir | context-kit |
| PROSE_RAG_BIN | binary | context-kit |

## Known gaps (documented, not enforced by this lint , out of this sub-goal's scope)

The seed regex is deliberately the exact reproducible command named in
`_meta/megagoals/harness-loop/goals/08-config-surface.md` step 2, scoped to a
fixed prefix family (`KIT|WAVE|QUEUE|MEGA|CC_SI|PROSE_RAG|MONEY_GATE|TIER4|MUX|TMUX|PANE|TERMINAL|STATS|CC_BACKLOG|HARVEST|BACKLOG|DWARVES`)
and to bash `$VAR`/`${VAR}` tokens only. During verification, real user-facing env
vars were found OUTSIDE that family; they are NOT covered by the drift lint
(a future sub-goal widening the prefix family, or switching the lint's detection
to the structural `${VAR:-`/`[ -n "${VAR:-}" ]` pattern instead of a prefix
allowlist, would close this), but are named here so they are not lost:
`LANE_DEESCALATE_FLOOR` (`lib/classify/lane-classify.sh`), `MONEY_GATE_STRICT`
(`hooks/money-gate.py`, Python-only, no `$` token), `MUTATION_SMOKE_BASE` /
`MUTATION_SMOKE_TEST_CMD` / `MUTATION_SMOKE_RID` / `MUTATION_SMOKE_MAX`
(`lib/gate/mutation-smoke.sh`), `HANDOFF_MAX_LINES` / `WATCHDOG_STALL_SECS` /
`WATCHDOG_POLL_SECS` / `FLIP_LOCK_STALE_SECS` / `FLIP_LOCK_POLL_SECS` /
`VIEWER_CMD` / `STREAM_RETENTION_DAYS` / `NC_SKIP_WAVE_START` /
`NC_SKIP_WAVE_TOKENS` (`lib/queue/orchestrate.sh`), `GOAL_SPECS_DIR`
(`lib/goal/goal-drafts.sh`), `SPEC_RESERVE_FILE` / `SPEC_RESERVE_TTL` /
`SPEC_RESERVE_MAX_TRIES` (`lib/spec/spec-next.sh`), `SIGNIFICANCE_WORTHINESS_MIN`
(`lib/classify/significance-classify.sh`), `HERMES_BIN` (`lib/board/board-mirror.sh`),
`REPO_FILTER` (`lib/learn/weekend-batch.sh`), `OFFLOAD_MAX_TOKENS`
(`hooks/output-offload.sh`), `KIT_WEEKLY_JOBS` (`deploy/macos/kit-weekly`; its
predecessor `INTEL_DIR` retired with the per-job session-intel launcher,
ADR-0034 decision 9).
