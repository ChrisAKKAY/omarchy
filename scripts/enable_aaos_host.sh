#!/bin/bash
# Enable AAOS memory FUSE + C2 on this host. Linux / 4of9 only.
# Installs units, runs preflight, then enable --now. Refuses otherwise.
set -euo pipefail

status() { printf '[aaos-enable] %s\n' "$*"; }
refuse() { printf '[aaos-enable] refuse: %s\n' "$*" >&2; exit 1; }

[[ $(uname -s) == Linux ]] || refuse "enablement is Linux-only"
host=$(hostname -s 2>/dev/null || hostname)
if [[ ${AAOS_FORCE_ENABLE:-} != 1 ]]; then
  [[ $host == 4of9 ]] || refuse "hostname is $host, not 4of9 (set AAOS_FORCE_ENABLE=1 to override)"
fi

(( EUID == 0 )) || refuse "enablement must run as root"

command -v systemctl >/dev/null || refuse "systemctl is missing"
command -v bindfs >/dev/null || refuse "bindfs is missing (FUSE helper)"
command -v nft >/dev/null || refuse "nft is missing (C2 egress table)"

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
omarchy=$(cd -- "$here/.." && pwd)
aaos=${AAOS_ROOT:-/opt/aaos}

[[ -f $here/aaos-memory-fuse ]] || refuse "aaos-memory-fuse helper is missing"
[[ -f $here/aaos-c2-bus ]] || refuse "aaos-c2-bus binding is missing"
[[ -f $omarchy/default/systemd/system/aaos-c2.service ]] || refuse "aaos-c2.service is missing"
[[ -f $omarchy/default/systemd/system/aaos-c2-dbus.service ]] || refuse "aaos-c2-dbus.service is missing"
[[ -f $omarchy/default/systemd/system/aaos-c2-nftables.service ]] || refuse "aaos-c2-nftables.service is missing"
[[ -f $omarchy/etc/nftables.d/aaos-c2.nft ]] || refuse "aaos-c2 nftables table is missing"
[[ -f $omarchy/default/systemd/system/mnt-aaos-fuse.mount ]] || refuse "mnt-aaos-fuse.mount is missing"
[[ -f $omarchy/default/systemd/system/aaos-memory-fuse.service ]] || refuse "aaos-memory-fuse.service is missing"
[[ -f $aaos/scripts/aaos_c2.py ]] || refuse "aaos_c2.py is not at $aaos/scripts/aaos_c2.py"
[[ -f $aaos/scripts/aaos_c2_dbus.py ]] || refuse "aaos_c2_dbus.py is not at $aaos/scripts/aaos_c2_dbus.py"

status "installing helper and units"
install -D -m 0755 "$here/aaos-memory-fuse" /usr/sbin/aaos-memory-fuse
install -D -m 0755 "$here/aaos-c2-bus" /usr/sbin/aaos-c2-bus
install -D -m 0644 "$omarchy/default/systemd/system/mnt-aaos-fuse.mount" \
  /etc/systemd/system/mnt-aaos-fuse.mount
install -D -m 0644 "$omarchy/default/systemd/system/aaos-memory-fuse.service" \
  /etc/systemd/system/aaos-memory-fuse.service
install -D -m 0644 "$omarchy/default/systemd/system/aaos-c2.service" \
  /etc/systemd/system/aaos-c2.service
install -D -m 0644 "$omarchy/default/systemd/system/aaos-c2-dbus.service" \
  /etc/systemd/system/aaos-c2-dbus.service
install -D -m 0644 "$omarchy/default/systemd/system/aaos-c2-nftables.service" \
  /etc/systemd/system/aaos-c2-nftables.service
install -D -m 0644 "$omarchy/etc/nftables.d/aaos-c2.nft" /etc/nftables.d/aaos-c2.nft
install -D -m 0644 "$omarchy/etc/sysusers.d/aaos-c2.conf" /etc/sysusers.d/aaos-c2.conf
install -D -m 0644 "$omarchy/etc/tmpfiles.d/aaos-c2.conf" /etc/tmpfiles.d/aaos-c2.conf
install -D -m 0644 "$omarchy/etc/dbus-1/system.d/aaos-c2.conf" /etc/dbus-1/system.d/aaos-c2.conf
if command -v systemctl >/dev/null; then
  systemctl reload dbus.service 2>/dev/null || systemctl reload dbus 2>/dev/null || true
fi
if [[ -d /etc/fuse.conf.d ]]; then
  printf '%s\n' 'user_allow_other' >/etc/fuse.conf.d/aaos-memory.conf
elif [[ -f /etc/fuse.conf ]] && ! grep -qx 'user_allow_other' /etc/fuse.conf; then
  printf '\n%s\n' 'user_allow_other' >>/etc/fuse.conf
fi

status "applying sysusers and tmpfiles"
systemd-sysusers aaos-c2.conf
systemd-tmpfiles --create "$omarchy/etc/tmpfiles.d/aaos-c2.conf"

status "FUSE preflight"
[[ -d /knowledge && -d /mnt/aaos/fuse ]] || refuse "knowledge or fuse mountpoint missing"
command -v bindfs >/dev/null || refuse "bindfs is missing"

status "C2 preflight (--check only)"
export AAOS_STORE=/store AAOS_KNOWLEDGE=/knowledge AAOS_TRACES=/traces AAOS_C2_OPERATOR=k
export PATH=/usr/bin:/bin PYTHONNOUSERSITE=1
/usr/bin/env python3.12 "$aaos/scripts/aaos_c2.py" --root "$aaos" --check \
  || refuse "aaos_c2.py --check failed"
export AAOS_ROOT="$aaos"
/usr/bin/env python3.12 /usr/sbin/aaos-c2-bus --root "$aaos" --check \
  || refuse "aaos-c2-bus --check failed"

status "reloading systemd and enabling FUSE then C2"
systemctl daemon-reload
if systemctl enable --now mnt-aaos-fuse.mount; then
  status "mnt-aaos-fuse.mount is active"
else
  status "fuse.bindfs .mount failed; falling back to aaos-memory-fuse.service"
  systemctl disable --now mnt-aaos-fuse.mount || true
  systemctl enable --now aaos-memory-fuse.service
  systemctl is-active --quiet aaos-memory-fuse.service || refuse "FUSE helper is not active"
fi
findmnt -n -M /mnt/aaos/fuse >/dev/null || refuse "FUSE mount is not visible"
fstype=$(findmnt -n -o FSTYPE -M /mnt/aaos/fuse || true)
[[ $fstype == fuse* ]] || refuse "mount at /mnt/aaos/fuse is $fstype, not FUSE"

systemctl enable --now aaos-c2-nftables.service
systemctl is-active --quiet aaos-c2-nftables.service || refuse "aaos-c2-nftables.service is not active"
systemctl enable --now aaos-c2.service
systemctl is-active --quiet aaos-c2.service || refuse "aaos-c2.service is not active"
systemctl enable --now aaos-c2-dbus.service
systemctl is-active --quiet aaos-c2-dbus.service || refuse "aaos-c2-dbus.service is not active"

status "active: FUSE at /mnt/aaos/fuse, aaos-c2.service, and aaos-c2-dbus.service"
systemctl is-enabled mnt-aaos-fuse.mount || true
systemctl is-enabled aaos-c2.service
systemctl is-enabled aaos-c2-dbus.service
status "enablement complete"
