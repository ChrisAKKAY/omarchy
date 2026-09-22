#!/bin/bash
# aaos CLI talks to Control1 over D-Bus (or AAOS_BUS=fake). It must not read store files.
# Sandboxed agents must not be allowed to send Control1 / ApproveTask.

set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"

cli="$ROOT/bin/aaos"
py="$ROOT/src/user-space/aaos-cli/aaos.py"
buspy="$ROOT/src/user-space/aaos-cli/bus.py"
fmt="$ROOT/src/user-space/aaos-cli/render.py"
policy="$ROOT/etc/dbus-1/system.d/aaos-c2.conf"
[[ -f $cli && -f $py && -f $buspy && -f $fmt ]] || fail "aaos CLI sources are present"

export OMARCHY_PATH="$ROOT"
aaos() { bash "$cli" "$@"; }

! grep -E '/store|/traces|HEARTBEAT_NAME' "$py" "$buspy" "$fmt" >/dev/null \
  || fail "CLI must not name store or traces paths"
! grep -E '\bopen\(' "$py" "$fmt" >/dev/null \
  || fail "CLI router/format must not open files"
pass "CLI source does not read store trees"

grep -q 'send_interface="org.akkay.aaos.C2.Control1"' "$policy" ||
  fail "dbus allows Control1 for aaos-ui"
grep -q 'deny send_interface="org.akkay.aaos.C2.Control1"' "$policy" ||
  fail "dbus denies Control1 for aaos-agent"
grep -q 'deny send_member="ApproveTask"' "$policy" ||
  fail "dbus denies ApproveTask to aaos-agent"
grep -q 'send_interface="org.akkay.aaos.C2.Fetch1"' "$policy" ||
  fail "dbus still allows Fetch1 for aaos-agent"
pass "sandboxed agents cannot send Control1 or ApproveTask"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

AAOS_BUS=missing aaos status >"$work/out" 2>"$work/err" && fail "missing Control1 must fail" || true
grep -q 'org.akkay.aaos.C2.Control1 is not on the bus' "$work/err" ||
  fail "missing bus names Control1" "$(<"$work/err")"
! grep -q '/store' "$work/err" || fail "missing-bus error must not mention store paths"
pass "missing Control1 refuses without file fallback"

if ! command -v python3 >/dev/null; then
  printf 'ok - # SKIP no python3 to exercise fake bus\n'
  exit 0
fi

AAOS_BUS=fake aaos status >"$work/status" 2>"$work/err" || fail "fake status" "$(<"$work/err")"
grep -q 'OPERATOR' "$work/status" || fail "status prints a health table" "$(<"$work/status")"
grep -q 'k' "$work/status" || fail "status shows operator k"

AAOS_BUS=fake aaos --json status >"$work/status.json" 2>"$work/err" || fail "json status"
grep -q '"alive"' "$work/status.json" || fail "json status includes alive"

AAOS_BUS=fake aaos missions >"$work/missions" 2>"$work/err" || fail "fake missions"
grep -q 'M-001' "$work/missions" || fail "missions lists M-001" "$(<"$work/missions")"

AAOS_BUS=fake aaos tasks >"$work/tasks" 2>"$work/err" || fail "fake tasks"
grep -q 'T-001' "$work/tasks" || fail "tasks lists T-001"

AAOS_BUS=fake aaos approve T-001 >"$work/approve" 2>"$work/err" || fail "fake approve" "$(<"$work/err")"
grep -q 'T-001' "$work/approve" || fail "approve prints task id"
grep -qi 'approved' "$work/approve" || fail "approve prints approved"

AAOS_BUS=fake aaos approve T-999 >"$work/bad" 2>"$work/err" && fail "unknown task must refuse" || true
grep -q 'org.akkay.aaos.C2.Error.Refused' "$work/err" ||
  fail "unknown task is Refused" "$(<"$work/err")"

! aaos >/dev/null 2>"$work/err" || fail "missing subcommand must fail"
grep -q 'usage:' "$work/err" || fail "missing subcommand prints usage"

pass "fake bus status/missions/approve work and refusals stay named"
