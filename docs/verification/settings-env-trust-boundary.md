# Investigation: can a repo-committed `.claude/settings.json` env block reach a hook subprocess?

**Verdict: YES, and the exposure is wider than the question assumed.** A project-level
`.claude/settings.json` sets environment variables for hook subprocesses, overrides a value the
operator exported in their own shell, and registers hook commands that run without any approval
step. Measured on Claude Code 2.1.265, macOS.

This is an INVESTIGATION record. It changes no boundary and no code. It answers ID-474 and
supersedes the "caps what the operator tier is worth" caveat the reverted cloud module carried.

## The question

Two independent reviews of the reverted cloud module flagged that its operator/project config
tier split sits BELOW an environment tier. If a repo-committed settings file can set env for a
hook subprocess, a pull request sets `CLOUD_PROVISION=1` plus an operator key and bypasses the
split. Neither review could answer it without a real session. The question is kit-wide: every
kit hook reads env, so this bounds what any config tier split in the kit is worth.

## Method

A throwaway git repo, never opened before, holding one `.claude/settings.json` that declares an
`env` block and three hooks pointing at a probe script. The probe appends the values it sees to
a file. Nothing else is in the repo. Each run starts from a clean environment (`env -u`) so an
inherited value cannot be mistaken for a delivered one.

```
.claude/settings.json
  env:   KIT_TRUST_PROBE=reached-from-project-settings, CLOUD_PROVISION=1
  hooks: SessionStart, UserPromptSubmit, PreToolUse(Bash) -> probe.sh
```

## Runs

| # | Command | Result |
|---|---|---|
| 1 | `claude -p '... printenv KIT_TRUST_PROBE ...' --setting-sources project --allowedTools Bash` | all three hooks ran; each saw `KIT_TRUST_PROBE=reached-from-project-settings` and `CLOUD_PROVISION=1`; the Bash tool printed the same value |
| 2 | same, NO `--setting-sources` flag, in a second never-before-opened repo | identical: all three hooks ran, both env keys delivered, no trust prompt |
| 3 | `KIT_TRUST_PROBE=operator-ambient-value claude -p '...'` | hooks saw `reached-from-project-settings`, NOT the operator's ambient value |
| 4 | `claude -p '...' --setting-sources user` | no probe file written: the project hooks never ran |

Run 2 output, verbatim:

```
hook_ran=SessionStart
  KIT_TRUST_PROBE=reached-from-project-settings
  CLOUD_PROVISION=1
hook_ran=UserPromptSubmit
  KIT_TRUST_PROBE=reached-from-project-settings
  CLOUD_PROVISION=1
hook_ran=PreToolUse
  KIT_TRUST_PROBE=reached-from-project-settings
  CLOUD_PROVISION=1
```

Run 3 is the sharpest of the four. The operator exported a value in their own shell and the
repo's file won. A project settings file does not merely fill an unset variable, it displaces
an operator-set one.

## What the documentation says

Claude Code's own settings and permissions documentation matches the measurement. Precedence
runs managed settings, then command line arguments, then `.claude/settings.local.json`, then
`.claude/settings.json`, then `~/.claude/settings.json`, so a project source outranks a user
source. The permissions page carries a "what runs before you trust a folder" table listing
hooks and the `env` block as USED both when only a parent folder was trusted and in `claude -p`
sessions where the folder was never trusted. Only `permissions.allow` rules wait for the trust
dialog. The documentation does not state a rationale for that split.

## Reading

The config tier split was never the boundary. The stronger framing in the ID-474 row is the
correct one, and the measurement confirms it: a pull request that can write `.claude/settings.json`
already registers arbitrary hook commands that run on the reviewer's machine. Setting an env var
is the smaller half of that capability. Any kit config split that a hook enforces is defense in
depth against an honest mistake, never a boundary against a hostile pull request.

That reframes what a fix would have to be. Hardening the kit's own env reads cannot help, because
the attacker's hook is not the kit's hook. The only controls that bite sit above the kit:

- `--setting-sources user`, proven by run 4, excludes project settings entirely. It is per
  invocation, so it protects a scripted run and not an operator's habitual session.
- Managed enterprise settings expose `allowManagedHooksOnly` and `allowManagedPermissionRulesOnly`,
  which the documentation says block user, project, local, and plugin hooks. Untested here.
- Reviewing `.claude/settings.json` in a pull request diff before checking the branch out. This is
  the only control available to a solo operator today, and it is procedural.

## What remains unknown

State these before quoting this verdict anywhere.

1. **Interactive mode is untested.** All four runs are headless `claude -p`. An interactive
   session shows a workspace trust dialog that headless mode never shows. Whether declining it
   stops the `env` block and the hooks is not measured here. The documentation implies hooks and
   `env` run before that dialog, but implication is not measurement.
2. **One version, one platform.** Claude Code 2.1.265 on macOS. This is harness behavior, not kit
   behavior, so it can change in any release without a kit change.
3. **Managed settings untested.** The two managed keys above are quoted from documentation. No run
   here exercised them, so their real blast radius is unverified.
4. **A cloud VM was never used.** The original question named a cloud VM. Runs 1 to 4 are local. A
   VM adds a provisioning path but cannot make the local answer less true, so the finding holds a
   fortiori; the VM-specific surface is still unmeasured.
5. **`settings.local.json` precedence is untested.** It outranks `settings.json` per the docs and
   is normally gitignored, so it was out of scope. A repo that commits one would rank higher still.

## Reproduce

```bash
d=$(mktemp -d); mkdir -p "$d/.claude"; cd "$d"; git init -q
cat > probe.sh <<'EOF'
#!/bin/bash
cat >/dev/null
{ echo "hook_ran=${1:-unknown}"; echo "  KIT_TRUST_PROBE=${KIT_TRUST_PROBE:-UNSET}"; } >> "$(dirname "$0")/probe-result.txt"
EOF
chmod +x probe.sh
cat > .claude/settings.json <<EOF
{"env":{"KIT_TRUST_PROBE":"reached-from-project-settings"},
 "hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"$d/probe.sh SessionStart"}]}]}}
EOF
KIT_TRUST_PROBE=operator-ambient-value claude -p 'reply with the single word ok' --model haiku
cat probe-result.txt   # expect: reached-from-project-settings
```

Negative control for the same fixture: re-run with `--setting-sources user`. No probe file
appears, because the project hook never runs.
