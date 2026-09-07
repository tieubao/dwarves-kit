"""Core planner/board tests (source-agnostic). Spoke I/O is tested per
adapter with fake transports; live runs are recorded in docs/proof-of-done.md.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from sync_core import (  # noqa: E402
    Plan,
    apply_board,
    build_state,
    describe,
    extract_tags,
    next_id,
    parse_board,
    parse_title,
    plan_sync,
    strip_tags,
    title_for,
    UNTRUSTED_PREFIX,
)

BOARD = """# Backlog

### Section A

| ID | Item | Notes & source | Status |
|---|---|---|---|
| ID-10 | Fix the frobnicator | notes with escaped \\| pipe #tag | queued |
| ID-11 | Ship the widget | some notes #infra #tooling | executing |
| ID-12 | Old thing | done long ago | shipped #99 |
| ID-13 | Deferred thing | waiting | parked [revisit when X] |

## Recently closed

| ID | Item | Notes & source | Status |
|---|---|---|---|
| ID-5 | Ancient | shipped 2026-01-01 | shipped |
"""


def item(rid, title, done=False, body="", status=None):
    return {"rid": rid, "title": title, "done": done, "body": body,
            "status": status}


def creates(p):
    return {bid: title for bid, title, _b, _kw in p.src_create}


def snap(bid, rid, title, notes=None, status=None):
    rows = parse_board(BOARD)
    return {bid: {"rid": rid, "title": title,
                  "notes": rows[bid].notes if notes is None else notes,
                  "status": rows[bid].status_kw if status is None else status}}


def test_parse_board():
    rows = parse_board(BOARD)
    assert set(rows) == {"ID-10", "ID-11", "ID-12", "ID-13", "ID-5"}
    assert rows["ID-10"].item == "Fix the frobnicator"
    assert rows["ID-10"].status_kw == "queued"
    assert rows["ID-10"].notes == "notes with escaped | pipe #tag"
    assert rows["ID-13"].status_kw == "parked"


def test_parse_board_skips_malformed():
    assert parse_board("| ID-1 | too | many | cells | here | queued |\n") == {}


def test_next_id_skips_id_in_malformed_row():
    """A pipe-broken row is invisible to parse_board, but its literal ID
    token must still block reuse: next_id's raw-text floor matches any
    row-SHAPED line (`| ID-N |` at line start) even when the rest of the row
    fails to parse, so a malformed row can never let a later spoke-born item
    mint its id."""
    broken = BOARD + "| ID-309 | Queue-watcher pilot widening | notes\n"
    assert "ID-309" not in parse_board(broken)  # confirms invisibility
    assert next_id(broken) == 310


def test_next_id_ignores_id_token_in_notes_prose():
    """ID-480: an id-like token in a notes/prose cell -- not row-shaped, just
    text inside another row's third column -- must never inflate next_id.
    Before the fix, next_id regex-scanned the whole raw text and this row
    alone would have pushed the mint to 100000000."""
    poisoned = BOARD + (
        "| ID-14 | Demo row | mentions ID-99999999 in prose, not a row "
        "| queued |\n"
    )
    assert next_id(poisoned) == 15  # from the real ID-14 row, not the token


def test_next_id_and_title_and_tags():
    assert next_id(BOARD) == 14
    assert parse_title("ID-10 · Fix it") == ("ID-10", "Fix it")
    assert parse_title("buy milk") == (None, "buy milk")
    assert extract_tags("x #infra y #tooling #infra") == ["infra", "tooling"]
    assert strip_tags("x #infra y #tooling z") == "x y z"
    assert strip_tags("→ docs/x.md #u-lo #f-hi") == "→ docs/x.md"


def test_creates_for_active_rows_only_with_full_data():
    p = plan_sync(parse_board(BOARD), [], {})
    assert set(creates(p)) == {"ID-10", "ID-11"}
    bid, title, body, kw = p.src_create[0]
    assert (bid, title, kw) == ("ID-10", "ID-10 · Fix the frobnicator", "queued")
    assert body == "notes with escaped | pipe #tag"
    assert not p.board_set_status and not p.board_add


def test_done_item_flips_board_to_shipped():
    items = [item("r1", "ID-10 · Fix the frobnicator", done=True)]
    p = plan_sync(parse_board(BOARD), items,
                  {"map": snap("ID-10", "r1", "Fix the frobnicator")})
    assert p.board_set_status == [("ID-10", "shipped")]
    assert "ID-10" not in creates(p)


def test_definitive_spoke_status_flips_board():
    items = [item("r1", "ID-10 · Fix the frobnicator", status="executing")]
    p = plan_sync(parse_board(BOARD), items,
                  {"map": snap("ID-10", "r1", "Fix the frobnicator")})
    assert p.board_set_status == [("ID-10", "executing")]
    assert not p.src_set_status


def test_board_status_change_pushes_to_spoke():
    items = [item("r1", "ID-10 · Fix the frobnicator", status="claimed")]
    p = plan_sync(parse_board(BOARD), items,
                  {"map": snap("ID-10", "r1", "Fix the frobnicator",
                               status="claimed")})
    # board moved claimed -> queued since snapshot; spoke unchanged
    assert p.src_set_status == [("r1", "queued")]
    assert not p.board_set_status


def test_status_conflict_board_wins():
    items = [item("r1", "ID-10 · Fix the frobnicator", status="executing")]
    p = plan_sync(parse_board(BOARD), items,
                  {"map": snap("ID-10", "r1", "Fix the frobnicator",
                               status="claimed")})
    # snapshot claimed; board now queued, spoke now executing -> board wins
    assert p.src_set_status == [("r1", "queued")]
    assert not p.board_set_status
    assert p.conflicts


def test_inactive_row_closes_spoke_item():
    items = [item("r2", "ID-12 · Old thing")]
    p = plan_sync(parse_board(BOARD), items,
                  {"map": snap("ID-12", "r2", "Old thing", status="executing")})
    assert p.src_set_status == [("r2", "shipped")]


def test_reopen_pushes_active_status():
    items = [item("r1", "ID-10 · Fix the frobnicator", done=True)]
    p = plan_sync(parse_board(BOARD), items,
                  {"map": snap("ID-10", "r1", "Fix the frobnicator",
                               status="shipped")})
    # board reopened shipped -> queued; spoke still done (= shipped, unchanged)
    assert p.src_set_status == [("r1", "queued")]
    assert not p.board_set_status


def test_adoption_board_wins():
    """No snapshot entry: spoke state is aligned to the board, never pulled."""
    items = [item("r1", "ID-10 · Fix the frobnicator", status="executing")]
    p = plan_sync(parse_board(BOARD), items, {})
    assert p.src_set_status == [("r1", "queued")]
    assert not p.board_set_status
    # done-flag adapters: done spoke item + active row also re-aligns
    items2 = [item("r1", "ID-10 · Fix the frobnicator", done=True)]
    p2 = plan_sync(parse_board(BOARD), items2, {})
    assert p2.src_set_status == [("r1", "queued")]


def test_deleted_spoke_item_tombstones_never_touches_board():
    state = {"map": snap("ID-10", "gone", "Fix the frobnicator")}
    p = plan_sync(parse_board(BOARD), [], state)
    assert p.tombstone == ["ID-10"]
    assert not p.board_set_status
    assert "ID-10" not in creates(p)
    p2 = plan_sync(parse_board(BOARD), [], {"tombstones": ["ID-10"]})
    assert creates(p2).keys() == {"ID-11"}


def test_new_spoke_item_becomes_board_row_with_status():
    items = [item("r9", "buy milk", body="2% only", status="claimed"),
             item("r10", "call bank", status="shipped"),  # non-active kw
             item("r11", "done thing", done=True)]        # done: skipped
    p = plan_sync(parse_board(BOARD), items, {})
    assert p.board_add == [("r9", "buy milk", "2% only", "claimed"),
                           ("r10", "call bank", "", "queued")]


def test_board_add_skips_duplicate_title():
    items = [item("r9", "Fix the frobnicator")]
    p = plan_sync(parse_board(BOARD), items, {})
    assert not p.board_add
    assert any("already on board" in n for n in p.notes)


def test_link_skips_title_mismatched_id_collision():
    """Repaired-row scenario: ID-309 now exists on the board, but a
    spoke-born item that reused the id (minted while the row was broken and
    invisible to parse_board) carries an unrelated title. The title-prefix
    link must refuse to adopt it rather than let the spoke item silently
    overwrite the real row's title/status."""
    board = BOARD + ("\n| ID-309 | Queue-watcher pilot widening | real row "
                     "| executing |\n")
    rows = parse_board(board)
    items = [item("spoke-1", "ID-309 · done", done=True)]
    p = plan_sync(rows, items, {})
    assert not p.board_edit_item
    assert not any(bid == "ID-309" for bid, _ in p.board_set_status)
    assert any("id collision" in n and "ID-309" in n and "done" in n
              for n in p.notes)


def test_title_sync_board_wins_and_spoke_edit_pulls():
    state = {"map": snap("ID-10", "r1", "Old title")}
    # spoke stale -> push
    p = plan_sync(parse_board(BOARD),
                  [item("r1", "ID-10 · Old title")], state)
    assert ("r1", "ID-10 · Fix the frobnicator") in p.src_set_title
    # spoke edited, board unchanged -> pull
    state2 = {"map": snap("ID-10", "r1", "Fix the frobnicator")}
    p2 = plan_sync(parse_board(BOARD),
                   [item("r1", "ID-10 · Fix the frobnicator NOW")], state2)
    assert ("ID-10", "Fix the frobnicator NOW") in p2.board_edit_item
    # both edited -> board wins + conflict
    p3 = plan_sync(parse_board(BOARD),
                   [item("r1", "ID-10 · spoke version")],
                   {"map": snap("ID-10", "r1", "snapshot version")})
    assert ("r1", "ID-10 · Fix the frobnicator") in p3.src_set_title
    assert p3.conflicts and not p3.board_edit_item


def test_notes_change_pushes_body():
    state = {"map": snap("ID-10", "r1", "Fix the frobnicator",
                         notes="old notes")}
    p = plan_sync(parse_board(BOARD),
                  [item("r1", "ID-10 · Fix the frobnicator", body="stale")],
                  state)
    assert p.src_set_body == [("r1", "notes with escaped | pipe #tag")]
    state2 = {"map": snap("ID-10", "r1", "Fix the frobnicator")}
    p2 = plan_sync(parse_board(BOARD),
                   [item("r1", "ID-10 · Fix the frobnicator", body="stale")],
                   state2)
    assert not p2.src_set_body  # spoke-side body edit persists (board wins lazily)


def test_sync_fields_false_freezes_fields():
    """Field actions are never emitted and stale spoke titles never pulled."""
    state = {"map": snap("ID-10", "r1", "Fix the frobnicator")}
    items = [item("r1", "ID-10 · totally stale title", body="stale")]
    p = plan_sync(parse_board(BOARD), items, state, sync_fields=False)
    assert not p.src_set_title and not p.src_set_body
    assert not p.board_edit_item


def test_apply_board_status_flip_preserves_prose():
    plan = Plan(board_set_status=[("ID-13", "queued")])
    new_text, _ = apply_board(BOARD, plan)
    assert "| queued [revisit when X] |" in new_text
    assert "| ID-10 | Fix the frobnicator | notes with escaped \\| pipe #tag | queued |" in new_text


def test_apply_board_add_inbox_section_and_status():
    plan = Plan(board_add=[("r9", "buy milk", "2% only\nfrom shop", "claimed"),
                           ("r10", "call bank", "", "queued")])
    new_text, assigned = apply_board(BOARD, plan)
    assert assigned == {"r9": "ID-14", "r10": "ID-15"}
    assert new_text.index("### Reminders inbox") < new_text.index("## Recently closed")
    rows = parse_board(new_text)
    assert rows["ID-14"].status_kw == "claimed"
    assert rows["ID-14"].notes.startswith(UNTRUSTED_PREFIX)
    plan2 = Plan(board_add=[("r11", "third", "", "queued")])
    text3, assigned2 = apply_board(new_text, plan2)
    assert text3.count("### Reminders inbox") == 1
    assert assigned2 == {"r11": "ID-16"}


def test_second_run_is_idempotent():
    """Negative control: after a full round-trip the plan is empty."""
    rows = parse_board(BOARD)
    p1 = plan_sync(rows, [], {})
    created = {bid: f"rid-{bid}" for bid in creates(p1)}
    state = build_state(rows, [], p1, created, {}, {})
    items = [item(created[bid], title_for(bid, rows[bid].item),
                  body=rows[bid].notes, status=rows[bid].status_kw)
             for bid in created]
    p2 = plan_sync(rows, items, state)
    assert p2.empty(), "unexpected plan:\n" + describe(p2)
    # same for a done-flag-only spoke (reminders shape)
    items3 = [item(created[bid], title_for(bid, rows[bid].item),
                   body=rows[bid].notes) for bid in created]
    p3 = plan_sync(rows, items3, state)
    assert p3.empty(), "unexpected plan:\n" + describe(p3)


def test_full_round_trip_completion():
    """Seed, tick one off on the spoke, sync flips board, then stable."""
    rows = parse_board(BOARD)
    p1 = plan_sync(rows, [], {})
    created = {bid: f"rid-{bid}" for bid in creates(p1)}
    state = build_state(rows, [], p1, created, {}, {})
    items = [item(created["ID-10"], "ID-10 · Fix the frobnicator", done=True),
             item(created["ID-11"], "ID-11 · Ship the widget",
                  body=rows["ID-11"].notes, status="executing")]
    p2 = plan_sync(rows, items, state)
    assert p2.board_set_status == [("ID-10", "shipped")]
    new_text, _ = apply_board(BOARD, p2)
    rows3 = parse_board(new_text)
    assert rows3["ID-10"].status_kw == "shipped"
    state3 = build_state(rows3, items, p2, {}, {}, state)
    assert state3["map"]["ID-10"]["status"] == "shipped"  # stays linked
    p3 = plan_sync(rows3, items, state3)
    assert p3.empty(), "unexpected plan:\n" + describe(p3)


def test_crash_retry_does_not_duplicate_creates():
    """State lost AFTER spoke creates succeeded (crash before state write):
    the next run re-links via title-prefix adoption instead of re-creating."""
    rows = parse_board(BOARD)
    p1 = plan_sync(rows, [], {})
    items = [item(f"rid-{bid}", title_for(bid, rows[bid].item),
                  body=rows[bid].notes, status=rows[bid].status_kw)
             for bid in creates(p1)]
    p2 = plan_sync(rows, items, {})  # empty state = the crash case
    assert not p2.src_create and not p2.board_add


def test_board_add_flattens_newline_titles():
    plan = Plan(board_add=[("r9", "line one\nline two", "", "queued")])
    new_text, assigned = apply_board(BOARD, plan)
    rows = parse_board(new_text)
    assert rows[assigned["r9"]].item == "line one line two"


def test_cli_warns_on_duplicate_and_malformed_rows(capsys):
    import backlog_sync
    backlog_sync.warn_duplicate_ids(
        BOARD
        + "| ID-10 | dup row | n | queued |\n"
        + "| ID-99 | missing status cell | notes only\n"
        + "| ID-98 | raw pipe | head -c 4 | wc | queued |\n")
    out = capsys.readouterr().out
    assert "duplicate board rows for ID-10" in out
    assert "malformed board rows" in out
    assert "ID-98" in out and "ID-99" in out


FAMILY_FILTER = {"skip_tags": {"family"}}
BOARD_F = BOARD.replace(
    "| ID-11 | Ship the widget | some notes #infra #tooling | executing |",
    "| ID-11 | Ship the widget | family thing #family | executing |")


def test_down_filter_skips_creation():
    p = plan_sync(parse_board(BOARD_F), [], {}, filt=FAMILY_FILTER)
    assert set(creates(p)) == {"ID-10"}  # ID-11 carries #family: never created
    p2 = plan_sync(parse_board(BOARD_F), [], {},
                   filt={"only_tags": {"family"}})
    assert set(creates(p2)) == {"ID-11"}


def test_scope_exit_freeze_and_reenter():
    rows = parse_board(BOARD_F)
    items = [item("r1", "ID-11 · Ship the widget", status="executing")]
    state = {"map": {"ID-11": {"rid": "r1", "title": "Ship the widget",
                               "notes": "family thing #family",
                               "status": "executing"}}}
    # transition out: filter newly applied -> close on app, no field flow
    p = plan_sync(rows, items, state, filt=FAMILY_FILTER)
    assert p.src_scope_exit == [("ID-11", "r1")]
    assert not p.src_set_body and not p.src_set_title
    state2 = build_state(rows, items, p, {}, {}, state)
    assert state2["map"]["ID-11"]["scoped_out"] is True
    # frozen: app-side done is NOT a shipped proposal while out of scope
    items2 = [item("r1", "ID-11 · Ship the widget", done=True)]
    p2 = plan_sync(rows, items2, state2, filt=FAMILY_FILTER)
    assert not p2.board_set_status  # the done flag is ignored while frozen
    assert not p2.src_scope_exit and not p2.scope_reenter
    assert "ID-11" not in creates(p2)
    # filter relaxed -> re-enter: reopen + realign from the board
    p3 = plan_sync(rows, items2, state2, filt=None)
    assert p3.scope_reenter == [("ID-11", "r1")]
    assert ("r1", "executing") in p3.src_set_status
    state3 = build_state(rows, items2, p3, {}, {}, state2)
    assert "scoped_out" not in state3["map"]["ID-11"]


def test_scope_exited_then_deleted_item_never_tombstones():
    rows = parse_board(BOARD_F)
    state = {"map": {"ID-11": {"rid": "gone", "title": "Ship the widget",
                               "notes": "family thing #family",
                               "status": "executing", "scoped_out": True}}}
    p = plan_sync(rows, [], state, filt=FAMILY_FILTER)
    assert not p.tombstone and "ID-11" not in creates(p)


def test_intake_filter_modes():
    items = [item("r9", "from the app", body="x #ops"),
             item("r10", "unrelated", body="y")]
    p = plan_sync(parse_board(BOARD), items, {},
                  filt={"intake": "tagged:ops"})
    assert [a[0] for a in p.board_add] == ["r9"]
    p2 = plan_sync(parse_board(BOARD), items, {}, filt={"intake": "none"})
    assert not p2.board_add
    assert any("intake filtered" in n for n in p2.notes)


def test_intake_skip_re_keeps_threaded_tickets_on_the_app():
    # A support ticket carries a `thread:` line and closes through its own
    # desk; adopting it would archive it on the next scope-exit.
    items = [item("r11", "Support: payment | someone",
                  body="category: payment\nthread: 1546399662305443940\nfiled-by: support-desk"),
             item("r12", "Investigate CRIT", body="rule_id: x\nno thread here")]
    p = plan_sync(parse_board(BOARD), items, {},
                  filt={"intake": "all", "intake_skip_re": r"^thread: "})
    assert [a[0] for a in p.board_add] == ["r12"]
    assert any("intake filtered" in n and "Support:" in n for n in p.notes)


def test_inbox_quarantine_tag_on_intake_rows():
    plan = Plan(board_add=[("r9", "buy milk", "", "queued")])
    new_text, assigned = apply_board(BOARD, plan)
    assert "inbox" in extract_tags(parse_board(new_text)[assigned["r9"]].notes)


def test_build_state_preserves_binding():
    rows = parse_board(BOARD)
    s = build_state(rows, [], Plan(), {}, {}, {"binding": {"ds_id": "x"}})
    assert s["binding"] == {"ds_id": "x"}


def test_board_add_marks_intake_notes_untrusted():
    """ID-481: intake-born rows carry the untrusted-data prefix in their notes,
    so foreign spoke content reaches agent context flagged DATA not instructions.
    The title is deliberately left clean: it carries the minted id + item that
    titles_agree()/re-linking compare, so a permanent prefix would break the
    two-way identity check."""
    plan = Plan(board_add=[("r9", "buy milk", "2% only", "claimed")])
    new_text, assigned = apply_board(BOARD, plan)
    row = parse_board(new_text)[assigned["r9"]]
    assert row.notes.startswith(UNTRUSTED_PREFIX)
    assert "2% only" in row.notes
    assert row.notes.endswith("#inbox")
    assert row.item == "buy milk"  # title deliberately not tagged


def test_build_state_refuses_mispaired_prefix_adoption():
    """A spoke item whose embedded id points at a board row with DIFFERENT
    text must not be adopted into the snapshot map: adoption stores the
    BOARD's title as snap-truth, so the very next sync reads the spoke's
    text as a retitle and overwrites the board row (the 2026-09-01
    dfoundation DF-310/311/312 scramble, reproduced on two machines)."""
    rows = parse_board(BOARD)
    poisoned = item("r-poison", "ID-10 · Ship the widget")  # ID-11's text
    honest = item("r-ok", "ID-11 · Ship the widget")
    state = build_state(rows, [poisoned, honest], Plan(), {}, {}, {})
    assert "ID-10" not in state["map"]
    assert state["map"]["ID-11"]["rid"] == "r-ok"


def test_rotation_guard_board_wins_on_cross_row_title():
    """A linked spoke item 'retitled' to exactly ANOTHER row's current item
    is the cross-row mispairing signature: the board must win (spoke gets
    re-titled back), never a board_edit_item."""
    rows = parse_board(BOARD)
    state = {"map": snap("ID-10", "r1", "Fix the frobnicator")}
    it = item("r1", "ID-10 · Ship the widget")  # ID-11's exact item text
    p = plan_sync(rows, [it], state)
    assert p.board_edit_item == []
    assert any("mispairing" in c for c in p.conflicts)
    assert ("r1", title_for("ID-10", "Fix the frobnicator")) in p.src_set_title


def test_rotation_guard_still_allows_real_retitle():
    """A genuine spoke retitle (text not matching any other row) still flows
    to the board."""
    rows = parse_board(BOARD)
    state = {"map": snap("ID-10", "r1", "Fix the frobnicator")}
    it = item("r1", "ID-10 · Fix the frobnicator properly")
    p = plan_sync(rows, [it], state)
    assert ("ID-10", "Fix the frobnicator properly") in p.board_edit_item
    assert p.conflicts == []


def test_worktree_fence_refuses_sync(tmp_path):
    """Spokes are shared per board; a worktree checkout's divergent rows
    poison them for every other checkout. The engine refuses the path
    outright (KIT_SYNC_ALLOW_WORKTREE=1 is the explicit override)."""
    import os
    import subprocess
    wt = tmp_path / "repo" / ".claude" / "worktrees" / "x" / "_meta"
    wt.mkdir(parents=True)
    (wt / "BACKLOG.md").write_text(BOARD)
    engine = Path(__file__).resolve().parents[1] / "backlog_sync.py"
    env = {k: v for k, v in os.environ.items() if k != "KIT_SYNC_ALLOW_WORKTREE"}
    r = subprocess.run(
        [sys.executable, str(engine), "--backlog", str(wt / "BACKLOG.md"),
         "--apps", "reminders", "--dry-run"],
        capture_output=True, text=True, env=env)
    assert r.returncode != 0
    assert "refusing to sync a worktree" in (r.stderr + r.stdout)


def test_collided_bid_holds_create_instead_of_duplicating():
    """After an id-collision refusal (title-mismatched spoke item), the row
    must NOT src_create a second spoke item; that would duplicate forever
    while the stale item lingers (battery 2026-09-01)."""
    rows = parse_board(BOARD)
    stale = item("r-stale", "ID-10 · Ship the widget")  # wrong text for ID-10
    p = plan_sync(rows, [stale], {})
    assert all(bid != "ID-10" for bid, *_ in p.src_create)
    assert any("create held" in n for n in p.notes)
    # other rows still create normally
    assert any(bid == "ID-11" for bid, *_ in p.src_create)


def test_renumbered_row_relinks_instead_of_minting_a_duplicate():
    """Renumbering a linked row must not orphan its spoke card.

    The map is keyed by board id, so a renumber (collision fix, manual edit)
    leaves the entry under a dead id. The row then reads as unlinked and the
    next tick mints a SECOND card for the same work. Reproduced live on the
    personal board: an incident card filed by vps-mon was adopted as ID-629,
    the row was renumbered to ID-634 in git, and the following sync created a
    duplicate `ID-634 · ...` card. The two idempotency namespaces cannot
    collide, so spoke-side idempotency can never catch it.

    The card carries no `ID-NNN ·` prefix here on purpose: that is how a
    sensor-filed card looks, and it is why prefix matching cannot recover the
    link.
    """
    rows = parse_board(BOARD)
    dead = {"map": {"ID-99": {"rid": "r1", "title": "Fix the frobnicator",
                              "notes": rows["ID-10"].notes,
                              "status": rows["ID-10"].status_kw}}}
    it = item("r1", "[vps-mon] CRIT heartbeat-silent on air.upgrade-check")
    p = plan_sync(rows, [it], dead)
    assert "ID-10" not in creates(p), "renumbered row minted a duplicate card"
    assert p.tombstone == [], "renumbered row must not stop mirroring either"


def test_renumber_relink_needs_an_unambiguous_match():
    """The relink keys on the stored title, so it only fires when exactly one
    unmapped row still carries that text. Two candidates means we cannot tell
    which row inherited the card: leave it alone rather than guess."""
    board = BOARD.replace("| ID-11 | Ship the widget |",
                          "| ID-11 | Fix the frobnicator |")
    rows = parse_board(board)
    dead = {"map": {"ID-99": {"rid": "r1", "title": "Fix the frobnicator",
                              "notes": rows["ID-10"].notes,
                              "status": rows["ID-10"].status_kw}}}
    it = item("r1", "[vps-mon] CRIT heartbeat-silent on air.upgrade-check")
    p = plan_sync(rows, [it], dead)
    assert "ID-10" in creates(p) and "ID-11" in creates(p)
