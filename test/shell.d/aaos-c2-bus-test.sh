#!/bin/bash
# The Omarchy bus binding owns org.akkay.aaos.C2 and must not grow a policy of its own.

set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"

bus="$ROOT/scripts/aaos-c2-bus"
unit="$ROOT/default/systemd/system/aaos-c2-dbus.service"
c2="$ROOT/default/systemd/system/aaos-c2.service"
spawn="$ROOT/scripts/spawn_agent_sandbox.sh"
enable="$ROOT/scripts/enable_aaos_host.sh"
policy="$ROOT/etc/dbus-1/system.d/aaos-c2.conf"

[[ -f $bus ]] || fail "aaos-c2-bus is present"
[[ -f $unit ]] || fail "aaos-c2-dbus.service is present"

grep -q 'import aaos_c2_dbus' "$bus" || fail "binding must import aaos_c2_dbus"
grep -q 'dbus.dispatch' "$bus" || fail "binding must call dispatch"
grep -q 'org.akkay.aaos.C2' "$bus" || fail "binding names org.akkay.aaos.C2"
grep -q 'return_dbus_error' "$bus" || fail "binding raises named D-Bus errors"
if grep -qE 'print\(.*body|log.*body' "$bus"; then
  fail "binding must not log the fetched body"
fi
pass "binding is a thin dispatch wrapper"

grep -q '^Type=dbus' "$unit" || fail "aaos-c2-dbus.service is Type=dbus"
grep -q '^BusName=org.akkay.aaos.C2' "$unit" || fail "aaos-c2-dbus.service claims org.akkay.aaos.C2"
grep -q 'ExecStart=/usr/bin/env python3.12 /usr/sbin/aaos-c2-bus' "$unit" ||
  fail "aaos-c2-dbus ExecStart runs the Omarchy binding"
grep -q '^NFTSet=cgroup:inet:aaos:aaos_c2_cgroup' "$unit" ||
  fail "dbus unit shares the C2 nftables set"
grep -q 'RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6' "$unit" ||
  fail "dbus unit allows UNIX plus DNS/HTTPS families"
if grep -qE '^PrivateNetwork=' "$unit"; then
  fail "dbus unit must not set PrivateNetwork"
fi
if grep -qE '^IPAddressDeny=' "$unit"; then
  fail "dbus unit must not set IPAddressDeny"
fi
pass "aaos-c2-dbus.service owns the name with Option B egress"

grep -q 'Wants=.*aaos-c2-dbus.service' "$c2" ||
  fail "aaos-c2.service must want the bus binding"
grep -q 'install -D -m 0755 .*aaos-c2-bus' "$enable" ||
  fail "enable script installs aaos-c2-bus"
grep -q 'enable --now aaos-c2-dbus.service' "$enable" ||
  fail "enable script starts the bus binding"
pass "enablement installs and starts the binding"

grep -q -- '--volume /run/dbus/system_bus_socket:/run/dbus/system_bus_socket:ro' "$spawn" ||
  fail "sandbox still bind-mounts the system bus socket"
grep -q -- 'DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket' "$spawn" ||
  fail "sandbox still sets DBUS_SYSTEM_BUS_ADDRESS"
grep -q 'deny own="org.akkay.aaos.C2"' "$policy" ||
  fail "default dbus policy still denies owning org.akkay.aaos.C2"
grep -q 'allow own="org.akkay.aaos.C2"' "$policy" ||
  fail "aaos-c2 may own org.akkay.aaos.C2"
grep -q 'deny send_interface="org.akkay.aaos.C2.Control1"' "$policy" ||
  fail "dbus denies Control1 to aaos-agent"
grep -q 'deny send_member="ApproveTask"' "$policy" ||
  fail "dbus denies ApproveTask to aaos-agent"
pass "sandbox can reach a bus that is allowed to list org.akkay.aaos.C2"

# Marshalling without Gio: handle_call must pass arguments through dispatch unchanged.
if ! command -v python3 >/dev/null && ! command -v py >/dev/null; then
  printf 'ok - # SKIP no python to exercise handle_call\n'
  exit 0
fi

py=python3
command -v python3 >/dev/null || py='py -3.12'

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/aaos"
cat >"$work/aaos/aaos_c2.py" <<'PY'
class C2Error(RuntimeError):
    pass
def preflight(root=None, env=None):
    return {"AAOS_TRACES": None}, "test-actor"
PY
cat >"$work/aaos/aaos_c2_dbus.py" <<'PY'
BUS_NAME = "org.akkay.aaos.C2"
OBJECT_PATH = "/org/akkay/aaos/C2"
INTERFACE = "org.akkay.aaos.C2.Fetch1"
class Reply:
    def __init__(self, ok, error_name="", detail="", body=b"", meta=None):
        self.ok = ok
        self.error_name = error_name
        self.detail = detail
        self.body = body
        self.meta = meta or {}
CALLS = []
def dispatch(method, args, *, root, trees, actor, **kwargs):
    CALLS.append((method, tuple(args), str(root), actor))
    if method == "FetchURL":
        return Reply(True, body=b"abc", meta={"status": 200, "source_id": "s1"})
    return Reply(True, meta={"sources": [{"host": "example.com", "port": 443}]})
def introspect():
    return "<node/>"
PY

export AAOS_ROOT="$work"
# The binding inserts AAOS_ROOT/scripts. Point it at the stub dir.
mkdir -p "$work/scripts"
cp "$work/aaos/"*.py "$work/scripts/"
export AAOS_ROOT="$work"

code='
import os, sys
from pathlib import Path
path = Path(os.environ["BUS"])
ns = {"__name__": "aaos_c2_bus"}
exec(compile(path.read_text(encoding="utf-8"), str(path), "exec"), ns)
surface = ns["load_surface"]()
root = Path(os.environ["AAOS_ROOT"])
reply = ns["handle_call"](surface, "FetchURL", ["https://example.com/", "AG-001"],
                          root=root, trees={"AAOS_TRACES": None}, actor="test-actor")
assert reply.ok and reply.body == b"abc", reply
body, meta = ns["payload_for_reply"]("FetchURL", reply)
assert body == b"abc" and meta["status"] == 200
stub = sys.modules["aaos_c2_dbus"]
assert stub.CALLS[0][0] == "FetchURL"
assert stub.CALLS[0][1] == ("https://example.com/", "AG-001")
'
BUS=$bus AAOS_ROOT=$work $py -c "$code" || fail "handle_call must pass arguments through dispatch"
pass "handle_call passes arguments through dispatch"
