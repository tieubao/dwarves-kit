# Proof of done: money-gate + prose-rag fold (kit-foldin completion)

Change under proof (the 2026-07-05 "stays personal" disposition was overruled
2026-07-11: the engines are generic, only their DEFAULTS were personal):

1. `hooks/money-gate.{sh,py}` , function-named port of ops-toolkit's money guard.
   Kit naming on entry: env knobs are `MONEY_GATE_REPOS` / `MONEY_GATE_STRICT` /
   `MONEY_GATE_LOG` (host-agent `CC_` prefix dropped). Genericized: no default
   repo list; INERT unless the consumer sets `MONEY_GATE_REPOS` (adapter-default
   invariant, the kit ships no tenant repo names and no tenant vendor keywords).
   Module `money_gate` (PreToolUse `Edit|Write|MultiEdit`).
Superseded on the prose-rag half by the adapter (SPEC-250): the folded-in crate is
retired and the engine binary now comes from context-kit, so the build and cargo-test
lines below are historical.

2. `lib/prose-rag/` , fold of the semantic-recall engine, **Rust only** (the
   Python/fastembed engine was dropped at the fold: strictly slower on every
   axis, and one engine is one truth). Genericized: corpus comes from
   `PROSE_RAG_CORPUS` (colon-separated, `~/` expands); unset = empty corpus.
   Module `prose_rag`: dormant UserPromptSubmit hook (`hooks/prose-rag.sh`,
   activates only with `PROSE_RAG_INJECT=1`) + `prose-rag` CLI shim via the
   SPEC-184 stable entrypoint `bin/prose-rag` (`hook` with no engine built exits
   0, never breaks a prompt).
3. Wiring: kit `settings.json` (+2 gated hooks), `kit.toml` rows, README module
   table, `test-install-modules.sh` UNWANTED list, `test-install-clis.sh`
   extension, `test-hooks.sh` hook-count pin 22 -> 24.

## Confirmation run-table

| # | Check | Command | Result | Verdict |
|---|---|---|---|---|
| 1 | money-gate behavior (7 checks incl. 3 NCs, one NEW: inert-without-config) | `bash tests/test-money-gate.sh` | all 7 passed | PASS |
| 2 | prose-rag Rust suite (genericized corpus) | `cd lib/prose-rag/rust && cargo test --release` | 10 passed, 0 failed | PASS |
| 3 | prose-rag Rust CLI smoke | `bash lib/prose-rag/rust/tests/smoke.sh` | all 13 passed | PASS |
| 4 | installer CLI/hook wiring incl. new modules | `bash tests/test-install-clis.sh` | all 26 passed | PASS |
| 5 | module machinery | `bash tests/test-install-modules.sh` | 37 passed, 0 failed | PASS |
| 6 | full hooks suite | `bash tests/test-hooks.sh` | 453 / 453 | PASS |
| 7 | compat + contract installs | `bash tests/test-install-compat.sh; bash tests/test-install-contract.sh` | PASS; 4/4 | PASS |
| 8 | dormant hook shims cost ~0 | `echo '{}' \| hooks/prose-rag.sh` (no PROSE_RAG_INJECT); money-gate without MONEY_GATE_REPOS | both exit 0 silent | PASS |
| 9 | unbuilt-engine fail-open | fresh-HOME shim: `prose-rag hook` with no Rust binary | exit 0 | PASS |

## Negative controls

- `tests/test-money-gate.sh` [4][5][6]: no fire on a non-money edit; no fire
  outside named repos; **inert with `MONEY_GATE_REPOS` unset** (the kit-default
  state).
- `tests/test-install-clis.sh`: spine-only install exposes neither hook nor shim;
  user-owned files never clobbered.
- Tenant-leak grep over the folded code paths (personal workspace paths, tenant
  repo names, tenant vendor keywords) -> no hits; historical SPEC and
  implementation-notes keep their original context as records, with a
  supersession note on the SPEC.

## Reproduce

```
bash tests/test-money-gate.sh
bash tests/test-install-clis.sh
(cd lib/prose-rag/rust && cargo test --release)
bash lib/prose-rag/rust/tests/smoke.sh
bash tests/test-hooks.sh
```
