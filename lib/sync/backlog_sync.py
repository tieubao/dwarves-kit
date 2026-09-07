#!/usr/bin/env python3
"""Two-way sync between a kit kanban BACKLOG.md (hub) and its spokes: Apple
Reminders, a Notion board, the Hermes kanban. See docs/specs/SPEC-001.

Front door: `board sync` (bin/board), which any adopted repo's `_meta/board`
shim already forwards to with the right --backlog-file. Spokes plug in per
repo via the `[sync]` section of `.kit.toml` (ADR-0034 config layer); the
`cmd_sync` shim in lib/board/board.sh resolves those keys through
lib/config/kit-config.sh (the ONE TOML reader) and hands this engine plain
flags. This file reads no config file, by design.

Each configured spoke syncs independently via a three-way merge with a
per-board snapshot in ~/.cache/backlog-sync/<board-slug>/<source>.state.json.
Board wins on conflict; spoke deletions never touch the board.
"""

import argparse
import fcntl
import json
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from sync_core import (ID_TOKEN, apply_board, build_state, describe,  # noqa: E402
                       detect_prefix, parse_board, plan_create_only,
                       plan_pull_only, plan_sync)

# apps that push one-way and read boards with any repo prefix (not just ID-)
CREATE_ONLY_APPS = {"notion-taskboard"}
# apps that only READ a foreign board and intake into the hub (SPEC-004)
PULL_ONLY_APPS = {"notion-taskboard-pull"}
from sources.github import GitHubSource  # noqa: E402
from sources.hermes import HermesSource  # noqa: E402
from sources.multica import MulticaSource  # noqa: E402
from sources.notion import NotionSource  # noqa: E402
from sources.notion_taskboard import (NotionTaskBoardSource,  # noqa: E402
                                      parse_map)
from sources.notion_taskboard_pull import (  # noqa: E402
    NotionTaskBoardPullSource)
from sources.reminders import RemindersSource  # noqa: E402

LEGACY_REMINDERS_STATE = (Path.home() / ".cache" / "backlog-reminders-sync"
                          / "state.json")


def atomic_write(path: Path, text: str) -> None:
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


def warn_duplicate_ids(text: str, strict_id: bool = True) -> None:
    token = (re.escape(detect_prefix(text)) + r"-\d+") if strict_id \
        else ID_TOKEN
    ids = re.findall(r"^\| (" + token + r") \|", text, flags=re.M)
    dups = sorted({i for i in ids if ids.count(i) > 1})
    if dups:
        print(f"WARNING: duplicate board rows for {', '.join(dups)}; "
              "first occurrence wins, fix the board")
    parsed = set(parse_board(text, strict_id=strict_id,
                             prefix=detect_prefix(text)))
    broken = sorted(set(ids) - parsed - set(dups))
    if broken:
        print(f"WARNING: malformed board rows (not 4 cells, invisible to "
              f"sync) for {', '.join(broken)}; fix the board")


def sync_create_only(src, backlog: Path, state_path: Path, dry_run: bool,
                     filt: dict | None = None) -> None:
    """One-way, insert-only push to a write-only sink (SPEC-003). The board
    file is never written; the local state map is the identity index. State is
    checkpointed after EACH create, so a mid-batch failure never re-pushes an
    already-created page (no duplicate cards on a team-owned board)."""
    text = backlog.read_text()
    rows = parse_board(text, strict_id=False)
    state = json.loads(state_path.read_text()) if state_path.exists() else {}
    if hasattr(src, "binding") and state.get("binding"):
        src.binding = state["binding"]
    plan = plan_create_only(rows, state, skip_kw=getattr(src, "skip_kw", None),
                            filt=filt)
    # Validate the whole batch (maps resolve, options exist) BEFORE any write,
    # so `--dry-run` surfaces config errors and a live run never dies part-way.
    if hasattr(src, "preflight"):
        src.preflight(plan)
    header = (f"{src.name}: {len(rows)} board rows, "
              f"{len(plan.src_create)} to create")
    if dry_run:
        print(f"dry-run {header}")
        print(describe(plan))
        return

    new_map = dict(state.get("map", {}))
    state_path.parent.mkdir(parents=True, exist_ok=True)

    def write_state() -> None:
        new_state = {"map": new_map}
        if getattr(src, "binding", None):
            new_state["binding"] = src.binding
        atomic_write(state_path, json.dumps(new_state, indent=1))

    def checkpoint(bid: str, rid: str) -> None:
        new_map[bid] = {"rid": rid}
        write_state()

    # Adoptions bind an existing page with no network call, so they are
    # persisted up front rather than through the create-only checkpoint,
    # which fires per POST.
    if plan.src_adopt:
        for bid, pid in plan.src_adopt:
            new_map[bid] = {"rid": pid, "via": "pull-marker"}
        write_state()

    created = src.apply(plan, {}, rows, on_created=checkpoint)
    print(f"synced {header}")
    print(describe(plan, created))


def sync_pull_only(src, backlog: Path, dry_run: bool) -> None:
    """One-way, insert-only INTAKE from a read-only source (SPEC-004). Writes
    only the board file: no spoke write (the source has no write method), and
    no state file at all. Identity lives in the board row's own notes cell, so
    there is nothing to lose and a re-run recomputes exactly the missing rows.
    """
    text = backlog.read_text()
    prefix = detect_prefix(text)
    plan = plan_pull_only(text, src.read())
    header = f"{src.name}: {len(plan.board_add)} to intake"
    if dry_run:
        print(f"dry-run {header}")
        print(describe(plan))
        return
    new_text, assigned = apply_board(text, plan, prefix=prefix)
    if new_text != text:
        atomic_write(backlog, new_text)
    print(f"synced {header}")
    print(describe(plan, assigned))


def check_pull_isolation(names: list, args,
                         filters: dict | None = None) -> None:
    """Three refusals that keep a read-only intake read-only (SPEC-004).

    FILTER: this app takes none. The source board's own `Agent Queue` checkbox
    is the gate, and the pull path never consults `filt`, so accepting
    `--filter notion-taskboard-pull:intake=none` would hand an operator a
    guard that silently does nothing.

    ISOLATION: a pull app runs alone. Intake mints a board id, and a downstream
    spoke keys its own idempotency on that id, so an intake row must be
    published to git BEFORE anything relays it. Sharing one invocation would
    let a relay key on an id the publish step may still discard, which
    duplicates the relayed task on the next run. The runner sequences
    intake, publish, relay as separate invocations instead.

    TARGET: no other app may point at the pull source's own database. The pull
    adapter cannot write, but `notion` is two-way and hub-wins; aimed at the
    same board it would PATCH the very human-owned pages this app exists to
    leave alone, and trash them on a scope exit. The guard is on the engine
    because the adapter cannot see its siblings.
    """
    # The TARGET check runs whenever a pull database is configured, even on a
    # run that lists no pull app: `--apps notion` alone against that database
    # is exactly the write this guard exists to stop. Ids are compared with
    # dashes stripped, since Notion accepts both forms for the same database.
    target = (args.notion_taskboard_pull_db or "").replace("-", "")
    if target:
        clash = [k for k, v in
                 (("notion_db", args.notion_db),
                  ("notion_taskboard_db", args.notion_taskboard_db))
                 if v and v.replace("-", "") == target]
        if clash:
            sys.exit(f"{', '.join(clash)} points at the same database as "
                     "notion_taskboard_pull_db. That board is read-only by "
                     "contract; never aim a write-capable app at it.")
    filtered = sorted(set(filters or {}) & PULL_ONLY_APPS)
    if filtered:
        sys.exit(f"{filtered[0]}: this app takes no --filter; the source "
                 "board's own Agent Queue checkbox is the gate.")
    pull = [n for n in names if n in PULL_ONLY_APPS]
    others = [n for n in names if n not in PULL_ONLY_APPS]
    if pull and others:
        sys.exit(f"{pull[0]}: a pull app runs alone, but this invocation also "
                 f"lists {', '.join(others)}. Run intake first, publish the "
                 "board, then run the other apps (SPEC-004 design question 1).")


def sync_source(src, backlog: Path, state_path: Path, dry_run: bool,
                filt: dict | None = None, cap: int = 20,
                allow: int = 0) -> None:
    if getattr(src, "pull_only", False):
        return sync_pull_only(src, backlog, dry_run)
    if getattr(src, "create_only", False):
        return sync_create_only(src, backlog, state_path, dry_run, filt)
    text = backlog.read_text()
    prefix = detect_prefix(text)
    rows = parse_board(text, prefix=prefix)
    state = json.loads(state_path.read_text()) if state_path.exists() else {}
    if hasattr(src, "binding") and state.get("binding"):
        src.binding = state["binding"]
    items = src.read()
    plan = plan_sync(rows, items, state, sync_fields=src.sync_fields,
                     filt=filt)
    header = (f"{src.name}: {len(items)} spoke items, {len(rows)} board rows")
    preview = getattr(src, "preview", None)
    if preview:
        plan.notes.extend(preview(plan))
    if dry_run:
        print(f"dry-run {header}")
        print(describe(plan))
        return
    exits = len(plan.src_scope_exit)
    if exits > max(cap, allow):
        print(f"{src.name}: ABORTED, {exits} items would leave this app's "
              f"scope (cap {max(cap, allow)}). Review with --dry-run, then "
              f"re-run with --allow-scope-exit {exits}.")
        return
    new_text, assigned = apply_board(text, plan, prefix=prefix)
    if new_text != text:
        atomic_write(backlog, new_text)
    rows_after = parse_board(new_text, prefix=prefix)
    created = src.apply(plan, assigned, rows_after)
    new_state = build_state(rows_after, items, plan, created, assigned, state)
    if getattr(src, "binding", None):
        new_state["binding"] = src.binding
    state_path.parent.mkdir(parents=True, exist_ok=True)
    atomic_write(state_path, json.dumps(new_state, indent=1))
    print(f"synced {header}")
    print(describe(plan, assigned))


def board_state_dir(root: Path, backlog: Path) -> Path:
    slug = re.sub(r"[^a-zA-Z0-9]+", "-", str(backlog.resolve())).strip("-")
    d = root / slug
    if not d.exists():
        d.mkdir(parents=True, exist_ok=True)
        # adopt pre-slug flat state files (single-board era) once
        for f in root.glob("*.state.json"):
            shutil.move(str(f), d / f.name)
            print(f"migrated state {f.name} -> {d}")
    return d


def build_source(name: str, args):
    if name == "reminders":
        return RemindersSource(args.list_name or "Backlog")
    if name == "notion":
        return NotionSource(db=args.notion_db, parent=args.notion_parent)
    if name == "notion-taskboard":
        if not args.notion_taskboard_db:
            sys.exit("notion-taskboard: set notion_taskboard_db in [sync] "
                     "(.kit.toml) or pass --notion-taskboard-db")
        status_map = parse_map(args.notion_taskboard_status_map)
        if not status_map and not args.notion_taskboard_status_default:
            sys.exit("notion-taskboard: set notion_taskboard_status_map "
                     "(and/or notion_taskboard_status_default) in [sync]")
        props = json.loads(args.notion_taskboard_props) \
            if args.notion_taskboard_props else None
        types = json.loads(args.notion_taskboard_types) \
            if args.notion_taskboard_types else None
        return NotionTaskBoardSource(
            db=args.notion_taskboard_db, status_map=status_map,
            status_default=args.notion_taskboard_status_default,
            priority_map=parse_map(args.notion_taskboard_priority_map),
            weight_map=parse_map(args.notion_taskboard_weight_map),
            owner=args.notion_taskboard_owner, props=props, types=types)
    if name == "notion-taskboard-pull":
        if not args.notion_taskboard_pull_db:
            sys.exit("notion-taskboard-pull: set notion_taskboard_pull_db in "
                     "[sync] (.kit.toml) or pass --notion-taskboard-pull-db")
        props = json.loads(args.notion_taskboard_pull_props) \
            if args.notion_taskboard_pull_props else None
        return NotionTaskBoardPullSource(
            db=args.notion_taskboard_pull_db, props=props,
            done_option=args.notion_taskboard_pull_done_option or "Done")
    if name == "github":
        # repo empty is fine: gh resolves origin from the backlog's own repo
        # (KIT_PROJECT_ROOT), never the process cwd, which under launchd is
        # nowhere near the checkout.
        return GitHubSource(args.github_repo or "",
                            cwd=os.environ.get("KIT_PROJECT_ROOT"))
    if name == "hermes":
        if not args.hermes_home:
            sys.exit("hermes: set hermes_home in [sync] (.kit.toml) or pass "
                     "--hermes-home (the HERMES_HOME to sync against)")
        # Both keys name one operator's own instance, so neither carries a default:
        # guessing a target would point the sync at someone else's machine.
        if not args.hermes_target:
            sys.exit("hermes: set hermes_target in [sync] (.kit.toml) or pass "
                     "--hermes-target (an ssh host, 'local', or 'sudo:<user>')")
        return HermesSource(args.hermes_target,
                            args.hermes_home, board=args.hermes_board,
                            assignee=args.hermes_assignee,
                            workspace=args.hermes_workspace)
    if name == "multica":
        missing = [f for f, v in (("multica_url", args.multica_url),
                                  ("multica_workspace", args.multica_workspace),
                                  ("multica_project", args.multica_project))
                   if not v]
        if missing:
            sys.exit(f"multica: set {', '.join(missing)} in [sync] "
                     "(.kit.toml) or pass the matching --flags")
        return MulticaSource(args.multica_url, args.multica_workspace,
                             args.multica_project)
    sys.exit(f"unknown source {name!r}")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--apps", "--surfaces", "--sources", dest="apps",
                    default="reminders",
                    help="comma list of apps (cmd_sync fills this from "
                         ".kit.toml [sync] apps; --surfaces/--sources are "
                         "legacy aliases)")
    ap.add_argument("--backlog", type=Path,
                    default=Path.cwd() / "_meta" / "BACKLOG.md")
    ap.add_argument("--state-root", type=Path,
                    default=Path.home() / ".cache" / "backlog-sync")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--list", dest="list_name", help="Reminders list name")
    ap.add_argument("--notion-db", help="bind an existing Notion database id")
    ap.add_argument("--notion-parent",
                    help="Notion page id to create the board under (bootstrap)")
    ap.add_argument("--github-repo",
                    help="owner/repo for the github app (default: the cwd's "
                         "origin remote, as gh resolves it)")
    ap.add_argument("--hermes-target",
                    help="ssh host, or `local`, or `sudo:<user>` for an "
                         "instance owned by another uid on this host")
    ap.add_argument("--hermes-home")
    ap.add_argument("--hermes-board",
                    help="kanban board slug (default: the instance's own "
                         "current board)")
    ap.add_argument("--hermes-assignee",
                    help="profile name to assign every relayed task to")
    ap.add_argument("--hermes-workspace",
                    help="workspace for every relayed task, e.g. "
                         "'dir:/path/outbox/{id}'; `{id}` is the board id")
    ap.add_argument("--notion-taskboard-db",
                    help="target Notion database id for the one-way "
                         "insert-only Task Board push")
    ap.add_argument("--notion-taskboard-status-map",
                    help="board-state->option map, e.g. "
                         "'queued=Backlog,executing=In progress'")
    ap.add_argument("--notion-taskboard-status-default",
                    help="Status option for board states not in the map")
    ap.add_argument("--notion-taskboard-priority-map",
                    help="tag->Priority map, e.g. 'u-hi=P0,u-mid=P1,u-lo=P2'")
    ap.add_argument("--notion-taskboard-weight-map",
                    help="tag->Weight map, e.g. 'f-hi=2,f-mid=5,f-lo=13'")
    ap.add_argument("--notion-taskboard-owner",
                    help="Owner value (people-prop user id by default)")
    ap.add_argument("--notion-taskboard-props",
                    help="JSON overriding prop names "
                         "{title,status,priority,weight,owner,notes}")
    ap.add_argument("--notion-taskboard-types",
                    help="JSON overriding prop types "
                         "{status,priority,weight,owner}")
    ap.add_argument("--notion-taskboard-pull-db",
                    help="source Notion database id for the read-only "
                         "Task Board intake (SPEC-004)")
    ap.add_argument("--notion-taskboard-pull-props",
                    help="JSON overriding prop names "
                         "{title,status,notes,queue}")
    ap.add_argument("--notion-taskboard-pull-done-option",
                    help="Status option treated as done, and thus never "
                         "pulled (default: Done)")
    ap.add_argument("--multica-url", help="Multica server base URL")
    ap.add_argument("--multica-workspace", help="Multica workspace UUID")
    ap.add_argument("--multica-project", help="Multica project UUID")
    ap.add_argument("--filter", action="append", default=[],
                    help="app:key=value (key: only_tags|skip_tags|intake|"
                         "intake_skip_re); "
                         "repeatable; cmd_sync fills these from .kit.toml")
    ap.add_argument("--scope-exit-cap", type=int, default=20)
    ap.add_argument("--allow-scope-exit", type=int, default=0,
                    help="one-run override when a legitimate bulk exit "
                         "exceeds the cap")
    args = ap.parse_args(argv)

    filters: dict[str, dict] = {}
    for spec in args.filter:
        app, _, kv = spec.partition(":")
        key, _, val = kv.partition("=")
        if key in ("only_tags", "skip_tags"):
            filters.setdefault(app, {})[key] = {
                t.strip() for t in val.split(",") if t.strip()}
        elif key == "intake":
            filters.setdefault(app, {})[key] = val.strip()
        elif key == "intake_skip_re":
            try:
                re.compile(val)
            except re.error as exc:
                sys.exit(f"bad --filter intake_skip_re {val!r}: {exc}")
            filters.setdefault(app, {})[key] = val
        else:
            sys.exit(f"bad --filter key {key!r} "
                     "(only_tags|skip_tags|intake|intake_skip_re)")

    names = [s.strip() for s in args.apps.split(",") if s.strip()]
    # before any source is built, so a refused combination never touches a
    # transport or the board file
    check_pull_isolation(names, args, filters)

    if not args.backlog.exists():
        sys.exit(f"no backlog at {args.backlog}; pass --backlog or run via "
                 "`board sync` from an adopted repo")

    # worktree fence: spokes (a Reminders list, a Notion db) are shared per
    # BOARD, not per checkout. A sync run from a git worktree pairs the
    # spoke's items against that branch's divergent row set and poisons the
    # shared state for every other checkout (a 180-row cross-board fossil
    # map from exactly this, 2026-08-16, fed the 2026-09-01 dfoundation
    # title scramble). Only the canonical checkout may sync.
    if "/.claude/worktrees/" in str(args.backlog.resolve()) \
            and not os.environ.get("KIT_SYNC_ALLOW_WORKTREE"):
        sys.exit("board sync: refusing to sync a worktree checkout "
                 f"({args.backlog}); spokes are shared per board, and a "
                 "worktree's divergent rows poison them for every checkout. "
                 "Run from the canonical checkout, or set "
                 "KIT_SYNC_ALLOW_WORKTREE=1 if you truly know better.")

    state_dir = board_state_dir(args.state_root, args.backlog)
    # single-writer lock: overlapping runs would hand out colliding IDs and
    # clobber each other's board writes
    lock = open(state_dir / ".lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        sys.exit("another backlog-sync run holds the lock; try again")
    strict_id = not (set(names) & CREATE_ONLY_APPS)
    warn_duplicate_ids(args.backlog.read_text(), strict_id=strict_id)

    # one-time migration from the pre-kit single-source tool's state path
    rem_state = state_dir / "reminders.state.json"
    if not rem_state.exists() and LEGACY_REMINDERS_STATE.exists():
        shutil.copy(LEGACY_REMINDERS_STATE, rem_state)
        print(f"migrated legacy reminders state -> {rem_state}")

    for name in names:
        state_path = state_dir / f"{name}.state.json"
        if name == "notion":
            has_binding = (state_path.exists() and
                           json.loads(state_path.read_text()).get("binding"))
            if not (has_binding or args.notion_db or args.notion_parent):
                print("notion: skipped (no binding; set notion_db/notion_parent"
                      " in [sync] (.kit.toml) or pass --notion-db)")
                continue
        src = build_source(name, args)
        sync_source(src, args.backlog, state_path, args.dry_run,
                    filt=filters.get(name), cap=args.scope_exit_cap,
                    allow=args.allow_scope_exit)


if __name__ == "__main__":
    main()
