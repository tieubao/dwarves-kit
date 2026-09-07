# Pitfall Report: dwarves-kit Estate Seams

## Critical (will block implementation)

- **Tilde expansion gap in kit-config.sh**: lib/config/kit-config.sh:54 only unquotes double-quotes; does not expand `~` in paths. Kit.toml documents paths as "absolute or ~-prefixed" (kit.toml:179), but _kit_toml_get returns raw strings. Wrap.sh works around this manually (lib/wrap/wrap.sh ~535 does `target="${HOME}/${target#\~/}"`). New code consuming kit.toml paths MUST replicate this expansion or paths fail. -- Suggested resolution: either add ~ expansion to _kit_toml_get's unquote block, OR document the caller-side expansion requirement prominently and audit all new kit_config_get() calls.

- **test-meta.sh size (3079 lines)**: File exceeds 500-line split threshold. Changes to it require careful review of its complex awk-based FEATURES.md generation logic. -- Suggested resolution: split into test-meta-core.sh (test runner) + test-features-gen.sh (registry logic).

## Warnings (will cause problems if ignored)

- **Deprecated bridge module still in kit.toml:40-41**: Folded into sync 2026-07-16; legacy mirror/status/writeback verbs remain until SPEC-002 P2 port (ID-290). Code referencing bridge may silently work but eventually fail when P2 shipping removes it. -- Risk: orphaned hook or command handler targeting removed module.

- **CI depth-1 checkout breaks vendored history reads**: test-precedent.sh:214 documents that depth-1 CI checkouts make `git show` return nothing, breaking parity diffs. The test uses a vendored fixture (tests/fixtures/precedent/precedent-pre-move.sh) to work around it. Any new features that call `git show <old-ref>` on commit history will fail in CI unless vendored or mocked. -- Risk: silent CI-only failures.

- **gate-ledger.sh debt verb has unvalidated upstream encoding**: debt() writes structured keywords (significance, worthiness, verdict) with case validation at write time (lines 286-288) but readers (check/override/descent) never call normalize_phase on debt lines (they're ignored per line 253 comment "key on $2==GATE|START|ACTION"). A malformed debt line from an external writer silently passes through. -- Risk: silent log corruption if debt-response or external callers bypass the validation.

- **backlog-stage.py detached-run seam for SessionEnd timeout**: Hook runs during SessionEnd (process tearing down, 30s timeout). LLM call via BACKLOG_STAGE_EXTRACTOR can take 120s, so detached child spawned (backlog-stage.py:48-50 _spawn_staged_detached). Failure to hand off payload or write staging file happens silently after parent exit. -- Risk: lost backlog candidates, no error surface.

## Noted (cosmetic, low risk)

- anti-rationalization.sh:2 mentions TODO/FIXME in code never trips the gate; the comment is correct but the TODO/FIXME handling design is documented only in that comment.

- No circular dependencies: wrap.sh sources kit-config.sh; gate-ledger.sh sources telemetry.sh and ledger.sh; dependency graph is acyclic.

- backlog-stage.py dedup logic (lines 200-240) uses list comprehensions without an explicit index; O(n²) iteration on backlog sizing. Works at current scale (100-200 rows) but slow if board grows to 1000+.

## Missing prerequisites

- [ ] Tilde expansion must be handled by callers of kit_config_get() when keys return paths; OR _kit_toml_get must expand ~ before returning.
- [ ] bridge module reference in install.sh:191 and kit.toml:40-41 will need removal when SPEC-002 P2 ships (ID-290 tracking).
- [ ] CI depth-1 checkout limitation: any new git history reads must vendor fixture or run only in full-checkout test modes.
- [ ] SessionEnd hook timeout + detached-run pattern in backlog-stage.py needs observability for silent failures (logs, exit codes trapped somewhere).

## Files over 500 lines (split candidates)

- test-meta.sh: 3,079 lines -- split into test runner + FEATURES.md generation engine.
