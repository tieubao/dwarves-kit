#!/usr/bin/env python3
"""propose.py -- `learn propose`: the cross-run auto-improvement distiller (SPEC-195).

A retro one layer up from /kit:retro. /kit:retro reads ONE run; this reads MANY megas'
worth of ledger telemetry, interprets the aggregate, and emits candidate BACKLOG ROWS a
human triages. It is `propose`-only (ADR-0034 decision 5): its ONLY legal sink is the
staging file. It never writes a board, never rewrites a ledger, never edits kit/skill/
CLAUDE.md. The three disciplines ARE the feature:

  - propose-only     : writes `## [staged]` blocks; a human promotes via `board promote`.
  - cite-the-number  : every block names the lens + figure + rids it rests on, and the
                       citation is REBUILT from the deterministic aggregate, NEVER taken
                       from the model (a model cannot inject a fabricated figure).
  - dedup HARD       : anchored exact-key membership vs open + staged + [expired] +
                       [rejected] rows, the cross-repo cockpit boards, and every megagoal
                       ROADMAP/TODO; a rejected proposal never reappears.

Three stages (docs/research/2026-07-05-auto-improvement-loop-design.md):

  1. AGGREGATE (deterministic, no LLM): run the `stats` lenses over a window and build a
     signal table. Each signal = {id, lens, figure, rids, detail}. Each lens fails
     independently (contributes zero signals, never aborts) -> honest-empty holds.
  2. INTERPRET (ONE `claude -p` sonnet pass): signals + board/staging -> hypotheses, each
     citing ONE signal id. Isolated behind LEARN_PROPOSE_INTERPRETER (testable). Emits a
     TOKENS marker.
  3. CHECK + WRITE: (a) deterministic grounding (cited signal must exist), (b) adversarial
     refute pass (claim-verifier pattern, refute-if-uncertain -> drop; behind
     LEARN_PROPOSE_VERIFIER; emits a TOKENS marker), (c) anchored dedup, (d) staged write.

Env / seams:
  --days N | --megas N          window (default --days 30). Best-effort: ledger start_ts
                                is sparse, so the window trims rids by count when needed.
  --staging FILE / --backlog F  override the staging + board paths.
  --dry-run                     compute + print, write nothing.
  --aggregate-file FILE         load a precomputed aggregate JSON instead of running stats
                                (test seam for stages 2-3; never used by the live run).
  LEARN_PROPOSE_INTERPRETER=CMD interpret pass (default claude -p sonnet). Reads the prompt
                                on stdin, writes hypotheses (JSON array, or a --output-format
                                json envelope) on stdout.
  LEARN_PROPOSE_VERIFIER=CMD    adversarial pass (default claude -p sonnet). Reads the prompt
                                on stdin, writes a verdict (`VERDICT: HOLDS|REFUTED`) on stdout.
  LEARN_PROPOSE_RID=STR         rid for the TOKENS markers (default: gate rid / date slug).
  BACKLOG_STAGE_STAGING / BACKLOG_STAGE_BACKLOG   staging + board defaults (shared with the
                                hook + add-backlog, so propose writes where board promote reads).
  LEARN_PROPOSE_COCKPIT         cross-repo board registry read for dedup (default
                                <repo>/_meta/boards.txt).
  LEARN_PROPOSE_MEGAGOALS       megagoal tree whose ROADMAP/TODO files join the dedup anchor
                                (default <repo>/_meta/megagoals).
  REPO_ROOT                     consumer seam for the two defaults above.
  STATS_LEARNED_MD              learned-ledger path (starvation counter; skip-safe when unset).

Stdlib only. Always exits 0 unless a bad invocation (a propose run never blocks anything).
"""
import argparse
import datetime
import json
import os
import re
import shlex
import subprocess
import sys

SELF_DIR = os.path.dirname(os.path.abspath(__file__))
KIT_ROOT = os.path.dirname(os.path.dirname(SELF_DIR))  # lib/learn -> lib -> repo root
sys.path.insert(0, SELF_DIR)
# staging-format.py is the ONE staging-block definition (ADR-0034 decision 1), shared with
# `learn drain`. Its hyphenated name is not directly importable, so load it by path, the
# same shim drain.py uses.
import importlib.util  # noqa: E402
_sf_spec = importlib.util.spec_from_file_location(
    "staging_format", os.path.join(SELF_DIR, "staging-format.py")
)
sf = importlib.util.module_from_spec(_sf_spec)
_sf_spec.loader.exec_module(sf)

DEFAULT_INTERPRETER = "claude -p --model sonnet --setting-sources project --output-format json"
DEFAULT_VERIFIER = "claude -p --model sonnet --setting-sources project --output-format json"
# The fixed set of window-aware stats lenses (subcmd, extra-args). Each is best-effort:
# a lens that errors contributes no signal. --window-days is passed where the lens takes it.
_LENSES = [
    ("anomalies", []),
    ("gate-yield", []),
    ("review-yield", []),
    ("defect-correlation", ["--window-days"]),
    ("deviation-rate", ["--window-days"]),
]


def _repo_root():
    env = os.environ.get("REPO_ROOT")
    if env:
        return env
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, timeout=5
        )
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return os.getcwd()


def _default_staging():
    return os.environ.get("BACKLOG_STAGE_STAGING") or os.path.join(
        _repo_root(), "_meta", "backlog-staging.md")


def _default_backlog():
    return os.environ.get("BACKLOG_STAGE_BACKLOG") or os.path.join(
        _repo_root(), "_meta", "BACKLOG.md")


_ROADMAP_FILES = ("ROADMAP.md", "TODO.md")


def _dedup_sources(staging, backlog):
    """The dedup anchor set: this repo's staging + board, PLUS the cross-repo cockpit
    registry and every megagoal ROADMAP/TODO under this repo.

    ID-294 measured 28 of 69 staged candidates duplicating work already tracked on exactly
    those two surfaces. The anchor read neither, so that work re-entered staging as new.
    Archived megagoals stay in the set on purpose: they hold finished work, and proposing
    finished work is the same false positive.

    LEARN_PROPOSE_COCKPIT / LEARN_PROPOSE_MEGAGOALS override the two default locations; a
    missing path contributes nothing, so a repo without either surface behaves as before.
    """
    root = _repo_root()
    sources = [("staging", staging), ("board", backlog)]
    sources.append(("cockpit", os.environ.get("LEARN_PROPOSE_COCKPIT")
                    or os.path.join(root, "_meta", "boards.txt")))
    megagoals = os.environ.get("LEARN_PROPOSE_MEGAGOALS") or os.path.join(
        root, "_meta", "megagoals")
    for dirpath, _dirs, files in os.walk(megagoals):
        for name in files:
            if name in _ROADMAP_FILES:
                sources.append(("roadmap", os.path.join(dirpath, name)))
    return sources


def _rid():
    env = os.environ.get("LEARN_PROPOSE_RID")
    if env:
        return env
    try:
        out = subprocess.run(
            ["bash", os.path.join(KIT_ROOT, "lib", "gate", "gate-ledger.sh"), "rid"],
            capture_output=True, text=True, timeout=5)
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return "learn-propose-" + datetime.date.today().isoformat()


def _stats_json(subcmd, extra):
    """Run `bin/stats <subcmd> [extra] --json`; return the parsed list, or None on any
    failure (missing uv, non-zero exit, unparseable). A failing lens contributes nothing."""
    cmd = [os.path.join(KIT_ROOT, "bin", "stats"), subcmd] + extra + ["--json"]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    try:
        val = json.loads(r.stdout or "[]")
    except json.JSONDecodeError:
        return None
    return val if isinstance(val, list) else None


def _window_rids(days, megas):
    """Best-effort window rids from kit_gates. Timestamps (start_ts) are sparse on the real
    corpus, so a --days filter is applied only where start_ts is present; otherwise the
    window trims by count (--megas, or the last `days`-implied slice is not attempted and
    all rids are covered). Returns a sorted list; [] on any failure (honest-empty)."""
    rows = _stats_query("SELECT DISTINCT rid FROM kit_gates ORDER BY rid")
    if not rows:
        return []
    rids = [str(r.get("rid")) for r in rows if r.get("rid")]
    if megas and megas > 0:
        return rids[-megas:]
    return rids


def _stats_query(sql):
    """Read-only `bin/stats query <sql> --json`. Returns a list of row dicts or None."""
    cmd = [os.path.join(KIT_ROOT, "bin", "stats"), "query", sql, "--json"]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    try:
        val = json.loads(r.stdout or "[]")
    except json.JSONDecodeError:
        return None
    return val if isinstance(val, list) else None


def _debt_count():
    """Starvation counter: `bin/learn debt list` row count. Best-effort (0 on failure)."""
    try:
        r = subprocess.run(
            [os.path.join(KIT_ROOT, "bin", "learn"), "debt", "list"],
            capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return 0
    if r.returncode != 0:
        return 0
    return sum(1 for ln in r.stdout.splitlines() if ln.strip() and not ln.strip().startswith("#"))


def _learned_ledger_stat():
    """Starvation counter: learned-ledger queued count + oldest-entry age (days). Reads
    STATS_LEARNED_MD; returns (count, oldest_age_days) or (0, None) when unset/absent."""
    path = os.environ.get("STATS_LEARNED_MD")
    if not path or not os.path.isfile(path):
        return 0, None
    dates = []
    count = 0
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                # queued entries are markdown list rows or headers carrying an ISO date.
                if re.match(r"\s*[-*]\s", line) or line.startswith("#"):
                    m = re.search(r"(\d{4}-\d{2}-\d{2})", line)
                    if m:
                        count += 1
                        try:
                            dates.append(datetime.date.fromisoformat(m.group(1)))
                        except ValueError:
                            pass
    except OSError:
        return 0, None
    if not dates:
        return count, None
    oldest = min(dates)
    return count, (datetime.date.today() - oldest).days


def build_aggregate(days, megas):
    """Stage 1: the deterministic signal table. Never raises; a broken lens yields no
    signal. Returns {"window": {...}, "signals": [{id, lens, figure, rids, detail}, ...]}."""
    rids = _window_rids(days, megas)
    signals = []

    def add(lens, figure, detail):
        if not figure:
            return
        signals.append({
            "id": f"S{len(signals) + 1}", "lens": lens,
            "figure": str(figure), "rids": rids, "detail": detail,
        })

    for subcmd, extra in _LENSES:
        args = list(extra)
        if extra == ["--window-days"]:
            args = ["--window-days", str(days)]
        rows = _stats_json(subcmd, args)
        if not rows:
            continue
        if subcmd == "anomalies":
            for a in rows:
                add(f"anomalies:{a.get('key', '?')}", a.get("metric") or a.get("title"), a)
        elif subcmd == "gate-yield":
            for g in rows:
                figure = g.get("override_pct")
                if figure not in (None, "", 0, "0"):
                    add("gate-yield", f"{g.get('gate', '?')} override_pct={figure}", g)
        else:
            # one headline signal per non-empty lens (the first row's compact form)
            head = rows[0]
            add(subcmd, "; ".join(f"{k}={v}" for k, v in head.items() if v not in (None, "")), head)

    # Surfaced counters (never processed; ID-100 owns memory repair).
    mem = _stats_json("memory-sweep", [])
    if mem:
        dead = sum(1 for m in mem if (m.get("dead_ref_count") or 0))
        stale = sum(1 for m in mem if m.get("stale") in (True, "true", "True"))
        if dead or stale:
            add("memory-sweep",
                f"{dead} memory notes reference dead paths, {stale} stale (>180d)",
                {"dead": dead, "stale": stale})

    debt = _debt_count()
    if debt:
        add("learn-debt", f"learn debt: {debt} unpaid", {"count": debt})

    lcount, loldest = _learned_ledger_stat()
    if lcount:
        oldest_s = f" oldest={loldest}d" if loldest is not None else ""
        add("learned-ledger", f"learned-ledger queued={lcount}{oldest_s}",
            {"count": lcount, "oldest_days": loldest})

    return {
        "window": {"days": days, "megas": megas, "rids": rids, "n_rids": len(rids)},
        "signals": signals,
    }


def _run_llm(cmd, prompt):
    """Run an LLM seam (interpreter/verifier). Returns (text, in_tokens, out_tokens).
    Dual-mode: if stdout parses as a `--output-format json` envelope (has "usage"), use its
    real token counts and its "result" text; else treat stdout as raw text and estimate
    tokens from chars (chars/4). Never raises."""
    try:
        r = subprocess.run(shlex.split(cmd), input=prompt, capture_output=True, text=True, timeout=180)
        raw = r.stdout or ""
    except (subprocess.SubprocessError, OSError):
        return "", 0, 0
    try:
        env = json.loads(raw)
        if isinstance(env, dict) and "usage" in env:
            usage = env.get("usage") or {}
            text = env.get("result") or ""
            return (str(text),
                    int(usage.get("input_tokens", 0) or 0),
                    int(usage.get("output_tokens", 0) or 0))
    except (json.JSONDecodeError, ValueError, TypeError):
        pass
    # raw text path (mock/plain output): estimate tokens from prompt + output chars.
    return raw, (len(prompt) + 3) // 4, (len(raw) + 3) // 4


def _emit_tokens(rid, in_tok, out_tok):
    """Emit a TOKENS marker for a pass. Best-effort; a failure never blocks the run."""
    try:
        subprocess.run(
            ["bash", os.path.join(KIT_ROOT, "lib", "gate", "gate-ledger.sh"), "tokens",
             rid, f"in={int(in_tok)}", f"out={int(out_tok)}"],
            capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        pass


def _extract_json_array(text):
    """First balanced [...] out of text (tolerates fences / prose / canary)."""
    start = text.find("[")
    if start < 0:
        return []
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "[":
            depth += 1
        elif text[i] == "]":
            depth -= 1
            if depth == 0:
                try:
                    val = json.loads(text[start:i + 1])
                    return val if isinstance(val, list) else []
                except json.JSONDecodeError:
                    return []
    return []


_INTERPRET_PROMPT = (
    "You read a WINDOW-AGGREGATE of harness telemetry (a signal table) and propose backlog "
    "items: what the DATA is telling us to fix. Output ONLY a JSON array, no prose.\n"
    "Each element:\n"
    '  {"title":"<short imperative, count-free>", "intent":"<one sentence: the outcome>", '
    '"approach":"<1-2 steps or the open question>", "u":"hi|mid|lo", "f":"hi|mid|lo", '
    '"home":"<repo guess or empty>", "signal":"<the ONE signal id this rests on, e.g. S1>"}\n'
    "HARD RULES: (1) every proposal MUST cite exactly one signal id from the table below; a "
    "proposal you cannot ground in a specific signal is noise -- omit it. (2) Do NOT propose "
    "anything already present in the board/staging list below (dedup). (3) If the table is "
    "empty or nothing warrants a proposal, output []. u=urgency, f=feasibility.\n\n"
    "=== SIGNAL TABLE (the ONLY grounding; cite a signal's id) ===\n"
)

_VERIFY_PROMPT = (
    "You are an adversarial skeptic. A proposed backlog item claims to rest on ONE telemetry "
    "signal. REFUTE the proposal if it is NOT a supported inference from that signal, is "
    "overstated, draws a conclusion the signal does not license, or you cannot verify it from "
    "the signal alone. Default to REFUTED on ANY doubt (fail-closed). Output EXACTLY one line: "
    "`VERDICT: HOLDS` or `VERDICT: REFUTED`.\n\n"
)


def interpret(aggregate, staging, backlog, rid):
    """Stage 2. Returns the list of hypothesis dicts. Emits a TOKENS marker."""
    if not aggregate["signals"]:
        return []
    table = "\n".join(
        f"{s['id']}: lens={s['lens']} figure=\"{s['figure']}\" rids={','.join(s['rids']) or '(none)'}"
        for s in aggregate["signals"])
    existing = "\n".join(sorted(sf.existing_keys(*_dedup_sources(staging, backlog)))) or "(none)"
    prompt = (_INTERPRET_PROMPT + table
              + "\n\n=== ALREADY ON BOARD / STAGED (do not re-propose) ===\n" + existing + "\n")
    cmd = os.environ.get("LEARN_PROPOSE_INTERPRETER") or DEFAULT_INTERPRETER
    text, in_tok, out_tok = _run_llm(cmd, prompt)
    _emit_tokens(rid, in_tok, out_tok)
    return [h for h in _extract_json_array(text) if isinstance(h, dict)]


def adversarial_holds(hyp, signal, rid):
    """Stage 3b. True iff the verifier does NOT refute. Fail-closed: an empty/garbled/errored
    verdict is treated as REFUTED. Emits a TOKENS marker."""
    prompt = (_VERIFY_PROMPT
              + f"PROPOSAL: {hyp.get('title', '')}\n"
              + f"  intent: {hyp.get('intent', '')}\n"
              + f"  approach: {hyp.get('approach', '')}\n"
              + f"SIGNAL {signal['id']}: lens={signal['lens']} figure=\"{signal['figure']}\" "
              + f"rids={','.join(signal['rids']) or '(none)'}\n")
    cmd = os.environ.get("LEARN_PROPOSE_VERIFIER") or DEFAULT_VERIFIER
    text, in_tok, out_tok = _run_llm(cmd, prompt)
    _emit_tokens(rid, in_tok, out_tok)
    up = text.upper()
    if "REFUTED" in up:
        return False
    if "HOLDS" in up:
        return True
    return False  # fail-closed: no clear verdict == refuted


_RIDS_SHOWN = 8  # cap the rids sample in a citation; the window can be hundreds of rids


def _citation_source(signal, date):
    """The `- Source:` line value: origin + date + the rebuilt citation (lens/figure/rids).
    ONE line (the reader's Source field is single-line). Figure is stripped of `|` and
    newlines so it can never break the block or the board row. The rids are the WINDOW the
    aggregate covers; a long window is shown as a bounded sample + count (`+N more`) so the
    citation stays readable and honest about breadth, never a hundreds-of-ids wall."""
    figure = re.sub(r"[|\n\r]", " ", signal["figure"]).strip()
    all_rids = signal.get("rids") or []
    if len(all_rids) > _RIDS_SHOWN:
        rids = ",".join(all_rids[:_RIDS_SHOWN]) + f",+{len(all_rids) - _RIDS_SHOWN} more"
    else:
        rids = ",".join(all_rids) or "(none)"
    return f'learn propose {date} | lens={signal["lens"]} figure="{figure}" rids={rids}'


# `- [ ] change -- owner: x -- deadline: y`. Only UNCHECKED boxes: a `[x]` item is already done,
# and staging it would propose work the retro says is finished. Split on ` -- ` rather than one
# clever regex: a non-greedy group with optional trailing fields backtracks into swallowing the
# whole line (it did, on the first cut), and a parser that silently keeps the metadata in the
# title is worse than one that fails.
_RETRO_ITEM = re.compile(r"^\s*[-*]\s*\[\s\]\s*(?P<body>.+?)\s*$")
_RETRO_DATE = re.compile(r"(\d{4}-\d{2}-\d{2})")


def _split_retro_item(body):
    """`change -- owner: @tieubao -- deadline: X` -> (change, owner).

    The owner is a GITHUB HANDLE, normalized to `@handle`: a proposal that reaches the board
    should name someone GitHub can @-mention, not a nickname only the author decodes. A bare
    `tieubao` gets the `@`; a template placeholder (`[person]`, `@[github-handle]`) is dropped.
    """
    parts = re.split(r"\s+--\s+|\s*,\s*(?=owner:|deadline:)", body)
    change = parts[0].strip(" .")
    owner = ""
    for p in parts[1:]:
        m = re.match(r"owner:\s*(.+)", p.strip(), re.I)
        if m:
            raw = m.group(1).strip()
            if raw.startswith("[") or raw.startswith("@["):   # unfilled template
                continue
            owner = raw if raw.startswith("@") else f"@{raw}"
    return change, owner


def parse_retro_actions(path):
    """Action items out of a RETRO doc's `## Action items` section.

    /kit:retro writes its outcomes as a checkbox list inside docs/retro/RETRO-<date>.md.
    `board promote` reads ONLY the staging buffer, so those items could never be promoted:
    a human had to retype one to act on it, and so nobody did. Same disease session-intel had
    (SPEC-200 I1/T6). This is the deterministic reader; the retro doc keeps its checkboxes as
    the READING surface, staging becomes the ACTING surface.

    Deliberately NOT done in the /kit:retro prompt: that file is markdown an LLM reads, so
    asking the model to also emit staging blocks is a promise it keeps only sometimes. A parser
    either works or fails a test.
    """
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    m = re.search(r"^##\s*Action items\s*$(.*?)(?=^##\s|\Z)", text, re.M | re.S)
    if not m:
        return []
    d = _RETRO_DATE.search(os.path.basename(path)) or _RETRO_DATE.search(text)
    date = d.group(1) if d else datetime.date.today().isoformat()
    out = []
    for line in m.group(1).splitlines():
        hit = _RETRO_ITEM.match(line)
        if not hit:
            continue
        change, owner = _split_retro_item(hit.group("body"))
        # Template placeholders (`[concrete change]`, `owner: [person]`) are not action items.
        if not change or change.startswith("[") or "concrete change" in change.lower():
            continue
        src = f"retro {date} | {os.path.basename(path)}"
        if owner and not owner.startswith("["):
            src += f" owner={owner}"
        out.append({
            "title": change,
            "intent": "Action item a retro committed to; it lived only as a checkbox nobody could promote.",
            "approach": change,
            "u": "mid", "f": "mid",
            "source": src,
        })
    return out


def run_retro(retro_path, staging, backlog, dry_run):
    """Stage a retro's action items. Deterministic: no LLM, no grounding pass, no refute.
    The items were written by a human in a retro; the evidence IS the retro."""
    cands = parse_retro_actions(retro_path)
    dedup = sf.existing_keys(*_dedup_sources(staging, backlog))
    blocks, staged, skipped = [], [], []
    for c in cands:
        key = sf.norm(c["title"])
        if not key or key in dedup:
            skipped.append(c["title"])
            continue
        block = sf.render_block(c)
        if not block:
            continue
        dedup.add(key)
        blocks.append(block)
        staged.append(c["title"])

    if blocks and not dry_run:
        header = "" if os.path.isfile(staging) else (
            "# Backlog staging (auto, via learn propose)\n\n"
            "Candidates auto-extracted from the ledger. Review + promote by hand "
            "(`board promote`).\nGitignored: may name unfiled work. NEVER the source of truth.\n\n"
        )
        os.makedirs(os.path.dirname(staging) or ".", exist_ok=True)
        with open(staging, "a", encoding="utf-8") as fh:
            fh.write(header + "".join(blocks))

    if dry_run:
        sys.stdout.write("".join(blocks) or "learn propose --retro: nothing new to stage\n")
        return 0
    print(f"learn propose --retro: {len(cands)} action item{'s' if len(cands) != 1 else ''} read, "
          f"{len(staged)} staged, {len(skipped)} duplicate -> "
          f"{staging if blocks else '(nothing new)'}\n"
          f"  review with: learn drain   promote with: board promote <n>")
    return 0


def run(days, megas, staging, backlog, dry_run, aggregate_file):
    date = datetime.date.today().isoformat()
    rid = _rid()

    if aggregate_file:
        with open(aggregate_file, encoding="utf-8") as fh:
            aggregate = json.load(fh)
    else:
        aggregate = build_aggregate(days, megas)

    by_id = {s["id"]: s for s in aggregate["signals"]}
    hypotheses = interpret(aggregate, staging, backlog, rid)

    dedup = sf.existing_keys(*_dedup_sources(staging, backlog))
    staged_blocks = []
    dropped = {"ungrounded": 0, "refuted": 0, "duplicate": 0}

    # Order: grounding -> dedup -> adversarial -> write. Grounding and dedup are the cheap
    # deterministic anchors; running the (per-hypothesis) adversarial LLM pass only on
    # survivors keeps the weekly cycle's spend minimal (a duplicate never burns a call).
    for hyp in hypotheses:
        signal = by_id.get(str(hyp.get("signal", "")))
        if signal is None or not signal.get("figure"):  # (3a) deterministic grounding
            # a cited id that is absent, OR present-but-figure-empty, is not evidence.
            dropped["ungrounded"] += 1
            continue
        key = sf.norm(hyp.get("title", ""))               # (3b) anchored dedup (cheap)
        if not key or key in dedup:
            dropped["duplicate"] += 1
            continue
        if not adversarial_holds(hyp, signal, rid):       # (3c) adversarial refute (LLM)
            dropped["refuted"] += 1
            continue
        block = sf.render_block({
            "title": hyp.get("title", ""),
            "intent": hyp.get("intent", ""),
            "approach": hyp.get("approach", ""),
            "u": hyp.get("u"), "f": hyp.get("f"), "home": hyp.get("home", ""),
            "source": _citation_source(signal, date),
        })
        if block:
            staged_blocks.append(block)
            dedup.add(key)  # dedup within this batch too

    n = len(staged_blocks)
    if staged_blocks and not dry_run:                     # (3d) staged write
        header = "" if os.path.isfile(staging) else (
            "# Backlog staging (auto, via learn propose)\n\n"
            "Candidates auto-extracted from the ledger. Review + promote by hand "
            "(`board promote`).\nGitignored: may name unfiled work. NEVER the source of truth.\n\n"
        )
        os.makedirs(os.path.dirname(staging) or ".", exist_ok=True)
        with open(staging, "a", encoding="utf-8") as fh:
            fh.write(header + "".join(staged_blocks))

    print(f"learn propose: {len(aggregate['signals'])} signals over "
          f"{aggregate['window']['n_rids']} rids -> {len(hypotheses)} hypotheses -> "
          f"{n} candidate{'s' if n != 1 else ''} staged "
          f"(dropped: {dropped['ungrounded']} ungrounded, {dropped['refuted']} refuted, "
          f"{dropped['duplicate']} duplicate)"
          + (" [dry-run]" if dry_run else ""))
    if n == 0:
        print("learn propose: 0 candidates" + (" (empty window)" if not aggregate["signals"] else ""))
    return 0


def main(argv):
    p = argparse.ArgumentParser(prog="learn propose", description="cross-run backlog proposer (SPEC-195)")
    g = p.add_mutually_exclusive_group()
    g.add_argument("--days", type=int, default=30, help="window in days (default 30)")
    g.add_argument("--megas", type=int, help="window as the last N run-ids")
    p.add_argument("--staging", help="staging file (default <repo>/_meta/backlog-staging.md)")
    p.add_argument("--backlog", help="board file (default <repo>/_meta/BACKLOG.md)")
    p.add_argument("--dry-run", action="store_true", help="compute + print, write nothing")
    p.add_argument("--aggregate-file", help="load a precomputed aggregate JSON (test seam)")
    p.add_argument("--retro", metavar="FILE",
                   help="stage a RETRO doc's `## Action items` instead of the ledger window "
                        "(deterministic: no LLM pass, the retro IS the evidence)")
    args = p.parse_args(argv)
    staging = args.staging or _default_staging()
    backlog = args.backlog or _default_backlog()
    if args.retro:
        # Same verb (SPEC-200 I4: `propose` = stage proposals); the flag names the SOURCE.
        return run_retro(args.retro, staging, backlog, args.dry_run)
    return run(
        days=args.days, megas=args.megas,
        staging=staging, backlog=backlog,
        dry_run=args.dry_run, aggregate_file=args.aggregate_file,
    )


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(130)
