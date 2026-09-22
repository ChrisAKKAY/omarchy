#!/usr/bin/env python3
"""aaos — operator CLI for org.akkay.aaos.C2.Control1. Bus only. No store reads."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import bus
import render as fmt


USAGE = "usage: aaos [--json] <status|missions|tasks|approve> [id]"


def _fail(error):
    if isinstance(error, bus.BusError):
        print(f"refuse: {error.error_name}: {error.detail}", file=sys.stderr)
        return 1
    print(f"refuse: {error}", file=sys.stderr)
    return 1


def cmd_status(client, args):
    fmt.health(client.get_health(), as_json_out=args.json)
    return 0


def cmd_missions(client, args):
    fmt.missions(client.list_missions(), as_json_out=args.json)
    return 0


def cmd_tasks(client, args):
    fmt.tasks(client.list_tasks(args.mission_id or ""), as_json_out=args.json)
    return 0


def cmd_approve(client, args):
    task_id = (args.task_id or "").strip()
    if not task_id:
        print("refuse: approve requires a task id", file=sys.stderr)
        return 2
    fmt.approved(
        client.approve_task(task_id, args.reason or ""),
        as_json_out=args.json,
    )
    return 0


def build_parser():
    parser = argparse.ArgumentParser(prog="aaos")
    sub = parser.add_subparsers(dest="command")

    sub.add_parser("status", help="GetHealth")
    sub.add_parser("missions", help="ListMissions")

    tasks = sub.add_parser("tasks", help="ListTasks")
    tasks.add_argument("mission_id", nargs="?", default="")

    approve = sub.add_parser("approve", help="ApproveTask")
    approve.add_argument("task_id")
    approve.add_argument("--reason", default="")
    return parser


def main(argv=None):
    argv = list(argv if argv is not None else sys.argv[1:])
    as_json = False
    if "--json" in argv:
        as_json = True
        argv = [a for a in argv if a != "--json"]
    parser = build_parser()
    args = parser.parse_args(argv)
    args.json = as_json
    if not args.command:
        print(USAGE, file=sys.stderr)
        return 2
    try:
        client = bus.connect()
    except bus.BusError as exc:
        return _fail(exc)
    commands = {
        "status": cmd_status,
        "missions": cmd_missions,
        "tasks": cmd_tasks,
        "approve": cmd_approve,
    }
    try:
        return commands[args.command](client, args)
    except bus.BusError as exc:
        return _fail(exc)


if __name__ == "__main__":
    raise SystemExit(main())
