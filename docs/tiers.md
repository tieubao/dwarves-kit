# Feature inventory by tier (canonical, DRAFT)

Product-side source of truth for what ships in which tier. Consumed by: the pricing page, the
ID-426 entitlement sets, and the FG-01 business brief (forge
`docs/briefs/DECISION-BRIEF-kit-monetization.md`, which owns pricing/model decisions; this file
owns the FEATURE->TIER->MODULE mapping). Status column: shipped (exists today) / queued (board
row) / planned (catalog, parked).

Two hard principles: **safety is never paywalled**, and **raw telemetry is always free** (the
loop cannot run without it; plain local files, the user's forever). Paid tiers sell the
INTERPRETATION layer: "your data is free forever; our reading of it is the product."

## Core (free forever, open)

| Feature | Module/surface | Status |
|---|---|---|
| Safety spine: secrets guard, push-to-main block, force-push block, destructive-command block, commit hygiene, anti-rationalization stop | spine hooks | shipped |
| Ship gate: no proof, no push (proof-of-done ledger) | gate | shipped |
| Lane classifier (evidence tiers) + 12 work-type loops | classify | shipped |
| Kanban board + pull flow (`board`, states, next) | board | shipped |
| Session doctor `/start` (state + one next action, always-on onboarding) | onboard | shipped |
| Guided first-run `/onboard` (previews every write, decline = no-op) | onboard/adopt | shipped |
| Portable repo adopt (4 files, machine-independent) | adopt | shipped (ID-408) |
| Workflow gallery (generated ASCII flows per work type) | onboard | queued ID-407 |
| Intake interview `/grill` (one question at a time, facts vs decisions) | grill | shipped (+ID-404) |
| Spec pipeline: think / spec / spec-validate (adversarial, 6 lenses) / execute / review / ship | commands | shipped |
| Verifier chain: task, integration, acceptance, system + recheck (fresh-context re-audit) | gate/agents | shipped |
| Review teams (security / architecture / test-coverage lenses) + advisor extra lens | agents | shipped |
| Debug loop (root cause before any fix) | commands | shipped |
| Test-plan matrices + adversarial test-plan review team | test-plan | shipped; default-flip queued as ID-406 |
| Decision briefs (brief-on-file at intake) | assign/briefs | queued ID-409 |
| Worktree isolation per parallel writer + disjointness gate | queue/gate | shipped |
| Mega-goal roadmaps + wavefront orchestration + overnight queue | queue | shipped (ADR-0030) |
| Fan-in/fan-out ordering graph | queue | queued ID-394 |
| Multi-vendor headless dispatch (claude/codex/pi/opencode) | queue | executing ID-390 |
| Append-only ledgers + stats projections (raw telemetry, plain files) | stats/telemetry | shipped |
| Lane-misfire detection | telemetry | shipped |
| Docs sync `/docs` + doc-verifier | commands | shipped |
| Retro engine + gate ledger audit trail | commands/gate | shipped |
| Understanding axis: explain, quiz gates, debt ledger, weekend paydown | quiz_gate/weekend_batch | shipped |
| Upstream absorb machinery + seed watch | absorb | shipped (+ID-403) |
| Tool-selection ladders, BASIC set (browser use, memory, computer use, rendering, model routing: which tool when) | ladders (new) | queued ID-418 |
| North-star alignment lens (proposals state the criterion they serve) | advisor | shipped (+ID-397) |
| Skill fleet: cross-runtime registry + `fleet sync` (one skill body -> every harness) + `fleet render` | fleet (new) | queued ID-431/432 · [docs/fleet/](fleet/) |

## Craft (perpetual license + update stream)

| Feature | Module/surface | Status |
|---|---|---|
| Workflow Insights: weekly report + the-one-thing-to-change recommendation | stats (paid layer) | queued ID-411 |
| Greenlight loop: open PR driven to merge-ready (CI fix + comment triage) | ship | executing ID-401 |
| One persona pack included (Frontend first: visual proof, design lenses, deslop, visual acceptance) | proof/packs | queued ID-395 (deslop lens shipped, ID-402) |
| Tool-selection ladders, MAINTAINED library (updated as the ecosystem moves; part of the stream) | ladders | queued ID-418 |
| Private update channel + pack marketplace access | install | queued ID-426 (supersedes dropped ID-410) |
| Ambient module self-suggest | onboard | queued ID-405 |
| Fleet skills ride the stream (maintained skills propagate to every harness in one pull) | fleet | queued ID-431 · [docs/fleet/PRIVATE-STREAM.md](fleet/PRIVATE-STREAM.md) |

## Crew (per-seat, annual, flat)

| Feature | Module/surface | Status |
|---|---|---|
| Funded workspaces: org token pool, allowances, rollover, never raw keys | gateway (server) | queued ID-412 |
| Policy-as-code: model tiers by role, budget caps by lane, strictest-wins | gateway + policy | planned (team-mode SG-05) |
| Attestation: every change attributed, human or agent, per-actor ledger | team-mode | planned (SG-01/02) |
| Review-economics dashboard: first-pass acceptance, rework, reviewer minutes, cost per merged change | stats (team) | executing ID-392 |
| Canary cards (planted-defect gate testing) | gate | queued ID-393 |
| Morning digest (what your agents did overnight, per member + lead rollup) | stats (team) | planned |
| Reviewer load balancing + assignment routing | board (team) | planned |
| Shared org packs + templates | packs | planned |
| Shadow mode for policy rollout (observe-only first) | policy | planned |
| Business SLA support | support | planned |

## Guild (enterprise, custom, self-host available)

| Feature | Module/surface | Status |
|---|---|---|
| Flight recorder: replay bundle per change, retention, export, search (audit evidence) | gate (enterprise) | planned ID-414 |
| Provenance manifest per PR + dependency quarantine | gate | planned ID-414 |
| Showback/chargeback + burn forecasting + waste detection + rate cards | gateway/stats | planned ID-413 |
| Environment fences, change windows, org kill switch, key-revoke offboarding | policy | planned ID-415 |
| Dual-control locks + claim leases at org scale | policy | planned ID-415 |
| Comprehension health: bus-factor of understanding, per-member debt aggregates | quiz_gate (org) | planned ID-416 |
| Graduated autonomy + workforce registry (agents as staff) | team-mode | planned ID-416 |
| Org board WIP/SLA + cross-team program view + adoption scorecard | board (org) | planned ID-417 |
| Quality regression alarms (control-chart acceptance trends) | stats | planned |
| Model-deprecation radar + migration reports | gateway | planned |
| Vendor failover policies | gateway | planned |
| Compliance preset packs (SOC2 / ISO mapped to gates) | policy | planned |
| Knowledge handover bundles (offboarding continuity) | context | planned |
| Approval delegation (vacation mode, audited) | policy | planned |
| SSO / SCIM · self-hosted deployment · private pack registry | platform | planned |
| Named TAM + quarterly telemetry review | support | planned |

## Add-ons (any tier)

Persona packs a la carte: Frontend (first), Designer, Vibe-coder/CEO, Marketing (sequenced,
content-validated before build per the DF brief). Each = taste pack + guardrail preset +
vocabulary on the same spine.
