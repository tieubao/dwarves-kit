# Stack Report: dwarves-kit

## Languages
- **Bash**: 3.2+ (primary; macOS /bin/bash, Linux /bin/bash or later)
  - Source: lib/*/\*.sh lib modules, tests/test-\*.sh test suite, bin/\* shims
- **Python**: 3.10+ (stdlib only for most modules; DuckDB + Typer for stats)
  - Source: lib/stats/pyproject.toml, lib/sync/\*.py, lib/precedent/inventory.py, lib/webcheck/core.py, lib/session/recall/session_recall.py
- **TypeScript**: 5.4.5 (Raycast integration only, ES2021 target)
  - Source: integrations/raycast/package.json

## Frameworks
- **Bash scripting framework**: Modular lib/ layout (lib/<subsystem>/<subsystem>.sh) with bin/ shims per ADR-0034
- **CLI tools**: Typer (Python CLI framework for stats module)
- **Test framework**: Bash-based; tests/test-*.sh discovering steps from .github/workflows/test.yml (no external test runner; sh scripts with assertion helpers)
- **Data processing**: DuckDB 1.5+ (in-memory ledger projection for stats module); Python stdlib (json, sqlite, pathlib)
- **Raycast**: Extension framework (@raycast/api ^1.80.0)

## Key dependencies
- **duckdb**: 1.5+, in-memory OLAP for ledger analytics (stats module)
- **typer**: 0.12+, command-line interface generator (stats module CLI)
- **@raycast/api**: 1.80.0+, Raycast extension SDK (integrations)
- **typescript**: 5.4.5 (dev, Raycast only)
- **jq**: external binary, required for install.sh (JSON merge, settings.json wiring)
- **git**: external binary, required for install.sh and all CI workflows

## Infrastructure
- **Build**: Bash install.sh (idempotent, merges hooks into ~/.claude/settings.json, symlinks commands + skills)
- **Test**: Bash test suite; 70+ test files (test-*.sh) covering hooks, specs, proofs, classified workflows; CI runs on Ubuntu + macOS (pinned checkout@v4.1.1, setup-uv@v8.3.2)
- **Deploy**: Claude Code plugin (Raymond marketplace integration); manual `bash install.sh` or plugin marketplace (`/plugin marketplace add dwarvesf/dwarves-kit`)
- **Ledger**: append-only log (XDG shared or project-isolated per kit.toml [ledger] location)
- **No DB/cache/queue**: Stateless; one-way file reads (transcripts, configs, ledgers)

## Build & deploy
- **Build**: `bash install.sh [--with <modules>]` (modular, SPINE always, opt-in modules via kit.toml [modules])
- **Test**: `bash tests/test-*.sh` (CI runs all 65+ test scripts in parallel over matrix [ubuntu-latest, macos-latest])
- **Docs**: `bash lib/registry/feature-registry.sh generate` (regenerates docs/FEATURES.md command registry; pinned fresh by tests/test-meta.sh)
- **Deploy to Claude Code**: `bash install.sh` symlinks commands/* to ~/.claude/commands/, skills/*/ to ~/.claude/skills/; wires hooks into settings.json via jq merge
- **Install prereqs**: jq, git, uv (for lib/stats only)

