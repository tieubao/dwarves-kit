#!/usr/bin/env python3
"""staging-format.py -- the ONE definition of the `_meta/backlog-staging.md` block grammar
(SPEC-196/SPEC-195, ADR-0034 decision 1: shared by `learn drain` and `learn propose`, landed
by whichever of the two sub-goals merges first; SG-06 landed it -- SG-05's `staging-format*`
did not exist yet on this branch's history).

Three verbs on the CLI: `parse <file>` (read blocks back as JSON), `render` (render one
candidate from stdin JSON), and `stage` (the one staging WRITER: dedupe + render + append
in a single process, used directly and by `wrap stage`, SPEC-249 TASK-003/004).

A staging file is a sequence of `## [<state>] <title>` blocks, each followed by `- Field:
value` lines (Intent, Approach, Tags, Home, Source, ...). This mirrors
`lib/board/bin/add-backlog`'s private `parse_staging()` (that reader is settled, working, and
NOT on this sub-goal's touch list -- it keeps its own copy for now; a future cleanup can point
it at this module instead of maintaining the grammar twice).

Filename is deliberately hyphenated (matches the `staging-format*` file-fence token both
sub-goal files use); a plain `import staging_format` cannot see it, so importers load it via
`importlib.util.spec_from_file_location` (see `drain.py`).

Stdlib only.
"""
import json
import sys
import re
from datetime import date, datetime

# A block starts at a line beginning with '## [' -- the one boundary definition every reader
# (drain, propose, and eventually add-backlog) must agree on.
_BLOCK_START_RE = re.compile(r"(?m)^##\s*\[")
_HEAD_RE = re.compile(r"##\s*\[([^\]]+)\]\s*(.+)")
_FIELD_RE = re.compile(r"(?m)^-\s*([A-Za-z]+):\s*(.+)$")
_SOURCE_DATE_RE = re.compile(r"(\d{4}-\d{2}-\d{2})")


def parse_blocks(text):
    """Return an ordered list of dicts (file order preserved, never re-sorted here):
    {raw, start, end, state, title, fields}. `state` is the bracket token
    ('staged' | 'expired' | 'rejected' | 'promoted ID-NNN' | ...), `fields` is a dict of the
    block's `- Field: value` lines (last write wins per key, same as `dict(re.findall(...))`)."""
    blocks = []
    idxs = [m.start() for m in _BLOCK_START_RE.finditer(text)]
    for i, s in enumerate(idxs):
        e = idxs[i + 1] if i + 1 < len(idxs) else len(text)
        raw = text[s:e]
        head = _HEAD_RE.match(raw)
        if not head:
            continue
        fields = dict(_FIELD_RE.findall(raw))
        blocks.append(
            {
                "raw": raw,
                "start": s,
                "end": e,
                "state": head.group(1).strip(),
                "title": head.group(2).strip(),
                "fields": fields,
            }
        )
    return blocks


def source_date(fields):
    """Best-effort `date.date` parsed out of the `Source` field (e.g. 'session 2026-06-29').
    None if missing/unparseable -- callers must treat that as "age unknown", never 0."""
    src = fields.get("Source", "")
    m = _SOURCE_DATE_RE.search(src)
    if not m:
        return None
    try:
        return datetime.strptime(m.group(1), "%Y-%m-%d").date()
    except ValueError:
        return None


def age_days(fields, today=None):
    """Whole days between `today` (default: real today) and the block's Source date.
    None if the date is missing/unparseable."""
    d = source_date(fields)
    if d is None:
        return None
    today = today or date.today()
    return (today - d).days

# --- write side (from SG-05 `learn propose`; unified here per ADR-0034 decision 1:
# ONE staging-block definition, shared by drain, propose, and the `stage` verb below) ---

_NORM_RE = re.compile(r"[a-z0-9]+")

def norm(title):
    """Normalize a title into a dedup key: lowercase alphanumeric words."""
    return " ".join(_NORM_RE.findall(str(title).lower()))

def render_block(candidate):
    """Render one candidate dict as a `## [staged]` block string (trailing blank line).

    Byte-identical to hooks/backlog-stage.py:render_candidate / anomalies.py:render_block.
    Required: title. Optional: intent, approach, u, f, home, source. Returns None if the
    title is empty (a titleless block is unparseable and never emitted).
    """
    # Collapse ALL whitespace (newlines included) in every rendered field. A block is a
    # line-oriented grammar: an embedded "\n\n## [staged] ..." in a field forges a SECOND
    # proposal that parse_blocks() reads as real. The fields now carry LLM-authored text
    # derived from transcripts (session-audit), i.e. attacker-influenceable content, and
    # SPEC-200 I1 routes ever more of it through this one renderer. Sanitize at the ONE
    # place every writer shares (review finding).
    def _flat(v, fallback=""):
        s = re.sub(r"\s+", " ", str(v)).strip()
        return s or fallback

    title = _flat(candidate.get("title", ""))
    if not title:
        return None
    intent = _flat(candidate.get("intent", ""), "(no intent extracted)")
    approach = _flat(candidate.get("approach", ""), "(no approach extracted)")
    u = candidate.get("u") if candidate.get("u") in ("hi", "mid", "lo") else "lo"
    f = candidate.get("f") if candidate.get("f") in ("hi", "mid", "lo") else "mid"
    home = _flat(candidate.get("home", ""))
    # Source carries the origin + date; propose folds the lens/figure/rids citation onto
    # this ONE line so it rides into the board Notes column on promote.
    source = _flat(candidate.get("source", ""), "unknown")
    home_line = f"- Home: {home}\n" if home else ""
    return (
        f"## [staged] {title}\n"
        f"- Intent: {intent}\n"
        f"- Approach: {approach}\n"
        f"- Tags: #u-{u} #f-{f}\n"
        f"{home_line}"
        f"- Source: {source}\n\n"
    )

def existing_keys(*sources):
    """Build the dedup key SET from any number of (kind, path) sources.

    kind == "staging" -> parse `## [<state>] <title>` blocks (ALL states: staged,
    rejected, expired, promoted -- a rejected/expired proposal must never be re-proposed).
    kind == "board"   -> parse board rows `| ID-NNN | Item | ... |` (the Item cell).
    A missing file contributes nothing. Keys are norm()'d titles; membership is EXACT
    (the anchored dedup form).
    """
    import os
    keys = set()
    board_row = re.compile(r"\s*\|\s*[A-Z]+-\d+\s*\|\s*([^|]+)\|")
    for kind, path in sources:
        if not path or not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        if kind == "staging":
            for b in parse_blocks(text):
                if b["title"]:
                    keys.add(norm(b["title"]))
        elif kind == "board":
            for line in text.splitlines():
                m = board_row.match(line)
                if m:
                    keys.add(norm(m.group(1)))
    return keys


def cmd_stage():
    """`staging-format.py stage`: read one JSON object on stdin (title, intent, home,
    staging, backlog?) and either report a duplicate or append one block. See the
    `### Interfaces` `staging-format.py stage` paragraph, SPEC-249 TASK-003. The dedupe
    check runs immediately before the append, in this same process -- there is no window
    between "is it staged" and "stage it" for another writer to land in."""
    import os
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        sys.stderr.write(
            "usage: staging-format.py stage: expects one JSON object on stdin "
            "({title, intent, home, staging, backlog?})\n"
        )
        return 64

    title = data.get("title", "")
    staging = data.get("staging", "")
    key = norm(title)
    if key and key in existing_keys(("staging", staging), ("board", data.get("backlog"))):
        print(f"stage: already staged: {title}")
        return 0

    block = render_block({
        "title": title,
        "intent": data.get("intent", ""),
        "home": data.get("home", ""),
        "u": "lo",
        "f": "mid",
        "source": f"session {date.today().isoformat()}",
    })
    if block is None:
        sys.stderr.write("usage: staging-format.py stage: title is required\n")
        return 64

    header = "" if os.path.isfile(staging) else "# Backlog staging\n\n"
    try:
        with open(staging, "a", encoding="utf-8") as fh:
            fh.write(header + block)
    except OSError as e:
        print(f"FAILED: {e}")
        return 2

    print(block.splitlines()[0])
    return 0


def _main(argv):
    if len(argv) >= 2 and argv[1] == "parse":
        with open(argv[2], encoding="utf-8") as fh:
            print(json.dumps(parse_blocks(fh.read()), ensure_ascii=False, indent=2))
        return 0
    if len(argv) >= 2 and argv[1] == "render":
        block = render_block(json.load(sys.stdin))
        if block is None:
            return 1
        sys.stdout.write(block)
        return 0
    if len(argv) >= 2 and argv[1] == "stage":
        return cmd_stage()
    sys.stderr.write("usage: staging_format.py {parse <file>|render <stdin-json>|stage}\n")
    return 64


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
