# Retro: estate seams (SPEC-249, ID-646)

Full lane, one session. Six tasks, one lead task, three review-fix batches, one battery fix batch, two probe fixes.

## Metrics

- Tasks planned vs done: 6 of 6, every task verified and five re-audited in fresh context.
- Suites at ship: `test-config-seams.sh` 45, `test-staging-stage.sh` 33, `test-wrap.sh` 205 (39 then 25 added), `test-config-registry.sh` 23, kit-config selftest, meta 840.
- Findings: spec gates 24 (11 critical, one revision); integration 1 (source-only library run as a command); review-team round one 13 (1 CRITICAL, 2 HIGH validated by exploit), round two 8, targeted re-verify closed; battery 8 (5 static, 1 advisor, 2 probes).

## What worked

- Reviewer-6-style validate before build: the parser-window, second-grammar, and unbound-expansion findings would each have shipped as a defect; one spec rewrite removed all of them.
- Independent refuters per CRITICAL/HIGH: both reproduced the exploit with a canary before the fix and confirmed the close after, so the fix commits carry RED-before evidence.
- The advisor as a whole-work lens: it was the only arm that noticed the checked-in proof had gone stale after the fix commits, while every code-level arm re-ran the exploits and called the code sound.
- break-it after a green suite: two inputs (a CJK title, a directory as a binary) that no test constrained, found in one probe pass.

## What hurt

- The freeze rule broke a third time: a fix batch and a proof-doc commit landed while the acceptance leg was reading the tree, and the leg escalated instead of certifying; the whole leg re-ran.
- A HIGH fix was half a fix: the post-copy re-fence ran on an unresolved path, so a symlinked parent directory still escaped; the second security round caught it. A fence that takes a path must resolve it itself.
- Two research agents wrote into the main checkout instead of the worktree; relative paths in a brief resolve against the agent's cwd.
- The kit's own command prose ran a source-only library as a command; every other consumer sourced it, and only the integration verifier executed the prose.

## Action items

- [ ] Fences resolve their own argument (`_home_fence` now does); audit `_under_home` callers for the same shape when a third caller appears.
- [ ] `wrap log` fences on HOME only; a repo fence would close the residual inside-HOME `_meta` symlink redirect. One row.
- [ ] `_realpath_f "/"` returns `//`; normalise before any caller can pass the root.
- [ ] The vendored prose-rag crate leaves the kit (ID-647).

## Kit feedback

- `config list` still renders `[consumer]` seam rows as inert; `config seams` is the live view, by the spec's Out of Scope. Worth one line in `config list`'s header pointing at `seams`.
- The commit-format and ship-gate hooks reject a whole compound; commit and push in their own commands, every time.
