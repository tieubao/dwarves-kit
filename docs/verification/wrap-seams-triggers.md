# Proof of done: the `wrap.after` seam and the required `**Seam:**` line

Branch `feat/wrap-seams-triggers`. Behavioral surface: `lib/wrap/report-lint.sh` gains a
required `**Seam:**` line, `lib/config/module-registry.md` gains a `wrap.after` seam row, and
`kit.toml` declares the key.

## Runs

| # | Command | Exit | Verdict |
|---|---|---|---|
| 1 | `bash tests/run-all.sh` | 0 | PASS |
| 2 | `bash tests/test-wrap.sh` | 0 | PASS (236 + 6 new lint cases) |
| 3 | `bash tests/test-config-seams.sh` | 0 | PASS (six seam rows, was five) |
| 4 | `bash bin/config seams` | 0 | PASS (`wrap.after` resolves, `default`) |

Run 4 output, the two seam rows:

```
KEY                            KIND       VALUE                          STATUS
wrap.before                    skill      learning-ledger                filled
wrap.after                     skill      (empty)                        default
```

`wrap.before` reads `filled` because this machine's operator `kit.toml` still names the flush
on that side. The flip to `after` is a dotfiles change, not this branch's.

## Negative control

```
## Negative control (negctl)
Command: bash tests/test-wrap.sh
Exit: 0 (green before mutation)
Mutation: sed -i '' s/Seam/Seamz/g lib/wrap/report-lint.sh
Changed: lib/wrap/report-lint.sh
Exit: 1 (under mutation, RED expected)
Restore: git checkout HEAD -- lib/wrap/report-lint.sh
Exit: 0 (green after restore)
Verdict: PASS
```

Reproduce:

```bash
bash lib/gate/negctl.sh . "bash tests/test-wrap.sh" "sed -i '' s/Seam/Seamz/g lib/wrap/report-lint.sh"
```

The mutation breaks the pattern the lint matches, so every fixture carrying a `**Seam:**` line
reads as missing one and the three new cases plus the shared fixtures go red. Restoring the
file returns the suite to green in the same run, so the RED belongs to the rule and not to a
dirty tree.

## Not proven here

The `wrap.after` invocation itself is command prose in `commands/wrap.md`, executed by the
model at step 8b. No test drives it, the same as every other step in that file. What the tests
cover is the config key resolving and the report line the step owes.
