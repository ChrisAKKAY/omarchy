"""Control1 D-Bus client. Fake bus for tests until AAOS exports the interface."""
from __future__ import annotations

import os

BUS_NAME = "org.akkay.aaos.C2"
OBJECT_PATH = "/org/akkay/aaos/C2"
INTERFACE = "org.akkay.aaos.C2.Control1"

ERROR_UNAVAILABLE = "org.akkay.aaos.C2.Error.Unavailable"
ERROR_REFUSED = "org.akkay.aaos.C2.Error.Refused"
ERROR_UNKNOWN_METHOD = "org.freedesktop.DBus.Error.UnknownMethod"
ERROR_ACCESS = "org.freedesktop.DBus.Error.AccessDenied"

CONTROL_MISSING = "org.akkay.aaos.C2.Control1 is not on the bus"


class BusError(RuntimeError):
    """Named D-Bus failure. The CLI prints error_name and detail and does not retry."""

    def __init__(self, error_name, detail=""):
        super().__init__(detail or error_name)
        self.error_name = error_name
        self.detail = detail or error_name


def _sv_plain(value):
    if hasattr(value, "unpack"):
        return _sv_plain(value.unpack())
    if isinstance(value, dict):
        return {str(k): _sv_plain(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_sv_plain(v) for v in value]
    return value


class FakeBus:
    """In-process Control1. No files. Used when AAOS_BUS=fake."""

    def __init__(self):
        self.health = {
            "alive": True,
            "operator": "k",
            "fetch_bound": True,
            "fuse_mounted": True,
            "tick": 7,
            "observed_at": "2026-09-22T08:00:00Z",
        }
        self.missions = [
            {
                "mission_id": "M-001",
                "title": "Governed mission spine",
                "status": "awaiting_approval",
                "approval_required": True,
                "updated": "2026-09-22T08:00:00Z",
            }
        ]
        self.tasks = [
            {
                "task_id": "T-001",
                "mission_id": "M-001",
                "title": "Sprint 1 soak",
                "status": "awaiting_approval",
                "awaiting_approval": True,
                "updated": "2026-09-22T08:00:00Z",
            }
        ]

    def get_health(self):
        return dict(self.health)

    def list_missions(self):
        return [dict(row) for row in self.missions]

    def list_tasks(self, mission_id=""):
        mission_id = (mission_id or "").strip()
        rows = [dict(row) for row in self.tasks]
        if mission_id:
            rows = [row for row in rows if row.get("mission_id") == mission_id]
        else:
            rows = [row for row in rows if row.get("awaiting_approval")]
        return rows

    def approve_task(self, task_id, reason=""):
        task_id = (task_id or "").strip()
        for row in self.tasks:
            if row.get("task_id") != task_id:
                continue
            if not row.get("awaiting_approval"):
                raise BusError(ERROR_REFUSED, f"{task_id} is not awaiting approval")
            row["awaiting_approval"] = False
            row["status"] = "approved"
            return {
                "task_id": task_id,
                "status": "approved",
                "approved": True,
                "observed_at": row.get("updated") or "",
                "reason": reason or "",
            }
        raise BusError(ERROR_REFUSED, f"{task_id} is not a known task")


class GioBus:
    """Live system bus. Gio is imported here so FakeBus tests do not need PyGObject."""

    def get_health(self):
        unpacked = self._call("GetHealth", "", ())
        return dict(_sv_plain(unpacked[0]) if unpacked else {})

    def list_missions(self):
        unpacked = self._call("ListMissions", "", ())
        return [_sv_plain(row) for row in (unpacked[0] if unpacked else [])]

    def list_tasks(self, mission_id=""):
        unpacked = self._call("ListTasks", "s", ((mission_id or ""),))
        return [_sv_plain(row) for row in (unpacked[0] if unpacked else [])]

    def approve_task(self, task_id, reason=""):
        unpacked = self._call("ApproveTask", "ss", (task_id, reason or ""))
        return dict(_sv_plain(unpacked[0]) if unpacked else {})

    def _call(self, method, in_signature, args):
        try:
            import gi
            gi.require_version("Gio", "2.0")
            gi.require_version("GLib", "2.0")
            from gi.repository import Gio, GLib
        except (ImportError, ValueError) as exc:
            raise BusError(ERROR_UNAVAILABLE, f"PyGObject Gio is missing ({exc})") from exc
        try:
            conn = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
        except GLib.Error as exc:
            raise BusError(ERROR_UNAVAILABLE, str(exc)) from exc
        parameters = None
        if in_signature:
            parameters = GLib.Variant(f"({in_signature})", args)
        try:
            reply = conn.call_sync(
                BUS_NAME,
                OBJECT_PATH,
                INTERFACE,
                method,
                parameters,
                None,
                Gio.DBusCallFlags.NONE,
                8000,
                None,
            )
        except GLib.Error as exc:
            raise BusError(_glib_error_name(exc), str(exc)) from exc
        return reply.unpack() if reply is not None else ()


def _glib_error_name(exc):
    message = str(exc)
    for name in (ERROR_UNKNOWN_METHOD, ERROR_ACCESS, ERROR_REFUSED, ERROR_UNAVAILABLE):
        if name in message:
            return name
    if "UnknownMethod" in message or "unknown method" in message.lower():
        return ERROR_UNKNOWN_METHOD
    if "AccessDenied" in message or "access denied" in message.lower():
        return ERROR_ACCESS
    return ERROR_UNAVAILABLE


def connect():
    mode = (os.environ.get("AAOS_BUS") or "live").strip().lower()
    if mode == "fake":
        return FakeBus()
    if mode == "missing":
        raise BusError(ERROR_UNKNOWN_METHOD, CONTROL_MISSING)
    return GioBus()
