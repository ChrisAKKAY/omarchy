#!/bin/bash
# Stage Omarchy C2 host files and the AAOS payload onto a node, then run --check.
# Does not activate units. First argument is an SSH destination (alias, user@host, or IP).
set -euo pipefail

usage() {
  printf '%s\n' "usage: deploy_to_node.sh <ssh-destination>" >&2
  exit 2
}

status() {
  printf '[aaos-stage] %s\n' "$*"
}

refuse() {
  printf '[aaos-stage] refuse: %s\n' "$*" >&2
  exit 1
}

(( $# == 1 )) || usage
target=$1
[[ $target =~ ^[A-Za-z0-9._@:-]+$ ]] || refuse "target is not a safe SSH destination"

OMARCHY_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ -n ${AAOS_ROOT:-} ]]; then
  AAOS_ROOT=$(cd -- "$AAOS_ROOT" && pwd)
else
  sibling_a="$OMARCHY_ROOT/../AKKAY Agentic OS"
  sibling_b="$OMARCHY_ROOT/../AkkayAgenticOS"
  if [[ -d "$sibling_a/scripts" ]]; then
    AAOS_ROOT=$(cd -- "$sibling_a" && pwd)
  elif [[ -d "$sibling_b/scripts" ]]; then
    AAOS_ROOT=$(cd -- "$sibling_b" && pwd)
  else
    refuse "AAOS_ROOT is unset and no sibling AAOS checkout was found"
  fi
fi

command -v ssh >/dev/null || refuse "ssh is missing"
command -v rsync >/dev/null || refuse "rsync is missing"

ssh_cmd() {
  ssh -o BatchMode=yes -o ConnectTimeout=20 -- "$@"
}
export RSYNC_RSH='ssh -o BatchMode=yes -o ConnectTimeout=20'

unit=$OMARCHY_ROOT/default/systemd/system/aaos-c2.service
dbus_unit=$OMARCHY_ROOT/default/systemd/system/aaos-c2-dbus.service
nft_unit=$OMARCHY_ROOT/default/systemd/system/aaos-c2-nftables.service
nft_table=$OMARCHY_ROOT/etc/nftables.d/aaos-c2.nft
mount=$OMARCHY_ROOT/default/systemd/system/mnt-aaos-fuse.mount
fuse_unit=$OMARCHY_ROOT/default/systemd/system/aaos-memory-fuse.service
helper=$OMARCHY_ROOT/scripts/aaos-memory-fuse
bus=$OMARCHY_ROOT/scripts/aaos-c2-bus
sysusers=$OMARCHY_ROOT/etc/sysusers.d/aaos-c2.conf
tmpfiles=$OMARCHY_ROOT/etc/tmpfiles.d/aaos-c2.conf
dbus=$OMARCHY_ROOT/etc/dbus-1/system.d/aaos-c2.conf
daemon=$AAOS_ROOT/scripts/aaos_c2.py
for path in "$unit" "$dbus_unit" "$nft_unit" "$nft_table" "$mount" "$fuse_unit" "$helper" "$bus" "$sysusers" "$tmpfiles" "$dbus" "$daemon"; do
  [[ -f $path ]] || refuse "missing local file: $path"
done

status "target=$target"
status "omarchy=$OMARCHY_ROOT"
status "aaos=$AAOS_ROOT"

status "creating /tmp/aaos-staging on the node (mode 0700)"
ssh_cmd "$target" 'umask 077; mkdir -p /tmp/aaos-staging'

status "staging systemd, sysusers, tmpfiles, D-Bus, nftables, and FUSE helper to /tmp/aaos-staging"
rsync -a --chmod=F0644,D0700 \
  "$unit" "$dbus_unit" "$nft_unit" "$nft_table" "$mount" "$fuse_unit" "$sysusers" "$tmpfiles" "$dbus" \
  "$target:/tmp/aaos-staging/"
rsync -a --chmod=F0755,D0700 \
  "$helper" "$bus" \
  "$target:/tmp/aaos-staging/"

status "synchronizing AAOS python payload to /opt/aaos (no --delete)"
ssh_cmd "$target" 'umask 022; mkdir -p /opt/aaos/scripts /opt/aaos/config' \
  || ssh_cmd "$target" 'sudo -n mkdir -p /opt/aaos/scripts /opt/aaos/config'

rsync_payload() {
  local rsync_path=$1
  rsync -a --chmod=F0644,D0755 \
    --exclude '.git/' \
    --exclude '__pycache__/' \
    --exclude '.test-tmp/' \
    --rsync-path="$rsync_path" \
    "$AAOS_ROOT/scripts/" "$target:/opt/aaos/scripts/"
  if [[ -d $AAOS_ROOT/config ]]; then
    rsync -a --chmod=F0600,D0700 \
      --exclude '.git/' \
      --rsync-path="$rsync_path" \
      "$AAOS_ROOT/config/" "$target:/opt/aaos/config/"
  fi
}

if rsync_payload rsync; then
  status "payload landed without privilege escalation"
else
  status "retrying payload with sudo rsync (still not activating units)"
  rsync_payload 'sudo -n rsync' || refuse "cannot write /opt/aaos on the node"
fi

status "running C2 preflight (--check only)"
ssh_cmd "$target" \
  'export AAOS_STORE=/store AAOS_KNOWLEDGE=/knowledge AAOS_TRACES=/traces AAOS_C2_OPERATOR=k PATH=/usr/bin:/bin; /usr/bin/env python3.12 /opt/aaos/scripts/aaos_c2.py --check'

status "preflight returned; units were not activated"
