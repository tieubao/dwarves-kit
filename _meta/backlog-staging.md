# Backlog staging (auto, via learn propose)

Candidates auto-extracted from the ledger. Review + promote by hand (`board promote`).
Gitignored: may name unfiled work. NEVER the source of truth.

## [staged] Audit high override rate on reflect gate
- Intent: Bring the reflect gate's override rate down from its current outlier level.
- Approach: Sample reflect-gate override reasons to find the common cause; adjust gate criteria or the retro flow that keeps triggering it.
- Tags: #u-hi #f-hi
- Home: dwarves-kit
- Source: learn propose 2026-07-12 | lens=gate-yield figure="reflect override_pct=28.0" rids=SPEC-105-hardening,SPEC-106-admin-moderation,SPEC-107-launch-pack,SPEC-108-account-settings,SPEC-109-onboarding,advisor-visibility,board-mirror,board-tool,+143 more

## [staged] Add a token-runaway guard for sessions
- Intent: Stop sessions from ballooning into billions of tokens unnoticed.
- Approach: Add a session-level token ceiling check that alerts or halts; separately root-cause the 2.1B-token session that triggered this.
- Tags: #u-hi #f-mid
- Home: ops-toolkit
- Source: learn propose 2026-07-12 | lens=anomalies:token_runaway figure="session_id=8ae69411-07d1-474e-a33d-64b1531ce251 project_slug=-Users-tieubao-workspace-tieubao-ops-toolkit total_tokens=2115144012" rids=SPEC-105-hardening,SPEC-106-admin-moderation,SPEC-107-launch-pack,SPEC-108-account-settings,SPEC-109-onboarding,advisor-visibility,board-mirror,board-tool,+143 more

## [staged] Tighten the observability spec against its deviation log
- Intent: Bring the 01-observability spec out of under-specced territory.
- Approach: Review the 15 logged implementation deviations and fold the recurring ones back into the spec.
- Tags: #u-mid #f-hi
- Home: dwarves-kit
- Source: learn propose 2026-07-12 | lens=deviation-rate figure="repo=dwarves-kit; slug=01-observability; file=lib/session/observe/docs/implementation-notes/01-observability.md; n_deviations=15; zero_marker=False; first_ts=2026-06-14 00:00; last_ts=2026-06-15 14:40; class=UNDER-SPECCED" rids=SPEC-105-hardening,SPEC-106-admin-moderation,SPEC-107-launch-pack,SPEC-108-account-settings,SPEC-109-onboarding,advisor-visibility,board-mirror,board-tool,+143 more

## [staged] Sweep memory notes pointing at dead paths
- Intent: Stop memory notes from citing paths that no longer exist in the repo.
- Approach: Run a dead-path scan across memory notes and remove or repoint the stale ones.
- Tags: #u-lo #f-hi
- Home: dwarves-kit
- Source: learn propose 2026-07-12 | lens=memory-sweep figure="21 memory notes reference dead paths, 0 stale (>180d)" rids=SPEC-105-hardening,SPEC-106-admin-moderation,SPEC-107-launch-pack,SPEC-108-account-settings,SPEC-109-onboarding,advisor-visibility,board-mirror,board-tool,+143 more

## [staged] Add a self-answer detection check to `/kit:think` (and any other forcing-question command):
- Intent: Action item a retro committed to; it lived only as a checkbox nobody could promote.
- Approach: Add a self-answer detection check to `/kit:think` (and any other forcing-question command):
- Tags: #u-mid #f-mid
- Source: retro 2026-08-01 | RETRO-2026-08-01-backlog-reconcile.md

## [staged] Make "fetch origin before cutting any new branch" a reflex step in the
- Intent: Action item a retro committed to; it lived only as a checkbox nobody could promote.
- Approach: Make "fetch origin before cutting any new branch" a reflex step in the
- Tags: #u-mid #f-mid
- Source: retro 2026-08-01 | RETRO-2026-08-01-backlog-reconcile.md

## [staged] wrap merge union retry
- Intent: bin/wrap merge: on a CONFLICTING squash caused by GitHub ignoring merge=union, merge the default branch into the branch worktree and retry once
- Approach: (no approach extracted)
- Tags: #u-lo #f-mid
- Home: dwarves-kit
- Source: session 2026-09-08

