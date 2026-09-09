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
import os
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

# Unicode word runs (letters and digits in any script, underscore excluded): an ASCII-only
# class turned every CJK title into an empty key that skipped dedupe (battery probe).
_NORM_RE = re.compile(r"[^\W_]+")

def norm(title):
    """Normalize a title into a dedup key: casefolded word runs in any script."""
    return " ".join(_NORM_RE.findall(str(title).casefold()))

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

_BOARD_ROW_RE = re.compile(r"\s*\|\s*[A-Z]+-\d+\s*\|\s*([^|]+)\|")
# `- [ ] title` / `- [x] title`. A CHECKED item counts for dedup too: it is finished work,
# and re-proposing finished work is the second-largest false-positive class (ID-294).
_CHECKBOX_RE = re.compile(r"(?m)^\s*[-*]\s*\[[ xX]\]\s*(.+?)\s*$")
# A cockpit registry line: `<name>  <path-to-BACKLOG.md>`, `#` comments, `~` expands.
_REGISTRY_RE = re.compile(r"^([^\s#]+)\s+(\S.*)$")


def _registry_boards(path):
    """The board files a cockpit registry points at. Unreadable lines contribute nothing."""
    out = []
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                m = _REGISTRY_RE.match(line)
                if m:
                    out.append(os.path.expanduser(m.group(2).strip()))
    except OSError:
        return []
    return out


def existing_keys(*sources):
    """Build the dedup key SET from any number of (kind, path) sources.

    kind == "staging" -> parse `## [<state>] <title>` blocks (ALL states: staged,
    rejected, expired, promoted -- a rejected/expired proposal must never be re-proposed).
    kind == "board"   -> parse board rows `| ID-NNN | Item | ... |` (the Item cell).
    kind == "cockpit" -> a `name  path/to/BACKLOG.md` registry; every board it lists.
    kind == "roadmap" -> a megagoal ROADMAP/TODO: its checkbox items and any board rows.
    A missing file contributes nothing. Keys are norm()'d titles; membership is EXACT
    (the anchored dedup form).

    The last two kinds close the anchor gap ID-294 measured: 28 of 69 staged candidates
    duplicated work already tracked on a cross-repo cockpit board or a megagoal TODO,
    surfaces this set never read, so that work re-entered staging as new.
    """
    keys = set()
    for kind, path in sources:
        if not path or not os.path.isfile(path):
            continue
        if kind == "cockpit":
            for board in _registry_boards(path):
                keys |= existing_keys(("board", board))
            continue
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        if kind == "staging":
            for b in parse_blocks(text):
                if b["title"]:
                    keys.add(norm(b["title"]))
        elif kind == "board":
            for line in text.splitlines():
                m = _BOARD_ROW_RE.match(line)
                if m:
                    keys.add(norm(m.group(1)))
        elif kind == "roadmap":
            for m in _CHECKBOX_RE.finditer(text):
                # `change -- owner: x -- deadline: y`: the change alone is the title a
                # proposal would carry, so the trailing metadata must not join the key.
                keys.add(norm(re.split(r"\s+--\s+", m.group(1))[0]))
            for line in text.splitlines():
                m = _BOARD_ROW_RE.match(line)
                if m:
                    keys.add(norm(m.group(1)))
    return keys


def cmd_stage():
    """`staging-format.py stage`: read one JSON object on stdin (title, intent, home,
    staging, backlog?) and either report a duplicate or append one block. See the
    `### Interfaces` `staging-format.py stage` paragraph, SPEC-249 TASK-003. The dedupe
    check runs immediately before the append, in this same process -- there is no window
    between "is it staged" and "stage it" for another writer to land in."""
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        sys.stderr.write(
            "usage: staging-format.py stage: expects one JSON object on stdin "
            "({title, intent, home, staging, backlog?})\n"
        )
        return 64
    # Valid JSON but not an object (a list, string, number, or null) is the same usage
    # error, not an AttributeError from `.get()` on the wrong type a few lines down.
    if not isinstance(data, dict):
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
        # O_NOFOLLOW closes the window between the caller's symlink check and this append: a
        # symlink swapped in after that check raises ELOOP here instead of redirecting the write.
        fd = os.open(
            staging, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o644
        )
        with os.fdopen(fd, "a", encoding="utf-8") as fh:
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
