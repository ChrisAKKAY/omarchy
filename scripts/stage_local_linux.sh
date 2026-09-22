#!/bin/bash
# Local systemd staging when the physical 4of9 node is unreachable.
# Provisions trees, copies the AAOS payload, then enable --now via AAOS_FORCE_ENABLE=1.
# Does not write Windows hosts or ~/.ssh/config.
set -euo pipefail

status() { printf '[aaos-local] %s\n' "$*"; }
refuse() { printf '[aaos-local] refuse: %s\n' "$*" >&2; exit 1; }

[[ $(uname -s) == Linux ]] || refuse "local staging is Linux-only"
command -v systemctl >/dev/null || refuse "systemd is missing"
systemctl is-system-running --wait >/dev/null 2>&1 \
  || [[ $(systemctl is-system-running 2>/dev/null || true) == running ]] \
  || refuse "systemd is not running"
(( EUID == 0 )) || refuse "local staging must run as root"

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
omarchy=$(cd -- "$here/.." && pwd)

if [[ -n ${AAOS_ROOT:-} ]]; then
  aaos_src=$(cd -- "$AAOS_ROOT" && pwd)
else
  sibling_a="$omarchy/../AKKAY Agentic OS"
  sibling_b="$omarchy/../AkkayAgenticOS"
  if [[ -d $sibling_a/scripts ]]; then
    aaos_src=$(cd -- "$sibling_a" && pwd)
  elif [[ -d $sibling_b/scripts ]]; then
    aaos_src=$(cd -- "$sibling_b" && pwd)
  else
    refuse "AAOS_ROOT is unset and no sibling AAOS checkout was found"
  fi
fi

[[ -f $aaos_src/scripts/aaos_c2.py ]] || refuse "aaos_c2.py is missing from $aaos_src"
[[ -f $aaos_src/config/operators.json ]] || refuse "config/operators.json is missing (C2 will refuse operator k)"

host=$(hostname -s 2>/dev/null || hostname)
if [[ $host == 4of9 ]]; then
  status "this host is 4of9; handing off to enable_aaos_host.sh"
  exec "$here/enable_aaos_host.sh"
fi

status "installing FUSE tools if missing"
if ! command -v bindfs >/dev/null; then
  command -v apt-get >/dev/null || refuse "bindfs is missing and apt-get is not available"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y bindfs fuse3
fi
command -v bindfs >/dev/null || refuse "bindfs is still missing"
[[ -e /dev/fuse ]] || refuse "/dev/fuse is missing"

if ! command -v python3.12 >/dev/null; then
  py=$(command -v python3 || true)
  [[ -n $py ]] || refuse "python3 is missing and python3.12 is required by aaos-c2.service"
  status "installing /usr/bin/python3.12 shim -> $py (local staging only)"
  ln -sfn "$py" /usr/bin/python3.12
fi
command -v python3.12 >/dev/null || refuse "python3.12 is missing"

status "installing AAOS payload at /opt/aaos"
install -d -m 0755 /opt/aaos/scripts /opt/aaos/config
if command -v rsync >/dev/null; then
  rsync -a --delete --exclude '__pycache__/' --exclude '.git/' \
    "$aaos_src/scripts/" /opt/aaos/scripts/
  rsync -a --exclude '.git/' "$aaos_src/config/" /opt/aaos/config/
else
  cp -a "$aaos_src/scripts/." /opt/aaos/scripts/
  cp -a "$aaos_src/config/." /opt/aaos/config/
fi
systemd-sysusers "$omarchy/etc/sysusers.d/aaos-c2.conf"
chmod 0755 /opt/aaos /opt/aaos/scripts /opt/aaos/config
chown -R root:root /opt/aaos
chown root:aaos-c2 /opt/aaos/config/operators.json
chmod 0640 /opt/aaos/config/operators.json

# AEAC deny-by-default for the agent runtime. Installed AFTER systemd-sysusers, so
# aaos-c2 and aaos-ui exist and the rule has subjects to match.
#
# Root-owned and 0644: polkit refuses to load a rules file that is group- or
# world-writable, and a rule the agent runtime could edit is not a rule.
status "installing polkit AEAC rule"
aeac_rule=$omarchy/etc/polkit-1/rules.d/49-aaos-aeac.rules
[[ -f $aeac_rule ]] || refuse "polkit AEAC rule is missing: $aeac_rule"
if [[ ! -d /etc/polkit-1/rules.d ]]; then
  # polkit >= 0.106 is what reads .rules at all. An older polkit silently ignores the
  # whole directory, so its absence is reported rather than created and assumed.
  refuse "/etc/polkit-1/rules.d is absent; polkit >= 0.106 is required for JS rules"
fi
install -o root -g root -m 0644 "$aeac_rule" /etc/polkit-1/rules.d/49-aaos-aeac.rules
if command -v pkaction >/dev/null; then
  pkaction >/dev/null 2>&1 || refuse "pkaction failed; polkit did not accept its config"
fi
# polkit re-reads rules.d on change, so no restart. Reloading is still asked for
# explicitly, because "it should pick it up" is not a verification.
if command -v systemctl >/dev/null && systemctl is-active --quiet polkit.service; then
  systemctl reload polkit.service 2>/dev/null ||
    systemctl restart polkit.service ||
    refuse "polkit would not reload after installing the AEAC rule"
fi

status "provisioning backing store /knowledge (tmpfiles must not stub this)"
install -d -m 0755 /knowledge
printf '%s\n' 'aaos-fuse-probe' >/knowledge/FUSE-PROBE
chown -R aaos-c2:aaos-c2 /knowledge
chmod 0550 /knowledge
chmod 0440 /knowledge/FUSE-PROBE

export AAOS_ROOT=/opt/aaos
export AAOS_FORCE_ENABLE=1
status "calling enable_aaos_host.sh (AAOS_FORCE_ENABLE=1, host=$host)"
"$here/enable_aaos_host.sh"

status "verifying FUSE is read-only"
findmnt -n -M /mnt/aaos/fuse >/dev/null || refuse "FUSE mount is not a mountpoint"
opts=$(findmnt -n -o OPTIONS -M /mnt/aaos/fuse)
[[ ,$opts, == *,ro,* ]] || refuse "FUSE options are not read-only: $opts"
test -r /mnt/aaos/fuse/FUSE-PROBE || refuse "probe file is not readable through FUSE"
if su -s /bin/bash -c 'echo write >/mnt/aaos/fuse/SHOULD-FAIL' nobody 2>/dev/null; then
  rm -f /mnt/aaos/fuse/SHOULD-FAIL
  refuse "FUSE accepted a write"
fi
[[ ! -e /mnt/aaos/fuse/SHOULD-FAIL ]] || refuse "write leaked onto the FUSE tree"

status "verifying aaos-c2.service"
systemctl is-active --quiet aaos-c2.service || refuse "aaos-c2.service is not active"
systemctl is-enabled --quiet aaos-c2.service || refuse "aaos-c2.service is not enabled"
user=$(systemctl show -p User --value aaos-c2.service)
[[ $user == aaos-c2 ]] || refuse "aaos-c2.service User= is $user"

if command -v busctl >/dev/null; then
  if busctl --system status org.akkay.aaos.C2 >/dev/null 2>&1; then
    status "D-Bus name org.akkay.aaos.C2 is claimed"
  elif busctl --system status org.akkay.AAOS >/dev/null 2>&1; then
    status "D-Bus name org.akkay.AAOS is claimed"
  else
    status "D-Bus policy installed; org.akkay.aaos.C2 is not claimed (bus binding not in this slice)"
  fi
fi

status "local staging complete"
systemctl is-active mnt-aaos-fuse.mount aaos-memory-fuse.service aaos-c2.service || true
findmnt -n -M /mnt/aaos/fuse || true
