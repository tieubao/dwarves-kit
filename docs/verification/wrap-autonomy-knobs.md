# Verification log: wrap autonomy knobs

Spec: `docs/specs/SPEC-246-kit-wrap.md`. Branch `feat/wrap-autonomy-config`, base 932b280 (origin/master at start).

Three keys make the wrap landing step's write actions configurable, each defaulting to the acting posture: `wrap.merge_own_prs` (step 3), `wrap.tidy_worktrees` (step 5), `wrap.build_candidates` (step 7b).

## Green run (a52b186)

Command: `bash tests/test-wrap.sh && bash tests/test-config-registry.sh`
Exit: 0 for each suite
Output (excerpt): `test-wrap: all 220 passed` (205 before, 15 new knob cases); config-registry `23/23 passed`
Verdict: PASS

Per knob, three cases prove the resolution: it ships as `true`, an operator `kit.toml` setting it `false` is honoured, and a project `.kit.toml` setting it `false` is ignored. Two further cases per knob pin the wiring: `commands/wrap.md` names the key and `kit.toml` declares it.

The project-toml case is the one that matters. Each knob authorizes a write (a merge into the default branch, a worktree and branch delete, a commit of new code), and a project `.kit.toml` rides inside a pull request. All three resolve with `kit_config_get_root`, which never consults a project file, so a contributor cannot widen what wrap does to the machine running it.

Rendering check: `bash bin/config list | grep 'wrap\.'` shows all three as `[impl]` with default `true`, alongside the two existing `[consumer]` keys.

## NEGATIVE CONTROL (a52b186)

Command: `bash lib/gate/negctl.sh . "bash tests/test-wrap.sh" "sed -i '' 's/^merge_own_prs = true/merge_own_prs = false/' kit.toml"`
Exit: 0 green before; 1 under mutation; 0 after restore
Output (excerpt): `Exit: 1 (under mutation, RED expected)`; `Restore: git checkout HEAD -- kit.toml`; `Verdict: PASS`
Verdict: RED-as-expected. Flipping the shipped default turns the suite red, so the default assertion reads the real file rather than passing vacuously.

## Reproduce

```
git checkout a52b186
bash tests/test-wrap.sh
bash bin/config list | grep 'wrap\.'
```
