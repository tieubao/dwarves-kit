# Verification log: command autonomy knobs

Branch `feat/command-autonomy-knobs`, base f9f1cd3 (origin/master at start). Sibling of `docs/verification/wrap-autonomy-knobs.md`: the same contract applied to `/kit:ship`, `/kit:debug` and `/kit:review-team`.

Five keys, each gating an action that is reversible in git, each shipping the acting default: `ship.confirm_commit` (`false`), `ship.confirm_bump` (`"major"`), `ship.create_changelog` (`true`), `debug.confirm_fix` (`false`), `review.apply_findings` (`true`).

## Green run (00246d9)

Command: `bash tests/test-config-registry.sh && bash tests/test-meta.sh && bash tests/test-docs-wiring.sh && bash tests/test-review-team-plants.sh && bash tests/test-command-emit-sweep.sh && bash tests/test-no-personal-paths.sh`
Exit: 0 for each suite
Output (excerpt): config-registry `38/38 passed` (23 before, 15 new); `Passed: 840 / 840`; docs-wiring `25/25 passed`; `All review-team plant tests passed.`; `All command-emit-sweep tests passed.`; `All no-personal-paths tests passed.`
Verdict: PASS

Three cases per key: it ships as its declared default, an operator `kit.toml` setting the opposite is honoured, and a project `.kit.toml` setting the opposite is ignored. The third is the one that matters. Each knob authorizes a write (a commit, a version-file edit, a new file, a verdict, an applied code fix) and a project `.kit.toml` rides inside a pull request, so a contributor must not be able to widen what a command does to the machine running it. All five resolve with `kit_config_get_root`, which never consults a project file.

Rendering check: `bash bin/config list | grep -E '^(ship|debug|review)\.'` shows all five as `[impl]` at their declared defaults.

`docs/FEATURES.md` regenerated (`bash lib/registry/feature-registry.sh generate docs/FEATURES.md`); the SPEC-219 freshness pin in `test-meta.sh` is green.

## NEGATIVE CONTROL (00246d9)

Command: `bash lib/gate/negctl.sh . "bash tests/test-config-registry.sh" "sed -i '' 's/^confirm_fix      = false/confirm_fix      = true/' kit.toml"`
Exit: 0 green before; 1 under mutation; 0 after restore
Output (excerpt): `Exit: 1 (under mutation, RED expected)`; `Restore: git checkout HEAD -- kit.toml`; `Verdict: PASS`
Verdict: RED-as-expected.

### The first run of this control FAILED, and that is the useful part

At cd7ad8e the same command returned `Exit: 0 (under mutation, RED expected)` and `Verdict: FAIL: test stayed green under the mutation (the check is vacuous)`.

Root cause: the probes called `kit_config_get_root` without pinning `KIT_CONFIG_ROOT`, so the resolver read the INSTALLED kit rather than the repo under test. The installed kit does not carry these keys, so every "ships as X" assertion fell through to the fallback argument, which was the expected value. Fifteen cases passed while proving nothing, and flipping the real `kit.toml` could not fail them.

Fixed in 00246d9: every probe pins `KIT_CONFIG_ROOT` at the repo under test and passes `__unset__` as the fallback, so a missing key fails loudly instead of matching by coincidence.

## Reproduce

```
git checkout 00246d9
bash tests/test-config-registry.sh
bash bin/config list | grep -E '^(ship|debug|review)\.'
```

## wrap.drain_staged (09ea0df)

The ninth knob, and the only one across `[wrap]`, `[ship]`, `[debug]` and `[review]` whose
shipped default does NOT act. The asymmetry is the point: the other eight govern finishing work
the operator already asked for, while this one starts work nobody has decided on, at the moment
the operator said to stop.

Command: `bash tests/test-config-registry.sh && bash tests/test-wrap.sh && bash tests/test-meta.sh && bash tests/test-docs-wiring.sh && bash tests/test-no-personal-paths.sh`
Exit: 0 for each suite
Output (excerpt): config-registry `41/41 passed` (38 before, 3 new); `test-wrap: all 236 passed`;
`All meta tests passed.` after regenerating `docs/FEATURES.md`; docs-wiring `25/25 passed`
Verdict: PASS

Same three cases as every other knob: it ships `false`, an operator `kit.toml` setting `true` is
honoured, a project `.kit.toml` setting `true` is ignored. The project fence matters more here
than anywhere else in the set, because this key starts an unattended agent under
`--dangerously-skip-permissions`, and a project `.kit.toml` rides inside a pull request.

## NEGATIVE CONTROL (09ea0df)

Command: `bash lib/gate/negctl.sh . "bash tests/test-config-registry.sh" "sed -i '' 's/^drain_staged = false/drain_staged = true/' kit.toml"`
Exit: 0 green before; 1 under mutation; 0 after restore
Output (excerpt): `Verdict: PASS`
Verdict: RED-as-expected. Flipping the shipped default to `true` turns the suite red, so the
default assertion reads the real file.

## What is NOT proven here

The drain path itself has never run. `wrap.drain_staged` is `false` in the shipped kit and no
staged row in this repo carries a goal pointer, so the tsv emission, the `queue run` handoff and
the pointerless-row skip are prompt text with no execution behind them. What IS proven is the
knob: its default, its precedence, and its fence. A live drain owes its own entry here, with the
journal path as the evidence.
