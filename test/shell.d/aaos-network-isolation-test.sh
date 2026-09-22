#!/bin/bash
# The agent runtime has no network. Fetch-on-behalf is a D-Bus mount, not a route.
#
# WHY THIS EXISTS INSTEAD OF AN eBPF EGRESS FILTER ON THE CONTAINER. Sprint 2.3 asked
# for an eBPF program to drop unauthorised container egress. There is no unauthorised
# container egress to drop: spawn_agent_sandbox.sh runs every agent with --network none,
# so the container gets a namespace with loopback and no route to anything. A filter
# there would inspect zero packets for as long as that stays true, and every test of it
# would pass whether or not the filter worked. That is a control that cannot fail, which
# is the same defect as a capability that cannot be called.
#
# The property worth guarding is "container egress is still impossible". Remove
# --network none in a refactor, or publish a port, and the isolation would quietly
# disappear with no test going red. This file goes red instead.
#
# The C2 daemon is the other half. It used to set IPAddressDeny=any, which cannot
# express "port 443". Fetch-on-behalf replaced that with NFTSet cgroup filtering:
# DNS and HTTPS out, RFC1918/link-local/loopback rejected. The daemon may open
# sockets; the container still may not.

set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"

spawn="$ROOT/scripts/spawn_agent_sandbox.sh"
unit="$ROOT/default/systemd/system/aaos-c2.service"
nft_unit="$ROOT/default/systemd/system/aaos-c2-nftables.service"
nft_table="$ROOT/etc/nftables.d/aaos-c2.nft"
dbus="$ROOT/etc/dbus-1/system.d/aaos-c2.conf"
[[ -f $spawn ]] || fail "spawn_agent_sandbox.sh is present"
[[ -f $unit ]] || fail "aaos-c2.service is present"
[[ -f $nft_unit ]] || fail "aaos-c2-nftables.service is present"
[[ -f $nft_table ]] || fail "aaos-c2 nftables table is present"

# --- the sandbox has no network -------------------------------------------------

grep -qE -- '--network[= ]none' "$spawn" ||
  fail "sandbox must run with --network none" \
       "$(grep -nE -- '--network' "$spawn" || echo 'no --network flag at all')"
pass "agent sandbox runs with --network none"

# A second --network later in the argv would win. One occurrence, or the first is advice.
count=$(grep -cE -- '--network' "$spawn")
[[ $count -eq 1 ]] ||
  fail "sandbox declares --network $count times; the last one wins" \
       "$(grep -nE -- '--network' "$spawn")"
pass "agent sandbox declares --network exactly once"

# Scoped to the podman invocation, not the whole file. A bare `-p ` over the whole
# script matched `mkdir -p "$work/bin"`, which is not a published port. A check that
# fires on unrelated code is a check people learn to silence.
podman_block=$(sed -n '/podman --remote=false run/,/^$/p' "$spawn")
[[ -n $podman_block ]] || fail "could not locate the podman run invocation"
for banned in '--publish' '(^|[[:space:]])-p[[:space:]]' '--network[= ]host' \
              '--network[= ]bridge' '--dns' '--add-host'; do
  if grep -qE -- "$banned" <<<"$podman_block"; then
    fail "sandbox must not open a network path: $banned" \
         "$(grep -nE -- "$banned" <<<"$podman_block")"
  fi
done
pass "agent sandbox publishes no ports and joins no bridge"

grep -q -- '--volume /run/dbus/system_bus_socket:/run/dbus/system_bus_socket:ro' "$spawn" ||
  fail "sandbox must bind-mount the system bus socket read-only"
if grep -q -- 'system_bus_socket:ro,Z' "$spawn"; then
  fail "sandbox must not SELinux-relabel the host D-Bus socket with :Z"
fi
grep -q -- 'DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket' "$spawn" ||
  fail "sandbox must set DBUS_SYSTEM_BUS_ADDRESS to the system bus socket"
pass "agent sandbox mounts the system bus socket read-only without :Z"

# --- the daemon has filtered egress, not a blanket deny -------------------------

if grep -qE '^IPAddressDeny=' "$unit"; then
  fail "aaos-c2.service must not set IPAddressDeny; port filter is nftables via NFTSet" \
       "$(grep -nE '^IPAddressDeny=' "$unit")"
fi
if grep -qE '^IPAddressAllow=' "$unit"; then
  fail "aaos-c2.service must not set IPAddressAllow; that implies deny-any for everything else" \
       "$(grep -nE '^IPAddressAllow=' "$unit")"
fi
if grep -qE '^PrivateNetwork=' "$unit"; then
  fail "aaos-c2.service must not set PrivateNetwork; fetch-on-behalf needs a route" \
       "$(grep -nE '^PrivateNetwork=' "$unit")"
fi
pass "aaos-c2.service does not reimpose address-only deny or PrivateNetwork"

families=$(grep '^RestrictAddressFamilies=' "$unit" || true)
[[ $families == "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6" ]] ||
  fail "aaos-c2.service must allow AF_UNIX AF_INET AF_INET6 for DNS/HTTPS" "$families"
pass "aaos-c2.service allows AF_UNIX AF_INET AF_INET6"

grep -q '^NFTSet=cgroup:inet:aaos:aaos_c2_cgroup' "$unit" ||
  fail "aaos-c2.service must bind its cgroup into table inet aaos set aaos_c2_cgroup"
grep -q 'Requires=.*aaos-c2-nftables.service' "$unit" ||
  fail "aaos-c2.service must require the nftables table unit"
pass "aaos-c2.service uses NFTSet Option B"

grep -q 'type cgroupsv2' "$nft_table" || fail "nft table declares a cgroupsv2 set"
grep -q 'tcp dport 443 accept' "$nft_table" || fail "nft table allows outbound HTTPS"
grep -q 'udp dport 53 accept' "$nft_table" || fail "nft table allows outbound DNS"
grep -q 'ip daddr 127.0.0.53 udp dport 53 accept' "$nft_table" ||
  fail "nft table must allow DNS to systemd-resolved before rejecting loopback"
if ! grep -q '10.0.0.0/8' "$nft_table" || ! grep -q '169.254.0.0/16' "$nft_table"; then
  fail "nft table must reject RFC1918 and link-local destinations"
fi
grep -q '^[[:space:]]*drop$' "$nft_table" || fail "nft C2 egress chain must default-drop"
if grep -qiE 'flush ruleset' "$nft_table"; then
  fail "nft table must not flush the host ruleset"
fi
pass "nft table allows DNS/HTTPS and rejects private ranges"

grep -q 'ExecStart=/usr/bin/env nft -f /etc/nftables.d/aaos-c2.nft' "$nft_unit" ||
  fail "aaos-c2-nftables.service must load /etc/nftables.d/aaos-c2.nft"
grep -q 'Before=aaos-c2.service' "$nft_unit" ||
  fail "aaos-c2-nftables.service must start before aaos-c2.service"
grep -q 'Before=.*aaos-c2-dbus.service' "$nft_unit" ||
  fail "aaos-c2-nftables.service must start before aaos-c2-dbus.service"
pass "aaos-c2-nftables.service loads the table before C2"

grep -q '^BusName=org.akkay.aaos.C2' "$ROOT/default/systemd/system/aaos-c2-dbus.service" ||
  fail "aaos-c2-dbus.service must claim org.akkay.aaos.C2"
pass "bus binding unit claims org.akkay.aaos.C2"

grep -q 'deny own="org.akkay.aaos.C2"' "$dbus" ||
  fail "dbus default denies owning org.akkay.aaos.C2"
grep -q 'allow own="org.akkay.aaos.C2"' "$dbus" ||
  fail "dbus allows aaos-c2 to own org.akkay.aaos.C2"
grep -q 'send_interface="org.akkay.aaos.C2.Fetch1"' "$dbus" ||
  fail "dbus allows aaos-agent to send Fetch1"
pass "dbus policy names org.akkay.aaos.C2 and Fetch1"

# The Python side, because the unit could be relaxed independently of the code and the
# code could grow a socket independently of the unit. aaos_c2.py itself still must
# open no socket; fetch-on-behalf lives in aaos_c2_dbus.py / fetch_on_behalf.py.
daemon=""
for candidate in \
  "$ROOT/../AKKAY Agentic OS/scripts/aaos_c2.py" \
  /opt/aaos/scripts/aaos_c2.py; do
  if [[ -f $candidate ]]; then
    daemon=$candidate
    break
  fi
done

if [[ -z $daemon ]]; then
  printf 'ok - # SKIP aaos_c2.py not found beside omarchy or at /opt/aaos\n'
  exit 0
fi

# Comment lines are stripped: the module DISCUSSES having no socket at length, and an
# unstripped grep reads that explanation as the thing it warns about.
code=$(grep -vE '^[[:space:]]*#' "$daemon")
for banned in 'import socket' 'import http' 'socketserver' 'HTTPServer' 'asyncio' \
              '\.bind\(' '\.listen\('; do
  if grep -qE "$banned" <<<"$code"; then
    fail "aaos_c2.py must open no socket: $banned" \
         "$(grep -nE "$banned" "$daemon")"
  fi
done
pass "aaos_c2.py opens no socket"

# --- tailscale, stated rather than assumed --------------------------------------
#
# Sprint 2.3 asked for the daemon to be bound exclusively to tailscale0. Fetch-on-behalf
# egress is public HTTPS/DNS via nftables, not a mesh listener. A BindToDevice would
# pin fetches to one interface and break resolved-on-loopback. Keep the absence
# deliberate.
if grep -qE '^BindToDevice=' "$unit"; then
  fail "aaos-c2.service must not bind a network device" \
       "$(grep -nE '^BindToDevice=' "$unit")"
fi
pass "aaos-c2.service binds no device"

if grep -qE '^(Requires|After)=.*tailscaled' "$unit"; then
  fail "aaos-c2.service depends on tailscaled but fetch-on-behalf is not mesh-bound" \
       "revisit this test if the daemon actually serves over the mesh"
fi
pass "aaos-c2.service does not depend on tailscaled it does not use"
