#!/bin/bash

set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"

helper="$ROOT/scripts/aaos-memory-fuse"
enable="$ROOT/scripts/enable_aaos_host.sh"
[[ -f $helper && -f $enable ]] || fail "FUSE helper and enable script are present"

! grep -E 'systemctl[[:space:]]+enable' "$ROOT/scripts/deploy_to_node.sh" >/dev/null \
  || fail "deploy_to_node must not enable units"

grep -q 'WantedBy=multi-user.target' "$ROOT/default/systemd/system/mnt-aaos-fuse.mount" \
  || fail "FUSE mount survives reboot"
grep -q 'WantedBy=multi-user.target' "$ROOT/default/systemd/system/aaos-c2.service" \
  || fail "C2 service survives reboot"
grep -q 'mnt-aaos-fuse.mount' "$ROOT/default/systemd/system/aaos-c2.service" \
  || fail "C2 waits for FUSE mount"
grep -q 'Where=/mnt/aaos/fuse' "$ROOT/default/systemd/system/mnt-aaos-fuse.mount" \
  || fail "FUSE Where matches the unit name"
grep -q '^Options=ro,' "$ROOT/default/systemd/system/mnt-aaos-fuse.mount" \
  || fail "FUSE unit starts with ro"
! grep -q 'nofail' "$ROOT/default/systemd/system/mnt-aaos-fuse.mount" \
  || fail "FUSE unit must not use nofail"
! grep -q 'ConditionPathIsDirectory=/knowledge' "$ROOT/default/systemd/system/mnt-aaos-fuse.mount" \
  || fail "missing knowledge must fail the mount, not skip it"
grep -q 'knowledge tree is missing' "$helper" || fail "helper refuses a missing backing store"
! grep -q 'd /knowledge' "$ROOT/etc/tmpfiles.d/aaos-c2.conf" \
  || fail "tmpfiles must not stub /knowledge"
grep -q 'host == 4of9' "$enable" || fail "enable script requires exact hostname 4of9"
grep -q 'User=aaos-c2' "$ROOT/default/systemd/system/aaos-c2.service" \
  || fail "C2 drops privileges to aaos-c2"
grep -q 'enable --now mnt-aaos-fuse.mount' "$enable" || fail "enable script starts the FUSE mount"
grep -q 'hostname is' "$enable" || fail "enable script is host-gated"

err=$(mktemp)
trap 'rm -f "$err"' EXIT
if [[ $(uname -s) != Linux ]]; then
  ! "$helper" >/dev/null 2>"$err" || fail "helper must refuse off Linux"
  grep -q 'Linux-only' "$err" || fail "helper names the Linux refusal"
  ! "$enable" >/dev/null 2>"$err" || fail "enable must refuse off Linux"
  grep -q 'Linux-only' "$err" || fail "enable names the Linux refusal"
fi

pass "FUSE helper and host enablement fail closed off the target"
