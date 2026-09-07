---
description: "Guided first-run: detect the install mode, offer /kit:adopt for this repo, pick modules, capture the consumer knobs that make them work, disclose the plugin-path gaps honestly, and end with a five-sentence tour of the loop. Previews and confirms every write; a decline is a no-op."
---

You are running `/kit:onboard`: the kit introducing itself. This is a guided first-run, not a form.
Your job is to ORCHESTRATE the surfaces that already exist, never to reimplement them (ADR-0034
decision 4): you CALL `lib/onboard-detect.sh`, `lib/adopt.sh`, and `bin/config`; you never
re-detect, re-inject, or re-parse config yourself.

**Three rules that hold for the whole run:**
- **Every write is previewed then confirmed.** The only thing that writes is `lib/adopt.sh`, always
  after a `--dry-run` preview (or a shown `.kit.toml` plan) and an explicit yes.
- **A decline is a strict no-op.** At any prompt, declining skips forward and changes nothing on
  disk. Never punish a decline; the next step just continues.
- **A driven surface's failure never crashes the wizard.** If any `bash "$KIT/..."` call exits
  non-zero (a missing/corrupt registry, a failed adopt write), print its error, skip that one step
  with no partial write, and continue the tour. A failure is reported; a decline is silent. They are
  different.

Carry a recommended default on every question so `Enter`-`Enter`-`Enter` produces a sane setup, and
an expert can answer five questions in under a minute. Keep your prose short and welcoming.

Resolve the kit root once at the top: `KIT="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/dwarves-kit}"`. Use
`$KIT/lib/...` and `$KIT/bin/...` for every call below. Resolve the current repo once:
`REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"`.

---

## A. Detect the install mode

Run: `bash "$KIT/lib/onboard-detect.sh" explain`

It prints one of four modes plus a one-line explanation. Show the user the mode and what it means,
in one or two sentences, then branch:

- **`plugin`** -- "Installed as a Claude Code plugin; the runtime loads from the plugin. The
  bash-only extras (the statusLine HUD, and `install.sh --with` for module selection) aren't wired
  on this path, but I'll bridge the module choice below through `/kit:adopt`." Continue to B.
- **`bash`** -- "Installed via `bash install.sh`; your `settings.json` registers the kit hooks
  directly." Continue to B.
- **`both`** -- Disclose the hazard, do NOT try to fix it (that is a settings decision, an
  AGENTS.md Pause-if): "Heads up: BOTH a plugin and a bash install are present, so the kit hooks are
  double-registered and will fire twice. Keep exactly one path. To keep the plugin, remove the
  `dwarves-kit/hooks/*` entries from `~/.claude/settings.json` (or run `bash install.sh --uninstall`).
  To keep the bash install, `/plugin uninstall dwarves-kit@dwarves-marketplace`. I won't change this
  for you." Then continue to B (the rest still works; the double-fire is a warning, not a blocker).
- **`none`** -- The kit isn't installed on this machine yet. There is nothing to set up in a repo
  until it is. Tell the user the two install paths and STOP:
  - Recommended: `/plugin marketplace add dwarvesf/dwarves-kit` then `/plugin install dwarves-kit@dwarves-marketplace`
  - Alternative: `git clone` the kit and `bash install.sh`
  - "Re-run `/kit:onboard` once one of those finishes." End the run here.

## B. Offer to adopt this repo

Adoption is what makes an agent classify + pick a lane here and what makes the ship-gate engage
(`docs/consumer-contract.md`). Check it: `bash "$KIT/lib/adopt.sh" --check "$REPO"`.

- **Already adopted** -- Report it healthy: name what's present (`AGENTS.md`, the `CLAUDE.md` loader
  block, the `WORKFLOW.md` pointer, the `docs/verification/README.md` proof marker) and that
  `.kit.toml` records its module choices. **Write nothing, and do NOT call adopt.** To change modules
  on an already-adopted repo, the honest path (since a project's own `.kit.toml` is never overwritten,
  SPEC-192) is: hand-edit the `[modules]` section of `<repo>/.kit.toml`, then re-run `/kit:adopt` (or
  `bash "$KIT/lib/adopt.sh" --refresh "$REPO"`) to re-wire `settings.json` to match. Offer to show the
  current module state via the fenced read surface, `KIT_PROJECT_ROOT="$REPO" bash "$KIT/bin/config" list`
  filtered to the `modules.*` rows (PROVENANCE shows which values this repo's `.kit.toml` overrides);
  never edit anything silently. Then move to G (you may walk D/E as read-only guidance if the user
  asks, but the default is the tour).
- **Not adopted** -- Preview first: `bash "$KIT/lib/adopt.sh" --dry-run "$REPO"` and show exactly
  what it would create. Then ask, with **Y as the recommended default**:
  > Adopt this repo now? It creates AGENTS.md + a CLAUDE.md loader + a WORKFLOW pointer + the proof
  > marker (all non-destructive, never overwritten later). [Y/n]
  - **Y** -- go to C, pick modules FIRST, then adopt happens there in ONE call. Do not call adopt yet.
  - **decline** -- skip adoption entirely (no-op) and jump to G. Note that the ship-gate won't engage
    until the repo is adopted, so they can re-run `/kit:onboard` (or `/kit:adopt`) later.

## C. Pick the modules, then adopt in ONE call (bridges the plugin path's missing `--with`)

Reached only from B's "not adopted -> Y". The module roster and its defaults are GENERATED from the
registry, never hardcoded here. Read them: `bash "$KIT/bin/config" list` and keep the rows whose
DISPLAY KEY matches `modules.*` (the module rows; NOT the MODULE column, which also names non-module
subsystems like `config`/`ledger`/`gate`). Each row gives the module name, its kit-root default
(`true`/`false`). For the one-line purpose of each,
`bash "$KIT/bin/config" explain modules.<name>` prints it. A module added to the registry later
appears here automatically; do not maintain a second list.

Present the modules compactly (name -- one-line purpose -- default), grouped so the kit-root
`true` ones read as "the recommended baseline." Then let the user accept the baseline or toggle a
few. **Recommended default: accept the kit-root defaults** (that is the sane baseline the kit ships).
`Enter` takes them as-is.

**Then adopt ONCE, seeding the fresh `.kit.toml` with the picks in the same step.** `adopt --with`
seeds modules only on a FRESH `.kit.toml` (it is a no-op once the file exists, SPEC-192), so the
order matters: pick first, then a single call:

```
bash "$KIT/lib/adopt.sh" --with "<comma,separated,chosen>" "$REPO"
```

This injects the contract AND seeds `<repo>/.kit.toml` with those modules `true` AND wires the
enabled hook-bearing modules into `<repo>/.claude/settings.json`, all idempotent and non-destructive.
Show the command's output (it reports what it created). Never call adopt a second time; the "not
adopted" repo becomes adopted here, once. If the call exits non-zero, print its error and stop this
step with no partial state (adopt is atomic per file), then continue to D.

**Honest caveat about `adopt --with`'s reach.** `adopt --with` seeds only the module set adopt
itself knows, which is currently NARROWER than the registry's roster. Derive that set at runtime,
never hardcode it: `grep '^KIT_KNOWN_MODULES=' "$KIT/lib/adopt.sh"` prints adopt's seedable set.
Any picked module that is in the registry roster but NOT in that set (e.g. `prose_rag` today) would
be silently skipped by `--with`, so do NOT rely on it for those: after the adopt call, tell the user
the one exact line to add by hand to `<repo>/.kit.toml`'s `[modules]` section (e.g.
`prose_rag = true`) and to re-run `/kit:adopt --refresh "$REPO"`, exactly the hand-edit path an
already-adopted repo uses. That is the honest reach of the existing mechanic; if a later adopt fix
widens its set, this caveat heals on its own because both sides are derived, not copied.

## C2. Overlays and seams

The engine installs and runs alone; none of the modules picked above needs a companion kit. Two
overlays exist today. context-kit is the data plane: it owns the context tree and recall over it,
and fills `[knowledge] root` plus the `PROSE_RAG_BIN` binary. learning-kit is a study overlay on
the engine; it fills `[wrap] before` with its concept flush, the skill `/kit:wrap` runs at Step -1.

A seam is a key in the operator `kit.toml` (never a project `.kit.toml`) that the engine reads
with `kit_config_get_root`, so an overlay fills it without the engine ever depending on the
overlay. `bash "$KIT/bin/config" seams` lists every seam with its state (`default`, `filled`,
`unresolved`, `absent`); `--check` exits 1 the moment one is `unresolved`, the one-bit answer an
installer wants. With nothing filled, every seam reads `default` or `absent` and everything above
still works. The full table lives in `lib/config/module-registry.md` under `## Seams`.

## D. Capture the consumer knobs that make chosen modules non-inert

Some modules do nothing until a knob is set (e.g. `prose_rag` is dormant without `PROSE_RAG_INJECT=1`;
`money_gate` is inert without `MONEY_GATE_REPOS`). Surface ONLY the knobs for the modules just chosen,
and generate that list from the registry, never a second hardcoded list:

For each chosen module `M`, run `bash "$KIT/bin/config" list` and keep the `[impl]` rows whose MODULE
column equals `M`. For each such knob, `bash "$KIT/bin/config" explain <key>` shows its current value
and where that value comes from. Then:

- **A knob with a `kit.toml` key** (its EXPLAIN shows a `project .kit.toml` level, e.g. `ledger.location`)
  -- offer to write the chosen value into `<repo>/.kit.toml`. Preview the exact line you would add or
  change and confirm before writing; a decline leaves the file untouched.
- **An env-only knob** (EXPLAIN says "this key has no `kit.toml` backing", e.g. `PROSE_RAG_INJECT`,
  `MONEY_GATE_REPOS`, `WEB_DRIFT_SITES`, the `STATS_*` sources) -- there is no `.kit.toml` sink for it,
  so print the exact shell guidance instead, e.g. `export PROSE_RAG_INJECT=1` to activate prose-rag
  recall, and say which shell profile it belongs in. Do not try to edit the user's shell config.
  Quote the separator when a knob has an unusual one: `WEB_DRIFT_SITES` splits on comma or whitespace,
  never colon, because every URL in it carries a colon.
- **A `**no-default-consumer**` knob** (the VALUE column shows that marker, e.g. `stats`'s
  `STATS_TIDE_DB` / `STATS_LEARNED_MD` / `STATS_REPOS` source vars) -- these are OPTIONAL data
  sources, skip-safe by design: unset means "that source's table renders empty", never an error.
  Present them honestly as "optional, safe to leave unset; set only if you have that data source",
  with the `export` shape for each. Never call a module knob-free when it has such rows; "nothing you
  MUST set" and "nothing to configure" are different sentences, use the first.

If the chosen modules genuinely have no `[impl]` knob rows at all, say so in one line and move on.
Recommended default at each knob: leave it at its current value (skip), since the kit-root defaults
already give a working baseline.

## D2. Register the board (offer, never assume)

Adoption wires modules; it does not create the board. If `<repo>/_meta/BACKLOG.md` is missing, offer
this sequence, calling the real surfaces (`bin/board`, the sync installer), never reimplementing them:

1. `board init` -- scaffolds `_meta/BACKLOG.md` + the `_meta/board` shim, idempotently.
2. **Team surface, one question**: does this repo's team work in GitHub Issues (or Notion / Hermes /
   Reminders)? If yes, preview the `.kit.toml` addition (`[sync]` + `apps = "github"`, plus
   `github_repo` only when origin is not the right target) and confirm before writing, same contract
   as the knob writes in D.
3. First `board sync --dry-run`, then live: on a repo that already lived in its tracker, intake
   creates a queued `#inbox` row per open item -- history arrives on the board with no manual
   backfill. Tell the user the `#inbox` tag marks rows awaiting first human triage.
4. **Cadence**: manual `board sync` is the default. If they want it ambient, set
   `[sync] mode = "cron"` and run `bash "$KIT/lib/sync/deploy/macos/install" <backlog-path>`
   (the per-repo LaunchAgent; the launcher re-checks `mode` every run, so flipping back to
   "manual" in `.kit.toml` stops it without an uninstall). Mention `board capture "<title>"`
   as the from-a-session filing verb while you are here.

A repo that declines any step stays fully functional; the board is additive.

## E. Disclose the plugin-path gaps (only for mode `plugin` or `both`)

Be honest about what the plugin path cannot do (ADR-0009), in four short bullets:
- **statusLine HUD:** the v1 plugin schema has no `statusLine` field, so the status-line HUD is
  bash-install-only. If they want it, that is the one reason to run the bash install.
- **Frozen SHA vs `git pull`:** a plugin install is pinned to the version you installed; it moves only
  on `/plugin update`. A bash checkout tracks whatever you `git pull`.
- **Project hook wiring points at the bash path:** adopt's per-repo `settings.json` wiring copies hook
  commands that reference `$HOME/.claude/dwarves-kit/hooks/...`, a path only the bash install creates
  (the plugin compat shim symlinks lib/bin but NOT hooks/). On a plugin-only machine those wired
  project-level hook entries will not fire until a bash install also runs. The PLUGIN's own hooks
  (registered via `hooks/hooks.json` at `${CLAUDE_PLUGIN_ROOT}`) are unaffected and do fire; this gap
  is specifically the adopt-wired per-repo module entries. Say this at adopt time too, not only here:
  on a plugin machine, never claim the module hooks are live after adopt.
- **`KIT_FORCE_FULL=1` escape:** `KIT_FORCE_FULL=1 bash install.sh` forces the full bash install even
  on a plugin machine, but that is exactly what creates the double-hooks hazard from step A -- only do
  it if you are deliberately switching paths, and remove the plugin first.

Skip this section entirely for `bash` mode (no gap to disclose).

## F. Install staleness (one line, not a flow) -- `bash` mode only

If `~/.claude/dwarves-kit/INSTALL-STAMP` exists, compare its `sha=` line to the kit checkout's current
HEAD. If they differ, print exactly ONE line: "Your bash install (sha `<short>`) is behind the checkout
(`<short>`); re-run `bash install.sh` to refresh. Details: `/kit:kit-health`." That is the whole
staleness surface -- it is a pointer, never an upgrade wizard. If the stamp is absent or current, say
nothing.

## G. The welcome tour: the loop in five sentences

Close with the five-stage loop, one sentence per stage, then the next step. Keep it to five sentences:

1. **Shape** -- you turn an intent into a spec (`/kit:spec`) and a lane, so the work has a written,
   testable contract before any code.
2. **Build** -- the build runs against that spec (`/kit:execute`), worker then verifier then a
   bounded fix retry, the smallest verifiable increment at a time.
3. **Watch** -- every run leaves an append-only trail that `stats` projects on demand, so you can
   see what actually happened without a second source of truth.
4. **Check** -- the ship-gate blocks a push whose lane skipped a required gate or a stateful change
   with no recorded proof, so "done" means proven, not claimed.
5. **Learn** -- retros and the Learn stage distill each run's lessons back into the backlog, closing the
   loop so the next cycle starts smarter.

Then: **"Next: run `/kit:start` -- it detects where this repo stands and hands you the single right
command to run first."** End the run there.

## Do NOT

- Reimplement detection, injection, or config parsing (call the three surfaces above; ADR-0034 fence).
- Change `install.sh` or `adopt.sh`, or add a flag to `bin/config`. onboard is a consumer of them.
- Write anything without a preview + an explicit yes. A decline changes nothing.
- Auto-fix the `both` double-hooks hazard, or edit the user's shell profile. Disclose and point.
- Turn INSTALL-STAMP staleness into a flow. It is one line and a `/kit:kit-health` pointer.

## Optional: tell it as the workshop story

If the user seems newer, or asks why the stage names are what they are, you may retell the
closing five-sentence tour of the loop using the story below instead of the plain version. Same
five stages, same one sentence each, just voiced as a role plus what it hands you. Never use
these story names as command or file names; they are prose only, and the code still calls the
stages Shape/Build/Watch/Check/Learn. Full mapping: `docs/glossary.md`.

1. **The interview** (Shape) -- you describe what you want; the interview hands you back a
   blueprint, the written spec.
2. **The night shift** (Build) -- the crew builds against that blueprint while you are not
   watching every line: worker, then verifier, then a bounded retry.
3. **The logbook** (Watch) -- every run leaves an entry in the logbook, so what happened is
   never just someone's memory of it.
4. **The inspector** (Check) -- walks every doorway; a job with no stamp does not leave the
   shop.
5. **The debrief** (Learn) -- writes up what the run taught, and the lesson goes back on the
   board as the next job.
