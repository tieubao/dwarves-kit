#!/usr/bin/env python3
"""backlog-stage.py: SessionEnd hook that stages backlog candidates from a session.

Ported from ops-toolkit's cc-backlog (function-named per the kit-foldin design note:
no host-agent prefix, was cc-backlog). A harvest applied to a project board instead of
a knowledge ledger. When a session ends, the action-items the user stated but did not
dictate onto the board are easy to lose. This hook reads the transcript, asks a cheap
Claude model (Haiku) to extract the genuine forward-looking work-items, dedups them
against the live board + the staging buffer, and appends ONLY the new ones to a
staging file as `[staged]` candidates.

It NEVER writes the board directly. The human gate stays: this auto-STAGES; a human
(or a separate promote tool, out of scope here) flushes chosen candidates onto the
real board with real IDs. (Propose-don't-dispose.)

The LLM call is isolated behind BACKLOG_STAGE_EXTRACTOR (a shell command that reads
the prompt on stdin and writes a JSON array on stdout), so the dedup/append logic is
testable without a live model. Default: `claude -p --model haiku --setting-sources
project`. The `--setting-sources project` is load-bearing: it stops the spawned
extractor from loading the USER settings.json (where this hook lives), so it cannot
re-fire SessionEnd and recurse.

Consumer seam (no hardcoded tenant path; per kit-foldin DECISIONS.md): the board and
staging file default REPO-RELATIVE under `_meta/`, resolved from REPO_ROOT (env) else
`git rev-parse --show-toplevel` else $PWD, mirroring lib/board/board.sh's own
`_default_repo_root`/`_resolve_repo_root` precedent for the same `_meta/BACKLOG.md`
convention. There is no ops-toolkit-specific fallback.

Env:
  BACKLOG_STAGE_BACKLOG=FILE    board to dedup against (default <repo-root>/_meta/BACKLOG.md)
  BACKLOG_STAGE_STAGING=FILE    staging buffer (default <repo-root>/_meta/backlog-staging.md)
  REPO_ROOT=DIR                 consumer seam for the two defaults above
  BACKLOG_STAGE_EXTRACTOR=CMD   override the LLM call (tests)
  BACKLOG_STAGE_MAXCHARS=N      transcript chars sent to the model (default 12000)
  BACKLOG_STAGE_MIN_INTERVAL=S  rate-limit to at most once per S seconds (default 3600). 0 off.
  BACKLOG_STAGE_STATE_DIR=DIR   throttle lock dir, AND the detached-child payload
                                handoff dir (default ~/.claude/dwarves-kit/state/backlog-stage)
  BACKLOG_STAGE_PREFILTER=0     disable the deterministic forward-intent pre-filter (default on)
  BACKLOG_STAGE_SYNC=1          run the extractor call + append INLINE instead of detached
                                (test seam, deterministic; default OFF = detached)

This hook is invoked ONLY from SessionEnd, which fires while the CLI process is
already tearing down -- and the `claude -p` extractor call it makes can take up to its
own 120s budget, well past the SessionEnd hook's own declared timeout (30s in this
kit's hooks.json). Either factor alone can get the invocation killed before it writes
anything. So the fast synchronous part (throttle + prefilter, both cheap/local) runs
inline, then the slow part (the extractor call + dedup + append) is handed to a
detached child (`--staged-run`, via `_spawn_staged_detached`, the same detach pattern
harvest.py's `_spawn_detached` uses for `--stop-trigger`) that outlives both the hook's
timeout and the parent's exit.
BACKLOG_STAGE_SYNC=1 opts back into the old inline behavior (used by test fixtures).

Stdlib only. Always exits 0 (a harvest never blocks a session end).
"""
import json
import os
import re
import shlex
import subprocess
import sys
import time

DEFAULT_EXTRACTOR = "claude -p --model haiku --setting-sources project"
DEFAULT_STATE_DIR = os.path.expanduser("~/.claude/dwarves-kit/state/backlog-stage")
SECTION = "### Conversation intake (backlog-stage)"


def _repo_root():
    """REPO_ROOT env wins; else git top-level; else cwd. Mirrors lib/board/board.sh's
    _default_repo_root/_resolve_repo_root precedent -- no invented tenant var."""
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


def _default_backlog():
    return os.path.join(_repo_root(), "_meta", "BACKLOG.md")


def _default_staging():
    return os.path.join(_repo_root(), "_meta", "backlog-staging.md")


PROMPT_HEAD = (
    "You extract FORWARD-LOOKING work-items from a coding/ops session transcript: things the user "
    "said they want to DO LATER but did not necessarily file yet.\n"
    "Output ONLY a JSON array, no prose. Each element:\n"
    '  {"title": "<short imperative title>", "intent": "<one sentence: the outcome wanted>", '
    '"approach": "<1-2 key steps or the open question>", "u": "hi|mid|lo", "f": "hi|mid|lo", '
    '"home": "<repo/tool guess or empty>"}\n'
    "Include ONLY items with explicit forward intent (add to backlog, we should, let's later, TODO, "
    "next time, remind me to, follow up). EXCLUDE: things already done this session, idle musings, "
    "questions, and anything already obviously tracked. If there is nothing, output []. "
    "u=urgency (cost of delay), f=feasibility (doable now). Transcript follows:\n\n"
)


def read_payload():
    try:
        return json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return {}


def transcript_text(path, max_chars):
    """User+assistant text blocks, most-recent-kept up to max_chars."""
    parts = []
    try:
        fh = open(path, encoding="utf-8")
    except OSError:
        return ""
    with fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except json.JSONDecodeError:
                continue
            if o.get("type") not in ("user", "assistant"):
                continue
            for b in (o.get("message") or {}).get("content", []) or []:
                if isinstance(b, dict) and b.get("type") == "text" and b.get("text"):
                    parts.append(b["text"])
    text = "\n".join(parts)
    return text[-max_chars:] if len(text) > max_chars else text


def run_extractor(prompt):
    cmd = os.environ.get("BACKLOG_STAGE_EXTRACTOR") or DEFAULT_EXTRACTOR
    # No shell: prompt on stdin, command split with shlex so transcript content can never be
    # interpreted as a shell metacharacter.
    try:
        r = subprocess.run(shlex.split(cmd), input=prompt, capture_output=True, text=True, timeout=120)
        return r.stdout
    except (subprocess.SubprocessError, OSError):
        return ""


def extract_json_array(text):
    """First balanced [...] out of model output (tolerates fences/canary/prose)."""
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
                    val = json.loads(text[start : i + 1])
                    return val if isinstance(val, list) else []
                except json.JSONDecodeError:
                    return []
    return []


def norm(s):
    """Normalize a title for dedup: casefolded word runs in any script (keep equal to staging-format.norm)."""
    return " ".join(re.findall(r"[^\W_]+", str(s).casefold()))


def existing_titles(backlog, staging):
    """Normalized titles already on the board (Item col) or already staged."""
    titles = set()
    if os.path.isfile(backlog):
        for line in open(backlog, encoding="utf-8"):
            # board rows: | ID-NNN | Item | Notes | Status |
            m = re.match(r"\s*\|\s*[A-Z]+-\d+\s*\|\s*([^|]+)\|", line)
            if m:
                titles.add(norm(m.group(1)))
    if os.path.isfile(staging):
        for line in open(staging, encoding="utf-8"):
            m = re.match(r"##\s*\[[^\]]+\]\s*(.+)", line)
            if m:
                titles.add(norm(m.group(1)))
    return titles


def throttled(state_dir):
    """True if a harvest ran within BACKLOG_STAGE_MIN_INTERVAL seconds. Bookkeeping errors
    never block (returns False)."""
    try:
        interval = int(os.environ.get("BACKLOG_STAGE_MIN_INTERVAL", "3600"))
    except ValueError:
        interval = 3600
    if interval <= 0:
        return False
    stamp = os.path.join(state_dir, "last-run")
    try:
        os.makedirs(state_dir, exist_ok=True)
        if os.path.isfile(stamp) and (time.time() - os.path.getmtime(stamp)) < interval:
            return True
        open(stamp, "w").close()
        os.utime(stamp, None)
    except OSError:
        return False
    return False


def _staging_format():
    """The kit's ONE staging-block grammar (ADR-0034 decision 1 / SPEC-200 I1)."""
    import importlib.util
    here = os.path.dirname(os.path.realpath(__file__))
    path = os.path.join(here, "..", "lib", "learn", "staging-format.py")
    spec = importlib.util.spec_from_file_location("staging_format", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def render_candidate(c, date):
    """Delegates to the ONE renderer. This function KEPT ITS OWN COPY of the block grammar
    until 2026-07-15, and the copy had already drifted into a live hole: the shared renderer
    collapses whitespace per field (added when these fields started carrying LLM-extracted
    transcript text), this copy did a bare .strip(), so an embedded newline survived into a
    line-oriented grammar and FORGED A SECOND STAGED BLOCK. One candidate in, two proposals
    out, and the forged one was indistinguishable from a real one to `board promote`.

    A copy of a shared grammar is not a copy for long. Same bug class as the hand-list beside
    a deriving resolver, and as the second Python implementation of the ledger-root chain.
    """
    sf = _staging_format()
    return sf.render_block({
        "title": c.get("title", ""),
        "intent": c.get("intent", ""),
        "approach": c.get("approach", ""),
        "u": c.get("u", "lo"),
        "f": c.get("f", "mid"),
        "home": c.get("home", ""),
        "source": f"session {date}",
    })


# Deterministic pre-filter: forward-intent markers. If a transcript has NONE of these, it has no
# "do this later" signal, so the model call is skipped entirely (saves a model invocation + quota).
# Generous + biased to NOT skip: bare "should"/"later" are excluded (too common); multi-word
# deferral phrases + strong singles only. Set BACKLOG_STAGE_PREFILTER=0 to disable.
INTENT_RE = re.compile(
    r"\b(?:to-?do|backlog|we should|i should|should we|let'?s\b|next time|follow[- ]?up|"
    r"remind me|reminder|need to|have to|going to|gonna|plan to|want to|in the future|"
    r"revisit|circle back|action item|down the line|later on|come back to|for later)\b",
    re.IGNORECASE,
)


def has_intent(text):
    """True if the transcript shows any forward-looking 'do this later' signal."""
    return bool(INTENT_RE.search(text))


def surface():
    """SessionStart surfacing (not wired by default): print one line if candidates are
    waiting for review. Fast + synchronous (no model call)."""
    staging = os.environ.get("BACKLOG_STAGE_STAGING", _default_staging())
    if not os.path.isfile(staging):
        return 0
    n = sum(1 for line in open(staging, encoding="utf-8") if line.startswith("## [staged]"))
    if n:
        s = "s" if n != 1 else ""
        print(f"\U0001F4CB {n} backlog candidate{s} staged in {staging}.")
    return 0


def _truthy(v):
    return str(v or "").strip().lower() in ("1", "true", "yes", "on")


def stage_from_text(text, date, backlog, staging):
    """The slow half: the `claude -p` extractor call, dedup against the live board +
    staging buffer, and the append. Runs in a detached child by default (see main()) --
    the fast synchronous half (throttle + prefilter) already decided a model call is
    warranted before this is ever reached."""
    candidates = extract_json_array(run_extractor(PROMPT_HEAD + text))
    if not candidates:
        return

    known = existing_titles(backlog, staging)
    new_blocks = []
    for c in candidates:
        if not isinstance(c, dict):
            continue
        if norm(c.get("title", "")) in known or not norm(c.get("title", "")):
            continue
        block = render_candidate(c, date)
        if block:
            new_blocks.append(block)
            known.add(norm(c.get("title", "")))  # dedup within this batch too

    if new_blocks:
        header = "" if os.path.isfile(staging) else (
            "# Backlog staging (auto, via backlog-stage)\n\n"
            "Candidates auto-extracted from sessions. Review + promote by hand.\n"
            "Gitignored: may name unfiled work. NEVER the source of truth.\n\n"
        )
        os.makedirs(os.path.dirname(staging), exist_ok=True)
        with open(staging, "a", encoding="utf-8") as fh:
            fh.write(header + "".join(new_blocks))


def _spawn_staged_detached(data, sdir):
    """Write the (text, date, backlog, staging) handoff to a state-dir file and spawn a
    detached child (start_new_session) that re-invokes this script as
    `--staged-run <payload-file>`, then return immediately. A `claude -p` extractor call
    can take up to its own 120s budget, well past the SessionEnd hook's own timeout, and
    SessionEnd fires while the CLI process is already tearing down -- so the parent must
    not wait on it. Same shape as harvest.py's _spawn_detached, but a distinct name +
    2-arg signature (this file has only one detach mode, so no mode_flag parameter) --
    named differently on purpose so the two are never mistaken for interchangeable
    copies of the same interface. Returns True on success.

    If Popen itself fails AFTER the payload file was already written, there is no child
    left to clean it up -- remove it here so a spawn failure never leaks a payload file."""
    pf = None
    try:
        os.makedirs(sdir, exist_ok=True)
        pf = os.path.join(sdir, f"payload-{os.getpid()}.json")
        with open(pf, "w") as fh:
            json.dump(data, fh)
        subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "--staged-run", pf],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,  # detach from the hook's process group; survives session end
        )
    except OSError:
        if pf:
            try:
                os.remove(pf)
            except OSError:
                pass
        return False
    return True


def cmd_staged_run(pf):
    """Internal: the detached child spawned by main(). Reads the handed-off
    (text, date, backlog, staging) payload, runs stage_from_text, ALWAYS removes the
    payload file afterward -- whether the read, stage_from_text, or nothing at all
    failed (a corrupt/truncated payload previously leaked the file forever, since the
    old finally only wrapped the second try)."""
    try:
        try:
            data = json.load(open(pf))
        except (OSError, ValueError):
            return 0
        stage_from_text(data["text"], data["date"], data["backlog"], data["staging"])
    finally:
        try:
            os.remove(pf)
        except OSError:
            pass
    return 0


def main():
    if "--surface" in sys.argv[1:]:
        return surface()
    if "--staged-run" in sys.argv[1:]:
        i = sys.argv.index("--staged-run")
        return cmd_staged_run(sys.argv[i + 1] if i + 1 < len(sys.argv) else "")

    payload = read_payload()
    tp = payload.get("transcript_path")
    if not tp:
        return 0  # no transcript, nothing to do

    state_dir = os.environ.get("BACKLOG_STAGE_STATE_DIR", DEFAULT_STATE_DIR)
    if throttled(state_dir):
        return 0

    backlog = os.environ.get("BACKLOG_STAGE_BACKLOG", _default_backlog())
    staging = os.environ.get("BACKLOG_STAGE_STAGING", _default_staging())

    text = transcript_text(tp, int(os.environ.get("BACKLOG_STAGE_MAXCHARS", "12000")))
    if not text.strip():
        return 0

    # Skip the model call on sessions with no forward-intent signal (deterministic gate).
    if os.environ.get("BACKLOG_STAGE_PREFILTER", "1") != "0" and not has_intent(text):
        return 0

    date = payload.get("_today") or time.strftime("%Y-%m-%d")

    if _truthy(os.environ.get("BACKLOG_STAGE_SYNC")):
        stage_from_text(text, date, backlog, staging)
        return 0

    data = {"text": text, "date": date, "backlog": backlog, "staging": staging}
    if _spawn_staged_detached(data, state_dir):
        print(f"backlog-stage: fired detached (candidates land in {staging} after this hook returns)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)  # a harvest never blocks a session end
