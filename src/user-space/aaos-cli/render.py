"""TTY tables and --json for Control1 replies. No bus I/O."""
from __future__ import annotations

import json
import sys


def _yn(value):
    return "yes" if value else "no"


def _cell(value):
    if isinstance(value, bool):
        return _yn(value)
    if value is None:
        return ""
    return str(value)


def table(rows, columns, out=None):
    out = sys.stdout if out is None else out
    if not rows:
        return
    widths = [len(title) for _, title in columns]
    rendered = []
    for row in rows:
        cells = [_cell(row.get(key)) for key, _title in columns]
        rendered.append(cells)
        for i, cell in enumerate(cells):
            if len(cell) > widths[i]:
                widths[i] = len(cell)
    header = "  ".join(title.ljust(widths[i]) for i, (_key, title) in enumerate(columns))
    print(header, file=out)
    print("  ".join("-" * widths[i] for i in range(len(columns))), file=out)
    for cells in rendered:
        print("  ".join(cells[i].ljust(widths[i]) for i in range(len(columns))), file=out)


def as_json(payload, out=None):
    out = sys.stdout if out is None else out
    print(json.dumps(payload, indent=2, sort_keys=True, default=str), file=out)


def health(row, *, as_json_out=False, out=None):
    if as_json_out:
        as_json(row, out=out)
        return
    table(
        [row],
        [
            ("alive", "ALIVE"),
            ("operator", "OPERATOR"),
            ("fetch_bound", "FETCH"),
            ("fuse_mounted", "FUSE"),
            ("tick", "TICK"),
            ("observed_at", "OBSERVED"),
        ],
        out=out,
    )


def missions(rows, *, as_json_out=False, out=None):
    out = sys.stdout if out is None else out
    if as_json_out:
        as_json(rows, out=out)
        return
    if not rows:
        print("no missions", file=out)
        return
    table(
        rows,
        [
            ("mission_id", "MISSION"),
            ("status", "STATUS"),
            ("approval_required", "NEEDS APPROVAL"),
            ("title", "TITLE"),
            ("updated", "UPDATED"),
        ],
        out=out,
    )


def tasks(rows, *, as_json_out=False, out=None):
    out = sys.stdout if out is None else out
    if as_json_out:
        as_json(rows, out=out)
        return
    if not rows:
        print("no tasks", file=out)
        return
    table(
        rows,
        [
            ("task_id", "TASK"),
            ("mission_id", "MISSION"),
            ("status", "STATUS"),
            ("awaiting_approval", "AWAITING"),
            ("title", "TITLE"),
        ],
        out=out,
    )


def approved(row, *, as_json_out=False, out=None):
    out = sys.stdout if out is None else out
    if as_json_out:
        as_json(row, out=out)
        return
    print(
        f"{row.get('task_id', '')}  {row.get('status', '')}  approved={_yn(row.get('approved'))}",
        file=out,
    )
